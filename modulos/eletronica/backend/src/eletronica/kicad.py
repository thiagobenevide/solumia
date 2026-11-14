"""Leitor de bibliotecas de símbolos do KiCad (`.kicad_sym`, KiCad 6 a 9) para o formato de
`biblioteca.py`. O KiCad usa mm com y para cima; aqui vira µm com y para baixo. O pino do KiCad tem
a ponta em `at` e o ângulo aponta para o corpo (0 direita, 90 cima, 180 esquerda, 270 baixo), igual
ao nosso `dir`. Símbolos com várias unidades (amp-op duplo, portas lógicas) viram um símbolo por
unidade (`<lib>:<nome>:<n>`), cada um com o desenho comum (unidade 0); o estilo De Morgan (2) fica
de fora. `extends` herda o desenho do pai."""

import math
import re
from typing import Any

Sexp = list[Any]

TIPOS_PINO = {
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
DIRECOES = {0: "d", 90: "c", 180: "e", 270: "b"}


class ArquivoInvalido(Exception):
    pass


class _Atomo(str):
    """Palavra sem aspas (diferencia `hide` de `"hide"`)."""


_TOKEN = re.compile(r'\s*(?:(\()|(\))|"((?:[^"\\]|\\.)*)"|([^\s()"]+))', re.S)


def ler_sexp(texto: str) -> Sexp:
    pilha: list[Sexp] = [[]]
    pos, fim = 0, len(texto)
    while pos < fim:
        m = _TOKEN.match(texto, pos)
        if not m:
            if texto[pos:].strip():
                raise ArquivoInvalido(f"Caractere inesperado na posição {pos}")
            break
        pos = m.end()
        abre, fecha, cadeia, atomo = m.groups()
        if abre:
            pilha.append([])
        elif fecha:
            if len(pilha) < 2:
                raise ArquivoInvalido("Parêntese fechando sem abrir")
            feito = pilha.pop()
            pilha[-1].append(feito)
        elif cadeia is not None:
            pilha[-1].append(re.sub(r"\\(.)", r"\1", cadeia))
        elif atomo is not None:
            pilha[-1].append(_Atomo(atomo))
    if len(pilha) != 1 or len(pilha[0]) != 1 or not isinstance(pilha[0][0], list):
        raise ArquivoInvalido("Arquivo não é uma expressão S completa")
    return pilha[0][0]


def _filhos(no: Sexp, nome: str) -> list[Sexp]:
    return [f for f in no[1:] if isinstance(f, list) and f and f[0] == nome]


def _filho(no: Sexp, nome: str) -> Sexp | None:
    achados = _filhos(no, nome)
    return achados[0] if achados else None


def _oculto(no: Sexp | None) -> bool:
    """`hide` solto (KiCad 6–7) ou `(hide yes)` (KiCad 8+)."""
    if no is None:
        return False
    if any(isinstance(f, _Atomo) and f == "hide" for f in no[1:]):
        return True
    h = _filho(no, "hide")
    return h is not None and (len(h) == 1 or h[1] == "yes")


def _um(v: Any) -> int:
    return round(float(v) * 1000)


def _xy(no: Sexp, i: int = 1) -> list[int]:
    """[x, y] em µm com y para baixo a partir de `(at x y …)`, `(start x y)` etc."""
    return [_um(no[i]), -_um(no[i + 1])]


def _preenchido(no: Sexp) -> bool:
    fill = _filho(no, "fill")
    tipo = _filho(fill, "type") if fill else None
    return bool(tipo and tipo[1] == "outline")


def _arco(inicio: list[int], meio: list[int], fim: list[int]) -> dict[str, Any] | None:
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


def _bezier(pts: list[list[int]], passos: int = 12) -> list[list[int]]:
    if len(pts) != 4:
        return pts
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = pts
    saida = []
    for i in range(passos + 1):
        t = i / passos
        a, b, c, d = (1 - t) ** 3, 3 * t * (1 - t) ** 2, 3 * t * t * (1 - t), t**3
        saida.append(
            [round(a * x0 + b * x1 + c * x2 + d * x3), round(a * y0 + b * y1 + c * y2 + d * y3)]
        )
    return saida


def _primitiva(no: Sexp) -> dict[str, Any] | None:
    match no[0]:
        case "rectangle":
            a, b = _filho(no, "start"), _filho(no, "end")
            if a and b:
                return {"t": "ret", "a": _xy(a), "b": _xy(b), "cheio": _preenchido(no)}
        case "polyline" | "bezier":
            pts_no = _filho(no, "pts")
            pts = [_xy(p) for p in _filhos(pts_no, "xy")] if pts_no else []
            if no[0] == "bezier":
                pts = _bezier(pts)
            if len(pts) >= 2:
                cheia = _preenchido(no)
                fechada = cheia or pts[0] == pts[-1]
                return {"t": "linha", "p": pts, "fechada": fechada, "cheia": cheia}
        case "circle":
            c, r = _filho(no, "center"), _filho(no, "radius")
            if c and r:
                return {"t": "circ", "c": _xy(c), "r": _um(r[1]), "cheio": _preenchido(no)}
        case "arc":
            a, m, b = _filho(no, "start"), _filho(no, "mid"), _filho(no, "end")
            if a and m and b:
                return _arco(_xy(a), _xy(m), _xy(b))
        case "text":
            at = _filho(no, "at")
            if at and isinstance(no[1], str):
                return {"t": "texto", "p": _xy(at), "s": no[1]}
    return None


def _pino(no: Sexp) -> dict[str, Any] | None:
    at, comp = _filho(no, "at"), _filho(no, "length")
    nome, numero = _filho(no, "name"), _filho(no, "number")
    if not (at and numero):
        return None
    angulo = round(float(at[3]) if len(at) > 3 else 0) % 360
    rotulo = nome[1] if nome and isinstance(nome[1], str) else ""
    return {
        "n": str(numero[1]),
        "nome": "" if rotulo == "~" else rotulo,
        "x": _um(at[1]),
        "y": -_um(at[2]),
        "dir": DIRECOES.get(angulo, "d"),
        "comp": _um(comp[1]) if comp else 0,
        "tipo": TIPOS_PINO.get(str(no[1]), "passivo"),
        "oculto": _oculto(no),
    }


def _propriedades(no: Sexp) -> dict[str, tuple[str, list[int] | None]]:
    props = {}
    for p in _filhos(no, "property"):
        if len(p) >= 3 and isinstance(p[1], str):
            at = _filho(p, "at")
            props[p[1]] = (str(p[2]), _xy(at) if at else None)
    return props


def _unidades(no: Sexp, nome: str) -> dict[int, list[Sexp]]:
    """Corpo de cada unidade (`<nome>_<unidade>_<estilo>`), só o estilo normal."""
    unidades: dict[int, list[Sexp]] = {}
    for sub in _filhos(no, "symbol"):
        partes = str(sub[1]).rsplit("_", 2)
        if len(partes) != 3 or not (partes[1].isdigit() and partes[2].isdigit()):
            continue
        unidade, estilo = int(partes[1]), int(partes[2])
        if estilo in (0, 1):
            unidades.setdefault(unidade, []).extend(f for f in sub[1:] if isinstance(f, list))
    return unidades


def _converter(
    lib: str, nome: str, no: Sexp, corpo: dict[int, list[Sexp]], props: dict[str, Any]
) -> list[dict[str, Any]]:
    ref, pos_ref = props.get("Reference", ("U", None))
    valor, pos_valor = props.get("Value", (nome, None))
    alimentacao = _filho(no, "power") is not None
    nomes = not _oculto(_filho(no, "pin_names"))
    numeros = not _oculto(_filho(no, "pin_numbers"))
    comuns = corpo.get(0, [])
    numeradas = sorted(u for u in corpo if u > 0) or [0]
    saida = []
    for u in numeradas:
        itens = comuns + (corpo.get(u, []) if u else [])
        desenho = [p for p in map(_primitiva, (i for i in itens if i[0] != "pin")) if p]
        pinos = [p for p in map(_pino, (i for i in itens if i[0] == "pin")) if p]
        if not pinos and not desenho:
            continue
        varias = len(numeradas) > 1
        saida.append(
            {
                "id": f"{lib}:{nome}" + (f":{u}" if varias else ""),
                "nome": nome + (f" ({chr(64 + u)})" if varias else ""),
                "categoria": lib,
                "prefixo": ref.rstrip("?") or "U",
                "tipo": "alimentacao" if alimentacao else "componente",
                "valor": valor,
                "encapsulamento": props.get("Footprint", ("", None))[0],
                "descricao": props.get("Description", props.get("ki_description", ("", None)))[0],
                "palavras": props.get("ki_keywords", ("", None))[0],
                "desenho": desenho,
                "pinos": pinos,
                "campos": {"ref": pos_ref or [0, -2540], "valor": pos_valor or [0, 2540]},
                "nomes_pinos": nomes,
                "numeros_pinos": numeros,
            }
        )
    return saida


def ler_biblioteca(texto: str, lib: str) -> list[dict[str, Any]]:
    """Todos os símbolos de um `.kicad_sym`, já convertidos. [lib] vira a categoria e o prefixo
    do id."""
    raiz = ler_sexp(texto)
    if not raiz or raiz[0] != "kicad_symbol_lib":
        raise ArquivoInvalido("Não é uma biblioteca de símbolos do KiCad (kicad_symbol_lib)")
    nos = {str(s[1]): s for s in _filhos(raiz, "symbol") if len(s) > 1}
    corpos = {n: _unidades(s, n) for n, s in nos.items()}

    def corpo(nome: str, profundidade: int = 0) -> tuple[dict[int, list[Sexp]], dict[str, Any]]:
        no = nos[nome]
        props = _propriedades(no)
        pai = _filho(no, "extends")
        if pai and str(pai[1]) in nos and profundidade < 8:
            corpo_pai, props_pai = corpo(str(pai[1]), profundidade + 1)
            return corpo_pai, {**props_pai, **props}
        return corpos[nome], props

    simbolos = []
    for nome, no in nos.items():
        c, props = corpo(nome)
        simbolos.extend(_converter(lib, nome, no, c, props))
    return simbolos
