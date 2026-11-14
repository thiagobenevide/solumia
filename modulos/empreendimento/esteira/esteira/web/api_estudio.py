"""API JSON da aba Estúdio do app (canais da rede, estilos, produções, portões, dependências).

Trabalho pesado vai para a fila (`./dark studio`, `studio-style`, `studio-install`, `bench`); aqui só lê e
grava dados. Arquivos da produção (final.mp4, folha.jpg, quadros) saem por `/arq/<ep>/estudio/...`.
"""
import json
import re
import threading
from pathlib import Path

from esteira.projeto import PROJETOS, ep_id, pasta_ep
from esteira.web import fila
from fastapi import APIRouter, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, ValidationError

router = APIRouter(prefix="/api/v1/estudio", tags=["estudio"])


def _estilo(id_):
    from esteira.estudio import estilo
    try:
        return estilo.carregar(id_)
    except (KeyError, ValueError) as e:
        raise HTTPException(404, str(e)) from None


def _ep(ep):
    p = pasta_ep(ep)
    if not p.is_dir():
        raise HTTPException(404, f"episódio inexistente: {ep}")
    return p


# ── canais e estilos ──

@router.get("/canais")
def canais():
    from esteira.estudio import estilo
    todos = estilo.listar()
    return [{"canal": c, "episodios": len([p for p in (PROJETOS / c).glob("*") if p.is_dir()]) if (PROJETOS / c).is_dir() else 0,
             "estilos": [{"id": e.id, "nome": e.nome, "modo": e.modo, "formatos": e.formatos, "versao": e.versao,
                          "travado": e.travado, "destaque": e.pele.destaque, "fundo": e.pele.fundo}
                         for e in todos if e.canal == c]}
            for c in estilo.canais()]


def _versao(e):
    from esteira.estudio import amostra, estilo
    return {"ref": f"{e.id}@{e.versao}", "id": e.id, "versao": e.versao, "rotulo": estilo.rotulo(e), "nome": e.nome,
            "modo": e.modo, "formatos": e.formatos, "travado": e.travado, "salvo_em": e.salvo_em,
            "destaque": e.pele.destaque, "fundo": e.pele.fundo, "amostras": amostra.estado(e),
            "amostra_base": f"/api/v1/estudio/amostras/{e.id}-v{e.versao}"}


@router.get("/templates")
def templates(canal: str):
    """Templates do canal com todas as versões guardadas (`ref` = `id@N`, o que a produção usa) e os exemplos."""
    from esteira.estudio import estilo
    return [{"id": e.id, "nome": e.nome, "modo": e.modo, "formatos": e.formatos,
             "versoes": [_versao(v) for v in estilo.versoes(e.id)]} for e in estilo.listar(canal)]


class NovoTemplate(BaseModel):
    canal: str
    modo: str = "dark"
    formatos: list[str] = ["16:9", "9:16"]
    nome: str = ""


@router.post("/templates")
def novo_template(corpo: NovoTemplate):
    from esteira.estudio import estilo
    if corpo.modo not in ("dark", "apresentador", "curso") or not corpo.formatos \
            or any(f not in ("16:9", "9:16") for f in corpo.formatos):
        raise HTTPException(400, "modo: dark/apresentador/curso · formatos: 16:9, 9:16")
    try:
        return estilo.novo(corpo.canal, corpo.modo, corpo.formatos, corpo.nome)
    except ValueError as x:
        raise HTTPException(400, str(x)[:300]) from None


@router.post("/templates/{ref}/amostra")
def gerar_amostra(ref: str):
    """Exemplo de 30 s da versão nos formatos dela, na fila (render na GPU)."""
    e = _estilo(ref)
    t = fila.adicionar(f"{e.id}@{e.versao}", "studio-sample")
    if t is None:
        raise HTTPException(409, "o exemplo desta versão já está na fila")
    return t


@router.get("/amostras/{nome}/{formato}.mp4")
def arquivo_amostra(nome: str, formato: str):
    from esteira.estudio import amostra
    arq = amostra.PASTA / Path(nome).name / Path(formato).name / "previa.mp4"
    if formato not in ("16x9", "9x16") or not arq.is_file():
        raise HTTPException(404, "exemplo ainda não gerado")
    return FileResponse(arq, media_type="video/mp4")


class Template(BaseModel):
    estilo: str


@router.put("/producoes/{ep}/template")
def escolher_template(ep: str, corpo: Template):
    """Template (`id@N`) que o episódio vai usar na produção (escolhido na aba Roteiros)."""
    from esteira import estudio
    from esteira.projeto import Projeto
    _estilo(corpo.estilo)
    estudio.escolher_template(Projeto(_ep(ep)), corpo.estilo)
    return {"ok": True, "estilo": corpo.estilo}


class NovoCanal(BaseModel):
    slug: str
    nome: str
    nicho: str = ""
    cor: str = "#f5c518"
    modo: str = "dark"


@router.post("/canais")
def novo_canal(corpo: NovoCanal):
    from esteira.estudio import estilo
    try:
        return estilo.novo_canal(corpo.slug.strip().lower(), corpo.nome.strip(), corpo.nicho, corpo.cor, corpo.modo)
    except (ValueError, FileExistsError) as e:
        raise HTTPException(400, str(e)) from None


@router.get("/estilos/{id_}")
def ver_estilo(id_: str):
    from esteira.estudio import identidade
    e = _estilo(id_)
    refs = sorted(f.name for f in identidade.pasta_refs(id_).iterdir() if f.is_file())
    return {"estilo": e, "referencias": refs}


@router.put("/estilos/{id_}")
def salvar_estilo(id_: str, corpo: dict):
    from esteira.estudio import estilo
    try:
        e = estilo.Estilo.model_validate({**corpo, "id": id_})
        return estilo.salvar(e)
    except PermissionError as x:
        raise HTTPException(409, str(x)) from None
    except ValueError as x:
        raise HTTPException(400, str(x)[:300]) from None


class Duplicar(BaseModel):
    id: str
    nome: str


@router.post("/estilos/{id_}/duplicar")
def duplicar_estilo(id_: str, corpo: Duplicar):
    """Template novo a partir de um estilo (tudo igual, destravado, versão 1)."""
    from esteira.estudio import estilo
    _estilo(id_)
    try:
        return estilo.duplicar(id_, corpo.id, corpo.nome)
    except FileExistsError as x:
        raise HTTPException(409, str(x)) from None
    except ValueError as x:
        raise HTTPException(400, str(x)[:300]) from None


@router.get("/niveis")
def niveis():
    """Tabela dos níveis baixa/média/alta (o app mostra o que cada um preenche)."""
    from esteira.bancada import CENAS
    from esteira.estudio import estilo, gatilhos
    return {"niveis": estilo.NIVEIS, "broll": estilo.BROLL, "sfx_chave": list(estilo.SFX_CHAVE),
            # catálogos das abas do estilo: peças do kit, condições dos gatilhos, curvas e efeitos que dá para proibir
            "pecas": CENAS, "condicoes": gatilhos.CONDICOES, "curvas": list(estilo.CURVAS),
            "proibiveis": list(estilo.PROIBIVEIS), "gatilhos_padrao": [g.model_dump() for g in gatilhos.padrao()]}


class Testar(BaseModel):
    texto: str = ""  # trecho colado
    ep: str = ""  # ou um episódio (tempos reais do corte, se houver; senão o roteiro)
    estilo: dict | None = None  # rascunho ainda não salvo (o app testa o que está na tela)


@router.post("/estilos/{id_}/testar")
def testar_estilo(id_: str, corpo: Testar):
    """Decupagem do roteiro pelos gatilhos do estilo, sem IA e sem render: cenas, ritmo e avisos."""
    from esteira.estudio import estilo, gatilhos
    e = _estilo(id_)
    if corpo.estilo:
        try:
            e = estilo.Estilo.model_validate({**corpo.estilo, "id": e.id})
        except ValueError as x:
            raise HTTPException(400, str(x)[:300]) from None
    frases = None
    if corpo.ep:
        from esteira.projeto import Projeto
        pr = Projeto(_ep(corpo.ep))
        if (pr.pasta / "frases.json").is_file():
            from esteira.estudio import corte
            frases = corte.frases(pr)
        elif pr.roteiro():
            frases = gatilhos.frases_do_texto(pr.roteiro().read_text())
    elif corpo.texto.strip():
        frases = gatilhos.frases_do_texto(corpo.texto)
    if not frases:
        raise HTTPException(400, "cole um trecho ou escolha um episódio com roteiro")
    return gatilhos.testar(frases[:200], e)


@router.get("/fontes")
def listar_fontes():
    from esteira.estudio import fontes
    return fontes.listar()


@router.get("/fontes/arquivo/{nome}")
def arquivo_fonte(nome: str):
    """O .ttf/.otf para a prévia no app (FontLoader)."""

    from esteira.estudio import fontes
    p = fontes.caminho(nome)
    if not p:
        raise HTTPException(404, "fonte inexistente")
    return FileResponse(p, media_type="font/ttf")


@router.post("/fontes")
async def enviar_fonte(arquivo: UploadFile = File(...)):
    from esteira.estudio import fontes
    try:
        return {"nome": fontes.enviar(arquivo.filename or "", await arquivo.read())}
    except ValueError as x:
        raise HTTPException(400, str(x)) from None


class Trava(BaseModel):
    travado: bool


@router.post("/estilos/{id_}/travar")
def travar_estilo(id_: str, corpo: Trava):
    from esteira.estudio import estilo
    e = _estilo(id_)
    e.travado = corpo.travado
    return estilo.salvar(e, forcar=True, nova_versao=False)


@router.post("/estilos/{id_}/referencias")
async def enviar_referencia(id_: str, arquivo: UploadFile = File(...)):
    from esteira.estudio import identidade
    _estilo(id_)
    nome = re.sub(r"[^\w.\-]+", "_", Path(arquivo.filename or "ref.jpg").name)
    if Path(nome).suffix.lower() not in (".jpg", ".jpeg", ".png", ".webp"):
        raise HTTPException(400, "envie imagens (jpg, png ou webp)")
    (identidade.pasta_refs(id_) / nome).write_bytes(await arquivo.read())
    return {"ok": True, "nome": nome}


@router.delete("/estilos/{id_}/referencias/{nome}")
def apagar_referencia(id_: str, nome: str):
    from esteira.estudio import identidade
    alvo = identidade.pasta_refs(id_) / Path(nome).name
    if alvo.is_file():
        alvo.unlink()
    return {"ok": True}


class Propor(BaseModel):
    nicho: str = ""


@router.post("/estilos/{id_}/propor")
def propor_estilo(id_: str, corpo: Propor):
    """Fluxo A na fila (pista do Claude): proposta de identidade a partir das referências."""
    _estilo(id_)
    return fila.adicionar(id_, "studio-style", ["--niche", corpo.nicho] if corpo.nicho else [], "claude")


# ── produções ──

_gerando = set()


def _previa_ao_fundo(final):
    """Vídeos feitos antes da prévia leve: gera a prévia numa thread na primeira vez que a produção é aberta."""
    from esteira.estudio import compilar
    if final in _gerando:
        return
    _gerando.add(final)

    def rodar():
        try:
            compilar.previa(final)
        except Exception as e:  # noqa: BLE001 — sem prévia o app toca o final.mp4
            print(f"prévia de {final}: {e}", flush=True)
        finally:
            _gerando.discard(final)  # final refeito depois gera prévia nova

    threading.Thread(target=rodar, daemon=True).start()

@router.get("/producoes")
def producoes(canal: str):
    from esteira import estudio
    pasta = PROJETOS / canal
    if not pasta.is_dir():
        return []
    saida = []
    for p in sorted((x for x in pasta.iterdir() if x.is_dir() and (x / "frases.json").exists()), reverse=True):
        ep = ep_id(p)
        titulo = ""
        if (p / "roteiro.json").exists():
            titulo = json.loads((p / "roteiro.json").read_text()).get("titulo", "")
        saida.append({"ep": ep, "titulo": titulo, **estudio.situacao(ep)})
    return saida


@router.get("/producoes/{ep}")
def producao(ep: str):
    from esteira import estudio
    p = _ep(ep)
    r = estudio.situacao(ep)
    for fmt, d in r["formatos"].items():
        if d["final"] and not d["previa"]:
            _previa_ao_fundo(p / "estudio" / fmt / "final.mp4")
    mapa = p / "estudio" / "mapa.json"
    m = json.loads(mapa.read_text()) if mapa.exists() else {}
    r["cenas"], r["blocos"], r["direcao"] = m.get("cenas", []), m.get("blocos", []), m.get("direcao", "frases")
    return r


class Produzir(BaseModel):
    estilo: str = ""
    formatos: list[str] = []
    etapas: list[str] = []
    intensidade: dict[str, str] = {}


@router.post("/producoes/{ep}/produzir")
def produzir(ep: str, corpo: Produzir):
    from esteira import estudio
    _ep(ep)
    if any(f not in ("16:9", "9:16") for f in corpo.formatos) or any(e not in estudio.ETAPAS for e in corpo.etapas):
        raise HTTPException(400, "formatos: 16:9, 9:16 · etapas: " + ", ".join(estudio.ETAPAS))
    args = (["--style", corpo.estilo] if corpo.estilo else []) + (["--formats", ",".join(corpo.formatos)] if corpo.formatos else []) \
        + (["--stages", ",".join(corpo.etapas)] if corpo.etapas else [])
    if any(k not in ("sfx", "motion", "efeitos") or v not in ("baixa", "media", "alta") for k, v in corpo.intensidade.items()):
        raise HTTPException(400, "intensidade: sfx/motion/efeitos = baixa/media/alta")
    if corpo.intensidade:
        args += ["--intensity", ",".join(f"{k}={v}" for k, v in corpo.intensidade.items())]
    t = fila.adicionar(ep, "studio", args)
    if t is None:
        raise HTTPException(409, "esta produção já está na fila")
    return t


class Aprovacao(BaseModel):
    aprovado: bool = True
    nota: str = ""


@router.post("/producoes/{ep}/aprovar/{portao}")
def aprovar(ep: str, portao: str, corpo: Aprovacao):
    from esteira import estudio
    _ep(ep)
    try:
        return estudio.aprovar(ep, portao, corpo.aprovado, corpo.nota)
    except ValueError as e:
        raise HTTPException(400, str(e)) from None


@router.get("/producoes/{ep}/corte")
def ver_corte(ep: str):
    """Corte pelo som: estado, emendas (com o texto em volta) e a conferência."""
    from esteira.estudio import corte
    from esteira.projeto import Projeto
    projeto = Projeto(_ep(ep))
    c = corte.carregar(projeto) or {}

    def url(arq):
        return f"/arq/{ep}/{arq.relative_to(projeto.pasta)}?v={arq.stat().st_mtime_ns}" if arq.exists() else None
    return {"estado": corte.estado(projeto), "emendas": c.get("emendas", []), "revertidas": c.get("revertidas", []),
            "conferencia": c.get("conferencia"), "editada": url(projeto.pasta / "narracao.wav"),
            "cortada": url(corte.pasta(projeto) / "narracao.wav")}


@router.post("/producoes/{ep}/corte")
def cortar(ep: str):
    _ep(ep)
    return fila.adicionar(ep, "studio-cut") or {"ok": True, "ja_na_fila": True}


class Reversao(BaseModel):
    de: float
    ate: float
    reverter: bool = True


@router.put("/producoes/{ep}/corte/emenda")
def reverter_emenda(ep: str, corpo: Reversao):
    """Reverte (ou volta a cortar) uma emenda: reabre o portão 1 e põe o corte de novo na fila."""
    from esteira import estudio
    from esteira.estudio import corte
    from esteira.projeto import Projeto
    projeto = Projeto(_ep(ep))
    try:
        corte.reverter(projeto, corpo.de, corpo.ate, corpo.reverter)
    except ValueError as e:
        raise HTTPException(409, str(e)) from None
    if estudio.aprovacoes(projeto).get("corte", {}).get("aprovado"):
        estudio.aprovar(ep, "corte", False, "emenda revertida")
    return fila.adicionar(ep, "studio-cut") or {"ok": True, "ja_na_fila": True}


@router.get("/producoes/{ep}/apontamento")
def ver_apontamento(ep: str, estilo: str = ""):
    """Trechos da narração cortada com a cena marcada em cada um (auto / nenhuma / cena do cardápio)."""
    from esteira import estudio
    from esteira.estudio import apontamento, corte
    from esteira.estudio import estilo as E
    from esteira.projeto import Projeto
    projeto = Projeto(_ep(ep))
    if not corte.estado(projeto)["feito"]:
        raise HTTPException(409, "faça o corte pelo som antes do apontamento")
    est = E.carregar(estilo) if estilo else estudio.estilo_padrao(projeto)
    if not est:
        raise HTTPException(404, "nenhum estilo para o canal")
    return {"estilo": est.id, **apontamento.roteiro(projeto, est)}


class Marca(BaseModel):
    texto: str
    cena: str


class Apontamento(BaseModel):
    marcas: list[Marca] = []
    confirmar: bool = False
    produzir: Produzir | None = None


@router.put("/producoes/{ep}/apontamento")
def salvar_apontamento(ep: str, corpo: Apontamento):
    """Grava as marcas; com `confirmar` libera o diretor e, com `produzir`, já põe a produção na fila."""
    from esteira.estudio import apontamento
    from esteira.projeto import Projeto
    projeto = Projeto(_ep(ep))
    try:
        d = apontamento.salvar(projeto, [m.model_dump() for m in corpo.marcas], corpo.confirmar)
    except ValueError as e:
        raise HTTPException(400, str(e)) from None
    if corpo.confirmar and corpo.produzir:
        return {**d, "fila": produzir(ep, corpo.produzir)}
    return d


class EdicaoCena(BaseModel):
    cena: str
    titulo: str = ""
    valores: list[dict] = []


@router.put("/producoes/{ep}/cenas/{cid}")
def editar_cena(ep: str, cid: int, corpo: EdicaoCena):
    """Ajuste à mão de uma cena do mapa (fica `manual`, o replanejamento mantém) — e vira caso do gabarito."""
    from esteira.bancada import CENAS, GABARITO
    from esteira.estudio import peca
    from esteira.estudio.diretor import TAKEOVER
    ficha = peca.carregar(corpo.cena) if re.fullmatch(peca.ID, corpo.cena) and (peca.pasta(corpo.cena) / "ficha.json").exists() else None
    if corpo.cena not in CENAS and not ficha:
        raise HTTPException(400, f"cena inválida: {corpo.cena}")
    arq = _ep(ep) / "estudio" / "mapa.json"
    if not arq.exists():
        raise HTTPException(404, "sem mapa: rode a etapa dirigir")
    mapa = json.loads(arq.read_text())
    c = next((c for c in mapa["cenas"] if c["id"] == cid), None)
    if not c:
        raise HTTPException(404, "cena inexistente")
    if mapa.get("direcao") == "blocos" and c.get("candidatas") and corpo.cena != c["cena"]:
        from esteira.estudio import direcao
        direcao.gabarito(ep, c, corpo.cena, "troca")  # a troca da pessoa é a resposta certa da tarefa bloco_peca
    c.update(cena=corpo.cena, titulo=corpo.titulo, valores=corpo.valores, manual=True,
             takeover=ficha.tela_cheia if ficha else corpo.cena in TAKEOVER)
    if ficha:  # peça do acervo: título/valores viram os encaixes que ela tem; botões no padrão
        c["encaixes"] = peca.legado({"titulo": corpo.titulo, "valores": corpo.valores}, ficha)
        c["botoes"] = peca.padroes(ficha)
        if mapa.get("direcao") == "blocos":  # a correção da pessoa é a resposta certa do preenchimento
            from esteira.estudio import direcao
            direcao.gabarito_preencher(ep, c, "corrigido")
    arq.write_text(json.dumps(mapa, ensure_ascii=False, indent=1))
    GABARITO.mkdir(parents=True, exist_ok=True)
    with open(GABARITO / "cena.jsonl", "a") as f:  # a escolha humana ensina a bancada (e o fine-tune depois)
        f.write(json.dumps({"id": f"aprov:{ep}:{c['frase_i']}", "frase": c["frase"], "antes": "", "aceitas": [corpo.cena]},
                           ensure_ascii=False) + "\n")
    return c


# ── dependências do motor ──

@router.get("/dependencias")
def dependencias():
    from esteira.estudio import motor
    return motor.estado()


@router.post("/dependencias/instalar")
def instalar():
    return fila.adicionar("motor", "studio-install") or {"ok": True, "ja_na_fila": True}


# ── acervo de peças (estudio/pecas; docs/PLANO-ACERVO.md) ──

def _peca(id_):
    from esteira.estudio import peca
    if not re.fullmatch(peca.ID, id_) or not (peca.pasta(id_) / "ficha.json").exists():
        raise HTTPException(404, f"peça inexistente: {id_}")
    return peca.pasta(id_)


def _resumo_peca(p):
    from esteira.estudio import peca
    arq = p / "prova" / "portao.json"
    portao = json.loads(arq.read_text()) if arq.exists() else None
    try:
        ficha = peca.Ficha.model_validate_json((p / "ficha.json").read_text()).model_dump()
    except ValueError:
        ficha = {"id": p.name, "estado": "rascunho", "invalida": True}
    # ?v= com a data do arquivo: peça refeita com o mesmo id não mostra o quadro antigo do cache do app
    quadros = [f"/api/v1/estudio/pecas/{p.name}/prova/{q}?v={int(a.stat().st_mtime) if (a := p / 'prova' / q).exists() else 0}"
               for q in (portao or {}).get("quadros", [])]
    return {"id": p.name, "ficha": ficha, "portao": portao, "quadros": quadros}


@router.get("/pecas")
def pecas():
    """Peças do acervo com a ficha e o último resultado do portão de entrada (inválidas também, para corrigir)."""
    from esteira.estudio import peca
    return [_resumo_peca(f.parent) for f in sorted(peca.PASTA.glob("*/ficha.json"))]


@router.post("/pecas/{id_}/portao")
def portao_peca(id_: str):
    """Roda o portão de entrada (ficha, código e prova nas duas peles × formatos, ~10 s)."""
    from esteira.estudio import peca
    p = _peca(id_)
    try:
        peca.portao(id_)
    except RuntimeError as e:
        raise HTTPException(409, str(e)) from None
    return _resumo_peca(p)


@router.get("/pecas/{id_}/prova/{nome}")
def prova_peca(id_: str, nome: str):
    if not re.fullmatch(r"[a-z]+_\d+x\d+\.jpg", nome):
        raise HTTPException(404, "quadro inexistente")
    arq = _peca(id_) / "prova" / nome
    if not arq.exists():
        raise HTTPException(404, "quadro inexistente")
    return FileResponse(arq, media_type="image/jpeg")


# ── fábrica de peças (estudio/fabrica.py): pedidos, revisão, lacunas ──

class NovoPedido(BaseModel):
    tipo: str = "livre"
    texto: str = ""
    quantidade: int = 3
    teto_dia_usd: float = 3.0
    referencia: str = ""
    motor: str = "html"
    ia: str = "claude"  # "local": LLM local escreve as peças (só motor html)


class Revisao(BaseModel):
    acao: str
    texto: str = ""
    nota: int | None = None


class Motores(BaseModel):
    por_intencao: dict[str, str]
    padrao: str = "html"


@router.get("/fabrica")
def fabrica_resumo():
    from esteira.estudio import fabrica
    return fabrica.resumo()


@router.get("/fabrica/painel")
def fabrica_painel():
    """Painel ao vivo: ideias (Claude) → N1 (LLM local) → portão → revisão (Claude) → acervo/dataset."""
    from esteira.estudio import fabrica
    return fabrica.painel()


class PedidoIdeias(BaseModel):
    quantidade: int = 24
    texto: str = ""


@router.post("/fabrica/ideias")
def fabrica_ideias(corpo: PedidoIdeias):
    """O Claude cria ideias em lote e a LLM local executa cada uma em N1 (modo híbrido)."""
    from esteira.estudio import fabrica
    p = fabrica.pedido_hibrido("ideias", max(1, min(corpo.quantidade, 50)), corpo.texto.strip())
    fabrica.enfileirar(p.id)
    return p.model_dump()


@router.post("/fabrica/porte")
def fabrica_porte():
    """Porte das peças HTML para EffectCraft pela LLM local: retoma o pedido de porte aberto ou cria um."""
    from esteira.estudio import fabrica
    aberto = next((p for p in fabrica.pedidos() if p.tipo == "porte" and p.estado != "concluido"), None)
    p = fabrica.pausar(aberto.id, False) if aberto else fabrica.pedido_hibrido("porte")
    fabrica.enfileirar(p.id)
    return p.model_dump()


@router.post("/fabrica/pedidos")
def fabrica_pedido(corpo: NovoPedido):
    from esteira.estudio import fabrica
    try:
        p = fabrica.novo_pedido(corpo.tipo, corpo.texto, corpo.quantidade, corpo.teto_dia_usd, corpo.referencia,
                                corpo.motor, corpo.ia)
    except (ValueError, ValidationError) as e:
        raise HTTPException(400, str(e)) from None
    fabrica.enfileirar(p.id)
    return p.model_dump()


@router.post("/fabrica/citacao")
def fabrica_citacao(teto_dia_usd: float = 3.0, motor: str = "html"):
    """Pedido pronto da primeira peça da fábrica: a citação de PDF (motor "ambos" gera nos dois para comparar)."""
    from esteira.estudio import fabrica
    if motor not in ("html", "effectcraft", "ambos", "auto"):
        raise HTTPException(400, "motor: html, effectcraft, ambos ou auto")
    p = fabrica.pedido_citacao(teto_dia_usd, motor)
    fabrica.enfileirar(p.id)
    return p.model_dump()


@router.post("/fabrica/referencias")
async def fabrica_referencia(arquivo: UploadFile = File(...)):
    from esteira.estudio import fabrica
    try:
        return {"nome": fabrica.guardar_referencia(arquivo.filename or "ref.png", await arquivo.read())}
    except ValueError as e:
        raise HTTPException(400, str(e)) from None


@router.post("/fabrica/pedidos/{pid}/pausar")
def fabrica_pausar(pid: str, pausado: bool = True):
    from esteira.estudio import fabrica
    try:
        p = fabrica.pausar(pid, pausado)
    except KeyError as e:
        raise HTTPException(404, str(e)) from None
    if not pausado:
        fabrica.enfileirar(pid)
    return p.model_dump()


@router.post("/fabrica/pedidos/{pid}/rodar")
def fabrica_rodar(pid: str):
    from esteira.estudio import fabrica
    try:
        fabrica.pedido(pid)
    except KeyError as e:
        raise HTTPException(404, str(e)) from None
    return {"fila": fabrica.enfileirar(pid) is not None}


@router.post("/pecas/{id_}/revisar")
def revisar_peca(id_: str, corpo: Revisao):
    """aprovar | ajuste (texto = o que mudar) | variacao | reprovar (texto = motivo, vira regra no guia)."""
    from esteira.estudio import fabrica
    _peca(id_)
    try:
        return fabrica.revisar(id_, corpo.acao, corpo.texto, corpo.nota)
    except ValueError as e:
        raise HTTPException(400, str(e)) from None


class Previa(BaseModel):
    estilo: str
    formato: str = ""


@router.post("/pecas/{id_}/previa")
def previa_peca(id_: str, corpo: Previa):
    """MP4 curto da peça na pele do estilo (fila, motor de render)."""
    _peca(id_)
    _estilo(corpo.estilo)
    args = ["--style", corpo.estilo] + (["--format", corpo.formato] if corpo.formato in ("16:9", "9:16") else [])
    return fila.adicionar(f"peca:{id_}:{corpo.estilo}", "studio-piece-preview", args) or {"ok": True, "ja_na_fila": True}


@router.get("/pecas/{id_}/previas")
def previas_peca(id_: str):
    from esteira.estudio import peca
    _peca(id_)
    d = peca.previas_dir(id_)
    return [{"nome": a.stem, "url": f"/api/v1/estudio/pecas/{id_}/previas/{a.name}"} for a in sorted(d.glob("*.mp4"))]


@router.get("/pecas/{id_}/previas/{nome}")
def previa_arquivo(id_: str, nome: str):
    from esteira.estudio import peca
    _peca(id_)
    if not re.fullmatch(r"[a-z0-9-]+_\d+x\d+\.mp4", nome) or not (peca.previas_dir(id_) / nome).exists():
        raise HTTPException(404, "prévia inexistente")
    return FileResponse(peca.previas_dir(id_) / nome, media_type="video/mp4")


class ProvaCanais(BaseModel):
    estilos: list[str]


@router.post("/pecas/prova-canais")
def prova_canais(corpo: ProvaCanais):
    """Todas as peças aprovadas na pele de cada estilo (fila; ~1 min por estilo)."""
    if len(corpo.estilos) < 1:
        raise HTTPException(400, "escolha ao menos um estilo")
    for e in corpo.estilos:
        _estilo(e)
    return fila.adicionar("acervo:prova", "studio-channel-proof", ["--styles", *corpo.estilos]) or {"ok": True, "ja_na_fila": True}


@router.get("/pecas/prova-canais")
def prova_canais_resultado():
    from esteira.estudio import peca
    arq = peca.previas_dir("_canais").parent / "_prova_canais" / "resultado.json"
    if not arq.exists():
        return {"folhas": [], "problemas": [], "estilos": []}
    r = json.loads(arq.read_text())
    r["folhas"] = [f"/api/v1/estudio/pecas/prova-canais/{n}" for n in r["folhas"]]
    return r


@router.get("/pecas/prova-canais/{nome}")
def prova_canais_folha(nome: str):
    from esteira.estudio import peca
    arq = peca.previas_dir("_canais").parent / "_prova_canais" / nome
    if not re.fullmatch(r"[a-z0-9-]+_\d+x\d+\.jpg", nome) or not arq.exists():
        raise HTTPException(404, "folha inexistente")
    return FileResponse(arq, media_type="image/jpeg")


@router.get("/fabrica/comparacao")
def fabrica_comparacao():
    """HTML × EffectCraft: geral, por intenção e a sugestão de motor por intenção."""
    from esteira.estudio import fabrica
    return fabrica.comparacao()


@router.put("/fabrica/motores")
def fabrica_motores(corpo: Motores):
    """Aplica a decisão de motor por intenção (usada pelos pedidos com motor "auto")."""
    from esteira.estudio import fabrica
    return fabrica.aplicar_motores(corpo.por_intencao, corpo.padrao)


# ── perfis de ritmo (estudio/ritmo.py): longo e curto, como dado ──

@router.get("/ritmos")
def ritmos():
    from esteira.estudio import ritmo
    return [p.model_dump() for p in ritmo.listar()]


@router.put("/ritmos/{id_}")
def salvar_ritmo(id_: str, corpo: dict):
    """Ajusta um perfil (a semente fica; a cópia editada vai para os dados)."""
    from esteira.estudio import ritmo
    try:
        p = ritmo.Perfil.model_validate({**corpo, "id": id_})
    except ValidationError as e:
        raise HTTPException(400, str(e)[:400]) from None
    return ritmo.salvar(p).model_dump()


@router.get("/fabrica/ampliacao")
def fabrica_ampliacao():
    from esteira.estudio import fabrica
    return fabrica.ampliacao().model_dump()


@router.put("/fabrica/ampliacao")
def salvar_fabrica_ampliacao(corpo: dict):
    """Liga/ajusta a ampliação contínua do acervo pelas lacunas (um pedido por dia, dentro do teto)."""
    from esteira.estudio import fabrica
    try:
        a = fabrica.salvar_ampliacao(**corpo)
    except ValidationError as e:
        raise HTTPException(400, str(e)[:300]) from None
    p, motivo = fabrica.ampliar()
    return {**a.model_dump(), "agora": motivo, "pedido": p.id if p else None}


# ── linha do tempo por bloco (direção nova): trocar peça e render só do bloco ──

class Troca(BaseModel):
    peca: str


@router.post("/producoes/{ep}/cenas/{cid}/trocar")
def trocar_peca(ep: str, cid: int, corpo: Troca):
    """Troca a peça da cena por outra (uma das candidatas, um clique): a IA local preenche a nova, a troca vira caso
    do gabarito (`bloco_peca`) e a cena fica `manual` (o replanejamento mantém)."""
    from esteira.estudio import direcao, peca
    _peca(corpo.peca)
    arq = _ep(ep) / "estudio" / "mapa.json"
    if not arq.exists():
        raise HTTPException(404, "sem mapa: rode a etapa dirigir")
    mapa = json.loads(arq.read_text())
    c = next((c for c in mapa["cenas"] if c["id"] == cid), None)
    if not c:
        raise HTTPException(404, "cena inexistente")
    antes = dict(c)
    try:
        direcao.refazer_cena(c, peca.carregar(corpo.peca))
    except ValueError as e:
        raise HTTPException(409, str(e)) from None
    if antes.get("candidatas") and antes["cena"] != corpo.peca:
        direcao.gabarito(ep, antes, corpo.peca, "troca")
    proxima = next((x for x in mapa["cenas"] if x["t"] > c["t"]), None)
    if proxima:
        c["ate"] = round(min(c["ate"], proxima["t"] - 0.05), 3)
    arq.write_text(json.dumps(mapa, ensure_ascii=False, indent=1))
    return c


class RenderBloco(BaseModel):
    formatos: list[str] = []


@router.post("/producoes/{ep}/blocos/{bloco}/render")
def render_bloco(ep: str, bloco: int, corpo: RenderBloco):
    """Render só do bloco (fila): trecho → emenda no vídeo já renderizado → loudness e prévia."""
    _ep(ep)
    args = ["--block", str(bloco)] + (["--formats", *corpo.formatos] if corpo.formatos else [])
    return fila.adicionar(ep, "studio-block", args) or {"ok": True, "ja_na_fila": True}


# ── base de aprovações → fine-tune (estudio/treino.py) ──

@router.get("/treino")
def treino_situacao():
    from esteira.estudio import treino
    return {**treino.situacao(), "ambiente": treino.ambiente().exists()}


@router.post("/treino/exportar")
def treino_exportar():
    from esteira.estudio import treino
    return treino.exportar()


@router.post("/treino/treinar")
def treino_treinar():
    """Treino LoRA na GPU (fila, vaga da máquina): horas; o GGUF vai para a pasta de modelos."""
    from esteira.estudio import treino
    if not treino.ambiente().exists():
        raise HTTPException(409, "ambiente de treino ausente (.venv-treino com unsloth)")
    return fila.adicionar("treino:lora", "training", ["train"]) or {"ok": True, "ja_na_fila": True}
