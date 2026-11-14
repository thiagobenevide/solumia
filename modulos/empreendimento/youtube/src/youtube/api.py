"""Rotas dos canais do YouTube. A plataforma monta o router em `/api/youtube` com a autenticação e
guarda o [Youtube] em `app.state.youtube`. As notas continuam visíveis em `/api/notas`."""

from collections.abc import Callable
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from youtube.canais import Youtube

router = APIRouter(tags=["youtube"])


def get_youtube(request: Request) -> Youtube:
    youtube: Youtube = request.app.state.youtube
    return youtube


YoutubeDep = Annotated[Youtube, Depends(get_youtube)]


class CanalEntrada(BaseModel):
    slug: str = Field(min_length=1, max_length=41)
    titulo: str = Field(min_length=1, max_length=200)
    nome: str = Field("", max_length=100)
    status: str = "ideia"
    tags: list[str] = []
    corpo: str = ""


class CanalEdicao(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=200)
    nome: str | None = Field(None, max_length=100)
    status: str | None = None
    tags: list[str] | None = None
    corpo: str | None = None


class ItemEntrada(BaseModel):
    titulo: str = Field(min_length=1, max_length=200)
    propriedades: dict[str, Any] = {}
    tags: list[str] = []
    corpo: str = ""


class ItemEdicao(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=200)
    propriedades: dict[str, Any] | None = None
    tags: list[str] | None = None
    corpo: str | None = None


class Derivacao(BaseModel):
    colecao: str = Field(pattern="^(roteiros|historias)$")


class Importacao(BaseModel):
    substituir: bool = False


def _chamar(f: Callable[[], Any]) -> Any:
    try:
        return f()
    except KeyError as e:
        raise HTTPException(404, str(e.args[0]) if e.args else "Não encontrado") from e
    except ValueError as e:
        raise HTTPException(409, str(e)) from e


@router.get("/esquema")
def esquema(yt: YoutubeDep) -> Any:
    return yt.esquema()


@router.post("/importar")
def importar(entrada: Importacao, yt: YoutubeDep) -> Any:
    return _chamar(lambda: yt.importar(entrada.substituir))


@router.get("/canais")
def canais(yt: YoutubeDep) -> Any:
    return yt.canais()


@router.post("/canais", status_code=201)
def criar_canal(entrada: CanalEntrada, yt: YoutubeDep) -> Any:
    return _chamar(lambda: yt.criar_canal(entrada.model_dump()))


@router.get("/canais/{slug}")
def canal(slug: str, yt: YoutubeDep) -> Any:
    return _chamar(lambda: yt.canal(slug))


@router.patch("/canais/{slug}")
def editar_canal(slug: str, edicao: CanalEdicao, yt: YoutubeDep) -> Any:
    return _chamar(lambda: yt.editar_canal(slug, edicao.model_dump()))


@router.delete("/canais/{slug}", status_code=204)
def excluir_canal(slug: str, yt: YoutubeDep) -> Response:
    _chamar(lambda: yt.excluir_canal(slug))
    return Response(status_code=204)


@router.get("/canais/{slug}/{colecao}")
def itens(slug: str, colecao: str, yt: YoutubeDep, q: str = "", status: str | None = None) -> Any:
    return _chamar(lambda: yt.itens(slug, colecao, q, status))


@router.post("/canais/{slug}/{colecao}", status_code=201)
def criar(slug: str, colecao: str, entrada: ItemEntrada, yt: YoutubeDep) -> Any:
    return _chamar(lambda: yt.criar(slug, colecao, entrada.model_dump()))


@router.get("/canais/{slug}/{colecao}/{id_}")
def item(slug: str, colecao: str, id_: str, yt: YoutubeDep) -> Any:
    return _chamar(lambda: yt.item(slug, colecao, id_))


@router.patch("/canais/{slug}/{colecao}/{id_}")
def editar(slug: str, colecao: str, id_: str, edicao: ItemEdicao, yt: YoutubeDep) -> Any:
    return _chamar(lambda: yt.editar(slug, colecao, id_, edicao.model_dump()))


@router.delete("/canais/{slug}/{colecao}/{id_}", status_code=204)
def excluir(slug: str, colecao: str, id_: str, yt: YoutubeDep) -> Response:
    _chamar(lambda: yt.excluir(slug, colecao, id_))
    return Response(status_code=204)


@router.post("/canais/{slug}/temas/{id_}/derivar", status_code=201)
def derivar(slug: str, id_: str, entrada: Derivacao, yt: YoutubeDep) -> Any:
    return _chamar(lambda: yt.derivar(slug, id_, entrada.colecao))
