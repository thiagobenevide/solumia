"""WOPI host for Collabora Online (CODE): Collabora reads and writes the library original
through these routes, authenticated by the `access_token` signed here (never the app key).

Flow: the app requests `POST /api/arquivos/{id}/collabora` (with the key), receives the Collabora
action URL + token and POSTs the `access_token` form to that URL. Collabora then calls
`/wopi/files/{id}` (CheckFileInfo, GetFile, PutFile, locks) through the `wopi_base_url`.
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

from backend.core.config import Settings
from backend.files.library import Collection, FileInvalid, FileNotFound

router = APIRouter(prefix="/wopi", tags=["wopi"])

LOCK_SECONDS = 30 * 60
DISCOVERY_SECONDS = 60 * 60
# Preference order of the discovery actions (edit first).
ACTIONS = ("edit", "view_comment", "view")


# --- token (HMAC-SHA256 sobre JSON em base64url) ---


def _b64(dados: bytes) -> str:
    return base64.urlsafe_b64encode(dados).rstrip(b"=").decode()


def _of_b64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _secret(request: Request) -> bytes:
    settings: Settings = request.app.state.settings
    value = settings.wopi_secret.get_secret_value()
    if value:
        return value.encode()
    # No configured secret: a random one per process (tokens drop on a restart).
    if not hasattr(request.app.state, "wopi_segredo"):
        request.app.state.wopi_segredo = secrets.token_bytes(32)
    secret: bytes = request.app.state.wopi_segredo
    return secret


def generate_token(secret: bytes, id_: str, validity: int, origem: str = "") -> tuple[str, int]:
    """Returns (token, expiry in ms since the epoch — the WOPI `access_token_ttl`)."""
    exp = int(time.time()) + validity
    body = _b64(json.dumps({"id": id_, "exp": exp, "origem": origem}).encode())
    signature = _b64(hmac.new(secret, body.encode(), hashlib.sha256).digest())
    return f"{body}.{signature}", exp * 1000


def validate_token(secret: bytes, token: str, id_: str) -> dict[str, Any]:
    try:
        body, signature = token.split(".", 1)
        expected = _b64(hmac.new(secret, body.encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(expected, signature):
            raise ValueError
        data: dict[str, Any] = json.loads(_of_b64(body))
    except ValueError as e:
        raise HTTPException(401, "Token WOPI inválido") from e
    if data.get("id") != id_ or int(data.get("exp", 0)) < time.time():
        raise HTTPException(401, "Token WOPI inválido ou expirado")
    return data


# --- discovery ---

_discovery: dict[str, tuple[float, dict[str, str]]] = {}


def _read_discovery(xml: str) -> dict[str, str]:
    """extension → urlsrc, preferring the edit action."""
    actions: dict[str, tuple[int, str]] = {}
    for action in ET.fromstring(xml).iter("action"):
        ext, name, url = action.get("ext"), action.get("name"), action.get("urlsrc")
        if not ext or not url or name not in ACTIONS:
            continue
        prioridade = ACTIONS.index(name)
        if ext not in actions or prioridade < actions[ext][0]:
            actions[ext] = (prioridade, url)
    return {ext: url for ext, (_, url) in actions.items()}


async def _discovery_of(settings: Settings) -> dict[str, str]:
    base = (settings.collabora_interno_url or settings.collabora_url).rstrip("/")
    in_cache = _discovery.get(base)
    if in_cache and time.time() - in_cache[0] < DISCOVERY_SECONDS:
        return in_cache[1]
    try:
        async with httpx.AsyncClient(timeout=10) as cliente:
            r = await cliente.get(f"{base}/hosting/discovery")
            r.raise_for_status()
        actions = _read_discovery(r.text)
    except (httpx.HTTPError, ET.ParseError) as e:
        raise HTTPException(502, f"Collabora indisponível: {e}") from e
    _discovery[base] = (time.time(), actions)
    return actions


async def url_action(settings: Settings, extension: str, id_: str) -> str:
    """Collabora action URL for the extension, with this file's `WOPISrc`."""
    if not settings.collabora_url:
        raise HTTPException(503, "Collabora não configurado (GATEWAY_COLLABORA_URL)")
    urlsrc = (await _discovery_of(settings)).get(extension.lower())
    if urlsrc is None:
        raise HTTPException(415, f"O Collabora não edita .{extension}")
    # Strip the optional markers (<ui=UI_LLCC&>) and replace the origin with the public one: the
    # backend may have read the discovery through an internal address (http://collabora:9980).
    urlsrc = re.sub(r"<[^>]*>", "", urlsrc)
    public = urlsplit(settings.collabora_url)
    parts = urlsplit(urlsrc)._replace(scheme=public.scheme, netloc=public.netloc)
    url = urlunsplit(parts)
    wopi_src = f"{settings.wopi_base_url.rstrip('/')}/wopi/files/{id_}"
    separador = "" if url.endswith(("?", "&")) else ("&" if "?" in url else "?")
    return f"{url}{separador}WOPISrc={quote(wopi_src, safe='')}&lang=pt-BR"


async def session(request: Request, id_: str) -> dict[str, Any]:
    """Used by `POST /api/arquivos/{id}/collabora` (route protected by the app key)."""
    settings: Settings = request.app.state.settings
    collection: Collection = request.app.state.collection
    try:
        meta = collection.obter(id_)
    except FileNotFound as e:
        raise HTTPException(404, "Arquivo não encontrado") from e
    url = await url_action(settings, meta["extensao"], id_)
    origin = request.headers.get("origin", "")
    token, ttl = generate_token(_secret(request), id_, settings.wopi_token_minutos * 60, origin)
    return {"url": url, "access_token": token, "access_token_ttl": ttl}


# --- locks (in memory, expire in 30 min) ---


class Locks:
    def __init__(self) -> None:
        self._locks: dict[str, tuple[str, float]] = {}
        self.mutex = threading.Lock()

    def atual(self, id_: str) -> str:
        lock = self._locks.get(id_)
        if lock is None or lock[1] < time.time():
            self._locks.pop(id_, None)
            return ""
        return lock[0]

    def travar(self, id_: str, value: str) -> None:
        self._locks[id_] = (value, time.time() + LOCK_SECONDS)

    def soltar(self, id_: str) -> None:
        self._locks.pop(id_, None)


def _locks(request: Request) -> Locks:
    if not hasattr(request.app.state, "wopi_travas"):
        request.app.state.wopi_travas = Locks()
    locks: Locks = request.app.state.wopi_travas
    return locks


def _conflict(current: str, motivo: str) -> Response:
    # HTTP headers only accept ASCII: reasons without accents.
    return Response(
        status_code=409, headers={"X-WOPI-Lock": current, "X-WOPI-LockFailureReason": motivo}
    )


# --- rotas WOPI ---


def _meta(request: Request, id_: str, token: str) -> tuple[dict[str, Any], dict[str, Any]]:
    data = validate_token(_secret(request), token, id_)
    try:
        return request.app.state.collection.obter(id_), data
    except FileNotFound as e:
        raise HTTPException(404, "Arquivo não encontrado") from e


@router.get("/files/{id_}")
def check_file_info(id_: str, request: Request, access_token: str = "") -> Any:
    meta, data = _meta(request, id_, access_token)
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
    if data.get("origem"):
        info["PostMessageOrigin"] = data["origem"]
    return info


@router.get("/files/{id_}/contents")
def get_file(id_: str, request: Request, access_token: str = "") -> Response:
    meta, _ = _meta(request, id_, access_token)
    path, _ = request.app.state.collection.path_original(id_)
    return Response(
        path.read_bytes(),
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
    current = _locks(request).atual(id_)
    if current and request.headers.get("x-wopi-lock", "") != current:
        return _conflict(current, "Arquivo travado por outra sessao")
    # Collabora sends the time of the version it opened; if the file changed outside, it warns.
    carimbo = request.headers.get("x-cool-wopi-timestamp") or request.headers.get(
        "x-lool-wopi-timestamp"
    )
    if carimbo and carimbo != meta.get("atualizado"):
        return JSONResponse(
            status_code=409, content={"COOLStatusCode": 1010, "LOOLStatusCode": 1010}
        )
    collection: Collection = request.app.state.collection
    try:
        new = collection.substituir(id_, await request.body())
    except FileInvalid as e:
        raise HTTPException(400, str(e)) from e
    if new["status"] == "convertendo":
        tarefas.add_task(collection.convert, id_)
    return JSONResponse(
        {"LastModifiedTime": new["atualizado"]},
        headers={"X-WOPI-ItemVersion": new["sha256"]},
    )


@router.post("/files/{id_}")
def lock(id_: str, request: Request, access_token: str = "") -> Response:
    _meta(request, id_, access_token)
    locks = _locks(request)
    operation = request.headers.get("x-wopi-override", "").upper()
    pedida = request.headers.get("x-wopi-lock", "")
    old = request.headers.get("x-wopi-oldlock", "")
    with locks.mutex:
        current = locks.atual(id_)
        if operation == "GET_LOCK":
            return Response(headers={"X-WOPI-Lock": current})
        if not pedida:
            raise HTTPException(400, "Falta X-WOPI-Lock")
        if operation == "LOCK" and old:  # UnlockAndRelock
            if current != old:
                return _conflict(current, "Trava diferente")
        elif operation == "LOCK":
            if current and current != pedida:
                return _conflict(current, "Arquivo travado por outra sessao")
        elif operation in ("UNLOCK", "REFRESH_LOCK"):
            if current != pedida:
                return _conflict(current, "Trava diferente")
            if operation == "UNLOCK":
                locks.soltar(id_)
                return Response()
        else:
            raise HTTPException(501, f"X-WOPI-Override não suportado: {operation}")
        locks.travar(id_, pedida)
    return Response()


@router.get("/abrir/{id_}")
async def open_file(id_: str, request: Request, t: str = "") -> HTMLResponse:
    """Page that POSTs the token to Collabora: the desktop app (no webview) opens this URL in
    the browser. `t` is the `access_token` from `POST /api/arquivos/{id}/collabora`."""
    meta, data = _meta(request, id_, t)
    settings: Settings = request.app.state.settings
    url = await url_action(settings, meta["extensao"], id_)
    nonce = secrets.token_urlsafe(16)
    public = urlsplit(settings.collabora_url)
    origin = f"{public.scheme}://{public.netloc}"
    return HTMLResponse(
        page_form(url, t, int(data["exp"]) * 1000, meta["nome_original"], nonce),
        headers={
            # The security middleware only fills what is missing: allow the script and the POST.
            "Content-Security-Policy": (
                f"default-src 'none'; script-src 'nonce-{nonce}'; form-action {origin}; "
                "frame-ancestors 'none'"
            ),
            "Cache-Control": "no-store",
        },
    )


def page_form(url: str, token: str, ttl: int, titulo: str, nonce: str = "") -> str:
    """HTML with the self-submitting WOPI form (the app uses the same HTML in the webview)."""
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
