"""Routes of the Electronics module. The platform mounts the router at `/api/eletronica` with
authentication and stores the [Projects] in `app.state`."""

import re
from typing import Annotated, Any

import httpx
from fastapi import APIRouter, Depends, File, HTTPException, Request, Response, UploadFile
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from electronics import kicad
from electronics.libraries import SUGGESTED, Libraries, LibraryNotFound, NameInvalid
from electronics.library import SYMBOLS
from electronics.netlist import bom, bom_csv, netlist
from electronics.projects import Conflict, NotFound, Projects

router = APIRouter(tags=["eletronica"])


def get_projects(request: Request) -> Projects:
    projects: Projects = request.app.state.projetos_eletronica
    return projects


ProjectsDep = Annotated[Projects, Depends(get_projects)]


def get_libraries(request: Request) -> Libraries:
    libraries: Libraries = request.app.state.bibliotecas_eletronica
    return libraries


LibrariesDep = Annotated[Libraries, Depends(get_libraries)]

# Official libraries as a single file (from KiCad 10 on they became `.kicad_symdir` folders).
URL_KICAD = "https://gitlab.com/kicad/libraries/kicad-symbols/-/raw/{versao}/{nome}.kicad_sym"
MAX_FILE = 40 * 1024 * 1024


class ProjectInput(BaseModel):
    titulo: str = Field("", max_length=200)
    pasta: str = Field("", max_length=200)


class ProjectEdit(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=200)
    pasta: str | None = Field(None, max_length=200)


class Recording(BaseModel):
    versao: int = Field(ge=1)
    folhas: list[dict[str, Any]] = Field(min_length=1, max_length=200)
    componentes: list[dict[str, Any]] = Field(default_factory=list, max_length=20_000)
    fios: list[dict[str, Any]] = Field(default_factory=list, max_length=50_000)
    rotulos: list[dict[str, Any]] = Field(default_factory=list, max_length=20_000)
    textos: list[dict[str, Any]] = Field(default_factory=list, max_length=5_000)
    sondas: list[dict[str, Any]] = Field(default_factory=list, max_length=64)


def _error(e: Exception) -> HTTPException:
    if isinstance(e, NotFound):
        return HTTPException(404, "Projeto não encontrado")
    return HTTPException(422, str(e))


def _get(projects: Projects, id_: str) -> dict[str, Any]:
    try:
        return projects.obter(id_)
    except Exception as e:
        raise _error(e) from e


@router.get("/biblioteca")
def collection() -> Any:
    return SYMBOLS


class Ids(BaseModel):
    ids: list[str] = Field(max_length=2000)


class RequestKicad(BaseModel):
    nomes: list[str] = Field(min_length=1, max_length=60)


@router.get("/biblioteca/busca")
def fetch_symbols(
    bibliotecas: LibrariesDep, q: str = "", biblioteca: str | None = None, limite: int = 60
) -> Any:
    """Imported symbols with all the words of `q` (name, value, description, keywords)."""
    return bibliotecas.fetch(q, biblioteca, min(max(limite, 1), 200))


@router.post("/biblioteca/simbolos")
def symbols(pedido: Ids, bibliotecas: LibrariesDep) -> Any:
    """The requested symbols (base or imported) that exist; the app asks for the project's on
    open."""
    return bibliotecas.varios(pedido.ids)


@router.get("/bibliotecas")
def list_libraries(bibliotecas: LibrariesDep) -> Any:
    return bibliotecas.list_all()


@router.post("/bibliotecas/importar", status_code=201)
async def import_collection(
    bibliotecas: LibrariesDep, arquivo: Annotated[UploadFile, File()]
) -> Any:
    """A `.kicad_sym` sent by the app; the file name becomes the library name."""
    raw = await arquivo.read()
    if len(raw) > MAX_FILE:
        raise HTTPException(413, "Arquivo maior que 40 MB.")
    name = re.sub(r"\.kicad_sym$", "", arquivo.filename or "", flags=re.I)
    name = re.sub(r"[^A-Za-z0-9_.+-]+", "_", name).strip("_") or "Importada"
    try:
        symbols = kicad.read_collection(raw.decode("utf-8", "replace"), name)
        return bibliotecas.store(name, symbols, "arquivo")
    except (kicad.FileInvalid, NameInvalid) as e:
        raise HTTPException(422, str(e)) from e


@router.get("/bibliotecas/kicad")
def kicad_suggested(request: Request) -> Any:
    return {"versao": request.app.state.eletronica_kicad_versao, "sugeridas": SUGGESTED}


@router.post("/bibliotecas/kicad")
async def download_kicad(pedido: RequestKicad, request: Request, bibliotecas: LibrariesDep) -> Any:
    """Downloads the requested official libraries from the KiCad GitLab and imports each one;
    returns one line per name (`total` or `erro`)."""
    version = request.app.state.eletronica_kicad_versao
    output: list[dict[str, Any]] = []
    async with httpx.AsyncClient(timeout=60, follow_redirects=True) as http:
        for name in pedido.nomes:
            try:
                Libraries.validate_name(name)
                r = await http.get(URL_KICAD.format(versao=version, nome=name))
                if r.status_code != 200 or not r.text.lstrip().startswith("(kicad_symbol_lib"):
                    raise kicad.FileInvalid(
                        f"não achou no KiCad {version} (HTTP {r.status_code})"
                    )
                symbols = kicad.read_collection(r.text, name)
                output.append(bibliotecas.store(name, symbols, f"kicad {version}"))
            except (httpx.HTTPError, kicad.FileInvalid, NameInvalid) as e:
                output.append({"nome": name, "erro": str(e) or type(e).__name__})
    return output


@router.delete("/bibliotecas/{nome}", status_code=204)
def remove_collection(nome: str, bibliotecas: LibrariesDep) -> Response:
    try:
        bibliotecas.remover(nome)
    except LibraryNotFound as e:
        raise HTTPException(404, "Biblioteca não encontrada") from e
    return Response(status_code=204)


@router.get("/projetos")
def list_all(projetos: ProjectsDep, pasta: str | None = None) -> Any:
    return projetos.list_all(pasta)


@router.post("/projetos", status_code=201)
def create(entrada: ProjectInput, projetos: ProjectsDep) -> Any:
    try:
        return projetos.criar(entrada.model_dump())
    except Exception as e:
        raise _error(e) from e


@router.get("/projetos/{id_}")
def get(id_: str, projetos: ProjectsDep) -> Any:
    return _get(projetos, id_)


@router.patch("/projetos/{id_}")
def edit(id_: str, edicao: ProjectEdit, projetos: ProjectsDep) -> Any:
    try:
        return projetos.edit(id_, edicao.model_dump(exclude_unset=True))
    except Exception as e:
        raise _error(e) from e


@router.put("/projetos/{id_}/esquematico")
def save(id_: str, g: Recording, projetos: ProjectsDep) -> Any:
    """409 brings the current project in `projeto`: the app decides between reloading and
    overwriting."""
    try:
        return projetos.salvar(id_, g.model_dump(exclude={"versao"}), g.versao)
    except Conflict as e:
        body = {"error": {"message": str(e)}, "projeto": e.atual}
        return JSONResponse(status_code=409, content=body)
    except Exception as e:
        raise _error(e) from e


@router.get("/projetos/{id_}/netlist")
def show_netlist(id_: str, projetos: ProjectsDep) -> Any:
    return netlist(_get(projetos, id_), projetos.symbol)


@router.get("/projetos/{id_}/bom")
def show_bom(id_: str, projetos: ProjectsDep) -> Any:
    return bom(_get(projetos, id_), projetos.symbol)


@router.get("/projetos/{id_}/bom.csv")
def download_bom(id_: str, projetos: ProjectsDep) -> Response:
    p = _get(projetos, id_)
    name = re.sub(r"[^\w.-]+", "_", p["titulo"]).strip("_") or "projeto"
    return Response(
        bom_csv(p, projetos.symbol),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{name}-bom.csv"'},
    )


@router.post("/projetos/{id_}/duplicar", status_code=201)
def duplicate(id_: str, projetos: ProjectsDep) -> Any:
    try:
        return projetos.duplicate(id_)
    except Exception as e:
        raise _error(e) from e


@router.delete("/projetos/{id_}", status_code=204)
def delete(id_: str, projetos: ProjectsDep) -> Response:
    try:
        projetos.excluir(id_)
    except NotFound as e:
        raise _error(e) from e
    return Response(status_code=204)


@router.get("/projetos/{id_}/erc")
def show_erc(id_: str, projetos: ProjectsDep) -> Any:
    """Electrical rule check problems (errors first)."""
    from electronics.erc import erc

    return erc(_get(projetos, id_), projetos.symbol)
