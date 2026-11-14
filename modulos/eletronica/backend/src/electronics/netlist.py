"""Schematic electrical connections (netlist) and bill of materials (BOM). Connects at the same
point of the same sheet: pins, wire ends and wire corners. A wire end (or a pin) landing in the
middle of another wire also connects (T-junction); wires that only cross do not. Labels with the
same name and power symbols with the same value connect nets across sheets. The pin position math
is the same as the app's (`posicaoPino` in `modelos.dart`): mirrors in x, rotates in 90° steps
clockwise on screen (y down) and adds the component position."""

import csv
import io
import re
from typing import Any

from electronics.library import POR_ID
from electronics.projects import SearchSymbol

Point = tuple[str, int, int]  # (sheet, x, y)


def position_pin(c: dict[str, Any], pin: dict[str, Any]) -> tuple[int, int]:
    x, y = pin["x"], pin["y"]
    if c.get("espelho"):
        x = -x
    for _ in range(c.get("rot", 0) // 90):
        x, y = -y, x
    return c["x"] + x, c["y"] + y


class _Union:
    def __init__(self) -> None:
        self.pai: dict[Any, Any] = {}

    def achar(self, a: Any) -> Any:
        self.pai.setdefault(a, a)
        while self.pai[a] != a:
            self.pai[a] = self.pai[self.pai[a]]
            a = self.pai[a]
        return a

    def unir(self, a: Any, b: Any) -> None:
        self.pai[self.achar(a)] = self.achar(b)


def _in_segment(p: tuple[int, int], a: list[int], b: list[int]) -> bool:
    (x, y), (x1, y1), (x2, y2) = p, a, b
    if (x2 - x1) * (y - y1) != (y2 - y1) * (x - x1):
        return False
    return min(x1, x2) <= x <= max(x1, x2) and min(y1, y2) <= y <= max(y1, y2)


def _key_natural(ref: str) -> list[Any]:
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", ref)]


def netlist(project: dict[str, Any], symbol: SearchSymbol = POR_ID.get) -> dict[str, Any]:
    """`redes` [{nome, pinos: [{ref, pino, nome}]}], `soltos` (unconnected pins) and `sondas`
    [{id, tipo, rede | ref}]: the net each voltage probe touches (None if nothing)."""
    u = _Union()
    pins: list[tuple[Point, dict[str, Any], dict[str, Any]]] = []
    names: dict[Any, set[str]] = {}

    def nomear(no: Any, nome: str) -> None:
        u.unir(no, ("nome", nome))
        names.setdefault(("nome", nome), set()).add(nome)

    for c in project.get("componentes", []):
        simb = symbol(c["simbolo"])
        if simb is None:
            continue
        for pin in simb["pinos"]:
            point = (c["folha"], *position_pin(c, pin))
            u.achar(point)
            if simb["tipo"] == "alimentacao":
                nomear(point, c.get("valor") or simb["valor"])
            else:
                pins.append((point, c, pin))

    fios = project.get("fios", [])
    for f in fios:
        cantos = [(f["folha"], x, y) for x, y in f["pontos"]]
        for a in cantos[1:]:
            u.unir(cantos[0], a)
    # Wire ends and pins in the middle of a wire on the same sheet.
    pontas = [(f["folha"], *f["pontos"][i]) for f in fios for i in (0, -1)]
    pontas += [p for p, _, _ in pins]
    sondas_v = [s for s in project.get("sondas", []) if s.get("tipo") == "v"]
    for s in sondas_v:
        point = (s["folha"], s["x"], s["y"])
        u.achar(point)
        pontas.append(point)
    for f in fios:
        owner = (f["folha"], *f["pontos"][0])
        for sheet, x, y in pontas:
            if sheet != f["folha"]:
                continue
            pts = f["pontos"]
            if any(_in_segment((x, y), pts[i], pts[i + 1]) for i in range(len(pts) - 1)):
                u.unir((sheet, x, y), owner)

    for r in project.get("rotulos", []):
        nomear((r["folha"], r["x"], r["y"]), r["nome"].strip())

    groups: dict[Any, list[dict[str, Any]]] = {}
    for point, c, pin in pins:
        groups.setdefault(u.achar(point), []).append(
            {"ref": c.get("ref", "?"), "pino": pin["n"], "nome": pin["nome"]}
        )
    name_of: dict[Any, str] = {}
    for key, conj in names.items():
        name_of.setdefault(u.achar(key), sorted(conj)[0])

    redes, loose, anonimas = [], [], 0
    name_root: dict[Any, str] = dict(name_of)
    for root, items in sorted(
        groups.items(), key=lambda kv: _key_natural(min(p["ref"] for p in kv[1]))
    ):
        items.sort(key=lambda p: (_key_natural(p["ref"]), _key_natural(p["pino"])))
        nome = name_of.get(root)
        if nome is None:
            if len(items) == 1:
                loose.extend(items)
                continue
            anonimas += 1
            nome = f"N${anonimas}"
        name_root[root] = nome
        redes.append({"nome": nome, "pinos": items})
    redes.sort(key=lambda r: _key_natural(r["nome"]))
    sondas = [
        {"id": s["id"], "tipo": "v", "rede": name_root.get(u.achar((s["folha"], s["x"], s["y"])))}
        for s in sondas_v
    ] + [
        {"id": s["id"], "tipo": "i", "ref": s.get("ref", "")}
        for s in project.get("sondas", [])
        if s.get("tipo") == "i"
    ]
    return {"redes": redes, "soltos": loose, "sondas": sondas}


def bom(project: dict[str, Any], symbol: SearchSymbol = POR_ID.get) -> list[dict[str, Any]]:
    """One line per symbol + value + footprint, with the references in natural order.
    Units of the same IC (U1 A, U1 B) count once."""
    lines: dict[tuple[str, str, str], list[str]] = {}
    for c in project.get("componentes", []):
        simb = symbol(c["simbolo"])
        if simb is not None and simb["tipo"] != "componente":
            continue
        name = simb["nome"].split(" (")[0] if simb else c["simbolo"]
        key = (name, c.get("valor", ""), c.get("encapsulamento", ""))
        refs = lines.setdefault(key, [])
        if c.get("ref", "?") not in refs:
            refs.append(c.get("ref", "?"))
    output = [
        {
            "refs": sorted(refs, key=_key_natural),
            "quantidade": len(refs),
            "descricao": name,
            "valor": value,
            "encapsulamento": enc,
        }
        for (name, value, enc), refs in lines.items()
    ]
    return sorted(output, key=lambda line: _key_natural(line["refs"][0]))


def bom_csv(project: dict[str, Any], symbol: SearchSymbol = POR_ID.get) -> str:
    output = io.StringIO()
    w = csv.writer(output)
    w.writerow(["Referências", "Quantidade", "Descrição", "Valor", "Encapsulamento"])
    for line in bom(project, symbol):
        w.writerow(
            [
                " ".join(line["refs"]),
                line["quantidade"],
                line["descricao"],
                line["valor"],
                line["encapsulamento"],
            ]
        )
    return output.getvalue()
