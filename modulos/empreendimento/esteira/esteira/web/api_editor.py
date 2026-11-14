"""API do editor manual (gráficos e thumbnails) para o app Flutter.

O estado é o mesmo do editor do painel (`esteira/editor.py`). A diferença é a prévia: o app pede o quadro
pronto em PNG (`/editor/quadro`, renderizado por `web/quadros.py`) em vez de embutir o HTML do modelo.
"""
import asyncio
import json

from esteira import editor
from esteira.web import api, fila, quadros
from fastapi import APIRouter, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

router = APIRouter(prefix="/api/v1/episodios/{ep}/editor", tags=["editor"])


def _contexto(p, tipo):
    rot = api._json(p.caminho("roteiro.json"), {}) or {}
    return {"tipo": tipo, "motor": p.cfg.get("editor", {}).get("motor_ia", "claude"),
            "cor": p.cfg.get("graficos", {}).get("cor", "#ffd400"),
            "citacoes": [{k: c.get(k) for k in ("autores", "ano", "revista", "pt")} for c in rot.get("citacoes", [])]}


@router.get("/grafico/{i}")
def abrir_grafico(ep: str, i: int, t: float = 0.0):
    """Estado da peça `i` do graficos.json; i < 0 → peça nova de caixas no instante `t`."""
    p = api._projeto(ep)
    total = len(editor.graficos(p))
    if i >= total:
        raise HTTPException(404, "gráfico não encontrado")
    w, h = editor._dim(p)
    return _contexto(p, "grafico") | {"i": i, "estado": editor.estado_grafico(p, i, t), "w": w, "h": h,
                                      "modelos": list(editor.MODELOS), "total": total}


@router.get("/thumb")
def abrir_thumb(ep: str, arquivo: str = "", fundo: str = ""):
    p = api._projeto(ep)
    fundos = editor.fundos(p)
    if not fundos:
        raise HTTPException(404, "sem fundos: rode a etapa thumb ou envie uma imagem em Thumbs")
    estado = next((t["estado"] for t in editor.thumbs(p) if t["arquivo"] == arquivo), None) or {
        "texto": "TEXTO DA THUMB", "destaque": "", "layout": "rosto_direita", "seta": False,
        "fundo": fundo if fundo in fundos else fundos[0]}
    w, h = editor._dim_thumb(p)
    return _contexto(p, "thumb") | {"estado": estado, "w": w, "h": h, "fundos": fundos,
                                    "fundos_url": {f: f"/arq/{ep}/thumbs/{f}" for f in fundos}}


class Quadro(BaseModel):
    tipo: str = "grafico"
    estado: dict
    t: float = 0.0


@router.post("/quadro")
def quadro(ep: str, corpo: Quadro):
    """PNG da prévia: gráfico com fundo transparente no instante `t`; thumb inteira."""
    p = api._projeto(ep)
    try:
        if corpo.tipo == "thumb":
            html, w, h = editor.html_thumb(p, corpo.estado)
        else:
            html, w, h = editor.html_grafico(p, corpo.estado)
    except (ValueError, KeyError, TypeError) as e:
        raise HTTPException(400, str(e))
    png = quadros.quadro(html, w, h, corpo.t, transparente=corpo.tipo != "thumb")
    return Response(png, media_type="image/png", headers={"Cache-Control": "no-store"})


@router.post("/grafico/{i}")
def salvar_grafico(ep: str, i: int, estado: dict):
    """Grava a peça (vira `manual`) e põe só a renderização das peças mudadas na fila."""
    p = api._projeto(ep)
    try:
        novo = editor.salvar_grafico(p, i, estado)
    except (ValueError, KeyError, TypeError, IndexError) as e:
        raise HTTPException(400, str(e))
    fila.adicionar(ep, "graficos", ["--so-render"])
    return {"i": novo}


@router.post("/grafico/{i}/excluir")
def excluir_grafico(ep: str, i: int):
    p = api._projeto(ep)
    if not 0 <= i < len(editor.graficos(p)):
        raise HTTPException(404, "gráfico não encontrado")
    editor.excluir_grafico(p, i)
    return {"ok": True}


@router.post("/thumb")
def salvar_thumb(ep: str, estado: dict):
    try:
        return {"arquivo": editor.salvar_thumb(api._projeto(ep), estado)}
    except (ValueError, KeyError, TypeError) as e:
        raise HTTPException(400, str(e))


class Pedido(BaseModel):
    tipo: str = "grafico"
    estado: dict
    pedido: str
    motor: str = "claude"


@router.post("/ia")
async def sugerir(ep: str, corpo: Pedido):
    """Assistente: devolve um estado novo para a prévia (nada é salvo sem o usuário)."""
    from esteira.core import locks
    if not corpo.pedido.strip():
        raise HTTPException(400, "escreva o pedido")
    if corpo.motor == "local" and not locks.is_free("machine"):
        d = locks.owner("machine")
        raise HTTPException(409, f"a máquina está ocupada por `{d['command']}`: só um processo local por vez. "
                                 "Use o motor Claude ou espere terminar.")
    p = api._projeto(ep)
    try:
        novo, explicacao, avisos = await asyncio.to_thread(
            editor.sugerir, p, ep, corpo.estado, corpo.pedido.strip(), corpo.motor, corpo.tipo)
    except (ValueError, KeyError, TypeError) as e:
        raise HTTPException(400, str(e))
    return {"estado": json.loads(json.dumps(novo, default=str)), "explicacao": explicacao, "avisos": avisos}

