"""API JSON da aba Estúdio do app (canais da rede, estilos, produções, portões, dependências).

Trabalho pesado vai para a fila (`./dark studio`, `studio-style`, `studio-install`, `bench`); aqui só lê e
grava dados. Arquivos da produção (final.mp4, folha.jpg, quadros) saem por `/arq/<ep>/estudio/...`.
"""
import json
import re
import threading
from pathlib import Path

from esteira.project import PROJECTS, ep_id, folder_ep
from esteira.web import queue
from fastapi import APIRouter, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, ValidationError

router = APIRouter(prefix="/api/v1/estudio", tags=["estudio"])


def _style(id_):
    from esteira.studio import style
    try:
        return style.load(id_)
    except (KeyError, ValueError) as e:
        raise HTTPException(404, str(e)) from None


def _ep(ep):
    p = folder_ep(ep)
    if not p.is_dir():
        raise HTTPException(404, f"episódio inexistente: {ep}")
    return p


# ── canais e estilos ──

@router.get("/canais")
def channels():
    from esteira.studio import style
    todos = style.list_all()
    return [{"canal": c, "episodios": len([p for p in (PROJECTS / c).glob("*") if p.is_dir()]) if (PROJECTS / c).is_dir() else 0,
             "estilos": [{"id": e.id, "nome": e.nome, "modo": e.modo, "formatos": e.formatos, "versao": e.versao,
                          "travado": e.travado, "destaque": e.pele.destaque, "fundo": e.pele.fundo}
                         for e in todos if e.canal == c]}
            for c in style.channels()]


def _version(e):
    from esteira.studio import sample, style
    return {"ref": f"{e.id}@{e.versao}", "id": e.id, "versao": e.versao, "rotulo": style.label(e), "nome": e.nome,
            "modo": e.modo, "formatos": e.formatos, "travado": e.travado, "salvo_em": e.salvo_em,
            "destaque": e.pele.destaque, "fundo": e.pele.fundo, "amostras": sample.state(e),
            "amostra_base": f"/api/v1/estudio/amostras/{e.id}-v{e.versao}"}


@router.get("/templates")
def templates(canal: str):
    """Templates do canal com todas as versões guardadas (`ref` = `id@N`, o que a produção usa) e os exemplos."""
    from esteira.studio import style
    return [{"id": e.id, "nome": e.nome, "modo": e.modo, "formatos": e.formatos,
             "versoes": [_version(v) for v in style.versions(e.id)]} for e in style.list_all(canal)]


class NewTemplate(BaseModel):
    canal: str
    modo: str = "dark"
    formatos: list[str] = ["16:9", "9:16"]
    nome: str = ""


@router.post("/templates")
def new_template(corpo: NewTemplate):
    from esteira.studio import style
    if corpo.modo not in ("dark", "apresentador", "curso") or not corpo.formatos \
            or any(f not in ("16:9", "9:16") for f in corpo.formatos):
        raise HTTPException(400, "modo: dark/apresentador/curso · formatos: 16:9, 9:16")
    try:
        return style.new(corpo.canal, corpo.modo, corpo.formatos, corpo.nome)
    except ValueError as x:
        raise HTTPException(400, str(x)[:300]) from None


@router.post("/templates/{ref}/amostra")
def generate_sample(ref: str):
    """Exemplo de 30 s da versão nos formatos dela, na fila (render na GPU)."""
    e = _style(ref)
    t = queue.add(f"{e.id}@{e.versao}", "studio-sample")
    if t is None:
        raise HTTPException(409, "o exemplo desta versão já está na fila")
    return t


@router.get("/amostras/{nome}/{formato}.mp4")
def file_sample(nome: str, formato: str):
    from esteira.studio import sample
    arq = sample.FOLDER / Path(nome).name / Path(formato).name / "previa.mp4"
    if formato not in ("16x9", "9x16") or not arq.is_file():
        raise HTTPException(404, "exemplo ainda não gerado")
    return FileResponse(arq, media_type="video/mp4")


class Template(BaseModel):
    estilo: str


@router.put("/producoes/{ep}/template")
def choose_template(ep: str, corpo: Template):
    """Template (`id@N`) que o episódio vai usar na produção (escolhido na aba Roteiros)."""
    from esteira import studio
    from esteira.project import Project
    _style(corpo.estilo)
    studio.choose_template(Project(_ep(ep)), corpo.estilo)
    return {"ok": True, "estilo": corpo.estilo}


class NewChannel(BaseModel):
    slug: str
    nome: str
    nicho: str = ""
    cor: str = "#f5c518"
    modo: str = "dark"


@router.post("/canais")
def new_channel(corpo: NewChannel):
    from esteira.studio import style
    try:
        return style.new_channel(corpo.slug.strip().lower(), corpo.nome.strip(), corpo.nicho, corpo.cor, corpo.modo)
    except (ValueError, FileExistsError) as e:
        raise HTTPException(400, str(e)) from None


@router.get("/estilos/{id_}")
def show_style(id_: str):
    from esteira.studio import identity
    e = _style(id_)
    refs = sorted(f.name for f in identity.folder_refs(id_).iterdir() if f.is_file())
    return {"estilo": e, "referencias": refs}


@router.put("/estilos/{id_}")
def save_style(id_: str, corpo: dict):
    from esteira.studio import style
    try:
        e = style.Style.model_validate({**corpo, "id": id_})
        return style.save(e)
    except PermissionError as x:
        raise HTTPException(409, str(x)) from None
    except ValueError as x:
        raise HTTPException(400, str(x)[:300]) from None


class Duplicate(BaseModel):
    id: str
    nome: str


@router.post("/estilos/{id_}/duplicar")
def duplicate_style(id_: str, corpo: Duplicate):
    """Template novo a partir de um estilo (tudo igual, destravado, versão 1)."""
    from esteira.studio import style
    _style(id_)
    try:
        return style.duplicate(id_, corpo.id, corpo.nome)
    except FileExistsError as x:
        raise HTTPException(409, str(x)) from None
    except ValueError as x:
        raise HTTPException(400, str(x)[:300]) from None


@router.get("/niveis")
def levels():
    """Tabela dos níveis baixa/média/alta (o app mostra o que cada um preenche)."""
    from esteira.bench import SCENES
    from esteira.studio import style, triggers
    return {"niveis": style.LEVELS, "broll": style.BROLL, "sfx_chave": list(style.SFX_KEY),
            # catálogos das abas do estilo: peças do kit, condições dos gatilhos, curvas e efeitos que dá para proibir
            "pecas": SCENES, "condicoes": triggers.CONDITIONS, "curvas": list(style.CURVES),
            "proibiveis": list(style.FORBIDDABLE), "gatilhos_padrao": [g.model_dump() for g in triggers.default()]}


class Test(BaseModel):
    texto: str = ""  # trecho colado
    ep: str = ""  # ou um episódio (tempos reais do corte, se houver; senão o roteiro)
    estilo: dict | None = None  # rascunho ainda não salvo (o app testa o que está na tela)


@router.post("/estilos/{id_}/testar")
def test_style(id_: str, corpo: Test):
    """Decupagem do roteiro pelos gatilhos do estilo, sem IA e sem render: cenas, ritmo e avisos."""
    from esteira.studio import style, triggers
    e = _style(id_)
    if corpo.estilo:
        try:
            e = style.Style.model_validate({**corpo.estilo, "id": e.id})
        except ValueError as x:
            raise HTTPException(400, str(x)[:300]) from None
    frases = None
    if corpo.ep:
        from esteira.project import Project
        pr = Project(_ep(corpo.ep))
        if (pr.pasta / "frases.json").is_file():
            from esteira.studio import cut
            frases = cut.sentences(pr)
        elif pr.roteiro():
            frases = triggers.sentences_of_text(pr.roteiro().read_text())
    elif corpo.texto.strip():
        frases = triggers.sentences_of_text(corpo.texto)
    if not frases:
        raise HTTPException(400, "cole um trecho ou escolha um episódio com roteiro")
    return triggers.test(frases[:200], e)


@router.get("/fontes")
def list_fonts():
    from esteira.studio import fonts
    return fonts.list_all()


@router.get("/fontes/arquivo/{nome}")
def font_file(nome: str):
    """O .ttf/.otf para a prévia no app (FontLoader)."""

    from esteira.studio import fonts
    p = fonts.path(nome)
    if not p:
        raise HTTPException(404, "fonte inexistente")
    return FileResponse(p, media_type="font/ttf")


@router.post("/fontes")
async def upload_font(arquivo: UploadFile = File(...)):
    from esteira.studio import fonts
    try:
        return {"nome": fonts.send(arquivo.filename or "", await arquivo.read())}
    except ValueError as x:
        raise HTTPException(400, str(x)) from None


class Lock(BaseModel):
    travado: bool


@router.post("/estilos/{id_}/travar")
def lock_style(id_: str, corpo: Lock):
    from esteira.studio import style
    e = _style(id_)
    e.travado = corpo.travado
    return style.save(e, forcar=True, nova_versao=False)


@router.post("/estilos/{id_}/referencias")
async def send_reference(id_: str, arquivo: UploadFile = File(...)):
    from esteira.studio import identity
    _style(id_)
    nome = re.sub(r"[^\w.\-]+", "_", Path(arquivo.filename or "ref.jpg").name)
    if Path(nome).suffix.lower() not in (".jpg", ".jpeg", ".png", ".webp"):
        raise HTTPException(400, "envie imagens (jpg, png ou webp)")
    (identity.folder_refs(id_) / nome).write_bytes(await arquivo.read())
    return {"ok": True, "nome": nome}


@router.delete("/estilos/{id_}/referencias/{nome}")
def erase_reference(id_: str, nome: str):
    from esteira.studio import identity
    alvo = identity.folder_refs(id_) / Path(nome).name
    if alvo.is_file():
        alvo.unlink()
    return {"ok": True}


class Propose(BaseModel):
    nicho: str = ""


@router.post("/estilos/{id_}/propor")
def propose_style(id_: str, corpo: Propose):
    """Fluxo A na fila (pista do Claude): proposta de identidade a partir das referências."""
    _style(id_)
    return queue.add(id_, "studio-style", ["--niche", corpo.nicho] if corpo.nicho else [], "claude")


# ── produções ──

_generating = set()


def _preview_to_background(final):
    """Vídeos feitos antes da prévia leve: gera a prévia numa thread na primeira vez que a produção é aberta."""
    from esteira.studio import compiler
    if final in _generating:
        return
    _generating.add(final)

    def rodar():
        try:
            compiler.preview(final)
        except Exception as e:  # noqa: BLE001 — sem prévia o app toca o final.mp4
            print(f"prévia de {final}: {e}", flush=True)
        finally:
            _generating.discard(final)  # final refeito depois gera prévia nova

    threading.Thread(target=rodar, daemon=True).start()

@router.get("/producoes")
def productions(canal: str):
    from esteira import studio
    pasta = PROJECTS / canal
    if not pasta.is_dir():
        return []
    saida = []
    for p in sorted((x for x in pasta.iterdir() if x.is_dir() and (x / "frases.json").exists()), reverse=True):
        ep = ep_id(p)
        titulo = ""
        if (p / "roteiro.json").exists():
            titulo = json.loads((p / "roteiro.json").read_text()).get("titulo", "")
        saida.append({"ep": ep, "titulo": titulo, **studio.status(ep)})
    return saida


@router.get("/producoes/{ep}")
def production(ep: str):
    from esteira import studio
    p = _ep(ep)
    r = studio.status(ep)
    for fmt, d in r["formatos"].items():
        if d["final"] and not d["previa"]:
            _preview_to_background(p / "estudio" / fmt / "final.mp4")
    mapa = p / "estudio" / "mapa.json"
    m = json.loads(mapa.read_text()) if mapa.exists() else {}
    r["cenas"], r["blocos"], r["direcao"] = m.get("cenas", []), m.get("blocos", []), m.get("direcao", "frases")
    return r


class Produce(BaseModel):
    estilo: str = ""
    formatos: list[str] = []
    etapas: list[str] = []
    intensidade: dict[str, str] = {}


@router.post("/producoes/{ep}/produzir")
def produce(ep: str, corpo: Produce):
    from esteira import studio
    _ep(ep)
    if any(f not in ("16:9", "9:16") for f in corpo.formatos) or any(e not in studio.STAGES for e in corpo.etapas):
        raise HTTPException(400, "formatos: 16:9, 9:16 · etapas: " + ", ".join(studio.STAGES))
    args = (["--style", corpo.estilo] if corpo.estilo else []) + (["--formats", ",".join(corpo.formatos)] if corpo.formatos else []) \
        + (["--stages", ",".join(corpo.etapas)] if corpo.etapas else [])
    if any(k not in ("sfx", "motion", "efeitos") or v not in ("baixa", "media", "alta") for k, v in corpo.intensidade.items()):
        raise HTTPException(400, "intensidade: sfx/motion/efeitos = baixa/media/alta")
    if corpo.intensidade:
        args += ["--intensity", ",".join(f"{k}={v}" for k, v in corpo.intensidade.items())]
    t = queue.add(ep, "studio", args)
    if t is None:
        raise HTTPException(409, "esta produção já está na fila")
    return t


class Approval(BaseModel):
    aprovado: bool = True
    nota: str = ""


@router.post("/producoes/{ep}/aprovar/{portao}")
def approve(ep: str, portao: str, corpo: Approval):
    from esteira import studio
    _ep(ep)
    try:
        return studio.approve(ep, portao, corpo.aprovado, corpo.nota)
    except ValueError as e:
        raise HTTPException(400, str(e)) from None


@router.get("/producoes/{ep}/corte")
def show_cut(ep: str):
    """Corte pelo som: estado, emendas (com o texto em volta) e a conferência."""
    from esteira.studio import cut
    from esteira.project import Project
    projeto = Project(_ep(ep))
    c = cut.load(projeto) or {}

    def url(arq):
        return f"/arq/{ep}/{arq.relative_to(projeto.pasta)}?v={arq.stat().st_mtime_ns}" if arq.exists() else None
    return {"estado": cut.state(projeto), "emendas": c.get("emendas", []), "revertidas": c.get("revertidas", []),
            "conferencia": c.get("conferencia"), "editada": url(projeto.pasta / "narracao.wav"),
            "cortada": url(cut.folder(projeto) / "narracao.wav")}


@router.post("/producoes/{ep}/corte")
def cut(ep: str):
    _ep(ep)
    return queue.add(ep, "studio-cut") or {"ok": True, "ja_na_fila": True}


class Reversal(BaseModel):
    de: float
    ate: float
    reverter: bool = True


@router.put("/producoes/{ep}/corte/emenda")
def revert_splice(ep: str, corpo: Reversal):
    """Reverte (ou volta a cortar) uma emenda: reabre o portão 1 e põe o corte de novo na fila."""
    from esteira import studio
    from esteira.studio import cut
    from esteira.project import Project
    projeto = Project(_ep(ep))
    try:
        cut.revert(projeto, corpo.de, corpo.ate, corpo.reverter)
    except ValueError as e:
        raise HTTPException(409, str(e)) from None
    if studio.approvals(projeto).get("corte", {}).get("aprovado"):
        studio.approve(ep, "corte", False, "emenda revertida")
    return queue.add(ep, "studio-cut") or {"ok": True, "ja_na_fila": True}


@router.get("/producoes/{ep}/apontamento")
def show_marking(ep: str, estilo: str = ""):
    """Trechos da narração cortada com a cena marcada em cada um (auto / nenhuma / cena do cardápio)."""
    from esteira import studio
    from esteira.studio import marking, cut
    from esteira.studio import style as E
    from esteira.project import Project
    projeto = Project(_ep(ep))
    if not cut.state(projeto)["feito"]:
        raise HTTPException(409, "faça o corte pelo som antes do apontamento")
    est = E.load(estilo) if estilo else studio.style_default(projeto)
    if not est:
        raise HTTPException(404, "nenhum estilo para o canal")
    return {"estilo": est.id, **marking.script(projeto, est)}


class Mark(BaseModel):
    texto: str
    cena: str


class Marking(BaseModel):
    marcas: list[Mark] = []
    confirmar: bool = False
    produzir: Produce | None = None


@router.put("/producoes/{ep}/apontamento")
def save_marking(ep: str, corpo: Marking):
    """Grava as marcas; com `confirmar` libera o diretor e, com `produzir`, já põe a produção na fila."""
    from esteira.studio import marking
    from esteira.project import Project
    projeto = Project(_ep(ep))
    try:
        d = marking.save(projeto, [m.model_dump() for m in corpo.marcas], corpo.confirmar)
    except ValueError as e:
        raise HTTPException(400, str(e)) from None
    if corpo.confirmar and corpo.produzir:
        return {**d, "fila": produce(ep, corpo.produzir)}
    return d


class EditScene(BaseModel):
    cena: str
    titulo: str = ""
    valores: list[dict] = []


@router.put("/producoes/{ep}/cenas/{cid}")
def edit_scene(ep: str, cid: int, corpo: EditScene):
    """Ajuste à mão de uma cena do mapa (fica `manual`, o replanejamento mantém) — e vira caso do gabarito."""
    from esteira.bench import SCENES, ANSWER_KEY
    from esteira.studio import piece
    from esteira.studio.director import TAKEOVER
    ficha = piece.load(corpo.cena) if re.fullmatch(piece.ID, corpo.cena) and (piece.folder(corpo.cena) / "ficha.json").exists() else None
    if corpo.cena not in SCENES and not ficha:
        raise HTTPException(400, f"cena inválida: {corpo.cena}")
    arq = _ep(ep) / "estudio" / "mapa.json"
    if not arq.exists():
        raise HTTPException(404, "sem mapa: rode a etapa dirigir")
    mapa = json.loads(arq.read_text())
    c = next((c for c in mapa["cenas"] if c["id"] == cid), None)
    if not c:
        raise HTTPException(404, "cena inexistente")
    if mapa.get("direcao") == "blocos" and c.get("candidatas") and corpo.cena != c["cena"]:
        from esteira.studio import direction
        direction.answer_key(ep, c, corpo.cena, "troca")  # a troca da pessoa é a resposta certa da tarefa bloco_peca
    c.update(cena=corpo.cena, titulo=corpo.titulo, valores=corpo.valores, manual=True,
             takeover=ficha.tela_cheia if ficha else corpo.cena in TAKEOVER)
    if ficha:  # peça do acervo: título/valores viram os encaixes que ela tem; botões no padrão
        c["encaixes"] = piece.legacy({"titulo": corpo.titulo, "valores": corpo.valores}, ficha)
        c["botoes"] = piece.defaults(ficha)
        if mapa.get("direcao") == "blocos":  # a correção da pessoa é a resposta certa do preenchimento
            from esteira.studio import direction
            direction.answer_key_fill(ep, c, "corrigido")
    arq.write_text(json.dumps(mapa, ensure_ascii=False, indent=1))
    ANSWER_KEY.mkdir(parents=True, exist_ok=True)
    with open(ANSWER_KEY / "cena.jsonl", "a") as f:  # a escolha humana ensina a bancada (e o fine-tune depois)
        f.write(json.dumps({"id": f"aprov:{ep}:{c['frase_i']}", "frase": c["frase"], "antes": "", "aceitas": [corpo.cena]},
                           ensure_ascii=False) + "\n")
    return c


# ── dependências do motor ──

@router.get("/dependencias")
def dependencies():
    from esteira.studio import engine
    return engine.state()


@router.post("/dependencias/instalar")
def install():
    return queue.add("motor", "studio-install") or {"ok": True, "ja_na_fila": True}


# ── acervo de peças (estudio/pecas; docs/PLANO-ACERVO.md) ──

def _piece(id_):
    from esteira.studio import piece
    if not re.fullmatch(piece.ID, id_) or not (piece.folder(id_) / "ficha.json").exists():
        raise HTTPException(404, f"peça inexistente: {id_}")
    return piece.folder(id_)


def _summary_piece(p):
    from esteira.studio import piece
    arq = p / "prova" / "portao.json"
    portao = json.loads(arq.read_text()) if arq.exists() else None
    try:
        ficha = piece.Card.model_validate_json((p / "ficha.json").read_text()).model_dump()
    except ValueError:
        ficha = {"id": p.name, "estado": "rascunho", "invalida": True}
    # ?v= com a data do arquivo: peça refeita com o mesmo id não mostra o quadro antigo do cache do app
    quadros = [f"/api/v1/estudio/pecas/{p.name}/prova/{q}?v={int(a.stat().st_mtime) if (a := p / 'prova' / q).exists() else 0}"
               for q in (portao or {}).get("quadros", [])]
    return {"id": p.name, "ficha": ficha, "portao": portao, "quadros": quadros}


@router.get("/pecas")
def pieces():
    """Peças do acervo com a ficha e o último resultado do portão de entrada (inválidas também, para corrigir)."""
    from esteira.studio import piece
    return [_summary_piece(f.parent) for f in sorted(piece.FOLDER.glob("*/ficha.json"))]


@router.post("/pecas/{id_}/portao")
def gate_piece(id_: str):
    """Roda o portão de entrada (ficha, código e prova nas duas peles × formatos, ~10 s)."""
    from esteira.studio import piece
    p = _piece(id_)
    try:
        piece.gate(id_)
    except RuntimeError as e:
        raise HTTPException(409, str(e)) from None
    return _summary_piece(p)


@router.get("/pecas/{id_}/prova/{nome}")
def proof_piece(id_: str, nome: str):
    if not re.fullmatch(r"[a-z]+_\d+x\d+\.jpg", nome):
        raise HTTPException(404, "quadro inexistente")
    arq = _piece(id_) / "prova" / nome
    if not arq.exists():
        raise HTTPException(404, "quadro inexistente")
    return FileResponse(arq, media_type="image/jpeg")


# ── fábrica de peças (studio/factory.py): pedidos, revisão, lacunas ──

class NewRequest(BaseModel):
    tipo: str = "livre"
    texto: str = ""
    quantidade: int = 3
    teto_dia_usd: float = 3.0
    referencia: str = ""
    motor: str = "html"
    ia: str = "claude"  # "local": LLM local escreve as peças (só motor html)


class Review(BaseModel):
    acao: str
    texto: str = ""
    nota: int | None = None


class Engines(BaseModel):
    por_intencao: dict[str, str]
    padrao: str = "html"


@router.get("/fabrica")
def factory_summary():
    from esteira.studio import factory
    return factory.summary()


@router.get("/fabrica/painel")
def factory_panel():
    """Painel ao vivo: ideias (Claude) → N1 (LLM local) → portão → revisão (Claude) → acervo/dataset."""
    from esteira.studio import factory
    return factory.panel()


class RequestIdeas(BaseModel):
    quantidade: int = 24
    texto: str = ""


@router.post("/fabrica/ideias")
def factory_ideas(corpo: RequestIdeas):
    """O Claude cria ideias em lote e a LLM local executa cada uma em N1 (modo híbrido)."""
    from esteira.studio import factory
    p = factory.request_hybrid("ideias", max(1, min(corpo.quantidade, 50)), corpo.texto.strip())
    factory.enqueue(p.id)
    return p.model_dump()


@router.post("/fabrica/porte")
def factory_size():
    """Porte das peças HTML para EffectCraft pela LLM local: retoma o pedido de porte aberto ou cria um."""
    from esteira.studio import factory
    aberto = next((p for p in factory.requests() if p.tipo == "porte" and p.estado != "concluido"), None)
    p = factory.pause(aberto.id, False) if aberto else factory.request_hybrid("porte")
    factory.enqueue(p.id)
    return p.model_dump()


@router.post("/fabrica/pedidos")
def factory_request(corpo: NewRequest):
    from esteira.studio import factory
    try:
        p = factory.new_request(corpo.tipo, corpo.texto, corpo.quantidade, corpo.teto_dia_usd, corpo.referencia,
                                corpo.motor, corpo.ia)
    except (ValueError, ValidationError) as e:
        raise HTTPException(400, str(e)) from None
    factory.enqueue(p.id)
    return p.model_dump()


@router.post("/fabrica/citacao")
def factory_quote(teto_dia_usd: float = 3.0, motor: str = "html"):
    """Pedido pronto da primeira peça da fábrica: a citação de PDF (motor "ambos" gera nos dois para comparar)."""
    from esteira.studio import factory
    if motor not in ("html", "effectcraft", "ambos", "auto"):
        raise HTTPException(400, "motor: html, effectcraft, ambos ou auto")
    p = factory.request_quote(teto_dia_usd, motor)
    factory.enqueue(p.id)
    return p.model_dump()


@router.post("/fabrica/referencias")
async def factory_reference(arquivo: UploadFile = File(...)):
    from esteira.studio import factory
    try:
        return {"nome": factory.store_reference(arquivo.filename or "ref.png", await arquivo.read())}
    except ValueError as e:
        raise HTTPException(400, str(e)) from None


@router.post("/fabrica/pedidos/{pid}/pausar")
def factory_pause(pid: str, pausado: bool = True):
    from esteira.studio import factory
    try:
        p = factory.pause(pid, pausado)
    except KeyError as e:
        raise HTTPException(404, str(e)) from None
    if not pausado:
        factory.enqueue(pid)
    return p.model_dump()


@router.post("/fabrica/pedidos/{pid}/rodar")
def factory_run(pid: str):
    from esteira.studio import factory
    try:
        factory.request(pid)
    except KeyError as e:
        raise HTTPException(404, str(e)) from None
    return {"fila": factory.enqueue(pid) is not None}


@router.post("/pecas/{id_}/revisar")
def review_piece(id_: str, corpo: Review):
    """aprovar | ajuste (texto = o que mudar) | variacao | reprovar (texto = motivo, vira regra no guia)."""
    from esteira.studio import factory
    _piece(id_)
    try:
        return factory.review(id_, corpo.acao, corpo.texto, corpo.nota)
    except ValueError as e:
        raise HTTPException(400, str(e)) from None


class Preview(BaseModel):
    estilo: str
    formato: str = ""


@router.post("/pecas/{id_}/previa")
def preview_piece(id_: str, corpo: Preview):
    """MP4 curto da peça na pele do estilo (fila, motor de render)."""
    _piece(id_)
    _style(corpo.estilo)
    args = ["--style", corpo.estilo] + (["--format", corpo.formato] if corpo.formato in ("16:9", "9:16") else [])
    return queue.add(f"peca:{id_}:{corpo.estilo}", "studio-piece-preview", args) or {"ok": True, "ja_na_fila": True}


@router.get("/pecas/{id_}/previas")
def previews_piece(id_: str):
    from esteira.studio import piece
    _piece(id_)
    d = piece.previews_dir(id_)
    return [{"nome": a.stem, "url": f"/api/v1/estudio/pecas/{id_}/previas/{a.name}"} for a in sorted(d.glob("*.mp4"))]


@router.get("/pecas/{id_}/previas/{nome}")
def preview_file(id_: str, nome: str):
    from esteira.studio import piece
    _piece(id_)
    if not re.fullmatch(r"[a-z0-9-]+_\d+x\d+\.mp4", nome) or not (piece.previews_dir(id_) / nome).exists():
        raise HTTPException(404, "prévia inexistente")
    return FileResponse(piece.previews_dir(id_) / nome, media_type="video/mp4")


class ProofChannels(BaseModel):
    estilos: list[str]


@router.post("/pecas/prova-canais")
def proof_channels(corpo: ProofChannels):
    """Todas as peças aprovadas na pele de cada estilo (fila; ~1 min por estilo)."""
    if len(corpo.estilos) < 1:
        raise HTTPException(400, "escolha ao menos um estilo")
    for e in corpo.estilos:
        _style(e)
    return queue.add("acervo:prova", "studio-channel-proof", ["--styles", *corpo.estilos]) or {"ok": True, "ja_na_fila": True}


@router.get("/pecas/prova-canais")
def proof_channels_result():
    from esteira.studio import piece
    arq = piece.previews_dir("_canais").parent / "_prova_canais" / "resultado.json"
    if not arq.exists():
        return {"folhas": [], "problemas": [], "estilos": []}
    r = json.loads(arq.read_text())
    r["folhas"] = [f"/api/v1/estudio/pecas/prova-canais/{n}" for n in r["folhas"]]
    return r


@router.get("/pecas/prova-canais/{nome}")
def proof_channels_sheet(nome: str):
    from esteira.studio import piece
    arq = piece.previews_dir("_canais").parent / "_prova_canais" / nome
    if not re.fullmatch(r"[a-z0-9-]+_\d+x\d+\.jpg", nome) or not arq.exists():
        raise HTTPException(404, "folha inexistente")
    return FileResponse(arq, media_type="image/jpeg")


@router.get("/fabrica/comparacao")
def factory_comparison():
    """HTML × EffectCraft: geral, por intenção e a sugestão de motor por intenção."""
    from esteira.studio import factory
    return factory.comparison()


@router.put("/fabrica/motores")
def factory_engines(corpo: Engines):
    """Aplica a decisão de motor por intenção (usada pelos pedidos com motor "auto")."""
    from esteira.studio import factory
    return factory.aplicar_engines(corpo.por_intencao, corpo.padrao)


# ── perfis de ritmo (studio/rhythm.py): longo e curto, como dado ──

@router.get("/ritmos")
def rhythms():
    from esteira.studio import rhythm
    return [p.model_dump() for p in rhythm.list_all()]


@router.put("/ritmos/{id_}")
def save_rhythm(id_: str, corpo: dict):
    """Ajusta um perfil (a semente fica; a cópia editada vai para os dados)."""
    from esteira.studio import rhythm
    try:
        p = rhythm.Profile.model_validate({**corpo, "id": id_})
    except ValidationError as e:
        raise HTTPException(400, str(e)[:400]) from None
    return rhythm.save(p).model_dump()


@router.get("/fabrica/ampliacao")
def factory_expansion():
    from esteira.studio import factory
    return factory.expansion().model_dump()


@router.put("/fabrica/ampliacao")
def save_factory_expansion(corpo: dict):
    """Liga/ajusta a ampliação contínua do acervo pelas lacunas (um pedido por dia, dentro do teto)."""
    from esteira.studio import factory
    try:
        a = factory.save_expansion(**corpo)
    except ValidationError as e:
        raise HTTPException(400, str(e)[:300]) from None
    p, motivo = factory.expand()
    return {**a.model_dump(), "agora": motivo, "pedido": p.id if p else None}


# ── linha do tempo por bloco (direção nova): trocar peça e render só do bloco ──

class Swap(BaseModel):
    peca: str


@router.post("/producoes/{ep}/cenas/{cid}/trocar")
def swap_piece(ep: str, cid: int, corpo: Swap):
    """Troca a peça da cena por outra (uma das candidatas, um clique): a IA local preenche a nova, a troca vira caso
    do gabarito (`bloco_peca`) e a cena fica `manual` (o replanejamento mantém)."""
    from esteira.studio import direction, piece
    _piece(corpo.peca)
    arq = _ep(ep) / "estudio" / "mapa.json"
    if not arq.exists():
        raise HTTPException(404, "sem mapa: rode a etapa dirigir")
    mapa = json.loads(arq.read_text())
    c = next((c for c in mapa["cenas"] if c["id"] == cid), None)
    if not c:
        raise HTTPException(404, "cena inexistente")
    antes = dict(c)
    try:
        direction.redo_scene(c, piece.load(corpo.peca))
    except ValueError as e:
        raise HTTPException(409, str(e)) from None
    if antes.get("candidatas") and antes["cena"] != corpo.peca:
        direction.answer_key(ep, antes, corpo.peca, "troca")
    proxima = next((x for x in mapa["cenas"] if x["t"] > c["t"]), None)
    if proxima:
        c["ate"] = round(min(c["ate"], proxima["t"] - 0.05), 3)
    arq.write_text(json.dumps(mapa, ensure_ascii=False, indent=1))
    return c


class RenderBlock(BaseModel):
    formatos: list[str] = []


@router.post("/producoes/{ep}/blocos/{bloco}/render")
def render_block(ep: str, bloco: int, corpo: RenderBlock):
    """Render só do bloco (fila): trecho → emenda no vídeo já renderizado → loudness e prévia."""
    _ep(ep)
    args = ["--block", str(bloco)] + (["--formats", *corpo.formatos] if corpo.formatos else [])
    return queue.add(ep, "studio-block", args) or {"ok": True, "ja_na_fila": True}


# ── base de aprovações → fine-tune (studio/training.py) ──

@router.get("/treino")
def training_status():
    from esteira.studio import training
    return {**training.status(), "ambiente": training.environment().exists()}


@router.post("/treino/exportar")
def training_export():
    from esteira.studio import training
    return training.export()


@router.post("/treino/treinar")
def training_train():
    """Treino LoRA na GPU (fila, vaga da máquina): horas; o GGUF vai para a pasta de modelos."""
    from esteira.studio import training
    if not training.environment().exists():
        raise HTTPException(409, "ambiente de treino ausente (.venv-treino com unsloth)")
    return queue.add("treino:lora", "training", ["train"]) or {"ok": True, "ja_na_fila": True}
