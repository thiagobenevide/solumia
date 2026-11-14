"""Rotas do Painel/Cobrador. A plataforma monta o router em `/api/painel` e guarda em `app.state`:
`cobrador` ([Cobrador]), `painel_fontes` ([Fontes]: tarefas e notas de outros módulos),
`painel_llms` (provedor → função de chat; `local` = worker no PC, `claude` = API da Anthropic),
`painel_voz` ([Voz], pelo worker), `painel_pc` ([PC], comandos no PC pelo worker), `medidor`
([Medidor]) e `painel_workers` (workers conectados)."""

import asyncio
import json
import logging
import re
import unicodedata
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Form, HTTPException, Request, Response, UploadFile
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from painel import agent, performance
from painel.nagger import Nagger, Invalid, NotFound
from painel.meter import Meter

router = APIRouter(tags=["painel"])
log = logging.getLogger(__name__)

# `content` é texto ou, com imagem, partes no formato OpenAI (text + image_url com data URL).
ChatLLM = Callable[[list[dict[str, Any]]], Awaitable[str]]
# Aviso de andamento ("consultando a internet…") para quem acompanha pelas rotas `/fluxo`.
Notice = Callable[..., Awaitable[None]]


async def _without_warning(_: str, event: str = "aviso") -> None:
    return None

SYSTEM = (
    "Você é o Cobrador: o assistente de disciplina do usuário. Responda em português, curto e "
    "direto, como um parceiro exigente porém justo. Use o retrato do dia abaixo (agenda, metas, "
    "alertas e tarefas) para dizer o que fazer agora, cobrar o que está atrasado e defender as "
    "entregas prioritárias. Se o usuário quiser mudar a agenda, avalie o impacto nos prazos "
    "antes de concordar. Não invente tarefas nem metas que não estão no retrato.\n\n"
)


class LLMUnavailable(Exception):
    pass


@dataclass
class Sources:
    tarefas: Callable[[], list[dict[str, Any]]]
    buscar_notas: Callable[[str], list[dict[str, Any]]]
    ler_nota: Callable[[str], dict[str, Any]]
    criar_nota: Callable[[dict[str, Any]], dict[str, Any]]
    criar_tarefa: Callable[[dict[str, Any]], dict[str, Any]]
    mover_tarefa: Callable[[str, str], dict[str, Any]]
    # Ações em outros módulos (caderno, fluxograma, leitura…): tipo → (exemplo JSON para o prompt,
    # função que recebe a ação e o LLM da conversa e devolve o resumo). A plataforma registra.
    modulos: dict[str, tuple[str, Callable[[dict[str, Any], "ChatLLM"], Awaitable[str]]]] = field(
        default_factory=dict
    )


@dataclass
class Voice:
    """Fala e escuta pelo worker: `transcrever(audio, mime, idioma) → texto` (idioma `pt`, `en` ou
    vazio = detecta entre os dois) e `falar(texto, trecho=None) → wav` (com trecho, só aquele
    pedaço da fala; vazio depois do último)."""

    transcrever: Callable[[bytes, str, str], Awaitable[str]]
    falar: Callable[..., Awaitable[bytes]]


def get_nagger(request: Request) -> Nagger:
    nagger: Nagger = request.app.state.cobrador
    return nagger


def get_sources(request: Request) -> Sources:
    sources: Sources = request.app.state.painel_fontes
    return sources


def get_llms(request: Request) -> dict[str, ChatLLM]:
    llms: dict[str, ChatLLM] = request.app.state.painel_llms
    return llms


def get_voice(request: Request) -> Voice:
    voice: Voice = request.app.state.painel_voz
    return voice


def get_meter(request: Request) -> Meter:
    meter: Meter = request.app.state.medidor
    return meter


# Comando no PC pelo worker: `{"acao": ..., ...}` → `{"ok", "detalhe"}` (ver worker/pc.py).
PC = Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]


def get_pc(request: Request) -> PC | None:
    return getattr(request.app.state, "painel_pc", None)


PCDep = Annotated[PC | None, Depends(get_pc)]
NaggerDep = Annotated[Nagger, Depends(get_nagger)]
VoiceDep = Annotated[Voice, Depends(get_voice)]
MeterDep = Annotated[Meter, Depends(get_meter)]
SourcesDep = Annotated[Sources, Depends(get_sources)]
LLMsDep = Annotated[dict[str, ChatLLM], Depends(get_llms)]


def get_internet(request: Request) -> Any:
    """Ferramentas de dados em tempo real da plataforma (`backend.internet.Internet`), se houver."""
    return getattr(request.app.state, "internet", None)


InternetDep = Annotated[Any, Depends(get_internet)]


class MetaInput(BaseModel):
    titulo: str = Field(min_length=1, max_length=200)
    frequencia: str = "diaria"
    alvo: float = 1
    unidade: str = Field("vez", max_length=40)


class ActionInput(BaseModel):
    quantidade: float = Field(1, gt=0)
    nota: str = Field("", max_length=2000)


class Block(BaseModel):
    id: str | None = None
    titulo: str = Field(min_length=1, max_length=200)
    inicio: str = Field(pattern=r"^\d{2}:\d{2}$")
    fim: str = Field(pattern=r"^\d{2}:\d{2}$")
    prioridade: str = Field("media", pattern="^(baixa|media|alta)$")
    tarefa_id: str | None = None
    prazo: str | None = None
    feito: bool = False


class AgendaInput(BaseModel):
    blocos: list[Block] = Field(max_length=60)
    motivo: str = Field("", max_length=2000)


class Message(BaseModel):
    papel: str = Field(pattern="^(usuario|assistente)$")
    texto: str = Field(max_length=8000)


class Speech(BaseModel):
    texto: str = Field(min_length=1, max_length=4000)
    trecho: int | None = Field(default=None, ge=0)
    """Só o n-ésimo pedaço da fala: o app toca um enquanto o próximo é sintetizado."""


class Conversation(BaseModel):
    mensagem: str = Field(min_length=1, max_length=8000)
    historico: list[Message] = Field([], max_length=20)
    provedor: str = "local"
    # foto anexada à mensagem (base64, sem o prefixo data:); só vale para esta mensagem
    imagem: str | None = None
    imagem_mime: Literal["image/jpeg", "image/png", "image/webp", "image/gif"] = "image/jpeg"
    # mensagem por voz: a resposta vai ser ouvida, então sai curta (cada frase a mais é ~1 s de
    # geração e outro tanto de síntese)
    falada: bool = False


def _error(e: Exception) -> HTTPException:
    if isinstance(e, NotFound):
        return HTTPException(404, "Não encontrado")
    return HTTPException(422, str(e))


# --- metas ---


@router.get("/metas")
def goals(cobrador: NaggerDep) -> Any:
    return cobrador.metas()


@router.post("/metas", status_code=201)
def create_meta(m: MetaInput, cobrador: NaggerDep) -> Any:
    try:
        return cobrador.criar_meta(m.model_dump())
    except Invalid as e:
        raise _error(e) from e


@router.delete("/metas/{id_}", status_code=204)
def delete_meta(id_: str, cobrador: NaggerDep) -> None:
    try:
        cobrador.excluir_meta(id_)
    except NotFound as e:
        raise _error(e) from e


@router.post("/metas/{id_}/acoes", status_code=201)
def register_action(id_: str, a: ActionInput, cobrador: NaggerDep) -> Any:
    try:
        return cobrador.registrar_acao(id_, a.quantidade, a.nota)
    except NotFound as e:
        raise _error(e) from e


# --- agenda ---


@router.get("/agenda/{dia}")
def agenda(dia: str, cobrador: NaggerDep) -> Any:
    try:
        return cobrador.agenda(dia)
    except ValueError as e:
        raise _error(e) from e


@router.post("/agenda/{dia}/sugerir")
def suggest(dia: str, cobrador: NaggerDep, fontes: SourcesDep) -> Any:
    try:
        return cobrador.sugerir(dia, fontes.tarefas())
    except ValueError as e:
        raise _error(e) from e


@router.put("/agenda/{dia}")
def save_agenda(dia: str, ag: AgendaInput, cobrador: NaggerDep) -> Any:
    blocks = [b.model_dump(exclude_none=True) for b in ag.blocos]
    try:
        return cobrador.salvar(dia, blocks, ag.motivo)
    except (Invalid, ValueError) as e:
        raise _error(e) from e


@router.post("/agenda/{dia}/blocos/{bloco_id}/feito")
def mark(dia: str, bloco_id: str, cobrador: NaggerDep, feito: bool = True) -> Any:
    try:
        return cobrador.marcar(dia, bloco_id, feito)
    except NotFound as e:
        raise _error(e) from e


# --- cobrança ---


@router.get("/disciplina")
def subject(cobrador: NaggerDep, fontes: SourcesDep) -> Any:
    return cobrador.disciplina(fontes.tarefas())


@router.get("/desempenho")
def show_performance(cobrador: NaggerDep, fontes: SourcesDep, dias: int = 30) -> Any:
    return performance.analyze(fontes.tarefas(), cobrador, dias)


@router.get("/provedores")
def providers(llms: LLMsDep) -> Any:
    return sorted(llms)


# --- conversa ---

_ANNOTATE = re.compile(
    r"^\s*(?:anot[ae]|nota:|escrev[ae] (?:uma|essa|esta|a) nota|cri[ae] (?:uma|a) nota)"
    r"(?:\s+(?:que|sobre|isso|isto))?\s*[:,\-]?\s*",
    re.I,
)
# "busque na internet …", "pesquise na web …": vai às ferramentas de tempo real (antes do
# "pesquise" da base, que casaria primeiro).
_INTERNET = re.compile(
    r"^\s*(?:pesquis[ae]|busc?que|busca|procur[ae]|consult[ae]|veja)\s+(?:na|no|em)\s+"
    r"(?:internet|web|google)\b(?:\s+(?:sobre|por|o que|pelo|pela|qual|quanto))?\s*[:,\-]?\s*",
    re.I,
)
# Assuntos que pedem dado atual mesmo sem dizer "internet": cotação, FIPE, juros, notícias.
_TIME_REAL = re.compile(
    r"\b(?:cota[cç][aã]o|d[oó]lar|euro|bitcoin|fipe|selic|cdi|ipca|infla[cç][aã]o|ibovespa|"
    r"pre[cç]o (?:atual|de hoje|hoje)|not[ií]cias?|quanto (?:est[aá]|custa) (?:o|a|hoje))\b",
    re.I,
)

# Pedido para o computador ("abre o Brave e pesquisa…", "desliga o PC"): vai direto ao agente,
# sem os atalhos de pesquisa na web/notas acima.
_COMMAND_PC = re.compile(
    r"^\s*(?:abr[ae]|abrir|desligu?[ae]|desligar|cancel[ae] o desligamento)\b|"
    r"\b(?:brave|firefox|navegador|youtube|computador|pc)\b",
    re.I,
)

_SEARCH = re.compile(
    r"^\s*(?:pesquis[ae]|busc?que|busca|procur[ae])"
    r"(?:\s+(?:na|em|nas)\s+(?:nossa\s+)?(?:base(?: de conhecimento)?|notas|cofre))?"
    r"(?:\s+(?:sobre|por|o que|pelo|pela))?\s*[:,\-]?\s*",
    re.I,
)


def _without_accent(text: str) -> str:
    return "".join(
        c for c in unicodedata.normalize("NFD", text.lower()) if unicodedata.category(c) != "Mn"
    )


def _fetch(sources: Sources, query: str, limite: int = 5) -> list[dict[str, Any]]:
    """Notas que contêm mais palavras da consulta (palavras de 4+ letras)."""
    words = [p for p in re.findall(r"\w+", _without_accent(query)) if len(p) >= 4] or [query]
    points: dict[str, int] = {}
    found: dict[str, dict[str, Any]] = {}
    for p in words:
        for n in sources.buscar_notas(p):
            points[n["id"]] = points.get(n["id"], 0) + 1
            found[n["id"]] = n
    order = sorted(points, key=lambda i: -points[i])[:limite]
    return [found[i] for i in order]


async def _answer(llm: ChatLLM, system: str, c: Conversation, pergunta: str) -> str:
    roles = {"usuario": "user", "assistente": "assistant"}
    messages: list[dict[str, Any]] = [{"role": "system", "content": system}]
    messages += [{"role": roles[m.papel], "content": m.texto} for m in c.historico]
    content: Any = pergunta
    if c.imagem:
        url = f"data:{c.imagem_mime};base64,{c.imagem}"
        content = [
            {"type": "text", "text": pergunta},
            {"type": "image_url", "image_url": {"url": url}},
        ]
    messages.append({"role": "user", "content": content})
    return await llm(messages)


_SPOKEN = (
    "[Mensagem por voz: sua resposta será ouvida, não lida. Responda em até 3 frases curtas e "
    "naturais, sem markdown, tabelas ou listas longas; se houver passos, diga primeiro, segundo.]"
    "\n\n"
)

_MAX_IMAGE = 8_000_000  # caracteres de base64 (~6 MB de imagem)


async def _chat(
    c: Conversation,
    nagger: Nagger,
    sources: Sources,
    llms: dict[str, ChatLLM],
    internet: Any = None,
    pc: PC | None = None,
    aviso: Notice = _without_warning,
) -> Any:
    """Chat do cobrador. Entende dois comandos antes de ir ao LLM: “anote …” cria uma nota no
    cofre e “pesquise …” busca na base de notas e responde com elas como contexto. No resto, o
    LLM responde e pode pedir ações (ver [agente]); elas voltam em `executadas`."""
    if c.provedor not in llms:
        raise HTTPException(422, f"Provedor indisponível: {c.provedor}")
    # o app já manda ≤ 1 MB; acima disso a mensagem ao worker (teto 16 MB) poderia estourar
    if c.imagem and len(c.imagem) > _MAX_IMAGE:
        raise HTTPException(413, "Imagem grande demais; envie uma foto menor (até ~6 MB).")
    llm = llms[c.provedor]

    if m := _ANNOTATE.match(c.mensagem):
        body = c.mensagem[m.end() :].strip()
        if not body:
            raise HTTPException(422, "Diga o que anotar depois de “anote”.")
        primeira = re.split(r"[.\n!?]", body, maxsplit=1)[0].strip()
        title = f"{nagger.agora():%Y-%m-%d %H%M} {primeira[:60]}".strip()
        note = sources.criar_nota({"titulo": title, "corpo": body, "tags": ["cobrador"]})
        return {"resposta": f"Anotado em “{note['titulo']}”.", "acao": "nota", "nota": note}

    node_pc = pc is not None and bool(_COMMAND_PC.search(c.mensagem))
    m = _INTERNET.match(c.mensagem)
    if not node_pc and internet is not None and (
        m or (_TIME_REAL.search(c.mensagem) and not _ANNOTATE.match(c.mensagem))
    ):
        request = c.mensagem[m.end() :].strip() if m else c.mensagem
        await aviso("Certo, vou consultar na internet. Um instante.")
        try:
            r = await internet.pesquisar(
                llm, request or c.mensagem, contexto=_SPOKEN if c.falada else "", aviso=aviso
            )
        except LLMUnavailable as e:
            raise HTTPException(503, str(e)) from e
        return {
            "resposta": r["resposta"],
            "acao": "internet",
            "fontes": r["fontes"],
            "links": r["links"],
        }

    if not node_pc and (m := _SEARCH.match(c.mensagem)):
        query = c.mensagem[m.end() :].strip() or c.mensagem
        notes = _fetch(sources, query)
        if not notes:
            return {
                "resposta": f"Nada na base sobre “{query}”.",
                "acao": "pesquisa",
                "notas": [],
            }
        spans = []
        for n in notes[:3]:
            body = str(sources.ler_nota(n["id"]).get("corpo", ""))[:3000]
            spans.append(f"### {n['titulo']}\n{body}")
        system = (
            "Responda em português, curto, usando só as notas abaixo da base de conhecimento do "
            "usuário; cite o título da nota de onde veio cada informação.\n\n"
            + "\n\n".join(spans)
        )
        try:
            answer = await _answer(llm, system, c, f"Pergunta: {query}")
        except LLMUnavailable:
            answer = "Sem LLM agora; notas encontradas:\n" + "\n".join(
                f"- {n['titulo']}" for n in notes
            )
        return {"resposta": answer, "acao": "pesquisa", "notas": notes}

    # Ordem pensada para o cache do llama-server: o que quase não muda (instruções, agenda,
    # tarefas) vai no sistema e o que muda a cada minuto (hora, alertas) só na última mensagem;
    # assim cada mensagem processa só o texto novo em vez do prompt inteiro.
    tasks = sources.tarefas()
    system = SYSTEM + agent.INSTRUCTIONS + agent.instructions_modules(sources.modulos)
    if pc is not None:
        system += agent.COMPUTER
    system += "\n# Retrato do dia\n" + nagger.retrato(tasks)
    analysis = None
    if _PERFORMANCE.search(c.mensagem):
        analysis = performance.analyze(tasks, nagger)
        system += "\n" + performance.text(analysis) + "\n" + agent.ANALYSIS
    now = f"[{nagger.momento(tasks)}]\n\n"
    if c.falada:  # na última mensagem, não no sistema: não invalida o cache do prompt
        now += _SPOKEN

    async def agir(actions: list[dict[str, Any]]) -> list[dict[str, Any]]:
        node_pc, actions = agent.separate_pc(actions)
        nodes_modules, actions = agent.separate_modules(actions, sources.modulos)
        done = agent.execute(actions, nagger, sources, motivo=c.mensagem[:300])
        done += await agent.execute_modules(nodes_modules, sources.modulos, llm)
        return done + await agent.execute_pc(node_pc, pc)

    try:
        raw = await _answer(llm, system, c, now + c.mensagem)
        answer, actions = agent.extract(raw)
        queries, actions = agent.separate(actions)
        executadas = await agir(actions)
        links: list[dict[str, Any]] = []
        if queries:
            # uma rodada de consultas: o LLM recebe os resultados e responde de novo
            results = []
            for a in queries[:3]:
                await aviso(_ONGOING.get(str(a.get("tipo")), "Consultando…"))
                text, feita, found = await _query(a, llm, nagger, sources, internet)
                results.append(text)
                executadas.append(feita)
                links += found
            question = (
                f"{now}{c.mensagem}\n\n[Resultados das consultas que você pediu]\n"
                + "\n\n".join(results)
                + "\n\nResponda agora com esses resultados; não peça as mesmas consultas."
            )
            answer, actions = agent.extract(await _answer(llm, system, c, question))
            _, actions = agent.separate(actions)
            executadas += await agir(actions)
    except LLMUnavailable as e:
        if c.imagem and c.provedor == "local":
            raise HTTPException(
                503,
                f"{e}. Para ler imagens o modelo local precisa de visão (gemma-4, qwen2.5vl ou "
                "qwen3.8, escolha na aba LLMs) ou use o Claude.",
            ) from e
        raise HTTPException(503, str(e)) from e
    r: dict[str, Any] = {
        "resposta": answer,
        "acao": "agente" if executadas else ("desempenho" if analysis else None),
        "executadas": executadas,
    }
    if links:
        r["links"] = links
    if analysis:
        r["desempenho"] = analysis
    return r


_ONGOING = {
    "pesquisar_web": "Deixa eu pesquisar na internet.",
    "pesquisar_notas": "Vou procurar nas suas notas.",
    "analisar_desempenho": "Vou analisar o seu desempenho.",
}

# "como está meu desempenho", "analise minha produtividade": a análise entra no prompt.
_PERFORMANCE = re.compile(r"\b(?:desempenho|produtividade|rendimento)\b", re.I)


async def _query(
    a: dict[str, Any], llm: ChatLLM, nagger: Nagger, sources: Sources, internet: Any
) -> tuple[str, dict[str, Any], list[dict[str, Any]]]:
    """Executa uma consulta do agente: (texto para o LLM, item de `executadas`, links)."""
    kind = str(a.get("tipo"))
    query = str(a.get("consulta", "")).strip()
    if kind == "analisar_desempenho":
        days = int(a.get("dias") or 30)
        text = performance.text(performance.analyze(sources.tarefas(), nagger, days))
        return text, {"tipo": kind, "ok": True, "detalhe": f"Analisei {days} dias"}, []
    if not query:
        return "", {"tipo": kind, "ok": False, "detalhe": "Consulta vazia."}, []
    if kind == "pesquisar_notas":
        notes = _fetch(sources, query)
        spans = [
            f"### {n['titulo']}\n{str(sources.ler_nota(n['id']).get('corpo', ''))[:1500]}"
            for n in notes[:3]
        ]
        text = f"## Notas sobre “{query}”\n" + ("\n\n".join(spans) or "nenhuma")
        detail = f"Busquei nas notas: {query} ({len(notes)})"
        return text, {"tipo": kind, "ok": True, "detalhe": detail}, []
    if internet is None:
        return "", {"tipo": kind, "ok": False, "detalhe": "Internet indisponível."}, []
    try:
        r = await internet.pesquisar(llm, query)
    except LLMUnavailable:
        raise
    except Exception as e:  # ferramenta externa fora do ar não derruba a conversa
        return "", {"tipo": kind, "ok": False, "detalhe": f"Falha na web: {e}"}, []
    text = f"## Web: “{query}”\n{r['resposta']}"
    return text, {"tipo": kind, "ok": True, "detalhe": f"Pesquisei na web: {query}"}, r["links"]


@router.post("/conversar")
async def chat(
    c: Conversation,
    cobrador: NaggerDep,
    fontes: SourcesDep,
    llms: LLMsDep,
    internet: InternetDep,
    pc: PCDep,
) -> Any:
    return await _chat(c, cobrador, fontes, llms, internet, pc)


class CommandPC(BaseModel):
    acao: Literal["ligar", "desligar", "cancelar_desligar"]
    minutos: int = Field(0, ge=0, le=600)


@router.post("/pc")
async def command_pc(cmd: CommandPC, pc: PCDep) -> Any:
    """Botão do app: desligar o PC (ou cancelar um desligamento agendado)."""
    if pc is None:
        raise HTTPException(503, "Comandos no PC indisponíveis.")
    try:
        return await pc(cmd.model_dump())
    except Exception as e:
        raise HTTPException(503, f"No PC: {e}") from e


# --- voz ---


async def _transcribe(voice: Voice, audio: bytes, tipo: str, language: str) -> str:
    try:
        text = await voice.transcrever(audio, tipo, language)
    except LLMUnavailable as e:
        raise HTTPException(503, str(e)) from e
    if not text.strip():
        raise HTTPException(422, "Não entendi o áudio; tente de novo mais perto do microfone.")
    return text


@router.post("/transcrever")
async def transcribe(
    audio: UploadFile, voz: VoiceDep, idioma: Annotated[str, Form()] = ""
) -> dict[str, str]:
    """Só a transcrição, para o microfone dos outros chats (rotinas, código…): o app põe o texto
    no próprio chat."""
    return {"texto": await _transcribe(voz, await audio.read(), audio.content_type or "", idioma)}


@router.post("/voz")
async def voice(
    audio: UploadFile,
    cobrador: NaggerDep,
    fontes: SourcesDep,
    llms: LLMsDep,
    voz: VoiceDep,
    internet: InternetDep,
    pc: PCDep,
    provedor: Annotated[str, Form()] = "local",
    historico: Annotated[str, Form()] = "[]",
    idioma: Annotated[str, Form()] = "",
) -> Any:
    """Mensagem falada: o worker transcreve e a transcrição segue como mensagem de texto."""
    text = await _transcribe(voz, await audio.read(), audio.content_type or "", idioma)
    c = Conversation(
        mensagem=text[:8000], historico=_history(historico), provedor=provedor, falada=True
    )
    return {"transcricao": text} | await _chat(c, cobrador, fontes, llms, internet, pc)


def _history(historico: str) -> list[Message]:
    try:
        return [Message(**m) for m in json.loads(historico)][-20:]
    except (ValueError, TypeError) as e:
        raise HTTPException(422, "Histórico inválido") from e


def _flow(work: Callable[[Notice], Awaitable[dict[str, Any]]]) -> StreamingResponse:
    """Resposta em NDJSON, uma linha por evento: `aviso` (andamento, para o app mostrar e falar
    enquanto espera), `transcricao`, e no fim `fim` (o mesmo corpo da rota sem fluxo) ou `erro`.
    Linha vazia a cada 10 s mantém a conexão viva nos proxies."""
    queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()

    async def aviso(text: str, event: str = "aviso") -> None:
        await queue.put({"evento": event, "texto": text})

    async def rodar() -> None:
        try:
            await queue.put({"evento": "fim"} | await work(aviso))
        except HTTPException as e:
            await queue.put({"evento": "erro", "detalhe": str(e.detail), "status": e.status_code})
        except Exception:
            log.exception("conversa em fluxo falhou")
            await queue.put({"evento": "erro", "detalhe": "Falha no servidor.", "status": 500})
        finally:
            await queue.put(None)

    async def linhas() -> Any:
        task = asyncio.create_task(rodar())
        try:
            while True:
                try:
                    ev = await asyncio.wait_for(queue.get(), 10)
                except TimeoutError:
                    yield "\n"
                    continue
                if ev is None:
                    break
                yield json.dumps(ev, ensure_ascii=False) + "\n"
        finally:
            task.cancel()  # o app desconectou: não segue gastando LLM

    return StreamingResponse(
        linhas(),
        media_type="application/x-ndjson",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@router.post("/conversar/fluxo")
async def chat_flow(
    c: Conversation,
    cobrador: NaggerDep,
    fontes: SourcesDep,
    llms: LLMsDep,
    internet: InternetDep,
    pc: PCDep,
) -> StreamingResponse:
    """[conversar] com avisos de andamento ([_fluxo])."""
    return _flow(lambda aviso: _chat(c, cobrador, fontes, llms, internet, pc, aviso))


@router.post("/voz/fluxo")
async def voice_flow(
    audio: UploadFile,
    cobrador: NaggerDep,
    fontes: SourcesDep,
    llms: LLMsDep,
    voz: VoiceDep,
    internet: InternetDep,
    pc: PCDep,
    provedor: Annotated[str, Form()] = "local",
    historico: Annotated[str, Form()] = "[]",
    idioma: Annotated[str, Form()] = "",
) -> StreamingResponse:
    """[voz] com avisos: a transcrição sai assim que fica pronta, depois os avisos e o `fim`."""
    data, kind = await audio.read(), audio.content_type or ""  # o arquivo fecha antes do fluxo
    previous = _history(historico)

    async def trabalho(aviso: Notice) -> dict[str, Any]:
        text = await _transcribe(voz, data, kind, idioma)
        await aviso(text, "transcricao")
        c = Conversation(mensagem=text[:8000], historico=previous, provedor=provedor, falada=True)
        return {"transcricao": text} | await _chat(
            c, cobrador, fontes, llms, internet, pc, aviso
        )

    return _flow(trabalho)


@router.post("/falar")
async def speak(f: Speech, voz: VoiceDep) -> Response:
    """A resposta do cobrador em áudio (WAV), sintetizada no worker; com `trecho`, 204 depois do
    último pedaço."""
    try:
        wav = await (voz.falar(f.texto) if f.trecho is None else voz.falar(f.texto, f.trecho))
    except LLMUnavailable as e:
        raise HTTPException(503, str(e)) from e
    if not wav:
        return Response(status_code=204)
    return Response(wav, media_type="audio/wav")


# --- dashboard das LLMs ---


@router.get("/dashboard")
def dashboard(request: Request, medidor: MeterDep, llms: LLMsDep, horas: float = 24) -> Any:
    """Uso por provedor (pedidos, erros, latência p50/p95, tokens), últimos pedidos e os
    workers conectados com o uso de CPU/RAM/GPU da máquina."""
    workers: list[dict[str, Any]] = request.app.state.painel_workers()
    return medidor.resumo(horas) | {"configurados": sorted(llms), "workers": workers}
