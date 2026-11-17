"""Patch over an EffectCraft N1 document: the local LLM answers with a short list of edits
instead of rewriting the whole piece. Each op is applied on a copy and validated against the N1
schema on its own: a bad op is refused (and reported back to the model), the good ones stay.

The N1 field names (`nome`, `alvo`, `cor`…) stay as the N1 contract defines them.
"""
import copy
from typing import Annotated, Literal

from pydantic import BaseModel, Field, ValidationError

from esteira.n1 import effectcraft as N1EC

MAX_OPS = 12
MAX_ADDS = 3                       # added shapes are accents beside the content, not a second layout
LINE_H, LINE_W = (0.006, 0.03), (0.3, 0.9)   # (default, max) of an added rectangle: a thin rule
T_MAX, DUR_MAX = 1.8, 0.8            # s: every entrance settles early (the proof frame and the viewer see it whole)
ACCENT_WEIGHT = 0.25               # cell of an added accent next to the cells of the content (1.0 each)
DOT_D = (0.04, 0.12)               # (default, max) diameter of an added ellipse: a dot or a ring
ENTRANCES = Literal["baixo", "esq", "dir", "aparecer", "escala"]


class _Op(BaseModel):
    model_config = {"extra": "forbid"}


class Style(_Op):
    """Changes the look of one existing element; only the fields that change."""
    op: Literal["style"]
    nome: str
    nivel: Literal["titulo", "destaque", "numero", "corpo", "rotulo"] | None = None
    peso: int | None = Field(None, ge=100, le=900)
    tam: float | None = Field(None, gt=0, le=0.4)
    fonte: N1EC.RoleSource | None = None
    cor: N1EC.RoleColor | None = None
    alinhar: Literal["esquerda", "centro", "direita"] | None = None
    caps: bool | None = None
    italico: bool | None = None
    opacidade: float | None = Field(None, ge=0, le=100)
    raio: float | None = Field(None, ge=0)
    contorno: float | None = Field(None, ge=0)


class Motion(_Op):
    """Changes (or creates) the entrance animation of one existing element."""
    op: Literal["motion"]
    alvo: str
    de: ENTRANCES | None = None
    t: N1EC.Time | None = None
    dur: N1EC.Duration | None = None


class Add(_Op):
    """Adds a shape inside an existing box (the compiler places it), optionally with an entrance."""
    op: Literal["add"]
    caixa: str
    elemento: Annotated[N1EC.Rectangle | N1EC.Ellipse, Field(discriminator="tipo")]
    de: ENTRANCES | None = None
    t: N1EC.Time | None = None


class Weights(_Op):
    """Relative size of each child of a box (a text that came out tiny needs a bigger cell)."""
    op: Literal["weights"]
    caixa: str
    pesos: list[Annotated[float, Field(gt=0, le=10)]] = Field(min_length=1, max_length=20)


Op = Annotated[Style | Motion | Add | Weights, Field(discriminator="op")]


class Patch(BaseModel):
    ops: list[Op] = Field(default_factory=list, max_length=MAX_OPS)
    comunica: str = ""


def _children(el):
    if el.get("tipo") == "caixa":
        return el.get("filhos") or []
    if el.get("tipo") == "repetir":
        return el.get("elementos") or []
    return []


def _find(els, name, owner):
    """(element, owner): owner is the dict whose `animacoes` animates it (document or `repetir`)."""
    for el in els or []:
        if el.get("nome") == name:
            return el, owner
        inner_owner = owner
        if el.get("tipo") == "repetir":
            inner_owner = el
        found = _find(_children(el), name, inner_owner)
        if found[0] is not None:
            return found
    return None, None


def _names(els, out):
    for el in els or []:
        out.append(el.get("nome"))
        _names(_children(el), out)
    return out


def _apply_style(doc, op):
    el, _ = _find(doc.get("elementos"), op["nome"], doc)
    if el is None:
        return f"no element named {op['nome']!r}"
    if el.get("tipo") in ("caixa", "repetir"):
        return f"{op['nome']!r} is a {el['tipo']}: style its texts and shapes, not the container"
    if op.get("nivel") is not None and "numero" in (op["nivel"], el.get("nivel")) and op["nivel"] != el.get("nivel"):
        return (f"the hierarchy of the BASE stays: {op['nome']!r} keeps nivel {el.get('nivel')!r} (change peso, "
                "cor or caps instead)")
    if op.get("tam") is not None and el.get("tipo") != "texto":
        return f"{op['nome']!r} is not a text: tam only for texts"
    changed = False
    for field, value in op.items():
        if field in ("op", "nome") or value is None:
            continue
        el[field] = value
        changed = True
    if not changed:
        return f"style of {op['nome']!r} changes no field"
    return None


def _apply_motion(doc, op):
    el, owner = _find(doc.get("elementos"), op["alvo"], doc)
    if el is None:
        return f"no element named {op['alvo']!r}"
    entrance = None
    for anim in owner.setdefault("animacoes", []):
        if anim.get("alvo") == op["alvo"] and anim.get("anim") == "entrar":
            entrance = anim
            break
    if entrance is None:
        entrance = {"anim": "entrar", "alvo": op["alvo"]}
        owner["animacoes"].append(entrance)
    changed = False
    for field in ("de", "t", "dur"):
        if op.get(field) is not None:
            entrance[field] = _early(field, op[field])
            changed = True
    if not changed:
        return f"motion of {op['alvo']!r} changes no field"
    if op.get("t") is not None:
        for anim in owner["animacoes"]:  # the number counts when it enters, not before
            if anim.get("alvo") == op["alvo"] and anim.get("anim") == "contar":
                anim["t"] = entrance["t"]
    return None


def _early(field, value):
    """Numeric start and duration clamped; expressions ("@numero+0.5v", "0.4v") stay as written."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return value
    return min(value, T_MAX if field == "t" else DUR_MAX)


def _apply_add(doc, op):
    box, owner = _find(doc.get("elementos"), op["caixa"], doc)
    if box is None or box.get("tipo") != "caixa":
        return f"no box named {op['caixa']!r}"
    shape = dict(op["elemento"])
    if shape["nome"] in _names(doc.get("elementos"), []):
        return f"element name {shape['nome']!r} already exists"
    added = sum(1 for n in _names(doc.get("elementos"), []) if n in doc.get("_added", []))
    if added >= MAX_ADDS:
        return f"at most {MAX_ADDS} added shapes: style and animate what exists"
    for field in ("x", "y"):
        shape.pop(field, None)
    _accent_size(shape)
    doc.setdefault("_added", []).append(shape["nome"])
    kids = box.setdefault("filhos", [])
    weights = list(box.get("pesos") or [])[:len(kids)]
    while len(weights) < len(kids):
        weights.append(1.0)
    box["pesos"] = [*weights, ACCENT_WEIGHT]  # without it the accent took a whole cell and squeezed the texts
    kids.append(shape)
    if op.get("de") is not None or op.get("t") is not None:
        entrance = {"anim": "entrar", "alvo": shape["nome"]}
        for field in ("de", "t"):
            if op.get(field) is not None:
                entrance[field] = _early(field, op[field])
        owner.setdefault("animacoes", []).append(entrance)
    return None


def _accent_size(shape):
    """Without a size a shape fills the cell of the box (a block over the layout): an added one is always a thin
    line or a small dot/ring."""
    if shape["tipo"] == "retangulo":
        shape["h"] = min(shape.get("h") or LINE_H[0], LINE_H[1])
        shape["w"] = min(shape.get("w") or LINE_W[0], LINE_W[1])
    else:
        shape.pop("w", None)
        shape.pop("h", None)
        shape["d"] = min(shape.get("d") or DOT_D[0], DOT_D[1])


def _apply_weights(doc, op):
    """Box: size of each child. `repetir`: size of each element inside ONE item (`pesos_item`)."""
    box, _ = _find(doc.get("elementos"), op["caixa"], doc)
    if box is None or box.get("tipo") not in ("caixa", "repetir"):
        return f"no box or repetir named {op['caixa']!r}"
    field = "pesos" if box["tipo"] == "caixa" else "pesos_item"
    kids = len(_children(box))
    if len(op["pesos"]) != kids:
        return f"{box['tipo']} {op['caixa']!r} has {kids} children: send {kids} weights"
    box[field] = op["pesos"]
    return None


_APPLY = {"style": _apply_style, "motion": _apply_motion, "add": _apply_add, "weights": _apply_weights}


def _label(op):
    return f"{op['op']} {op.get('nome') or op.get('alvo') or op.get('caixa')}"


def apply(base: dict, patch: Patch) -> tuple[dict, list[str]]:
    """→ (document with the accepted ops, refusals as text for the model). Base unchanged."""
    doc = copy.deepcopy(base)
    doc.pop("_added", None)
    refused = []
    for item in patch.ops:
        op = item.model_dump(mode="json", exclude_unset=True)
        attempt = copy.deepcopy(doc)
        problem = _APPLY[op["op"]](attempt, op)
        if problem is None:
            try:
                N1EC.Piece.model_validate({k: v for k, v in attempt.items() if k != "_added"})
            except ValidationError as e:
                first = e.errors()[0]
                problem = f"{first['msg']} at {'.'.join(str(x) for x in first['loc'][-3:])}"
        if problem is None:
            doc = attempt
        else:
            refused.append(f"op refused ({_label(op)}): {problem}")
    doc.pop("_added", None)
    return doc, refused
