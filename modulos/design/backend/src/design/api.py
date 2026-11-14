"""Rotas do módulo Design. A plataforma monta o router em `/api/design` com a autenticação e guarda
os [Quadros] em `app.state.quadros_design`."""

import json
import re
from typing import Annotated, Any

import httpx
from fastapi import APIRouter, Depends, File, HTTPException, Request, Response, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field

from design.imagens import Imagens, Invalida
from design.quadros import Conflito, NaoEncontrado, Quadros

router = APIRouter(tags=["design"])


def get_quadros(request: Request) -> Quadros:
    quadros: Quadros = request.app.state.quadros_design
    return quadros


QuadrosDep = Annotated[Quadros, Depends(get_quadros)]


class QuadroEntrada(BaseModel):
    titulo: str = Field("", max_length=200)
    fundo: str = "pontos"
    pasta: str = Field("", max_length=200)


class QuadroEdicao(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=200)
    fundo: str | None = None
    pasta: str | None = Field(None, max_length=200)
    paginas: list[dict[str, Any]] | None = Field(None, max_length=200)


class Gravacao(BaseModel):
    versao: int = Field(ge=1)
    elementos: list[dict[str, Any]] = Field(max_length=50_000)


def _erro(e: Exception) -> HTTPException:
    if isinstance(e, NaoEncontrado):
        return HTTPException(404, "Quadro não encontrado")
    return HTTPException(422, str(e))


@router.get("/quadros")
def listar(quadros: QuadrosDep, pasta: str | None = None) -> Any:
    return quadros.listar(pasta)


@router.post("/quadros", status_code=201)
def criar(entrada: QuadroEntrada, quadros: QuadrosDep) -> Any:
    try:
        return quadros.criar(entrada.model_dump())
    except Exception as e:
        raise _erro(e) from e


@router.post("/quadros/importar-drawio", status_code=201)
async def importar_drawio(quadros: QuadrosDep, arquivo: UploadFile = File(...)) -> Any:
    """Cria um quadro a partir de um `.drawio`/`.xml` do draw.io (todas as páginas)."""
    from design import drawio

    bruto = await arquivo.read()
    if len(bruto) > 20 * 1024 * 1024:
        raise HTTPException(413, "Arquivo maior que 20 MB.")
    try:
        lido = drawio.ler(bruto.decode("utf-8", "ignore"))
    except drawio.ArquivoInvalido as e:
        raise HTTPException(422, str(e)) from e
    titulo = re.sub(r"\.(drawio|xml)$", "", arquivo.filename or "", flags=re.I) or "Diagrama"
    q = quadros.criar({"titulo": titulo[:200], "fundo": "grade", **lido})
    return {
        **{k: v for k, v in q.items() if k != "elementos"},
        "total": len(q["elementos"]),
        "ignorados": lido["ignorados"],
    }


@router.get("/quadros/{id_}/drawio")
def exportar_drawio(id_: str, quadros: QuadrosDep) -> Response:
    """O quadro como `.drawio`, para abrir e editar no draw.io/diagrams.net."""
    from design import drawio

    try:
        q = quadros.obter(id_)
    except Exception as e:
        raise _erro(e) from e
    return Response(
        drawio.escrever(q),
        media_type="application/xml",
        headers={
            "Content-Disposition": "attachment; filename*=UTF-8''"
            + drawio.nome_arquivo(q["titulo"])
        },
    )


@router.get("/quadros/{id_}")
def obter(id_: str, quadros: QuadrosDep) -> Any:
    try:
        return quadros.obter(id_)
    except Exception as e:
        raise _erro(e) from e


@router.patch("/quadros/{id_}")
def editar(id_: str, edicao: QuadroEdicao, quadros: QuadrosDep) -> Any:
    try:
        return quadros.editar(id_, edicao.model_dump(exclude_unset=True))
    except Exception as e:
        raise _erro(e) from e


@router.put("/quadros/{id_}/elementos")
def salvar(id_: str, g: Gravacao, quadros: QuadrosDep) -> Any:
    """409 traz o quadro atual em `quadro`: o app mescla e grava de novo com a versão dele."""
    try:
        return quadros.salvar(id_, g.elementos, g.versao)
    except Conflito as e:
        corpo = {"error": {"message": str(e)}, "quadro": e.atual}
        return JSONResponse(status_code=409, content=corpo)
    except Exception as e:
        raise _erro(e) from e


@router.get("/quadros/{id_}/miniatura")
def miniatura(id_: str, quadros: QuadrosDep) -> FileResponse:
    try:
        return FileResponse(quadros.miniatura(id_), media_type="image/png")
    except Exception as e:
        raise _erro(e) from e


@router.post("/quadros/{id_}/miniatura", status_code=204)
async def guardar_miniatura(
    id_: str, quadros: QuadrosDep, arquivo: Annotated[UploadFile, File()]
) -> Response:
    try:
        quadros.guardar_miniatura(id_, await arquivo.read())
    except Exception as e:
        raise _erro(e) from e
    return Response(status_code=204)


@router.post("/quadros/{id_}/duplicar", status_code=201)
def duplicar(id_: str, quadros: QuadrosDep) -> Any:
    try:
        return quadros.duplicar(id_)
    except Exception as e:
        raise _erro(e) from e


@router.delete("/quadros/{id_}", status_code=204)
def excluir(id_: str, quadros: QuadrosDep) -> Response:
    try:
        quadros.excluir(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e
    return Response(status_code=204)


# ---------- Wireframes ----------
# Mesma guarda dos quadros (`wireframes/`), com os componentes de `wireframe_ia` como elementos.


def get_wireframes(request: Request) -> Quadros:
    wireframes: Quadros = request.app.state.wireframes_design
    return wireframes


WireframesDep = Annotated[Quadros, Depends(get_wireframes)]


class WireframeEntrada(BaseModel):
    titulo: str = Field("", max_length=200)
    pasta: str = Field("", max_length=200)


@router.get("/wireframes")
def listar_wireframes(wireframes: WireframesDep) -> Any:
    return wireframes.listar()


@router.post("/wireframes", status_code=201)
def criar_wireframe(entrada: WireframeEntrada, wireframes: WireframesDep) -> Any:
    from design.wireframe_ia import tela_padrao

    titulo = entrada.titulo or "Wireframe sem título"
    return wireframes.criar({"titulo": titulo, "pasta": entrada.pasta, "paginas": [tela_padrao()]})


async def _ler_pacote(arquivo: UploadFile) -> dict[str, Any]:
    from design import wireframe_ia

    bruto = await arquivo.read()
    if len(bruto) > 20 * 1024 * 1024:
        raise HTTPException(413, "Arquivo maior que 20 MB.")
    try:
        return wireframe_ia.ler(bruto)
    except wireframe_ia.FormatoInvalido as e:
        raise HTTPException(422, str(e)) from e


@router.post("/wireframes/importar-ia", status_code=201)
async def importar_wireframe(wireframes: WireframesDep, arquivo: UploadFile = File(...)) -> Any:
    """Cria um wireframe do `wireframe.json` (ou do ZIP) que voltou de outra IA."""
    return wireframes.criar(await _ler_pacote(arquivo))


@router.get("/wireframes/{id_}")
def obter_wireframe(id_: str, wireframes: WireframesDep) -> Any:
    try:
        return wireframes.obter(id_)
    except Exception as e:
        raise _erro(e) from e


@router.patch("/wireframes/{id_}")
def editar_wireframe(id_: str, edicao: QuadroEdicao, wireframes: WireframesDep) -> Any:
    try:
        return wireframes.editar(id_, edicao.model_dump(exclude_unset=True))
    except Exception as e:
        raise _erro(e) from e


@router.put("/wireframes/{id_}/elementos")
def salvar_wireframe(id_: str, g: Gravacao, wireframes: WireframesDep) -> Any:
    try:
        return wireframes.salvar(id_, g.elementos, g.versao)
    except Conflito as e:
        corpo = {"error": {"message": str(e)}, "quadro": e.atual}
        return JSONResponse(status_code=409, content=corpo)
    except Exception as e:
        raise _erro(e) from e


@router.get("/wireframes/{id_}/ia")
def exportar_wireframe(id_: str, wireframes: WireframesDep, formato: str = "zip") -> Response:
    """Pacote para outra IA editar: `zip` (AGENTS.md + schema + wireframe.json + PNGs das telas)
    ou só o `json`. Os PNGs são os últimos que o app enviou em `…/telas/{tela}/png`."""
    from urllib.parse import quote

    from design import wireframe_ia

    try:
        q = wireframes.obter(id_)
    except Exception as e:
        raise _erro(e) from e
    nome = re.sub(r"[^\w\- ]+", "_", q["titulo"]).strip() or "wireframe"
    if formato == "json":
        corpo = json.dumps(wireframe_ia.para_ia(q), ensure_ascii=False, indent=2).encode()
        tipo, nome = "application/json", f"{nome}.wireframe.json"
    else:
        corpo = wireframe_ia.pacote(q, wireframes.pngs(id_))
        tipo, nome = "application/zip", f"{nome}.wireframe.zip"
    disposicao = "attachment; filename*=UTF-8''" + quote(nome)
    return Response(corpo, media_type=tipo, headers={"Content-Disposition": disposicao})


@router.post("/wireframes/{id_}/telas/{tela}/png", status_code=204)
async def guardar_png_tela(
    id_: str, tela: str, wireframes: WireframesDep, arquivo: Annotated[UploadFile, File()]
) -> Response:
    """Render da tela feito pelo app (mesmo pintor do editor), para ir no pacote da IA."""
    try:
        wireframes.guardar_png(id_, tela, await arquivo.read())
    except Exception as e:
        raise _erro(e) from e
    return Response(status_code=204)


@router.post("/wireframes/{id_}/importar-ia")
async def reimportar_wireframe(
    id_: str, wireframes: WireframesDep, arquivo: UploadFile = File(...)
) -> Any:
    """Troca o conteúdo pelo que a IA devolveu (mesmo id, versão nova)."""
    lido = await _ler_pacote(arquivo)
    try:
        return wireframes.substituir(id_, lido)
    except Exception as e:
        raise _erro(e) from e


@router.post("/wireframes/{id_}/duplicar", status_code=201)
def duplicar_wireframe(id_: str, wireframes: WireframesDep) -> Any:
    try:
        return wireframes.duplicar(id_)
    except Exception as e:
        raise _erro(e) from e


@router.delete("/wireframes/{id_}", status_code=204)
def excluir_wireframe(id_: str, wireframes: WireframesDep) -> Response:
    try:
        wireframes.excluir(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e
    return Response(status_code=204)


# ---------- Imagens (Google Imagens) ----------


def get_imagens(request: Request) -> Imagens:
    imagens: Imagens = request.app.state.imagens_design
    return imagens


ImagensDep = Annotated[Imagens, Depends(get_imagens)]


class PedidoImagem(BaseModel):
    url: str = Field(min_length=8, max_length=4000)


@router.get("/imagens/busca")
async def buscar_imagens(
    imagens: ImagensDep, q: str, tipo: str = "foto", pagina: int = 0
) -> list[dict[str, Any]]:
    """Google Imagens (ou Bing/Openverse sem chave); `tipo`: foto, icone, figura ou todos."""
    if not q.strip():
        return []
    try:
        return await imagens.buscar(q.strip(), tipo, max(pagina, 0))
    except (Invalida, OSError, httpx.HTTPError) as e:
        raise HTTPException(503, str(e)) from e


@router.post("/imagens", status_code=201)
async def guardar_imagem(p: PedidoImagem, imagens: ImagensDep) -> dict[str, Any]:
    """Copia a imagem escolhida para o servidor; o elemento `imagem` do quadro guarda o `id`."""
    try:
        return await imagens.baixar(p.url)
    except Invalida as e:
        raise HTTPException(422, str(e)) from e
    except (OSError, httpx.HTTPError) as e:
        raise HTTPException(502, f"Não foi possível baixar a imagem: {e}") from e


@router.get("/imagens/{id_}")
def obter_imagem(id_: str, imagens: ImagensDep) -> FileResponse:
    try:
        return FileResponse(imagens.caminho(id_), headers={"Cache-Control": "max-age=31536000"})
    except FileNotFoundError as e:
        raise HTTPException(404, "Imagem não encontrada") from e


# ---------- Fluxogramas com IA ----------


def get_llms(request: Request) -> dict[str, Any]:
    """Provedores de LLM (`local` = worker no PC, `claude` se houver chave), da plataforma."""
    return getattr(request.app.state, "design_llms", {})


LLMsDep = Annotated[dict[str, Any], Depends(get_llms)]


class PedidoFluxo(BaseModel):
    pedido: str = Field("", max_length=4000)
    codigo: str = Field("", max_length=400_000)
    arquivo: str = Field("", max_length=300)
    atual: dict[str, Any] | None = None
    """Fluxo que já está no quadro (`nos`/`ligacoes`), para a IA ajustar em vez de criar do zero."""
    provedor: str = "local"


@router.get("/fluxos/provedores")
def provedores_fluxo(llms: LLMsDep) -> list[str]:
    return sorted(llms)


# Gerações em andamento (em memória): a IA pode levar minutos com código grande, e a Cloudflare
# corta resposta que demora mais de 100 s para começar; o app cria a tarefa e consulta até terminar.
_TAREFAS: dict[str, dict[str, Any]] = {}
_MAX_TAREFAS = 50


@router.post("/fluxos/gerar", status_code=202)
async def gerar_fluxo(p: PedidoFluxo, llms: LLMsDep) -> dict[str, Any]:
    """Começa a gerar o fluxograma (estrutura pela IA, posições em camadas, ver `fluxos`); devolve o
    id da tarefa para `GET /fluxos/tarefas/{id}`."""
    import asyncio
    import uuid

    from design import fluxos

    if not (p.pedido.strip() or p.codigo.strip() or p.atual):
        raise HTTPException(422, "Descreva o fluxo, envie um código ou peça um ajuste.")
    llm = llms.get(p.provedor)
    if llm is None:
        raise HTTPException(503, f"IA '{p.provedor}' indisponível.")
    tid = uuid.uuid4().hex[:12]
    tarefa: dict[str, Any] = {"estado": "gerando"}

    async def rodar() -> None:
        try:
            tarefa.update(
                estado="pronto",
                fluxo=await fluxos.gerar(llm, p.pedido, p.codigo, p.arquivo, p.atual),
            )
        except fluxos.FluxoInvalido as e:
            tarefa.update(estado="erro", erro=str(e))
        except Exception as e:  # worker desligado, tempo esgotado, API fora
            tarefa.update(estado="erro", erro=f"A IA não respondeu: {e}")

    while len(_TAREFAS) >= _MAX_TAREFAS:
        _TAREFAS.pop(next(iter(_TAREFAS)))
    _TAREFAS[tid] = tarefa
    tarefa["_task"] = asyncio.create_task(rodar())
    return {"id": tid, "estado": "gerando"}


@router.get("/fluxos/tarefas/{tid}")
def tarefa_fluxo(tid: str) -> dict[str, Any]:
    t = _TAREFAS.get(tid)
    if t is None:
        raise HTTPException(404, "Tarefa não encontrada (o servidor reiniciou?).")
    return {k: v for k, v in t.items() if not k.startswith("_")}
