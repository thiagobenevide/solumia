"""Rotas do módulo Estudos. A plataforma monta o router em `/api/estudos` com a autenticação e
guarda os [Estudos] em `app.state.estudos`. O grafo do conhecimento vem de `/api/notas/grafo`."""

import unicodedata
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from estudos.api_linguagem import router as linguagem_router
from estudos.conhecimento import ItemInexistente
from estudos.estudos import AREAS, STATUS_LEITURA, Estudos, Invalido, NaoEncontrado
from estudos.idiomas import IDIOMAS, NIVEIS
from estudos.projetos import STATUS_USO, TIPOS_CITACAO, TIPOS_CONTEUDO, exportar_xlsx

router = APIRouter(tags=["estudos"])
router.include_router(linguagem_router)


def get_estudos(request: Request) -> Estudos:
    estudos: Estudos = request.app.state.estudos
    return estudos


EstudosDep = Annotated[Estudos, Depends(get_estudos)]


class LeituraEntrada(BaseModel):
    titulo: str = Field(min_length=1, max_length=300)
    autor: str = Field("", max_length=200)
    tipo: str = Field("livro", pattern="^(livro|artigo)$")
    area: str = Field(min_length=1, max_length=60)
    status: str = "quero ler"
    paginas: int | None = Field(None, ge=1)
    pagina_atual: int = Field(0, ge=0)
    nota_id: str | None = None
    arquivo_id: str | None = None
    tags: list[str] = []
    url: str = Field("", max_length=2000)
    ano: str | None = Field(None, max_length=20)
    referencia: str | None = Field(None, max_length=3000)
    tipo_publicacao: str | None = Field(None, max_length=100)
    veiculo: str | None = Field(None, max_length=300)
    doi: str | None = Field(None, max_length=2000)
    idioma: str | None = Field(None, max_length=40)


class LeituraEdicao(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=300)
    autor: str | None = Field(None, max_length=200)
    tipo: str | None = Field(None, pattern="^(livro|artigo)$")
    area: str | None = Field(None, min_length=1, max_length=60)
    status: str | None = None
    paginas: int | None = Field(None, ge=1)
    pagina_atual: int | None = Field(None, ge=0)
    nota_id: str | None = None
    arquivo_id: str | None = None
    tags: list[str] | None = None
    url: str | None = Field(None, max_length=2000)
    ano: str | None = Field(None, max_length=20)
    referencia: str | None = Field(None, max_length=3000)
    tipo_publicacao: str | None = Field(None, max_length=100)
    veiculo: str | None = Field(None, max_length=300)
    doi: str | None = Field(None, max_length=2000)
    idioma: str | None = Field(None, max_length=40)


class TrilhaEntrada(BaseModel):
    idioma: str
    nivel_inicial: str = "A1"
    nivel_alvo: str = "C2"
    minutos_por_dia: int = Field(45, ge=10, le=600)
    dias_semana: list[int] = [1, 2, 3, 4, 5, 6]
    inicio: str | None = None


class TrilhaEdicao(BaseModel):
    nivel_inicial: str | None = None
    nivel_alvo: str | None = None
    minutos_por_dia: int | None = Field(None, ge=10, le=600)
    dias_semana: list[int] | None = None
    inicio: str | None = None


class Sessao(BaseModel):
    data: str
    minutos: int = Field(ge=0, le=1440)


def _erro(e: Exception) -> HTTPException:
    if isinstance(e, NaoEncontrado | ItemInexistente):
        return HTTPException(404, "Não encontrado")
    return HTTPException(422, str(e))


@router.get("/opcoes")
def opcoes() -> Any:
    return {
        "areas": AREAS,
        "status": STATUS_LEITURA,
        "idiomas": IDIOMAS,
        "niveis": NIVEIS,
        "tipos_citacao": TIPOS_CITACAO,
        "tipos_conteudo": TIPOS_CONTEUDO,
        "status_uso": STATUS_USO,
    }


@router.get("/leituras")
def listar_leituras(estudos: EstudosDep, area: str | None = None, status: str | None = None) -> Any:
    return estudos.listar_leituras(area, status)


@router.post("/leituras", status_code=201)
def criar_leitura(estudos: EstudosDep, corpo: LeituraEntrada) -> Any:
    try:
        return estudos.criar_leitura(corpo.model_dump())
    except Invalido as e:
        raise _erro(e) from e


@router.patch("/leituras/{id_}")
def editar_leitura(estudos: EstudosDep, id_: str, corpo: LeituraEdicao) -> Any:
    try:
        return estudos.editar_leitura(id_, corpo.model_dump(exclude_unset=True))
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


@router.delete("/leituras/{id_}", status_code=204)
def excluir_leitura(estudos: EstudosDep, id_: str) -> None:
    try:
        estudos.leituras.excluir(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.get("/idiomas")
def listar_trilhas(estudos: EstudosDep) -> Any:
    return estudos.listar_trilhas()


@router.post("/idiomas", status_code=201)
def criar_trilha(estudos: EstudosDep, corpo: TrilhaEntrada) -> Any:
    try:
        return estudos.criar_trilha(corpo.model_dump(exclude_none=True))
    except Invalido as e:
        raise _erro(e) from e


@router.get("/idiomas/{id_}")
def trilha(estudos: EstudosDep, id_: str) -> Any:
    try:
        return estudos.trilha(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.patch("/idiomas/{id_}")
def editar_trilha(estudos: EstudosDep, id_: str, corpo: TrilhaEdicao) -> Any:
    try:
        return estudos.editar_trilha(id_, corpo.model_dump(exclude_none=True))
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


@router.delete("/idiomas/{id_}", status_code=204)
def excluir_trilha(estudos: EstudosDep, id_: str) -> None:
    try:
        estudos.trilhas.excluir(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.get("/idiomas/{id_}/cronograma")
def cronograma(estudos: EstudosDep, id_: str, de: str, ate: str) -> Any:
    try:
        return estudos.cronograma(id_, de, ate)
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


@router.post("/idiomas/{id_}/sessoes")
def registrar_sessao(estudos: EstudosDep, id_: str, corpo: Sessao) -> Any:
    try:
        return estudos.registrar_sessao(id_, corpo.data, corpo.minutos)
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


class LivroEdicao(BaseModel):
    tenho: bool


class MarcaEtapa(BaseModel):
    leitura: int | None = Field(None, ge=0)
    feita: bool = True
    pratica: bool | None = None
    nota_id: str | None = Field(None, max_length=200)


@router.get("/conhecimento/trilhas")
def trilhas_conhecimento(estudos: EstudosDep) -> Any:
    return estudos.conhecimento.listar_trilhas()


@router.get("/conhecimento/trilhas/{id_}")
def trilha_conhecimento(estudos: EstudosDep, id_: str, frente: str | None = None) -> Any:
    try:
        return estudos.conhecimento.trilha(id_, frente)
    except ItemInexistente as e:
        raise _erro(e) from e


@router.post("/conhecimento/trilhas/{id_}/etapas/{etapa}")
def marcar_etapa(estudos: EstudosDep, id_: str, etapa: str, corpo: MarcaEtapa) -> Any:
    try:
        return estudos.conhecimento.marcar(id_, etapa, corpo.model_dump())
    except ItemInexistente as e:
        raise _erro(e) from e


@router.get("/conhecimento/livros")
def livros_conhecimento(estudos: EstudosDep) -> Any:
    return estudos.conhecimento.livros()


@router.patch("/conhecimento/livros/{id_}")
def editar_livro(estudos: EstudosDep, id_: str, corpo: LivroEdicao) -> Any:
    try:
        return estudos.conhecimento.editar_livro(id_, corpo.tenho)
    except ItemInexistente as e:
        raise _erro(e) from e


@router.post("/conhecimento/livros/{id_}/leitura")
def vincular_leitura(estudos: EstudosDep, id_: str) -> Any:
    """Liga o livro a uma leitura (cria se não houver) para ler e grifar na aba Leituras."""
    try:
        return estudos.conhecimento.vincular_leitura(id_)
    except ItemInexistente as e:
        raise _erro(e) from e


class ProjetoEntrada(BaseModel):
    nome: str = Field(min_length=1, max_length=200)
    descricao: str = Field("", max_length=4000)
    cor: int | None = None
    secoes: list[str] = []


class ProjetoEdicao(BaseModel):
    nome: str | None = Field(None, min_length=1, max_length=200)
    descricao: str | None = Field(None, max_length=4000)
    cor: int | None = None
    secoes: list[str] | None = None


class Classificacao(BaseModel):
    secao: str | None = Field(None, max_length=300)
    tipo_citacao: str | None = Field(None, max_length=100)
    tipo_conteudo: str | None = Field(None, max_length=100)
    palavras_chave: str | None = Field(None, max_length=1000)
    status_uso: str | None = Field(None, max_length=40)
    parafrase: str | None = Field(None, max_length=20_000)
    observacoes: str | None = Field(None, max_length=10_000)


@router.get("/projetos")
def listar_projetos(estudos: EstudosDep) -> Any:
    return estudos.listar_projetos()


@router.post("/projetos", status_code=201)
def criar_projeto(estudos: EstudosDep, corpo: ProjetoEntrada) -> Any:
    return estudos.criar_projeto(corpo.model_dump(exclude_none=True))


@router.patch("/projetos/{id_}")
def editar_projeto(estudos: EstudosDep, id_: str, corpo: ProjetoEdicao) -> Any:
    try:
        return estudos.editar_projeto(id_, corpo.model_dump(exclude_none=True))
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.delete("/projetos/{id_}", status_code=204)
def excluir_projeto(estudos: EstudosDep, id_: str) -> None:
    try:
        estudos.projetos.excluir(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.get("/projetos/{id_}/matriz")
def matriz(estudos: EstudosDep, id_: str) -> Any:
    try:
        return estudos.matriz(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.patch("/projetos/{id_}/itens/{item_id}")
def classificar(estudos: EstudosDep, id_: str, item_id: str, corpo: Classificacao) -> Any:
    try:
        return estudos.classificar(id_, item_id, corpo.model_dump(exclude_none=True))
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.get("/projetos/{id_}/exportar")
def exportar(estudos: EstudosDep, id_: str) -> Response:
    try:
        m = estudos.matriz(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e
    ascii_ = unicodedata.normalize("NFKD", m["projeto"]["nome"]).encode("ascii", "ignore").decode()
    nome = "".join(c for c in ascii_ if c.isalnum() or c in " -_").strip() or "projeto"
    return Response(
        exportar_xlsx(m),
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f'attachment; filename="Matriz - {nome}.xlsx"'},
    )
