"""Editor manual do painel: gráficos animados (dados, tempo, efeitos, caixas de texto livres) e thumbnails.

O estado de um gráfico é o próprio item do graficos.json ({modelo, inicio, dur, dados, efeito, caixas}); o
de uma thumb são os campos de `thumbs.data_thumb` + `fundo` (arquivo em thumbs/). A prévia é o mesmo HTML
que vira o vídeo/PNG, servido ao navegador com `seek`. Gráfico salvo fica `manual: true`: o replanejamento
o mantém e só ele é renderizado de novo (o resto está em cache). O assistente de IA (Claude ou LLM local)
devolve um estado novo para a prévia; nada é salvo sem o usuário.
"""
import hashlib
import json
import re
import shutil

from pydantic import BaseModel, Field

from esteira.graphics import plan, render
from esteira.thumbs import data_thumb

MODELS = ("caixas", "frase", "numero", "lista", "comparacao", "capitulo", "fonte", "citacao")
NEW = {"modelo": "caixas", "dur": 4.0, "dados": {"veu": "baixo"}, "efeito": {},
        "caixas": [dict(render.BOX, texto="Novo *texto*")]}
FIELDS_THUMB = ("texto", "destaque", "layout", "seta", "selo", "tamanho", "cor_d", "alerta", "fundo", "caixas")


def _swaps(project, ep):
    return {render.ROOT.as_uri(): "/graf", project.folder_path.resolve().as_uri(): f"/arq/{ep}"}


def _dim(project):
    v = project.cfg["video"]
    return v["largura"], v["altura"]


def _dim_thumb(project):
    t = project.cfg.get("thumb", {})
    return t.get("largura", 1280), t.get("altura", 720)


# ---------- Gráficos ----------

def graphics(project):
    return project.load_json("graficos.json") if project.path_of("graficos.json").exists() else []


def state_graphic(project, i, start=0.0):
    """Item `i` do graficos.json; i < 0 → peça nova de caixas em `inicio`."""
    if i < 0:
        return dict(json.loads(json.dumps(NEW)), inicio=round(start, 2))
    g = graphics(project)[i]
    return {k: g.get(k) for k in ("modelo", "inicio", "dur", "dados", "efeito", "caixas", "origem")} | {
        "efeito": g.get("efeito") or {}, "caixas": g.get("caixas") or []}


def _clean(e):
    if e.get("modelo") not in MODELS:
        raise ValueError("modelo desconhecido")
    return {"modelo": e["modelo"], "inicio": round(float(e["inicio"]), 2), "dur": round(max(1.0, float(e["dur"])), 2),
            "dados": dict(e.get("dados") or {}), "efeito": dict(e.get("efeito") or {}),
            "caixas": [dict(c) for c in e.get("caixas") or []]}


def preview_graphic(project, ep, state):
    e = _clean(state)
    w, h = _dim(project)
    folder = project.path_of("graficos")
    folder.mkdir(exist_ok=True)
    pc = plan.piece(e, folder, w, h, folder / "pag_editor.png")
    if not pc:
        raise ValueError("o trecho da citação não foi achado no PDF")
    return render.preview(*pc, e["dur"], w, h, project.cfg.get("graficos", {}).get("cor", "#ffd400"),
                         _swaps(project, ep))


def html_graphic(project, state):
    """(HTML com caminhos file://, w, h) da peça: o que o app pede como quadro PNG (`web/frames.py`)."""
    e = _clean(state)
    w, h = _dim(project)
    folder = project.path_of("graficos")
    folder.mkdir(exist_ok=True)
    pc = plan.piece(e, folder, w, h, folder / "pag_editor.png")
    if not pc:
        raise ValueError("o trecho da citação não foi achado no PDF")
    return render.html(*pc, e["dur"], w, h, project.cfg.get("graficos", {}).get("cor", "#ffd400")), w, h


def save_graphic(project, i, state):
    """Grava no graficos.json como `manual` (i < 0 acrescenta). Devolve o índice na lista ordenada."""
    e = _clean(state)
    items = graphics(project)
    if i < 0:
        item = dict(e, origem="editor")
        items.append(item)
    else:
        item = items[i]
        item.update(e)
        # dados novos: a peça é refeita a partir deles (um .ecproj editado à mão fica em graficos/ como estava)
        for k in ("arquivo", "manual_ec", "ecproj", "ec_gerado"):
            item.pop(k, None)
    item["manual"] = True
    items.sort(key=lambda g: g["inicio"])
    project.save_json("graficos.json", items)
    return items.index(item)


def delete_graphic(project, i):
    items = graphics(project)
    items.pop(i)
    project.save_json("graficos.json", items)


# ---------- Thumbnails ----------

def _edits(project):
    file = project.path_of("thumbs/edicoes.json")
    return json.loads(file.read_text()) if file.exists() else {}


def backgrounds(project):
    folder = project.path_of("thumbs")
    return sorted(p.name for p in folder.iterdir() if p.name.startswith(("fundo_", "upload_"))
                  and p.suffix in (".png", ".jpg", ".jpeg", ".webp")) if folder.exists() else []


def thumbs(project):
    """Thumbs editáveis: as da etapa (ranking.json) e as feitas no editor (edicoes.json)."""
    output = []
    rk = project.path_of("thumbs/ranking.json")
    for r in json.loads(rk.read_text()) if rk.exists() else []:
        c = r["conceito"]
        background = r.get("fundo") or f"fundo_{hashlib.sha1(c['cena_en'].encode()).hexdigest()[:8]}.png"
        output.append({"arquivo": r["arquivo"], "nota": r.get("nota"), "origem": "etapa",
                      "estado": {k: c.get(k) for k in ("texto", "destaque", "layout", "seta")} | {"fundo": background}})
    for file, e in _edits(project).items():
        output.append({"arquivo": file, "nota": None, "origem": "editor", "estado": e})
    return [t for t in output if project.path_of(f"thumbs/{t['arquivo']}").exists()]


def _clean_thumb(project, e):
    e = {k: e[k] for k in FIELDS_THUMB if k in e}
    if e.get("layout") not in ("rosto_direita", "rosto_esquerda", "numero"):
        e["layout"] = "rosto_direita"
    if "/" in e.get("fundo", "/") or not project.path_of(f"thumbs/{e['fundo']}").exists():
        raise ValueError("fundo inválido")
    return e


def preview_thumb(project, ep, state):
    e = _clean_thumb(project, state)
    w, h = _dim_thumb(project)
    data = data_thumb(e, project.path_of(f"thumbs/{e['fundo']}").resolve().as_uri(), project.cfg)
    return render.preview("thumb", data, 1, w, h, "#ffd400", _swaps(project, ep), estatico=True)


def html_thumb(project, state):
    """(HTML com caminhos file://, w, h) da thumb, como `html_grafico`."""
    e = _clean_thumb(project, state)
    w, h = _dim_thumb(project)
    data = data_thumb(e, project.path_of(f"thumbs/{e['fundo']}").resolve().as_uri(), project.cfg)
    return render.html("thumb", data, 1, w, h, "#ffd400", estatico=True), w, h


def save_thumb(project, state):
    e = _clean_thumb(project, state)
    name = f"manual_{hashlib.sha1(json.dumps(e, sort_keys=True).encode()).hexdigest()[:8]}.png"
    w, h = _dim_thumb(project)
    from esteira.thumbs import compose_file
    compose_file(e, project.path_of(f"thumbs/{e['fundo']}"), project.path_of(f"thumbs/{name}"), project.cfg)
    ed = _edits(project)
    ed[name] = e
    project.save_json("thumbs/edicoes.json", ed)
    return name


def use_thumb(project, file, k):
    """Põe a thumb na vaga k (1..3) do teste A/B; a 1 também vira thumb.png."""
    origin = project.path_of(f"thumbs/{file}")
    if "/" in file or not origin.exists() or k not in (1, 2, 3):
        raise ValueError("thumb inválida")
    shutil.copy2(origin, project.path_of(f"thumb_{k}.png"))
    if k == 1:
        shutil.copy2(origin, project.path_of("thumb.png"))
    try:  # escolha da pessoa → veredito no dataset (candidata gerada pela etapa thumbs)
        from esteira.dataset import registry as R
        rg = R.last(f"thumb:{project.ep}", "thumb_compor", arquivo=file)
        if rg:
            R.evaluate(rg["id"], "escolhida", comentario=f"vaga {k}")
    except Exception:  # noqa: BLE001
        pass


def store_background(project, content, suffix):
    name = f"upload_{hashlib.sha1(content).hexdigest()[:8]}{suffix}"
    project.path_of("thumbs").mkdir(exist_ok=True)
    project.path_of(f"thumbs/{name}").write_bytes(content)
    return name


# ---------- Assistente de IA ----------

class BoxAi(BaseModel):
    texto: str = Field(max_length=220)
    x: float = Field(ge=0, le=100)
    y: float = Field(ge=0, le=100)
    w: float = Field(ge=5, le=100)
    tam: int = Field(ge=14, le=260)
    fonte: str = Field(pattern="^(Inter|Playfair|Mono)$")
    peso: int = Field(ge=300, le=900)
    cor: str = Field(pattern=r"^#[0-9a-fA-F]{6}$")
    fundo: str = Field(pattern="^(nenhum|solido|vidro|tarja|contorno)$")
    alinhar: str = Field(pattern="^(left|center|right)$")
    maiusculas: bool = False
    entrada: str = Field("subir", pattern="^(subir|fade|zoom|esquerda|revelar|nenhuma)$")
    atraso: float = Field(0.2, ge=0, le=20)


class Suggestion(BaseModel):
    dados_json: str = Field(description="objeto JSON com as mesmas chaves de estado.dados, valores novos")
    entrada: str = Field("padrao", pattern="^(padrao|nenhuma|fade|subir|zoom|deslizar|desfoque|revelar)$")
    saida: str = Field("padrao", pattern="^(padrao|nenhuma|fade|zoom|deslizar|descer)$")
    caixas: list[BoxAi] = Field([], max_length=8)
    explicacao: str = Field("", max_length=240)


FIXED = {"arquivo", "trecho", "pagina", "fundo"}  # a IA não troca PDF/trecho conferido nem o fundo da thumb


def _context(project, start, duration):
    speeches = []
    if start is not None and project.path_of("frases.json").exists():
        speeches = [f["texto"] for f in project.load_json("frases.json")
                 if f.get("ini") is not None and start - 6 <= f["ini"] <= start + duration + 4]
    rot = json.loads(project.path_of("roteiro.json").read_text()) if project.path_of("roteiro.json").exists() else {}
    sources = [f"{c.get('autores')} ({c.get('ano')}), {c.get('revista')}: \"{c.get('pt')}\"" for c in rot.get("citacoes", [])]
    return rot.get("titulo", ""), " ".join(speeches), sources


def _numbers(text):
    return set(re.findall(r"\d+(?:[.,]\d+)?", text))


def suggest(project, ep, state, request, engine="claude", kind="grafico"):
    """Devolve (estado_novo, explicacao, avisos) ou levanta ValueError."""
    from esteira.ai import claude, local
    thumb = kind == "thumb"
    if thumb:
        e = _clean_thumb(project, state)
        w, h = _dim_thumb(project)
        data = {k: v for k, v in e.items() if k not in ("caixas", "fundo")}
        title, speeches, sources = _context(project, None, 0)
        target = f"a YouTube thumbnail ({w}x{h}); giant text, few words, layout rosto_direita|rosto_esquerda|numero"
        boxes, effect = e.get("caixas") or [], {}
    else:
        e = _clean(state)
        w, h = _dim(project)
        data = {k: v for k, v in e["dados"].items() if k not in FIXED}
        title, speeches, sources = _context(project, e["inicio"], e["dur"])
        target = f"an animated graphic ({w}x{h}, template {e['modelo']}, {e['dur']}s, overlaid on the video)"
        boxes, effect = e["caixas"], e["efeito"]
    dossier = "\n".join([
        f"You edit {target} of the video \"{title}\" (channel {getattr(project, 'canal', '')}).",
        f"Editor's request (in Brazilian Portuguese): {request}",
        f"Current state: {json.dumps({'dados': data, 'efeito': effect, 'caixas': boxes}, ensure_ascii=False)}",
        f"Narration in this segment: {speeches or '-'}",
        "Script sources (the only study data that may appear):", *(sources or ["-"]),
        "Rules: every on-screen text in Brazilian Portuguese, short and strong; numbers, names and years only if "
        "they are in the narration, the sources or the state; *asterisks* mark the highlighted word; boxes "
        "(caixas): x, y, w in % of the frame (x, y = top-left corner), tam in px of the frame; do not cover the "
        "main content of the template; dados_json with the same keys as estado.dados; keep whatever the request "
        "did not ask to change."])
    from esteira.core import trace
    trace.node(f"editor:{ep}", "editor", request[:120])
    try:
        if engine == "local":
            r = local.ask(dossier, Suggestion, temperature=0.4, max_tokens=2500, operation="editor")
        else:
            r = claude.query(dossier, Suggestion, project.cfg, ep, f"editor: {request[:40]}")
    finally:
        trace.node(None, None)
    if not r:
        raise ValueError("a IA não respondeu (teto de custo do Claude ou falha do LLM local)")
    try:
        new = json.loads(r.dados_json)
    except ValueError:
        new = {}
    if not isinstance(new, dict):
        new = {}
    new = {k: v for k, v in new.items() if k in data}
    boxes_n = [dict(render.BOX, **c.model_dump()) for c in r.caixas]
    base = _numbers(" ".join([speeches, *sources, json.dumps(data, ensure_ascii=False), json.dumps(boxes, ensure_ascii=False)]))
    output_txt = json.dumps(new, ensure_ascii=False) + " ".join(c["texto"] for c in boxes_n)
    warnings = [f"o número {n} não aparece na fala nem nas fontes: confira" for n in sorted(_numbers(output_txt) - base)]
    if thumb:
        novo = dict(e, **new, caixas=boxes_n)
    else:
        novo = dict(e, dados=dict(e["dados"], **new), caixas=boxes_n, efeito={**effect, "entrada": r.entrada, "saida": r.saida})
    return novo, r.explicacao, warnings

