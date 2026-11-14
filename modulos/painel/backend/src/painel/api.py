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

from painel import agente, desempenho
from painel.cobrador import Cobrador, Invalido, NaoEncontrado
from painel.medidor import Medidor

router = APIRouter(tags=["painel"])
log = logging.getLogger(__name__)

# `content` é texto ou, com imagem, partes no formato OpenAI (text + image_url com data URL).
ChatLLM = Callable[[list[dict[str, Any]]], Awaitable[str]]
# Aviso de andamento ("consultando a internet…") para quem acompanha pelas rotas `/fluxo`.
Aviso = Callable[..., Awaitable[None]]


async def _sem_aviso(_: str, evento: str = "aviso") -> None:
    return None

SISTEMA = (
    "Você é o Cobrador: o assistente de disciplina do usuário. Responda em português, curto e "
    "direto, como um parceiro exigente porém justo. Use o retrato do dia abaixo (agenda, metas, "
    "alertas e tarefas) para dizer o que fazer agora, cobrar o que está atrasado e defender as "
    "entregas prioritárias. Se o usuário quiser mudar a agenda, avalie o impacto nos prazos "
    "antes de concordar. Não invente tarefas nem metas que não estão no retrato.\n\n"
)


class LLMIndisponivel(Exception):
    pass


@dataclass
class Fontes:
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
class Voz:
    """Fala e escuta pelo worker: `transcrever(audio, mime, idioma) → texto` (idioma `pt`, `en` ou
    vazio = detecta entre os dois) e `falar(texto, trecho=None) → wav` (com trecho, só aquele
    pedaço da fala; vazio depois do último)."""

    transcrever: Callable[[bytes, str, str], Awaitable[str]]
    falar: Callable[..., Awaitable[bytes]]


def get_cobrador(request: Request) -> Cobrador:
    cobrador: Cobrador = request.app.state.cobrador
    return cobrador


def get_fontes(request: Request) -> Fontes:
    fontes: Fontes = request.app.state.painel_fontes
    return fontes


def get_llms(request: Request) -> dict[str, ChatLLM]:
    llms: dict[str, ChatLLM] = request.app.state.painel_llms
    return llms


def get_voz(request: Request) -> Voz:
    voz: Voz = request.app.state.painel_voz
    return voz


def get_medidor(request: Request) -> Medidor:
    medidor: Medidor = request.app.state.medidor
    return medidor


# Comando no PC pelo worker: `{"acao": ..., ...}` → `{"ok", "detalhe"}` (ver worker/pc.py).
PC = Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]


def get_pc(request: Request) -> PC | None:
    return getattr(request.app.state, "painel_pc", None)


PCDep = Annotated[PC | None, Depends(get_pc)]
CobradorDep = Annotated[Cobrador, Depends(get_cobrador)]
VozDep = Annotated[Voz, Depends(get_voz)]
MedidorDep = Annotated[Medidor, Depends(get_medidor)]
FontesDep = Annotated[Fontes, Depends(get_fontes)]
LLMsDep = Annotated[dict[str, ChatLLM], Depends(get_llms)]


def get_internet(request: Request) -> Any:
    """Ferramentas de dados em tempo real da plataforma (`backend.internet.Internet`), se houver."""
    return getattr(request.app.state, "internet", None)


InternetDep = Annotated[Any, Depends(get_internet)]


class MetaEntrada(BaseModel):
    titulo: str = Field(min_length=1, max_length=200)
    frequencia: str = "diaria"
    alvo: float = 1
    unidade: str = Field("vez", max_length=40)


class AcaoEntrada(BaseModel):
    quantidade: float = Field(1, gt=0)
    nota: str = Field("", max_length=2000)


class Bloco(BaseModel):
    id: str | None = None
    titulo: str = Field(min_length=1, max_length=200)
    inicio: str = Field(pattern=r"^\d{2}:\d{2}$")
    fim: str = Field(pattern=r"^\d{2}:\d{2}$")
    prioridade: str = Field("media", pattern="^(baixa|media|alta)$")
    tarefa_id: str | None = None
    prazo: str | None = None
    feito: bool = False


class AgendaEntrada(BaseModel):
    blocos: list[Bloco] = Field(max_length=60)
    motivo: str = Field("", max_length=2000)


class Mensagem(BaseModel):
    papel: str = Field(pattern="^(usuario|assistente)$")
    texto: str = Field(max_length=8000)


class Fala(BaseModel):
    texto: str = Field(min_length=1, max_length=4000)
    trecho: int | None = Field(default=None, ge=0)
    """Só o n-ésimo pedaço da fala: o app toca um enquanto o próximo é sintetizado."""


class Conversa(BaseModel):
    mensagem: str = Field(min_length=1, max_length=8000)
    historico: list[Mensagem] = Field([], max_length=20)
    provedor: str = "local"
    # foto anexada à mensagem (base64, sem o prefixo data:); só vale para esta mensagem
    imagem: str | None = None
    imagem_mime: Literal["image/jpeg", "image/png", "image/webp", "image/gif"] = "image/jpeg"
    # mensagem por voz: a resposta vai ser ouvida, então sai curta (cada frase a mais é ~1 s de
    # geração e outro tanto de síntese)
    falada: bool = False


def _erro(e: Exception) -> HTTPException:
    if isinstance(e, NaoEncontrado):
        return HTTPException(404, "Não encontrado")
    return HTTPException(422, str(e))


# --- metas ---


@router.get("/metas")
def metas(cobrador: CobradorDep) -> Any:
    return cobrador.metas()


@router.post("/metas", status_code=201)
def criar_meta(m: MetaEntrada, cobrador: CobradorDep) -> Any:
    try:
        return cobrador.criar_meta(m.model_dump())
    except Invalido as e:
        raise _erro(e) from e


@router.delete("/metas/{id_}", status_code=204)
def excluir_meta(id_: str, cobrador: CobradorDep) -> None:
    try:
        cobrador.excluir_meta(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.post("/metas/{id_}/acoes", status_code=201)
def registrar_acao(id_: str, a: AcaoEntrada, cobrador: CobradorDep) -> Any:
    try:
        return cobrador.registrar_acao(id_, a.quantidade, a.nota)
    except NaoEncontrado as e:
        raise _erro(e) from e


# --- agenda ---


@router.get("/agenda/{dia}")
def agenda(dia: str, cobrador: CobradorDep) -> Any:
    try:
        return cobrador.agenda(dia)
    except ValueError as e:
        raise _erro(e) from e


@router.post("/agenda/{dia}/sugerir")
def sugerir(dia: str, cobrador: CobradorDep, fontes: FontesDep) -> Any:
    try:
        return cobrador.sugerir(dia, fontes.tarefas())
    except ValueError as e:
        raise _erro(e) from e


@router.put("/agenda/{dia}")
def salvar_agenda(dia: str, ag: AgendaEntrada, cobrador: CobradorDep) -> Any:
    blocos = [b.model_dump(exclude_none=True) for b in ag.blocos]
    try:
        return cobrador.salvar(dia, blocos, ag.motivo)
    except (Invalido, ValueError) as e:
        raise _erro(e) from e


@router.post("/agenda/{dia}/blocos/{bloco_id}/feito")
def marcar(dia: str, bloco_id: str, cobrador: CobradorDep, feito: bool = True) -> Any:
    try:
        return cobrador.marcar(dia, bloco_id, feito)
    except NaoEncontrado as e:
        raise _erro(e) from e


# --- cobrança ---


@router.get("/disciplina")
def disciplina(cobrador: CobradorDep, fontes: FontesDep) -> Any:
    return cobrador.disciplina(fontes.tarefas())


@router.get("/desempenho")
def ver_desempenho(cobrador: CobradorDep, fontes: FontesDep, dias: int = 30) -> Any:
    return desempenho.analisar(fontes.tarefas(), cobrador, dias)


@router.get("/provedores")
def provedores(llms: LLMsDep) -> Any:
    return sorted(llms)


# --- conversa ---

_ANOTAR = re.compile(
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
_TEMPO_REAL = re.compile(
    r"\b(?:cota[cç][aã]o|d[oó]lar|euro|bitcoin|fipe|selic|cdi|ipca|infla[cç][aã]o|ibovespa|"
    r"pre[cç]o (?:atual|de hoje|hoje)|not[ií]cias?|quanto (?:est[aá]|custa) (?:o|a|hoje))\b",
    re.I,
)

# Pedido para o computador ("abre o Brave e pesquisa…", "desliga o PC"): vai direto ao agente,
# sem os atalhos de pesquisa na web/notas acima.
_COMANDO_PC = re.compile(
    r"^\s*(?:abr[ae]|abrir|desligu?[ae]|desligar|cancel[ae] o desligamento)\b|"
    r"\b(?:brave|firefox|navegador|youtube|computador|pc)\b",
    re.I,
)

_PESQUISAR = re.compile(
    r"^\s*(?:pesquis[ae]|busc?que|busca|procur[ae])"
    r"(?:\s+(?:na|em|nas)\s+(?:nossa\s+)?(?:base(?: de conhecimento)?|notas|cofre))?"
    r"(?:\s+(?:sobre|por|o que|pelo|pela))?\s*[:,\-]?\s*",
    re.I,
)


def _sem_acento(texto: str) -> str:
    return "".join(
        c for c in unicodedata.normalize("NFD", texto.lower()) if unicodedata.category(c) != "Mn"
    )


def _buscar(fontes: Fontes, consulta: str, limite: int = 5) -> list[dict[str, Any]]:
    """Notas que contêm mais palavras da consulta (palavras de 4+ letras)."""
    palavras = [p for p in re.findall(r"\w+", _sem_acento(consulta)) if len(p) >= 4] or [consulta]
    pontos: dict[str, int] = {}
    achadas: dict[str, dict[str, Any]] = {}
    for p in palavras:
        for n in fontes.buscar_notas(p):
            pontos[n["id"]] = pontos.get(n["id"], 0) + 1
            achadas[n["id"]] = n
    ordem = sorted(pontos, key=lambda i: -pontos[i])[:limite]
    return [achadas[i] for i in ordem]


async def _responder(llm: ChatLLM, sistema: str, c: Conversa, pergunta: str) -> str:
    papeis = {"usuario": "user", "assistente": "assistant"}
    mensagens: list[dict[str, Any]] = [{"role": "system", "content": sistema}]
    mensagens += [{"role": papeis[m.papel], "content": m.texto} for m in c.historico]
    conteudo: Any = pergunta
    if c.imagem:
        url = f"data:{c.imagem_mime};base64,{c.imagem}"
        conteudo = [
            {"type": "text", "text": pergunta},
            {"type": "image_url", "image_url": {"url": url}},
        ]
    mensagens.append({"role": "user", "content": conteudo})
    return await llm(mensagens)


_FALADA = (
    "[Mensagem por voz: sua resposta será ouvida, não lida. Responda em até 3 frases curtas e "
    "naturais, sem markdown, tabelas ou listas longas; se houver passos, diga primeiro, segundo.]"
    "\n\n"
)

_MAX_IMAGEM = 8_000_000  # caracteres de base64 (~6 MB de imagem)


async def _conversar(
    c: Conversa,
    cobrador: Cobrador,
    fontes: Fontes,
    llms: dict[str, ChatLLM],
    internet: Any = None,
    pc: PC | None = None,
    aviso: Aviso = _sem_aviso,
) -> Any:
    """Chat do cobrador. Entende dois comandos antes de ir ao LLM: “anote …” cria uma nota no
    cofre e “pesquise …” busca na base de notas e responde com elas como contexto. No resto, o
    LLM responde e pode pedir ações (ver [agente]); elas voltam em `executadas`."""
    if c.provedor not in llms:
        raise HTTPException(422, f"Provedor indisponível: {c.provedor}")
    # o app já manda ≤ 1 MB; acima disso a mensagem ao worker (teto 16 MB) poderia estourar
    if c.imagem and len(c.imagem) > _MAX_IMAGEM:
        raise HTTPException(413, "Imagem grande demais; envie uma foto menor (até ~6 MB).")
    llm = llms[c.provedor]

    if m := _ANOTAR.match(c.mensagem):
        corpo = c.mensagem[m.end() :].strip()
        if not corpo:
            raise HTTPException(422, "Diga o que anotar depois de “anote”.")
        primeira = re.split(r"[.\n!?]", corpo, maxsplit=1)[0].strip()
        titulo = f"{cobrador.agora():%Y-%m-%d %H%M} {primeira[:60]}".strip()
        nota = fontes.criar_nota({"titulo": titulo, "corpo": corpo, "tags": ["cobrador"]})
        return {"resposta": f"Anotado em “{nota['titulo']}”.", "acao": "nota", "nota": nota}

    no_pc = pc is not None and bool(_COMANDO_PC.search(c.mensagem))
    m = _INTERNET.match(c.mensagem)
    if not no_pc and internet is not None and (
        m or (_TEMPO_REAL.search(c.mensagem) and not _ANOTAR.match(c.mensagem))
    ):
        pedido = c.mensagem[m.end() :].strip() if m else c.mensagem
        await aviso("Certo, vou consultar na internet. Um instante.")
        try:
            r = await internet.pesquisar(
                llm, pedido or c.mensagem, contexto=_FALADA if c.falada else "", aviso=aviso
            )
        except LLMIndisponivel as e:
            raise HTTPException(503, str(e)) from e
        return {
            "resposta": r["resposta"],
            "acao": "internet",
            "fontes": r["fontes"],
            "links": r["links"],
        }

    if not no_pc and (m := _PESQUISAR.match(c.mensagem)):
        consulta = c.mensagem[m.end() :].strip() or c.mensagem
        notas = _buscar(fontes, consulta)
        if not notas:
            return {
                "resposta": f"Nada na base sobre “{consulta}”.",
                "acao": "pesquisa",
                "notas": [],
            }
        trechos = []
        for n in notas[:3]:
            corpo = str(fontes.ler_nota(n["id"]).get("corpo", ""))[:3000]
            trechos.append(f"### {n['titulo']}\n{corpo}")
        sistema = (
            "Responda em português, curto, usando só as notas abaixo da base de conhecimento do "
            "usuário; cite o título da nota de onde veio cada informação.\n\n"
            + "\n\n".join(trechos)
        )
        try:
            resposta = await _responder(llm, sistema, c, f"Pergunta: {consulta}")
        except LLMIndisponivel:
            resposta = "Sem LLM agora; notas encontradas:\n" + "\n".join(
                f"- {n['titulo']}" for n in notas
            )
        return {"resposta": resposta, "acao": "pesquisa", "notas": notas}

    # Ordem pensada para o cache do llama-server: o que quase não muda (instruções, agenda,
    # tarefas) vai no sistema e o que muda a cada minuto (hora, alertas) só na última mensagem;
    # assim cada mensagem processa só o texto novo em vez do prompt inteiro.
    tarefas = fontes.tarefas()
    sistema = SISTEMA + agente.INSTRUCOES + agente.instrucoes_modulos(fontes.modulos)
    if pc is not None:
        sistema += agente.COMPUTADOR
    sistema += "\n# Retrato do dia\n" + cobrador.retrato(tarefas)
    analise = None
    if _DESEMPENHO.search(c.mensagem):
        analise = desempenho.analisar(tarefas, cobrador)
        sistema += "\n" + desempenho.texto(analise) + "\n" + agente.ANALISE
    agora = f"[{cobrador.momento(tarefas)}]\n\n"
    if c.falada:  # na última mensagem, não no sistema: não invalida o cache do prompt
        agora += _FALADA

    async def agir(acoes: list[dict[str, Any]]) -> list[dict[str, Any]]:
        no_pc, acoes = agente.separar_pc(acoes)
        nos_modulos, acoes = agente.separar_modulos(acoes, fontes.modulos)
        feitas = agente.executar(acoes, cobrador, fontes, motivo=c.mensagem[:300])
        feitas += await agente.executar_modulos(nos_modulos, fontes.modulos, llm)
        return feitas + await agente.executar_pc(no_pc, pc)

    try:
        bruta = await _responder(llm, sistema, c, agora + c.mensagem)
        resposta, acoes = agente.extrair(bruta)
        consultas, acoes = agente.separar(acoes)
        executadas = await agir(acoes)
        links: list[dict[str, Any]] = []
        if consultas:
            # uma rodada de consultas: o LLM recebe os resultados e responde de novo
            resultados = []
            for a in consultas[:3]:
                await aviso(_ANDAMENTO.get(str(a.get("tipo")), "Consultando…"))
                texto, feita, achados = await _consultar(a, llm, cobrador, fontes, internet)
                resultados.append(texto)
                executadas.append(feita)
                links += achados
            pergunta = (
                f"{agora}{c.mensagem}\n\n[Resultados das consultas que você pediu]\n"
                + "\n\n".join(resultados)
                + "\n\nResponda agora com esses resultados; não peça as mesmas consultas."
            )
            resposta, acoes = agente.extrair(await _responder(llm, sistema, c, pergunta))
            _, acoes = agente.separar(acoes)
            executadas += await agir(acoes)
    except LLMIndisponivel as e:
        if c.imagem and c.provedor == "local":
            raise HTTPException(
                503,
                f"{e}. Para ler imagens o modelo local precisa de visão (gemma-4, qwen2.5vl ou "
                "qwen3.8, escolha na aba LLMs) ou use o Claude.",
            ) from e
        raise HTTPException(503, str(e)) from e
    r: dict[str, Any] = {
        "resposta": resposta,
        "acao": "agente" if executadas else ("desempenho" if analise else None),
        "executadas": executadas,
    }
    if links:
        r["links"] = links
    if analise:
        r["desempenho"] = analise
    return r


_ANDAMENTO = {
    "pesquisar_web": "Deixa eu pesquisar na internet.",
    "pesquisar_notas": "Vou procurar nas suas notas.",
    "analisar_desempenho": "Vou analisar o seu desempenho.",
}

# "como está meu desempenho", "analise minha produtividade": a análise entra no prompt.
_DESEMPENHO = re.compile(r"\b(?:desempenho|produtividade|rendimento)\b", re.I)


async def _consultar(
    a: dict[str, Any], llm: ChatLLM, cobrador: Cobrador, fontes: Fontes, internet: Any
) -> tuple[str, dict[str, Any], list[dict[str, Any]]]:
    """Executa uma consulta do agente: (texto para o LLM, item de `executadas`, links)."""
    tipo = str(a.get("tipo"))
    consulta = str(a.get("consulta", "")).strip()
    if tipo == "analisar_desempenho":
        dias = int(a.get("dias") or 30)
        texto = desempenho.texto(desempenho.analisar(fontes.tarefas(), cobrador, dias))
        return texto, {"tipo": tipo, "ok": True, "detalhe": f"Analisei {dias} dias"}, []
    if not consulta:
        return "", {"tipo": tipo, "ok": False, "detalhe": "Consulta vazia."}, []
    if tipo == "pesquisar_notas":
        notas = _buscar(fontes, consulta)
        trechos = [
            f"### {n['titulo']}\n{str(fontes.ler_nota(n['id']).get('corpo', ''))[:1500]}"
            for n in notas[:3]
        ]
        texto = f"## Notas sobre “{consulta}”\n" + ("\n\n".join(trechos) or "nenhuma")
        detalhe = f"Busquei nas notas: {consulta} ({len(notas)})"
        return texto, {"tipo": tipo, "ok": True, "detalhe": detalhe}, []
    if internet is None:
        return "", {"tipo": tipo, "ok": False, "detalhe": "Internet indisponível."}, []
    try:
        r = await internet.pesquisar(llm, consulta)
    except LLMIndisponivel:
        raise
    except Exception as e:  # ferramenta externa fora do ar não derruba a conversa
        return "", {"tipo": tipo, "ok": False, "detalhe": f"Falha na web: {e}"}, []
    texto = f"## Web: “{consulta}”\n{r['resposta']}"
    return texto, {"tipo": tipo, "ok": True, "detalhe": f"Pesquisei na web: {consulta}"}, r["links"]


@router.post("/conversar")
async def conversar(
    c: Conversa,
    cobrador: CobradorDep,
    fontes: FontesDep,
    llms: LLMsDep,
    internet: InternetDep,
    pc: PCDep,
) -> Any:
    return await _conversar(c, cobrador, fontes, llms, internet, pc)


class ComandoPC(BaseModel):
    acao: Literal["ligar", "desligar", "cancelar_desligar"]
    minutos: int = Field(0, ge=0, le=600)


@router.post("/pc")
async def comando_pc(cmd: ComandoPC, pc: PCDep) -> Any:
    """Botão do app: desligar o PC (ou cancelar um desligamento agendado)."""
    if pc is None:
        raise HTTPException(503, "Comandos no PC indisponíveis.")
    try:
        return await pc(cmd.model_dump())
    except Exception as e:
        raise HTTPException(503, f"No PC: {e}") from e


# --- voz ---


async def _transcrever(voz: Voz, audio: bytes, tipo: str, idioma: str) -> str:
    try:
        texto = await voz.transcrever(audio, tipo, idioma)
    except LLMIndisponivel as e:
        raise HTTPException(503, str(e)) from e
    if not texto.strip():
        raise HTTPException(422, "Não entendi o áudio; tente de novo mais perto do microfone.")
    return texto


@router.post("/transcrever")
async def transcrever(
    audio: UploadFile, voz: VozDep, idioma: Annotated[str, Form()] = ""
) -> dict[str, str]:
    """Só a transcrição, para o microfone dos outros chats (rotinas, código…): o app põe o texto
    no próprio chat."""
    return {"texto": await _transcrever(voz, await audio.read(), audio.content_type or "", idioma)}


@router.post("/voz")
async def voz(
    audio: UploadFile,
    cobrador: CobradorDep,
    fontes: FontesDep,
    llms: LLMsDep,
    voz: VozDep,
    internet: InternetDep,
    pc: PCDep,
    provedor: Annotated[str, Form()] = "local",
    historico: Annotated[str, Form()] = "[]",
    idioma: Annotated[str, Form()] = "",
) -> Any:
    """Mensagem falada: o worker transcreve e a transcrição segue como mensagem de texto."""
    texto = await _transcrever(voz, await audio.read(), audio.content_type or "", idioma)
    c = Conversa(
        mensagem=texto[:8000], historico=_historico(historico), provedor=provedor, falada=True
    )
    return {"transcricao": texto} | await _conversar(c, cobrador, fontes, llms, internet, pc)


def _historico(historico: str) -> list[Mensagem]:
    try:
        return [Mensagem(**m) for m in json.loads(historico)][-20:]
    except (ValueError, TypeError) as e:
        raise HTTPException(422, "Histórico inválido") from e


def _fluxo(trabalho: Callable[[Aviso], Awaitable[dict[str, Any]]]) -> StreamingResponse:
    """Resposta em NDJSON, uma linha por evento: `aviso` (andamento, para o app mostrar e falar
    enquanto espera), `transcricao`, e no fim `fim` (o mesmo corpo da rota sem fluxo) ou `erro`.
    Linha vazia a cada 10 s mantém a conexão viva nos proxies."""
    fila: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()

    async def aviso(texto: str, evento: str = "aviso") -> None:
        await fila.put({"evento": evento, "texto": texto})

    async def rodar() -> None:
        try:
            await fila.put({"evento": "fim"} | await trabalho(aviso))
        except HTTPException as e:
            await fila.put({"evento": "erro", "detalhe": str(e.detail), "status": e.status_code})
        except Exception:
            log.exception("conversa em fluxo falhou")
            await fila.put({"evento": "erro", "detalhe": "Falha no servidor.", "status": 500})
        finally:
            await fila.put(None)

    async def linhas() -> Any:
        tarefa = asyncio.create_task(rodar())
        try:
            while True:
                try:
                    ev = await asyncio.wait_for(fila.get(), 10)
                except TimeoutError:
                    yield "\n"
                    continue
                if ev is None:
                    break
                yield json.dumps(ev, ensure_ascii=False) + "\n"
        finally:
            tarefa.cancel()  # o app desconectou: não segue gastando LLM

    return StreamingResponse(
        linhas(),
        media_type="application/x-ndjson",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@router.post("/conversar/fluxo")
async def conversar_fluxo(
    c: Conversa,
    cobrador: CobradorDep,
    fontes: FontesDep,
    llms: LLMsDep,
    internet: InternetDep,
    pc: PCDep,
) -> StreamingResponse:
    """[conversar] com avisos de andamento ([_fluxo])."""
    return _fluxo(lambda aviso: _conversar(c, cobrador, fontes, llms, internet, pc, aviso))


@router.post("/voz/fluxo")
async def voz_fluxo(
    audio: UploadFile,
    cobrador: CobradorDep,
    fontes: FontesDep,
    llms: LLMsDep,
    voz: VozDep,
    internet: InternetDep,
    pc: PCDep,
    provedor: Annotated[str, Form()] = "local",
    historico: Annotated[str, Form()] = "[]",
    idioma: Annotated[str, Form()] = "",
) -> StreamingResponse:
    """[voz] com avisos: a transcrição sai assim que fica pronta, depois os avisos e o `fim`."""
    dados, tipo = await audio.read(), audio.content_type or ""  # o arquivo fecha antes do fluxo
    anteriores = _historico(historico)

    async def trabalho(aviso: Aviso) -> dict[str, Any]:
        texto = await _transcrever(voz, dados, tipo, idioma)
        await aviso(texto, "transcricao")
        c = Conversa(mensagem=texto[:8000], historico=anteriores, provedor=provedor, falada=True)
        return {"transcricao": texto} | await _conversar(
            c, cobrador, fontes, llms, internet, pc, aviso
        )

    return _fluxo(trabalho)


@router.post("/falar")
async def falar(f: Fala, voz: VozDep) -> Response:
    """A resposta do cobrador em áudio (WAV), sintetizada no worker; com `trecho`, 204 depois do
    último pedaço."""
    try:
        wav = await (voz.falar(f.texto) if f.trecho is None else voz.falar(f.texto, f.trecho))
    except LLMIndisponivel as e:
        raise HTTPException(503, str(e)) from e
    if not wav:
        return Response(status_code=204)
    return Response(wav, media_type="audio/wav")


# --- dashboard das LLMs ---


@router.get("/dashboard")
def dashboard(request: Request, medidor: MedidorDep, llms: LLMsDep, horas: float = 24) -> Any:
    """Uso por provedor (pedidos, erros, latência p50/p95, tokens), últimos pedidos e os
    workers conectados com o uso de CPU/RAM/GPU da máquina."""
    workers: list[dict[str, Any]] = request.app.state.painel_workers()
    return medidor.resumo(horas) | {"configurados": sorted(llms), "workers": workers}
