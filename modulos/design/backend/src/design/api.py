"""Routes of the Design module. The platform mounts the router at `/api/design` with
authentication and stores the [Frames] in `app.state`."""

import json
import re
from typing import Annotated, Any

import httpx
from fastapi import APIRouter, Depends, File, HTTPException, Request, Response, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field

from design.boards import Conflict, Frames, NotFound
from design.images import Images, Invalid

router = APIRouter(tags=["design"])


def get_frames(request: Request) -> Frames:
    frames: Frames = request.app.state.quadros_design
    return frames


FramesDep = Annotated[Frames, Depends(get_frames)]


class FrameInput(BaseModel):
    titulo: str = Field("", max_length=200)
    fundo: str = "pontos"
    pasta: str = Field("", max_length=200)


class FrameEdit(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=200)
    fundo: str | None = None
    pasta: str | None = Field(None, max_length=200)
    paginas: list[dict[str, Any]] | None = Field(None, max_length=200)


class Recording(BaseModel):
    versao: int = Field(ge=1)
    elementos: list[dict[str, Any]] = Field(max_length=50_000)


def _error(e: Exception) -> HTTPException:
    if isinstance(e, NotFound):
        return HTTPException(404, "Quadro não encontrado")
    return HTTPException(422, str(e))


@router.get("/quadros")
def list_all(quadros: FramesDep, pasta: str | None = None) -> Any:
    return quadros.list_all(pasta)


@router.post("/quadros", status_code=201)
def create(entrada: FrameInput, quadros: FramesDep) -> Any:
    try:
        return quadros.criar(entrada.model_dump())
    except Exception as e:
        raise _error(e) from e


@router.post("/quadros/importar-drawio", status_code=201)
async def import_drawio(quadros: FramesDep, arquivo: UploadFile = File(...)) -> Any:
    """Creates a board from a draw.io `.drawio`/`.xml` (all pages)."""
    from design import drawio

    raw = await arquivo.read()
    if len(raw) > 20 * 1024 * 1024:
        raise HTTPException(413, "Arquivo maior que 20 MB.")
    try:
        read = drawio.read(raw.decode("utf-8", "ignore"))
    except drawio.FileInvalid as e:
        raise HTTPException(422, str(e)) from e
    title = re.sub(r"\.(drawio|xml)$", "", arquivo.filename or "", flags=re.I) or "Diagrama"
    q = quadros.criar({"titulo": title[:200], "fundo": "grade", **read})
    return {
        **{k: v for k, v in q.items() if k != "elementos"},
        "total": len(q["elementos"]),
        "ignorados": read["ignorados"],
    }


@router.get("/quadros/{id_}/drawio")
def export_drawio(id_: str, quadros: FramesDep) -> Response:
    """The board as `.drawio`, to open and edit in draw.io/diagrams.net."""
    from design import drawio

    try:
        q = quadros.obter(id_)
    except Exception as e:
        raise _error(e) from e
    return Response(
        drawio.write(q),
        media_type="application/xml",
        headers={
            "Content-Disposition": "attachment; filename*=UTF-8''"
            + drawio.name_file(q["titulo"])
        },
    )


@router.get("/quadros/{id_}")
def get(id_: str, quadros: FramesDep) -> Any:
    try:
        return quadros.obter(id_)
    except Exception as e:
        raise _error(e) from e


@router.patch("/quadros/{id_}")
def edit(id_: str, edicao: FrameEdit, quadros: FramesDep) -> Any:
    try:
        return quadros.edit(id_, edicao.model_dump(exclude_unset=True))
    except Exception as e:
        raise _error(e) from e


@router.put("/quadros/{id_}/elementos")
def save(id_: str, g: Recording, quadros: FramesDep) -> Any:
    """409 brings the current board in `quadro`: the app merges and saves again with its version."""
    try:
        return quadros.salvar(id_, g.elementos, g.versao)
    except Conflict as e:
        body = {"error": {"message": str(e)}, "quadro": e.atual}
        return JSONResponse(status_code=409, content=body)
    except Exception as e:
        raise _error(e) from e


@router.get("/quadros/{id_}/miniatura")
def thumbnail(id_: str, quadros: FramesDep) -> FileResponse:
    try:
        return FileResponse(quadros.thumbnail(id_), media_type="image/png")
    except Exception as e:
        raise _error(e) from e


@router.post("/quadros/{id_}/miniatura", status_code=204)
async def store_thumbnail(
    id_: str, quadros: FramesDep, arquivo: Annotated[UploadFile, File()]
) -> Response:
    try:
        quadros.store_thumbnail(id_, await arquivo.read())
    except Exception as e:
        raise _error(e) from e
    return Response(status_code=204)


@router.post("/quadros/{id_}/duplicar", status_code=201)
def duplicate(id_: str, quadros: FramesDep) -> Any:
    try:
        return quadros.duplicate(id_)
    except Exception as e:
        raise _error(e) from e


@router.delete("/quadros/{id_}", status_code=204)
def delete(id_: str, quadros: FramesDep) -> Response:
    try:
        quadros.excluir(id_)
    except NotFound as e:
        raise _error(e) from e
    return Response(status_code=204)


# ---------- Wireframes ----------
# Same storage as the boards (`wireframes/`), with the `ai_wireframe` components as elements.


def get_wireframes(request: Request) -> Frames:
    wireframes: Frames = request.app.state.wireframes_design
    return wireframes


WireframesDep = Annotated[Frames, Depends(get_wireframes)]


class WireframeInput(BaseModel):
    titulo: str = Field("", max_length=200)
    pasta: str = Field("", max_length=200)


@router.get("/wireframes")
def list_wireframes(wireframes: WireframesDep) -> Any:
    return wireframes.list_all()


@router.post("/wireframes", status_code=201)
def create_wireframe(entrada: WireframeInput, wireframes: WireframesDep) -> Any:
    from design.ai_wireframe import screen_default

    title = entrada.titulo or "Wireframe sem título"
    return wireframes.criar(
        {"titulo": title, "pasta": entrada.pasta, "paginas": [screen_default()]}
    )


async def _read_package(file: UploadFile) -> dict[str, Any]:
    from design import ai_wireframe

    raw = await file.read()
    if len(raw) > 20 * 1024 * 1024:
        raise HTTPException(413, "Arquivo maior que 20 MB.")
    try:
        return ai_wireframe.read(raw)
    except ai_wireframe.FormatInvalid as e:
        raise HTTPException(422, str(e)) from e


@router.post("/wireframes/importar-ia", status_code=201)
async def import_wireframe(wireframes: WireframesDep, arquivo: UploadFile = File(...)) -> Any:
    """Creates a wireframe from the `wireframe.json` (or the ZIP) that came back from another AI."""
    return wireframes.criar(await _read_package(arquivo))


@router.get("/wireframes/{id_}")
def get_wireframe(id_: str, wireframes: WireframesDep) -> Any:
    try:
        return wireframes.obter(id_)
    except Exception as e:
        raise _error(e) from e


@router.patch("/wireframes/{id_}")
def edit_wireframe(id_: str, edicao: FrameEdit, wireframes: WireframesDep) -> Any:
    try:
        return wireframes.edit(id_, edicao.model_dump(exclude_unset=True))
    except Exception as e:
        raise _error(e) from e


@router.put("/wireframes/{id_}/elementos")
def save_wireframe(id_: str, g: Recording, wireframes: WireframesDep) -> Any:
    try:
        return wireframes.salvar(id_, g.elementos, g.versao)
    except Conflict as e:
        body = {"error": {"message": str(e)}, "quadro": e.atual}
        return JSONResponse(status_code=409, content=body)
    except Exception as e:
        raise _error(e) from e


@router.get("/wireframes/{id_}/ia")
def export_wireframe(id_: str, wireframes: WireframesDep, formato: str = "zip") -> Response:
    """Package for another AI to edit: `zip` (AGENTS.md + schema + wireframe.json + screen PNGs)
    or just the `json`. The PNGs are the last ones the app sent to `…/telas/{tela}/png`."""
    from urllib.parse import quote

    from design import ai_wireframe

    try:
        q = wireframes.obter(id_)
    except Exception as e:
        raise _error(e) from e
    name = re.sub(r"[^\w\- ]+", "_", q["titulo"]).strip() or "wireframe"
    if formato == "json":
        body = json.dumps(ai_wireframe.for_ai(q), ensure_ascii=False, indent=2).encode()
        kind, name = "application/json", f"{name}.wireframe.json"
    else:
        body = ai_wireframe.package(q, wireframes.pngs(id_))
        kind, name = "application/zip", f"{name}.wireframe.zip"
    disposicao = "attachment; filename*=UTF-8''" + quote(name)
    return Response(body, media_type=kind, headers={"Content-Disposition": disposicao})


@router.post("/wireframes/{id_}/telas/{tela}/png", status_code=204)
async def store_png_screen(
    id_: str, tela: str, wireframes: WireframesDep, arquivo: Annotated[UploadFile, File()]
) -> Response:
    """Screen render made by the app (same painter as the editor), to go into the AI package."""
    try:
        wireframes.store_png(id_, tela, await arquivo.read())
    except Exception as e:
        raise _error(e) from e
    return Response(status_code=204)


@router.post("/wireframes/{id_}/importar-ia")
async def reimport_wireframe(
    id_: str, wireframes: WireframesDep, arquivo: UploadFile = File(...)
) -> Any:
    """Replaces the content with what the AI returned (same id, new version)."""
    read = await _read_package(arquivo)
    try:
        return wireframes.substituir(id_, read)
    except Exception as e:
        raise _error(e) from e


@router.post("/wireframes/{id_}/duplicar", status_code=201)
def duplicate_wireframe(id_: str, wireframes: WireframesDep) -> Any:
    try:
        return wireframes.duplicate(id_)
    except Exception as e:
        raise _error(e) from e


@router.delete("/wireframes/{id_}", status_code=204)
def delete_wireframe(id_: str, wireframes: WireframesDep) -> Response:
    try:
        wireframes.excluir(id_)
    except NotFound as e:
        raise _error(e) from e
    return Response(status_code=204)


# ---------- Images (Google Images) ----------


def get_images(request: Request) -> Images:
    images: Images = request.app.state.imagens_design
    return images


ImagesDep = Annotated[Images, Depends(get_images)]


class RequestImage(BaseModel):
    url: str = Field(min_length=8, max_length=4000)


@router.get("/imagens/busca")
async def fetch_images(
    imagens: ImagesDep, q: str, tipo: str = "foto", pagina: int = 0
) -> list[dict[str, Any]]:
    """Google Images (or Bing/Openverse without a key); `tipo`: foto, icone, figura or todos."""
    if not q.strip():
        return []
    try:
        return await imagens.fetch(q.strip(), tipo, max(pagina, 0))
    except (Invalid, OSError, httpx.HTTPError) as e:
        raise HTTPException(503, str(e)) from e


@router.post("/imagens", status_code=201)
async def store_image(p: RequestImage, imagens: ImagesDep) -> dict[str, Any]:
    """Copies the chosen image to the server; the board `imagem` element keeps the `id`."""
    try:
        return await imagens.download(p.url)
    except Invalid as e:
        raise HTTPException(422, str(e)) from e
    except (OSError, httpx.HTTPError) as e:
        raise HTTPException(502, f"Não foi possível baixar a imagem: {e}") from e


@router.get("/imagens/{id_}")
def get_image(id_: str, imagens: ImagesDep) -> FileResponse:
    try:
        return FileResponse(imagens.caminho(id_), headers={"Cache-Control": "max-age=31536000"})
    except FileNotFoundError as e:
        raise HTTPException(404, "Imagem não encontrada") from e


# ---------- AI flowcharts ----------


def get_llms(request: Request) -> dict[str, Any]:
    """The platform's LLM providers (`local` = worker on the PC, `claude` when available)."""
    return getattr(request.app.state, "design_llms", {})


LLMsDep = Annotated[dict[str, Any], Depends(get_llms)]


class RequestFlow(BaseModel):
    pedido: str = Field("", max_length=4000)
    codigo: str = Field("", max_length=400_000)
    arquivo: str = Field("", max_length=300)
    atual: dict[str, Any] | None = None
    """Fluxo que já está no quadro (`nos`/`ligacoes`), para a IA ajustar em vez de criar do zero."""
    provedor: str = "local"


@router.get("/fluxos/provedores")
def providers_flow(llms: LLMsDep) -> list[str]:
    return sorted(llms)


# Generations in progress (in memory): the AI can take minutes with large code, and Cloudflare
# cuts responses that take more than 100 s to start; the app creates the task and polls until done.
_TASKS: dict[str, dict[str, Any]] = {}
_MAX_TASKS = 50


@router.post("/fluxos/gerar", status_code=202)
async def generate_flow(p: RequestFlow, llms: LLMsDep) -> dict[str, Any]:
    """Starts generating the flowchart (structure from the AI, layered positions, see `flows`);
    returns the task id for `GET /fluxos/tarefas/{id}`."""
    import asyncio
    import uuid

    from design import flows

    if not (p.pedido.strip() or p.codigo.strip() or p.atual):
        raise HTTPException(422, "Descreva o fluxo, envie um código ou peça um ajuste.")
    llm = llms.get(p.provedor)
    if llm is None:
        raise HTTPException(503, f"IA '{p.provedor}' indisponível.")
    tid = uuid.uuid4().hex[:12]
    task: dict[str, Any] = {"estado": "gerando"}

    async def rodar() -> None:
        try:
            task.update(
                estado="pronto",
                fluxo=await flows.generate(llm, p.pedido, p.codigo, p.arquivo, p.atual),
            )
        except flows.FlowInvalid as e:
            task.update(estado="erro", erro=str(e))
        except Exception as e:  # worker off, timeout, API down
            task.update(estado="erro", erro=f"A IA não respondeu: {e}")

    while len(_TASKS) >= _MAX_TASKS:
        _TASKS.pop(next(iter(_TASKS)))
    _TASKS[tid] = task
    task["_task"] = asyncio.create_task(rodar())
    return {"id": tid, "estado": "gerando"}


@router.get("/fluxos/tarefas/{tid}")
def task_flow(tid: str) -> dict[str, Any]:
    t = _TASKS.get(tid)
    if t is None:
        raise HTTPException(404, "Tarefa não encontrada (o servidor reiniciou?).")
    return {k: v for k, v in t.items() if not k.startswith("_")}
