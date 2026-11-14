"""Gráficos no EffectCraft: cada peça do graficos.json vira um projeto `.ecproj` editável (camadas com nomes
em português, keyframes e expressões à vista) e é renderizada pela engine em ProRes 4444 com alfa.

`effectcraft.jsx` monta as comps a partir dos mesmos dados dos modelos HTML (`pecas.py`). O `.ecproj` fica ao lado
do `.mov` em `graficos/`; se ele for salvo à mão no EffectCraft (data mais nova que a do `.mov`), a etapa
renderiza a versão editada e não o recria (ver `plano.renderizar`).
"""
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from esteira.core import trace
from esteira.core.display import open_program

JSX = Path(__file__).with_name("effectcraft.jsx")
CLI = "effectcraft-cli"


def available():
    return shutil.which(CLI) is not None


def _run(cmd, rotulo=None, timeout=600):
    """Roda o effectcraft-cli; com `rotulo`, lê as linhas `progress <feito> <total> …` e alimenta a barra do Monitor."""
    if not rotulo:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if r.returncode:
            raise RuntimeError(f"EffectCraft: {(r.stderr or r.stdout).strip()[-400:]}")
        return r.stdout
    p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    errors = []
    for line in p.stderr:
        m = re.match(r"progress (\d+) (\d+) ([\d.]+) ([\d.]+|-)", line)
        if m:
            trace.task("render", rotulo, int(m[1]), int(m[2]), "quadros")
        else:
            errors.append(line)
    p.wait(timeout)
    trace.end_task("render")
    if p.returncode:
        raise RuntimeError(f"EffectCraft: {''.join(errors).strip()[-400:]}")


def build(model, dados, segundos, destino, w=1920, h=1080, cor="#ffd400", fps=30):
    """Cria `destino` (.ecproj) com as comps "Conteúdo" e "Peça". `dados` como em `render.html` (com efeito e caixas)."""
    from esteira.graphics.render import BOX
    dados = dict(dados)
    effect = dados.pop("efeito", None) or {}
    boxes = [dict(BOX, **c) for c in dados.pop("caixas", None) or []]
    entry = {"modelo": model, "dados": dados, "dur": segundos, "w": w, "h": h, "cor": cor, "fps": fps,
               "efeito": effect, "caixas": boxes}
    destino = Path(destino)
    with tempfile.TemporaryDirectory(prefix="ec_") as tmp:
        script = Path(tmp) / "peca.jsx"
        script.write_text(f"var DADOS = {json.dumps(entry, ensure_ascii=False)};\n" + JSX.read_text())
        output = _run([CLI, "script", str(script), "--save-as", str(destino)])
    if "ok " not in output:
        raise RuntimeError(f"EffectCraft não montou a peça: {output.strip()[-300:]}")
    return destino


def render(ecproj, destino, preview=None, w=1920, h=1080):
    """`ecproj` → `destino` (.mov ProRes 4444 com alfa). `previa`: instante (s) salvo em PNG sobre fundo cinza."""
    destino = Path(destino)
    _run([CLI, "render", "--project", str(ecproj), "--comp", "Peça", "--out", str(destino), "--format", "prores",
            "--prores", "4444", "--channels", "rgba", "--quality", "best", "--progress"],
           rotulo=f"EffectCraft: {destino.name}")
    if preview is not None:
        frame(ecproj, preview, destino.with_suffix(".png"), w, h)
    return destino


def frame(ecproj, t, destino, w=1920, h=1080, fundo="0x2a2d33", max_side=None):
    """Um quadro da peça em PNG (sobre cinza, como a prévia do painel)."""
    with tempfile.TemporaryDirectory(prefix="ecq_") as tmp:
        png = Path(tmp) / "q.png"
        cmd = [CLI, "render-frame", "--project", str(ecproj), "--comp", "Peça", "--time", f"{t:.3f}",
               "--out", str(png), "--transparent"]
        if max_side:
            cmd += ["--max-side", str(max_side)]
        _run(cmd)
        subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", str(png), "-f", "lavfi",
                        "-i", f"color=c={fundo}:s=16x16", "-filter_complex",
                        "[1][0]scale2ref[f][q];[f][q]overlay", "-frames:v", "1", str(destino)], check=True)
    return Path(destino)


def open_file(ecproj):
    """Abre o projeto no EffectCraft (janela), sem prender o processo que chamou."""
    open_program("effectcraft", str(ecproj))
