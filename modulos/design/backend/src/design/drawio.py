"""Compatibilidade com o draw.io (diagrams.net): lê `.drawio`/`.xml` (mxfile com várias páginas,
comprimidas ou não) para os elementos do quadro e escreve o quadro de volta como `.drawio`.

Mapeamento: vértices viram blocos (`no`) pelo estilo do draw.io (losango → decisão, elipse →
círculo, cilindro → banco, documento, nota, hexágono, paralelogramo → entrada/saída, processo
predefinido → subprocesso, raia/contêiner → contêiner, cantos arredondados → processo, o resto →
quadrado); `text` vira texto solto; arestas viram setas (`ligacao`) presas aos blocos, com rótulo.
Cores de preenchimento, borda e texto vêm junto. O visual é o do app, não o do draw.io.
"""

import base64
import html
import re
import uuid
import xml.etree.ElementTree as ET
import zlib
from typing import Any
from urllib.parse import quote, unquote

CINZA = 0xFF37474F
PRETO = 0xFF111111


class ArquivoInvalido(ValueError):
    pass


# ---------- leitura ----------


def _modelos(xml: str) -> list[tuple[str, ET.Element]]:
    """(nome da página, mxGraphModel) de cada diagrama; descomprime o formato antigo."""
    try:
        raiz = ET.fromstring(xml)
    except ET.ParseError as e:
        raise ArquivoInvalido(f"XML inválido: {e}") from e
    if raiz.tag == "mxGraphModel":
        return [("Página 1", raiz)]
    if raiz.tag != "mxfile":
        raise ArquivoInvalido("Não é um arquivo do draw.io (esperava <mxfile>).")
    saida = []
    for i, d in enumerate(raiz.findall("diagram"), start=1):
        nome = d.get("name") or f"Página {i}"
        modelo = d.find("mxGraphModel")
        if modelo is None and (d.text or "").strip():
            try:  # base64 → deflate cru → URL-encoded
                bruto = zlib.decompress(base64.b64decode(d.text.strip()), -15).decode("utf-8")
                modelo = ET.fromstring(unquote(bruto))
            except (ValueError, zlib.error, ET.ParseError) as e:
                raise ArquivoInvalido(
                    f"Página '{nome}' comprimida de um jeito que não entendi."
                ) from e
        if modelo is not None:
            saida.append((nome, modelo))
    if not saida:
        raise ArquivoInvalido("O arquivo não tem páginas.")
    return saida


def _estilo(s: str) -> tuple[set[str], dict[str, str]]:
    """'rhombus;whiteSpace=wrap;fillColor=#fff' → ({'rhombus'}, {'whiteSpace': 'wrap', ...})."""
    soltos, pares = set(), {}
    for parte in (s or "").split(";"):
        if not parte:
            continue
        if "=" in parte:
            k, v = parte.split("=", 1)
            pares[k.strip()] = v.strip()
        else:
            soltos.add(parte.strip())
    return soltos, pares


def _cor(v: str | None, padrao: int | None = None) -> int | None:
    if not v or v in ("none", "default", "inherit"):
        return padrao
    m = re.fullmatch(r"#?([0-9a-fA-F]{6})", v.strip())
    return 0xFF000000 | int(m.group(1), 16) if m else padrao


def texto_de_html(valor: str) -> str:
    """Rótulo HTML do draw.io → texto com a marcação do app (**negrito**, *itálico*,
    __sublinhado__)."""
    t = valor or ""
    t = re.sub(r"(?i)<br\s*/?>|</div>\s*<div[^>]*>|</p>\s*<p[^>]*>", "\n", t)
    t = re.sub(r"(?is)<(b|strong)\b[^>]*>(.*?)</\1>", r"**\2**", t)
    t = re.sub(r"(?is)<(i|em)\b[^>]*>(.*?)</\1>", r"*\2*", t)
    t = re.sub(r"(?is)<u\b[^>]*>(.*?)</u>", r"__\1__", t)
    t = html.unescape(re.sub(r"(?s)<[^>]+>", "", t))
    return re.sub(r"[ \t]+", " ", re.sub(r"\n\s*\n+", "\n", t)).strip()


def _com_fonte(texto: str, pares: dict[str, str]) -> str:
    """`fontStyle` do draw.io é uma máscara (1 negrito, 2 itálico, 4 sublinhado) sobre o texto
    todo."""
    try:
        f = int(pares.get("fontStyle", "0") or 0)
    except ValueError:
        return texto
    if not texto:
        return texto
    if f & 1 and not texto.startswith("**"):
        texto = f"**{texto}**"
    if f & 2:
        texto = f"*{texto}*"
    if f & 4:
        texto = f"__{texto}__"
    return texto


def _tipo_no(soltos: set[str], pares: dict[str, str]) -> str:
    forma = pares.get("shape", "")
    todos = " ".join(soltos) + " " + forma
    if (
        "swimlane" in soltos
        or pares.get("container") == "1"
        or "group" in soltos
        or forma == "swimlane"
    ):
        return "container"
    for chave, tipo in (
        ("rhombus", "decisao"),
        ("decision", "decisao"),
        ("terminator", "inicio"),
        ("start_1", "inicio"),
        ("start_2", "inicio"),
        ("predefined_process", "subprocesso"),
        ("process", "subprocesso"),
        ("parallelogram", "dado"),
        ("flowchart.data", "dado"),
        ("cylinder", "banco"),
        ("database", "banco"),
        ("datastore", "banco"),
        ("document", "documento"),
        ("note", "nota"),
        ("hexagon", "hexagono"),
        ("ellipse", "circulo"),
        ("doubleEllipse", "circulo"),
        ("on-page_reference", "circulo"),
    ):
        if chave in todos:
            return tipo
    if pares.get("rounded") == "1":
        return "inicio" if int(float(pares.get("arcSize", "10") or 10)) >= 40 else "processo"
    return "quadrado"


def ler(xml: str) -> dict[str, Any]:
    """`{"paginas": [{id, nome}], "elementos": [...]}` no formato do app (coordenadas absolutas)."""
    paginas, elementos = [], []
    ignorados = 0
    for n, (nome, modelo) in enumerate(_modelos(xml)):
        pid = uuid.uuid4().hex[:8]
        paginas.append({"id": pid, "nome": nome})
        raiz = modelo.find("root")
        if raiz is None:
            continue
        celulas: dict[str, dict[str, Any]] = {}
        for item in raiz:
            if item.tag in ("UserObject", "object"):
                cel = item.find("mxCell")
                if cel is None:
                    continue
                dados = {**cel.attrib, "id": item.get("id"), "value": item.get("label", "")}
            elif item.tag == "mxCell":
                cel, dados = item, dict(item.attrib)
            else:
                continue
            geo = cel.find("mxGeometry")
            dados["_geo"] = geo.attrib if geo is not None else {}
            pontos = geo.find("mxPoint[@as='sourcePoint']") if geo is not None else None
            alvo = geo.find("mxPoint[@as='targetPoint']") if geo is not None else None
            dados["_pontos"] = (
                (pontos.attrib if pontos is not None else None),
                (alvo.attrib if alvo is not None else None),
            )
            celulas[dados["id"]] = dados

        def origem(cid: str, celulas: dict[str, dict[str, Any]] = celulas) -> tuple[float, float]:
            """Canto do pai (contêiner/grupo) somado até a raiz: no draw.io filhos são relativos."""
            x = y = 0.0
            pai = celulas.get(cid, {}).get("parent")
            vistos = set()
            while pai and pai in celulas and pai not in vistos:
                vistos.add(pai)
                g = celulas[pai]["_geo"]
                x += float(g.get("x", 0) or 0)
                y += float(g.get("y", 0) or 0)
                pai = celulas[pai].get("parent")
            return x, y

        def eid(cid: str, pid: str = pid) -> str:
            return f"{pid}.{cid}"

        vertices, arestas = [], []
        for cid, c in celulas.items():
            soltos, pares = _estilo(c.get("style", ""))
            g = c["_geo"]
            if c.get("vertex") == "1" and g:
                ox, oy = origem(cid)
                x, y = ox + float(g.get("x", 0) or 0), oy + float(g.get("y", 0) or 0)
                w, h = float(g.get("width", 80) or 80), float(g.get("height", 40) or 40)
                texto = texto_de_html(c.get("value", ""))
                if "text" in soltos or pares.get("text") == "1":
                    texto = _com_fonte(texto, pares)
                    if texto:
                        vertices.append(
                            (
                                0,
                                {
                                    "id": eid(cid),
                                    "tipo": "texto",
                                    "posicao": [round(x, 2), round(y, 2)],
                                    "texto": texto,
                                    "cor": _cor(pares.get("fontColor"), PRETO),
                                    "tamanho": float(pares.get("fontSize", 12) or 12) * 1.25,
                                    "pagina": pid,
                                },
                            )
                        )
                    continue
                texto = _com_fonte(texto, pares)
                tipo = _tipo_no(soltos, pares)
                vertices.append(
                    (
                        0 if tipo == "container" else 1,
                        {
                            "id": eid(cid),
                            "tipo": "no",
                            "no": tipo,
                            "texto": texto,
                            "a": [round(x, 2), round(y, 2)],
                            "b": [round(x + w, 2), round(y + h, 2)],
                            "cor": _cor(pares.get("strokeColor"), CINZA),
                            "fundo": _cor(pares.get("fillColor")),
                            "cor_texto": _cor(pares.get("fontColor")),
                            "esquerda": pares.get("align") == "left",
                            "fluxo": f"drawio-{pid}",
                            "pagina": pid,
                        },
                    )
                )
            elif c.get("edge") == "1":
                arestas.append((cid, c, pares))
        ids = {e["id"] for _, e in vertices if e["tipo"] == "no"}
        caixas = [
            (e["id"], e["a"], e["b"])
            for _, e in vertices
            if e["tipo"] == "no" and e["no"] != "container"
        ]

        def bloco_em(
            pt: dict[str, str] | None, ox: float, oy: float, caixas: list[Any] = caixas
        ) -> str:
            """Bloco cuja borda está a até 8 px do ponto (seta solta encostada no bloco)."""
            if not pt:
                return ""
            x, y = ox + float(pt.get("x", 0)), oy + float(pt.get("y", 0))
            dentro = [
                (abs(b[0] - a[0]) * abs(b[1] - a[1]), i)
                for i, a, b in caixas
                if a[0] - 8 <= x <= b[0] + 8 and a[1] - 8 <= y <= b[1] + 8
            ]
            return min(dentro)[1] if dentro else ""

        for cid, c, pares in arestas:
            de, para = eid(c.get("source", "")), eid(c.get("target", ""))
            if de not in ids or para not in ids:
                ox, oy = origem(cid)
                de = de if de in ids else bloco_em(c["_pontos"][0], ox, oy)
                para = para if para in ids else bloco_em(c["_pontos"][1], ox, oy)
                if de and para and de != para:
                    pares = {**pares, "edgeStyle": pares.get("edgeStyle", "none")}
            rotulo = texto_de_html(c.get("value", ""))
            # rótulo como filho da aresta (edgeLabel) no draw.io
            for filho in celulas.values():
                if filho.get("parent") == cid and filho.get("vertex") == "1" and not rotulo:
                    rotulo = texto_de_html(filho.get("value", ""))
            if de in ids and para in ids:
                elementos_seta = {
                    "id": eid(cid),
                    "tipo": "ligacao",
                    "de": de,
                    "para": para,
                    "rotulo": rotulo[:60],
                    "a": [0, 0],
                    "b": [0, 0],
                    "cor": _cor(pares.get("strokeColor"), CINZA),
                    "ortogonal": pares.get("edgeStyle", "").startswith(("orthogonal", "elbow"))
                    or "edgeStyle" not in pares,
                    "tracejada": pares.get("dashed") == "1",
                    "fluxo": f"drawio-{pid}",
                    "pagina": pid,
                }
                vertices.append((2, elementos_seta))
            else:
                s, t = c["_pontos"]
                if s and t:  # seta solta: vira forma
                    ox, oy = origem(cid)
                    vertices.append(
                        (
                            2,
                            {
                                "id": eid(cid),
                                "tipo": "forma",
                                "forma": "seta",
                                "a": [ox + float(s.get("x", 0)), oy + float(s.get("y", 0))],
                                "b": [ox + float(t.get("x", 0)), oy + float(t.get("y", 0))],
                                "cor": _cor(pares.get("strokeColor"), CINZA),
                                "espessura": 2,
                                "pagina": pid,
                            },
                        )
                    )
                else:
                    ignorados += 1
        # contêineres atrás, blocos no meio, setas na frente
        elementos += [e for _, e in sorted(vertices, key=lambda v: v[0])]
        del n
    return {"paginas": paginas, "elementos": elementos, "ignorados": ignorados}


# ---------- escrita ----------

ESTILOS = {
    "inicio": "rounded=1;arcSize=50;",
    "fim": "rounded=1;arcSize=50;",
    "processo": "rounded=1;arcSize=12;",
    "quadrado": "rounded=0;",
    "decisao": "rhombus;",
    "dado": "shape=parallelogram;perimeter=parallelogramPerimeter;fixedSize=1;",
    "subprocesso": "shape=process;backgroundOutline=1;",
    "circulo": "ellipse;",
    "documento": "shape=document;boundedLbl=1;",
    "banco": "shape=cylinder3;boundedLbl=1;backgroundOutline=1;size=12;",
    "nota": "shape=note;size=14;",
    "hexagono": "shape=hexagon;perimeter=hexagonPerimeter2;fixedSize=1;",
    "container": "swimlane;startSize=26;horizontal=1;container=1;collapsible=0;",
}


def _hex(cor: Any) -> str | None:
    return f"#{int(cor) & 0xFFFFFF:06x}" if isinstance(cor, int) else None


def html_de_texto(t: str) -> str:
    t = html.escape(t or "")
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"__(.+?)__", r"<u>\1</u>", t)
    t = re.sub(r"==(.+?)==", r'<span style="background-color:#ffe066">\1</span>', t)
    t = re.sub(r"\*(.+?)\*", r"<i>\1</i>", t)
    return t.replace("\n", "<br>")


def escrever(quadro: dict[str, Any]) -> str:
    """O quadro como `.drawio` (uma página por aba, sem compressão: abre no draw.io/diagrams.net).
    Traços à mão livre não têm equivalente e ficam de fora."""
    paginas = quadro.get("paginas") or [{"id": "", "nome": "Página 1"}]
    primeira = paginas[0]["id"]
    arquivo = ET.Element("mxfile", host="agent", type="device")
    for p in paginas:
        diagrama = ET.SubElement(arquivo, "diagram", id=p["id"] or "pagina", name=p["nome"])
        modelo = ET.SubElement(diagrama, "mxGraphModel", grid="1", gridSize="10", page="0")
        raiz = ET.SubElement(modelo, "root")
        ET.SubElement(raiz, "mxCell", id="0")
        ET.SubElement(raiz, "mxCell", id="1", parent="0")
        da_pagina = [
            e for e in quadro.get("elementos", []) if (e.get("pagina") or primeira) == p["id"]
        ]
        ids = {e["id"] for e in da_pagina}
        for e in da_pagina:
            tipo = e.get("tipo")
            if tipo == "no":
                estilo = ESTILOS.get(e.get("no", ""), "rounded=1;") + "whiteSpace=wrap;html=1;"
                if e.get("esquerda"):
                    estilo += "align=left;spacingLeft=6;"
                for chave, cor in (
                    ("strokeColor", e.get("cor")),
                    ("fillColor", e.get("fundo")),
                    ("fontColor", e.get("cor_texto")),
                ):
                    if (h := _hex(cor)) is not None:
                        estilo += f"{chave}={h};"
                (x1, y1), (x2, y2) = e["a"], e["b"]
                c = ET.SubElement(
                    raiz,
                    "mxCell",
                    id=e["id"],
                    value=html_de_texto(e.get("texto", "")),
                    style=estilo,
                    vertex="1",
                    parent="1",
                )
                ET.SubElement(
                    c,
                    "mxGeometry",
                    {
                        "x": f"{min(x1, x2):g}",
                        "y": f"{min(y1, y2):g}",
                        "width": f"{abs(x2 - x1):g}",
                        "height": f"{abs(y2 - y1):g}",
                        "as": "geometry",
                    },
                )
            elif tipo == "ligacao" and e.get("de") in ids and e.get("para") in ids:
                estilo = (
                    "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;"
                    if e.get("ortogonal")
                    else "html=1;"
                )
                if e.get("tracejada"):
                    estilo += "dashed=1;"
                if (h := _hex(e.get("cor"))) is not None:
                    estilo += f"strokeColor={h};"
                c = ET.SubElement(
                    raiz,
                    "mxCell",
                    id=e["id"],
                    value=html.escape(e.get("rotulo", "")),
                    style=estilo,
                    edge="1",
                    parent="1",
                    source=e["de"],
                    target=e["para"],
                )
                geo = ET.SubElement(c, "mxGeometry", {"relative": "1", "as": "geometry"})
                if e.get("pontos"):  # a rota que o app calculou vira pontos de passagem no draw.io
                    pontos = ET.SubElement(geo, "Array", {"as": "points"})
                    for x, y in e["pontos"]:
                        ET.SubElement(pontos, "mxPoint", {"x": f"{x:g}", "y": f"{y:g}"})
            elif tipo == "texto":
                x, y = e["posicao"]
                c = ET.SubElement(
                    raiz,
                    "mxCell",
                    id=e["id"],
                    value=html_de_texto(e.get("texto", "")),
                    style=f"text;html=1;fontSize={round(float(e.get('tamanho', 15)) / 1.25)};"
                    f"fontColor={_hex(e.get('cor')) or '#111111'};",
                    vertex="1",
                    parent="1",
                )
                largura = max(40, len(e.get("texto", "")) * float(e.get("tamanho", 15)) * 0.55)
                ET.SubElement(
                    c,
                    "mxGeometry",
                    {
                        "x": f"{x:g}",
                        "y": f"{y:g}",
                        "width": f"{largura:.0f}",
                        "height": f"{float(e.get('tamanho', 15)) * 1.6:.0f}",
                        "as": "geometry",
                    },
                )
            elif tipo == "forma":
                (x1, y1), (x2, y2) = e["a"], e["b"]
                cor = _hex(e.get("cor")) or "#111111"
                if e.get("forma") in ("reta", "seta"):
                    fim = "classic" if e["forma"] == "seta" else "none"
                    c = ET.SubElement(
                        raiz,
                        "mxCell",
                        id=e["id"],
                        style=f"endArrow={fim};html=1;strokeColor={cor};",
                        edge="1",
                        parent="1",
                    )
                    g = ET.SubElement(c, "mxGeometry", {"relative": "1", "as": "geometry"})
                    ET.SubElement(
                        g, "mxPoint", {"x": f"{x1:g}", "y": f"{y1:g}", "as": "sourcePoint"}
                    )
                    ET.SubElement(
                        g, "mxPoint", {"x": f"{x2:g}", "y": f"{y2:g}", "as": "targetPoint"}
                    )
                else:
                    base = "ellipse;" if e.get("forma") == "elipse" else ""
                    c = ET.SubElement(
                        raiz,
                        "mxCell",
                        id=e["id"],
                        value="",
                        style=f"{base}fillColor=none;strokeColor={cor};html=1;",
                        vertex="1",
                        parent="1",
                    )
                    ET.SubElement(
                        c,
                        "mxGeometry",
                        {
                            "x": f"{min(x1, x2):g}",
                            "y": f"{min(y1, y2):g}",
                            "width": f"{abs(x2 - x1):g}",
                            "height": f"{abs(y2 - y1):g}",
                            "as": "geometry",
                        },
                    )
    return ET.tostring(arquivo, encoding="unicode")


def nome_arquivo(titulo: str) -> str:
    return quote(re.sub(r"[^\w\s.-]", "", titulo).strip().replace(" ", "-") or "quadro") + ".drawio"
