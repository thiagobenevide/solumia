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


def disponivel():
    return shutil.which(CLI) is not None


def _rodar(cmd, rotulo=None, timeout=600):
    """Roda o effectcraft-cli; com `rotulo`, lê as linhas `progress <feito> <total> …` e alimenta a barra do Monitor."""
    if not rotulo:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if r.returncode:
            raise RuntimeError(f"EffectCraft: {(r.stderr or r.stdout).strip()[-400:]}")
        return r.stdout
    p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    erros = []
    for linha in p.stderr:
        m = re.match(r"progress (\d+) (\d+) ([\d.]+) ([\d.]+|-)", linha)
        if m:
            trace.task("render", rotulo, int(m[1]), int(m[2]), "quadros")
        else:
            erros.append(linha)
    p.wait(timeout)
    trace.end_task("render")
    if p.returncode:
        raise RuntimeError(f"EffectCraft: {''.join(erros).strip()[-400:]}")


def construir(modelo, dados, segundos, destino, w=1920, h=1080, cor="#ffd400", fps=30):
    """Cria `destino` (.ecproj) com as comps "Conteúdo" e "Peça". `dados` como em `render.html` (com efeito e caixas)."""
    from esteira.graficos.render import CAIXA
    dados = dict(dados)
    efeito = dados.pop("efeito", None) or {}
    caixas = [dict(CAIXA, **c) for c in dados.pop("caixas", None) or []]
    entrada = {"modelo": modelo, "dados": dados, "dur": segundos, "w": w, "h": h, "cor": cor, "fps": fps,
               "efeito": efeito, "caixas": caixas}
    destino = Path(destino)
    with tempfile.TemporaryDirectory(prefix="ec_") as tmp:
        script = Path(tmp) / "peca.jsx"
        script.write_text(f"var DADOS = {json.dumps(entrada, ensure_ascii=False)};\n" + JSX.read_text())
        saida = _rodar([CLI, "script", str(script), "--save-as", str(destino)])
    if "ok " not in saida:
        raise RuntimeError(f"EffectCraft não montou a peça: {saida.strip()[-300:]}")
    return destino


def renderizar(ecproj, destino, previa=None, w=1920, h=1080):
    """`ecproj` → `destino` (.mov ProRes 4444 com alfa). `previa`: instante (s) salvo em PNG sobre fundo cinza."""
    destino = Path(destino)
    _rodar([CLI, "render", "--project", str(ecproj), "--comp", "Peça", "--out", str(destino), "--format", "prores",
            "--prores", "4444", "--channels", "rgba", "--quality", "best", "--progress"],
           rotulo=f"EffectCraft: {destino.name}")
    if previa is not None:
        quadro(ecproj, previa, destino.with_suffix(".png"), w, h)
    return destino


def quadro(ecproj, t, destino, w=1920, h=1080, fundo="0x2a2d33", max_lado=None):
    """Um quadro da peça em PNG (sobre cinza, como a prévia do painel)."""
    with tempfile.TemporaryDirectory(prefix="ecq_") as tmp:
        png = Path(tmp) / "q.png"
        cmd = [CLI, "render-frame", "--project", str(ecproj), "--comp", "Peça", "--time", f"{t:.3f}",
               "--out", str(png), "--transparent"]
        if max_lado:
            cmd += ["--max-side", str(max_lado)]
        _rodar(cmd)
        subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", str(png), "-f", "lavfi",
                        "-i", f"color=c={fundo}:s=16x16", "-filter_complex",
                        "[1][0]scale2ref[f][q];[f][q]overlay", "-frames:v", "1", str(destino)], check=True)
    return Path(destino)


def abrir(ecproj):
    """Abre o projeto no EffectCraft (janela), sem prender o processo que chamou."""
    open_program("effectcraft", str(ecproj))
