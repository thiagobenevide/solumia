"""Host WOPI para o Collabora Online (CODE): o Collabora lê e grava o original da biblioteca
por estas rotas, autenticado pelo `access_token` assinado aqui (nunca a chave do app).

Fluxo: o app pede `POST /api/arquivos/{id}/collabora` (com a chave), recebe a action URL do
Collabora + token e faz POST do formulário `access_token` nessa URL. O Collabora então chama
`/wopi/files/{id}` (CheckFileInfo, GetFile, PutFile, locks) pela `wopi_base_url`.
"""

import base64
import hashlib
import hmac
import html
import json
import re
import secrets
import threading
import time
import xml.etree.ElementTree as ET
from typing import Any
from urllib.parse import quote, urlsplit, urlunsplit

import httpx
from fastapi import APIRouter, BackgroundTasks, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse

from backend.arquivos.biblioteca import ArquivoInvalido, ArquivoNaoEncontrado, Biblioteca
from backend.core.config import Settings

router = APIRouter(prefix="/wopi", tags=["wopi"])

TRAVA_SEGUNDOS = 30 * 60
DISCOVERY_SEGUNDOS = 60 * 60
# Ordem de preferência das ações do discovery (edição primeiro).
ACOES = ("edit", "view_comment", "view")


# --- token (HMAC-SHA256 sobre JSON em base64url) ---


def _b64(dados: bytes) -> str:
    return base64.urlsafe_b64encode(dados).rstrip(b"=").decode()


def _de_b64(texto: str) -> bytes:
    return base64.urlsafe_b64decode(texto + "=" * (-len(texto) % 4))


def _segredo(request: Request) -> bytes:
    settings: Settings = request.app.state.settings
    valor = settings.wopi_secret.get_secret_value()
    if valor:
        return valor.encode()
    # Sem segredo configurado: um aleatório por processo (tokens caem num reinício).
    if not hasattr(request.app.state, "wopi_segredo"):
        request.app.state.wopi_segredo = secrets.token_bytes(32)
    segredo: bytes = request.app.state.wopi_segredo
    return segredo


def gerar_token(segredo: bytes, id_: str, validade: int, origem: str = "") -> tuple[str, int]:
    """Devolve (token, expiração em ms desde a época — o `access_token_ttl` do WOPI)."""
    exp = int(time.time()) + validade
    corpo = _b64(json.dumps({"id": id_, "exp": exp, "origem": origem}).encode())
    assinatura = _b64(hmac.new(segredo, corpo.encode(), hashlib.sha256).digest())
    return f"{corpo}.{assinatura}", exp * 1000


def validar_token(segredo: bytes, token: str, id_: str) -> dict[str, Any]:
    try:
        corpo, assinatura = token.split(".", 1)
        esperado = _b64(hmac.new(segredo, corpo.encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(esperado, assinatura):
            raise ValueError
        dados: dict[str, Any] = json.loads(_de_b64(corpo))
    except ValueError as e:
        raise HTTPException(401, "Token WOPI inválido") from e
    if dados.get("id") != id_ or int(dados.get("exp", 0)) < time.time():
        raise HTTPException(401, "Token WOPI inválido ou expirado")
    return dados


# --- discovery ---

_discovery: dict[str, tuple[float, dict[str, str]]] = {}


def _ler_discovery(xml: str) -> dict[str, str]:
    """extensão → urlsrc, preferindo a ação de edição."""
    acoes: dict[str, tuple[int, str]] = {}
    for acao in ET.fromstring(xml).iter("action"):
        ext, nome, url = acao.get("ext"), acao.get("name"), acao.get("urlsrc")
        if not ext or not url or nome not in ACOES:
            continue
        prioridade = ACOES.index(nome)
        if ext not in acoes or prioridade < acoes[ext][0]:
            acoes[ext] = (prioridade, url)
    return {ext: url for ext, (_, url) in acoes.items()}


async def _discovery_de(settings: Settings) -> dict[str, str]:
    base = (settings.collabora_interno_url or settings.collabora_url).rstrip("/")
    em_cache = _discovery.get(base)
    if em_cache and time.time() - em_cache[0] < DISCOVERY_SEGUNDOS:
        return em_cache[1]
    try:
        async with httpx.AsyncClient(timeout=10) as cliente:
            r = await cliente.get(f"{base}/hosting/discovery")
            r.raise_for_status()
        acoes = _ler_discovery(r.text)
    except (httpx.HTTPError, ET.ParseError) as e:
        raise HTTPException(502, f"Collabora indisponível: {e}") from e
    _discovery[base] = (time.time(), acoes)
    return acoes


async def url_acao(settings: Settings, extensao: str, id_: str) -> str:
    """Action URL do Collabora para a extensão, com o `WOPISrc` deste arquivo."""
    if not settings.collabora_url:
        raise HTTPException(503, "Collabora não configurado (GATEWAY_COLLABORA_URL)")
    urlsrc = (await _discovery_de(settings)).get(extensao.lower())
    if urlsrc is None:
        raise HTTPException(415, f"O Collabora não edita .{extensao}")
    # Tira os marcadores opcionais (<ui=UI_LLCC&>) e troca a origem pela pública: o backend pode
    # ter lido o discovery por um endereço interno (http://collabora:9980).
    urlsrc = re.sub(r"<[^>]*>", "", urlsrc)
    publica = urlsplit(settings.collabora_url)
    partes = urlsplit(urlsrc)._replace(scheme=publica.scheme, netloc=publica.netloc)
    url = urlunsplit(partes)
    wopi_src = f"{settings.wopi_base_url.rstrip('/')}/wopi/files/{id_}"
    separador = "" if url.endswith(("?", "&")) else ("&" if "?" in url else "?")
    return f"{url}{separador}WOPISrc={quote(wopi_src, safe='')}&lang=pt-BR"


async def sessao(request: Request, id_: str) -> dict[str, Any]:
    """Usado por `POST /api/arquivos/{id}/collabora` (rota protegida pela chave do app)."""
    settings: Settings = request.app.state.settings
    biblioteca: Biblioteca = request.app.state.biblioteca
    try:
        meta = biblioteca.obter(id_)
    except ArquivoNaoEncontrado as e:
        raise HTTPException(404, "Arquivo não encontrado") from e
    url = await url_acao(settings, meta["extensao"], id_)
    origem = request.headers.get("origin", "")
    token, ttl = gerar_token(_segredo(request), id_, settings.wopi_token_minutos * 60, origem)
    return {"url": url, "access_token": token, "access_token_ttl": ttl}


# --- travas (em memória, expiram em 30 min) ---


class Travas:
    def __init__(self) -> None:
        self._travas: dict[str, tuple[str, float]] = {}
        self.mutex = threading.Lock()

    def atual(self, id_: str) -> str:
        trava = self._travas.get(id_)
        if trava is None or trava[1] < time.time():
            self._travas.pop(id_, None)
            return ""
        return trava[0]

    def travar(self, id_: str, valor: str) -> None:
        self._travas[id_] = (valor, time.time() + TRAVA_SEGUNDOS)

    def soltar(self, id_: str) -> None:
        self._travas.pop(id_, None)


def _travas(request: Request) -> Travas:
    if not hasattr(request.app.state, "wopi_travas"):
        request.app.state.wopi_travas = Travas()
    travas: Travas = request.app.state.wopi_travas
    return travas


def _conflito(atual: str, motivo: str) -> Response:
    # Cabeçalho HTTP só aceita ASCII: motivos sem acento.
    return Response(
        status_code=409, headers={"X-WOPI-Lock": atual, "X-WOPI-LockFailureReason": motivo}
    )


# --- rotas WOPI ---


def _meta(request: Request, id_: str, token: str) -> tuple[dict[str, Any], dict[str, Any]]:
    dados = validar_token(_segredo(request), token, id_)
    try:
        return request.app.state.biblioteca.obter(id_), dados
    except ArquivoNaoEncontrado as e:
        raise HTTPException(404, "Arquivo não encontrado") from e


@router.get("/files/{id_}")
def check_file_info(id_: str, request: Request, access_token: str = "") -> Any:
    meta, dados = _meta(request, id_, access_token)
    settings: Settings = request.app.state.settings
    info: dict[str, Any] = {
        "BaseFileName": meta["nome_original"],
        "Size": meta["tamanho"],
        "Version": meta["sha256"],
        "LastModifiedTime": meta.get("atualizado"),
        "OwnerId": "agent",
        "UserId": settings.admin_usuario,
        "UserFriendlyName": settings.admin_usuario,
        "UserCanWrite": True,
        "UserCanNotWriteRelative": True,
        "SupportsLocks": True,
        "SupportsGetLock": True,
        "SupportsUpdate": True,
    }
    if dados.get("origem"):
        info["PostMessageOrigin"] = dados["origem"]
    return info


@router.get("/files/{id_}/contents")
def get_file(id_: str, request: Request, access_token: str = "") -> Response:
    meta, _ = _meta(request, id_, access_token)
    caminho, _ = request.app.state.biblioteca.caminho_original(id_)
    return Response(
        caminho.read_bytes(),
        media_type="application/octet-stream",
        headers={"X-WOPI-ItemVersion": meta["sha256"]},
    )


@router.post("/files/{id_}/contents")
async def put_file(
    id_: str, request: Request, tarefas: BackgroundTasks, access_token: str = ""
) -> Response:
    meta, _ = _meta(request, id_, access_token)
    if request.headers.get("x-wopi-override", "PUT").upper() != "PUT":
        raise HTTPException(400, "X-WOPI-Override inválido")
    atual = _travas(request).atual(id_)
    if atual and request.headers.get("x-wopi-lock", "") != atual:
        return _conflito(atual, "Arquivo travado por outra sessao")
    # O Collabora manda o horário da versão que abriu; se o arquivo mudou por fora, avisa.
    carimbo = request.headers.get("x-cool-wopi-timestamp") or request.headers.get(
        "x-lool-wopi-timestamp"
    )
    if carimbo and carimbo != meta.get("atualizado"):
        return JSONResponse(
            status_code=409, content={"COOLStatusCode": 1010, "LOOLStatusCode": 1010}
        )
    biblioteca: Biblioteca = request.app.state.biblioteca
    try:
        novo = biblioteca.substituir(id_, await request.body())
    except ArquivoInvalido as e:
        raise HTTPException(400, str(e)) from e
    if novo["status"] == "convertendo":
        tarefas.add_task(biblioteca.converter, id_)
    return JSONResponse(
        {"LastModifiedTime": novo["atualizado"]},
        headers={"X-WOPI-ItemVersion": novo["sha256"]},
    )


@router.post("/files/{id_}")
def trava(id_: str, request: Request, access_token: str = "") -> Response:
    _meta(request, id_, access_token)
    travas = _travas(request)
    operacao = request.headers.get("x-wopi-override", "").upper()
    pedida = request.headers.get("x-wopi-lock", "")
    antiga = request.headers.get("x-wopi-oldlock", "")
    with travas.mutex:
        atual = travas.atual(id_)
        if operacao == "GET_LOCK":
            return Response(headers={"X-WOPI-Lock": atual})
        if not pedida:
            raise HTTPException(400, "Falta X-WOPI-Lock")
        if operacao == "LOCK" and antiga:  # UnlockAndRelock
            if atual != antiga:
                return _conflito(atual, "Trava diferente")
        elif operacao == "LOCK":
            if atual and atual != pedida:
                return _conflito(atual, "Arquivo travado por outra sessao")
        elif operacao in ("UNLOCK", "REFRESH_LOCK"):
            if atual != pedida:
                return _conflito(atual, "Trava diferente")
            if operacao == "UNLOCK":
                travas.soltar(id_)
                return Response()
        else:
            raise HTTPException(501, f"X-WOPI-Override não suportado: {operacao}")
        travas.travar(id_, pedida)
    return Response()


@router.get("/abrir/{id_}")
async def abrir(id_: str, request: Request, t: str = "") -> HTMLResponse:
    """Página que faz POST do token para o Collabora: o app no desktop (sem webview) abre
    esta URL no navegador. `t` é o `access_token` de `POST /api/arquivos/{id}/collabora`."""
    meta, dados = _meta(request, id_, t)
    settings: Settings = request.app.state.settings
    url = await url_acao(settings, meta["extensao"], id_)
    nonce = secrets.token_urlsafe(16)
    publica = urlsplit(settings.collabora_url)
    origem = f"{publica.scheme}://{publica.netloc}"
    return HTMLResponse(
        pagina_formulario(url, t, int(dados["exp"]) * 1000, meta["nome_original"], nonce),
        headers={
            # O middleware de segurança só preenche o que faltar: libera o script e o POST.
            "Content-Security-Policy": (
                f"default-src 'none'; script-src 'nonce-{nonce}'; form-action {origem}; "
                "frame-ancestors 'none'"
            ),
            "Cache-Control": "no-store",
        },
    )


def pagina_formulario(url: str, token: str, ttl: int, titulo: str, nonce: str = "") -> str:
    """HTML com o formulário WOPI que se envia sozinho (o app usa o mesmo HTML na webview)."""
    atributo = f' nonce="{nonce}"' if nonce else ""
    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'>"
        f"<title>{html.escape(titulo)}</title></head><body>"
        f"<form id='f' method='post' action='{html.escape(url, quote=True)}'>"
        f"<input type='hidden' name='access_token' value='{html.escape(token, quote=True)}'>"
        f"<input type='hidden' name='access_token_ttl' value='{ttl}'>"
        "<noscript><button type='submit'>Abrir no Collabora</button></noscript></form>"
        f"<script{atributo}>document.getElementById('f').submit()</script></body></html>"
    )
