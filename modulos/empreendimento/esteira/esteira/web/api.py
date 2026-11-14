"""API JSON do painel (`/api/v1`), consumida pelo app Flutter (módulo Empreendimento da plataforma).

Mesma regra do painel htmx: nenhuma lógica própria de produção. Leituras usam as mesmas funções das páginas
e toda ação de etapa entra na fila (`esteira.web.fila`), que roda os comandos do `./dark`. Arquivos do
episódio (thumbs, vídeo, áudio, quadros) são servidos por `/arq/{ep}/{caminho}`; PDFs do vault por `/pdf`.

Este módulo: biblioteca, episódio (geral, roteiro, cortes, cenas, gráficos, thumbs) e fila. O editor está
em `api_editor.py`; monitor, processos, opções, custos e acervo em `api_sistema.py`.
"""
import json
import re
from pathlib import Path
from urllib.parse import quote

from esteira.core import status
from esteira.fontes import gravacoes, obsidian
from esteira.projeto import Projeto, ep_id, episodios, pasta_ep
from esteira.web import app as painel
from esteira.web import fila
from fastapi import APIRouter, File, HTTPException, UploadFile
from pydantic import BaseModel

router = APIRouter(prefix="/api/v1", tags=["app"])

ACOES = painel.PIPELINE + ["all", "frames", "transcribe", "export"]


def _episodios(canal=""):
    """Episódios de verdade (com roteiro.json), do canal pedido ou de todos."""
    return [p for p in episodios() if (p / "roteiro.json").exists() and (not canal or p.parent.name == canal)]


def _json(arq, padrao=None):
    try:
        return json.loads(arq.read_text()) if arq.exists() else padrao
    except ValueError:
        return padrao


def _video_leve(ep, final):
    """O final da montagem tem 300–400 MB com o índice (moov) no fim: o player do celular precisa de tudo antes
    de tocar. O app toca a `previa.mp4` (540p, faststart, começa na hora); enquanto ela não existe ou está
    mais velha que o final, é gerada ao fundo e vai o final."""
    if not final.exists():
        return None
    previa, pasta = final.with_name("previa.mp4"), pasta_ep(ep)
    if previa.exists() and previa.stat().st_mtime >= final.stat().st_mtime:
        return f"/arq/{ep}/{previa.relative_to(pasta)}?v={_v(previa)}"
    from esteira.web.api_estudio import _previa_ao_fundo
    _previa_ao_fundo(final)
    return f"/arq/{ep}/{final.relative_to(pasta)}?v={_v(final)}"


def _v(arq):
    """Sufixo de versão para a URL do arquivo (o app não reaproveita imagem antiga do cache)."""
    return int(arq.stat().st_mtime)


def _thumbs(pasta, ep):
    return [{"vaga": k, "url": f"/arq/{ep}/thumb_{k}.png?v={_v(a)}"}
            for k in (1, 2, 3) if (a := pasta / f"thumb_{k}.png").exists()]


def _resumo(pasta):
    ep = ep_id(pasta)
    return {"id": ep, "canal": pasta.parent.name, "numero": pasta.name,
            "titulo": (_json(pasta / "roteiro.json", {}) or {}).get("titulo", ""),
            "prog": painel._resumo_ep(ep), "thumbs": _thumbs(pasta, ep)}


def _projeto(ep):
    return Projeto(painel._pasta(ep))


# ---------- Metadados (nomes das etapas e quem faz cada operação) ----------

@router.get("/meta")
def meta():
    return {"pipeline": painel.PIPELINE, "nomes": painel.NOMES,
            "motores": {k: [{"motor": m, "rotulo": r} for m, r in v] for k, v in painel.MOTORES.items()},
            "motor_ia": painel._motor_ia()}


# ---------- Biblioteca (roteiros do vault) ----------

@router.get("/canais")
def canais():
    vault = painel._cfg()["fontes"]["vault"]
    base = obsidian.pasta_canais(vault)
    eps = _episodios()
    return [{"id": c, "roteiros": sum(len(list((base / c / sub).glob("*.md"))) for sub in ("Roteiros", "Shorts")),
             "episodios": sum(1 for p in eps if p.parent.name == c)} for c in obsidian.canais(vault)]


def _template(ep):
    if not ep:
        return None
    from esteira import estudio
    return estudio.template(Projeto(pasta_ep(ep)))


@router.get("/canais/{canal}/roteiros")
def roteiros(canal: str):
    cfg = painel._cfg()["fontes"]
    if canal not in obsidian.canais(cfg["vault"]):
        raise HTTPException(404, "canal não encontrado")
    modo_perfil = None
    itens = []
    for r in obsidian.listar(cfg["vault"], canal):
        audio = gravacoes.candidatos(cfg["gravacoes"], canal, r["numero"], r["titulo"], n=1, short=bool(r["short"]))
        audio = audio[0] if audio and audio[0]["nota"] >= 0.5 else None
        ep = painel._projeto_do_roteiro(r["caminho"])
        definido = r["modo"] in ("dark", "apresentador")
        if definido:
            modo = r["modo"]
        elif ep:
            modo = Projeto(pasta_ep(ep)).cfg.get("producao", {}).get("modo", "dark")
        else:
            modo = modo_perfil = modo_perfil or painel._modo_do_perfil(canal)
        citacoes = len(re.findall(r"^>\s*\[!cite\]", Path(r["caminho"]).read_text(), re.M))
        itens.append({**r, "audio": bool(audio), "audio_mb": round(audio["mb"]) if audio else None,
                      "modo": modo, "modo_definido": definido, "citacoes": citacoes, "ep": ep,
                      "template": _template(ep),
                      "prog": painel._resumo_ep(ep) if ep else None})
    return itens


class GerarRoteiro(BaseModel):
    alvo: str
    ate: str = ""
    motor: str = "local"


@router.post("/roteiros/gerar")
def gerar_roteiro(corpo: GerarRoteiro):
    """Roteiro(s) do plano do canal na fila (`./dark script canal:N [--to M] [--engine claude]`)."""
    alvo = corpo.alvo.strip()
    if not re.fullmatch(r"[a-z0-9_-]+:\d+", alvo):
        raise HTTPException(400, "use canal:N, ex.: finlumia:51")
    ate = corpo.ate.strip()
    return fila.adicionar(alvo, "script", ["--to", ate] if ate.isdigit() else [], corpo.motor)


class Produzir(BaseModel):
    roteiros: list[str]
    templates: dict[str, str] = {}  # caminho do roteiro → template `id@N` da produção no Estúdio


@router.post("/produzir")
def produzir(corpo: Produzir):
    """Importa os roteiros do vault (se ainda não viraram episódio), grava o template escolhido e põe `tudo` na fila."""
    from esteira import estudio
    from esteira.estudio import estilo
    from esteira.fontes.importar import importar
    vault = Path(painel._cfg()["fontes"]["vault"]).expanduser().resolve()
    for ref in corpo.templates.values():
        try:
            estilo.carregar(ref)
        except (KeyError, ValueError):
            raise HTTPException(400, f"template inexistente: {ref}") from None
    tarefas = []
    for caminho in corpo.roteiros:
        if vault not in Path(caminho).resolve().parents:
            raise HTTPException(400, f"roteiro fora do vault: {caminho}")
        ep = painel._projeto_do_roteiro(caminho) or ep_id(importar(Path(caminho)))
        if ref := corpo.templates.get(caminho):
            estudio.escolher_template(Projeto(pasta_ep(ep)), ref)
        tarefas.append(fila.adicionar(ep, "all"))
    return tarefas


# ---------- Episódio: geral ----------

@router.get("/episodios")
def lista_episodios(canal: str = ""):
    return [_resumo(p) for p in reversed(_episodios(canal))]


@router.get("/episodios/{ep}")
def episodio(ep: str):
    from esteira import producao
    from esteira.ai import claude
    pasta = painel._pasta(ep)
    proj = Projeto(pasta)
    rot = _json(pasta / "roteiro.json", {}) or {}
    est = status.stages(pasta)
    nomes = painel.PIPELINE + [e for e in est if e not in painel.PIPELINE]
    etapas = [{"id": e, "nome": painel.NOMES.get(e, e), **(est.get(e) or {"status": "pending"})} for e in nomes]
    evs = [e for e in status.events(pasta) if e["kind"] in ("output", "warning", "error", "claude", "start", "end")]
    final, thumb = painel.final_do_ep(pasta), pasta / "thumb.png"
    modo = producao.modo(proj)
    camera = producao.info_camera(proj) if modo == "apresentador" and producao.camera(proj) else None
    return {**_resumo(pasta), "etapas": etapas, "eventos": evs[-40:][::-1], "gasto_claude": claude.spent(ep)[0],
            "video": _video_leve(ep, final),
            "thumb": f"/arq/{ep}/thumb.png?v={_v(thumb)}" if thumb.exists() else None,
            "vertical": proj.cfg["video"].get("formato", "16:9") == "9:16", "modo": modo,
            "camera": camera if modo == "apresentador" else None, "sem_camera": modo == "apresentador" and not camera,
            "partes": len(rot.get("capitulos", [])), "notas": len(rot.get("notas", [])),
            "citacoes": len(rot.get("citacoes", [])), "fontes": rot.get("fontes", []),
            "fcproj": (pasta / "projeto.fcproj").exists(),
            "manuais": sorted(p.name for p in pasta.glob("projeto.manual-*.fcproj")),
            "motor_ia": painel._motor_ia()}


class Rodar(BaseModel):
    refazer: bool = False
    motor: str = ""
    so_render: bool = False


@router.post("/episodios/{ep}/rodar/{etapa}")
def rodar(ep: str, etapa: str, corpo: Rodar | None = None):
    from esteira.core import options
    painel._pasta(ep)
    if etapa not in ACOES:
        raise HTTPException(400, "etapa desconhecida")
    corpo = corpo or Rodar()
    args = ["--redo"] if corpo.refazer and etapa in ("clean", "curate", "fetch", "all") else []
    if corpo.so_render and etapa == "graphics":
        args = ["--render-only"]
    return fila.adicionar(ep, etapa, args, corpo.motor or options.read()["engine"])


@router.post("/episodios/{ep}/abrir")
def abrir_filmcraft(ep: str):
    """Abre o projeto do vídeo no FilmCraft (na máquina onde o painel roda)."""
    from esteira.montar import abrir
    abrir(_projeto(ep))
    return {"ok": True}


# ---------- Episódio: roteiro (como a esteira leu o vault) ----------

@router.get("/episodios/{ep}/roteiro")
def roteiro(ep: str):
    """Partes com notas de cena, falas e citações. Textos crus: *destaque* nas falas, **negrito** nas notas."""
    pasta = painel._pasta(ep)
    rot = _json(pasta / "roteiro.json")
    if rot is None:
        raise HTTPException(404, "projeto sem roteiro.json: importe do vault")
    falas = [l for l in (pasta / "roteiro.txt").read_text().splitlines()[1:] if l.strip()]
    graficos = _json(pasta / "graficos.json", []) or []
    na_tela = {g["dados"].get("trecho") for g in graficos if g["modelo"] == "citacao" and g.get("arquivo")}
    caps = rot.get("capitulos", [])
    partes = []
    for i, cap in enumerate(caps):
        fim = caps[i + 1]["fala"] if i + 1 < len(caps) else len(falas)
        itens = []
        for k in range(cap["fala"], fim):
            itens += [{"tipo": "cena", "texto": n["texto"]} for n in rot.get("notas", []) if n["antes_da_fala"] == k]
            itens.append({"tipo": "fala", "n": k + 1, "texto": falas[k]})
            for j, c in enumerate(rot.get("citacoes", [])):
                if c["fala"] != k:
                    continue
                rec = painel._recorte_citacao(pasta, j, c) if c.get("ok") and Path(c["arquivo"]).exists() else None
                if rec:
                    rec = {**rec, "url": f"/arq/{ep}/graficos/{rec['img']}"}
                itens.append({"tipo": "cite", "c": c, "recorte": rec, "no_video": c["en"] in na_tela,
                              "pdf": f"/pdf?arq={quote(c['arquivo'])}#page={c.get('pagina', 1)}" if c.get("arquivo") else None})
        partes.append({"parte": cap.get("parte"), "nome": cap.get("nome", ""), "itens": itens})
    citadas = {re.split(r"[ ,]", c["autores"])[0].lower() for c in rot.get("citacoes", []) if c.get("autores")}
    fontes = [{**f, "situacao": "citação na tela" if re.split(r"[ ,]", f.get("autores", ""))[0].lower() in citadas
               else "só tarja / lista"} for f in rot.get("fontes", [])]
    return {"titulo": rot.get("titulo", ""), "formato": rot.get("formato") or "16:9", "origem": rot.get("origem"),
            "partes": partes, "fontes": fontes, "n_falas": len(falas),
            "palavras": sum(len(f.split()) for f in falas), "n_notas": len(rot.get("notas", [])),
            "n_citacoes": len(rot.get("citacoes", [])), "tem_graficos": bool(graficos)}


# ---------- Episódio: cortes da narração ----------

@router.get("/episodios/{ep}/cortes")
def cortes(ep: str, filtro: str = "revisar"):
    pasta = painel._pasta(ep)
    dados = _json(pasta / "cortes.json")
    if dados is None:
        raise HTTPException(404, "os cortes ainda não foram decididos")
    trechos = [dict(t, k=k) for k, t in enumerate(dados["trechos"])]
    if filtro == "revisar":
        trechos = [t for t in trechos if t["tipo"] != "tomada" or t["confianca"] < 0.85]
    elif filtro == "cortados":
        trechos = [t for t in trechos if not t["manter"]]
    bruta = next(pasta.glob("narracao_bruta.*"), None)
    return {"trechos": trechos, "faltando": dados["faltando"], "editado": dados.get("editado_no_painel", False),
            "bruta": f"/arq/{ep}/{bruta.name}?v={_v(bruta)}" if bruta else None}


@router.post("/episodios/{ep}/cortes/{k}/alternar")
def alternar_corte(ep: str, k: int):
    """Inverte fica/sai de um trecho (vale ao rodar o `limpar` de novo)."""
    arq = painel._pasta(ep) / "cortes.json"
    dados = json.loads(arq.read_text())
    if not 0 <= k < len(dados["trechos"]):
        raise HTTPException(404, "trecho não encontrado")
    t = dados["trechos"][k]
    t["manter"] = not t["manter"]
    t["por"] = "painel"
    t["motivo"] = t["motivo"].split(" → painel")[0] + f" → painel: {'fica' if t['manter'] else 'sai'}"
    dados["editado_no_painel"] = True
    arq.write_text(json.dumps(dados, ensure_ascii=False, indent=1))
    return dict(t, k=k)


# ---------- Episódio: cenas (linha do tempo) ----------

def _rotulo_grafico(g):
    d = g.get("dados") or {}
    texto = (d.get("nome") or d.get("texto") or d.get("titulo") or d.get("linha1") or d.get("nome_a")
             or d.get("autores") or d.get("citacao") or (g["caixas"][0]["texto"] if g.get("caixas") else ""))
    return str(texto).replace("*", "")


@router.get("/episodios/{ep}/cenas")
def cenas(ep: str):
    pasta = painel._pasta(ep)
    plano = _json(pasta / "plano.json")
    if plano is None:
        raise HTTPException(404, "as cenas ainda não foram geradas")
    graficos = _json(pasta / "graficos.json", []) or []
    saida = []
    for c in plano["cenas"]:
        q = pasta / "midia" / f".aval_{c['id']:03d}.jpg"
        quadro = q.name if q.exists() else (Path(c["midia"]).name if (c.get("midia") or "").endswith(".jpg") else None)
        saida.append({k: c.get(k) for k in ("id", "inicio", "fim", "texto", "clima", "busca_en", "busca", "nota_midia",
                                            "midia_tipo", "problema_midia")}
                     | {"quadro": f"/arq/{ep}/midia/{quadro}" if quadro else None})
    return {"titulo": plano.get("titulo"), "cenas": saida,
            "graficos": [{"inicio": g["inicio"], "modelo": g["modelo"], "rotulo": _rotulo_grafico(g)[:40]}
                         for g in graficos]}


class Trocar(BaseModel):
    busca_en: str = ""


@router.post("/episodios/{ep}/cenas/{cid}/trocar")
def trocar_midia(ep: str, cid: int, corpo: Trocar):
    """Grava a busca nova da cena (se houver) e põe a busca só dessa cena na fila."""
    pasta = painel._pasta(ep)
    if corpo.busca_en.strip():
        arq = pasta / "plano.json"
        plano = json.loads(arq.read_text())
        for c in plano["cenas"]:
            if c["id"] == cid:
                c["busca_en"] = corpo.busca_en.strip()
        arq.write_text(json.dumps(plano, ensure_ascii=False, indent=2))
    return fila.adicionar(ep, "fetch", ["--redo", "--scenes", str(cid)])


# ---------- Episódio: gráficos animados ----------

@router.get("/episodios/{ep}/graficos")
def graficos(ep: str):
    pasta = painel._pasta(ep)
    lista = _json(pasta / "graficos.json")
    if lista is None:
        raise HTTPException(404, "os gráficos ainda não foram planejados")
    v = Projeto(pasta).cfg["video"]
    saida, por_tipo = [], {}
    for i, g in enumerate(lista):
        ecp = pasta / g["ecproj"] if g.get("ecproj") else None
        nome = g["arquivo"].split("/")[-1] if g.get("arquivo") else None
        por_tipo[g["modelo"]] = por_tipo.get(g["modelo"], 0) + 1
        saida.append({"i": i, "inicio": g["inicio"], "dur": g["dur"], "modelo": g["modelo"],
                      "manual": bool(g.get("manual")), "roteiro": bool(g.get("roteiro")), "origem": g.get("origem"),
                      "rotulo": _rotulo_grafico(g), "manual_ec": bool(g.get("manual_ec")),
                      "ec_editado": bool(ecp and ecp.exists() and ecp.stat().st_mtime > g.get("ec_gerado", 0) + 1),
                      "previa": f"/ep/{ep}/previa/{nome}" if nome else None})
    return {"graficos": saida, "por_tipo": por_tipo, "editados_ec": sum(g["ec_editado"] for g in saida),
            "vertical": v["altura"] > v["largura"]}


@router.post("/episodios/{ep}/graficos/{i}/effectcraft")
def abrir_effectcraft(ep: str, i: int):
    r = painel.abrir_effectcraft(ep, i)
    if getattr(r, "status_code", 303) == 400:
        raise HTTPException(400, r.body.decode())
    return {"ok": True}


# ---------- Episódio: thumbnails ----------

def _lista_thumbs(p):
    """Thumbs editáveis; .pcraft salvo à mão no PhotoCraft refaz o PNG antes (como a aba Thumbs do painel)."""
    from esteira import editor, photocraft
    marcas = p.caminho("thumbs/editadas_photocraft.json")
    feitas = set(_json(marcas, []) or [])
    lista = editor.thumbs(p)
    for t in lista:
        pc = p.caminho(f"thumbs/{t['arquivo']}").with_suffix(".pcraft")
        if photocraft.editado(pc):
            photocraft.exportar(pc)
            feitas.add(t["arquivo"])
            marcas.write_text(json.dumps(sorted(feitas)))
    for t in lista:
        t["pc_editado"] = t["arquivo"] in feitas
    return lista


@router.get("/episodios/{ep}/thumbs")
def thumbs(ep: str):
    from esteira import editor
    p = _projeto(ep)
    lista = _lista_thumbs(p)
    for t in lista:
        arq = p.caminho("thumbs") / t["arquivo"]
        t["url"] = f"/arq/{ep}/thumbs/{t['arquivo']}?v={_v(arq)}"
    return {"thumbs": lista, "vagas": _thumbs(p.pasta, ep),
            "fundos": [{"nome": f, "url": f"/arq/{ep}/thumbs/{f}"} for f in editor.fundos(p)]}


class UsarThumb(BaseModel):
    arquivo: str
    vaga: int


@router.post("/episodios/{ep}/thumbs/usar")
def usar_thumb(ep: str, corpo: UsarThumb):
    from esteira import editor
    try:
        editor.usar_thumb(_projeto(ep), corpo.arquivo, corpo.vaga)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"ok": True}


@router.post("/episodios/{ep}/thumbs/fundo")
async def enviar_fundo(ep: str, arquivo: UploadFile = File(...)):
    from esteira import editor
    sufixo = Path(arquivo.filename or "").suffix.lower()
    if sufixo not in (".png", ".jpg", ".jpeg", ".webp"):
        raise HTTPException(400, "envie PNG, JPG ou WebP")
    return {"nome": editor.guardar_fundo(_projeto(ep), await arquivo.read(), sufixo)}


class ArquivoThumb(BaseModel):
    arquivo: str


@router.post("/episodios/{ep}/thumbs/photocraft")
def abrir_photocraft(ep: str, corpo: ArquivoThumb):
    painel.abrir_photocraft(ep, corpo.arquivo)
    return {"ok": True}


# ---------- Pacotes de edição (baixar para editar em outra máquina e enviar de volta) ----------

def _alvo_edicao(ep, editor, i=None, arquivo=""):
    p = _projeto(ep)
    if editor == "filmcraft":
        alvo = p.caminho("projeto.fcproj")
        if not alvo.exists():
            raise HTTPException(400, "sem projeto.fcproj: rode o montar antes")
    elif editor == "effectcraft":
        alvo = painel.garantir_ecproj(ep, i)
        if not alvo:
            raise HTTPException(400, "a citação não achou o trecho no PDF")
    else:
        alvo = painel.garantir_pcraft(ep, arquivo)
    return p, Path(alvo)


def _baixar(ep, editor, i=None, arquivo=""):
    from esteira import pacote
    from fastapi.responses import FileResponse, StreamingResponse
    p, alvo = _alvo_edicao(ep, editor, i, arquivo)
    if alvo.suffix == ".pcraft":
        return FileResponse(alvo, filename=f"{ep}-{alvo.name}", media_type="application/octet-stream")
    nome = f"{ep}-{alvo.stem}"
    return StreamingResponse(pacote.empacotar(alvo, p.pasta, nome), media_type="application/zip",
                             headers={"Content-Disposition": f'attachment; filename="{nome}.zip"'})


async def _enviar(ep, editor, envio, i=None, arquivo=""):
    from esteira import pacote
    p, alvo = _alvo_edicao(ep, editor, i, arquivo)
    try:
        return pacote.receber(await envio.read(), alvo, p.pasta)
    except ValueError as e:
        raise HTTPException(400, str(e)) from e


@router.get("/episodios/{ep}/pacote/filmcraft")
def baixar_filmcraft(ep: str):
    """Zip com o projeto.fcproj (mídia com caminhos relativos) e a mídia que ele usa."""
    return _baixar(ep, "filmcraft")


@router.post("/episodios/{ep}/pacote/filmcraft")
async def enviar_filmcraft(ep: str, arquivo: UploadFile = File(...)):
    """Sobrescreve o projeto.fcproj (o anterior vai para log/envios/); depois, `exportar` refaz o vídeo."""
    return await _enviar(ep, "filmcraft", arquivo)


@router.get("/episodios/{ep}/graficos/{i}/pacote")
def baixar_grafico(ep: str, i: int):
    return _baixar(ep, "effectcraft", i)


@router.post("/episodios/{ep}/graficos/{i}/pacote")
async def enviar_grafico(ep: str, i: int, arquivo: UploadFile = File(...)):
    """O .ecproj enviado é renderizado como está na próxima renderização dos gráficos (`manual_ec`)."""
    return await _enviar(ep, "effectcraft", arquivo, i)


@router.get("/episodios/{ep}/thumbs/pacote")
def baixar_thumb(ep: str, arquivo: str):
    return _baixar(ep, "photocraft", arquivo=arquivo)


@router.post("/episodios/{ep}/thumbs/pacote")
async def enviar_thumb(ep: str, thumb: str, arquivo: UploadFile = File(...)):
    """O .pcraft enviado refaz o PNG da thumb ao listar as thumbs."""
    return await _enviar(ep, "photocraft", arquivo, arquivo=thumb)


# ---------- Fila ----------

@router.get("/fila")
def lista_fila():
    from esteira.core import locks, processes
    tarefas = list(reversed(fila.listar()))
    proc = {r.get("queue"): r["id"] for r in processes.list_recent(400) if r.get("queue")}
    for t in tarefas:
        p = pasta_ep(t["ep"]) if ":" not in t["ep"] else None
        t["prog"] = painel._resumo_ep(t["ep"]) if p and p.is_dir() else None
        t["processo"] = proc.get(str(t["id"]))
    return {"tarefas": tarefas, "vagas": {v: locks.owner(v) for v in locks.SLOTS}}


@router.post("/fila/{tid}/cancelar")
def cancelar(tid: int):
    fila.cancelar(tid)
    return {"ok": True}


@router.post("/fila/limpar")
def limpar_fila():
    fila.limpar_concluidas()
    return {"ok": True}


# ── bancada de LLM (Estúdio, fase 1) ──

class RodarBancada(BaseModel):
    modelos: list[str] = []
    tarefas: list[str] = []


@router.get("/bancada")
def ver_bancada():
    """Gabarito (casos por tarefa), modelos do roteador e o último resultado da bancada."""
    from esteira import bancada
    from esteira.ai import llama
    return {"gabarito": {t: len(bancada.casos(t)) for t in bancada.TAREFAS},
            "modelos": [m["id"] for m in llama.models() or []], "resultado": bancada.ultimo()}


@router.post("/bancada/rodar")
def rodar_bancada(corpo: RodarBancada):
    """Põe `./dark bench run` na fila (vaga da máquina: usa a GPU)."""
    from esteira import bancada
    if any(t not in bancada.TAREFAS for t in corpo.tarefas):
        raise HTTPException(400, f"tarefas válidas: {', '.join(bancada.TAREFAS)}")
    args = (["--models", ",".join(corpo.modelos)] if corpo.modelos else []) + (
        ["--tasks", ",".join(corpo.tarefas)] if corpo.tarefas else [])
    return fila.adicionar("run", "bench", args)
