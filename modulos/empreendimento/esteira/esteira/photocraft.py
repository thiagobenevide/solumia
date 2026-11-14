"""Thumbnail no PhotoCraft: os dados do modelo `thumb` (thumbs.data_thumb) viram um documento `.pcraft` com camadas
editáveis (Fundo como objeto inteligente, ajustes de contraste e saturação, Vinheta, Título com contorno e sombra,
Selo, Seta e as caixas de texto) e o PNG é exportado dele.

Os dados viram uma composição N1 (`esteira/n1/photocraft.py`), cujo executor faz as duas passagens pelo
`photocraft-cli run`: a primeira cria as camadas; a segunda, já sabendo o tamanho real do texto (type.info),
centraliza o título e põe selo e fundos das caixas no lugar. Se o `.pcraft` for salvo à mão (data mais
nova que a do PNG), `exportar` refaz só o PNG a partir dele.
"""
import json
import shutil
import subprocess
from pathlib import Path

from esteira.core.display import open_program

CLI = "photocraft-cli"


def available():
    return shutil.which(CLI) is not None


def _run(origin, steps, destination):
    """passos: [(comando, params)]. Devolve os resultados (um dict por comando)."""
    cmd = [CLI, "run", *(["--new", json.dumps(origin)] if isinstance(origin, dict) else [str(origin)])]
    for c, p in steps:
        cmd += ["--cmd", c, "--params", json.dumps(p, ensure_ascii=False)]
    cmd += ["--out", str(destination)]
    if str(origin) == str(destination):  # 2ª passagem reescreve o .pcraft: o CLI exige pedir
        cmd.append("--in-place")
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if r.returncode or "error:" in r.stderr:
        raise RuntimeError(f"PhotoCraft: {(r.stderr or r.stdout).strip()[-400:]}")
    return [json.loads(l)["result"] for l in r.stdout.splitlines() if l.startswith("{")]


def _size_image(file):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=width,height", "-of", "csv=p=0", str(file)],
                       capture_output=True, text=True, check=True)
    w, h = r.stdout.strip().split(",")[:2]
    return int(w), int(h)


LAST: dict[str, object] = {}  # destino → composição N1 usada (o dataset das thumbs grava)


def compose(d, destination, w=1280, h=720):
    """`d`: dados de `thumbs.data_thumb` (com `fundo` como caminho ou file://) → N1 → `destino` (.pcraft) + PNG."""
    from esteira.n1 import photocraft as N1
    doc = N1.of_data_thumb(d, w, h)
    colors = {"texto": "#ffffff", "destaque": d["cor_d"], "alerta": d["alerta"], "preto": "#000000"}
    N1.Executor(_run, {"fundo": d["fundo"]}, colors, _size_image).apply_doc(doc, Path(destination))
    LAST[str(Path(destination).with_suffix(".png"))] = doc
    return export(destination)


def export(pcraft, png=None):
    """PNG a partir do `.pcraft` (o que o painel e o YouTube usam)."""
    png = Path(png or Path(pcraft).with_suffix(".png"))
    r = subprocess.run([CLI, "convert", str(pcraft), str(png)], capture_output=True, text=True, timeout=120)
    if r.returncode:
        raise RuntimeError(f"PhotoCraft: {r.stderr.strip()[-300:]}")
    return png


def edited(pcraft):
    """O `.pcraft` foi salvo à mão depois do último PNG?"""
    pcraft = Path(pcraft)
    png = pcraft.with_suffix(".png")
    return pcraft.exists() and (not png.exists() or pcraft.stat().st_mtime > png.stat().st_mtime + 1)


def open_file(pcraft):
    open_program("photocraft", str(pcraft))
