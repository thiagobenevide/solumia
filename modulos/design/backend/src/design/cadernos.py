"""Cadernos de anotação à caneta: a mesma guarda dos quadros (pasta `cadernos/`), com o papel de
cada folha (`papel` em cada item de `paginas`: pauta, espaço, tamanho, cor), como veio do app.
A plataforma monta este router em `/api/design` e a guarda em `app.state.cadernos_design`."""

from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, HTTPException, Request, Response, UploadFile
from fastapi.responses import FileResponse, JSONResponse

from design.api import Gravacao, QuadroEdicao, QuadroEntrada
from design.quadros import Conflito, NaoEncontrado, Quadros

router = APIRouter(tags=["design"])


def get_cadernos(request: Request) -> Quadros:
    cadernos: Quadros = request.app.state.cadernos_design
    return cadernos


CadernosDep = Annotated[Quadros, Depends(get_cadernos)]


def _erro(e: Exception) -> HTTPException:
    if isinstance(e, NaoEncontrado):
        return HTTPException(404, "Caderno não encontrado")
    return HTTPException(422, str(e))


@router.get("/cadernos")
def listar(cadernos: CadernosDep) -> Any:
    return cadernos.listar()


@router.post("/cadernos", status_code=201)
def criar(entrada: QuadroEntrada, cadernos: CadernosDep) -> Any:
    campos = entrada.model_dump()
    campos["titulo"] = campos["titulo"] or "Caderno sem título"
    try:
        return cadernos.criar(campos)
    except Exception as e:
        raise _erro(e) from e


@router.get("/cadernos/{id_}")
def obter(id_: str, cadernos: CadernosDep) -> Any:
    try:
        return cadernos.obter(id_)
    except Exception as e:
        raise _erro(e) from e


@router.get("/cadernos/{id_}/drawio")
def exportar_drawio(id_: str, cadernos: CadernosDep) -> Response:
    from design import drawio

    try:
        q = cadernos.obter(id_)
    except Exception as e:
        raise _erro(e) from e
    nome = drawio.nome_arquivo(q["titulo"])
    return Response(
        drawio.escrever(q),
        media_type="application/xml",
        headers={"Content-Disposition": "attachment; filename*=UTF-8''" + nome},
    )


@router.patch("/cadernos/{id_}")
def editar(id_: str, edicao: QuadroEdicao, cadernos: CadernosDep) -> Any:
    try:
        return cadernos.editar(id_, edicao.model_dump(exclude_unset=True))
    except Exception as e:
        raise _erro(e) from e


@router.put("/cadernos/{id_}/elementos")
def salvar(id_: str, g: Gravacao, cadernos: CadernosDep) -> Any:
    try:
        return cadernos.salvar(id_, g.elementos, g.versao)
    except Conflito as e:
        corpo = {"error": {"message": str(e)}, "quadro": e.atual}
        return JSONResponse(status_code=409, content=corpo)
    except Exception as e:
        raise _erro(e) from e


@router.get("/cadernos/{id_}/miniatura")
def miniatura(id_: str, cadernos: CadernosDep) -> FileResponse:
    try:
        return FileResponse(cadernos.miniatura(id_), media_type="image/png")
    except Exception as e:
        raise _erro(e) from e


@router.post("/cadernos/{id_}/miniatura", status_code=204)
async def guardar_miniatura(
    id_: str, cadernos: CadernosDep, arquivo: Annotated[UploadFile, File()]
) -> Response:
    try:
        cadernos.guardar_miniatura(id_, await arquivo.read())
    except Exception as e:
        raise _erro(e) from e
    return Response(status_code=204)


@router.post("/cadernos/{id_}/duplicar", status_code=201)
def duplicar(id_: str, cadernos: CadernosDep) -> Any:
    try:
        return cadernos.duplicar(id_)
    except Exception as e:
        raise _erro(e) from e


@router.delete("/cadernos/{id_}", status_code=204)
def excluir(id_: str, cadernos: CadernosDep) -> Response:
    try:
        cadernos.excluir(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e
    return Response(status_code=204)
