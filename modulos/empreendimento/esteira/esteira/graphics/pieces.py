"""Monta os dados de cada modelo gráfico. Cada função devolve (modelo, dados) para `render.render`."""
import re

from esteira.graphics import pdf as P

# Janela do documento e ficha na citação (px): à direita no 1920x1080, embaixo no 1080x1920.
GEOMETRY = {False: dict(jx=110, jy=110, jw=1000, jh=860, fx=1190, fy=150, fw=640),
             True: dict(jx=60, jy=250, jw=960, jh=760, fx=60, fy=1070, fw=900)}


READING = 3.0  # palavras/s lidas na tela: o trecho original e a tradução ficam o tempo de serem lidos


def quote(arquivo, trecho, destination_img, titulo="", autores="", revista="", year="", citacao="", pagina=None,
            rotulo="Estudo", vertical=False, link=True):
    """Página do PDF aproximando até `trecho` (texto como está no PDF); `citacao` é o que aparece na ficha
    (ex.: a tradução do trecho). Devolve None se o trecho não estiver no PDF.

    Ritmo (lento, para ler): a página entra, a câmera aproxima devagar até o trecho (1,0 → 4,2 s), o marca-texto
    passa linha a linha, o trecho original aparece na ficha e, depois do tempo de lê-lo, a tradução. Autor e
    "link na descrição" ficam visíveis o tempo todo."""
    found = P.locate(arquivo, trecho, pagina)
    if not found:
        return None
    img = P.image_of_page(arquivo, found["pagina"], destination_img, found["rects"])
    iw, ih, rects = img["img_w"], img["img_h"], img["rects"]
    g = GEOMETRY[vertical]
    JW, JH = g["jw"], g["jh"]
    # Câmera: começa com a página inteira na janela e termina com o trecho ocupando ~86% da largura.
    s0 = min(JW / iw, JH / ih) * 0.94
    x0, y0 = min(r[0] for r in rects), min(r[1] for r in rects)
    x1, y1 = max(r[2] for r in rects), max(r[3] for r in rects)
    s1 = min(0.86 * JW / (x1 - x0), 0.55 * JH / (y1 - y0), s0 * 4.5)
    s1 = max(s1, s0 * 1.6)
    meta = P.metadata(arquivo)
    return "citacao", dict(
        img, **g,
        s0=round(s0, 4), tx0=round((JW - iw * s0) / 2, 1), ty0=round((JH - ih * s0) / 2, 1),
        s1=round(s1, 4), tx1=round(JW / 2 - (x0 + x1) / 2 * s1, 1), ty1=round(JH / 2 - (y0 + y1) / 2 * s1, 1),
        cam=1.0, cam_dur=3.2, t_marca=4.4, passo_marca=0.55,
        t_pt=round(4.4 + 0.55 * len(rects) + 0.6 + len(trecho.split()) / READING * 0.6, 2) if citacao else None,
        rotulo=f"{rotulo} · {year}" if year else rotulo, en=trecho if citacao else "",
        titulo=titulo or meta["titulo"], autores=autores or meta["autores"], revista=revista, link=link,
        citacao=citacao, pagina=found["pagina"] + 1, nota=found["nota"])


def number(texto, legenda="", fonte="", rotulo=""):
    """`texto` como falado/escrito: "97,1%", "R$ 1.200", "1,4 milhão". Legenda aceita *destaque*."""
    m = re.match(r"\s*([^\d\-]*)(-?[\d.,]+)\s*(.*)", texto)
    prefix, num, suffix = m.groups()
    whole, _, dec = num.replace(".", "").partition(",")
    value = float(f"{whole}.{dec or 0}")
    return "numero", dict(prefixo=prefix.strip() + (" " if prefix.strip() else ""), valor=value,
                          casas=len(dec), sufixo=suffix.strip(), rotulo=rotulo, fonte=fonte,
                          legenda=re.sub(r"\*(.+?)\*", r"<b>\1</b>", _escape(legenda)))


def sentence(texto, posicao="baixo", alinhar="centro", tamanho=None):
    """Texto cinético; palavras entre *asteriscos* ficam na cor de destaque."""
    words, inside = [], False
    for t in texto.split():
        start, end = t.startswith("*"), t.endswith("*")
        inside = inside or start
        words.append({"t": t.strip("*"), "d": inside})
        inside = inside and not end
    n = len(words)
    return "frase", dict(palavras=words, posicao=posicao, alinhar=alinhar,
                         tamanho=tamanho or (120 if n <= 4 else 96 if n <= 8 else 76),
                         passo=min(0.12, 1.2 / max(n, 1)))


def font(linha1, linha2="", rotulo="Fonte", link=True):
    return "fonte", dict(linha1=linha1, linha2=linha2, rotulo=rotulo, link=link)


def _escape(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def chapter(nome, rotulo="", sub=""):
    return "capitulo", dict(nome=nome, rotulo=rotulo, sub=sub)


def listing(itens, titulo="", rotulo="", foco=None, tempos=None):
    """itens: [{titulo, valor?, detalhe?}] (até 4); `foco`: índice do item destacado. `tempos`: s desde o início
    da peça em que cada cartão entra (o valor dele sendo falado); sem eles, entram em sequência fixa."""
    itens = [dict(it, foco=(k == foco)) for k, it in enumerate(itens[:4])]
    step = 0.45 if len(itens) <= 3 else 0.35
    tempos = list(tempos or [])[:len(itens)] or [0.45]
    while len(tempos) < len(itens):  # itens sem tempo: logo depois do anterior
        tempos.append(round(tempos[-1] + step, 2))
    return "lista", dict(itens=itens, titulo=titulo, rotulo=rotulo, passo=step, tempos=tempos)


def comparison(nome_a, itens_a, nome_b, itens_b, rotulo_a="", rotulo_b=""):
    return "comparacao", dict(nome_a=nome_a, itens_a=itens_a[:3], nome_b=nome_b, itens_b=itens_b[:3],
                              rotulo_a=rotulo_a, rotulo_b=rotulo_b)


def boxes(veu="nenhum"):
    """Peça feita no editor: só as caixas de texto (vêm em "caixas"), com véu "nenhum|baixo|esquerda|total"."""
    return "caixas", dict(veu=veu)
