"""Estudos › Linguagem: leitura guiada (fala com o tempo de cada palavra), tradução no contexto,
caderno de vocabulário com repetição espaçada (FSRS), escrita corrigida e leitura em voz alta.

Tudo pela LLM local e pela voz do worker do PC, nunca pelo Claude. Dados em
`<estudos>/linguagem/`: `vocabulario.json`, `escritas.json`, `leituras_voz.json`,
`atividades.json` e os caches de fala e tradução (`cache/`)."""

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

from estudos.studies import Collection, Invalid, NotFound
from estudos.languages import LANGUAGES, LEVELS
from shared.speech_text import compare_reading, normalize_word

logger = logging.getLogger(__name__)

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]
TaskWorker = Callable[[str, dict[str, Any]], Awaitable[dict[str, Any]]]

NAMES = {"en": "inglês", "es": "espanhol", "fr": "francês", "pt": "português"}
KINDS_ACTIVITY = {"leitura_guiada", "vocabulario", "escrita", "leitura_voz"}
LIMIT_CACHE_SPEECH = 2000
"""Falas guardadas (uma por frase); as mais antigas saem primeiro."""


class Unavailable(Exception):
    """Sem worker ou sem LLM local agora."""


def _now() -> datetime:
    return datetime.now(UTC)


def _iso(d: datetime) -> str:
    return d.isoformat(timespec="seconds")


def _language(language: str) -> str:
    if language not in LANGUAGES:
        raise Invalid(f"Idioma desconhecido: {language}")
    return language


# --- FSRS-4.5 (o agendador do Anki moderno), com os pesos padrão ---

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
    """Chance de lembrar depois de [dias] com a [estabilidade] do cartão."""
    return float((1 + _F * dias / estabilidade) ** _C)


def review(cartao: dict[str, Any], note: int, agora: datetime | None = None) -> dict[str, Any]:
    """Novo estado do cartão (`estabilidade`, `dificuldade`, `revisoes`, `ultima`, `proxima`)
    depois de uma revisão com [nota] 1–4. Com retenção-alvo de 90 %, o intervalo
    é a estabilidade."""
    if note not in NOTES:
        raise Invalid("A nota vai de 1 (errei) a 4 (fácil).")
    agora = agora or _now()
    s, d = cartao.get("estabilidade"), cartao.get("dificuldade")
    if not s or not d:
        s, d = W[note - 1], _d0(note)
    else:
        last = datetime.fromisoformat(cartao["ultima"])
        r = retention(max((agora - last).total_seconds() / 86400, 0.0), s)
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
        "ultima": _iso(agora),
        "proxima": _iso(agora + interval),
    }


def note_of(points: float) -> int:
    """Pontuação 0–100 de um exercício → nota do FSRS."""
    return 1 if points < 50 else 2 if points < 70 else 3 if points < 90 else 4


# --- LLM local: pedidos em JSON ---


def extract_json(answer: str) -> Any:
    """Primeiro objeto JSON da resposta (ignora <think>, cercas e texto em volta)."""
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
    "Você é professor de idiomas de um estudante brasileiro que lê artigos científicos. "
    "Responda SOMENTE com um objeto JSON válido, sem texto antes ou depois, no formato pedido. "
    "Explicações sempre em português do Brasil."
)


def prompt_translation(term: str, sentence: str, language: str, destination: str) -> str:
    return (
        f'Trecho em {NAMES[language]} marcado durante a leitura: "{term}"\n'
        f'Frase em que aparece: "{sentence}"\n\n'
        f"Traduza o trecho para o {NAMES[destination]} no sentido que ele tem NESSA frase.\n"
        'Formato: {"traducao": "...", "classe": "substantivo|verbo|adjetivo|advérbio|expressão|'
        'outra", "ipa": "pronúncia em IPA do trecho no idioma original", '
        '"sentido": "explicação curta do sentido no contexto", '
        '"frase_traduzida": "a frase inteira traduzida"}'
    )


def prompt_practice(item: dict[str, Any], nivel: str) -> str:
    contextos = "\n".join(
        f"- {c['frase']}" for c in item.get("contextos", [])[:3] if c.get("frase")
    )
    return (
        f'Palavra/expressão em {NAMES[item["idioma"]]}: "{item["termo"]}" '
        f"(tradução: {item.get('traducao') or '?'}). Nível do aluno: {nivel}.\n"
        f"Onde ela apareceu na leitura:\n{contextos or '- (sem contexto)'}\n\n"
        "Crie material para memorizar a palavra:\n"
        "- 6 frases novas e naturais que a usem, do nível A2 ao C1, com a tradução;\n"
        "- 2 exercícios de lacuna (a frase com ____ no lugar da palavra, resposta = a forma exata "
        "que completa);\n"
        "- 2 exercícios de tradução (enunciado = frase em português, resposta = tradução "
        "esperada);\n"
        "- 1 exercício de produção (enunciado pedindo uma frase própria com a palavra numa "
        "situação dada; resposta vazia).\n"
        'Formato: {"frases": [{"texto": "...", "traducao": "...", "nivel": "B1"}], '
        '"exercicios": [{"tipo": "lacuna|traducao|producao", "enunciado": "...", '
        '"resposta": "..."}]}'
    )


def prompt_correction(item: dict[str, Any], exercise: dict[str, Any], answer: str) -> str:
    return (
        f'Exercício de {NAMES[item["idioma"]]} sobre "{item["termo"]}" '
        f"({exercise['tipo']}).\nEnunciado: {exercise['enunciado']}\n"
        f"Resposta de referência: {exercise.get('resposta') or '(livre)'}\n"
        f"Resposta do aluno: {answer}\n\n"
        "Avalie se a resposta está correta e natural (aceite variações válidas, não exija a "
        "referência palavra por palavra) e se usa a palavra estudada corretamente.\n"
        'Formato: {"correto": true, "nota": 0-100, "correcao": "a resposta corrigida", '
        '"explicacao": "o que estava errado e por quê"}'
    )


def prompt_writing(language: str, nivel: str, text: str, words: list[str]) -> str:
    base = f'Texto lido pelo aluno (trecho):\n"""\n{text[:6000]}\n"""\n\n' if text else ""
    return (
        f"{base}Crie uma tarefa de escrita em {NAMES[language]} para um aluno de nível {nivel}. "
        f"{'Baseie as perguntas no texto acima. ' if text else ''}"
        "Faça 3 perguntas, escritas no idioma estudado: uma de compreensão, uma de resumo e uma "
        "de opinião/aplicação. Cada uma pede de 3 a 6 frases."
        + (
            f" Sugira usar algumas destas palavras do caderno do aluno: {', '.join(words)}."
            if words
            else ""
        )
        + '\nFormato: {"titulo": "...", "perguntas": [{"pergunta": "...", '
        '"tipo": "compreensao|resumo|opiniao", "palavras_sugeridas": ["..."]}]}'
    )


def prompt_correction_writing(
    language: str, nivel: str, pergunta: dict[str, Any], answer: str, text: str
) -> str:
    base = f'Trecho do texto de referência:\n"""\n{text[:3000]}\n"""\n\n' if text else ""
    return (
        f"{base}Pergunta ({NAMES[language]}): {pergunta['pergunta']}\n"
        f'Resposta do aluno (nível declarado {nivel}):\n"""\n{answer}\n"""\n\n'
        "Corrija como um professor: notas de 0 a 100 para gramática, vocabulário, coerência e "
        "adequação à pergunta; o nível CEFR que o texto demonstra; o texto corrigido mantendo a "
        "ideia do aluno; cada correção com a explicação em português; um comentário final com o "
        "que melhorar.\n"
        'Formato: {"nota": 0-100, "gramatica": 0-100, "vocabulario": 0-100, "coerencia": 0-100, '
        '"adequacao": 0-100, "nivel_cefr": "A1|A2|B1|B2|C1|C2", "texto_corrigido": "...", '
        '"correcoes": [{"trecho": "...", "correcao": "...", "explicacao": "..."}], '
        '"comentario": "..."}'
    )


def _points(valor: Any) -> int:
    try:
        return min(max(round(float(valor)), 0), 100)
    except (TypeError, ValueError):
        return 0


def _text(valor: Any, limite: int = 4000) -> str:
    return str(valor or "").strip()[:limite]


class Language:
    def __init__(
        self,
        root: str | Path,
        chat: ChatLLM | None = None,
        worker: TaskWorker | None = None,
        texto_do_arquivo: Callable[[str], str] | None = None,
        somar_minutos: Callable[[str, str, int], None] | None = None,
    ) -> None:
        self.raiz = Path(root).expanduser() / "linguagem"
        (self.raiz / "cache" / "fala").mkdir(parents=True, exist_ok=True)
        (self.raiz / "cache" / "traducao").mkdir(parents=True, exist_ok=True)
        lock = threading.RLock()
        self.vocabulario = Collection(self.raiz / "vocabulario.json", lock)
        self.escritas = Collection(self.raiz / "escritas.json", lock)
        self.leituras_voz = Collection(self.raiz / "leituras_voz.json", lock)
        self.atividades = Collection(self.raiz / "atividades.json", lock)
        self._chat = chat
        self._worker = worker
        self._texto_do_arquivo = texto_do_arquivo or (lambda _id: "")
        self._somar_minutos = somar_minutos or (lambda _i, _d, _m: None)

    # --- acesso à LLM local e ao worker ---

    async def _json(self, prompt: str) -> dict[str, Any]:
        if self._chat is None:
            raise Unavailable("LLM local não configurada neste servidor.")
        messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}]
        try:
            answer = await self._chat(messages)
            try:
                return extract_json(answer)
            except Invalid as e:  # segunda chance: o modelo local às vezes conversa antes
                messages += [
                    {"role": "assistant", "content": answer[:3000]},
                    {"role": "user", "content": f"{e} Responda de novo SOMENTE com o JSON."},
                ]
                return extract_json(await self._chat(messages))
        except RuntimeError as e:
            raise Unavailable(str(e)) from e

    async def _tarefa(self, task: str, payload: dict[str, Any]) -> dict[str, Any]:
        if self._worker is None:
            raise Unavailable("Worker de voz não configurado neste servidor.")
        try:
            return await self._worker(task, payload)
        except RuntimeError as e:
            raise Unavailable(str(e)) from e

    # --- leitura guiada ---

    def _cache(self, tipo: str, chave: str) -> Path:
        return (
            self.raiz / "cache" / tipo / f"{hashlib.sha256(chave.encode()).hexdigest()[:32]}.json"
        )

    def _podar_falas(self) -> None:
        files = sorted((self.raiz / "cache" / "fala").glob("*.json"), key=os.path.getmtime)
        for f in files[: max(0, len(files) - LIMIT_CACHE_SPEECH)]:
            f.unlink(missing_ok=True)

    async def fala(self, text: str, language: str, speed: float = 1.0) -> dict[str, Any]:
        """Áudio da frase e o tempo de cada palavra (`inicio`/`fim` no texto, `t0`/`t1` em s)."""
        language = _language(language)
        text = " ".join(text.split())
        if not text:
            raise Invalid("Texto vazio.")
        cache = self._cache("fala", f"{language}|{speed:.2f}|{text}")
        if cache.exists():
            os.utime(cache)
            data: dict[str, Any] = json.loads(cache.read_text("utf-8"))
            return data
        r = await self._tarefa(
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
        self._podar_falas()
        return data

    async def traduzir(
        self, term: str, sentence: str, language: str, destination: str = "pt"
    ) -> dict[str, Any]:
        """Tradução do trecho no sentido da frase, com classe, IPA e a frase traduzida."""
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

    # --- caderno de vocabulário ---

    def _nivel(self, language: str) -> str:
        return "B1" if language != "pt" else "C1"

    def listar_vocabulario(
        self, language: str | None = None, devidas: bool = False
    ) -> list[dict[str, Any]]:
        now = _iso(_now())
        items = [
            v
            for v in self.vocabulario.ler()
            if (language is None or v["idioma"] == language)
            and (not devidas or v.get("cartao", {}).get("proxima", "") <= now)
        ]
        key = (lambda v: v.get("cartao", {}).get("proxima", "")) if devidas else None
        return sorted(items, key=key) if key else items[::-1]

    def criar_vocabulario(self, dados: dict[str, Any]) -> dict[str, Any]:
        """Palavra marcada na leitura. A mesma palavra de novo junta o contexto à que já existe."""
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
        with self.vocabulario.trava:
            for v in self.vocabulario.ler():
                if v["idioma"] == language and normalize_word(v["termo"]) == normalize_word(term):
                    contextos = v.get("contextos", [])
                    if context["frase"] and all(
                        c["frase"] != context["frase"] for c in contextos
                    ):
                        contextos = [*contextos, context]
                    return self.vocabulario.editar(v["id"], {"contextos": contextos})
            return self.vocabulario.criar(
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

    async def gerar_pratica(self, id_: str) -> dict[str, Any]:
        """Frases e exercícios da palavra pela LLM local (substitui os anteriores)."""
        item = self.vocabulario.obter(id_)
        self.vocabulario.editar(id_, {"gerando": True, "erro": ""})
        try:
            r = await self._json(prompt_practice(item, self._nivel(item["idioma"])))
        except (Unavailable, Invalid) as e:
            self.vocabulario.editar(id_, {"gerando": False, "erro": str(e)})
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
        return self.vocabulario.editar(
            id_, {"frases": sentences, "exercicios": exercises, "gerando": False, "erro": ""}
        )

    def revisar_vocabulario(self, id_: str, note: int) -> dict[str, Any]:
        item = self.vocabulario.obter(id_)
        return self.vocabulario.editar(id_, {"cartao": review(item.get("cartao", {}), note)})

    async def responder_exercicio(self, id_: str, indice: int, answer: str) -> dict[str, Any]:
        """Corrige a resposta (lacuna igual à referência dispensa a IA) e agenda a revisão."""
        item = self.vocabulario.obter(id_)
        exercises = item.get("exercicios", [])
        if not 0 <= indice < len(exercises):
            raise NotFound(f"exercício {indice}")
        answer = answer.strip()
        if not answer:
            raise Invalid("Resposta vazia.")
        ex = exercises[indice]
        answer_certa = normalize_word(ex.get("resposta", ""))
        if ex["tipo"] == "lacuna" and normalize_word(answer) == answer_certa:
            correction = {"correto": True, "nota": 100, "correcao": ex["resposta"], "explicacao": ""}
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
        atualizado = self.vocabulario.editar(
            id_, {"respostas": [*item.get("respostas", []), record][-50:], "cartao": cartao}
        )
        return {"correcao": record, "item": atualizado}

    # --- escrita ---

    def listar_escritas(self, language: str | None = None) -> list[dict[str, Any]]:
        return [e for e in self.escritas.ler() if language is None or e["idioma"] == language][::-1]

    async def criar_escrita(self, dados: dict[str, Any]) -> dict[str, Any]:
        """Tarefa de escrita sobre um artigo dos Arquivos (ou um texto colado), pela LLM local."""
        language = _language(str(dados.get("idioma") or ""))
        level = dados.get("nivel") if dados.get("nivel") in LEVELS else self._nivel(language)
        text = _text(dados.get("texto"), 20_000)
        file_id = dados.get("arquivo_id")
        if not text and file_id:
            text = self._texto_do_arquivo(str(file_id))[:20_000]
        words = [v["termo"] for v in self.listar_vocabulario(language, devidas=True)[:8]]
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
        return self.escritas.criar(
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

    async def responder_escrita(self, id_: str, indice: int, answer: str) -> dict[str, Any]:
        e = self.escritas.obter(id_)
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
        return self.escritas.editar(id_, {"respostas": answers})

    # --- leitura em voz alta ---

    def listar_leituras_voz(self, language: str | None = None) -> list[dict[str, Any]]:
        return [x for x in self.leituras_voz.ler() if language is None or x["idioma"] == language][::-1]

    async def avaliar_leitura(
        self, audio: bytes, mime: str, language: str, reference: str, fonte: dict[str, Any]
    ) -> dict[str, Any]:
        """Compara a gravação com o texto: palavras certas/trocadas/puladas, ritmo, pausas e,
        com o modelo fonético no worker, a pronúncia de cada palavra."""
        language = _language(language)
        reference = " ".join(reference.split())
        if not reference:
            raise Invalid("Sem o texto que foi lido.")
        r = await self._tarefa(
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
        return self.leituras_voz.criar(
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

    # --- atividades e progresso ---

    def registrar_atividade(self, dados: dict[str, Any]) -> dict[str, Any]:
        """Tempo de estudo feito fora da aba (leitura guiada nos Arquivos…); os minutos entram na
        trilha do idioma, se houver uma."""
        kind = str(dados.get("tipo") or "")
        if kind not in KINDS_ACTIVITY:
            raise Invalid(f"Tipo de atividade desconhecido: {kind}")
        language = _language(str(dados.get("idioma") or ""))
        minutes = int(dados.get("minutos") or 0)
        if not 0 <= minutes <= 600:
            raise Invalid("Minutos entre 0 e 600.")
        day = _now().astimezone().date().isoformat()
        activity = self.atividades.criar(
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
            self._somar_minutos(language, day, minutes)
        return activity

    def progresso(self, language: str) -> dict[str, Any]:
        language = _language(language)
        now = _iso(_now())
        vocab = self.listar_vocabulario(language)
        cartoes = [v.get("cartao", {}) for v in vocab]
        writes = [
            {"data": c["data"], "nota": c["nota"], "nivel_cefr": c.get("nivel_cefr", "")}
            for e in self.listar_escritas(language)
            for c in e.get("respostas", {}).values()
        ]
        readings = [
            {
                "data": x["criado"],
                "precisao": x["precisao"],
                "ppm": x["ppm"],
                "pronuncia": x.get("pronuncia"),
            }
            for x in self.listar_leituras_voz(language)
        ]
        minutes: dict[str, int] = {}
        for a in self.atividades.ler():
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
