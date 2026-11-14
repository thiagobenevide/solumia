"""Acha um trecho num PDF e gera a imagem da página com os retângulos do trecho (para a citação em tela)."""
import re
import unicodedata
from difflib import SequenceMatcher
from pathlib import Path

import pymupdf

DPI = 200


def _norm(p):
    p = unicodedata.normalize("NFKD", p.lower())
    p = re.sub(r"[^\w%]", "", "".join(c for c in p if not unicodedata.combining(c)))
    return re.sub(r"(?<=[a-z]{2})\d+$", "", p)  # nota de rodapé colada (cash14–16 → cash)


def _best_window(target, words):
    """Janela de palavras da página mais parecida com o trecho: (nota, i, j)."""
    n, toks = len(target), [_norm(w[4]) for w in words]
    best = (0.0, 0, 0)
    for i in range(len(toks)):
        if toks[i] not in target[:4]:
            continue
        for m in (n - 2, n - 1, n, n + 1, n + 2):
            if m < 1 or i + m > len(toks):
                continue
            note = SequenceMatcher(None, target, toks[i:i + m], autojunk=False).ratio()
            if note > best[0]:
                best = (note, i, i + m)
    return best


def _lines(words):
    """Um retângulo por linha (bloco, linha) das palavras do trecho."""
    by_line = {}
    for w in words:
        r = by_line.setdefault((w[5], w[6]), [w[0], w[1], w[2], w[3]])
        r[0], r[1], r[2], r[3] = min(r[0], w[0]), min(r[1], w[1]), max(r[2], w[2]), max(r[3], w[3])
    return list(by_line.values())


def locate(file, segment, page=None, minimum=0.75):
    """{pagina, nota, rects (pt)} do trecho; tolera hifenização, quebras e pequenas diferenças."""
    target = [_norm(p) for p in segment.split() if _norm(p)]
    doc = pymupdf.open(file)
    pages = [page] if page is not None else range(len(doc))
    found = None
    for k in pages:
        words = doc[k].get_text("words")
        note, i, j = _best_window(target, words)
        if note >= minimum and (not found or note > found["nota"]):
            found = {"pagina": k, "nota": round(note, 3), "rects": _lines(words[i:j])}
            if note > 0.97:
                break
    return found


def metadata(file):
    m = pymupdf.open(file).metadata or {}
    return {"titulo": m.get("title") or "", "autores": m.get("author") or ""}


def image_of_page(file, page, destination, rects):
    """Salva a página em PNG e devolve os retângulos convertidos para pixels da imagem."""
    pg = pymupdf.open(file)[page]
    pix = pg.get_pixmap(dpi=DPI)
    Path(destination).parent.mkdir(parents=True, exist_ok=True)
    pix.save(destination)
    k = DPI / 72
    return {"img": Path(destination).resolve().as_uri(), "img_w": pix.width, "img_h": pix.height,
            "rects": [[round(v * k) for v in r] for r in rects]}
