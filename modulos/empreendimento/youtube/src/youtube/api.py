"""YouTube channel routes. The platform mounts the router at `/api/youtube` with authentication and
keeps the [Youtube] in `app.state.youtube`. The notes stay visible at `/api/notas`."""

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
        raise HTTPException(404, str(e.args[0]) if e.args else "Not found") from e
    except ValueError as e:
        raise HTTPException(409, str(e)) from e


@router.get("/esquema")
def schema(yt: YoutubeDep) -> Any:
    return yt.schema()


@router.post("/importar")
def run_import(payload: Import, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.run_import(payload.substituir))


@router.get("/canais")
def channels(yt: YoutubeDep) -> Any:
    return yt.channels()


@router.post("/canais", status_code=201)
def create_channel(payload: ChannelInput, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.create_channel(payload.model_dump()))


@router.get("/canais/{slug}")
def channel(slug: str, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.channel(slug))


@router.patch("/canais/{slug}")
def edit_channel(slug: str, changes: ChannelEdit, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.edit_channel(slug, changes.model_dump()))


@router.delete("/canais/{slug}", status_code=204)
def delete_channel(slug: str, yt: YoutubeDep) -> Response:
    _call(lambda: yt.delete_channel(slug))
    return Response(status_code=204)


@router.get("/canais/{slug}/{collection}")
def items(
    slug: str, collection: str, yt: YoutubeDep, q: str = "", status: str | None = None
) -> Any:
    return _call(lambda: yt.items(slug, collection, q, status))


@router.post("/canais/{slug}/{collection}", status_code=201)
def create(slug: str, collection: str, payload: ItemInput, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.create(slug, collection, payload.model_dump()))


@router.get("/canais/{slug}/{collection}/{id_}")
def item(slug: str, collection: str, id_: str, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.item(slug, collection, id_))


@router.patch("/canais/{slug}/{collection}/{id_}")
def edit(slug: str, collection: str, id_: str, changes: ItemEdit, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.edit(slug, collection, id_, changes.model_dump()))


@router.delete("/canais/{slug}/{collection}/{id_}", status_code=204)
def delete(slug: str, collection: str, id_: str, yt: YoutubeDep) -> Response:
    _call(lambda: yt.delete(slug, collection, id_))
    return Response(status_code=204)


@router.post("/canais/{slug}/temas/{id_}/derivar", status_code=201)
def derive(slug: str, id_: str, payload: Derivation, yt: YoutubeDep) -> Any:
    return _call(lambda: yt.derive(slug, id_, payload.colecao))
