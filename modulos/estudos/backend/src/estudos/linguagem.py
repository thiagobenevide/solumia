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

from estudos.estudos import Colecao, Invalido, NaoEncontrado
from estudos.idiomas import IDIOMAS, NIVEIS
from shared.speech_text import compare_reading, normalize_word

logger = logging.getLogger(__name__)

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]
TarefaWorker = Callable[[str, dict[str, Any]], Awaitable[dict[str, Any]]]

NOMES = {"en": "inglês", "es": "espanhol", "fr": "francês", "pt": "português"}
TIPOS_ATIVIDADE = {"leitura_guiada", "vocabulario", "escrita", "leitura_voz"}
LIMITE_CACHE_FALA = 2000
"""Falas guardadas (uma por frase); as mais antigas saem primeiro."""


class Indisponivel(Exception):
    """Sem worker ou sem LLM local agora."""


def _agora() -> datetime:
    return datetime.now(UTC)


def _iso(d: datetime) -> str:
    return d.isoformat(timespec="seconds")


def _idioma(idioma: str) -> str:
    if idioma not in IDIOMAS:
        raise Invalido(f"Idioma desconhecido: {idioma}")
    return idioma


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
NOTAS = {1: "errei", 2: "difícil", 3: "bom", 4: "fácil"}


def _d0(nota: int) -> float:
    return min(max(W[4] - (nota - 3) * W[5], 1.0), 10.0)


def retencao(dias: float, estabilidade: float) -> float:
    """Chance de lembrar depois de [dias] com a [estabilidade] do cartão."""
    return float((1 + _F * dias / estabilidade) ** _C)


def revisar(cartao: dict[str, Any], nota: int, agora: datetime | None = None) -> dict[str, Any]:
    """Novo estado do cartão (`estabilidade`, `dificuldade`, `revisoes`, `ultima`, `proxima`)
    depois de uma revisão com [nota] 1–4. Com retenção-alvo de 90 %, o intervalo
    é a estabilidade."""
    if nota not in NOTAS:
        raise Invalido("A nota vai de 1 (errei) a 4 (fácil).")
    agora = agora or _agora()
    s, d = cartao.get("estabilidade"), cartao.get("dificuldade")
    if not s or not d:
        s, d = W[nota - 1], _d0(nota)
    else:
        ultima = datetime.fromisoformat(cartao["ultima"])
        r = retencao(max((agora - ultima).total_seconds() / 86400, 0.0), s)
        if nota == 1:
            s = W[11] * d ** -W[12] * ((s + 1) ** W[13] - 1) * math.exp(W[14] * (1 - r))
        else:
            bonus = (W[15] if nota == 2 else 1.0) * (W[16] if nota == 4 else 1.0)
            s = s * (
                math.exp(W[8]) * (11 - d) * s ** -W[9] * (math.exp(W[10] * (1 - r)) - 1) * bonus + 1
            )
        d = W[7] * _d0(3) + (1 - W[7]) * (d - W[6] * (nota - 3))
        d = min(max(d, 1.0), 10.0)
    s = max(float(s), 0.01)
    intervalo = timedelta(minutes=10) if nota == 1 else timedelta(days=max(1, round(s)))
    return {
        "estabilidade": round(s, 4),
        "dificuldade": round(float(d), 4),
        "revisoes": int(cartao.get("revisoes", 0)) + 1,
        "lapsos": int(cartao.get("lapsos", 0)) + (1 if nota == 1 else 0),
        "ultima": _iso(agora),
        "proxima": _iso(agora + intervalo),
    }


def nota_de(pontos: float) -> int:
    """Pontuação 0–100 de um exercício → nota do FSRS."""
    return 1 if pontos < 50 else 2 if pontos < 70 else 3 if pontos < 90 else 4


# --- LLM local: pedidos em JSON ---


def extrair_json(resposta: str) -> Any:
    """Primeiro objeto JSON da resposta (ignora <think>, cercas e texto em volta)."""
    texto = re.sub(r"<think>.*?</think>", "", resposta, flags=re.DOTALL)
    inicio = texto.find("{")
    if inicio < 0:
        raise Invalido("A IA não devolveu JSON.")
    try:
        dados, _ = json.JSONDecoder().raw_decode(texto[inicio:])
    except json.JSONDecodeError as e:
        raise Invalido(f"A IA devolveu um JSON inválido: {e.msg}.") from e
    if not isinstance(dados, dict):
        raise Invalido("A IA não devolveu um objeto JSON.")
    return dados


SISTEMA = (
    "Você é professor de idiomas de um estudante brasileiro que lê artigos científicos. "
    "Responda SOMENTE com um objeto JSON válido, sem texto antes ou depois, no formato pedido. "
    "Explicações sempre em português do Brasil."
)


def prompt_traducao(termo: str, frase: str, idioma: str, destino: str) -> str:
    return (
        f'Trecho em {NOMES[idioma]} marcado durante a leitura: "{termo}"\n'
        f'Frase em que aparece: "{frase}"\n\n'
        f"Traduza o trecho para o {NOMES[destino]} no sentido que ele tem NESSA frase.\n"
        'Formato: {"traducao": "...", "classe": "substantivo|verbo|adjetivo|advérbio|expressão|'
        'outra", "ipa": "pronúncia em IPA do trecho no idioma original", '
        '"sentido": "explicação curta do sentido no contexto", '
        '"frase_traduzida": "a frase inteira traduzida"}'
    )


def prompt_pratica(item: dict[str, Any], nivel: str) -> str:
    contextos = "\n".join(
        f"- {c['frase']}" for c in item.get("contextos", [])[:3] if c.get("frase")
    )
    return (
        f'Palavra/expressão em {NOMES[item["idioma"]]}: "{item["termo"]}" '
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


def prompt_correcao(item: dict[str, Any], exercicio: dict[str, Any], resposta: str) -> str:
    return (
        f'Exercício de {NOMES[item["idioma"]]} sobre "{item["termo"]}" '
        f"({exercicio['tipo']}).\nEnunciado: {exercicio['enunciado']}\n"
        f"Resposta de referência: {exercicio.get('resposta') or '(livre)'}\n"
        f"Resposta do aluno: {resposta}\n\n"
        "Avalie se a resposta está correta e natural (aceite variações válidas, não exija a "
        "referência palavra por palavra) e se usa a palavra estudada corretamente.\n"
        'Formato: {"correto": true, "nota": 0-100, "correcao": "a resposta corrigida", '
        '"explicacao": "o que estava errado e por quê"}'
    )


def prompt_escrita(idioma: str, nivel: str, texto: str, palavras: list[str]) -> str:
    base = f'Texto lido pelo aluno (trecho):\n"""\n{texto[:6000]}\n"""\n\n' if texto else ""
    return (
        f"{base}Crie uma tarefa de escrita em {NOMES[idioma]} para um aluno de nível {nivel}. "
        f"{'Baseie as perguntas no texto acima. ' if texto else ''}"
        "Faça 3 perguntas, escritas no idioma estudado: uma de compreensão, uma de resumo e uma "
        "de opinião/aplicação. Cada uma pede de 3 a 6 frases."
        + (
            f" Sugira usar algumas destas palavras do caderno do aluno: {', '.join(palavras)}."
            if palavras
            else ""
        )
        + '\nFormato: {"titulo": "...", "perguntas": [{"pergunta": "...", '
        '"tipo": "compreensao|resumo|opiniao", "palavras_sugeridas": ["..."]}]}'
    )


def prompt_correcao_escrita(
    idioma: str, nivel: str, pergunta: dict[str, Any], resposta: str, texto: str
) -> str:
    base = f'Trecho do texto de referência:\n"""\n{texto[:3000]}\n"""\n\n' if texto else ""
    return (
        f"{base}Pergunta ({NOMES[idioma]}): {pergunta['pergunta']}\n"
        f'Resposta do aluno (nível declarado {nivel}):\n"""\n{resposta}\n"""\n\n'
        "Corrija como um professor: notas de 0 a 100 para gramática, vocabulário, coerência e "
        "adequação à pergunta; o nível CEFR que o texto demonstra; o texto corrigido mantendo a "
        "ideia do aluno; cada correção com a explicação em português; um comentário final com o "
        "que melhorar.\n"
        'Formato: {"nota": 0-100, "gramatica": 0-100, "vocabulario": 0-100, "coerencia": 0-100, '
        '"adequacao": 0-100, "nivel_cefr": "A1|A2|B1|B2|C1|C2", "texto_corrigido": "...", '
        '"correcoes": [{"trecho": "...", "correcao": "...", "explicacao": "..."}], '
        '"comentario": "..."}'
    )


def _pontos(valor: Any) -> int:
    try:
        return min(max(round(float(valor)), 0), 100)
    except (TypeError, ValueError):
        return 0


def _texto(valor: Any, limite: int = 4000) -> str:
    return str(valor or "").strip()[:limite]


class Linguagem:
    def __init__(
        self,
        raiz: str | Path,
        chat: ChatLLM | None = None,
        worker: TarefaWorker | None = None,
        texto_do_arquivo: Callable[[str], str] | None = None,
        somar_minutos: Callable[[str, str, int], None] | None = None,
    ) -> None:
        self.raiz = Path(raiz).expanduser() / "linguagem"
        (self.raiz / "cache" / "fala").mkdir(parents=True, exist_ok=True)
        (self.raiz / "cache" / "traducao").mkdir(parents=True, exist_ok=True)
        trava = threading.RLock()
        self.vocabulario = Colecao(self.raiz / "vocabulario.json", trava)
        self.escritas = Colecao(self.raiz / "escritas.json", trava)
        self.leituras_voz = Colecao(self.raiz / "leituras_voz.json", trava)
        self.atividades = Colecao(self.raiz / "atividades.json", trava)
        self._chat = chat
        self._worker = worker
        self._texto_do_arquivo = texto_do_arquivo or (lambda _id: "")
        self._somar_minutos = somar_minutos or (lambda _i, _d, _m: None)

    # --- acesso à LLM local e ao worker ---

    async def _json(self, prompt: str) -> dict[str, Any]:
        if self._chat is None:
            raise Indisponivel("LLM local não configurada neste servidor.")
        mensagens = [{"role": "system", "content": SISTEMA}, {"role": "user", "content": prompt}]
        try:
            resposta = await self._chat(mensagens)
            try:
                return extrair_json(resposta)
            except Invalido as e:  # segunda chance: o modelo local às vezes conversa antes
                mensagens += [
                    {"role": "assistant", "content": resposta[:3000]},
                    {"role": "user", "content": f"{e} Responda de novo SOMENTE com o JSON."},
                ]
                return extrair_json(await self._chat(mensagens))
        except RuntimeError as e:
            raise Indisponivel(str(e)) from e

    async def _tarefa(self, tarefa: str, payload: dict[str, Any]) -> dict[str, Any]:
        if self._worker is None:
            raise Indisponivel("Worker de voz não configurado neste servidor.")
        try:
            return await self._worker(tarefa, payload)
        except RuntimeError as e:
            raise Indisponivel(str(e)) from e

    # --- leitura guiada ---

    def _cache(self, tipo: str, chave: str) -> Path:
        return (
            self.raiz / "cache" / tipo / f"{hashlib.sha256(chave.encode()).hexdigest()[:32]}.json"
        )

    def _podar_falas(self) -> None:
        arquivos = sorted((self.raiz / "cache" / "fala").glob("*.json"), key=os.path.getmtime)
        for f in arquivos[: max(0, len(arquivos) - LIMITE_CACHE_FALA)]:
            f.unlink(missing_ok=True)

    async def fala(self, texto: str, idioma: str, velocidade: float = 1.0) -> dict[str, Any]:
        """Áudio da frase e o tempo de cada palavra (`inicio`/`fim` no texto, `t0`/`t1` em s)."""
        idioma = _idioma(idioma)
        texto = " ".join(texto.split())
        if not texto:
            raise Invalido("Texto vazio.")
        cache = self._cache("fala", f"{idioma}|{velocidade:.2f}|{texto}")
        if cache.exists():
            os.utime(cache)
            dados: dict[str, Any] = json.loads(cache.read_text("utf-8"))
            return dados
        r = await self._tarefa(
            "falar_marcado", {"texto": texto, "idioma": idioma, "velocidade": velocidade}
        )
        dados = {
            "texto": texto,
            "audio_b64": r["audio_b64"],
            "mime": r.get("mime", "audio/wav"),
            "duracao": r.get("duracao", 0),
            "palavras": r.get("palavras", []),
        }
        cache.write_text(json.dumps(dados), "utf-8")
        self._podar_falas()
        return dados

    async def traduzir(
        self, termo: str, frase: str, idioma: str, destino: str = "pt"
    ) -> dict[str, Any]:
        """Tradução do trecho no sentido da frase, com classe, IPA e a frase traduzida."""
        idioma, destino = _idioma(idioma), _idioma(destino)
        termo, frase = " ".join(termo.split()), " ".join(frase.split())
        if not termo:
            raise Invalido("Nada para traduzir.")
        cache = self._cache("traducao", f"{idioma}>{destino}|{termo}|{frase}")
        if cache.exists():
            dados: dict[str, Any] = json.loads(cache.read_text("utf-8"))
            return dados
        r = await self._json(prompt_traducao(termo, frase or termo, idioma, destino))
        dados = {
            "termo": termo,
            "traducao": _texto(r.get("traducao"), 500),
            "classe": _texto(r.get("classe"), 40),
            "ipa": _texto(r.get("ipa"), 200),
            "sentido": _texto(r.get("sentido"), 1000),
            "frase_traduzida": _texto(r.get("frase_traduzida"), 2000),
        }
        if not dados["traducao"]:
            raise Invalido("A IA não trouxe a tradução.")
        cache.write_text(json.dumps(dados, ensure_ascii=False), "utf-8")
        return dados

    # --- caderno de vocabulário ---

    def _nivel(self, idioma: str) -> str:
        return "B1" if idioma != "pt" else "C1"

    def listar_vocabulario(
        self, idioma: str | None = None, devidas: bool = False
    ) -> list[dict[str, Any]]:
        agora = _iso(_agora())
        itens = [
            v
            for v in self.vocabulario.ler()
            if (idioma is None or v["idioma"] == idioma)
            and (not devidas or v.get("cartao", {}).get("proxima", "") <= agora)
        ]
        chave = (lambda v: v.get("cartao", {}).get("proxima", "")) if devidas else None
        return sorted(itens, key=chave) if chave else itens[::-1]

    def criar_vocabulario(self, dados: dict[str, Any]) -> dict[str, Any]:
        """Palavra marcada na leitura. A mesma palavra de novo junta o contexto à que já existe."""
        idioma = _idioma(str(dados.get("idioma") or ""))
        termo = " ".join(str(dados.get("termo") or "").split())
        if not termo:
            raise Invalido("Palavra vazia.")
        contexto = {
            "frase": _texto(dados.get("contexto"), 2000),
            "arquivo_id": dados.get("arquivo_id"),
            "titulo": _texto(dados.get("titulo"), 300),
            "pagina": dados.get("pagina"),
        }
        with self.vocabulario.trava:
            for v in self.vocabulario.ler():
                if v["idioma"] == idioma and normalize_word(v["termo"]) == normalize_word(termo):
                    contextos = v.get("contextos", [])
                    if contexto["frase"] and all(
                        c["frase"] != contexto["frase"] for c in contextos
                    ):
                        contextos = [*contextos, contexto]
                    return self.vocabulario.editar(v["id"], {"contextos": contextos})
            return self.vocabulario.criar(
                {
                    "termo": termo,
                    "idioma": idioma,
                    "traducao": _texto(dados.get("traducao"), 500),
                    "classe": _texto(dados.get("classe"), 40),
                    "ipa": _texto(dados.get("ipa"), 200),
                    "contextos": [contexto] if contexto["frase"] else [],
                    "frases": [],
                    "exercicios": [],
                    "respostas": [],
                    "cartao": {"proxima": _iso(_agora()), "revisoes": 0},
                    "gerando": False,
                }
            )

    async def gerar_pratica(self, id_: str) -> dict[str, Any]:
        """Frases e exercícios da palavra pela LLM local (substitui os anteriores)."""
        item = self.vocabulario.obter(id_)
        self.vocabulario.editar(id_, {"gerando": True, "erro": ""})
        try:
            r = await self._json(prompt_pratica(item, self._nivel(item["idioma"])))
        except (Indisponivel, Invalido) as e:
            self.vocabulario.editar(id_, {"gerando": False, "erro": str(e)})
            raise
        frases = [
            {
                "texto": _texto(f.get("texto"), 600),
                "traducao": _texto(f.get("traducao"), 600),
                "nivel": f.get("nivel") if f.get("nivel") in NIVEIS else "",
            }
            for f in r.get("frases") or []
            if isinstance(f, dict) and f.get("texto")
        ]
        exercicios = [
            {
                "tipo": e["tipo"],
                "enunciado": _texto(e.get("enunciado"), 600),
                "resposta": _texto(e.get("resposta"), 600),
            }
            for e in r.get("exercicios") or []
            if isinstance(e, dict)
            and e.get("tipo") in ("lacuna", "traducao", "producao")
            and e.get("enunciado")
        ]
        return self.vocabulario.editar(
            id_, {"frases": frases, "exercicios": exercicios, "gerando": False, "erro": ""}
        )

    def revisar_vocabulario(self, id_: str, nota: int) -> dict[str, Any]:
        item = self.vocabulario.obter(id_)
        return self.vocabulario.editar(id_, {"cartao": revisar(item.get("cartao", {}), nota)})

    async def responder_exercicio(self, id_: str, indice: int, resposta: str) -> dict[str, Any]:
        """Corrige a resposta (lacuna igual à referência dispensa a IA) e agenda a revisão."""
        item = self.vocabulario.obter(id_)
        exercicios = item.get("exercicios", [])
        if not 0 <= indice < len(exercicios):
            raise NaoEncontrado(f"exercício {indice}")
        resposta = resposta.strip()
        if not resposta:
            raise Invalido("Resposta vazia.")
        ex = exercicios[indice]
        resposta_certa = normalize_word(ex.get("resposta", ""))
        if ex["tipo"] == "lacuna" and normalize_word(resposta) == resposta_certa:
            correcao = {"correto": True, "nota": 100, "correcao": ex["resposta"], "explicacao": ""}
        else:
            r = await self._json(prompt_correcao(item, ex, resposta))
            correcao = {
                "correto": bool(r.get("correto")),
                "nota": _pontos(r.get("nota")),
                "correcao": _texto(r.get("correcao"), 1000),
                "explicacao": _texto(r.get("explicacao"), 2000),
            }
        registro = {"exercicio": indice, "resposta": resposta, **correcao, "data": _iso(_agora())}
        cartao = revisar(item.get("cartao", {}), nota_de(correcao["nota"]))
        atualizado = self.vocabulario.editar(
            id_, {"respostas": [*item.get("respostas", []), registro][-50:], "cartao": cartao}
        )
        return {"correcao": registro, "item": atualizado}

    # --- escrita ---

    def listar_escritas(self, idioma: str | None = None) -> list[dict[str, Any]]:
        return [e for e in self.escritas.ler() if idioma is None or e["idioma"] == idioma][::-1]

    async def criar_escrita(self, dados: dict[str, Any]) -> dict[str, Any]:
        """Tarefa de escrita sobre um artigo dos Arquivos (ou um texto colado), pela LLM local."""
        idioma = _idioma(str(dados.get("idioma") or ""))
        nivel = dados.get("nivel") if dados.get("nivel") in NIVEIS else self._nivel(idioma)
        texto = _texto(dados.get("texto"), 20_000)
        arquivo_id = dados.get("arquivo_id")
        if not texto and arquivo_id:
            texto = self._texto_do_arquivo(str(arquivo_id))[:20_000]
        palavras = [v["termo"] for v in self.listar_vocabulario(idioma, devidas=True)[:8]]
        r = await self._json(prompt_escrita(idioma, str(nivel), texto, palavras))
        perguntas = [
            {
                "pergunta": _texto(p.get("pergunta"), 1000),
                "tipo": _texto(p.get("tipo"), 30),
                "palavras_sugeridas": [str(x)[:80] for x in p.get("palavras_sugeridas") or []][:8],
            }
            for p in r.get("perguntas") or []
            if isinstance(p, dict) and p.get("pergunta")
        ]
        if not perguntas:
            raise Invalido("A IA não criou as perguntas; tente de novo.")
        return self.escritas.criar(
            {
                "idioma": idioma,
                "nivel": nivel,
                "titulo": _texto(r.get("titulo"), 200) or "Escrita",
                "arquivo_id": arquivo_id,
                "titulo_arquivo": _texto(dados.get("titulo_arquivo"), 300),
                "texto_base": texto[:6000],
                "perguntas": perguntas,
                "respostas": {},
            }
        )

    async def responder_escrita(self, id_: str, indice: int, resposta: str) -> dict[str, Any]:
        e = self.escritas.obter(id_)
        if not 0 <= indice < len(e["perguntas"]):
            raise NaoEncontrado(f"pergunta {indice}")
        if len(resposta.split()) < 3:
            raise Invalido("Escreva pelo menos uma frase.")
        r = await self._json(
            prompt_correcao_escrita(
                e["idioma"], e["nivel"], e["perguntas"][indice], resposta, e.get("texto_base", "")
            )
        )
        correcao = {
            "resposta": resposta,
            "nota": _pontos(r.get("nota")),
            **{
                k: _pontos(r.get(k)) for k in ("gramatica", "vocabulario", "coerencia", "adequacao")
            },
            "nivel_cefr": r.get("nivel_cefr") if r.get("nivel_cefr") in NIVEIS else "",
            "texto_corrigido": _texto(r.get("texto_corrigido"), 10_000),
            "correcoes": [
                {k: _texto(c.get(k), 1000) for k in ("trecho", "correcao", "explicacao")}
                for c in r.get("correcoes") or []
                if isinstance(c, dict)
            ][:30],
            "comentario": _texto(r.get("comentario"), 3000),
            "data": _iso(_agora()),
        }
        respostas = {**e.get("respostas", {}), str(indice): correcao}
        return self.escritas.editar(id_, {"respostas": respostas})

    # --- leitura em voz alta ---

    def listar_leituras_voz(self, idioma: str | None = None) -> list[dict[str, Any]]:
        return [x for x in self.leituras_voz.ler() if idioma is None or x["idioma"] == idioma][::-1]

    async def avaliar_leitura(
        self, audio: bytes, mime: str, idioma: str, referencia: str, fonte: dict[str, Any]
    ) -> dict[str, Any]:
        """Compara a gravação com o texto: palavras certas/trocadas/puladas, ritmo, pausas e,
        com o modelo fonético no worker, a pronúncia de cada palavra."""
        idioma = _idioma(idioma)
        referencia = " ".join(referencia.split())
        if not referencia:
            raise Invalido("Sem o texto que foi lido.")
        r = await self._tarefa(
            "avaliar_leitura",
            {
                "audio_b64": base64.b64encode(audio).decode(),
                "mime": mime,
                "idioma": idioma,
                "referencia": referencia,
            },
        )
        resultado = compare_reading(referencia, r.get("palavras") or [])
        pronuncia = r.get("pronuncia")
        if isinstance(pronuncia, list):
            for p in pronuncia:
                k = p.get("indice")
                if isinstance(k, int) and 0 <= k < len(resultado["palavras"]):
                    resultado["palavras"][k]["fonemas"] = {
                        "esperado": p.get("esperado", ""),
                        "ouvido": p.get("ouvido", ""),
                        "acerto": p.get("acerto", 0),
                    }
            ditas = [
                p["fonemas"]["acerto"]
                for p in resultado["palavras"]
                if "fonemas" in p and p["estado"] != "omitida"
            ]
            resultado["pronuncia"] = round(100 * sum(ditas) / len(ditas), 1) if ditas else None
        else:
            resultado["pronuncia"] = None
        return self.leituras_voz.criar(
            {
                "idioma": idioma,
                "referencia": referencia,
                "arquivo_id": fonte.get("arquivo_id"),
                "titulo": _texto(fonte.get("titulo"), 300),
                "pagina": fonte.get("pagina"),
                "aviso": _texto(r.get("aviso"), 300),
                **resultado,
            }
        )

    # --- atividades e progresso ---

    def registrar_atividade(self, dados: dict[str, Any]) -> dict[str, Any]:
        """Tempo de estudo feito fora da aba (leitura guiada nos Arquivos…); os minutos entram na
        trilha do idioma, se houver uma."""
        tipo = str(dados.get("tipo") or "")
        if tipo not in TIPOS_ATIVIDADE:
            raise Invalido(f"Tipo de atividade desconhecido: {tipo}")
        idioma = _idioma(str(dados.get("idioma") or ""))
        minutos = int(dados.get("minutos") or 0)
        if not 0 <= minutos <= 600:
            raise Invalido("Minutos entre 0 e 600.")
        dia = _agora().astimezone().date().isoformat()
        atividade = self.atividades.criar(
            {
                "tipo": tipo,
                "idioma": idioma,
                "minutos": minutos,
                "dia": dia,
                "detalhes": {
                    k: v
                    for k, v in (dados.get("detalhes") or {}).items()
                    if isinstance(v, int | float | str)
                },
            }
        )
        if minutos:
            self._somar_minutos(idioma, dia, minutos)
        return atividade

    def progresso(self, idioma: str) -> dict[str, Any]:
        idioma = _idioma(idioma)
        agora = _iso(_agora())
        vocab = self.listar_vocabulario(idioma)
        cartoes = [v.get("cartao", {}) for v in vocab]
        escritas = [
            {"data": c["data"], "nota": c["nota"], "nivel_cefr": c.get("nivel_cefr", "")}
            for e in self.listar_escritas(idioma)
            for c in e.get("respostas", {}).values()
        ]
        leituras = [
            {
                "data": x["criado"],
                "precisao": x["precisao"],
                "ppm": x["ppm"],
                "pronuncia": x.get("pronuncia"),
            }
            for x in self.listar_leituras_voz(idioma)
        ]
        minutos: dict[str, int] = {}
        for a in self.atividades.ler():
            if a["idioma"] == idioma:
                minutos[a["tipo"]] = minutos.get(a["tipo"], 0) + int(a["minutos"])
        return {
            "idioma": idioma,
            "vocabulario": {
                "total": len(vocab),
                "devidas": sum(1 for c in cartoes if c.get("proxima", "") <= agora),
                "aprendendo": sum(1 for c in cartoes if 0 < (c.get("estabilidade") or 0) < 21),
                "dominadas": sum(1 for c in cartoes if (c.get("estabilidade") or 0) >= 21),
            },
            "escrita": sorted(escritas, key=lambda x: x["data"]),
            "leitura_voz": sorted(leituras, key=lambda x: x["data"]),
            "minutos": minutos,
        }
