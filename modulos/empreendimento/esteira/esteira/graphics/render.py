"""Gráficos animados: modelo HTML/CSS → vídeo ProRes 4444 com transparência.

Cada modelo em `modelos/` é um HTML (Jinja2) com animações CSS. O Chromium (Playwright) renderiza quadro a
quadro: `seek(t)` congela todas as animações no instante t, então o resultado é determinístico e não
depende da velocidade da máquina. Várias páginas em paralelo dividem os quadros.
"""
import re
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from jinja2 import Environment, FileSystemLoader
from markupsafe import Markup, escape

from esteira.core import trace

ROOT = Path(__file__).parent
_jinja = Environment(loader=FileSystemLoader(ROOT / "modelos"), autoescape=True)

# Congela animações CSS e ganchos JS (contadores etc.) no instante t, em segundos.
_SEEK = """
window.__ganchos = window.__ganchos || [];
window.seek = (t) => {
  for (const a of document.getAnimations()) { a.pause(); a.currentTime = t * 1000; }
  for (const g of window.__ganchos) g(t);
};
"""


# Caixa de texto livre: valores que faltarem vêm daqui (o editor do painel usa os mesmos).
BOX = dict(texto="", x=8, y=70, w=60, tam=64, fonte="Inter", peso=800, cor="#f4f1ea", cor_d="", fundo="nenhum",
             cor_fundo="#0a1122", alinhar="left", maiusculas=False, entrada="subir", atraso=0.2, vel=0.6)


def _mark(text):
    """*destaque* → cor de destaque; quebra de linha preservada."""
    return Markup(re.sub(r"\*(.+?)\*", r'<span class="d">\1</span>', str(escape(text))).replace("\n", "<br>"))


def html(model, data, seconds, w=1920, h=1080, color="#ffd400", estatico=False):
    """`dados` pode trazer "efeito" ({entrada, saida, vel}) e "caixas" (lista de caixas de texto livres)."""
    data = dict(data)
    effect = data.pop("efeito", None) or {}
    boxes = [dict(BOX, **c, html=_mark(c.get("texto", ""))) for c in data.pop("caixas", None) or []]
    return _jinja.get_template(f"{model}.html").render(
        **data, dur=seconds, w=w, h=h, vertical=h > w, cor=color, raiz=ROOT.as_uri(), efeito=effect,
        caixas=boxes, estatico=estatico)


def preview(model, data, seconds, w, h, color, swaps, estatico=False):
    """HTML para o editor do painel: com `seek` e caminhos file:// trocados por URLs do servidor."""
    s = html(model, data, seconds, w, h, color, estatico).replace("<head>", f"<head><script>{_SEEK}</script>", 1)
    for de, replacement in swaps.items():
        s = s.replace(de, replacement)
    return s


def _frames(page_html, indexes, fps, w, h, folder, done=None, total=0, label=""):
    from playwright.sync_api import sync_playwright
    with sync_playwright() as pw:
        nav = pw.chromium.launch()
        pg = nav.new_page(viewport={"width": w, "height": h})
        pg.add_init_script(_SEEK)
        pg.goto(page_html.as_uri())
        pg.evaluate("document.fonts.ready")
        for i in indexes:
            pg.evaluate(f"seek({i / fps})")
            pg.screenshot(path=str(folder / f"q{i:05d}.png"), omit_background=True)
            if done is not None:
                done[0] += 1
                trace.task("render", label, done[0], total, "quadros")
        nav.close()


def render(model, dados, segundos, destino, fps=30, w=1920, h=1080, cor="#ffd400", paralelo=4,
               preview=None):
    """Gera `destino` (.mov ProRes 4444 com alfa). `previa`: instante (s) salvo em PNG sobre fundo cinza."""
    destino = Path(destino)
    tmp = Path(tempfile.mkdtemp(prefix="graf_"))
    try:
        page = tmp / "pagina.html"
        page.write_text(html(model, dados, segundos, w, h, cor))
        n = round(segundos * fps)
        parts = [range(k, n, paralelo) for k in range(paralelo)]
        done, label = [0], f"quadros de {destino.name} ({paralelo} abas do Chromium)"
        with ThreadPoolExecutor(paralelo) as ex:
            list(ex.map(lambda r: _frames(page, r, fps, w, h, tmp, done, n, label), parts))
        trace.task("render", f"ffmpeg: {n} PNG → ProRes 4444 com alfa", 0, None)
        subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-framerate", str(fps),
                        "-i", tmp / "q%05d.png", "-c:v", "prores_ks", "-profile:v", "4444",
                        "-pix_fmt", "yuva444p10le", "-vendor", "apl0", destino], check=True)
        if preview is not None:
            q = tmp / f"q{min(round(preview * fps), n - 1):05d}.png"
            subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-f", "lavfi",
                            "-i", f"color=c=0x2a2d33:s={w}x{h}", "-i", q, "-filter_complex",
                            "overlay", "-frames:v", "1", destino.with_suffix(".png")], check=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        trace.end_task("render")
    return destino


def image(model, data, destination, w=1280, h=720):
    """Um quadro só (thumbnail): modelo HTML → PNG."""
    from playwright.sync_api import sync_playwright
    tmp = Path(tempfile.mkdtemp(prefix="img_"))
    try:
        page = tmp / "pagina.html"
        page.write_text(html(model, data, 1, w, h, estatico=True))
        with sync_playwright() as pw:
            nav = pw.chromium.launch()
            pg = nav.new_page(viewport={"width": w, "height": h})
            pg.goto(page.as_uri())
            pg.evaluate("document.fonts.ready")
            pg.wait_for_timeout(150)
            pg.screenshot(path=str(destination))
            nav.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return destination
