"""Studies › Language: guided reading (speech with each word's timing), in-context translation,
vocabulary notebook with spaced repetition (FSRS), corrected writing and reading aloud.

Everything through the local LLM and the PC worker voice, never through Claude. Data in
`<estudos>/linguagem/`: `vocabulario.json`, `escritas.json`, `leituras_voz.json`,
`atividades.json` and the speech and translation caches (`cache/`)."""

import base64
import hashlib
import json
import logging
import math
import os
import re
import threading
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from shared.speech_text import compare_reading, normalize_word
from studies.languages import LANGUAGES, LEVELS
from studies.studies import Collection, Invalid, NotFound

logger = logging.getLogger(__name__)

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]
TaskWorker = Callable[[str, dict[str, Any]], Awaitable[dict[str, Any]]]

NAMES = {"en": "English", "es": "Spanish", "fr": "French", "pt": "Brazilian Portuguese"}
KINDS_ACTIVITY = {"leitura_guiada", "vocabulario", "escrita", "leitura_voz"}
LIMIT_CACHE_SPEECH = 2000
"""Falas guardadas (uma por frase); as mais antigas saem primeiro."""


class Unavailable(Exception):
    """No worker or no local LLM right now."""


def _now() -> datetime:
    return datetime.now(UTC)


def _iso(d: datetime) -> str:
    return d.isoformat(timespec="seconds")


def _language(language: str) -> str:
    if language not in LANGUAGES:
        raise Invalid(f"Idioma desconhecido: {language}")
    return language


# --- FSRS-4.5 (the modern Anki scheduler), with the default weights ---

W = [
    0.4872,
    1.4003,
    3.7145,
    13.8206,
    5.1618,
    1.2298,
    0.8975,
    0.031,
    1.6474,
    0.1367,
    1.0461,
    2.1072,
    0.0793,
    0.3246,
    1.587,
    0.2272,
    2.8755,
]
_F, _C = 19 / 81, -0.5
NOTES = {1: "errei", 2: "difícil", 3: "bom", 4: "fácil"}


def _d0(note: int) -> float:
    return min(max(W[4] - (note - 3) * W[5], 1.0), 10.0)


def retention(dias: float, estabilidade: float) -> float:
    """Chance of remembering after the given days with the card's stability."""
    return float((1 + _F * dias / estabilidade) ** _C)


def review(cartao: dict[str, Any], note: int, now: datetime | None = None) -> dict[str, Any]:
    """New card state (`estabilidade`, `dificuldade`, `revisoes`, `ultima`, `proxima`)
    after a review with a 1–4 grade. With a 90 % target retention, the interval
    is the stability."""
    if note not in NOTES:
        raise Invalid("A nota vai de 1 (errei) a 4 (fácil).")
    now = now or _now()
    s, d = cartao.get("estabilidade"), cartao.get("dificuldade")
    if not s or not d:
        s, d = W[note - 1], _d0(note)
    else:
        last = datetime.fromisoformat(cartao["ultima"])
        r = retention(max((now - last).total_seconds() / 86400, 0.0), s)
        if note == 1:
            s = W[11] * d ** -W[12] * ((s + 1) ** W[13] - 1) * math.exp(W[14] * (1 - r))
        else:
            bonus = (W[15] if note == 2 else 1.0) * (W[16] if note == 4 else 1.0)
            s = s * (
                math.exp(W[8]) * (11 - d) * s ** -W[9] * (math.exp(W[10] * (1 - r)) - 1) * bonus + 1
            )
        d = W[7] * _d0(3) + (1 - W[7]) * (d - W[6] * (note - 3))
        d = min(max(d, 1.0), 10.0)
    s = max(float(s), 0.01)
    interval = timedelta(minutes=10) if note == 1 else timedelta(days=max(1, round(s)))
    return {
        "estabilidade": round(s, 4),
        "dificuldade": round(float(d), 4),
        "revisoes": int(cartao.get("revisoes", 0)) + 1,
        "lapsos": int(cartao.get("lapsos", 0)) + (1 if note == 1 else 0),
        "ultima": _iso(now),
        "proxima": _iso(now + interval),
    }


def note_of(points: float) -> int:
    """0–100 exercise score → FSRS grade."""
    return 1 if points < 50 else 2 if points < 70 else 3 if points < 90 else 4


# --- local LLM: JSON requests ---


def extract_json(answer: str) -> Any:
    """First JSON object of the answer (ignores <think>, fences and surrounding text)."""
    text = re.sub(r"<think>.*?</think>", "", answer, flags=re.DOTALL)
    start = text.find("{")
    if start < 0:
        raise Invalid("A IA não devolveu JSON.")
    try:
        data, _ = json.JSONDecoder().raw_decode(text[start:])
    except json.JSONDecodeError as e:
        raise Invalid(f"A IA devolveu um JSON inválido: {e.msg}.") from e
    if not isinstance(data, dict):
        raise Invalid("A IA não devolveu um objeto JSON.")
    return data


SYSTEM = (
    "You are the language teacher of a Brazilian student who reads scientific papers. "
    "Respond ONLY with a valid JSON object, with no text before or after it, in the requested "
    "format. Explanations always in Brazilian Portuguese."
)


def prompt_translation(term: str, sentence: str, language: str, destination: str) -> str:
    return (
        f'Excerpt in {NAMES[language]} marked while reading: "{term}"\n'
        f'Sentence where it appears: "{sentence}"\n\n'
        f"Translate the excerpt into {NAMES[destination]} with the meaning it has IN THIS "
        "sentence.\n"
        'Format: {"traducao": "...", "classe": "substantivo|verbo|adjetivo|advérbio|expressão|'
        'outra", "ipa": "IPA pronunciation of the excerpt in the original language", '
        '"sentido": "short explanation of the meaning in context, in Brazilian Portuguese", '
        '"frase_traduzida": "the whole sentence translated"}'
    )


def prompt_practice(item: dict[str, Any], nivel: str) -> str:
    contextos = "\n".join(
        f"- {c['frase']}" for c in item.get("contextos", [])[:3] if c.get("frase")
    )
    return (
        f'Word/expression in {NAMES[item["idioma"]]}: "{item["termo"]}" '
        f"(translation: {item.get('traducao') or '?'}). Student level: {nivel}.\n"
        f"Where it appeared in the reading:\n{contextos or '- (no context)'}\n\n"
        "Create material to memorize the word:\n"
        "- 6 new, natural sentences that use it, from level A2 to C1, with their translation "
        "into Brazilian Portuguese;\n"
        "- 2 fill-in-the-blank exercises (the sentence with ____ in place of the word, answer = "
        "the exact form that completes it);\n"
        "- 2 translation exercises (statement = a sentence in Brazilian Portuguese, answer = the "
        "expected translation);\n"
        "- 1 production exercise (statement asking for an original sentence with the word in a "
        "given situation; empty answer).\n"
        "Write the statements of the exercises in Brazilian Portuguese.\n"
        'Format: {"frases": [{"texto": "...", "traducao": "...", "nivel": "B1"}], '
        '"exercicios": [{"tipo": "lacuna|traducao|producao", "enunciado": "...", '
        '"resposta": "..."}]}'
    )


def prompt_correction(item: dict[str, Any], exercise: dict[str, Any], answer: str) -> str:
    return (
        f'{NAMES[item["idioma"]]} exercise about "{item["termo"]}" '
        f"({exercise['tipo']}).\nStatement: {exercise['enunciado']}\n"
        f"Reference answer: {exercise.get('resposta') or '(free)'}\n"
        f"Student's answer: {answer}\n\n"
        "Assess whether the answer is correct and natural (accept valid variations, do not demand "
        "the reference word for word) and whether it uses the studied word correctly.\n"
        'Format: {"correto": true, "nota": 0-100, "correcao": "the corrected answer", '
        '"explicacao": "what was wrong and why, in Brazilian Portuguese"}'
    )


def prompt_writing(language: str, nivel: str, text: str, words: list[str]) -> str:
    base = f'Text read by the student (excerpt):\n"""\n{text[:6000]}\n"""\n\n' if text else ""
    return (
        f"{base}Create a writing task in {NAMES[language]} for a student at level {nivel}. "
        f"{'Base the questions on the text above. ' if text else ''}"
        "Write 3 questions, in the language being studied: one of comprehension, one of summary "
        "and one of opinion/application. Each one asks for 3 to 6 sentences."
        + (
            f" Suggest using some of these words from the student's notebook: {', '.join(words)}."
            if words
            else ""
        )
        + '\nFormat: {"titulo": "...", "perguntas": [{"pergunta": "...", '
        '"tipo": "compreensao|resumo|opiniao", "palavras_sugeridas": ["..."]}]}'
    )


def prompt_correction_writing(
    language: str, nivel: str, pergunta: dict[str, Any], answer: str, text: str
) -> str:
    base = f'Excerpt of the reference text:\n"""\n{text[:3000]}\n"""\n\n' if text else ""
    return (
        f"{base}Question ({NAMES[language]}): {pergunta['pergunta']}\n"
        f'Student\'s answer (declared level {nivel}):\n"""\n{answer}\n"""\n\n'
        "Correct it like a teacher: scores from 0 to 100 for grammar, vocabulary, coherence and "
        "fit to the question; the CEFR level the text shows; the corrected text keeping the "
        "student's idea; each correction with its explanation in Brazilian Portuguese; a final "
        "comment, in Brazilian Portuguese, on what to improve.\n"
        'Format: {"nota": 0-100, "gramatica": 0-100, "vocabulario": 0-100, "coerencia": 0-100, '
        '"adequacao": 0-100, "nivel_cefr": "A1|A2|B1|B2|C1|C2", "texto_corrigido": "...", '
        '"correcoes": [{"trecho": "...", "correcao": "...", "explicacao": "..."}], '
        '"comentario": "..."}'
    )


def _points(value: Any) -> int:
    try:
        return min(max(round(float(value)), 0), 100)
    except (TypeError, ValueError):
        return 0


def _text(value: Any, limite: int = 4000) -> str:
    return str(value or "").strip()[:limite]


class Language:
    def __init__(
        self,
        root: str | Path,
        chat: ChatLLM | None = None,
        worker: TaskWorker | None = None,
        texto_do_arquivo: Callable[[str], str] | None = None,
        somar_minutos: Callable[[str, str, int], None] | None = None,
    ) -> None:
        self.root = Path(root).expanduser() / "linguagem"
        (self.root / "cache" / "fala").mkdir(parents=True, exist_ok=True)
        (self.root / "cache" / "traducao").mkdir(parents=True, exist_ok=True)
        lock = threading.RLock()
        self.vocabulary = Collection(self.root / "vocabulario.json", lock)
        self.writes = Collection(self.root / "escritas.json", lock)
        self.readings_voice = Collection(self.root / "leituras_voz.json", lock)
        self.activities = Collection(self.root / "atividades.json", lock)
        self._chat = chat
        self._worker = worker
        self._text_of_file = texto_do_arquivo or (lambda _id: "")
        self._add_up_minutes = somar_minutos or (lambda _i, _d, _m: None)

    # --- access to the local LLM and the worker ---

    async def _json(self, prompt: str) -> dict[str, Any]:
        if self._chat is None:
            raise Unavailable("LLM local não configurada neste servidor.")
        messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}]
        try:
            answer = await self._chat(messages)
            try:
                return extract_json(answer)
            except Invalid as e:  # second chance: the local model sometimes chats first
                messages += [
                    {"role": "assistant", "content": answer[:3000]},
                    {"role": "user", "content": f"{e} Respond again ONLY with the JSON."},
                ]
                return extract_json(await self._chat(messages))
        except RuntimeError as e:
            raise Unavailable(str(e)) from e

    async def _task(self, task: str, payload: dict[str, Any]) -> dict[str, Any]:
        if self._worker is None:
            raise Unavailable("Worker de voz não configurado neste servidor.")
        try:
            return await self._worker(task, payload)
        except RuntimeError as e:
            raise Unavailable(str(e)) from e

    # --- guided reading ---

    def _cache(self, tipo: str, chave: str) -> Path:
        return (
            self.root / "cache" / tipo / f"{hashlib.sha256(chave.encode()).hexdigest()[:32]}.json"
        )

    def _prune_speeches(self) -> None:
        files = sorted((self.root / "cache" / "fala").glob("*.json"), key=os.path.getmtime)
        for f in files[: max(0, len(files) - LIMIT_CACHE_SPEECH)]:
            f.unlink(missing_ok=True)

    async def speech(self, text: str, language: str, speed: float = 1.0) -> dict[str, Any]:
        """Sentence audio and each word's timing (`inicio`/`fim` in the text, `t0`/`t1` in s)."""
        language = _language(language)
        text = " ".join(text.split())
        if not text:
            raise Invalid("Texto vazio.")
        cache = self._cache("fala", f"{language}|{speed:.2f}|{text}")
        if cache.exists():
            os.utime(cache)
            data: dict[str, Any] = json.loads(cache.read_text("utf-8"))
            return data
        r = await self._task(
            "falar_marcado", {"texto": text, "idioma": language, "velocidade": speed}
        )
        data = {
            "texto": text,
            "audio_b64": r["audio_b64"],
            "mime": r.get("mime", "audio/wav"),
            "duracao": r.get("duracao", 0),
            "palavras": r.get("palavras", []),
        }
        cache.write_text(json.dumps(data), "utf-8")
        self._prune_speeches()
        return data

    async def translate(
        self, term: str, sentence: str, language: str, destination: str = "pt"
    ) -> dict[str, Any]:
        """Translation of the excerpt in the sense of the sentence, with part of speech, IPA and
        the translated sentence."""
        language, destination = _language(language), _language(destination)
        term, sentence = " ".join(term.split()), " ".join(sentence.split())
        if not term:
            raise Invalid("Nada para traduzir.")
        cache = self._cache("traducao", f"{language}>{destination}|{term}|{sentence}")
        if cache.exists():
            data: dict[str, Any] = json.loads(cache.read_text("utf-8"))
            return data
        r = await self._json(prompt_translation(term, sentence or term, language, destination))
        data = {
            "termo": term,
            "traducao": _text(r.get("traducao"), 500),
            "classe": _text(r.get("classe"), 40),
            "ipa": _text(r.get("ipa"), 200),
            "sentido": _text(r.get("sentido"), 1000),
            "frase_traduzida": _text(r.get("frase_traduzida"), 2000),
        }
        if not data["traducao"]:
            raise Invalid("A IA não trouxe a tradução.")
        cache.write_text(json.dumps(data, ensure_ascii=False), "utf-8")
        return data

    # --- vocabulary notebook ---

    def _level(self, language: str) -> str:
        return "B1" if language != "pt" else "C1"

    def list_vocabulary(
        self, language: str | None = None, devidas: bool = False
    ) -> list[dict[str, Any]]:
        now = _iso(_now())
        items = [
            v
            for v in self.vocabulary.ler()
            if (language is None or v["idioma"] == language)
            and (not devidas or v.get("cartao", {}).get("proxima", "") <= now)
        ]
        key = (lambda v: v.get("cartao", {}).get("proxima", "")) if devidas else None
        return sorted(items, key=key) if key else items[::-1]

    def create_vocabulary(self, dados: dict[str, Any]) -> dict[str, Any]:
        """Word marked while reading. The same word again merges its context into the existing
        one."""
        language = _language(str(dados.get("idioma") or ""))
        term = " ".join(str(dados.get("termo") or "").split())
        if not term:
            raise Invalid("Palavra vazia.")
        context = {
            "frase": _text(dados.get("contexto"), 2000),
            "arquivo_id": dados.get("arquivo_id"),
            "titulo": _text(dados.get("titulo"), 300),
            "pagina": dados.get("pagina"),
        }
        with self.vocabulary.lock:
            for v in self.vocabulary.ler():
                if v["idioma"] == language and normalize_word(v["termo"]) == normalize_word(term):
                    contextos = v.get("contextos", [])
                    if context["frase"] and all(
                        c["frase"] != context["frase"] for c in contextos
                    ):
                        contextos = [*contextos, context]
                    return self.vocabulary.edit(v["id"], {"contextos": contextos})
            return self.vocabulary.criar(
                {
                    "termo": term,
                    "idioma": language,
                    "traducao": _text(dados.get("traducao"), 500),
                    "classe": _text(dados.get("classe"), 40),
                    "ipa": _text(dados.get("ipa"), 200),
                    "contextos": [context] if context["frase"] else [],
                    "frases": [],
                    "exercicios": [],
                    "respostas": [],
                    "cartao": {"proxima": _iso(_now()), "revisoes": 0},
                    "gerando": False,
                }
            )

    async def generate_practice(self, id_: str) -> dict[str, Any]:
        """Sentences and exercises for the word from the local LLM (replaces the previous ones)."""
        item = self.vocabulary.obter(id_)
        self.vocabulary.edit(id_, {"gerando": True, "erro": ""})
        try:
            r = await self._json(prompt_practice(item, self._level(item["idioma"])))
        except (Unavailable, Invalid) as e:
            self.vocabulary.edit(id_, {"gerando": False, "erro": str(e)})
            raise
        sentences = [
            {
                "texto": _text(f.get("texto"), 600),
                "traducao": _text(f.get("traducao"), 600),
                "nivel": f.get("nivel") if f.get("nivel") in LEVELS else "",
            }
            for f in r.get("frases") or []
            if isinstance(f, dict) and f.get("texto")
        ]
        exercises = [
            {
                "tipo": e["tipo"],
                "enunciado": _text(e.get("enunciado"), 600),
                "resposta": _text(e.get("resposta"), 600),
            }
            for e in r.get("exercicios") or []
            if isinstance(e, dict)
            and e.get("tipo") in ("lacuna", "traducao", "producao")
            and e.get("enunciado")
        ]
        return self.vocabulary.edit(
            id_, {"frases": sentences, "exercicios": exercises, "gerando": False, "erro": ""}
        )

    def review_vocabulary(self, id_: str, note: int) -> dict[str, Any]:
        item = self.vocabulary.obter(id_)
        return self.vocabulary.edit(id_, {"cartao": review(item.get("cartao", {}), note)})

    async def answer_exercise(self, id_: str, indice: int, answer: str) -> dict[str, Any]:
        """Grades the answer (a gap equal to the reference skips the AI) and schedules the
        review."""
        item = self.vocabulary.obter(id_)
        exercises = item.get("exercicios", [])
        if not 0 <= indice < len(exercises):
            raise NotFound(f"exercício {indice}")
        answer = answer.strip()
        if not answer:
            raise Invalid("Resposta vazia.")
        ex = exercises[indice]
        answer_certa = normalize_word(ex.get("resposta", ""))
        if ex["tipo"] == "lacuna" and normalize_word(answer) == answer_certa:
            correction = {
                "correto": True, "nota": 100, "correcao": ex["resposta"], "explicacao": ""
            }
        else:
            r = await self._json(prompt_correction(item, ex, answer))
            correction = {
                "correto": bool(r.get("correto")),
                "nota": _points(r.get("nota")),
                "correcao": _text(r.get("correcao"), 1000),
                "explicacao": _text(r.get("explicacao"), 2000),
            }
        record = {"exercicio": indice, "resposta": answer, **correction, "data": _iso(_now())}
        cartao = review(item.get("cartao", {}), note_of(correction["nota"]))
        atualizado = self.vocabulary.edit(
            id_, {"respostas": [*item.get("respostas", []), record][-50:], "cartao": cartao}
        )
        return {"correcao": record, "item": atualizado}

    # --- writing ---

    def list_writes(self, language: str | None = None) -> list[dict[str, Any]]:
        return [e for e in self.writes.ler() if language is None or e["idioma"] == language][::-1]

    async def create_writing(self, dados: dict[str, Any]) -> dict[str, Any]:
        """Writing task about an article from Files (or pasted text), by the local LLM."""
        language = _language(str(dados.get("idioma") or ""))
        level = dados.get("nivel") if dados.get("nivel") in LEVELS else self._level(language)
        text = _text(dados.get("texto"), 20_000)
        file_id = dados.get("arquivo_id")
        if not text and file_id:
            text = self._text_of_file(str(file_id))[:20_000]
        words = [v["termo"] for v in self.list_vocabulary(language, devidas=True)[:8]]
        r = await self._json(prompt_writing(language, str(level), text, words))
        perguntas = [
            {
                "pergunta": _text(p.get("pergunta"), 1000),
                "tipo": _text(p.get("tipo"), 30),
                "palavras_sugeridas": [str(x)[:80] for x in p.get("palavras_sugeridas") or []][:8],
            }
            for p in r.get("perguntas") or []
            if isinstance(p, dict) and p.get("pergunta")
        ]
        if not perguntas:
            raise Invalid("A IA não criou as perguntas; tente de novo.")
        return self.writes.criar(
            {
                "idioma": language,
                "nivel": level,
                "titulo": _text(r.get("titulo"), 200) or "Escrita",
                "arquivo_id": file_id,
                "titulo_arquivo": _text(dados.get("titulo_arquivo"), 300),
                "texto_base": text[:6000],
                "perguntas": perguntas,
                "respostas": {},
            }
        )

    async def answer_writing(self, id_: str, indice: int, answer: str) -> dict[str, Any]:
        e = self.writes.obter(id_)
        if not 0 <= indice < len(e["perguntas"]):
            raise NotFound(f"pergunta {indice}")
        if len(answer.split()) < 3:
            raise Invalid("Escreva pelo menos uma frase.")
        r = await self._json(
            prompt_correction_writing(
                e["idioma"], e["nivel"], e["perguntas"][indice], answer, e.get("texto_base", "")
            )
        )
        correction = {
            "resposta": answer,
            "nota": _points(r.get("nota")),
            **{
                k: _points(r.get(k)) for k in ("gramatica", "vocabulario", "coerencia", "adequacao")
            },
            "nivel_cefr": r.get("nivel_cefr") if r.get("nivel_cefr") in LEVELS else "",
            "texto_corrigido": _text(r.get("texto_corrigido"), 10_000),
            "correcoes": [
                {k: _text(c.get(k), 1000) for k in ("trecho", "correcao", "explicacao")}
                for c in r.get("correcoes") or []
                if isinstance(c, dict)
            ][:30],
            "comentario": _text(r.get("comentario"), 3000),
            "data": _iso(_now()),
        }
        answers = {**e.get("respostas", {}), str(indice): correction}
        return self.writes.edit(id_, {"respostas": answers})

    # --- reading aloud ---

    def list_readings_voice(self, language: str | None = None) -> list[dict[str, Any]]:
        return [
            x for x in self.readings_voice.ler() if language is None or x["idioma"] == language
        ][::-1]

    async def evaluate_reading(
        self, audio: bytes, mime: str, language: str, reference: str, fonte: dict[str, Any]
    ) -> dict[str, Any]:
        """Compares the recording with the text: right/swapped/skipped words, pace, pauses and,
        with the phonetic model on the worker, each word's pronunciation."""
        language = _language(language)
        reference = " ".join(reference.split())
        if not reference:
            raise Invalid("Sem o texto que foi lido.")
        r = await self._task(
            "avaliar_leitura",
            {
                "audio_b64": base64.b64encode(audio).decode(),
                "mime": mime,
                "idioma": language,
                "referencia": reference,
            },
        )
        result = compare_reading(reference, r.get("palavras") or [])
        pronunciation = r.get("pronuncia")
        if isinstance(pronunciation, list):
            for p in pronunciation:
                k = p.get("indice")
                if isinstance(k, int) and 0 <= k < len(result["palavras"]):
                    result["palavras"][k]["fonemas"] = {
                        "esperado": p.get("esperado", ""),
                        "ouvido": p.get("ouvido", ""),
                        "acerto": p.get("acerto", 0),
                    }
            spoken = [
                p["fonemas"]["acerto"]
                for p in result["palavras"]
                if "fonemas" in p and p["estado"] != "omitida"
            ]
            result["pronuncia"] = round(100 * sum(spoken) / len(spoken), 1) if spoken else None
        else:
            result["pronuncia"] = None
        return self.readings_voice.criar(
            {
                "idioma": language,
                "referencia": reference,
                "arquivo_id": fonte.get("arquivo_id"),
                "titulo": _text(fonte.get("titulo"), 300),
                "pagina": fonte.get("pagina"),
                "aviso": _text(r.get("aviso"), 300),
                **result,
            }
        )

    # --- activities and progress ---

    def register_activity(self, dados: dict[str, Any]) -> dict[str, Any]:
        """Study time done outside the tab (guided reading in Files…); the minutes go into the
        language track, if there is one."""
        kind = str(dados.get("tipo") or "")
        if kind not in KINDS_ACTIVITY:
            raise Invalid(f"Tipo de atividade desconhecido: {kind}")
        language = _language(str(dados.get("idioma") or ""))
        minutes = int(dados.get("minutos") or 0)
        if not 0 <= minutes <= 600:
            raise Invalid("Minutos entre 0 e 600.")
        day = _now().astimezone().date().isoformat()
        activity = self.activities.criar(
            {
                "tipo": kind,
                "idioma": language,
                "minutos": minutes,
                "dia": day,
                "detalhes": {
                    k: v
                    for k, v in (dados.get("detalhes") or {}).items()
                    if isinstance(v, int | float | str)
                },
            }
        )
        if minutes:
            self._add_up_minutes(language, day, minutes)
        return activity

    def progress(self, language: str) -> dict[str, Any]:
        language = _language(language)
        now = _iso(_now())
        vocab = self.list_vocabulary(language)
        cartoes = [v.get("cartao", {}) for v in vocab]
        writes = [
            {"data": c["data"], "nota": c["nota"], "nivel_cefr": c.get("nivel_cefr", "")}
            for e in self.list_writes(language)
            for c in e.get("respostas", {}).values()
        ]
        readings = [
            {
                "data": x["criado"],
                "precisao": x["precisao"],
                "ppm": x["ppm"],
                "pronuncia": x.get("pronuncia"),
            }
            for x in self.list_readings_voice(language)
        ]
        minutes: dict[str, int] = {}
        for a in self.activities.ler():
            if a["idioma"] == language:
                minutes[a["tipo"]] = minutes.get(a["tipo"], 0) + int(a["minutos"])
        return {
            "idioma": language,
            "vocabulario": {
                "total": len(vocab),
                "devidas": sum(1 for c in cartoes if c.get("proxima", "") <= now),
                "aprendendo": sum(1 for c in cartoes if 0 < (c.get("estabilidade") or 0) < 21),
                "dominadas": sum(1 for c in cartoes if (c.get("estabilidade") or 0) >= 21),
            },
            "escrita": sorted(writes, key=lambda x: x["data"]),
            "leitura_voz": sorted(readings, key=lambda x: x["data"]),
            "minutos": minutes,
        }
