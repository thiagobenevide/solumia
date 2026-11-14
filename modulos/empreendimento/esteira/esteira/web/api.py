"""API JSON do painel (`/api/v1`), consumida pelo app Flutter (módulo Empreendimento da plataforma).

Mesma regra do painel htmx: nenhuma lógica própria de produção. Leituras usam as mesmas funções das páginas
e toda ação de etapa entra na fila (`esteira.web.queue`), que roda os comandos do `./dark`. Arquivos do
episódio (thumbs, vídeo, áudio, quadros) são servidos por `/arq/{ep}/{caminho}`; PDFs do vault por `/pdf`.

Este módulo: biblioteca, episódio (geral, roteiro, cortes, cenas, gráficos, thumbs) e fila. O editor está
em `api_editor.py`; monitor, processos, opções, custos e acervo em `api_sistema.py`.
"""
import json
import re
from pathlib import Path
from urllib.parse import quote

from esteira.core import status
from esteira.sources import recordings, obsidian
from esteira.project import Project, ep_id, episodes, folder_ep
from esteira.web import app as painel
from esteira.web import queue
from fastapi import APIRouter, File, HTTPException, UploadFile
from pydantic import BaseModel

router = APIRouter(prefix="/api/v1", tags=["app"])

ACTIONS = painel.PIPELINE + ["all", "frames", "transcribe", "export"]


def _episodes(channel=""):
    """Episódios de verdade (com roteiro.json), do canal pedido ou de todos."""
    return [p for p in episodes() if (p / "roteiro.json").exists() and (not channel or p.parent.name == channel)]


def _json(file, default=None):
    try:
        return json.loads(file.read_text()) if file.exists() else default
    except ValueError:
        return default


def _video_light(ep, final):
    """O final da montagem tem 300–400 MB com o índice (moov) no fim: o player do celular precisa de tudo antes
    de tocar. O app toca a `previa.mp4` (540p, faststart, começa na hora); enquanto ela não existe ou está
    mais velha que o final, é gerada ao fundo e vai o final."""
    if not final.exists():
        return None
    preview, folder = final.with_name("previa.mp4"), folder_ep(ep)
    if preview.exists() and preview.stat().st_mtime >= final.stat().st_mtime:
        return f"/arq/{ep}/{preview.relative_to(folder)}?v={_v(preview)}"
    from esteira.web.api_studio import _preview_to_background
    _preview_to_background(final)
    return f"/arq/{ep}/{final.relative_to(folder)}?v={_v(final)}"


def _v(file):
    """Sufixo de versão para a URL do arquivo (o app não reaproveita imagem antiga do cache)."""
    return int(file.stat().st_mtime)


def _thumbs(folder, ep):
    return [{"vaga": k, "url": f"/arq/{ep}/thumb_{k}.png?v={_v(a)}"}
            for k in (1, 2, 3) if (a := folder / f"thumb_{k}.png").exists()]


def _summary(folder):
    ep = ep_id(folder)
    return {"id": ep, "canal": folder.parent.name, "numero": folder.name,
            "titulo": (_json(folder / "roteiro.json", {}) or {}).get("titulo", ""),
            "prog": painel._summary_ep(ep), "thumbs": _thumbs(folder, ep)}


def _project(ep):
    return Project(painel._folder(ep))


# ---------- Metadados (nomes das etapas e quem faz cada operação) ----------

@router.get("/meta")
def meta():
    return {"pipeline": painel.PIPELINE, "nomes": painel.NAMES,
            "motores": {k: [{"motor": m, "rotulo": r} for m, r in v] for k, v in painel.ENGINES.items()},
            "motor_ia": painel._engine_ai()}


# ---------- Biblioteca (roteiros do vault) ----------

@router.get("/canais")
def channels():
    vault = painel._cfg()["fontes"]["vault"]
    base = obsidian.folder_channels(vault)
    eps = _episodes()
    return [{"id": c, "roteiros": sum(len(list((base / c / sub).glob("*.md"))) for sub in ("Roteiros", "Shorts")),
             "episodios": sum(1 for p in eps if p.parent.name == c)} for c in obsidian.channels(vault)]


def _template(ep):
    if not ep:
        return None
    from esteira import studio
    return studio.template(Project(folder_ep(ep)))


@router.get("/canais/{canal}/roteiros")
def scripts(canal: str):
    cfg = painel._cfg()["fontes"]
    if canal not in obsidian.channels(cfg["vault"]):
        raise HTTPException(404, "canal não encontrado")
    mode_profile = None
    items = []
    for r in obsidian.list_all(cfg["vault"], canal):
        audio = recordings.candidates(cfg["gravacoes"], canal, r["numero"], r["titulo"], n=1, short=bool(r["short"]))
        audio = audio[0] if audio and audio[0]["nota"] >= 0.5 else None
        ep = painel._project_of_script(r["caminho"])
        definido = r["modo"] in ("dark", "apresentador")
        if definido:
            mode = r["modo"]
        elif ep:
            mode = Project(folder_ep(ep)).cfg.get("producao", {}).get("modo", "dark")
        else:
            mode = mode_profile = mode_profile or painel._mode_of_profile(canal)
        quotes = len(re.findall(r"^>\s*\[!cite\]", Path(r["caminho"]).read_text(), re.M))
        items.append({**r, "audio": bool(audio), "audio_mb": round(audio["mb"]) if audio else None,
                      "modo": mode, "modo_definido": definido, "citacoes": quotes, "ep": ep,
                      "template": _template(ep),
                      "prog": painel._summary_ep(ep) if ep else None})
    return items


class GenerateScript(BaseModel):
    alvo: str
    ate: str = ""
    motor: str = "local"


@router.post("/roteiros/gerar")
def generate_script(corpo: GenerateScript):
    """Roteiro(s) do plano do canal na fila (`./dark script canal:N [--to M] [--engine claude]`)."""
    target = corpo.alvo.strip()
    if not re.fullmatch(r"[a-z0-9_-]+:\d+", target):
        raise HTTPException(400, "use canal:N, ex.: finlumia:51")
    until = corpo.ate.strip()
    return queue.add(target, "script", ["--to", until] if until.isdigit() else [], corpo.motor)


class Produce(BaseModel):
    roteiros: list[str]
    templates: dict[str, str] = {}  # caminho do roteiro → template `id@N` da produção no Estúdio


@router.post("/produzir")
def produce(corpo: Produce):
    """Importa os roteiros do vault (se ainda não viraram episódio), grava o template escolhido e põe `tudo` na fila."""
    from esteira import studio
    from esteira.studio import style
    from esteira.sources.importer import run_import
    vault = Path(painel._cfg()["fontes"]["vault"]).expanduser().resolve()
    for ref in corpo.templates.values():
        try:
            style.load(ref)
        except (KeyError, ValueError):
            raise HTTPException(400, f"template inexistente: {ref}") from None
    tasks = []
    for path in corpo.roteiros:
        if vault not in Path(path).resolve().parents:
            raise HTTPException(400, f"roteiro fora do vault: {path}")
        ep = painel._project_of_script(path) or ep_id(run_import(Path(path)))
        if ref := corpo.templates.get(path):
            studio.choose_template(Project(folder_ep(ep)), ref)
        tasks.append(queue.add(ep, "all"))
    return tasks


# ---------- Episódio: geral ----------

@router.get("/episodios")
def list_episodes(canal: str = ""):
    return [_summary(p) for p in reversed(_episodes(canal))]


@router.get("/episodios/{ep}")
def episode(ep: str):
    from esteira import production
    from esteira.ai import claude
    folder = painel._folder(ep)
    proj = Project(folder)
    rot = _json(folder / "roteiro.json", {}) or {}
    est = status.stages(folder)
    names = painel.PIPELINE + [e for e in est if e not in painel.PIPELINE]
    stages = [{"id": e, "nome": painel.NAMES.get(e, e), **(est.get(e) or {"status": "pending"})} for e in names]
    evs = [e for e in status.events(folder) if e["kind"] in ("output", "warning", "error", "claude", "start", "end")]
    final, thumb = painel.final_of_ep(folder), folder / "thumb.png"
    mode = production.mode(proj)
    camera = production.info_camera(proj) if mode == "apresentador" and production.camera(proj) else None
    return {**_summary(folder), "etapas": stages, "eventos": evs[-40:][::-1], "gasto_claude": claude.spent(ep)[0],
            "video": _video_light(ep, final),
            "thumb": f"/arq/{ep}/thumb.png?v={_v(thumb)}" if thumb.exists() else None,
            "vertical": proj.cfg["video"].get("formato", "16:9") == "9:16", "modo": mode,
            "camera": camera if mode == "apresentador" else None, "sem_camera": mode == "apresentador" and not camera,
            "partes": len(rot.get("capitulos", [])), "notas": len(rot.get("notas", [])),
            "citacoes": len(rot.get("citacoes", [])), "fontes": rot.get("fontes", []),
            "fcproj": (folder / "projeto.fcproj").exists(),
            "manuais": sorted(p.name for p in folder.glob("projeto.manual-*.fcproj")),
            "motor_ia": painel._engine_ai()}


class Run(BaseModel):
    refazer: bool = False
    motor: str = ""
    so_render: bool = False


@router.post("/episodios/{ep}/rodar/{etapa}")
def run(ep: str, etapa: str, corpo: Run | None = None):
    from esteira.core import options
    painel._folder(ep)
    if etapa not in ACTIONS:
        raise HTTPException(400, "etapa desconhecida")
    corpo = corpo or Run()
    args = ["--redo"] if corpo.refazer and etapa in ("clean", "curate", "fetch", "all") else []
    if corpo.so_render and etapa == "graphics":
        args = ["--render-only"]
    return queue.add(ep, etapa, args, corpo.motor or options.read()["engine"])


@router.post("/episodios/{ep}/abrir")
def open_filmcraft(ep: str):
    """Abre o projeto do vídeo no FilmCraft (na máquina onde o painel roda)."""
    from esteira.assemble import open_file
    open_file(_project(ep))
    return {"ok": True}


# ---------- Episódio: roteiro (como a esteira leu o vault) ----------

@router.get("/episodios/{ep}/roteiro")
def script(ep: str):
    """Partes com notas de cena, falas e citações. Textos crus: *destaque* nas falas, **negrito** nas notas."""
    folder = painel._folder(ep)
    rot = _json(folder / "roteiro.json")
    if rot is None:
        raise HTTPException(404, "projeto sem roteiro.json: importe do vault")
    speeches = [l for l in (folder / "roteiro.txt").read_text().splitlines()[1:] if l.strip()]
    graphics = _json(folder / "graficos.json", []) or []
    in_screen = {g["dados"].get("trecho") for g in graphics if g["modelo"] == "citacao" and g.get("arquivo")}
    caps = rot.get("capitulos", [])
    parts = []
    for i, cap in enumerate(caps):
        end = caps[i + 1]["fala"] if i + 1 < len(caps) else len(speeches)
        items = []
        for k in range(cap["fala"], end):
            items += [{"tipo": "cena", "texto": n["texto"]} for n in rot.get("notas", []) if n["antes_da_fala"] == k]
            items.append({"tipo": "fala", "n": k + 1, "texto": speeches[k]})
            for j, c in enumerate(rot.get("citacoes", [])):
                if c["fala"] != k:
                    continue
                rec = painel._crop_quote(folder, j, c) if c.get("ok") and Path(c["arquivo"]).exists() else None
                if rec:
                    rec = {**rec, "url": f"/arq/{ep}/graficos/{rec['img']}"}
                items.append({"tipo": "cite", "c": c, "recorte": rec, "no_video": c["en"] in in_screen,
                              "pdf": f"/pdf?arq={quote(c['arquivo'])}#page={c.get('pagina', 1)}" if c.get("arquivo") else None})
        parts.append({"parte": cap.get("parte"), "nome": cap.get("nome", ""), "itens": items})
    quoted = {re.split(r"[ ,]", c["autores"])[0].lower() for c in rot.get("citacoes", []) if c.get("autores")}
    sources = [{**f, "situacao": "citação na tela" if re.split(r"[ ,]", f.get("autores", ""))[0].lower() in quoted
               else "só tarja / lista"} for f in rot.get("fontes", [])]
    return {"titulo": rot.get("titulo", ""), "formato": rot.get("formato") or "16:9", "origem": rot.get("origem"),
            "partes": parts, "fontes": sources, "n_falas": len(speeches),
            "palavras": sum(len(f.split()) for f in speeches), "n_notas": len(rot.get("notas", [])),
            "n_citacoes": len(rot.get("citacoes", [])), "tem_graficos": bool(graphics)}


# ---------- Episódio: cortes da narração ----------

@router.get("/episodios/{ep}/cortes")
def cuts(ep: str, filtro: str = "revisar"):
    folder = painel._folder(ep)
    data = _json(folder / "cortes.json")
    if data is None:
        raise HTTPException(404, "os cortes ainda não foram decididos")
    spans = [dict(t, k=k) for k, t in enumerate(data["trechos"])]
    if filtro == "revisar":
        spans = [t for t in spans if t["tipo"] != "tomada" or t["confianca"] < 0.85]
    elif filtro == "cortados":
        spans = [t for t in spans if not t["manter"]]
    raw = next(folder.glob("narracao_bruta.*"), None)
    return {"trechos": spans, "faltando": data["faltando"], "editado": data.get("editado_no_painel", False),
            "bruta": f"/arq/{ep}/{raw.name}?v={_v(raw)}" if raw else None}


@router.post("/episodios/{ep}/cortes/{k}/alternar")
def toggle_cut(ep: str, k: int):
    """Inverte fica/sai de um trecho (vale ao rodar o `limpar` de novo)."""
    file = painel._folder(ep) / "cortes.json"
    data = json.loads(file.read_text())
    if not 0 <= k < len(data["trechos"]):
        raise HTTPException(404, "trecho não encontrado")
    t = data["trechos"][k]
    t["manter"] = not t["manter"]
    t["por"] = "painel"
    t["motivo"] = t["motivo"].split(" → painel")[0] + f" → painel: {'fica' if t['manter'] else 'sai'}"
    data["editado_no_painel"] = True
    file.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    return dict(t, k=k)


# ---------- Episódio: cenas (linha do tempo) ----------

def _label_graphic(g):
    d = g.get("dados") or {}
    text = (d.get("nome") or d.get("texto") or d.get("titulo") or d.get("linha1") or d.get("nome_a")
             or d.get("autores") or d.get("citacao") or (g["caixas"][0]["texto"] if g.get("caixas") else ""))
    return str(text).replace("*", "")


@router.get("/episodios/{ep}/cenas")
def scenes(ep: str):
    folder = painel._folder(ep)
    plan = _json(folder / "plano.json")
    if plan is None:
        raise HTTPException(404, "as cenas ainda não foram geradas")
    graphics = _json(folder / "graficos.json", []) or []
    output = []
    for c in plan["cenas"]:
        q = folder / "midia" / f".aval_{c['id']:03d}.jpg"
        frame = q.name if q.exists() else (Path(c["midia"]).name if (c.get("midia") or "").endswith(".jpg") else None)
        output.append({k: c.get(k) for k in ("id", "inicio", "fim", "texto", "clima", "busca_en", "busca", "nota_midia",
                                            "midia_tipo", "problema_midia")}
                     | {"quadro": f"/arq/{ep}/midia/{frame}" if frame else None})
    return {"titulo": plan.get("titulo"), "cenas": output,
            "graficos": [{"inicio": g["inicio"], "modelo": g["modelo"], "rotulo": _label_graphic(g)[:40]}
                         for g in graphics]}


class Swap(BaseModel):
    busca_en: str = ""


@router.post("/episodios/{ep}/cenas/{cid}/trocar")
def swap_media(ep: str, cid: int, corpo: Swap):
    """Grava a busca nova da cena (se houver) e põe a busca só dessa cena na fila."""
    folder = painel._folder(ep)
    if corpo.busca_en.strip():
        file = folder / "plano.json"
        plan = json.loads(file.read_text())
        for c in plan["cenas"]:
            if c["id"] == cid:
                c["busca_en"] = corpo.busca_en.strip()
        file.write_text(json.dumps(plan, ensure_ascii=False, indent=2))
    return queue.add(ep, "fetch", ["--redo", "--scenes", str(cid)])


# ---------- Episódio: gráficos animados ----------

@router.get("/episodios/{ep}/graficos")
def graphics(ep: str):
    folder = painel._folder(ep)
    items = _json(folder / "graficos.json")
    if items is None:
        raise HTTPException(404, "os gráficos ainda não foram planejados")
    v = Project(folder).cfg["video"]
    output, by_kind = [], {}
    for i, g in enumerate(items):
        ecp = folder / g["ecproj"] if g.get("ecproj") else None
        name = g["arquivo"].split("/")[-1] if g.get("arquivo") else None
        by_kind[g["modelo"]] = by_kind.get(g["modelo"], 0) + 1
        output.append({"i": i, "inicio": g["inicio"], "dur": g["dur"], "modelo": g["modelo"],
                      "manual": bool(g.get("manual")), "roteiro": bool(g.get("roteiro")), "origem": g.get("origem"),
                      "rotulo": _label_graphic(g), "manual_ec": bool(g.get("manual_ec")),
                      "ec_editado": bool(ecp and ecp.exists() and ecp.stat().st_mtime > g.get("ec_gerado", 0) + 1),
                      "previa": f"/ep/{ep}/previa/{name}" if name else None})
    return {"graficos": output, "por_tipo": by_kind, "editados_ec": sum(g["ec_editado"] for g in output),
            "vertical": v["altura"] > v["largura"]}


@router.post("/episodios/{ep}/graficos/{i}/effectcraft")
def open_effectcraft(ep: str, i: int):
    r = painel.open_effectcraft(ep, i)
    if getattr(r, "status_code", 303) == 400:
        raise HTTPException(400, r.body.decode())
    return {"ok": True}


# ---------- Episódio: thumbnails ----------

def _list_thumbs(p):
    """Thumbs editáveis; .pcraft salvo à mão no PhotoCraft refaz o PNG antes (como a aba Thumbs do painel)."""
    from esteira import editor, photocraft
    marks = p.path_of("thumbs/editadas_photocraft.json")
    done = set(_json(marks, []) or [])
    items = editor.thumbs(p)
    for t in items:
        pc = p.path_of(f"thumbs/{t['arquivo']}").with_suffix(".pcraft")
        if photocraft.edited(pc):
            photocraft.export(pc)
            done.add(t["arquivo"])
            marks.write_text(json.dumps(sorted(done)))
    for t in items:
        t["pc_editado"] = t["arquivo"] in done
    return items


@router.get("/episodios/{ep}/thumbs")
def thumbs(ep: str):
    from esteira import editor
    p = _project(ep)
    items = _list_thumbs(p)
    for t in items:
        file = p.path_of("thumbs") / t["arquivo"]
        t["url"] = f"/arq/{ep}/thumbs/{t['arquivo']}?v={_v(file)}"
    return {"thumbs": items, "vagas": _thumbs(p.folder_path, ep),
            "fundos": [{"nome": f, "url": f"/arq/{ep}/thumbs/{f}"} for f in editor.backgrounds(p)]}


class UseThumb(BaseModel):
    arquivo: str
    vaga: int


@router.post("/episodios/{ep}/thumbs/usar")
def use_thumb(ep: str, corpo: UseThumb):
    from esteira import editor
    try:
        editor.use_thumb(_project(ep), corpo.arquivo, corpo.vaga)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"ok": True}


@router.post("/episodios/{ep}/thumbs/fundo")
async def send_background(ep: str, arquivo: UploadFile = File(...)):
    from esteira import editor
    suffix = Path(arquivo.filename or "").suffix.lower()
    if suffix not in (".png", ".jpg", ".jpeg", ".webp"):
        raise HTTPException(400, "envie PNG, JPG ou WebP")
    return {"nome": editor.store_background(_project(ep), await arquivo.read(), suffix)}


class FileThumb(BaseModel):
    arquivo: str


@router.post("/episodios/{ep}/thumbs/photocraft")
def open_photocraft(ep: str, corpo: FileThumb):
    painel.open_photocraft(ep, corpo.arquivo)
    return {"ok": True}


# ---------- Pacotes de edição (baixar para editar em outra máquina e enviar de volta) ----------

def _target_edit(ep, editor, i=None, file=""):
    p = _project(ep)
    if editor == "filmcraft":
        target = p.path_of("projeto.fcproj")
        if not target.exists():
            raise HTTPException(400, "sem projeto.fcproj: rode o montar antes")
    elif editor == "effectcraft":
        target = painel.ensure_ecproj(ep, i)
        if not target:
            raise HTTPException(400, "a citação não achou o trecho no PDF")
    else:
        target = painel.ensure_pcraft(ep, file)
    return p, Path(target)


def _download(ep, editor, i=None, file=""):
    from esteira import package
    from fastapi.responses import FileResponse, StreamingResponse
    p, target = _target_edit(ep, editor, i, file)
    if target.suffix == ".pcraft":
        return FileResponse(target, filename=f"{ep}-{target.name}", media_type="application/octet-stream")
    name = f"{ep}-{target.stem}"
    return StreamingResponse(package.pack(target, p.folder_path, name), media_type="application/zip",
                             headers={"Content-Disposition": f'attachment; filename="{name}.zip"'})


async def _send(ep, editor, envio, i=None, file=""):
    from esteira import package
    p, target = _target_edit(ep, editor, i, file)
    try:
        return package.receive(await envio.read(), target, p.folder_path)
    except ValueError as e:
        raise HTTPException(400, str(e)) from e


@router.get("/episodios/{ep}/pacote/filmcraft")
def download_filmcraft(ep: str):
    """Zip com o projeto.fcproj (mídia com caminhos relativos) e a mídia que ele usa."""
    return _download(ep, "filmcraft")


@router.post("/episodios/{ep}/pacote/filmcraft")
async def send_filmcraft(ep: str, arquivo: UploadFile = File(...)):
    """Sobrescreve o projeto.fcproj (o anterior vai para log/envios/); depois, `exportar` refaz o vídeo."""
    return await _send(ep, "filmcraft", arquivo)


@router.get("/episodios/{ep}/graficos/{i}/pacote")
def download_graphic(ep: str, i: int):
    return _download(ep, "effectcraft", i)


@router.post("/episodios/{ep}/graficos/{i}/pacote")
async def send_graphic(ep: str, i: int, arquivo: UploadFile = File(...)):
    """O .ecproj enviado é renderizado como está na próxima renderização dos gráficos (`manual_ec`)."""
    return await _send(ep, "effectcraft", arquivo, i)


@router.get("/episodios/{ep}/thumbs/pacote")
def download_thumb(ep: str, arquivo: str):
    return _download(ep, "photocraft", file=arquivo)


@router.post("/episodios/{ep}/thumbs/pacote")
async def send_thumb(ep: str, thumb: str, arquivo: UploadFile = File(...)):
    """O .pcraft enviado refaz o PNG da thumb ao listar as thumbs."""
    return await _send(ep, "photocraft", arquivo, file=thumb)


# ---------- Fila ----------

@router.get("/fila")
def list_queue():
    from esteira.core import locks, processes
    tasks = list(reversed(queue.list_all()))
    process = {r.get("queue"): r["id"] for r in processes.list_recent(400) if r.get("queue")}
    for t in tasks:
        p = folder_ep(t["ep"]) if ":" not in t["ep"] else None
        t["prog"] = painel._summary_ep(t["ep"]) if p and p.is_dir() else None
        t["processo"] = process.get(str(t["id"]))
    return {"tarefas": tasks, "vagas": {v: locks.owner(v) for v in locks.SLOTS}}


@router.post("/fila/{tid}/cancelar")
def cancel(tid: int):
    queue.cancel(tid)
    return {"ok": True}


@router.post("/fila/limpar")
def clean_queue():
    queue.clean_finished()
    return {"ok": True}


# ── bancada de LLM (Estúdio, fase 1) ──

class RunBench(BaseModel):
    modelos: list[str] = []
    tarefas: list[str] = []


@router.get("/bancada")
def show_bench():
    """Gabarito (casos por tarefa), modelos do roteador e o último resultado da bancada."""
    from esteira import bench
    from esteira.ai import llama
    return {"gabarito": {t: len(bench.cases(t)) for t in bench.TASKS},
            "modelos": [m["id"] for m in llama.models() or []], "resultado": bench.last()}


@router.post("/bancada/rodar")
def run_bench(corpo: RunBench):
    """Põe `./dark bench run` na fila (vaga da máquina: usa a GPU)."""
    from esteira import bench
    if any(t not in bench.TASKS for t in corpo.tarefas):
        raise HTTPException(400, f"tarefas válidas: {', '.join(bench.TASKS)}")
    args = (["--models", ",".join(corpo.modelos)] if corpo.modelos else []) + (
        ["--tasks", ",".join(corpo.tarefas)] if corpo.tarefas else [])
    return queue.add("run", "bench", args)
