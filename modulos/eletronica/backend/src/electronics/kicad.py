"""Reader of KiCad symbol libraries (`.kicad_sym`, KiCad 6 to 9) into the `library.py` format.
KiCad uses mm with y up; here it becomes µm with y down. A KiCad pin has its tip at `at` and the
angle points to the body (0 right, 90 up, 180 left, 270 down), like our `dir`. Multi-unit symbols
(dual op-amp, logic gates) become one symbol per unit (`<lib>:<nome>:<n>`), each with the common
drawing (unit 0); the De Morgan style (2) is left out. `extends` inherits the parent drawing."""

import math
import re
from typing import Any

Sexp = list[Any]

KINDS_PIN = {
    "input": "entrada",
    "output": "saida",
    "tri_state": "saida",
    "open_collector": "saida",
    "open_emitter": "saida",
    "bidirectional": "bidirecional",
    "power_in": "alimentacao",
    "power_out": "alimentacao",
    "no_connect": "nc",
}
DIRECTIONS = {0: "d", 90: "c", 180: "e", 270: "b"}


class FileInvalid(Exception):
    pass


class _Atom(str):
    """Unquoted word (tells `hide` apart from `"hide"`)."""


_TOKEN = re.compile(r'\s*(?:(\()|(\))|"((?:[^"\\]|\\.)*)"|([^\s()"]+))', re.S)


def read_sexp(text: str) -> Sexp:
    stack: list[Sexp] = [[]]
    pos, end = 0, len(text)
    while pos < end:
        m = _TOKEN.match(text, pos)
        if not m:
            if text[pos:].strip():
                raise FileInvalid(f"Caractere inesperado na posição {pos}")
            break
        pos = m.end()
        abre, fecha, cadeia, atom = m.groups()
        if abre:
            stack.append([])
        elif fecha:
            if len(stack) < 2:
                raise FileInvalid("Parêntese fechando sem abrir")
            done = stack.pop()
            stack[-1].append(done)
        elif cadeia is not None:
            stack[-1].append(re.sub(r"\\(.)", r"\1", cadeia))
        elif atom is not None:
            stack[-1].append(_Atom(atom))
    if len(stack) != 1 or len(stack[0]) != 1 or not isinstance(stack[0][0], list):
        raise FileInvalid("Arquivo não é uma expressão S completa")
    return stack[0][0]


def _children(no: Sexp, nome: str) -> list[Sexp]:
    return [f for f in no[1:] if isinstance(f, list) and f and f[0] == nome]


def _child(no: Sexp, nome: str) -> Sexp | None:
    found = _children(no, nome)
    return found[0] if found else None


def _hidden(no: Sexp | None) -> bool:
    """`hide` solto (KiCad 6–7) ou `(hide yes)` (KiCad 8+)."""
    if no is None:
        return False
    if any(isinstance(f, _Atom) and f == "hide" for f in no[1:]):
        return True
    h = _child(no, "hide")
    return h is not None and (len(h) == 1 or h[1] == "yes")


def _um(v: Any) -> int:
    return round(float(v) * 1000)


def _xy(no: Sexp, i: int = 1) -> list[int]:
    """[x, y] in µm with y down from `(at x y …)`, `(start x y)` etc."""
    return [_um(no[i]), -_um(no[i + 1])]


def _filled(no: Sexp) -> bool:
    fill = _child(no, "fill")
    kind = _child(fill, "type") if fill else None
    return bool(kind and kind[1] == "outline")


def _arc(inicio: list[int], meio: list[int], fim: list[int]) -> dict[str, Any] | None:
    (x1, y1), (x2, y2), (x3, y3) = inicio, meio, fim
    d = 2 * (x1 * (y2 - y3) + x2 * (y3 - y1) + x3 * (y1 - y2))
    if d == 0:
        return None
    q1, q2, q3 = x1 * x1 + y1 * y1, x2 * x2 + y2 * y2, x3 * x3 + y3 * y3
    cx = (q1 * (y2 - y3) + q2 * (y3 - y1) + q3 * (y1 - y2)) / d
    cy = (q1 * (x3 - x2) + q2 * (x1 - x3) + q3 * (x2 - x1)) / d
    ang = [math.degrees(math.atan2(y - cy, x - cx)) for x, y in (inicio, meio, fim)]
    varredura = (ang[2] - ang[0]) % 360
    if (ang[1] - ang[0]) % 360 > varredura:
        varredura -= 360
    return {
        "t": "arco",
        "c": [round(cx), round(cy)],
        "r": round(math.hypot(x1 - cx, y1 - cy)),
        "ini": round(ang[0], 2),
        "var": round(varredura, 2),
    }


def _bezier(pts: list[list[int]], steps: int = 12) -> list[list[int]]:
    if len(pts) != 4:
        return pts
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = pts
    output = []
    for i in range(steps + 1):
        t = i / steps
        a, b, c, d = (1 - t) ** 3, 3 * t * (1 - t) ** 2, 3 * t * t * (1 - t), t**3
        output.append(
            [round(a * x0 + b * x1 + c * x2 + d * x3), round(a * y0 + b * y1 + c * y2 + d * y3)]
        )
    return output


def _primitive(no: Sexp) -> dict[str, Any] | None:
    match no[0]:
        case "rectangle":
            a, b = _child(no, "start"), _child(no, "end")
            if a and b:
                return {"t": "ret", "a": _xy(a), "b": _xy(b), "cheio": _filled(no)}
        case "polyline" | "bezier":
            pts_node = _child(no, "pts")
            pts = [_xy(p) for p in _children(pts_node, "xy")] if pts_node else []
            if no[0] == "bezier":
                pts = _bezier(pts)
            if len(pts) >= 2:
                cheia = _filled(no)
                fechada = cheia or pts[0] == pts[-1]
                return {"t": "linha", "p": pts, "fechada": fechada, "cheia": cheia}
        case "circle":
            c, r = _child(no, "center"), _child(no, "radius")
            if c and r:
                return {"t": "circ", "c": _xy(c), "r": _um(r[1]), "cheio": _filled(no)}
        case "arc":
            a, m, b = _child(no, "start"), _child(no, "mid"), _child(no, "end")
            if a and m and b:
                return _arc(_xy(a), _xy(m), _xy(b))
        case "text":
            at = _child(no, "at")
            if at and isinstance(no[1], str):
                return {"t": "texto", "p": _xy(at), "s": no[1]}
    return None


def _pin(no: Sexp) -> dict[str, Any] | None:
    at, comp = _child(no, "at"), _child(no, "length")
    name, number = _child(no, "name"), _child(no, "number")
    if not (at and number):
        return None
    angulo = round(float(at[3]) if len(at) > 3 else 0) % 360
    label = name[1] if name and isinstance(name[1], str) else ""
    return {
        "n": str(number[1]),
        "nome": "" if label == "~" else label,
        "x": _um(at[1]),
        "y": -_um(at[2]),
        "dir": DIRECTIONS.get(angulo, "d"),
        "comp": _um(comp[1]) if comp else 0,
        "tipo": KINDS_PIN.get(str(no[1]), "passivo"),
        "oculto": _hidden(no),
    }


def _properties(no: Sexp) -> dict[str, tuple[str, list[int] | None]]:
    props = {}
    for p in _children(no, "property"):
        if len(p) >= 3 and isinstance(p[1], str):
            at = _child(p, "at")
            props[p[1]] = (str(p[2]), _xy(at) if at else None)
    return props


def _units(no: Sexp, nome: str) -> dict[int, list[Sexp]]:
    """Body of each unit (`<nome>_<unidade>_<estilo>`), normal style only."""
    units: dict[int, list[Sexp]] = {}
    for sub in _children(no, "symbol"):
        parts = str(sub[1]).rsplit("_", 2)
        if len(parts) != 3 or not (parts[1].isdigit() and parts[2].isdigit()):
            continue
        unit, style = int(parts[1]), int(parts[2])
        if style in (0, 1):
            units.setdefault(unit, []).extend(f for f in sub[1:] if isinstance(f, list))
    return units


def _convert(
    lib: str, nome: str, no: Sexp, corpo: dict[int, list[Sexp]], props: dict[str, Any]
) -> list[dict[str, Any]]:
    ref, pos_ref = props.get("Reference", ("U", None))
    value, pos_value = props.get("Value", (nome, None))
    nutrition = _child(no, "power") is not None
    names = not _hidden(_child(no, "pin_names"))
    numbers = not _hidden(_child(no, "pin_numbers"))
    comuns = corpo.get(0, [])
    numeradas = sorted(u for u in corpo if u > 0) or [0]
    output = []
    for u in numeradas:
        items = comuns + (corpo.get(u, []) if u else [])
        desenho = [p for p in map(_primitive, (i for i in items if i[0] != "pin")) if p]
        pins = [p for p in map(_pin, (i for i in items if i[0] == "pin")) if p]
        if not pins and not desenho:
            continue
        varias = len(numeradas) > 1
        output.append(
            {
                "id": f"{lib}:{nome}" + (f":{u}" if varias else ""),
                "nome": nome + (f" ({chr(64 + u)})" if varias else ""),
                "categoria": lib,
                "prefixo": ref.rstrip("?") or "U",
                "tipo": "alimentacao" if nutrition else "componente",
                "valor": value,
                "encapsulamento": props.get("Footprint", ("", None))[0],
                "descricao": props.get("Description", props.get("ki_description", ("", None)))[0],
                "palavras": props.get("ki_keywords", ("", None))[0],
                "desenho": desenho,
                "pinos": pins,
                "campos": {"ref": pos_ref or [0, -2540], "valor": pos_value or [0, 2540]},
                "nomes_pinos": names,
                "numeros_pinos": numbers,
            }
        )
    return output


def read_collection(text: str, lib: str) -> list[dict[str, Any]]:
    """All the symbols of a `.kicad_sym`, already converted. [lib] becomes the category and the id
    prefix."""
    root = read_sexp(text)
    if not root or root[0] != "kicad_symbol_lib":
        raise FileInvalid("Não é uma biblioteca de símbolos do KiCad (kicad_symbol_lib)")
    nodes = {str(s[1]): s for s in _children(root, "symbol") if len(s) > 1}
    corpos = {n: _units(s, n) for n, s in nodes.items()}

    def corpo(nome: str, profundidade: int = 0) -> tuple[dict[int, list[Sexp]], dict[str, Any]]:
        no = nodes[nome]
        props = _properties(no)
        parent = _child(no, "extends")
        if parent and str(parent[1]) in nodes and profundidade < 8:
            body_parent, props_parent = corpo(str(parent[1]), profundidade + 1)
            return body_parent, {**props_parent, **props}
        return corpos[nome], props

    symbols = []
    for nome, no in nodes.items():
        c, props = corpo(nome)
        symbols.extend(_convert(lib, nome, no, c, props))
    return symbols
