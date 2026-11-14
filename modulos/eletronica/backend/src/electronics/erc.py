"""Electrical rule check of the schematic (ERC). Uses the same connections as `netlist.py` (pins,
wire ends and wire T-junctions on the same sheet; labels and power symbols connect across sheets)
and
returns a list of problems `{nivel: "erro"|"aviso", codigo, mensagem, refs, pinos, rede, folha, x,
y}`
(position in µm when the problem has a point). Units of the same IC (`<lib>:<nome>:<n>`)
may repeat the ref."""

from typing import Any

from electronics.library import POR_ID
from electronics.netlist import _in_segment, _Union, netlist, position_pin
from electronics.projects import SearchSymbol

ORDER = {"erro": 0, "aviso": 1}


def _problem(
    nivel: str,
    code: str,
    mensagem: str,
    pins: list[dict[str, Any]] | None = None,
    refs: list[str] | None = None,
    rede: str | None = None,
    ponto: tuple[str, int, int] | None = None,
) -> dict[str, Any]:
    pins = pins or []
    p: dict[str, Any] = {
        "nivel": nivel,
        "codigo": code,
        "mensagem": mensagem,
        "refs": refs if refs is not None else sorted({x["ref"] for x in pins}),
        "pinos": pins,
        "rede": rede,
    }
    if ponto is not None:
        p["folha"], p["x"], p["y"] = ponto
    return p


def _is_source(simb: dict[str, Any]) -> bool:
    return simb.get("categoria") == "Fontes" or simb.get("prefixo") in ("V", "BT")


def _unit(id_: str) -> tuple[str, str] | None:
    """(`<lib>:<nome>`, `<n>`) for multi-unit symbols; otherwise None."""
    parts = id_.split(":")
    if len(parts) == 3 and parts[2].isdigit():
        return f"{parts[0]}:{parts[1]}", parts[2]
    return None


def erc(project: dict[str, Any], symbol: SearchSymbol = POR_ID.get) -> list[dict[str, Any]]:
    u = _Union()
    components = project.get("componentes", [])
    fios = project.get("fios", [])
    labels = project.get("rotulos", [])
    # (point, component, pin) of the symbols that are not power symbols.
    pins: list[tuple[tuple[str, int, int], dict[str, Any], dict[str, Any]]] = []
    points_pin: set[tuple[str, int, int]] = set()
    alimentados: set[Any] = set()  # nodes with a power symbol
    sources: list[tuple[str, int, int]] = []
    names_nutrition: set[str] = set()

    for c in components:
        simb = symbol(c["simbolo"])
        if simb is None:
            continue
        for pin in simb["pinos"]:
            point = (c["folha"], *position_pin(c, pin))
            u.achar(point)
            points_pin.add(point)
            if simb["tipo"] == "alimentacao":
                name = c.get("valor") or simb["valor"]
                names_nutrition.add(name)
                u.unir(point, ("nome", name))
                alimentados.add(point)
            else:
                pins.append((point, c, pin))
                if _is_source(simb):
                    sources.append(point)

    for f in fios:
        cantos = [(f["folha"], x, y) for x, y in f["pontos"]]
        for a in cantos[1:]:
            u.unir(cantos[0], a)
    pontas = [(f["folha"], *f["pontos"][i]) for f in fios for i in (0, -1)]
    pontas += [p for p, _, _ in pins]
    for f in fios:
        owner = (f["folha"], *f["pontos"][0])
        pts = f["pontos"]
        for sheet, x, y in pontas:
            if sheet == f["folha"] and any(
                _in_segment((x, y), pts[i], pts[i + 1]) for i in range(len(pts) - 1)
            ):
                u.unir((sheet, x, y), owner)

    names_label: dict[str, int] = {}
    root_label: dict[Any, str] = {}
    for r in labels:
        name = r["nome"].strip()
        point = (r["folha"], r["x"], r["y"])
        u.unir(point, ("nome", name))
        names_label[name] = names_label.get(name, 0) + 1

    for r in labels:
        root_label.setdefault(u.achar(("nome", r["nome"].strip())), r["nome"].strip())
    roots_alimentadas = {u.achar(p) for p in alimentados}
    roots_source = {u.achar(p) for p in sources}

    # Net name equal to the netlist one (same N$k order).
    name_of: dict[tuple[str, str], str] = {}
    for rede in netlist(project, symbol)["redes"]:
        for x in rede["pinos"]:
            name_of.setdefault((x["ref"], x["pino"]), rede["nome"])

    groups: dict[Any, list[tuple[tuple[str, int, int], dict[str, Any], dict[str, Any]]]] = {}
    for item in pins:
        groups.setdefault(u.achar(item[0]), []).append(item)

    def info(c: dict[str, Any], pin: dict[str, Any]) -> dict[str, Any]:
        return {"ref": c.get("ref", "?"), "pino": pin["n"], "nome": pin["nome"]}

    def rotulo_pino(c: dict[str, Any], pin: dict[str, Any]) -> str:
        name = f" ({pin['nome']})" if pin["nome"] else ""
        return f"{c.get('ref', '?')} pino {pin['n']}{name}"

    problems: list[dict[str, Any]] = []
    for root, items in groups.items():
        primeiro = items[0]
        rede = name_of.get((primeiro[1].get("ref", "?"), primeiro[2]["n"]))
        alimentada = root in roots_alimentadas
        rotulada = root in root_label
        if len(items) == 1:
            point, c, pin = primeiro
            if rotulada and not alimentada:
                problems.append(
                    _problem(
                        "aviso",
                        "rede_um_pino",
                        f"A rede {root_label[root]} liga só {rotulo_pino(c, pin)}.",
                        [info(c, pin)],
                        rede=root_label[root],
                        ponto=point,
                    )
                )
            elif not rotulada and not alimentada and pin.get("tipo") != "nc":
                problems.append(
                    _problem(
                        "erro",
                        "pino_solto",
                        f"{rotulo_pino(c, pin)} não está ligado a nada.",
                        [info(c, pin)],
                        ponto=point,
                    )
                )
        saidas = [(p, c, pin) for p, c, pin in items if pin.get("tipo") == "saida"]
        if len(saidas) >= 2:
            problems.append(
                _problem(
                    "erro",
                    "saidas_em_curto",
                    f"{len(saidas)} saídas ligadas na mesma rede {rede}: "
                    + ", ".join(rotulo_pino(c, pin) for _, c, pin in saidas)
                    + ".",
                    [info(c, pin) for _, c, pin in saidas],
                    rede=rede,
                    ponto=saidas[0][0],
                )
            )
        kinds = {pin.get("tipo") for _, _, pin in items}
        if len(items) >= 2 and kinds == {"entrada"} and not alimentada:
            problems.append(
                _problem(
                    "erro",
                    "entrada_sem_acionamento",
                    f"A rede {rede} só liga entradas; nada a aciona.",
                    [info(c, pin) for _, c, pin in items],
                    rede=rede,
                    ponto=primeiro[0],
                )
            )
        if not alimentada and root not in roots_source:
            for point, c, pin in items:
                if pin.get("tipo") == "alimentacao":
                    problems.append(
                        _problem(
                            "aviso",
                            "alimentacao_sem_fonte",
                            f"{rotulo_pino(c, pin)} é de alimentação, mas a rede não tem "
                            "símbolo de alimentação nem fonte.",
                            [info(c, pin)],
                            rede=rede,
                            ponto=point,
                        )
                    )

    # Repeated references (except power symbols and different units of the same IC).
    by_ref: dict[str, list[dict[str, Any]]] = {}
    for c in components:
        simb = symbol(c["simbolo"])
        if simb is not None and simb["tipo"] != "componente":
            continue
        by_ref.setdefault(c.get("ref", "?"), []).append(c)
    for ref, items in by_ref.items():
        if len(items) < 2:
            continue
        units = [_unit(c["simbolo"]) for c in items]
        if (
            all(units)
            and len({un[0] for un in units if un}) == 1
            and len({un[1] for un in units if un}) == len(units)
        ):
            continue
        c = items[1]
        problems.append(
            _problem(
                "erro",
                "ref_duplicada",
                f"A referência {ref} aparece {len(items)} vezes.",
                refs=[ref],
                ponto=(c["folha"], c["x"], c["y"]),
            )
        )

    by_position: dict[tuple[str, int, int], list[dict[str, Any]]] = {}
    for c in components:
        by_position.setdefault((c["folha"], c["x"], c["y"]), []).append(c)
    for point, items in by_position.items():
        if len(items) >= 2:
            refs = [c.get("ref", "?") for c in items]
            problems.append(
                _problem(
                    "erro",
                    "componentes_sobrepostos",
                    f"Componentes um em cima do outro: {', '.join(refs)}.",
                    refs=refs,
                    ponto=point,
                )
            )

    points_label = {(r["folha"], r["x"], r["y"]) for r in labels}
    for f in fios:
        for i in (0, -1):
            ponta = (f["folha"], *f["pontos"][i])
            if ponta in points_pin or ponta in points_label:
                continue
            if any(
                g is not f
                and g["folha"] == f["folha"]
                and any(
                    _in_segment(ponta[1:], g["pontos"][k], g["pontos"][k + 1])
                    for k in range(len(g["pontos"]) - 1)
                )
                for g in fios
            ):
                continue
            problems.append(
                _problem(
                    "aviso",
                    "fio_solto",
                    "Ponta de fio que não liga a nada.",
                    refs=[],
                    ponto=ponta,
                )
            )

    for r in labels:
        name = r["nome"].strip()
        if names_label.get(name) == 1 and name not in names_nutrition:
            problems.append(
                _problem(
                    "aviso",
                    "rotulo_unico",
                    f"O rótulo {name} aparece uma vez só no projeto.",
                    refs=[],
                    rede=name,
                    ponto=(r["folha"], r["x"], r["y"]),
                )
            )

    problems.sort(key=lambda p: ORDER[p["nivel"]])
    return problems
