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

GRAY = 0xFF37474F
BLACK = 0xFF111111


class FileInvalid(ValueError):
    pass


# ---------- leitura ----------


def _models(xml: str) -> list[tuple[str, ET.Element]]:
    """(nome da página, mxGraphModel) de cada diagrama; descomprime o formato antigo."""
    try:
        root = ET.fromstring(xml)
    except ET.ParseError as e:
        raise FileInvalid(f"XML inválido: {e}") from e
    if root.tag == "mxGraphModel":
        return [("Página 1", root)]
    if root.tag != "mxfile":
        raise FileInvalid("Não é um arquivo do draw.io (esperava <mxfile>).")
    output = []
    for i, d in enumerate(root.findall("diagram"), start=1):
        name = d.get("name") or f"Página {i}"
        model = d.find("mxGraphModel")
        if model is None and (d.text or "").strip():
            try:  # base64 → deflate cru → URL-encoded
                raw = zlib.decompress(base64.b64decode(d.text.strip()), -15).decode("utf-8")
                model = ET.fromstring(unquote(raw))
            except (ValueError, zlib.error, ET.ParseError) as e:
                raise FileInvalid(
                    f"Página '{name}' comprimida de um jeito que não entendi."
                ) from e
        if model is not None:
            output.append((name, model))
    if not output:
        raise FileInvalid("O arquivo não tem páginas.")
    return output


def _style(s: str) -> tuple[set[str], dict[str, str]]:
    """'rhombus;whiteSpace=wrap;fillColor=#fff' → ({'rhombus'}, {'whiteSpace': 'wrap', ...})."""
    loose, pairs = set(), {}
    for part in (s or "").split(";"):
        if not part:
            continue
        if "=" in part:
            k, v = part.split("=", 1)
            pairs[k.strip()] = v.strip()
        else:
            loose.add(part.strip())
    return loose, pairs


def _color(v: str | None, default: int | None = None) -> int | None:
    if not v or v in ("none", "default", "inherit"):
        return default
    m = re.fullmatch(r"#?([0-9a-fA-F]{6})", v.strip())
    return 0xFF000000 | int(m.group(1), 16) if m else default


def text_of_html(valor: str) -> str:
    """Rótulo HTML do draw.io → texto com a marcação do app (**negrito**, *itálico*,
    __sublinhado__)."""
    t = valor or ""
    t = re.sub(r"(?i)<br\s*/?>|</div>\s*<div[^>]*>|</p>\s*<p[^>]*>", "\n", t)
    t = re.sub(r"(?is)<(b|strong)\b[^>]*>(.*?)</\1>", r"**\2**", t)
    t = re.sub(r"(?is)<(i|em)\b[^>]*>(.*?)</\1>", r"*\2*", t)
    t = re.sub(r"(?is)<u\b[^>]*>(.*?)</u>", r"__\1__", t)
    t = html.unescape(re.sub(r"(?s)<[^>]+>", "", t))
    return re.sub(r"[ \t]+", " ", re.sub(r"\n\s*\n+", "\n", t)).strip()


def _with_source(text: str, pairs: dict[str, str]) -> str:
    """`fontStyle` do draw.io é uma máscara (1 negrito, 2 itálico, 4 sublinhado) sobre o texto
    todo."""
    try:
        f = int(pairs.get("fontStyle", "0") or 0)
    except ValueError:
        return text
    if not text:
        return text
    if f & 1 and not text.startswith("**"):
        text = f"**{text}**"
    if f & 2:
        text = f"*{text}*"
    if f & 4:
        text = f"__{text}__"
    return text


def _kind_node(loose: set[str], pairs: dict[str, str]) -> str:
    shape = pairs.get("shape", "")
    everything = " ".join(loose) + " " + shape
    if (
        "swimlane" in loose
        or pairs.get("container") == "1"
        or "group" in loose
        or shape == "swimlane"
    ):
        return "container"
    for key, kind in (
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
        if key in everything:
            return kind
    if pairs.get("rounded") == "1":
        return "inicio" if int(float(pairs.get("arcSize", "10") or 10)) >= 40 else "processo"
    return "quadrado"


def read(xml: str) -> dict[str, Any]:
    """`{"paginas": [{id, nome}], "elementos": [...]}` no formato do app (coordenadas absolutas)."""
    pages, elements = [], []
    ignorados = 0
    for n, (name, model) in enumerate(_models(xml)):
        pid = uuid.uuid4().hex[:8]
        pages.append({"id": pid, "nome": name})
        root = model.find("root")
        if root is None:
            continue
        cells: dict[str, dict[str, Any]] = {}
        for item in root:
            if item.tag in ("UserObject", "object"):
                cel = item.find("mxCell")
                if cel is None:
                    continue
                data = {**cel.attrib, "id": item.get("id"), "value": item.get("label", "")}
            elif item.tag == "mxCell":
                cel, data = item, dict(item.attrib)
            else:
                continue
            geo = cel.find("mxGeometry")
            data["_geo"] = geo.attrib if geo is not None else {}
            points = geo.find("mxPoint[@as='sourcePoint']") if geo is not None else None
            target = geo.find("mxPoint[@as='targetPoint']") if geo is not None else None
            data["_pontos"] = (
                (points.attrib if points is not None else None),
                (target.attrib if target is not None else None),
            )
            cells[data["id"]] = data

        def origem(cid: str, cells: dict[str, dict[str, Any]] = cells) -> tuple[float, float]:
            """Canto do pai (contêiner/grupo) somado até a raiz: no draw.io filhos são relativos."""
            x = y = 0.0
            pai = cells.get(cid, {}).get("parent")
            seen = set()
            while pai and pai in cells and pai not in seen:
                seen.add(pai)
                g = cells[pai]["_geo"]
                x += float(g.get("x", 0) or 0)
                y += float(g.get("y", 0) or 0)
                pai = cells[pai].get("parent")
            return x, y

        def eid(cid: str, pid: str = pid) -> str:
            return f"{pid}.{cid}"

        vertices, arestas = [], []
        for cid, c in cells.items():
            loose, pairs = _style(c.get("style", ""))
            g = c["_geo"]
            if c.get("vertex") == "1" and g:
                ox, oy = origem(cid)
                x, y = ox + float(g.get("x", 0) or 0), oy + float(g.get("y", 0) or 0)
                w, h = float(g.get("width", 80) or 80), float(g.get("height", 40) or 40)
                text = text_of_html(c.get("value", ""))
                if "text" in loose or pairs.get("text") == "1":
                    text = _with_source(text, pairs)
                    if text:
                        vertices.append(
                            (
                                0,
                                {
                                    "id": eid(cid),
                                    "tipo": "texto",
                                    "posicao": [round(x, 2), round(y, 2)],
                                    "texto": text,
                                    "cor": _color(pairs.get("fontColor"), BLACK),
                                    "tamanho": float(pairs.get("fontSize", 12) or 12) * 1.25,
                                    "pagina": pid,
                                },
                            )
                        )
                    continue
                text = _with_source(text, pairs)
                kind = _kind_node(loose, pairs)
                vertices.append(
                    (
                        0 if kind == "container" else 1,
                        {
                            "id": eid(cid),
                            "tipo": "no",
                            "no": kind,
                            "texto": text,
                            "a": [round(x, 2), round(y, 2)],
                            "b": [round(x + w, 2), round(y + h, 2)],
                            "cor": _color(pairs.get("strokeColor"), GRAY),
                            "fundo": _color(pairs.get("fillColor")),
                            "cor_texto": _color(pairs.get("fontColor")),
                            "esquerda": pairs.get("align") == "left",
                            "fluxo": f"drawio-{pid}",
                            "pagina": pid,
                        },
                    )
                )
            elif c.get("edge") == "1":
                arestas.append((cid, c, pairs))
        ids = {e["id"] for _, e in vertices if e["tipo"] == "no"}
        boxes = [
            (e["id"], e["a"], e["b"])
            for _, e in vertices
            if e["tipo"] == "no" and e["no"] != "container"
        ]

        def bloco_em(
            pt: dict[str, str] | None, ox: float, oy: float, boxes: list[Any] = boxes
        ) -> str:
            """Bloco cuja borda está a até 8 px do ponto (seta solta encostada no bloco)."""
            if not pt:
                return ""
            x, y = ox + float(pt.get("x", 0)), oy + float(pt.get("y", 0))
            inside = [
                (abs(b[0] - a[0]) * abs(b[1] - a[1]), i)
                for i, a, b in boxes
                if a[0] - 8 <= x <= b[0] + 8 and a[1] - 8 <= y <= b[1] + 8
            ]
            return min(inside)[1] if inside else ""

        for cid, c, pairs in arestas:
            de, para = eid(c.get("source", "")), eid(c.get("target", ""))
            if de not in ids or para not in ids:
                ox, oy = origem(cid)
                de = de if de in ids else bloco_em(c["_pontos"][0], ox, oy)
                para = para if para in ids else bloco_em(c["_pontos"][1], ox, oy)
                if de and para and de != para:
                    pairs = {**pairs, "edgeStyle": pairs.get("edgeStyle", "none")}
            label = text_of_html(c.get("value", ""))
            # rótulo como filho da aresta (edgeLabel) no draw.io
            for child in cells.values():
                if child.get("parent") == cid and child.get("vertex") == "1" and not label:
                    label = text_of_html(child.get("value", ""))
            if de in ids and para in ids:
                elements_arrow = {
                    "id": eid(cid),
                    "tipo": "ligacao",
                    "de": de,
                    "para": para,
                    "rotulo": label[:60],
                    "a": [0, 0],
                    "b": [0, 0],
                    "cor": _color(pairs.get("strokeColor"), GRAY),
                    "ortogonal": pairs.get("edgeStyle", "").startswith(("orthogonal", "elbow"))
                    or "edgeStyle" not in pairs,
                    "tracejada": pairs.get("dashed") == "1",
                    "fluxo": f"drawio-{pid}",
                    "pagina": pid,
                }
                vertices.append((2, elements_arrow))
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
                                "cor": _color(pairs.get("strokeColor"), GRAY),
                                "espessura": 2,
                                "pagina": pid,
                            },
                        )
                    )
                else:
                    ignorados += 1
        # contêineres atrás, blocos no meio, setas na frente
        elements += [e for _, e in sorted(vertices, key=lambda v: v[0])]
        del n
    return {"paginas": pages, "elementos": elements, "ignorados": ignorados}


# ---------- escrita ----------

STYLES = {
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


def _hex(color: Any) -> str | None:
    return f"#{int(color) & 0xFFFFFF:06x}" if isinstance(color, int) else None


def html_of_text(t: str) -> str:
    t = html.escape(t or "")
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"__(.+?)__", r"<u>\1</u>", t)
    t = re.sub(r"==(.+?)==", r'<span style="background-color:#ffe066">\1</span>', t)
    t = re.sub(r"\*(.+?)\*", r"<i>\1</i>", t)
    return t.replace("\n", "<br>")


def write(frame: dict[str, Any]) -> str:
    """O quadro como `.drawio` (uma página por aba, sem compressão: abre no draw.io/diagrams.net).
    Traços à mão livre não têm equivalente e ficam de fora."""
    pages = frame.get("paginas") or [{"id": "", "nome": "Página 1"}]
    primeira = pages[0]["id"]
    file = ET.Element("mxfile", host="agent", type="device")
    for p in pages:
        diagrama = ET.SubElement(file, "diagram", id=p["id"] or "pagina", name=p["nome"])
        model = ET.SubElement(diagrama, "mxGraphModel", grid="1", gridSize="10", page="0")
        root = ET.SubElement(model, "root")
        ET.SubElement(root, "mxCell", id="0")
        ET.SubElement(root, "mxCell", id="1", parent="0")
        of_page = [
            e for e in frame.get("elementos", []) if (e.get("pagina") or primeira) == p["id"]
        ]
        ids = {e["id"] for e in of_page}
        for e in of_page:
            kind = e.get("tipo")
            if kind == "no":
                style = STYLES.get(e.get("no", ""), "rounded=1;") + "whiteSpace=wrap;html=1;"
                if e.get("esquerda"):
                    style += "align=left;spacingLeft=6;"
                for key, color in (
                    ("strokeColor", e.get("cor")),
                    ("fillColor", e.get("fundo")),
                    ("fontColor", e.get("cor_texto")),
                ):
                    if (h := _hex(color)) is not None:
                        style += f"{key}={h};"
                (x1, y1), (x2, y2) = e["a"], e["b"]
                c = ET.SubElement(
                    root,
                    "mxCell",
                    id=e["id"],
                    value=html_of_text(e.get("texto", "")),
                    style=style,
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
            elif kind == "ligacao" and e.get("de") in ids and e.get("para") in ids:
                style = (
                    "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;"
                    if e.get("ortogonal")
                    else "html=1;"
                )
                if e.get("tracejada"):
                    style += "dashed=1;"
                if (h := _hex(e.get("cor"))) is not None:
                    style += f"strokeColor={h};"
                c = ET.SubElement(
                    root,
                    "mxCell",
                    id=e["id"],
                    value=html.escape(e.get("rotulo", "")),
                    style=style,
                    edge="1",
                    parent="1",
                    source=e["de"],
                    target=e["para"],
                )
                geo = ET.SubElement(c, "mxGeometry", {"relative": "1", "as": "geometry"})
                if e.get("pontos"):  # a rota que o app calculou vira pontos de passagem no draw.io
                    points = ET.SubElement(geo, "Array", {"as": "points"})
                    for x, y in e["pontos"]:
                        ET.SubElement(points, "mxPoint", {"x": f"{x:g}", "y": f"{y:g}"})
            elif kind == "texto":
                x, y = e["posicao"]
                c = ET.SubElement(
                    root,
                    "mxCell",
                    id=e["id"],
                    value=html_of_text(e.get("texto", "")),
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
            elif kind == "forma":
                (x1, y1), (x2, y2) = e["a"], e["b"]
                color = _hex(e.get("cor")) or "#111111"
                if e.get("forma") in ("reta", "seta"):
                    end = "classic" if e["forma"] == "seta" else "none"
                    c = ET.SubElement(
                        root,
                        "mxCell",
                        id=e["id"],
                        style=f"endArrow={end};html=1;strokeColor={color};",
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
                        root,
                        "mxCell",
                        id=e["id"],
                        value="",
                        style=f"{base}fillColor=none;strokeColor={color};html=1;",
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
    return ET.tostring(file, encoding="unicode")


def name_file(titulo: str) -> str:
    return quote(re.sub(r"[^\w\s.-]", "", titulo).strip().replace(" ", "-") or "quadro") + ".drawio"
