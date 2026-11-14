"""Rotas dos canais do YouTube. A plataforma monta o router em `/api/youtube` com a autenticação e
guarda o [Youtube] em `app.state.youtube`. As notas continuam visíveis em `/api/notas`."""

from collections.abc import Callable
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from youtube.channels import Youtube

router = APIRouter(tags=["youtube"])


def get_youtube(request: Request) -> Youtube:
    youtube: Youtube = request.app.state.youtube
    return youtube


YoutubeDep = Annotated[Youtube, Depends(get_youtube)]


class ChannelInput(BaseModel):
    slug: str = Field(min_length=1, max_length=41)
    titulo: str = Field(min_length=1, max_length=200)
    nome: str = Field("", max_length=100)
    status: str = "ideia"
    tags: list[str] = []
    corpo: str = ""


class ChannelEdit(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=200)
    nome: str | None = Field(None, max_length=100)
    status: str | None = None
    tags: list[str] | None = None
    corpo: str | None = None


class ItemInput(BaseModel):
    titulo: str = Field(min_length=1, max_length=200)
    propriedades: dict[str, Any] = {}
    tags: list[str] = []
    corpo: str = ""


class ItemEdit(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=200)
    propriedades: dict[str, Any] | None = None
    tags: list[str] | None = None
    corpo: str | None = None


class Derivation(BaseModel):
    colecao: str = Field(pattern="^(roteiros|historias)$")


class Import(BaseModel):
    substituir: bool = False


def _call(f: Callable[[], Any]) -> Any:
    try:
        return f()
    except KeyError as e:
        raise HTTPException(404, str(e.args[0]) if e.args else "Não encontrado") from e
    except ValueError as e:
        raise HTTPException(409, str(e)) from e


@router.get("/esquema")
def schema(yt: YoutubeDep) -> Any:
    return yt.schema()


@router.post("/importar")
def run_import(entrada: Import, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.run_import(entrada.substituir))


@router.get("/canais")
def channels(yt: YoutubeDep) -> Any:
    return yt.channels()


@router.post("/canais", status_code=201)
def create_channel(entrada: ChannelInput, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.create_channel(entrada.model_dump()))


@router.get("/canais/{slug}")
def channel(slug: str, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.canal(slug))


@router.patch("/canais/{slug}")
def edit_channel(slug: str, edicao: ChannelEdit, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.edit_channel(slug, edicao.model_dump()))


@router.delete("/canais/{slug}", status_code=204)
def delete_channel(slug: str, yt: YoutubeDep) -> Response:
    _call(lambda: yt.delete_channel(slug))
    return Response(status_code=204)


@router.get("/canais/{slug}/{colecao}")
def items(slug: str, colecao: str, yt: YoutubeDep, q: str = "", status: str | None = None) -> Any:
    return _call(lambda: yt.itens(slug, colecao, q, status))


@router.post("/canais/{slug}/{colecao}", status_code=201)
def create(slug: str, colecao: str, entrada: ItemInput, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.criar(slug, colecao, entrada.model_dump()))


@router.get("/canais/{slug}/{colecao}/{id_}")
def item(slug: str, colecao: str, id_: str, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.item(slug, colecao, id_))


@router.patch("/canais/{slug}/{colecao}/{id_}")
def edit(slug: str, colecao: str, id_: str, edicao: ItemEdit, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.edit(slug, colecao, id_, edicao.model_dump()))


@router.delete("/canais/{slug}/{colecao}/{id_}", status_code=204)
def delete(slug: str, colecao: str, id_: str, yt: YoutubeDep) -> Response:
    _call(lambda: yt.excluir(slug, colecao, id_))
    return Response(status_code=204)


@router.post("/canais/{slug}/temas/{id_}/derivar", status_code=201)
def derive(slug: str, id_: str, entrada: Derivation, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.derive(slug, id_, entrada.colecao))
