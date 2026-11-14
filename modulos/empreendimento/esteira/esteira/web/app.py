"""Painel da esteira (`./dark panel`): biblioteca de roteiros do vault com seleção → fila de produção,
acompanhamento ao vivo de cada etapa, estrutura do roteiro (partes, falas, cenas, citações com o PDF),
prévia dos gráficos, revisão de cortes, linha do tempo das cenas, edição manual e custos do Claude.

Tudo o que os botões fazem passa pelos mesmos comandos do `./dark` (via fila), então o painel nunca tem uma
lógica própria que divirja do terminal. Atualização ao vivo por polling do HTMX (fragmentos `_*`).
"""
import json
import os
import re
import subprocess
import tomllib
from datetime import datetime
from pathlib import Path

from esteira.core import status
from esteira.core.display import NoDisplay
from esteira.sources import recordings, obsidian
from esteira.project import PROJECTS, ROOT, Project, ep_id, folder_ep
from esteira.web import queue
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import (
    FileResponse,
    HTMLResponse,
    JSONResponse,
    PlainTextResponse,
    RedirectResponse,
)
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

HERE = Path(__file__).parent
PIPELINE = ["clean", "scenes", "curate", "fetch", "evaluate", "graphics", "assemble", "thumb"]
NAMES = {"clean": "Cortes da narração", "scenes": "Cenas", "curate": "Curadoria (LLM)", "fetch": "Busca de mídia",
         "evaluate": "Avaliação visual", "graphics": "Gráficos animados", "assemble": "Montagem e exportação",
         "thumb": "Thumbnail", "transcribe": "Transcrição", "frames": "Quadros", "review": "Folhas de revisão"}

app = FastAPI(title="Esteira dark")


# A esteira não tem login (no PC só ouve 127.0.0.1; pela VPS o nginx exige o token). Sem estas
# travas, qualquer site aberto no navegador do PC poderia mandar formulários para ela (CSRF) ou, com
# DNS rebinding, ler as respostas. Host só local (o túnel chega com Host: localhost); POST/PUT/DELETE
# de navegador só da própria esteira ou do domínio da VPS (o app nativo não manda Origin).
_HOSTS_LOCALS = re.compile(r"(localhost|127\.0\.0\.1|\[::1\])(:\d+)?")
_ORIGINS = re.compile(
    r"https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?|https://"
    + re.escape(os.environ.get("ESTEIRA_DOMINIO", "agent.thiagobenevide.com"))
)


@app.middleware("http")
async def _local_only(request: Request, call_next):
    if not _HOSTS_LOCALS.fullmatch(request.headers.get("host", "")):
        return PlainTextResponse("Host não permitido", status_code=403)
    origin = request.headers.get("origin")
    if request.method not in ("GET", "HEAD", "OPTIONS") and origin and not _ORIGINS.fullmatch(origin):
        return PlainTextResponse("Origem não permitida", status_code=403)
    return await call_next(request)


@app.exception_handler(NoDisplay)
def _without_screen(_pedido, erro):
    return JSONResponse({"detail": str(erro)}, status_code=503)


app.mount("/static", StaticFiles(directory=HERE / "static"), name="static")
app.mount("/fontes", StaticFiles(directory=HERE.parent / "graphics" / "fontes"), name="fontes")
app.mount("/graf", StaticFiles(directory=HERE.parent / "graphics"), name="graf")  # prévia do editor (fontes dos modelos)
tpl = Jinja2Templates(directory=HERE / "templates")
# Quem faz cada operação: Python puro, LLM local (Ollama na GPU), outro modelo na GPU ou Claude (assinatura).
ENGINES = {
    "transcribe": [("gpu", "Whisper na GPU"), ("py", "Python")],
    "clean": [("py", "Python"), ("local", "LLM local"), ("claude", "Claude só se houver dúvida")],
    "scenes": [("py", "Python")],
    "curate": [("local", "LLM local")],
    "fetch": [("py", "Python + APIs dos bancos")],
    "evaluate": [("local", "visão local"), ("claude", "Claude só se houver dúvida")],
    "review": [("py", "Python")], "frames": [("py", "Python")], "export": [("py", "Python + FilmCraft")],
    "graphics": [("local", "LLM local planeja"), ("py", "Python renderiza (CPU)")],
    "assemble": [("py", "Python + FilmCraft")],
    "thumb": [("local", "LLM local"), ("gpu", "RealVisXL na GPU"), ("claude", "Claude escolhe as 3")],
    "all": [("py", "Python"), ("local", "LLM local"), ("gpu", "GPU"), ("claude", "Claude só se houver dúvida")],
    "script": [("py", "Python + OpenAlex"), ("local", "LLM local")],
    "painel": [("py", "Python")], "importar": [("py", "Python")],
}


def _engine_ai():
    from esteira.core import options
    o = options.read()
    if o["engine"] == "claude":
        return "Claude (" + options.claude({"modelo": "claude-sonnet-5-5"})["modelo"].removeprefix("claude-") + ")"
    return "LLM local"


tpl.env.globals.update(NOMES=NAMES, MOTORES=ENGINES, motor_ia=_engine_ai)
tpl.env.filters["datahora"] = lambda t: datetime.fromtimestamp(t).strftime("%d/%m %H:%M")


def _cfg():
    return tomllib.loads((ROOT / "config.toml").read_text())


def _folder(ep):
    p = folder_ep(ep).resolve()
    if p.parent.parent != PROJECTS.resolve() or not p.is_dir():
        raise HTTPException(404, "projeto não encontrado")
    return p


def _project_of_script(path):
    """Pasta de projeto já criada a partir deste roteiro (roteiro.json guarda a origem)."""
    for rj in PROJECTS.glob("*/*/roteiro.json"):
        try:
            if json.loads(rj.read_text()).get("origem") == path:
                return ep_id(rj.parent)
        except ValueError:
            pass
    return None


def final_of_ep(pasta):
    """`final.mp4` em vigor: o do Estúdio no formato do episódio, se existir (substitui gráficos + montagem); senão o
    da montagem."""
    fmt = Project(pasta).cfg["video"].get("formato", "16:9").replace(":", "x")
    estudio = pasta / "estudio" / fmt / "final.mp4"
    return estudio if estudio.exists() else pasta / "final.mp4"


def _summary_ep(ep):
    folder = folder_ep(ep)
    est = status.stages(folder)
    final = final_of_ep(folder)
    of_estudio = final.parent != folder
    done = sum(1 for e in PIPELINE if est.get(e, {}).get("status") == "ok"
                 or of_estudio and e in ("graphics", "assemble"))
    running = next((e for e, v in est.items() if v["status"] == "running"), None)
    error = next((e for e, v in est.items() if v["status"] == "error"), None)
    # roteiro reimportado ou gráficos refeitos depois da exportação: o vídeo não tem as mudanças
    sources = ("estudio/mapa.json", "estudio/corte/corte.json") if of_estudio else ("graficos.json",)
    desatualizado = final.exists() and any((folder / a).exists() and (folder / a).stat().st_mtime > final.stat().st_mtime
                                           for a in (*sources, "plano.json", "roteiro.json"))
    return {"feitas": done, "total": len(PIPELINE), "rodando": running, "erro": error, "desatualizado": desatualizado,
            "final": final.exists() and (of_estudio or est.get("assemble", {}).get("status") == "ok"),
            "thumb": (folder / "thumb.png").exists()}


@app.on_event("startup")
def _start():
    queue.start()
    from esteira import monitor
    monitor.start(_cfg())


@app.get("/", response_class=HTMLResponse)
def collection(request: Request, canal: str = "", status_r: str = ""):
    cfg = _cfg()["fontes"]
    channels = obsidian.channels(cfg["vault"])
    canal = canal or (channels[0] if channels else "")
    items = []
    for r in obsidian.list_all(cfg["vault"], canal):
        if status_r and r["status"] != status_r:
            continue
        audio = recordings.candidates(cfg["gravacoes"], canal, r["numero"], r["titulo"], n=1, short=bool(r["short"]))
        ep = _project_of_script(r["caminho"])
        items.append(dict(r, audio=audio[0] if audio and audio[0]["nota"] >= 0.5 else None,
                          ep=ep, prog=_summary_ep(ep) if ep else None))
    for r in items:
        r["citacoes"] = len(re.findall(r"^>\s*\[!cite\]", Path(r["caminho"]).read_text(), re.M))  # só blocos
    contagem = {c: sum(len(list((obsidian.folder_channels(cfg["vault"]) / c / sub).glob("*.md")))
                       for sub in ("Roteiros", "Shorts")) for c in channels}
    from esteira.project import Project
    profile_mode = {}
    for r in items:  # modo: do roteiro, senão do projeto/perfil do canal
        r["modo_definido"] = r["modo"] in ("dark", "apresentador")
        if not r["modo_definido"]:
            r["modo"] = ""
            if r["ep"]:
                r["modo"] = Project(folder_ep(r["ep"])).cfg.get("producao", {}).get("modo", "dark")
            else:
                r["modo"] = profile_mode.setdefault(canal, _mode_of_profile(canal))
    return tpl.TemplateResponse(request, "biblioteca.html", {"canais": channels, "canal": canal, "itens": items,
                                                             "contagem": contagem, "status_r": status_r})


def _mode_of_profile(canal):
    profile = ROOT / "perfis" / f"{canal}.toml"
    cfg = _cfg()
    if profile.exists():
        cfg.update(tomllib.loads(profile.read_text()))
    return cfg.get("producao", {}).get("modo", "dark")


@app.post("/produzir")
async def produce(request: Request):
    from esteira.sources.importer import run_import
    form = await request.form()
    for path in form.getlist("roteiro"):
        ep = _project_of_script(path) or ep_id(run_import(Path(path)))
        queue.add(ep, "all")
    return RedirectResponse("/fila", status_code=303)


@app.get("/fila", response_class=HTMLResponse)
def page_queue(request: Request):
    return tpl.TemplateResponse(request, "fila.html", {})


@app.get("/_fila", response_class=HTMLResponse)
def fragment_queue(request: Request):
    from esteira.core import locks, processes
    tasks = list(reversed(queue.list_all()))
    process = {r.get("queue"): r["id"] for r in processes.list_recent(400) if r.get("queue")}
    for t in tasks:
        t["prog"] = _summary_ep(t["ep"]) if ":" not in t["ep"] and folder_ep(t["ep"]).is_dir() else None
        t["proc"] = process.get(str(t["id"]))
    slots = {v: locks.owner(v) for v in locks.SLOTS}
    return tpl.TemplateResponse(request, "_fila.html", {"tarefas": tasks, "vagas": slots})


@app.post("/fila/roteiro")
def queue_script(alvo: str = Form(...), ate: str = Form(""), motor: str = Form("local")):
    """Roteiro(s) do plano do canal na fila (`./dark script canal:N [--to M] [--engine claude]`)."""
    if not re.fullmatch(r"[a-z0-9_-]+:\d+", alvo.strip()):
        raise HTTPException(400, "use canal:N, ex.: finlumia:51")
    queue.add(alvo.strip(), "script", ["--to", ate.strip()] if ate.strip().isdigit() else [], motor)
    return RedirectResponse("/fila", status_code=303)


@app.post("/fila/{tid}/cancelar")
def cancel(tid: int):
    queue.cancel(tid)
    return RedirectResponse("/fila", status_code=303)


@app.post("/fila/limpar")
def clean_queue():
    queue.clean_finished()
    return RedirectResponse("/fila", status_code=303)


@app.get("/ep/{ep}", response_class=HTMLResponse)
def episode(request: Request, ep: str):
    folder = _folder(ep)
    rot = json.loads((folder / "roteiro.json").read_text()) if (folder / "roteiro.json").exists() else {}
    from esteira.project import Project
    cfg = Project(folder).cfg
    vertical = cfg["video"].get("formato", "16:9") == "9:16"
    from esteira import production
    proj = Project(folder)
    mode = production.mode(proj)
    camera = production.info_camera(proj) if production.camera(proj) else None
    return tpl.TemplateResponse(request, "episodio.html", {"ep": ep, "rot": rot, "pipeline": PIPELINE,
                                                           "final": (folder / "final.mp4").exists(),
                                                           "thumb": (folder / "thumb.png").exists(),
                                                           "vertical": vertical,
                                                           "prog": _summary_ep(ep),
                                                           "modo": mode, "camera": camera,
                                                           "fcproj": (folder / "projeto.fcproj").exists(),
                                                           "manuais": sorted(p.name for p in folder.glob("projeto.manual-*.fcproj"))})


# ---------- Estrutura do roteiro: partes, falas, cenas e citações (o que a esteira leu do vault) ----------

def _crop_quote(pasta, k, c):
    """PNG do pedaço da página do PDF com o trecho (cache em graficos/) e os retângulos do marca-texto em %."""
    import pymupdf
    from esteira.graphics import pdf as P
    destination = pasta / "graficos" / f"cite_{k}.png"
    meta = destination.with_suffix(".json")
    if destination.exists() and meta.exists() and meta.stat().st_mtime >= Path(c["arquivo"]).stat().st_mtime:
        return json.loads(meta.read_text())
    found = P.locate(c["arquivo"], c["en"], c["pagina"] - 1)
    if not found:
        return None
    pg = pymupdf.open(c["arquivo"])[found["pagina"]]
    x0, y0 = min(r[0] for r in found["rects"]), min(r[1] for r in found["rects"])
    x1, y1 = max(r[2] for r in found["rects"]), max(r[3] for r in found["rects"])
    clip = pymupdf.Rect(max(pg.rect.x0, min(x0, pg.rect.width * 0.08) - 10), max(0, y0 - 70),
                        min(pg.rect.x1, max(x1, pg.rect.width * 0.92) + 10), min(pg.rect.y1, y1 + 70))
    pix = pg.get_pixmap(dpi=150, clip=clip)
    destination.parent.mkdir(exist_ok=True)
    pix.save(destination)
    w, h = clip.width, clip.height
    data = {"img": destination.name, "pagina": found["pagina"] + 1, "nota": found["nota"],
             "rects": [[round((r[0] - clip.x0) / w * 100, 2), round((r[1] - clip.y0) / h * 100, 2),
                        round((r[2] - r[0]) / w * 100, 2), round((r[3] - r[1]) / h * 100, 2)] for r in found["rects"]]}
    meta.write_text(json.dumps(data))
    return data


@app.get("/ep/{ep}/roteiro", response_class=HTMLResponse)
def script(request: Request, ep: str):
    folder = _folder(ep)
    if not (folder / "roteiro.json").exists():
        return tpl.TemplateResponse(request, "vazio.html", {"ep": ep, "msg": "Projeto sem roteiro.json: importe do vault."})
    rot = json.loads((folder / "roteiro.json").read_text())
    speeches = [l for l in (folder / "roteiro.txt").read_text().splitlines()[1:] if l.strip()]
    caps = rot.get("capitulos", [])
    parts = []
    for i, cap in enumerate(caps):
        end = caps[i + 1]["fala"] if i + 1 < len(caps) else len(speeches)
        parts.append({**cap, "itens": []})
        for k in range(cap["fala"], end):
            for n in rot.get("notas", []):
                if n["antes_da_fala"] == k:
                    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", n["texto"].replace("<", "&lt;"))
                    parts[-1]["itens"].append({"tipo": "cena", "texto": text})
            speech = re.sub(r"\*([^*]+)\*", r"<mark>\1</mark>", speeches[k].replace("<", "&lt;"))
            parts[-1]["itens"].append({"tipo": "fala", "n": k + 1, "texto": speech})
            for j, c in enumerate(rot.get("citacoes", [])):
                if c["fala"] == k:
                    rec = _crop_quote(folder, j, c) if c.get("ok") and Path(c["arquivo"]).exists() else None
                    parts[-1]["itens"].append({"tipo": "cite", "c": c, "j": j, "rec": rec})
    graphics = json.loads((folder / "graficos.json").read_text()) if (folder / "graficos.json").exists() else []
    in_screen = {g["dados"].get("trecho") for g in graphics if g["modelo"] == "citacao" and g.get("arquivo")}
    quoted = {re.split(r"[ ,]", c["autores"])[0].lower() for c in rot.get("citacoes", []) if c.get("autores")}
    for f in rot.get("fontes", []):
        surname = re.split(r"[ ,]", f["autores"])[0].lower()
        f["situacao"] = "citação na tela" if surname in quoted else "só tarja / lista"
    for it in (i for p in parts for i in p["itens"] if i["tipo"] == "cite"):
        it["no_video"] = it["c"]["en"] in in_screen
    words = sum(len(f.split()) for f in speeches)
    return tpl.TemplateResponse(request, "roteiro.html", {"ep": ep, "rot": rot, "partes": parts,
                                                          "n_falas": len(speeches), "palavras": words,
                                                          "tem_graficos": bool(graphics)})


@app.get("/pdf")
def pdf_of_vault(arq: str):
    """PDFs de Referências/ do vault (para abrir a citação na página certa no navegador)."""
    cfg = _cfg()["fontes"]
    root = (Path(cfg["vault"]).expanduser() / "Referências").resolve()
    target = Path(arq).expanduser().resolve()
    if root not in target.parents or target.suffix.lower() != ".pdf" or not target.is_file():
        raise HTTPException(404)
    return FileResponse(target, media_type="application/pdf", headers={"Content-Disposition": "inline"})


# ---------- Gráficos: prévia de cada .mov renderizado ----------

@app.get("/ep/{ep}/graficos", response_class=HTMLResponse)
def graphics(request: Request, ep: str):
    folder = _folder(ep)
    file = folder / "graficos.json"
    if not file.exists():
        return tpl.TemplateResponse(request, "vazio.html", {"ep": ep, "msg": "Os gráficos ainda não foram planejados."})
    from esteira.project import Project
    v = Project(folder).cfg["video"]
    items = json.loads(file.read_text())
    for g in items:
        ecp = folder / g["ecproj"] if g.get("ecproj") else None
        g["ec_editado"] = bool(ecp and ecp.exists() and ecp.stat().st_mtime > g.get("ec_gerado", 0) + 1)
    by_kind = {}
    for g in items:
        by_kind[g["modelo"]] = by_kind.get(g["modelo"], 0) + 1
    return tpl.TemplateResponse(request, "graficos.html", {"ep": ep, "graficos": items, "por_tipo": by_kind,
                                                           "editados_ec": sum(g["ec_editado"] for g in items),
                                                           "vertical": v["altura"] > v["largura"]})


@app.get("/ep/{ep}/previa/{nome}")
def preview_graphic(ep: str, nome: str):
    """Quadro do gráfico (aos 65% da duração) sobre fundo cinza; gerado na 1ª visita e guardado ao lado do .mov."""
    folder = _folder(ep)
    mov = (folder / "graficos" / nome).resolve()
    if mov.parent != (folder / "graficos").resolve() or mov.suffix != ".mov" or not mov.exists():
        raise HTTPException(404)
    png = mov.with_suffix(".previa.jpg")
    if not png.exists():
        from esteira.media import duration_media
        from esteira.project import Project
        v = Project(folder).cfg["video"]
        n = int(duration_media(mov) * v["fps"] * 0.65)  # quadro escolhido por índice: -ss perde o alfa perto do fim
        subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", str(mov),
                        "-f", "lavfi", "-i", f"color=c=0x2a2d33:s={v['largura']}x{v['altura']}", "-filter_complex",
                        f"[0:v]select=eq(n\\,{n}),setpts=PTS-STARTPTS[g];[1:v][g]overlay=eof_action=pass,scale=-2:540",
                        "-frames:v", "1", "-q:v", "4", str(png)], check=True)
    return FileResponse(png)


# ---------- Monitor da máquina (GPU, CPU, energia, processos, arquivos) ----------

@app.get("/monitor", response_class=HTMLResponse)
def page_monitor(request: Request):
    return tpl.TemplateResponse(request, "monitor.html", {})


@app.get("/processos", response_class=HTMLResponse)
def page_processes(request: Request):
    from esteira.core import locks, processes
    return tpl.TemplateResponse(request, "processos.html", {"processos": processes.list_recent(300),
                                                            "vagas": {v: locks.owner(v) for v in locks.SLOTS}})


@app.get("/processos/{pid_id}", response_class=HTMLResponse)
def page_process(request: Request, pid_id: str):
    from esteira.core import processes
    r = processes.get(pid_id)
    if not r:
        raise HTTPException(404, "processo não encontrado")
    return tpl.TemplateResponse(request, "processo.html", {"p": r})


@app.post("/processos/{pid_id}/parar")
def stop_process(pid_id: str):
    """Para o processo (e o que ele abriu), venha da fila ou do terminal."""
    from esteira.core import processes
    r = processes.get(pid_id)
    if r and r["state"] == "running":
        t = next((t for t in queue.list_all() if str(t["id"]) == str(r.get("queue"))), None)
        if t:
            queue.cancel(t["id"])
        else:
            queue._close({"pid": r["pid"], "comando": r["command"], "ep": r["target"], "args": r["args"]})
    return RedirectResponse(f"/processos/{pid_id}", status_code=303)


@app.get("/api/processos/{pid_id}")
def api_process(pid_id: str):
    from esteira import monitor, process_monitor
    d = process_monitor.detail(pid_id, monitor.state(0.0).get("atual"))
    if not d:
        raise HTTPException(404, "processo não encontrado")
    d["tarefa_fila"] = next((t for t in queue.list_all() if str(t["id"]) == str(d["processo"].get("fila"))), None)
    return JSONResponse(d)


@app.get("/api/monitor")
def api_monitor():
    from esteira import monitor
    e = monitor.state(_cfg().get("monitor", {}).get("tarifa_kwh", 0.85))
    e["fila"] = [t for t in queue.list_all() if t["estado"] in ("rodando", "na fila")]
    return JSONResponse(e)


@app.get("/api/grafo")
def api_graph():
    from esteira import graph, monitor
    from esteira.graph import NODES, SEQ, USES
    current = monitor.state(0)["atual"]
    return JSONResponse(dict(graph.state(current), def_nos=[{"id": i, "rotulo": r, "faixa": f, "motor": m} for i, r, f, m, _ in NODES],
                             seq=SEQ, usa=USES))


@app.get("/api/grafo/no/{id_no}")
def api_graph_node(id_no: str):
    from esteira import graph, monitor
    if id_no not in graph.IDS:
        raise HTTPException(404)
    e = monitor.state(0)
    return JSONResponse(graph.detail(id_no, e["atual"], e["hist"]))


# ---------- Editor manual: gráficos e thumbnails ----------

def _project(ep):
    from esteira.project import Project
    return Project(_folder(ep))


def _error(e):
    return PlainTextResponse(str(e), status_code=400)


def _ctx_editor(p, ep, tipo):
    rot = json.loads(p.caminho("roteiro.json").read_text()) if p.caminho("roteiro.json").exists() else {}
    cits = [{k: c.get(k) for k in ("autores", "ano", "revista", "pt")} for c in rot.get("citacoes", [])]
    return {"ep": ep, "tipo": tipo, "citacoes": cits, "motor": p.cfg.get("editor", {}).get("motor_ia", "claude"),
            "cor": p.cfg.get("graficos", {}).get("cor", "#ffd400")}


@app.get("/ep/{ep}/graficos/{i}/editar", response_class=HTMLResponse)
def edit_graphic(request: Request, ep: str, i: int, t: float = 0.0):
    from esteira import editor
    p = _project(ep)
    w, h = editor._dim(p)
    items = editor.graphics(p)
    if i >= len(items):
        raise HTTPException(404)
    return tpl.TemplateResponse(request, "editor.html", _ctx_editor(p, ep, "grafico") | {
        "i": i, "estado": editor.state_graphic(p, i, t), "w": w, "h": h, "modelos": editor.MODELS,
        "titulo_pagina": "Novo gráfico" if i < 0 else f"Gráfico {i + 1} de {len(items)}"})


@app.get("/ep/{ep}/thumbs", response_class=HTMLResponse)
def page_thumbs(request: Request, ep: str):
    from esteira import editor
    p = _project(ep)
    from esteira import photocraft
    slots = [(k, p.caminho(f"thumb_{k}.png")) for k in (1, 2, 3)]
    items = editor.thumbs(p)
    for t in items:  # .pcraft salvo à mão no PhotoCraft → refaz o PNG (as vagas 1–3 são cópias: use de novo)
        pc = p.caminho(f"thumbs/{t['arquivo']}").with_suffix(".pcraft")
        if photocraft.edited(pc):
            photocraft.export(pc)
            marks = p.caminho("thumbs/editadas_photocraft.json")
            done = set(json.loads(marks.read_text())) if marks.exists() else set()
            marks.write_text(json.dumps(sorted(done | {t["arquivo"]})))
    marks = p.caminho("thumbs/editadas_photocraft.json")
    done = set(json.loads(marks.read_text())) if marks.exists() else set()
    for t in items:
        t["pc_editado"] = t["arquivo"] in done
    return tpl.TemplateResponse(request, "thumbs.html", {
        "ep": ep, "thumbs": items, "fundos": editor.backgrounds(p),
        "vagas": [(k, int(a.stat().st_mtime)) for k, a in slots if a.exists()]})


@app.get("/ep/{ep}/thumbs/editar", response_class=HTMLResponse)
def edit_thumb(request: Request, ep: str, arq: str = "", fundo: str = ""):
    from esteira import editor
    p = _project(ep)
    backgrounds = editor.backgrounds(p)
    if not backgrounds:
        return tpl.TemplateResponse(request, "vazio.html", {"ep": ep, "msg": "Sem fundos: rode a etapa thumb ou envie uma imagem em Thumbs."})
    state = next((t["estado"] for t in editor.thumbs(p) if t["arquivo"] == arq), None) or {
        "texto": "TEXTO DA THUMB", "destaque": "", "layout": "rosto_direita", "seta": False,
        "fundo": fundo if fundo in backgrounds else backgrounds[0]}
    w, h = editor._dim_thumb(p)
    return tpl.TemplateResponse(request, "editor.html", _ctx_editor(p, ep, "thumb") | {
        "i": -1, "estado": state, "w": w, "h": h, "fundos": backgrounds, "titulo_pagina": "Thumbnail"})


@app.post("/ep/{ep}/editor/previa", response_class=HTMLResponse)
async def editor_preview(request: Request, ep: str):
    from esteira import editor
    body = await request.json()
    p = _project(ep)
    try:
        if body.get("tipo") == "thumb":
            return HTMLResponse(editor.preview_thumb(p, ep, body["estado"]))
        return HTMLResponse(editor.preview_graphic(p, ep, body["estado"]))
    except (ValueError, KeyError, TypeError) as e:
        return _error(e)


@app.post("/ep/{ep}/editor/grafico/{i}")
async def editor_save_graphic(request: Request, ep: str, i: int):
    from esteira import editor
    p = _project(ep)
    try:
        new = editor.save_graphic(p, i, await request.json())
    except (ValueError, KeyError, TypeError, IndexError) as e:
        return _error(e)
    queue.add(ep, "graphics", ["--render-only"])  # só a peça editada é renderizada; o resto está em cache
    return {"i": new}


@app.post("/ep/{ep}/editor/grafico/{i}/excluir")
def editor_delete_graphic(ep: str, i: int):
    from esteira import editor
    editor.delete_graphic(_project(ep), i)
    return RedirectResponse(f"/ep/{ep}/graficos", status_code=303)


@app.post("/ep/{ep}/editor/thumb")
async def editor_save_thumb(request: Request, ep: str):
    from esteira import editor
    try:
        return {"arquivo": editor.save_thumb(_project(ep), await request.json())}
    except (ValueError, KeyError, TypeError) as e:
        return _error(e)


@app.post("/ep/{ep}/thumbs/usar")
def use_thumb(ep: str, arq: str = Form(...), k: int = Form(...)):
    from esteira import editor
    try:
        editor.use_thumb(_project(ep), arq, k)
    except ValueError as e:
        return _error(e)
    return RedirectResponse(f"/ep/{ep}/thumbs", status_code=303)


@app.post("/ep/{ep}/thumbs/fundo")
async def send_background(ep: str, arquivo: UploadFile = File(...)):
    from esteira import editor
    suffix = Path(arquivo.filename or "").suffix.lower()
    if suffix not in (".png", ".jpg", ".jpeg", ".webp"):
        return _error("envie PNG, JPG ou WebP")
    name = editor.store_background(_project(ep), await arquivo.read(), ".png" if suffix == ".png" else suffix)
    return RedirectResponse(f"/ep/{ep}/thumbs/editar?fundo={name}", status_code=303)


@app.post("/ep/{ep}/editor/ia")
async def editor_ai(request: Request, ep: str):
    from esteira import editor
    body = await request.json()
    pedido = (body.get("pedido") or "").strip()
    if not pedido:
        return _error("escreva o pedido")
    from esteira.core import locks
    if body.get("motor", "claude") == "local" and not locks.is_free("machine"):
        d = locks.owner("machine")
        return _error(f"a máquina está ocupada por `{d['command']}`: só um processo local por vez. "
                     "Use o motor Claude ou espere terminar.")
    try:
        import asyncio
        new, explanation, warnings = await asyncio.to_thread(
            editor.suggest, _project(ep), ep, body["estado"], pedido, body.get("motor", "claude"), body.get("tipo", "grafico"))
    except (ValueError, KeyError, TypeError) as e:
        return _error(e)
    return JSONResponse({"estado": new, "explicacao": explanation, "avisos": warnings})


# ---------- Edição manual no FilmCraft ----------

@app.post("/ep/{ep}/abrir")
def open_filmcraft(ep: str):
    from esteira.assemble import open_file
    from esteira.project import Project
    open_file(Project(_folder(ep)))
    return RedirectResponse(f"/ep/{ep}", status_code=303)


def ensure_ecproj(ep: str, i: int):
    """.ecproj da peça (cria agora se a peça é de antes do EffectCraft); None se a citação não achou o trecho."""
    from esteira.graphics import effectcraft, plan
    p = _project(ep)
    items = p.load_json("graficos.json")
    if not 0 <= i < len(items):
        raise HTTPException(404, "peça não encontrada")
    c = items[i]
    ecp = p.pasta / c["ecproj"] if c.get("ecproj") else None
    if not ecp or not ecp.exists():
        w, h = p.cfg["video"]["largura"], p.cfg["video"]["altura"]
        folder = p.caminho("graficos")
        base = Path(c["arquivo"]).stem if c.get("arquivo") else f"{c['modelo']}_{int(c['inicio'] * 1000)}"
        pc = plan.piece(c, folder, w, h, folder / f"pag_{base}.png")
        if not pc:
            return None
        ecp = effectcraft.build(*pc, c["dur"], folder / f"{base}.ecproj", w, h,
                                    p.cfg.get("graficos", {}).get("cor", "#ffd400"), p.cfg["video"]["fps"])
        c.update(ecproj=str(ecp.relative_to(p.pasta)), ec_gerado=ecp.stat().st_mtime)
        p.save_json("graficos.json", items)
    return ecp


@app.post("/ep/{ep}/graficos/{i}/effectcraft")
def open_effectcraft(ep: str, i: int):
    """Abre o .ecproj da peça no EffectCraft (cria agora se a peça é de antes do EffectCraft)."""
    from esteira.graphics import effectcraft
    ecp = ensure_ecproj(ep, i)
    if not ecp:
        return _error("a citação não achou o trecho no PDF")
    effectcraft.open_file(ecp)
    return RedirectResponse(f"/ep/{ep}/graficos", status_code=303)


def ensure_pcraft(ep: str, file: str):
    """Thumb em camadas (.pcraft) ao lado do PNG (cria agora se a thumb é de antes do PhotoCraft)."""
    from esteira import editor
    from esteira.thumbs import compose_file
    p = _project(ep)
    t = next((t for t in editor.thumbs(p) if t["arquivo"] == file), None)
    if not t:
        raise HTTPException(404, "thumb não encontrada")
    png = p.caminho(f"thumbs/{file}")
    pc = png.with_suffix(".pcraft")
    if not pc.exists():
        compose_file(t["estado"], p.caminho(f"thumbs/{t['estado']['fundo']}"), png, p.cfg)
    return pc


@app.post("/ep/{ep}/thumbs/photocraft")
def open_photocraft(ep: str, arq: str = Form(...)):
    """Abre a thumb em camadas (.pcraft) no PhotoCraft (cria agora se a thumb é de antes do PhotoCraft)."""
    from esteira import photocraft
    photocraft.open_file(ensure_pcraft(ep, arq))
    return RedirectResponse(f"/ep/{ep}/thumbs", status_code=303)


@app.get("/ep/{ep}/_etapas", response_class=HTMLResponse)
def fragment_stages(request: Request, ep: str):
    folder = _folder(ep)
    est = status.stages(folder)
    lines = [(e, est.get(e)) for e in PIPELINE] + [(e, v) for e, v in est.items() if e not in PIPELINE]
    evs = [e for e in status.events(folder) if e["kind"] in ("output", "warning", "error", "claude", "start", "end")]
    from esteira.ai import claude
    spent = claude.spent(ep)[0]
    return tpl.TemplateResponse(request, "_etapas.html", {"ep": ep, "linhas": lines, "eventos": evs[-40:][::-1],
                                                          "gasto": spent})


@app.post("/ep/{ep}/rodar/{etapa}")
def run(ep: str, etapa: str, refazer: str = Form(""), motor: str = Form(""), so_render: str = Form("")):
    from esteira.core import options
    _folder(ep)
    if etapa not in PIPELINE + ["all", "frames", "transcribe", "export"]:
        raise HTTPException(400, "etapa desconhecida")
    motor = motor or options.read()["engine"]
    args = ["--redo"] if refazer and etapa in ("clean", "curate", "fetch", "all") else []
    if so_render and etapa == "graphics":
        args = ["--render-only"]
    queue.add(ep, etapa, args, motor)
    return RedirectResponse(f"/ep/{ep}/graficos" if so_render else f"/ep/{ep}", status_code=303)


# ── Opções: motor de LLM (local ou Claude), modelo do Claude, modelos locais por operação, baixar modelos ──
_downloading = {}  # nome → {"estado", "feito", "total", "msg"}


def _local_models():
    """Modelos do llama.cpp (`~/agent-data/modelos`): [{nome, GB, visão}]."""
    from esteira.ai import llama
    if not llama.server():
        return []
    output = [{"nome": m["id"], "gb": llama.gb(m["id"]), "visao": llama.vision(m)} for m in llama.models() or []]
    return sorted(output, key=lambda m: m["nome"])


@app.get("/opcoes", response_class=HTMLResponse)
def page_options(request: Request, salvo: str = ""):
    from esteira.core import options
    from esteira.ai import local
    cfg = _cfg().get("claude", {})
    o = options.read()
    ops = [(k, name, desc, kinds, options.operation(k)) for k, (name, desc, kinds) in options.OPERATIONS.items()]
    return tpl.TemplateResponse(request, "opcoes.html", {
        "o": o, "ops": ops, "modelos_claude": options.MODELS, "sugestoes": options.SUGGESTIONS, "locais": _local_models(),
        "padrao": {"text": local.TEXT, "vision": local.VISION}, "cfg_claude": options.claude(cfg), "salvo": salvo})


@app.post("/opcoes")
async def save_options(request: Request):
    from esteira.core import options
    f = await request.form()
    num = lambda v: float(v.replace(",", ".")) if (v or "").strip() else None
    ops = {}
    for k, (_, _, kinds) in options.OPERATIONS.items():
        d = {"engine": f.get(f"{k}.motor") or "default"}
        for t in kinds:
            d[t] = f.get(f"{k}.{t}") or None
        ops[k] = d
    options.save(engine=f.get("motor") or "local", claude_model=f.get("modelo_claude") or None,
                  episode_cap_usd=num(f.get("teto_episodio_usd")), daily_cap_usd=num(f.get("teto_dia_usd")),
                  operations=ops)
    return RedirectResponse("/opcoes?salvo=1", status_code=303)


def _download(nome):
    """Baixa `usuario/repo:QUANT` do Hugging Face para a pasta de modelos do llama.cpp."""
    from esteira.ai import llama
    st = _downloading[nome]
    try:
        id_ = llama.download(nome, lambda feito, total, msg: st.update(feito=feito, total=total, msg=msg))
        st.update(estado="ok", msg=f"instalado como {id_}")
    except Exception as e:
        st.update(estado="erro", msg=str(e)[:200])


@app.post("/opcoes/baixar")
def download_model(nome: str = Form(...)):
    import threading
    nome = nome.strip()
    if not re.fullmatch(r"[\w.\-/]+(:[\w.\-]+)?", nome):
        raise HTTPException(400, "nome de modelo inválido (ex.: unsloth/Qwen3-8B-GGUF:Q4_K_M)")
    if _downloading.get(nome, {}).get("estado") != "baixando":
        _downloading[nome] = {"estado": "baixando", "feito": 0, "total": 0, "msg": "começando"}
        threading.Thread(target=_download, args=(nome,), daemon=True).start()
    return RedirectResponse("/opcoes#modelos", status_code=303)


@app.get("/opcoes/_baixando", response_class=HTMLResponse)
def fragment_downloading(request: Request):
    return tpl.TemplateResponse(request, "_baixando.html", {"baixando": _downloading})


@app.get("/ep/{ep}/cortes", response_class=HTMLResponse)
def cuts(request: Request, ep: str, filtro: str = "revisar"):
    folder = _folder(ep)
    file = folder / "cortes.json"
    if not file.exists():
        return tpl.TemplateResponse(request, "vazio.html", {"ep": ep, "msg": "Os cortes ainda não foram decididos."})
    data = json.loads(file.read_text())
    spans = [dict(t, k=k) for k, t in enumerate(data["trechos"])]
    if filtro == "revisar":
        spans = [t for t in spans if t["tipo"] != "tomada" or t["confianca"] < 0.85]
    elif filtro == "cortados":
        spans = [t for t in spans if not t["manter"]]
    raw = next((p.name for p in folder.glob("narracao_bruta.*")), None)
    return tpl.TemplateResponse(request, "cortes.html", {"ep": ep, "trechos": spans, "faltando": data["faltando"],
                                                         "bruta": raw, "filtro": filtro,
                                                         "editado": data.get("editado_no_painel", False)})


@app.post("/ep/{ep}/cortes/{k}/alternar", response_class=HTMLResponse)
def toggle_cut(request: Request, ep: str, k: int):
    file = _folder(ep) / "cortes.json"
    data = json.loads(file.read_text())
    t = data["trechos"][k]
    t["manter"] = not t["manter"]
    t["por"] = "painel"
    t["motivo"] = t["motivo"].split(" → painel")[0] + f" → painel: {'fica' if t['manter'] else 'sai'}"
    data["editado_no_painel"] = True
    file.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    raw = next((p.name for p in file.parent.glob("narracao_bruta.*")), None)
    return tpl.TemplateResponse(request, "_corte.html", {"ep": ep, "t": dict(t, k=k), "bruta": raw})


@app.get("/ep/{ep}/cenas", response_class=HTMLResponse)
def scenes(request: Request, ep: str):
    folder = _folder(ep)
    if not (folder / "plano.json").exists():
        return tpl.TemplateResponse(request, "vazio.html", {"ep": ep, "msg": "As cenas ainda não foram geradas."})
    plan = json.loads((folder / "plano.json").read_text())
    graphics = json.loads((folder / "graficos.json").read_text()) if (folder / "graficos.json").exists() else []
    for c in plan["cenas"]:
        q = folder / "midia" / f".aval_{c['id']:03d}.jpg"
        c["quadro"] = q.name if q.exists() else (Path(c["midia"]).name if c.get("midia", "").endswith(".jpg") else None)
    return tpl.TemplateResponse(request, "cenas.html", {"ep": ep, "cenas": plan["cenas"], "graficos": graphics,
                                                        "titulo": plan.get("titulo")})


@app.post("/ep/{ep}/cenas/{cid}/trocar")
def swap_media(ep: str, cid: int, busca_en: str = Form("")):
    folder = _folder(ep)
    if busca_en.strip():
        file = folder / "plano.json"
        plan = json.loads(file.read_text())
        for c in plan["cenas"]:
            if c["id"] == cid:
                c["busca_en"] = busca_en.strip()
        file.write_text(json.dumps(plan, ensure_ascii=False, indent=2))
    queue.add(ep, "fetch", ["--redo", "--scenes", str(cid)])
    return RedirectResponse(f"/ep/{ep}/cenas#c{cid}", status_code=303)


@app.get("/custos", response_class=HTMLResponse)
def costs(request: Request):
    from esteira.ai import claude
    regs = list(reversed(claude._records()))
    by_ep = {}
    for r in regs:
        by_ep[r["ep"]] = by_ep.get(r["ep"], 0) + (r.get("cost") or 0)
    today = datetime.now().date().isoformat()
    return tpl.TemplateResponse(request, "custos.html", {
        "regs": regs[:200], "por_ep": sorted(by_ep.items(), key=lambda x: -x[1]), "total": sum(by_ep.values()),
        "hoje": sum((r.get("cost") or 0) for r in regs if r["t"].startswith(today)), "cfg": _cfg().get("claude", {})})


@app.get("/arq/{ep}/{caminho:path}")
def file(ep: str, caminho: str):
    folder = _folder(ep)
    target = (folder / caminho).resolve()
    if folder not in target.parents or not target.is_file():
        raise HTTPException(404)
    return FileResponse(target)


# ---------- Acervo de mídia (reaproveitada entre vídeos) ----------

@app.get("/acervo", response_class=HTMLResponse)
def page_library(request: Request, q: str = "", tipo: str = ""):
    from esteira import library
    return tpl.TemplateResponse(request, "acervo.html", {"itens": library.list_all(q, tipo, limite=180), "q": q,
                                                         "tipo": tipo, "e": library.call_statistics()})


@app.get("/acervo/mini/{mid}")
def thumbnail_library(mid: str):
    from esteira import library
    it = library.item(mid)
    if not it:
        raise HTTPException(404)
    file = library.thumbnail(it)
    if not file.exists():
        raise HTTPException(404)
    return FileResponse(file)


# ---------- API JSON do app Flutter (plataforma, módulo Empreendimento) ----------

from esteira.web.api import router as _api  # noqa: E402  (no fim: a API usa os auxiliares acima)
from esteira.web.api_editor import router as _api_editor  # noqa: E402
from esteira.web.api_studio import router as _api_estudio  # noqa: E402
from esteira.web.api_system import router as _api_sistema  # noqa: E402
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402

app.add_middleware(CORSMiddleware, allow_origin_regex=r"https?://(localhost|127\.0\.0\.1)(:\d+)?",
                   allow_methods=["*"], allow_headers=["*"])
app.include_router(_api)
app.include_router(_api_editor)
app.include_router(_api_estudio)
app.include_router(_api_sistema)
