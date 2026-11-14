"""API do editor manual (gráficos e thumbnails) para o app Flutter.

O estado é o mesmo do editor do painel (`esteira/editor.py`). A diferença é a prévia: o app pede o quadro
pronto em PNG (`/editor/quadro`, renderizado por `web/frames.py`) em vez de embutir o HTML do modelo.
"""
import asyncio
import json

from esteira import editor
from esteira.web import api, queue, frames
from fastapi import APIRouter, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

router = APIRouter(prefix="/api/v1/episodios/{ep}/editor", tags=["editor"])


def _context(p, tipo):
    rot = api._json(p.caminho("roteiro.json"), {}) or {}
    return {"tipo": tipo, "motor": p.cfg.get("editor", {}).get("motor_ia", "claude"),
            "cor": p.cfg.get("graficos", {}).get("cor", "#ffd400"),
            "citacoes": [{k: c.get(k) for k in ("autores", "ano", "revista", "pt")} for c in rot.get("citacoes", [])]}


@router.get("/grafico/{i}")
def open_graphic(ep: str, i: int, t: float = 0.0):
    """Estado da peça `i` do graficos.json; i < 0 → peça nova de caixas no instante `t`."""
    p = api._project(ep)
    total = len(editor.graphics(p))
    if i >= total:
        raise HTTPException(404, "gráfico não encontrado")
    w, h = editor._dim(p)
    return _context(p, "grafico") | {"i": i, "estado": editor.state_graphic(p, i, t), "w": w, "h": h,
                                      "modelos": list(editor.MODELS), "total": total}


@router.get("/thumb")
def open_thumb(ep: str, arquivo: str = "", fundo: str = ""):
    p = api._project(ep)
    backgrounds = editor.backgrounds(p)
    if not backgrounds:
        raise HTTPException(404, "sem fundos: rode a etapa thumb ou envie uma imagem em Thumbs")
    state = next((t["estado"] for t in editor.thumbs(p) if t["arquivo"] == arquivo), None) or {
        "texto": "TEXTO DA THUMB", "destaque": "", "layout": "rosto_direita", "seta": False,
        "fundo": fundo if fundo in backgrounds else backgrounds[0]}
    w, h = editor._dim_thumb(p)
    return _context(p, "thumb") | {"estado": state, "w": w, "h": h, "fundos": backgrounds,
                                    "fundos_url": {f: f"/arq/{ep}/thumbs/{f}" for f in backgrounds}}


class Frame(BaseModel):
    tipo: str = "grafico"
    estado: dict
    t: float = 0.0


@router.post("/quadro")
def frame(ep: str, corpo: Frame):
    """PNG da prévia: gráfico com fundo transparente no instante `t`; thumb inteira."""
    p = api._project(ep)
    try:
        if corpo.tipo == "thumb":
            html, w, h = editor.html_thumb(p, corpo.estado)
        else:
            html, w, h = editor.html_graphic(p, corpo.estado)
    except (ValueError, KeyError, TypeError) as e:
        raise HTTPException(400, str(e))
    png = frames.frame(html, w, h, corpo.t, transparente=corpo.tipo != "thumb")
    return Response(png, media_type="image/png", headers={"Cache-Control": "no-store"})


@router.post("/grafico/{i}")
def save_graphic(ep: str, i: int, estado: dict):
    """Grava a peça (vira `manual`) e põe só a renderização das peças mudadas na fila."""
    p = api._project(ep)
    try:
        new = editor.save_graphic(p, i, estado)
    except (ValueError, KeyError, TypeError, IndexError) as e:
        raise HTTPException(400, str(e))
    queue.add(ep, "graphics", ["--render-only"])
    return {"i": new}


@router.post("/grafico/{i}/excluir")
def delete_graphic(ep: str, i: int):
    p = api._project(ep)
    if not 0 <= i < len(editor.graphics(p)):
        raise HTTPException(404, "gráfico não encontrado")
    editor.delete_graphic(p, i)
    return {"ok": True}


@router.post("/thumb")
def save_thumb(ep: str, estado: dict):
    try:
        return {"arquivo": editor.save_thumb(api._project(ep), estado)}
    except (ValueError, KeyError, TypeError) as e:
        raise HTTPException(400, str(e))


class Request(BaseModel):
    tipo: str = "grafico"
    estado: dict
    pedido: str
    motor: str = "claude"


@router.post("/ia")
async def suggest(ep: str, corpo: Request):
    """Assistente: devolve um estado novo para a prévia (nada é salvo sem o usuário)."""
    from esteira.core import locks
    if not corpo.pedido.strip():
        raise HTTPException(400, "escreva o pedido")
    if corpo.motor == "local" and not locks.is_free("machine"):
        d = locks.owner("machine")
        raise HTTPException(409, f"a máquina está ocupada por `{d['command']}`: só um processo local por vez. "
                                 "Use o motor Claude ou espere terminar.")
    p = api._project(ep)
    try:
        new, explanation, warnings = await asyncio.to_thread(
            editor.suggest, p, ep, corpo.estado, corpo.pedido.strip(), corpo.motor, corpo.tipo)
    except (ValueError, KeyError, TypeError) as e:
        raise HTTPException(400, str(e))
    return {"estado": json.loads(json.dumps(new, default=str)), "explicacao": explanation, "avisos": warnings}

