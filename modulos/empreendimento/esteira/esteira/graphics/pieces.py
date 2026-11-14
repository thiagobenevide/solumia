"""Monta os dados de cada modelo gráfico. Cada função devolve (modelo, dados) para `render.renderizar`."""
import re

from esteira.graphics import pdf as P

# Janela do documento e ficha na citação (px): à direita no 1920x1080, embaixo no 1080x1920.
GEOMETRIA = {False: dict(jx=110, jy=110, jw=1000, jh=860, fx=1190, fy=150, fw=640),
             True: dict(jx=60, jy=250, jw=960, jh=760, fx=60, fy=1070, fw=900)}


LEITURA = 3.0  # palavras/s lidas na tela: o trecho original e a tradução ficam o tempo de serem lidos


def citacao(arquivo, trecho, destino_img, titulo="", autores="", revista="", ano="", citacao="", pagina=None,
            rotulo="Estudo", vertical=False, link=True):
    """Página do PDF aproximando até `trecho` (texto como está no PDF); `citacao` é o que aparece na ficha
    (ex.: a tradução do trecho). Devolve None se o trecho não estiver no PDF.

    Ritmo (lento, para ler): a página entra, a câmera aproxima devagar até o trecho (1,0 → 4,2 s), o marca-texto
    passa linha a linha, o trecho original aparece na ficha e, depois do tempo de lê-lo, a tradução. Autor e
    "link na descrição" ficam visíveis o tempo todo."""
    achado = P.localizar(arquivo, trecho, pagina)
    if not achado:
        return None
    img = P.imagem_da_pagina(arquivo, achado["pagina"], destino_img, achado["rects"])
    iw, ih, rects = img["img_w"], img["img_h"], img["rects"]
    g = GEOMETRIA[vertical]
    JW, JH = g["jw"], g["jh"]
    # Câmera: começa com a página inteira na janela e termina com o trecho ocupando ~86% da largura.
    s0 = min(JW / iw, JH / ih) * 0.94
    x0, y0 = min(r[0] for r in rects), min(r[1] for r in rects)
    x1, y1 = max(r[2] for r in rects), max(r[3] for r in rects)
    s1 = min(0.86 * JW / (x1 - x0), 0.55 * JH / (y1 - y0), s0 * 4.5)
    s1 = max(s1, s0 * 1.6)
    meta = P.metadados(arquivo)
    return "citacao", dict(
        img, **g,
        s0=round(s0, 4), tx0=round((JW - iw * s0) / 2, 1), ty0=round((JH - ih * s0) / 2, 1),
        s1=round(s1, 4), tx1=round(JW / 2 - (x0 + x1) / 2 * s1, 1), ty1=round(JH / 2 - (y0 + y1) / 2 * s1, 1),
        cam=1.0, cam_dur=3.2, t_marca=4.4, passo_marca=0.55,
        t_pt=round(4.4 + 0.55 * len(rects) + 0.6 + len(trecho.split()) / LEITURA * 0.6, 2) if citacao else None,
        rotulo=f"{rotulo} · {ano}" if ano else rotulo, en=trecho if citacao else "",
        titulo=titulo or meta["titulo"], autores=autores or meta["autores"], revista=revista, link=link,
        citacao=citacao, pagina=achado["pagina"] + 1, nota=achado["nota"])


def numero(texto, legenda="", fonte="", rotulo=""):
    """`texto` como falado/escrito: "97,1%", "R$ 1.200", "1,4 milhão". Legenda aceita *destaque*."""
    m = re.match(r"\s*([^\d\-]*)(-?[\d.,]+)\s*(.*)", texto)
    prefixo, num, sufixo = m.groups()
    inteiro, _, dec = num.replace(".", "").partition(",")
    valor = float(f"{inteiro}.{dec or 0}")
    return "numero", dict(prefixo=prefixo.strip() + (" " if prefixo.strip() else ""), valor=valor,
                          casas=len(dec), sufixo=sufixo.strip(), rotulo=rotulo, fonte=fonte,
                          legenda=re.sub(r"\*(.+?)\*", r"<b>\1</b>", _escapar(legenda)))


def frase(texto, posicao="baixo", alinhar="centro", tamanho=None):
    """Texto cinético; palavras entre *asteriscos* ficam na cor de destaque."""
    palavras, dentro = [], False
    for t in texto.split():
        ini, fim = t.startswith("*"), t.endswith("*")
        dentro = dentro or ini
        palavras.append({"t": t.strip("*"), "d": dentro})
        dentro = dentro and not fim
    n = len(palavras)
    return "frase", dict(palavras=palavras, posicao=posicao, alinhar=alinhar,
                         tamanho=tamanho or (120 if n <= 4 else 96 if n <= 8 else 76),
                         passo=min(0.12, 1.2 / max(n, 1)))


def fonte(linha1, linha2="", rotulo="Fonte", link=True):
    return "fonte", dict(linha1=linha1, linha2=linha2, rotulo=rotulo, link=link)


def _escapar(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def capitulo(nome, rotulo="", sub=""):
    return "capitulo", dict(nome=nome, rotulo=rotulo, sub=sub)


def lista(itens, titulo="", rotulo="", foco=None, tempos=None):
    """itens: [{titulo, valor?, detalhe?}] (até 4); `foco`: índice do item destacado. `tempos`: s desde o início
    da peça em que cada cartão entra (o valor dele sendo falado); sem eles, entram em sequência fixa."""
    itens = [dict(it, foco=(k == foco)) for k, it in enumerate(itens[:4])]
    passo = 0.45 if len(itens) <= 3 else 0.35
    tempos = list(tempos or [])[:len(itens)] or [0.45]
    while len(tempos) < len(itens):  # itens sem tempo: logo depois do anterior
        tempos.append(round(tempos[-1] + passo, 2))
    return "lista", dict(itens=itens, titulo=titulo, rotulo=rotulo, passo=passo, tempos=tempos)


def comparacao(nome_a, itens_a, nome_b, itens_b, rotulo_a="", rotulo_b=""):
    return "comparacao", dict(nome_a=nome_a, itens_a=itens_a[:3], nome_b=nome_b, itens_b=itens_b[:3],
                              rotulo_a=rotulo_a, rotulo_b=rotulo_b)


def caixas(veu="nenhum"):
    """Peça feita no editor: só as caixas de texto (vêm em "caixas"), com véu "nenhum|baixo|esquerda|total"."""
    return "caixas", dict(veu=veu)
