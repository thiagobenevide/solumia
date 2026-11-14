"""Quadros da prévia do editor renderizados no servidor (para o app Flutter, que não embute HTML).

Um Chromium (Playwright) fica aberto numa thread própria — a API síncrona do Playwright só pode ser usada
na thread que a criou — e atende pedidos por uma fila: abre o HTML do modelo (o mesmo que vira vídeo/PNG),
congela no instante `t` com `seek` e devolve o PNG. Com `device_scale_factor` 0.5 o layout continua no
tamanho do vídeo e o quadro sai com metade da resolução (~50 ms por quadro), o bastante para a prévia.
"""
import hashlib
import queue
import tempfile
import threading
from concurrent.futures import Future
from pathlib import Path

from esteira.graphics import render

_requests: queue.Queue = queue.Queue()
_start = threading.Lock()
_thread = None
_TMP = Path(tempfile.mkdtemp(prefix="quadros_"))


def _serve():
    from playwright.sync_api import sync_playwright
    with sync_playwright() as pw:
        nav = pw.chromium.launch()
        pages = {}  # (w, h) → [página, hash do HTML aberto]
        while True:
            html, w, h, t, transparente, fut = _requests.get()
            try:
                if (w, h) not in pages:
                    pg = nav.new_page(viewport={"width": w, "height": h}, device_scale_factor=0.5)
                    pg.add_init_script(render._SEEK)
                    pages[w, h] = [pg, None]
                pg, opened = pages[w, h]
                key = hashlib.sha1(html.encode()).hexdigest()
                if key != opened:
                    file = _TMP / f"{key}.html"
                    file.write_text(html)
                    pg.goto(file.as_uri())
                    pg.evaluate("document.fonts.ready")
                    pages[w, h][1] = key
                pg.evaluate(f"window.seek && seek({float(t)})")
                fut.set_result(pg.screenshot(omit_background=transparente, type="png"))
            except Exception as e:  # o pedido falha; o navegador continua servindo os próximos
                fut.set_exception(e)


def frame(html, w, h, t=0.0, transparente=True, espera=30):
    """PNG do HTML no instante `t` (segundos)."""
    global _thread
    with _start:
        if _thread is None or not _thread.is_alive():
            _thread = threading.Thread(target=_serve, daemon=True, name="quadros")
            _thread.start()
    fut = Future()
    _requests.put((html, w, h, t, transparente, fut))
    return fut.result(timeout=espera)
