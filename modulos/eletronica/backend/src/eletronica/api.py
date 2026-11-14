"""Rotas do módulo Eletrônica. A plataforma monta o router em `/api/eletronica` com a autenticação e
guarda os [Projetos] em `app.state.projetos_eletronica`."""

import re
from typing import Annotated, Any

import httpx
from fastapi import APIRouter, Depends, File, HTTPException, Request, Response, UploadFile
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from eletronica import kicad
from eletronica.biblioteca import SIMBOLOS
from eletronica.bibliotecas import SUGERIDAS, Bibliotecas, NaoEncontrada, NomeInvalido
from eletronica.netlist import bom, bom_csv, netlist
from eletronica.projetos import Conflito, NaoEncontrado, Projetos

router = APIRouter(tags=["eletronica"])


def get_projetos(request: Request) -> Projetos:
    projetos: Projetos = request.app.state.projetos_eletronica
    return projetos


ProjetosDep = Annotated[Projetos, Depends(get_projetos)]


def get_bibliotecas(request: Request) -> Bibliotecas:
    bibliotecas: Bibliotecas = request.app.state.bibliotecas_eletronica
    return bibliotecas


BibliotecasDep = Annotated[Bibliotecas, Depends(get_bibliotecas)]

# Bibliotecas oficiais em arquivo único (a partir do KiCad 10 viraram pastas `.kicad_symdir`).
URL_KICAD = "https://gitlab.com/kicad/libraries/kicad-symbols/-/raw/{versao}/{nome}.kicad_sym"
MAX_ARQUIVO = 40 * 1024 * 1024


class ProjetoEntrada(BaseModel):
    titulo: str = Field("", max_length=200)
    pasta: str = Field("", max_length=200)


class ProjetoEdicao(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=200)
    pasta: str | None = Field(None, max_length=200)


class Gravacao(BaseModel):
    versao: int = Field(ge=1)
    folhas: list[dict[str, Any]] = Field(min_length=1, max_length=200)
    componentes: list[dict[str, Any]] = Field(default_factory=list, max_length=20_000)
    fios: list[dict[str, Any]] = Field(default_factory=list, max_length=50_000)
    rotulos: list[dict[str, Any]] = Field(default_factory=list, max_length=20_000)
    textos: list[dict[str, Any]] = Field(default_factory=list, max_length=5_000)
    sondas: list[dict[str, Any]] = Field(default_factory=list, max_length=64)


def _erro(e: Exception) -> HTTPException:
    if isinstance(e, NaoEncontrado):
        return HTTPException(404, "Projeto não encontrado")
    return HTTPException(422, str(e))


def _obter(projetos: Projetos, id_: str) -> dict[str, Any]:
    try:
        return projetos.obter(id_)
    except Exception as e:
        raise _erro(e) from e


@router.get("/biblioteca")
def biblioteca() -> Any:
    return SIMBOLOS


class Ids(BaseModel):
    ids: list[str] = Field(max_length=2000)


class PedidoKicad(BaseModel):
    nomes: list[str] = Field(min_length=1, max_length=60)


@router.get("/biblioteca/busca")
def buscar_simbolos(
    bibliotecas: BibliotecasDep, q: str = "", biblioteca: str | None = None, limite: int = 60
) -> Any:
    """Símbolos importados com todas as palavras de `q` (nome, valor, descrição, palavras-chave)."""
    return bibliotecas.buscar(q, biblioteca, min(max(limite, 1), 200))


@router.post("/biblioteca/simbolos")
def simbolos(pedido: Ids, bibliotecas: BibliotecasDep) -> Any:
    """Os símbolos pedidos (base ou importados) que existirem; o app pede os do projeto ao abrir."""
    return bibliotecas.varios(pedido.ids)


@router.get("/bibliotecas")
def listar_bibliotecas(bibliotecas: BibliotecasDep) -> Any:
    return bibliotecas.listar()


@router.post("/bibliotecas/importar", status_code=201)
async def importar_biblioteca(
    bibliotecas: BibliotecasDep, arquivo: Annotated[UploadFile, File()]
) -> Any:
    """Um `.kicad_sym` enviado pelo app; o nome do arquivo vira o nome da biblioteca."""
    bruto = await arquivo.read()
    if len(bruto) > MAX_ARQUIVO:
        raise HTTPException(413, "Arquivo maior que 40 MB.")
    nome = re.sub(r"\.kicad_sym$", "", arquivo.filename or "", flags=re.I)
    nome = re.sub(r"[^A-Za-z0-9_.+-]+", "_", nome).strip("_") or "Importada"
    try:
        simbolos = kicad.ler_biblioteca(bruto.decode("utf-8", "replace"), nome)
        return bibliotecas.guardar(nome, simbolos, "arquivo")
    except (kicad.ArquivoInvalido, NomeInvalido) as e:
        raise HTTPException(422, str(e)) from e


@router.get("/bibliotecas/kicad")
def kicad_sugeridas(request: Request) -> Any:
    return {"versao": request.app.state.eletronica_kicad_versao, "sugeridas": SUGERIDAS}


@router.post("/bibliotecas/kicad")
async def baixar_kicad(pedido: PedidoKicad, request: Request, bibliotecas: BibliotecasDep) -> Any:
    """Baixa as bibliotecas oficiais pedidas do GitLab do KiCad e importa cada uma; devolve uma
    linha por nome (`total` ou `erro`)."""
    versao = request.app.state.eletronica_kicad_versao
    saida: list[dict[str, Any]] = []
    async with httpx.AsyncClient(timeout=60, follow_redirects=True) as http:
        for nome in pedido.nomes:
            try:
                Bibliotecas.validar_nome(nome)
                r = await http.get(URL_KICAD.format(versao=versao, nome=nome))
                if r.status_code != 200 or not r.text.lstrip().startswith("(kicad_symbol_lib"):
                    raise kicad.ArquivoInvalido(
                        f"não achou no KiCad {versao} (HTTP {r.status_code})"
                    )
                simbolos = kicad.ler_biblioteca(r.text, nome)
                saida.append(bibliotecas.guardar(nome, simbolos, f"kicad {versao}"))
            except (httpx.HTTPError, kicad.ArquivoInvalido, NomeInvalido) as e:
                saida.append({"nome": nome, "erro": str(e) or type(e).__name__})
    return saida


@router.delete("/bibliotecas/{nome}", status_code=204)
def remover_biblioteca(nome: str, bibliotecas: BibliotecasDep) -> Response:
    try:
        bibliotecas.remover(nome)
    except NaoEncontrada as e:
        raise HTTPException(404, "Biblioteca não encontrada") from e
    return Response(status_code=204)


@router.get("/projetos")
def listar(projetos: ProjetosDep, pasta: str | None = None) -> Any:
    return projetos.listar(pasta)


@router.post("/projetos", status_code=201)
def criar(entrada: ProjetoEntrada, projetos: ProjetosDep) -> Any:
    try:
        return projetos.criar(entrada.model_dump())
    except Exception as e:
        raise _erro(e) from e


@router.get("/projetos/{id_}")
def obter(id_: str, projetos: ProjetosDep) -> Any:
    return _obter(projetos, id_)


@router.patch("/projetos/{id_}")
def editar(id_: str, edicao: ProjetoEdicao, projetos: ProjetosDep) -> Any:
    try:
        return projetos.editar(id_, edicao.model_dump(exclude_unset=True))
    except Exception as e:
        raise _erro(e) from e


@router.put("/projetos/{id_}/esquematico")
def salvar(id_: str, g: Gravacao, projetos: ProjetosDep) -> Any:
    """409 traz o projeto atual em `projeto`: o app decide entre recarregar e gravar por cima."""
    try:
        return projetos.salvar(id_, g.model_dump(exclude={"versao"}), g.versao)
    except Conflito as e:
        corpo = {"error": {"message": str(e)}, "projeto": e.atual}
        return JSONResponse(status_code=409, content=corpo)
    except Exception as e:
        raise _erro(e) from e


@router.get("/projetos/{id_}/netlist")
def ver_netlist(id_: str, projetos: ProjetosDep) -> Any:
    return netlist(_obter(projetos, id_), projetos.simbolo)


@router.get("/projetos/{id_}/bom")
def ver_bom(id_: str, projetos: ProjetosDep) -> Any:
    return bom(_obter(projetos, id_), projetos.simbolo)


@router.get("/projetos/{id_}/bom.csv")
def baixar_bom(id_: str, projetos: ProjetosDep) -> Response:
    p = _obter(projetos, id_)
    nome = re.sub(r"[^\w.-]+", "_", p["titulo"]).strip("_") or "projeto"
    return Response(
        bom_csv(p, projetos.simbolo),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{nome}-bom.csv"'},
    )


@router.post("/projetos/{id_}/duplicar", status_code=201)
def duplicar(id_: str, projetos: ProjetosDep) -> Any:
    try:
        return projetos.duplicar(id_)
    except Exception as e:
        raise _erro(e) from e


@router.delete("/projetos/{id_}", status_code=204)
def excluir(id_: str, projetos: ProjetosDep) -> Response:
    try:
        projetos.excluir(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e
    return Response(status_code=204)


@router.get("/projetos/{id_}/erc")
def ver_erc(id_: str, projetos: ProjetosDep) -> Any:
    """Problemas da verificação elétrica (erros primeiro)."""
    from eletronica.erc import erc

    return erc(_obter(projetos, id_), projetos.simbolo)
