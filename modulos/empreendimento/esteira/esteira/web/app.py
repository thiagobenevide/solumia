"""Painel da esteira (`./dark painel`): biblioteca de roteiros do vault com seleção → fila de produção,
acompanhamento ao vivo de cada etapa, estrutura do roteiro (partes, falas, cenas, citações com o PDF),
prévia dos gráficos, revisão de cortes, linha do tempo das cenas, edição manual e custos do Claude.

Tudo o que os botões fazem passa pelos mesmos comandos do `./dark` (via fila), então o painel nunca tem uma
lógica própria que divirja do terminal. Atualização ao vivo por polling do HTMX (fragmentos `_*`).
"""
import json
import os
import tomllib
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
import re
import subprocess

from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, PlainTextResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from esteira.fontes import gravacoes, obsidian
from esteira.nucleo import status
from esteira.nucleo.tela import SemTela
from esteira.projeto import PROJETOS, RAIZ, Projeto, ep_id, pasta_ep
from esteira.web import fila

AQUI = Path(__file__).parent
PIPELINE = ["limpar", "cenas", "curar", "buscar", "avaliar", "graficos", "montar", "thumb"]
NOMES = {"limpar": "Cortes da narração", "cenas": "Cenas", "curar": "Curadoria (LLM)", "buscar": "Busca de mídia",
         "avaliar": "Avaliação visual", "graficos": "Gráficos animados", "montar": "Montagem e exportação",
         "thumb": "Thumbnail", "transcrever": "Transcrição", "quadros": "Quadros", "revisar": "Folhas de revisão"}

app = FastAPI(title="Esteira dark")


# A esteira não tem login (no PC só ouve 127.0.0.1; pela VPS o nginx exige o token). Sem estas
# travas, qualquer site aberto no navegador do PC poderia mandar formulários para ela (CSRF) ou, com
# DNS rebinding, ler as respostas. Host só local (o túnel chega com Host: localhost); POST/PUT/DELETE
# de navegador só da própria esteira ou do domínio da VPS (o app nativo não manda Origin).
_HOSTS_LOCAIS = re.compile(r"(localhost|127\.0\.0\.1|\[::1\])(:\d+)?")
_ORIGENS = re.compile(
    r"https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?|https://"
    + re.escape(os.environ.get("ESTEIRA_DOMINIO", "agent.thiagobenevide.com"))
)


@app.middleware("http")
async def _so_local(request: Request, call_next):
    if not _HOSTS_LOCAIS.fullmatch(request.headers.get("host", "")):
        return PlainTextResponse("Host não permitido", status_code=403)
    origem = request.headers.get("origin")
    if request.method not in ("GET", "HEAD", "OPTIONS") and origem and not _ORIGENS.fullmatch(origem):
        return PlainTextResponse("Origem não permitida", status_code=403)
    return await call_next(request)


@app.exception_handler(SemTela)
def _sem_tela(_pedido, erro):
    return JSONResponse({"detail": str(erro)}, status_code=503)


app.mount("/static", StaticFiles(directory=AQUI / "static"), name="static")
app.mount("/fontes", StaticFiles(directory=AQUI.parent / "graficos" / "fontes"), name="fontes")
app.mount("/graf", StaticFiles(directory=AQUI.parent / "graficos"), name="graf")  # prévia do editor (fontes dos modelos)
tpl = Jinja2Templates(directory=AQUI / "templates")
# Quem faz cada operação: Python puro, LLM local (Ollama na GPU), outro modelo na GPU ou Claude (assinatura).
MOTORES = {
    "transcrever": [("gpu", "Whisper na GPU"), ("py", "Python")],
    "limpar": [("py", "Python"), ("local", "LLM local"), ("claude", "Claude só se houver dúvida")],
    "cenas": [("py", "Python")],
    "curar": [("local", "LLM local")],
    "buscar": [("py", "Python + APIs dos bancos")],
    "avaliar": [("local", "visão local"), ("claude", "Claude só se houver dúvida")],
    "revisar": [("py", "Python")], "quadros": [("py", "Python")], "exportar": [("py", "Python + FilmCraft")],
    "graficos": [("local", "LLM local planeja"), ("py", "Python renderiza (CPU)")],
    "montar": [("py", "Python + FilmCraft")],
    "thumb": [("local", "LLM local"), ("gpu", "RealVisXL na GPU"), ("claude", "Claude escolhe as 3")],
    "tudo": [("py", "Python"), ("local", "LLM local"), ("gpu", "GPU"), ("claude", "Claude só se houver dúvida")],
    "roteiro": [("py", "Python + OpenAlex"), ("local", "LLM local")],
    "painel": [("py", "Python")], "importar": [("py", "Python")],
}


def _motor_ia():
    from esteira.nucleo import opcoes
    o = opcoes.ler()
    if o["motor"] == "claude":
        return "Claude (" + opcoes.claude({"modelo": "claude-sonnet-5-5"})["modelo"].removeprefix("claude-") + ")"
    return "LLM local"


tpl.env.globals.update(NOMES=NOMES, MOTORES=MOTORES, motor_ia=_motor_ia)
tpl.env.filters["datahora"] = lambda t: datetime.fromtimestamp(t).strftime("%d/%m %H:%M")


def _cfg():
    return tomllib.loads((RAIZ / "config.toml").read_text())


def _pasta(ep):
    p = pasta_ep(ep).resolve()
    if p.parent.parent != PROJETOS.resolve() or not p.is_dir():
        raise HTTPException(404, "projeto não encontrado")
    return p


def _projeto_do_roteiro(caminho):
    """Pasta de projeto já criada a partir deste roteiro (roteiro.json guarda a origem)."""
    for rj in PROJETOS.glob("*/*/roteiro.json"):
        try:
            if json.loads(rj.read_text()).get("origem") == caminho:
                return ep_id(rj.parent)
        except ValueError:
            pass
    return None


def final_do_ep(pasta):
    """`final.mp4` em vigor: o do Estúdio no formato do episódio, se existir (substitui gráficos + montagem); senão o
    da montagem."""
    formato = Projeto(pasta).cfg["video"].get("formato", "16:9").replace(":", "x")
    estudio = pasta / "estudio" / formato / "final.mp4"
    return estudio if estudio.exists() else pasta / "final.mp4"


def _resumo_ep(ep):
    pasta = pasta_ep(ep)
    est = status.etapas(pasta)
    final = final_do_ep(pasta)
    de_estudio = final.parent != pasta
    feitas = sum(1 for e in PIPELINE if est.get(e, {}).get("status") == "ok"
                 or de_estudio and e in ("graficos", "montar"))
    rodando = next((e for e, v in est.items() if v["status"] == "rodando"), None)
    erro = next((e for e, v in est.items() if v["status"] == "erro"), None)
    # roteiro reimportado ou gráficos refeitos depois da exportação: o vídeo não tem as mudanças
    fontes = ("estudio/mapa.json", "estudio/corte/corte.json") if de_estudio else ("graficos.json",)
    desatualizado = final.exists() and any((pasta / a).exists() and (pasta / a).stat().st_mtime > final.stat().st_mtime
                                           for a in (*fontes, "plano.json", "roteiro.json"))
    return {"feitas": feitas, "total": len(PIPELINE), "rodando": rodando, "erro": erro, "desatualizado": desatualizado,
            "final": final.exists() and (de_estudio or est.get("montar", {}).get("status") == "ok"),
            "thumb": (pasta / "thumb.png").exists()}


@app.on_event("startup")
def _iniciar():
    fila.iniciar()
    from esteira import monitor
    monitor.iniciar(_cfg())


@app.get("/", response_class=HTMLResponse)
def biblioteca(request: Request, canal: str = "", status_r: str = ""):
    cfg = _cfg()["fontes"]
    canais = obsidian.canais(cfg["vault"])
    canal = canal or (canais[0] if canais else "")
    itens = []
    for r in obsidian.listar(cfg["vault"], canal):
        if status_r and r["status"] != status_r:
            continue
        audio = gravacoes.candidatos(cfg["gravacoes"], canal, r["numero"], r["titulo"], n=1, short=bool(r["short"]))
        ep = _projeto_do_roteiro(r["caminho"])
        itens.append(dict(r, audio=audio[0] if audio and audio[0]["nota"] >= 0.5 else None,
                          ep=ep, prog=_resumo_ep(ep) if ep else None))
    for r in itens:
        r["citacoes"] = len(re.findall(r"^>\s*\[!cite\]", Path(r["caminho"]).read_text(), re.M))  # só blocos
    contagem = {c: sum(len(list((obsidian.pasta_canais(cfg["vault"]) / c / sub).glob("*.md")))
                       for sub in ("Roteiros", "Shorts")) for c in canais}
    from esteira.projeto import Projeto
    perfil_modo = {}
    for r in itens:  # modo: do roteiro, senão do projeto/perfil do canal
        r["modo_definido"] = r["modo"] in ("dark", "apresentador")
        if not r["modo_definido"]:
            r["modo"] = ""
            if r["ep"]:
                r["modo"] = Projeto(pasta_ep(r["ep"])).cfg.get("producao", {}).get("modo", "dark")
            else:
                r["modo"] = perfil_modo.setdefault(canal, _modo_do_perfil(canal))
    return tpl.TemplateResponse(request, "biblioteca.html", {"canais": canais, "canal": canal, "itens": itens,
                                                             "contagem": contagem, "status_r": status_r})


def _modo_do_perfil(canal):
    perfil = RAIZ / "perfis" / f"{canal}.toml"
    cfg = _cfg()
    if perfil.exists():
        cfg.update(tomllib.loads(perfil.read_text()))
    return cfg.get("producao", {}).get("modo", "dark")


@app.post("/produzir")
async def produzir(request: Request):
    from esteira.fontes.importar import importar
    form = await request.form()
    for caminho in form.getlist("roteiro"):
        ep = _projeto_do_roteiro(caminho) or ep_id(importar(Path(caminho)))
        fila.adicionar(ep, "tudo")
    return RedirectResponse("/fila", status_code=303)


@app.get("/fila", response_class=HTMLResponse)
def pagina_fila(request: Request):
    return tpl.TemplateResponse(request, "fila.html", {})


@app.get("/_fila", response_class=HTMLResponse)
def fragmento_fila(request: Request):
    from esteira.nucleo import processos, travas
    tarefas = list(reversed(fila.listar()))
    proc = {r.get("fila"): r["id"] for r in processos.listar(400) if r.get("fila")}
    for t in tarefas:
        t["prog"] = _resumo_ep(t["ep"]) if ":" not in t["ep"] and pasta_ep(t["ep"]).is_dir() else None
        t["proc"] = proc.get(str(t["id"]))
    vagas = {v: travas.dono(v) for v in travas.VAGAS}
    return tpl.TemplateResponse(request, "_fila.html", {"tarefas": tarefas, "vagas": vagas})


@app.post("/fila/roteiro")
def fila_roteiro(alvo: str = Form(...), ate: str = Form(""), motor: str = Form("local")):
    """Roteiro(s) do plano do canal na fila (`./dark roteiro canal:N [--ate M] [--motor claude]`)."""
    if not re.fullmatch(r"[a-z0-9_-]+:\d+", alvo.strip()):
        raise HTTPException(400, "use canal:N, ex.: finlumia:51")
    fila.adicionar(alvo.strip(), "roteiro", ["--ate", ate.strip()] if ate.strip().isdigit() else [], motor)
    return RedirectResponse("/fila", status_code=303)


@app.post("/fila/{tid}/cancelar")
def cancelar(tid: int):
    fila.cancelar(tid)
    return RedirectResponse("/fila", status_code=303)


@app.post("/fila/limpar")
def limpar_fila():
    fila.limpar_concluidas()
    return RedirectResponse("/fila", status_code=303)


@app.get("/ep/{ep}", response_class=HTMLResponse)
def episodio(request: Request, ep: str):
    pasta = _pasta(ep)
    rot = json.loads((pasta / "roteiro.json").read_text()) if (pasta / "roteiro.json").exists() else {}
    from esteira.projeto import Projeto
    cfg = Projeto(pasta).cfg
    vertical = cfg["video"].get("formato", "16:9") == "9:16"
    from esteira import producao
    proj = Projeto(pasta)
    modo = producao.modo(proj)
    camera = producao.info_camera(proj) if producao.camera(proj) else None
    return tpl.TemplateResponse(request, "episodio.html", {"ep": ep, "rot": rot, "pipeline": PIPELINE,
                                                           "final": (pasta / "final.mp4").exists(),
                                                           "thumb": (pasta / "thumb.png").exists(),
                                                           "vertical": vertical,
                                                           "prog": _resumo_ep(ep),
                                                           "modo": modo, "camera": camera,
                                                           "fcproj": (pasta / "projeto.fcproj").exists(),
                                                           "manuais": sorted(p.name for p in pasta.glob("projeto.manual-*.fcproj"))})


# ---------- Estrutura do roteiro: partes, falas, cenas e citações (o que a esteira leu do vault) ----------

def _recorte_citacao(pasta, k, c):
    """PNG do pedaço da página do PDF com o trecho (cache em graficos/) e os retângulos do marca-texto em %."""
    import pymupdf
    from esteira.graficos import pdf as P
    destino = pasta / "graficos" / f"cite_{k}.png"
    meta = destino.with_suffix(".json")
    if destino.exists() and meta.exists() and meta.stat().st_mtime >= Path(c["arquivo"]).stat().st_mtime:
        return json.loads(meta.read_text())
    achado = P.localizar(c["arquivo"], c["en"], c["pagina"] - 1)
    if not achado:
        return None
    pg = pymupdf.open(c["arquivo"])[achado["pagina"]]
    x0, y0 = min(r[0] for r in achado["rects"]), min(r[1] for r in achado["rects"])
    x1, y1 = max(r[2] for r in achado["rects"]), max(r[3] for r in achado["rects"])
    clip = pymupdf.Rect(max(pg.rect.x0, min(x0, pg.rect.width * 0.08) - 10), max(0, y0 - 70),
                        min(pg.rect.x1, max(x1, pg.rect.width * 0.92) + 10), min(pg.rect.y1, y1 + 70))
    pix = pg.get_pixmap(dpi=150, clip=clip)
    destino.parent.mkdir(exist_ok=True)
    pix.save(destino)
    w, h = clip.width, clip.height
    dados = {"img": destino.name, "pagina": achado["pagina"] + 1, "nota": achado["nota"],
             "rects": [[round((r[0] - clip.x0) / w * 100, 2), round((r[1] - clip.y0) / h * 100, 2),
                        round((r[2] - r[0]) / w * 100, 2), round((r[3] - r[1]) / h * 100, 2)] for r in achado["rects"]]}
    meta.write_text(json.dumps(dados))
    return dados


@app.get("/ep/{ep}/roteiro", response_class=HTMLResponse)
def roteiro(request: Request, ep: str):
    pasta = _pasta(ep)
    if not (pasta / "roteiro.json").exists():
        return tpl.TemplateResponse(request, "vazio.html", {"ep": ep, "msg": "Projeto sem roteiro.json: importe do vault."})
    rot = json.loads((pasta / "roteiro.json").read_text())
    falas = [l for l in (pasta / "roteiro.txt").read_text().splitlines()[1:] if l.strip()]
    caps = rot.get("capitulos", [])
    partes = []
    for i, cap in enumerate(caps):
        fim = caps[i + 1]["fala"] if i + 1 < len(caps) else len(falas)
        partes.append({**cap, "itens": []})
        for k in range(cap["fala"], fim):
            for n in rot.get("notas", []):
                if n["antes_da_fala"] == k:
                    texto = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", n["texto"].replace("<", "&lt;"))
                    partes[-1]["itens"].append({"tipo": "cena", "texto": texto})
            fala = re.sub(r"\*([^*]+)\*", r"<mark>\1</mark>", falas[k].replace("<", "&lt;"))
            partes[-1]["itens"].append({"tipo": "fala", "n": k + 1, "texto": fala})
            for j, c in enumerate(rot.get("citacoes", [])):
                if c["fala"] == k:
                    rec = _recorte_citacao(pasta, j, c) if c.get("ok") and Path(c["arquivo"]).exists() else None
                    partes[-1]["itens"].append({"tipo": "cite", "c": c, "j": j, "rec": rec})
    graficos = json.loads((pasta / "graficos.json").read_text()) if (pasta / "graficos.json").exists() else []
    na_tela = {g["dados"].get("trecho") for g in graficos if g["modelo"] == "citacao" and g.get("arquivo")}
    citadas = {re.split(r"[ ,]", c["autores"])[0].lower() for c in rot.get("citacoes", []) if c.get("autores")}
    for f in rot.get("fontes", []):
        sobrenome = re.split(r"[ ,]", f["autores"])[0].lower()
        f["situacao"] = "citação na tela" if sobrenome in citadas else "só tarja / lista"
    for it in (i for p in partes for i in p["itens"] if i["tipo"] == "cite"):
        it["no_video"] = it["c"]["en"] in na_tela
    palavras = sum(len(f.split()) for f in falas)
    return tpl.TemplateResponse(request, "roteiro.html", {"ep": ep, "rot": rot, "partes": partes,
                                                          "n_falas": len(falas), "palavras": palavras,
                                                          "tem_graficos": bool(graficos)})


@app.get("/pdf")
def pdf_do_vault(arq: str):
    """PDFs de Referências/ do vault (para abrir a citação na página certa no navegador)."""
    cfg = _cfg()["fontes"]
    raiz = (Path(cfg["vault"]).expanduser() / "Referências").resolve()
    alvo = Path(arq).expanduser().resolve()
    if raiz not in alvo.parents or alvo.suffix.lower() != ".pdf" or not alvo.is_file():
        raise HTTPException(404)
    return FileResponse(alvo, media_type="application/pdf", headers={"Content-Disposition": "inline"})


# ---------- Gráficos: prévia de cada .mov renderizado ----------

@app.get("/ep/{ep}/graficos", response_class=HTMLResponse)
def graficos(request: Request, ep: str):
    pasta = _pasta(ep)
    arq = pasta / "graficos.json"
    if not arq.exists():
        return tpl.TemplateResponse(request, "vazio.html", {"ep": ep, "msg": "Os gráficos ainda não foram planejados."})
    from esteira.projeto import Projeto
    v = Projeto(pasta).cfg["video"]
    lista = json.loads(arq.read_text())
    for g in lista:
        ecp = pasta / g["ecproj"] if g.get("ecproj") else None
        g["ec_editado"] = bool(ecp and ecp.exists() and ecp.stat().st_mtime > g.get("ec_gerado", 0) + 1)
    por_tipo = {}
    for g in lista:
        por_tipo[g["modelo"]] = por_tipo.get(g["modelo"], 0) + 1
    return tpl.TemplateResponse(request, "graficos.html", {"ep": ep, "graficos": lista, "por_tipo": por_tipo,
                                                           "editados_ec": sum(g["ec_editado"] for g in lista),
                                                           "vertical": v["altura"] > v["largura"]})


@app.get("/ep/{ep}/previa/{nome}")
def previa_grafico(ep: str, nome: str):
    """Quadro do gráfico (aos 65% da duração) sobre fundo cinza; gerado na 1ª visita e guardado ao lado do .mov."""
    pasta = _pasta(ep)
    mov = (pasta / "graficos" / nome).resolve()
    if mov.parent != (pasta / "graficos").resolve() or mov.suffix != ".mov" or not mov.exists():
        raise HTTPException(404)
    png = mov.with_suffix(".previa.jpg")
    if not png.exists():
        from esteira.midia import duracao_midia
        from esteira.projeto import Projeto
        v = Projeto(pasta).cfg["video"]
        n = int(duracao_midia(mov) * v["fps"] * 0.65)  # quadro escolhido por índice: -ss perde o alfa perto do fim
        subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", str(mov),
                        "-f", "lavfi", "-i", f"color=c=0x2a2d33:s={v['largura']}x{v['altura']}", "-filter_complex",
                        f"[0:v]select=eq(n\\,{n}),setpts=PTS-STARTPTS[g];[1:v][g]overlay=eof_action=pass,scale=-2:540",
                        "-frames:v", "1", "-q:v", "4", str(png)], check=True)
    return FileResponse(png)


# ---------- Monitor da máquina (GPU, CPU, energia, processos, arquivos) ----------

@app.get("/monitor", response_class=HTMLResponse)
def pagina_monitor(request: Request):
    return tpl.TemplateResponse(request, "monitor.html", {})


@app.get("/processos", response_class=HTMLResponse)
def pagina_processos(request: Request):
    from esteira.nucleo import processos, travas
    return tpl.TemplateResponse(request, "processos.html", {"processos": processos.listar(300),
                                                            "vagas": {v: travas.dono(v) for v in travas.VAGAS}})


@app.get("/processos/{pid_id}", response_class=HTMLResponse)
def pagina_processo(request: Request, pid_id: str):
    from esteira.nucleo import processos
    r = processos.obter(pid_id)
    if not r:
        raise HTTPException(404, "processo não encontrado")
    return tpl.TemplateResponse(request, "processo.html", {"p": r})


@app.post("/processos/{pid_id}/parar")
def parar_processo(pid_id: str):
    """Para o processo (e o que ele abriu), venha da fila ou do terminal."""
    from esteira.nucleo import processos
    r = processos.obter(pid_id)
    if r and r["estado"] == "rodando":
        t = next((t for t in fila.listar() if str(t["id"]) == str(r.get("fila"))), None)
        if t:
            fila.cancelar(t["id"])
        else:
            fila._encerrar({"pid": r["pid"], "comando": r["comando"], "ep": r["alvo"], "args": r["args"]})
    return RedirectResponse(f"/processos/{pid_id}", status_code=303)


@app.get("/api/processos/{pid_id}")
def api_processo(pid_id: str):
    from esteira import monitor, monitor_processo
    d = monitor_processo.detalhe(pid_id, monitor.estado(0.0).get("atual"))
    if not d:
        raise HTTPException(404, "processo não encontrado")
    d["tarefa_fila"] = next((t for t in fila.listar() if str(t["id"]) == str(d["processo"].get("fila"))), None)
    return JSONResponse(d)


@app.get("/api/monitor")
def api_monitor():
    from esteira import monitor
    e = monitor.estado(_cfg().get("monitor", {}).get("tarifa_kwh", 0.85))
    e["fila"] = [t for t in fila.listar() if t["estado"] in ("rodando", "na fila")]
    return JSONResponse(e)


@app.get("/api/grafo")
def api_grafo():
    from esteira import grafo, monitor
    from esteira.grafo import NOS, SEQ, USA
    atual = monitor.estado(0)["atual"]
    return JSONResponse(dict(grafo.estado(atual), def_nos=[{"id": i, "rotulo": r, "faixa": f, "motor": m} for i, r, f, m, _ in NOS],
                             seq=SEQ, usa=USA))


@app.get("/api/grafo/no/{id_no}")
def api_grafo_no(id_no: str):
    from esteira import grafo, monitor
    if id_no not in grafo.IDS:
        raise HTTPException(404)
    e = monitor.estado(0)
    return JSONResponse(grafo.detalhe(id_no, e["atual"], e["hist"]))


# ---------- Editor manual: gráficos e thumbnails ----------

def _projeto(ep):
    from esteira.projeto import Projeto
    return Projeto(_pasta(ep))


def _erro(e):
    return PlainTextResponse(str(e), status_code=400)


def _ctx_editor(p, ep, tipo):
    rot = json.loads(p.caminho("roteiro.json").read_text()) if p.caminho("roteiro.json").exists() else {}
    cits = [{k: c.get(k) for k in ("autores", "ano", "revista", "pt")} for c in rot.get("citacoes", [])]
    return {"ep": ep, "tipo": tipo, "citacoes": cits, "motor": p.cfg.get("editor", {}).get("motor_ia", "claude"),
            "cor": p.cfg.get("graficos", {}).get("cor", "#ffd400")}


@app.get("/ep/{ep}/graficos/{i}/editar", response_class=HTMLResponse)
def editar_grafico(request: Request, ep: str, i: int, t: float = 0.0):
    from esteira import editor
    p = _projeto(ep)
    w, h = editor._dim(p)
    lista = editor.graficos(p)
    if i >= len(lista):
        raise HTTPException(404)
    return tpl.TemplateResponse(request, "editor.html", _ctx_editor(p, ep, "grafico") | {
        "i": i, "estado": editor.estado_grafico(p, i, t), "w": w, "h": h, "modelos": editor.MODELOS,
        "titulo_pagina": "Novo gráfico" if i < 0 else f"Gráfico {i + 1} de {len(lista)}"})


@app.get("/ep/{ep}/thumbs", response_class=HTMLResponse)
def pagina_thumbs(request: Request, ep: str):
    from esteira import editor
    p = _projeto(ep)
    from esteira import photocraft
    vagas = [(k, p.caminho(f"thumb_{k}.png")) for k in (1, 2, 3)]
    lista = editor.thumbs(p)
    for t in lista:  # .pcraft salvo à mão no PhotoCraft → refaz o PNG (as vagas 1–3 são cópias: use de novo)
        pc = p.caminho(f"thumbs/{t['arquivo']}").with_suffix(".pcraft")
        if photocraft.editado(pc):
            photocraft.exportar(pc)
            marcas = p.caminho("thumbs/editadas_photocraft.json")
            feitas = set(json.loads(marcas.read_text())) if marcas.exists() else set()
            marcas.write_text(json.dumps(sorted(feitas | {t["arquivo"]})))
    marcas = p.caminho("thumbs/editadas_photocraft.json")
    feitas = set(json.loads(marcas.read_text())) if marcas.exists() else set()
    for t in lista:
        t["pc_editado"] = t["arquivo"] in feitas
    return tpl.TemplateResponse(request, "thumbs.html", {
        "ep": ep, "thumbs": lista, "fundos": editor.fundos(p),
        "vagas": [(k, int(a.stat().st_mtime)) for k, a in vagas if a.exists()]})


@app.get("/ep/{ep}/thumbs/editar", response_class=HTMLResponse)
def editar_thumb(request: Request, ep: str, arq: str = "", fundo: str = ""):
    from esteira import editor
    p = _projeto(ep)
    fundos = editor.fundos(p)
    if not fundos:
        return tpl.TemplateResponse(request, "vazio.html", {"ep": ep, "msg": "Sem fundos: rode a etapa thumb ou envie uma imagem em Thumbs."})
    estado = next((t["estado"] for t in editor.thumbs(p) if t["arquivo"] == arq), None) or {
        "texto": "TEXTO DA THUMB", "destaque": "", "layout": "rosto_direita", "seta": False,
        "fundo": fundo if fundo in fundos else fundos[0]}
    w, h = editor._dim_thumb(p)
    return tpl.TemplateResponse(request, "editor.html", _ctx_editor(p, ep, "thumb") | {
        "i": -1, "estado": estado, "w": w, "h": h, "fundos": fundos, "titulo_pagina": "Thumbnail"})


@app.post("/ep/{ep}/editor/previa", response_class=HTMLResponse)
async def editor_previa(request: Request, ep: str):
    from esteira import editor
    corpo = await request.json()
    p = _projeto(ep)
    try:
        if corpo.get("tipo") == "thumb":
            return HTMLResponse(editor.previa_thumb(p, ep, corpo["estado"]))
        return HTMLResponse(editor.previa_grafico(p, ep, corpo["estado"]))
    except (ValueError, KeyError, TypeError) as e:
        return _erro(e)


@app.post("/ep/{ep}/editor/grafico/{i}")
async def editor_salvar_grafico(request: Request, ep: str, i: int):
    from esteira import editor
    p = _projeto(ep)
    try:
        novo = editor.salvar_grafico(p, i, await request.json())
    except (ValueError, KeyError, TypeError, IndexError) as e:
        return _erro(e)
    fila.adicionar(ep, "graficos", ["--so-render"])  # só a peça editada é renderizada; o resto está em cache
    return {"i": novo}


@app.post("/ep/{ep}/editor/grafico/{i}/excluir")
def editor_excluir_grafico(ep: str, i: int):
    from esteira import editor
    editor.excluir_grafico(_projeto(ep), i)
    return RedirectResponse(f"/ep/{ep}/graficos", status_code=303)


@app.post("/ep/{ep}/editor/thumb")
async def editor_salvar_thumb(request: Request, ep: str):
    from esteira import editor
    try:
        return {"arquivo": editor.salvar_thumb(_projeto(ep), await request.json())}
    except (ValueError, KeyError, TypeError) as e:
        return _erro(e)


@app.post("/ep/{ep}/thumbs/usar")
def usar_thumb(ep: str, arq: str = Form(...), k: int = Form(...)):
    from esteira import editor
    try:
        editor.usar_thumb(_projeto(ep), arq, k)
    except ValueError as e:
        return _erro(e)
    return RedirectResponse(f"/ep/{ep}/thumbs", status_code=303)


@app.post("/ep/{ep}/thumbs/fundo")
async def enviar_fundo(ep: str, arquivo: UploadFile = File(...)):
    from esteira import editor
    sufixo = Path(arquivo.filename or "").suffix.lower()
    if sufixo not in (".png", ".jpg", ".jpeg", ".webp"):
        return _erro("envie PNG, JPG ou WebP")
    nome = editor.guardar_fundo(_projeto(ep), await arquivo.read(), ".png" if sufixo == ".png" else sufixo)
    return RedirectResponse(f"/ep/{ep}/thumbs/editar?fundo={nome}", status_code=303)


@app.post("/ep/{ep}/editor/ia")
async def editor_ia(request: Request, ep: str):
    from esteira import editor
    corpo = await request.json()
    pedido = (corpo.get("pedido") or "").strip()
    if not pedido:
        return _erro("escreva o pedido")
    from esteira.nucleo import travas
    if corpo.get("motor", "claude") == "local" and not travas.livre("maquina"):
        d = travas.dono("maquina")
        return _erro(f"a máquina está ocupada por `{d['comando']}`: só um processo local por vez. "
                     "Use o motor Claude ou espere terminar.")
    try:
        import asyncio
        novo, explicacao, avisos = await asyncio.to_thread(
            editor.sugerir, _projeto(ep), ep, corpo["estado"], pedido, corpo.get("motor", "claude"), corpo.get("tipo", "grafico"))
    except (ValueError, KeyError, TypeError) as e:
        return _erro(e)
    return JSONResponse({"estado": novo, "explicacao": explicacao, "avisos": avisos})


# ---------- Edição manual no FilmCraft ----------

@app.post("/ep/{ep}/abrir")
def abrir_filmcraft(ep: str):
    from esteira.montar import abrir
    from esteira.projeto import Projeto
    abrir(Projeto(_pasta(ep)))
    return RedirectResponse(f"/ep/{ep}", status_code=303)


def garantir_ecproj(ep: str, i: int):
    """.ecproj da peça (cria agora se a peça é de antes do EffectCraft); None se a citação não achou o trecho."""
    from esteira.graficos import effectcraft, plano
    p = _projeto(ep)
    lista = p.carregar_json("graficos.json")
    if not 0 <= i < len(lista):
        raise HTTPException(404, "peça não encontrada")
    c = lista[i]
    ecp = p.pasta / c["ecproj"] if c.get("ecproj") else None
    if not ecp or not ecp.exists():
        w, h = p.cfg["video"]["largura"], p.cfg["video"]["altura"]
        pasta = p.caminho("graficos")
        base = Path(c["arquivo"]).stem if c.get("arquivo") else f"{c['modelo']}_{int(c['inicio'] * 1000)}"
        pc = plano.peca(c, pasta, w, h, pasta / f"pag_{base}.png")
        if not pc:
            return None
        ecp = effectcraft.construir(*pc, c["dur"], pasta / f"{base}.ecproj", w, h,
                                    p.cfg.get("graficos", {}).get("cor", "#ffd400"), p.cfg["video"]["fps"])
        c.update(ecproj=str(ecp.relative_to(p.pasta)), ec_gerado=ecp.stat().st_mtime)
        p.salvar_json("graficos.json", lista)
    return ecp


@app.post("/ep/{ep}/graficos/{i}/effectcraft")
def abrir_effectcraft(ep: str, i: int):
    """Abre o .ecproj da peça no EffectCraft (cria agora se a peça é de antes do EffectCraft)."""
    from esteira.graficos import effectcraft
    ecp = garantir_ecproj(ep, i)
    if not ecp:
        return _erro("a citação não achou o trecho no PDF")
    effectcraft.abrir(ecp)
    return RedirectResponse(f"/ep/{ep}/graficos", status_code=303)


def garantir_pcraft(ep: str, arq: str):
    """Thumb em camadas (.pcraft) ao lado do PNG (cria agora se a thumb é de antes do PhotoCraft)."""
    from esteira import editor
    from esteira.thumbs import compor_arquivo
    p = _projeto(ep)
    t = next((t for t in editor.thumbs(p) if t["arquivo"] == arq), None)
    if not t:
        raise HTTPException(404, "thumb não encontrada")
    png = p.caminho(f"thumbs/{arq}")
    pc = png.with_suffix(".pcraft")
    if not pc.exists():
        compor_arquivo(t["estado"], p.caminho(f"thumbs/{t['estado']['fundo']}"), png, p.cfg)
    return pc


@app.post("/ep/{ep}/thumbs/photocraft")
def abrir_photocraft(ep: str, arq: str = Form(...)):
    """Abre a thumb em camadas (.pcraft) no PhotoCraft (cria agora se a thumb é de antes do PhotoCraft)."""
    from esteira import photocraft
    photocraft.abrir(garantir_pcraft(ep, arq))
    return RedirectResponse(f"/ep/{ep}/thumbs", status_code=303)


@app.get("/ep/{ep}/_etapas", response_class=HTMLResponse)
def fragmento_etapas(request: Request, ep: str):
    pasta = _pasta(ep)
    est = status.etapas(pasta)
    linhas = [(e, est.get(e)) for e in PIPELINE] + [(e, v) for e, v in est.items() if e not in PIPELINE]
    evs = [e for e in status.eventos(pasta) if e["tipo"] in ("saida", "aviso", "erro", "claude", "inicio", "fim")]
    from esteira.ia import claude
    gasto = claude.gasto(ep)[0]
    return tpl.TemplateResponse(request, "_etapas.html", {"ep": ep, "linhas": linhas, "eventos": evs[-40:][::-1],
                                                          "gasto": gasto})


@app.post("/ep/{ep}/rodar/{etapa}")
def rodar(ep: str, etapa: str, refazer: str = Form(""), motor: str = Form(""), so_render: str = Form("")):
    from esteira.nucleo import opcoes
    _pasta(ep)
    if etapa not in PIPELINE + ["tudo", "quadros", "transcrever", "exportar"]:
        raise HTTPException(400, "etapa desconhecida")
    motor = motor or opcoes.ler()["motor"]
    args = ["--refazer"] if refazer and etapa in ("limpar", "curar", "buscar", "tudo") else []
    if so_render and etapa == "graficos":
        args = ["--so-render"]
    fila.adicionar(ep, etapa, args, motor)
    return RedirectResponse(f"/ep/{ep}/graficos" if so_render else f"/ep/{ep}", status_code=303)


# ── Opções: motor de LLM (local ou Claude), modelo do Claude, modelos locais por operação, baixar modelos ──
_baixando = {}  # nome → {"estado", "feito", "total", "msg"}


def _modelos_locais():
    """Modelos do llama.cpp (`~/agent-data/modelos`): [{nome, GB, visão}]."""
    from esteira.ia import llama
    if not llama.servidor():
        return []
    saida = [{"nome": m["id"], "gb": llama.gb(m["id"]), "visao": llama.visao(m)} for m in llama.modelos() or []]
    return sorted(saida, key=lambda m: m["nome"])


@app.get("/opcoes", response_class=HTMLResponse)
def pagina_opcoes(request: Request, salvo: str = ""):
    from esteira.ia import local
    from esteira.nucleo import opcoes
    cfg = _cfg().get("claude", {})
    o = opcoes.ler()
    ops = [(k, nome, desc, tipos, opcoes.operacao(k)) for k, (nome, desc, tipos) in opcoes.OPERACOES.items()]
    return tpl.TemplateResponse(request, "opcoes.html", {
        "o": o, "ops": ops, "modelos_claude": opcoes.MODELOS, "sugestoes": opcoes.SUGESTOES, "locais": _modelos_locais(),
        "padrao": {"texto": local.TEXTO, "visao": local.VISAO}, "cfg_claude": opcoes.claude(cfg), "salvo": salvo})


@app.post("/opcoes")
async def salvar_opcoes(request: Request):
    from esteira.nucleo import opcoes
    f = await request.form()
    num = lambda v: float(v.replace(",", ".")) if (v or "").strip() else None
    ops = {}
    for k, (_, _, tipos) in opcoes.OPERACOES.items():
        d = {"motor": f.get(f"{k}.motor") or "padrao"}
        for t in tipos:
            d[t] = f.get(f"{k}.{t}") or None
        ops[k] = d
    opcoes.salvar(motor=f.get("motor") or "local", modelo_claude=f.get("modelo_claude") or None,
                  teto_episodio_usd=num(f.get("teto_episodio_usd")), teto_dia_usd=num(f.get("teto_dia_usd")),
                  operacoes=ops)
    return RedirectResponse("/opcoes?salvo=1", status_code=303)


def _baixar(nome):
    """Baixa `usuario/repo:QUANT` do Hugging Face para a pasta de modelos do llama.cpp."""
    from esteira.ia import llama
    st = _baixando[nome]
    try:
        id_ = llama.baixar(nome, lambda feito, total, msg: st.update(feito=feito, total=total, msg=msg))
        st.update(estado="ok", msg=f"instalado como {id_}")
    except Exception as e:
        st.update(estado="erro", msg=str(e)[:200])


@app.post("/opcoes/baixar")
def baixar_modelo(nome: str = Form(...)):
    import threading
    nome = nome.strip()
    if not re.fullmatch(r"[\w.\-/]+(:[\w.\-]+)?", nome):
        raise HTTPException(400, "nome de modelo inválido (ex.: unsloth/Qwen3-8B-GGUF:Q4_K_M)")
    if _baixando.get(nome, {}).get("estado") != "baixando":
        _baixando[nome] = {"estado": "baixando", "feito": 0, "total": 0, "msg": "começando"}
        threading.Thread(target=_baixar, args=(nome,), daemon=True).start()
    return RedirectResponse("/opcoes#modelos", status_code=303)


@app.get("/opcoes/_baixando", response_class=HTMLResponse)
def fragmento_baixando(request: Request):
    return tpl.TemplateResponse(request, "_baixando.html", {"baixando": _baixando})


@app.get("/ep/{ep}/cortes", response_class=HTMLResponse)
def cortes(request: Request, ep: str, filtro: str = "revisar"):
    pasta = _pasta(ep)
    arq = pasta / "cortes.json"
    if not arq.exists():
        return tpl.TemplateResponse(request, "vazio.html", {"ep": ep, "msg": "Os cortes ainda não foram decididos."})
    dados = json.loads(arq.read_text())
    trechos = [dict(t, k=k) for k, t in enumerate(dados["trechos"])]
    if filtro == "revisar":
        trechos = [t for t in trechos if t["tipo"] != "tomada" or t["confianca"] < 0.85]
    elif filtro == "cortados":
        trechos = [t for t in trechos if not t["manter"]]
    bruta = next((p.name for p in pasta.glob("narracao_bruta.*")), None)
    return tpl.TemplateResponse(request, "cortes.html", {"ep": ep, "trechos": trechos, "faltando": dados["faltando"],
                                                         "bruta": bruta, "filtro": filtro,
                                                         "editado": dados.get("editado_no_painel", False)})


@app.post("/ep/{ep}/cortes/{k}/alternar", response_class=HTMLResponse)
def alternar_corte(request: Request, ep: str, k: int):
    arq = _pasta(ep) / "cortes.json"
    dados = json.loads(arq.read_text())
    t = dados["trechos"][k]
    t["manter"] = not t["manter"]
    t["por"] = "painel"
    t["motivo"] = t["motivo"].split(" → painel")[0] + f" → painel: {'fica' if t['manter'] else 'sai'}"
    dados["editado_no_painel"] = True
    arq.write_text(json.dumps(dados, ensure_ascii=False, indent=1))
    bruta = next((p.name for p in arq.parent.glob("narracao_bruta.*")), None)
    return tpl.TemplateResponse(request, "_corte.html", {"ep": ep, "t": dict(t, k=k), "bruta": bruta})


@app.get("/ep/{ep}/cenas", response_class=HTMLResponse)
def cenas(request: Request, ep: str):
    pasta = _pasta(ep)
    if not (pasta / "plano.json").exists():
        return tpl.TemplateResponse(request, "vazio.html", {"ep": ep, "msg": "As cenas ainda não foram geradas."})
    plano = json.loads((pasta / "plano.json").read_text())
    graficos = json.loads((pasta / "graficos.json").read_text()) if (pasta / "graficos.json").exists() else []
    for c in plano["cenas"]:
        q = pasta / "midia" / f".aval_{c['id']:03d}.jpg"
        c["quadro"] = q.name if q.exists() else (Path(c["midia"]).name if c.get("midia", "").endswith(".jpg") else None)
    return tpl.TemplateResponse(request, "cenas.html", {"ep": ep, "cenas": plano["cenas"], "graficos": graficos,
                                                        "titulo": plano.get("titulo")})


@app.post("/ep/{ep}/cenas/{cid}/trocar")
def trocar_midia(ep: str, cid: int, busca_en: str = Form("")):
    pasta = _pasta(ep)
    if busca_en.strip():
        arq = pasta / "plano.json"
        plano = json.loads(arq.read_text())
        for c in plano["cenas"]:
            if c["id"] == cid:
                c["busca_en"] = busca_en.strip()
        arq.write_text(json.dumps(plano, ensure_ascii=False, indent=2))
    fila.adicionar(ep, "buscar", ["--refazer", "--cenas", str(cid)])
    return RedirectResponse(f"/ep/{ep}/cenas#c{cid}", status_code=303)


@app.get("/custos", response_class=HTMLResponse)
def custos(request: Request):
    from esteira.ia import claude
    regs = list(reversed(claude._registros()))
    por_ep = {}
    for r in regs:
        por_ep[r["ep"]] = por_ep.get(r["ep"], 0) + r["custo"]
    hoje = datetime.now().date().isoformat()
    return tpl.TemplateResponse(request, "custos.html", {
        "regs": regs[:200], "por_ep": sorted(por_ep.items(), key=lambda x: -x[1]), "total": sum(por_ep.values()),
        "hoje": sum(r["custo"] for r in regs if r["t"].startswith(hoje)), "cfg": _cfg().get("claude", {})})


@app.get("/arq/{ep}/{caminho:path}")
def arquivo(ep: str, caminho: str):
    pasta = _pasta(ep)
    alvo = (pasta / caminho).resolve()
    if pasta not in alvo.parents or not alvo.is_file():
        raise HTTPException(404)
    return FileResponse(alvo)


# ---------- Acervo de mídia (reaproveitada entre vídeos) ----------

@app.get("/acervo", response_class=HTMLResponse)
def pagina_acervo(request: Request, q: str = "", tipo: str = ""):
    from esteira import acervo
    return tpl.TemplateResponse(request, "acervo.html", {"itens": acervo.listar(q, tipo, limite=180), "q": q,
                                                         "tipo": tipo, "e": acervo.estatisticas()})


@app.get("/acervo/mini/{mid}")
def miniatura_acervo(mid: str):
    from esteira import acervo
    it = acervo.item(mid)
    if not it:
        raise HTTPException(404)
    arq = acervo.miniatura(it)
    if not arq.exists():
        raise HTTPException(404)
    return FileResponse(arq)


# ---------- API JSON do app Flutter (plataforma, módulo Empreendimento) ----------

from fastapi.middleware.cors import CORSMiddleware  # noqa: E402

from esteira.web.api import router as _api  # noqa: E402  (no fim: a API usa os auxiliares acima)
from esteira.web.api_editor import router as _api_editor  # noqa: E402
from esteira.web.api_estudio import router as _api_estudio  # noqa: E402
from esteira.web.api_sistema import router as _api_sistema  # noqa: E402

app.add_middleware(CORSMiddleware, allow_origin_regex=r"https?://(localhost|127\.0\.0\.1)(:\d+)?",
                   allow_methods=["*"], allow_headers=["*"])
app.include_router(_api)
app.include_router(_api_editor)
app.include_router(_api_estudio)
app.include_router(_api_sistema)
