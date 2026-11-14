"""Etapa thumb: thumbnails agressivas com teste A/B.

1. LLM local: ~8 conceitos (emoção, gatilho, texto de 2–4 palavras que completa o título, cena de fundo).
2. RealVisXL na GPU (`.venv-img`): um fundo por conceito.
3. Modelo HTML `thumb` → PNG 1280×720 (texto gigante com contorno, cor de alerta, selo, seta).
4. Visão local: nota de impacto vendo a thumb no tamanho do celular (168×94 ampliado).
5. Claude: uma folha com as 6 melhores → escolhe 3 para o "Testar e comparar" do YouTube.
Saída: thumbs/*.png (todas), thumb_1..3.png e thumb.png (= thumb_1).
"""
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from pydantic import BaseModel, Field

from esteira.core import events
from esteira.curation import STYLES
from esteira.graphics import render
from esteira.ai import local
from esteira.project import ROOT

PY_IMG = ROOT / ".venv-img" / "bin" / "python"


class Concept(BaseModel):
    emocao: str = Field(max_length=20)
    gatilho: str = Field(max_length=120)
    texto: str = Field(max_length=40)
    destaque: str = Field(min_length=1, max_length=20)
    cena_en: str = Field(max_length=300)
    layout: str = Field(pattern="^(rosto_direita|rosto_esquerda|numero)$")
    seta: bool = False


class Concepts(BaseModel):
    conceitos: list[Concept] = Field(max_length=10)


class Impact(BaseModel):
    impacto: int = Field(ge=1, le=10)
    legivel: bool
    problema: str = Field("", max_length=80)


def _context(project):
    rot = json.loads(project.path_of("roteiro.json").read_text()) if project.path_of("roteiro.json").exists() else {}
    md = project.path_of("roteiro_original.md")
    promessa = ""
    if md.exists():
        m = re.search(r"\*\*Pergunta:\*\*(.+?)\n.*?\*\*Promessa:\*\*(.+?)\n", md.read_text(), re.S)
        promessa = " ".join(x.strip() for x in m.groups()) if m else ""
    text = project.script_path().read_text()
    speeches = [l for l in text.splitlines()[1:] if l.strip()]
    numbers = sorted(set(re.findall(r"\d[\d.,]*\s*(?:%|mil|milhão|milhões|bilhões)|R\$\s*[\d.,]+", text)))[:8]
    return {"titulo": rot.get("titulo") or text.splitlines()[0].lstrip("# "), "promessa": promessa or "-",
            "gancho": " ".join(speeches[:3])[:500].replace("*", ""), "numeros": ", ".join(numbers) or "nenhum"}


def _words(text, highlight):
    """Palavras em maiúsculas; a de destaque (ou o número, ou a última) vai na cor de alerta."""
    ps = text.upper().split()
    target = {w for w in highlight.upper().split()} & set(ps) or {next((w for w in ps if re.search(r"\d", w)), ps[-1])}
    return [{"t": p, "d": p in target} for p in ps]


def _valid(c, script):
    """Até 4 palavras (sem contar "R$") e todo número do texto presente no roteiro (nada de "R$ 400%")."""
    words = [w for w in c.texto.split() if w.upper() != "R$"]
    if len(words) > 4:
        return False
    rot = script.lower()
    for num, unit in re.findall(r"(\d[\d.,]*)\s*(%|mil\w*|milh\w*|bilh\w*|vezes|anos?)?", c.texto.lower()):
        # o número com a mesma unidade tem de estar no roteiro ("1,4 mil" ≠ "1,4 milhão")
        un = {"mil": r"mil\b", "%": "%"}.get(unit, re.escape(unit[:4]))
        if not re.search(re.escape(num) + (r"\s*" + un if unit else r"(?![\d,])"), rot):
            return False
    return not ("%" in c.texto and "R$" in c.texto.upper())


def data_thumb(e, background_uri, cfg):
    """Dados do modelo `thumb` a partir dos campos editáveis `e` (texto, destaque, layout, seta e, opcionais,
    selo, tamanho, cor_d, alerta, caixas). Usado pela etapa e pelo editor do painel."""
    t = cfg.get("thumb", {})
    words = _words(e["texto"], e.get("destaque") or "") if e.get("texto", "").strip() else []
    number = e["layout"] == "numero"
    n = len(words)
    size = e.get("tamanho") or (230 if number and n <= 2 else 150 if n <= 2 else 132 if n == 3 else 112)
    arrow_pos = ("left: 660px; top: 150px" if e["layout"] != "rosto_esquerda"
                else "right: 660px; top: 150px; transform: scaleX(-1)")
    return dict(fundo=background_uri, layout=e["layout"], palavras=words, tamanho=size,
                cor_d=e.get("cor_d") or t.get("cor_texto", "#ffd400"), alerta=e.get("alerta") or t.get("alerta", "#ff2d2d"),
                seta=bool(e.get("seta")) and not number, seta_pos=arrow_pos, selo=e.get("selo", ""),
                caixas=e.get("caixas") or [])


def compose_file(e, background, destination, cfg):
    """Campos editáveis `e` → `destino` (.png). Com o PhotoCraft (`[thumb] motor`, padrão), grava também o
    `.pcraft` em camadas ao lado do PNG, para edição manual."""
    from esteira import photocraft
    t = cfg.get("thumb", {})
    w, h = t.get("largura", 1280), t.get("altura", 720)
    data = data_thumb(e, Path(background).resolve().as_uri(), cfg)
    if t.get("motor", "photocraft") == "photocraft" and photocraft.available():
        photocraft.compose(data, Path(destination).with_suffix(".pcraft"), w, h)
    else:
        render.image("thumb", data, destination, w, h)
    return destination


def _compose(c, background, destination, cfg):
    return compose_file(c.model_dump(), background, destination, cfg)


def _generate_backgrounds(requests):
    if not PY_IMG.exists():
        raise SystemExit("geração de imagem não instalada (.venv-img); veja docs/PLANO.md")
    local.free_gpu()
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(requests, f)
    p = subprocess.Popen([str(PY_IMG), str(ROOT / "esteira/image/generate_sdxl.py"), f.name],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    n = 0
    for line in p.stdout:
        if line.startswith("{"):
            n += 1
            events.progress(n, len(requests), f"fundo {n} ({json.loads(line)['seg']}s)")
    if p.wait():
        raise RuntimeError(f"gerar_sdxl falhou: {p.stderr.read()[-600:]}")


def _evaluate(file, c, ctx):
    """Visão local vê a thumb pequena (como no feed do celular) e dá o impacto."""
    pequena = file.with_name(f".peq_{file.stem}.jpg")
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", file, "-vf",
                    "scale=168:94,scale=504:282:flags=neighbor", "-q:v", "3", "-update", "1", pequena], check=True)
    r = local.ask(
        f'This is a YouTube thumbnail seen at the size of the phone feed. Video title (in Brazilian Portuguese): '
        f'"{ctx["titulo"]}". Thumb text: "{c.texto}". From 1 to 10, how much does it make the person feel '
        f'{c.emocao} and need to click NOW (clear focal point, strong emotion, contrast)? Is the text readable at '
        f'this size? Respond in JSON: {{"impacto": 1-10, "legivel": true|false, "problema": "up to 10 words"}}',
        Impact, model=local.VISION, images=[pequena], max_tokens=100)
    pequena.unlink(missing_ok=True)
    return r


def _choose_with_claude(project, ranking, ctx):
    from esteira.ai import claude
    from esteira.media import sheet

    class ThumbChoice(BaseModel):
        chosen: list[int] = Field(min_length=1, max_length=3)
        reason: str

    top = ranking[:6]
    destination = project.path_of("thumbs/folha_escolha.jpg")
    sheet(project, [(r["arquivo"], None, str(k)) for k, r in enumerate(top)], destination, columns=3, w=512, h=288)
    script = project.script_path().read_text()

    def script_context(text):
        """Frase do roteiro onde está o número da thumb (para o Claude checar se a promessa é honesta)."""
        num = re.search(r"\d[\d.,]*", text)
        if not num:
            return ""
        sentence = next((f for f in re.split(r"(?<=[.!?])\s+", script) if num.group() in f), "")
        return f' | in the script: "{sentence[:200]}"'

    lines = "\n".join(f"{k}: text \"{r['conceito']['texto']}\", emotion {r['conceito']['emocao']}, "
                       f"trigger: {r['conceito']['gatilho']}{script_context(r['conceito']['texto'])}"
                       for k, r in enumerate(top))
    r = claude.query(
        f"Candidate thumbnails for the video \"{ctx['titulo']}\" (in Brazilian Portuguese; number in the corner). "
        f"Choose the 3 that most make the person stop scrolling and click RIGHT AWAY, with emotions/approaches "
        f"different from each other (for A/B testing), readable on a phone and honest with the content: reject any "
        f"that distorts the number or promises what the video does not say (compare with the script sentence). "
        f"Order them from best to worst.\n\n{lines}",
        ThumbChoice, project.cfg, project.ep, "thumb: escolher 3 de 6", image=destination)
    if not r:
        return top[:3]
    return [top[k] for k in r.escolhidas if 0 <= k < len(top)] or top[:3]


def _dataset(project, ctx, ranking, chosen):
    """Cada candidata vira registro `thumb_compor` (pendente: o veredito é da pessoa, ao pôr numa vaga A/B).
    A ordem do Claude e a nota da visão entram como métricas; nunca derruba a etapa."""
    try:
        from esteira import photocraft
        from esteira.dataset import registry as R
        from esteira.n1 import photocraft as N1
        order = [e["arquivo"].name for e in chosen]
        for x in ranking:
            name = x["arquivo"].name
            doc = photocraft.LAST.get(str(x["arquivo"]))
            R.write("thumb_compor", group=f"thumb:{project.ep}", origin="local:thumb_conceitos",
                     context={**ctx, "canal": getattr(project, "canal", "") or "", "fundo": x["fundo"],
                               "cena_en": x["conceito"].get("cena_en")},
                     output=doc.model_dump(mode="json") if doc else {"conceito": x["conceito"]},
                     versions={"n1": N1.VERSION if doc else None, "app": "photocraft"},
                     metricas={"nota_visao": x["nota"], "problema": x["problema"],
                               "ordem_claude": order.index(name) + 1 if name in order else None},
                     extra={"episodio": project.ep, "arquivo": name})
    except Exception as e:  # noqa: BLE001
        events.warning(f"dataset: thumbs de {project.ep} não gravadas ({e})")


def thumbs(project, n=8):
    if not project.cfg.get("thumb", {}).get("ativo", True):
        print("  thumbs desligadas neste formato ([thumb] ativo = false)")
        return
    for velho in project.path_of("thumbs").glob("thumb_*.png") if project.path_of("thumbs").exists() else []:
        velho.unlink()
    ctx = _context(project)
    channel = getattr(project, "canal", "") or ""
    script = project.script_path().read_text()
    prompt = local.prompt("thumb_concepts", canal=channel or "documentário",
                          estilo=STYLES.get(channel, "documentário dark"), n_pedidos=n + 4, **ctx)
    # o LLM às vezes ignora o limite de palavras: pede de novo até ter ao menos 3 válidos
    concepts, descartados, seen = [], 0, set()
    for attempt in range(3):
        warning = "" if not attempt else ("\n\nWARNING: in the previous answer almost every text had more than 4 "
                                          "words or numbers that are not in the script. Use AT MOST 4 words.")
        r = local.ask(prompt + warning, Concepts, temperature=0.8 + 0.1 * attempt, max_tokens=3000)
        for c in (r.conceitos if r else []):
            if c.texto.upper() in seen:
                continue
            seen.add(c.texto.upper())
            if _valid(c, script):
                concepts.append(c)
            else:
                descartados += 1
        if len(concepts) >= 3:
            break
    concepts = concepts[:n]
    if not concepts:
        raise SystemExit(f"o LLM local não gerou conceitos de thumbnail válidos em 3 tentativas "
                         f"({descartados} descartados: número fora do roteiro ou texto longo)")
    print(f"  {len(concepts)} conceitos" + (f" ({descartados} descartados: número fora do roteiro ou texto longo)"
                                             if descartados else "") + ": " + " | ".join(c.texto for c in concepts))

    folder = project.path_of("thumbs")
    folder.mkdir(exist_ok=True)
    style = ", cinematic photo, dramatic lighting, high contrast, shallow depth of field, 8k, sharp focus"
    backgrounds = [folder / f"fundo_{hashlib.sha1(c.cena_en.encode()).hexdigest()[:8]}.png" for c in concepts]
    requests = [{"prompt": c.cena_en + style, "semente": 1000 + k, "saida": str(f)}
               for k, (c, f) in enumerate(zip(concepts, backgrounds)) if not f.exists()]
    if requests:
        _generate_backgrounds(requests)

    ranking = []
    for k, c in enumerate(concepts):
        file = _compose(c, backgrounds[k], folder / f"thumb_{k}.png", project.cfg)
        av = _evaluate(file, c, ctx)
        note = (av.impacto if av else 5) - (3 if av and not av.legivel else 0)
        ranking.append({"arquivo": file, "nota": note, "conceito": c.model_dump(), "fundo": backgrounds[k].name,
                        "problema": av.problema if av else ""})
        events.debug(f"thumb {k}: {c.texto}", nota=note, problema=av.problema if av else "")
    ranking.sort(key=lambda x: -x["nota"])
    chosen = _choose_with_claude(project, ranking, ctx)
    for k, e in enumerate(chosen, 1):
        shutil.copy2(e["arquivo"], project.path_of(f"thumb_{k}.png"))
    shutil.copy2(chosen[0]["arquivo"], project.path_of("thumb.png"))
    project.save_json("thumbs/ranking.json", [dict(x, arquivo=str(x["arquivo"].name)) for x in ranking])
    _dataset(project, ctx, ranking, chosen)
    print(f"  thumb_1..{len(chosen)}.png para o teste A/B: " + " | ".join(e["conceito"]["texto"] for e in chosen))
