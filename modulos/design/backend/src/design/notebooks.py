"""Cadernos de anotação à caneta: a mesma guarda dos quadros (pasta `cadernos/`), com o papel de
cada folha (`papel` em cada item de `paginas`: pauta, espaço, tamanho, cor), como veio do app.
A plataforma monta este router em `/api/design` e a guarda em `app.state.cadernos_design`."""

from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, HTTPException, Request, Response, UploadFile
from fastapi.responses import FileResponse, JSONResponse

from design.api import Recording, FrameEdit, FrameInput
from design.boards import Conflict, NotFound, Frames

router = APIRouter(tags=["design"])


def get_notebooks(request: Request) -> Frames:
    notebooks: Frames = request.app.state.cadernos_design
    return notebooks


NotebooksDep = Annotated[Frames, Depends(get_notebooks)]


def _error(e: Exception) -> HTTPException:
    if isinstance(e, NotFound):
        return HTTPException(404, "Caderno não encontrado")
    return HTTPException(422, str(e))


@router.get("/cadernos")
def list_all(cadernos: NotebooksDep) -> Any:
    return cadernos.list_all()


@router.post("/cadernos", status_code=201)
def create(entrada: FrameInput, cadernos: NotebooksDep) -> Any:
    fields = entrada.model_dump()
    fields["titulo"] = fields["titulo"] or "Caderno sem título"
    try:
        return cadernos.criar(fields)
    except Exception as e:
        raise _error(e) from e


@router.get("/cadernos/{id_}")
def get(id_: str, cadernos: NotebooksDep) -> Any:
    try:
        return cadernos.obter(id_)
    except Exception as e:
        raise _error(e) from e


@router.get("/cadernos/{id_}/drawio")
def export_drawio(id_: str, cadernos: NotebooksDep) -> Response:
    from design import drawio

    try:
        q = cadernos.obter(id_)
    except Exception as e:
        raise _error(e) from e
    name = drawio.name_file(q["titulo"])
    return Response(
        drawio.write(q),
        media_type="application/xml",
        headers={"Content-Disposition": "attachment; filename*=UTF-8''" + name},
    )


@router.patch("/cadernos/{id_}")
def edit(id_: str, edicao: FrameEdit, cadernos: NotebooksDep) -> Any:
    try:
        return cadernos.edit(id_, edicao.model_dump(exclude_unset=True))
    except Exception as e:
        raise _error(e) from e


@router.put("/cadernos/{id_}/elementos")
def save(id_: str, g: Recording, cadernos: NotebooksDep) -> Any:
    try:
        return cadernos.salvar(id_, g.elementos, g.versao)
    except Conflict as e:
        body = {"error": {"message": str(e)}, "quadro": e.atual}
        return JSONResponse(status_code=409, content=body)
    except Exception as e:
        raise _error(e) from e


@router.get("/cadernos/{id_}/miniatura")
def thumbnail(id_: str, cadernos: NotebooksDep) -> FileResponse:
    try:
        return FileResponse(cadernos.thumbnail(id_), media_type="image/png")
    except Exception as e:
        raise _error(e) from e


@router.post("/cadernos/{id_}/miniatura", status_code=204)
async def store_thumbnail(
    id_: str, cadernos: NotebooksDep, arquivo: Annotated[UploadFile, File()]
) -> Response:
    try:
        cadernos.store_thumbnail(id_, await arquivo.read())
    except Exception as e:
        raise _error(e) from e
    return Response(status_code=204)


@router.post("/cadernos/{id_}/duplicar", status_code=201)
def duplicate(id_: str, cadernos: NotebooksDep) -> Any:
    try:
        return cadernos.duplicate(id_)
    except Exception as e:
        raise _error(e) from e


@router.delete("/cadernos/{id_}", status_code=204)
def delete(id_: str, cadernos: NotebooksDep) -> Response:
    try:
        cadernos.excluir(id_)
    except NotFound as e:
        raise _error(e) from e
    return Response(status_code=204)
