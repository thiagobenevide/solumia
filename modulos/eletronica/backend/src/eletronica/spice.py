"""Netlist SPICE de um projeto e leitura do resultado do ngspice (arquivo raw).

GND (e variações como AGND, GNDA) e "0" viram o nó 0; as outras redes ganham nomes saneados e o mapa
`nos` (nó em minúsculas → rede) devolve os nomes do esquemático no resultado. Componentes sem modelo
entram como comentário e voltam em `ignorados`.
"""

import cmath
import math
import re
import struct
from typing import Any

from eletronica.library import POR_ID
from eletronica.netlist import netlist
from eletronica.projects import SearchSymbol

ANALYSES = ("op", "tran", "ac", "dc")

# --- Valores --------------------------------------------------------------------------------------

_PREFIXES = {
    "p": "p",
    "n": "n",
    "u": "u",
    "µ": "u",
    "μ": "u",
    "m": "m",
    "k": "k",
    "K": "k",
    "M": "Meg",
    "G": "G",
    "T": "T",
}
_FACTOR = {
    "f": 1e-15,
    "p": 1e-12,
    "n": 1e-9,
    "u": 1e-6,
    "m": 1e-3,
    "k": 1e3,
    "meg": 1e6,
    "g": 1e9,
    "t": 1e12,
}
_UNIT = r"(?:ohms?|Ω|Hz|F|H|V|A|s|W)?"
# "4u7", "4k7", "10k", "2.2nF", "1mA", "1M" (mega, como no esquemático).
_COM_PREFIX = re.compile(rf"([+-]?\d+(?:[.,]\d+)?)\s*((?i:meg)|[pnuµμmkKMGT])?(\d+)?\s*{_UNIT}")
# "1R5", "5V1", "0Ω47": a letra é a vírgula e não multiplica.
_LETTER_COMMA = re.compile(r"([+-]?\d+)[RrVvΩ](\d+)")
_EXPONENT = re.compile(rf"([+-]?\d+(?:\.\d+)?[eE][+-]?\d+)\s*{_UNIT}")


def value_spice(text: str) -> str | None:
    """Valor do esquemático em notação SPICE ("4u7" → "4.7u", "1M" → "1Meg", "5V" → "5")."""
    t = text.strip()
    if m := _LETTER_COMMA.fullmatch(t):
        return f"{m[1]}.{m[2]}"
    if m := _EXPONENT.fullmatch(t):
        return m[1]
    m = _COM_PREFIX.fullmatch(t)
    if not m:
        return None
    number, prefix, rest = m[1].replace(",", "."), m[2] or "", m[3]
    if rest and "." in number:
        return None
    suffix = "Meg" if prefix.lower() == "meg" else _PREFIXES.get(prefix, "")
    return f"{number}{'.' + rest if rest else ''}{suffix}"


def number(spice: str) -> float:
    """Número de um valor já em notação SPICE ("4.7u" → 4.7e-6)."""
    m = re.fullmatch(r"([+-]?[\d.]+(?:[eE][+-]?\d+)?)(meg|[fpnumkgt])?", spice.strip(), re.I)
    if not m:
        raise ValueError(f"Valor inválido: {spice}")
    return float(m[1]) * _FACTOR.get((m[2] or "").lower(), 1.0)


def _source(text: str) -> str | None:
    """Especificação de fonte: "5V" → "DC 5"; "SIN(0 1V 1kHz)" → "SIN(0 1 1k)"; "DC 5 AC 1"."""
    t = text.strip()
    if (v := value_spice(t)) is not None:
        return f"DC {v}"
    if not re.match(r"(DC|AC|SIN|PULSE|PWL|EXP|SFFM)\b|(SIN|PULSE|PWL|EXP|SFFM)\(", t, re.I):
        return None

    def trocar(m: re.Match[str]) -> str:
        return value_spice(m[0]) or m[0]

    return re.sub(r"[^\s(),]+", trocar, t)


# --- Classificação dos símbolos -------------------------------------------------------------------

_BASE = {
    "resistor": "R",
    "capacitor": "C",
    "capacitor_polarizado": "C",
    "indutor": "L",
    "diodo": "D",
    "zener": "DZ",
    "schottky": "DS",
    "led": "LED",
    "npn": "NPN",
    "pnp": "PNP",
    "nmos": "NMOS",
    "pmos": "PMOS",
    "amp_op": "AMPOP",
    "fonte_tensao": "V",
    "bateria": "V",
    "fonte_corrente": "I",
}
_DEVICE = (
    (r"R(_Small)?(_US)?", "R"),
    (r"C(_Small)?|CP(_Small)?|C_Polarized.*", "C"),
    (r"L(_Small)?|L_Core.*", "L"),
    (r"LED(_Small)?", "LED"),
    (r"D_Zener.*", "DZ"),
    (r"D_Schottky.*", "DS"),
    (r"D(_Small)?", "D"),
    (r"Q_NPN_.*", "NPN"),
    (r"Q_PNP_.*", "PNP"),
    (r"Q_NMOS_.*", "NMOS"),
    (r"Q_PMOS_.*", "PMOS"),
    (r"Battery(_Cell)?", "V"),
)


def device_class(simb: dict[str, Any]) -> str | None:
    """Tipo de elemento SPICE do símbolo (base ou importado do KiCad), ou None sem modelo."""
    id_ = simb["id"]
    if id_ in _BASE:
        return _BASE[id_]
    if ":" not in id_:
        return None
    lib, name = id_.split(":")[:2]
    text = f"{name} {simb.get('descricao', '')}".upper()
    if lib == "Device":
        return next((c for default, c in _DEVICE if re.fullmatch(default, name)), None)
    if lib == "Transistor_BJT":
        return "PNP" if "PNP" in text else "NPN"
    if lib == "Transistor_FET":
        if "JFET" in text:
            return None
        return "PMOS" if re.search(r"P-CHANNEL|P-MOS|PMOS", text) else "NMOS"
    if lib == "Diode":
        return "DZ" if "ZENER" in text else "DS" if "SCHOTTKY" in text else "D"
    if lib == "Simulation_SPICE":
        return {"V": "V", "I": "I", "D": "D"}.get(name[:1])
    if lib == "Amplifier_Operational":
        return "AMPOP"
    return None


# Terminais por tipo: pelo nome do pino; sem nome, pelo número.
_TERMINALS: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "R": ((), ("1", "2")),
    "C": (("+", "-"), ("1", "2")),
    "L": ((), ("1", "2")),
    "D": (("A", "K"), ("2", "1")),
    "Q": (("C", "B", "E"), ()),
    "M": (("D", "G", "S"), ()),
    "V": (("+", "-"), ("1", "2")),
    "I": ((), ("1", "2")),
}
_LETTER = {
    "R": "R",
    "C": "C",
    "L": "L",
    "D": "D",
    "DZ": "D",
    "DS": "D",
    "LED": "D",
    "NPN": "Q",
    "PNP": "Q",
    "NMOS": "M",
    "PMOS": "M",
    "V": "V",
    "I": "I",
    "AMPOP": "X",
}

# --- Modelos padrão -------------------------------------------------------------------------------

_MODELS = {
    "D1N4148": ".model D1N4148 D(IS=2.52n RS=0.568 N=1.752 CJO=4p M=0.4 TT=20n BV=100 IBV=100u)",
    "DSCHOTTKY": ".model DSCHOTTKY D(IS=1u RS=0.05 N=1.05 CJO=100p M=0.5 BV=40 IBV=1m)",
    "LED_VERMELHO": ".model LED_VERMELHO D(IS=1e-19 N=1.8 RS=2 BV=5 IBV=10u)",
    "LED_VERDE": ".model LED_VERDE D(IS=1e-21 N=2 RS=2 BV=5 IBV=10u)",
    "LED_AZUL": ".model LED_AZUL D(IS=1e-22 N=2.6 RS=2 BV=5 IBV=10u)",
    "BC547": ".model BC547 NPN(IS=1.8e-14 BF=400 VAF=80 IKF=0.1 BR=35 CJC=5p CJE=11p TF=0.4n)",
    "BC557": ".model BC557 PNP(IS=1e-14 BF=300 VAF=60 IKF=0.1 BR=10 CJC=7p CJE=12p TF=0.5n)",
    "NMOS_GEN": ".model NMOS_GEN NMOS(LEVEL=1 VTO=1.2 KP=10 LAMBDA=0.01 CGSO=1n CGDO=0.3n)",
    "PMOS_GEN": ".model PMOS_GEN PMOS(LEVEL=1 VTO=-1.2 KP=5 LAMBDA=0.01 CGSO=1n CGDO=0.3n)",
}
# Op-amp quase ideal: ganho 1e5 com polo em ~10 Hz (GBW ~1 MHz), saturação 0,2 V dentro dos trilhos.
_SUBCIRCUITS = {
    "AMPOP": """.subckt AMPOP inp inn out vcc vee
Rin inp inn 10Meg
G1 0 n1 inp inn 1
R1 n1 0 1e5
C1 n1 0 159n
B1 n2 0 V = max(min(V(n1), V(vcc)-0.2), V(vee)+0.2)
Rout n2 out 50
.ends AMPOP""",
    "AMPOP_SEM_ALIM": """.subckt AMPOP_SEM_ALIM inp inn out
Rin inp inn 10Meg
G1 0 n1 inp inn 1
R1 n1 0 1e5
C1 n1 0 159n
B1 n2 0 V = max(min(V(n1), 15), -15)
Rout n2 out 50
.ends AMPOP_SEM_ALIM""",
}


def _model_led(valor: str) -> str:
    v = valor.lower()
    if re.search(r"azul|blue|branco|white|uv", v):
        return "LED_AZUL"
    if re.search(r"verde|green", v):
        return "LED_VERDE"
    return "LED_VERMELHO"


def _model_zener(valor: str, models: dict[str, str]) -> str:
    m = re.search(r"(\d+)V(\d*)", valor, re.I)
    bv = float(f"{m[1]}.{m[2] or 0}") if m else 5.1
    name = f"DZ_{bv:g}".replace(".", "V")
    models[name] = f".model {name} D(IS=1n RS=1 N=1.5 BV={bv:g} IBV=1m CJO=50p)"
    return name


# --- Geração --------------------------------------------------------------------------------------


def is_ground(rede: str) -> bool:
    return bool(re.fullmatch(r"0|[ADP]?GND\w*", rede.strip().upper()))


def _sanitized(text: str) -> str:
    t = text.strip()
    t = re.sub(r"^\+", "P", re.sub(r"^-", "N", t))
    return re.sub(r"\W", "_", t) or "_"


def _parameters(analise: str, p: dict[str, Any], sources: dict[str, str]) -> str:
    def valor(chave: str, default: str | None = None) -> str:
        raw = p.get(chave, default)
        if raw is None or str(raw).strip() == "":
            raise ValueError(f"Falta o parâmetro '{chave}' da análise {analise}.")
        v = value_spice(str(raw))
        if v is None:
            raise ValueError(f"Parâmetro '{chave}' inválido: {raw}")
        return v

    if analise == "op":
        return ".op"
    if analise == "tran":
        line = f".tran {valor('passo')} {valor('fim')}"
        if p.get("inicio") not in (None, ""):
            line += f" {valor('inicio')}"
        if number(valor("passo")) <= 0 or number(valor("fim")) <= 0:
            raise ValueError("Passo e fim do transiente precisam ser maiores que zero.")
        return line
    if analise == "ac":
        try:
            points = int(p.get("pontos", 20))
        except (TypeError, ValueError) as e:
            raise ValueError("Pontos da análise AC devem ser um número inteiro.") from e
        if not 1 <= points <= 10_000:
            raise ValueError("Pontos da análise AC devem ficar entre 1 e 10000.")
        return f".ac dec {points} {valor('inicio', '1')} {valor('fim', '1Meg')}"
    if analise == "dc":
        ref = str(p.get("fonte", "")).strip()
        element = sources.get(ref.upper())
        if element is None:
            raise ValueError(f"Fonte '{ref}' da varredura DC não existe no circuito.")
        return f".dc {element} {valor('inicio')} {valor('fim')} {valor('passo')}"
    raise ValueError(f"Análise desconhecida: {analise} (use {', '.join(ANALYSES)}).")


def generate(
    project: dict[str, Any],
    symbol: SearchSymbol = POR_ID.get,
    analise: str = "op",
    parametros: dict[str, Any] | None = None,
    rede: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """`{texto, ignorados:[{ref, simbolo, motivo}], avisos, nos:{nó: rede}}`.

    [rede] é a netlist já calculada (`netlist()`); sem ela, é calculada do esquemático.
    Levanta ValueError com parâmetros de análise inválidos.
    """
    if analise not in ANALYSES:
        raise ValueError(f"Análise desconhecida: {analise} (use {', '.join(ANALYSES)}).")
    rede = rede if rede is not None else netlist(project, symbol)
    nodes: dict[str, str] = {}  # nó SPICE (minúsculas) → rede
    node_of_rede: dict[str, str] = {}

    def no(name_rede: str) -> str:
        if is_ground(name_rede):
            return "0"
        if name_rede not in node_of_rede:
            base = n = _sanitized(name_rede)
            i = 1
            while n.lower() in nodes or n == "0":
                i += 1
                n = f"{base}_{i}"
            node_of_rede[name_rede] = n
            nodes[n.lower()] = name_rede
        return node_of_rede[name_rede]

    node_of_pin: dict[tuple[str, str], str] = {}
    for r in rede["redes"]:
        for p in r["pinos"]:
            node_of_pin[(p["ref"], p["pino"])] = no(r["nome"])
    for p in rede["soltos"]:
        node_of_pin[(p["ref"], p["pino"])] = no(f"NC_{p['ref']}_{p['pino']}")

    components = [
        (c, s) for c in project.get("componentes", []) if (s := symbol(c["simbolo"])) is not None
    ]
    # Pinos por nome de todas as unidades de cada ref (os trilhos do op-amp ficam noutra unidade).
    by_ref: dict[str, dict[str, str]] = {}
    for c, s in components:
        for p in s["pinos"]:
            if (k := (c.get("ref", "?"), p["n"])) in node_of_pin and p["nome"]:
                by_ref.setdefault(k[0], {})[p["nome"].upper()] = node_of_pin[k]

    lines: list[str] = []
    ignorados: list[dict[str, Any]] = []
    warnings: list[str] = []
    models: dict[str, str] = {}
    subcircuits: set[str] = set()
    used: set[str] = set()
    sources: dict[str, str] = {}  # ref ou elemento (maiúsculas) → elemento V/I
    refs_sources: list[str] = []  # refs das fontes do esquemático (para a varredura DC)
    nodes_with_source: set[str] = set()
    alimentacoes: dict[str, str] = {}
    lines_v: list[int] = []

    def nome_elemento(letter: str, ref: str) -> str:
        base = _sanitized(ref)
        base = base if base.upper().startswith(letter) else letter + base
        name, i = base, 1
        while name.upper() in used:
            i += 1
            name = f"{base}_{i}"
        used.add(name.upper())
        return name

    def ignorar(c: dict[str, Any], s: dict[str, Any], motivo: str) -> None:
        ref = c.get("ref", "?")
        ignorados.append({"ref": ref, "simbolo": s["id"], "motivo": motivo})
        lines.append(f"* ignorado: {ref} ({s['id']}) — {motivo}")

    for c, s in components:
        ref = c.get("ref", "?")
        if s["tipo"] == "alimentacao":
            name_rede = (c.get("valor") or s["valor"]).strip()
            if not is_ground(name_rede):
                alimentacoes[name_rede] = no(name_rede)
            continue
        kind = device_class(s)
        if kind is None:
            ignorar(c, s, "sem modelo SPICE")
            continue
        letter = _LETTER[kind]
        value = str(c.get("valor") or s.get("valor") or "")
        pins = {p["n"]: p for p in s["pinos"]}
        names = {p["nome"].upper(): p["n"] for p in s["pinos"] if p["nome"]}

        if kind == "AMPOP":
            outside = {"+", "-", "V+", "V-"}
            output = [n for n, p in pins.items() if p["nome"].upper() not in outside]
            if "+" not in names or "-" not in names or len(output) != 1:
                if not ({"+", "-"} & names.keys()):
                    continue  # unidade só de alimentação do op-amp
                ignorar(c, s, "pinos do amplificador não reconhecidos")
                continue
            names_node = [
                node_of_pin.get((ref, names["+"])),
                node_of_pin.get((ref, names["-"])),
                node_of_pin.get((ref, output[0])),
            ]
            trilhos = by_ref.get(ref, {})
            sub = "AMPOP_SEM_ALIM"
            if "V+" in trilhos and "V-" in trilhos:
                names_node += [trilhos["V+"], trilhos["V-"]]
                sub = "AMPOP"
            if None in names_node:
                ignorar(c, s, "pino sem ligação")
                continue
            unit = s["id"].split(":")[2] if s["id"].count(":") == 2 else ""
            element = nome_elemento(
                "X", ref + (chr(64 + int(unit)) if unit.isdigit() else "")
            )
            subcircuits.add(sub)
            lines.append(f"{element} {' '.join(str(n) for n in names_node)} {sub}")
            continue

        by_name, by_number = _TERMINALS[letter]
        if by_name and all(n in names for n in by_name):
            terminals = [names[n] for n in by_name]
        elif by_number and all(n in pins for n in by_number):
            terminals = list(by_number)
        else:
            ignorar(c, s, "pinos não reconhecidos")
            continue
        nodes_el = [node_of_pin.get((ref, t)) for t in terminals]
        if None in nodes_el:
            ignorar(c, s, "pino sem ligação")
            continue
        args = " ".join(str(n) for n in nodes_el)

        if letter in "RCL":
            v = value_spice(value)
            if v is None:
                ignorar(c, s, f"valor '{value}' não reconhecido")
                continue
            lines.append(f"{nome_elemento(letter, ref)} {args} {v}")
        elif letter in "VI":
            spec = _source(value)
            if spec is None:
                ignorar(c, s, f"valor de fonte '{value}' não reconhecido")
                continue
            element = nome_elemento(letter, ref)
            sources[ref.upper()] = sources[element.upper()] = element
            refs_sources.append(ref)
            if letter == "V":
                nodes_with_source.update(str(n) for n in nodes_el)
                lines_v.append(len(lines))
            lines.append(f"{element} {args} {spec}")
        elif letter == "D":
            if kind == "LED":
                model = _model_led(value)
            elif kind == "DZ":
                model = _model_zener(value, models)
            else:
                model = "DSCHOTTKY" if kind == "DS" else "D1N4148"
            models.setdefault(model, _MODELS.get(model, ""))
            lines.append(f"{nome_elemento('D', ref)} {args} {model}")
        elif letter == "Q":
            model = "BC557" if kind == "PNP" else "BC547"
            models[model] = _MODELS[model]
            lines.append(f"{nome_elemento('Q', ref)} {args} {model}")
        else:  # M: corpo ligado à fonte
            model = "PMOS_GEN" if kind == "PMOS" else "NMOS_GEN"
            models[model] = _MODELS[model]
            lines.append(f"{nome_elemento('M', ref)} {args} {nodes_el[2]} {model}")

    # Alimentação com tensão no nome (+5V, +3V3, -12V) vira fonte quando nada alimenta a rede.
    for name_rede, n in sorted(alimentacoes.items()):
        if n in nodes_with_source:
            continue
        m = re.fullmatch(r"([+-]?)(\d+)V(\d*)", name_rede, re.I)
        if m is None:
            warnings.append(f"Rede {name_rede} sem fonte de tensão: coloque uma fonte nela.")
            continue
        tensao = f"{m[1] if m[1] == '-' else ''}{m[2]}{'.' + m[3] if m[3] else ''}"
        element = nome_elemento("V", f"ALIM_{n}")
        sources[element.upper()] = element
        lines_v.append(len(lines))
        lines.append(f"{element} {n} 0 DC {tensao}")
        warnings.append(f"Fonte automática de {tensao} V na rede {name_rede}.")

    if analise == "ac" and not any(re.search(r"(?i)\bAC\b", lines[i]) for i in lines_v):
        if lines_v:
            lines[lines_v[0]] += " AC 1"
            warnings.append(f"Sinal AC de 1 V aplicado em {lines[lines_v[0]].split()[0]}.")
        else:
            warnings.append("Nenhuma fonte de tensão para a análise AC.")

    analysis_line = _parameters(analise, parametros or {}, sources)
    title = str(project.get("titulo") or "Circuito").replace("\n", " ")
    text = [f"* {title} — netlist gerada pelo módulo Eletrônica", *lines]
    text += [m for _, m in sorted(models.items())]
    text += [_SUBCIRCUITS[s] for s in sorted(subcircuits)]
    if analise == "op":
        text.append(".options savecurrents")
    text += [analysis_line, ".end", ""]
    eixo = {"tran": ("tempo", "s"), "ac": ("frequência", "Hz")}.get(analise)
    if analise == "dc":
        ref = str((parametros or {}).get("fonte", "")).strip()
        eixo = (ref, "A" if sources[ref.upper()].upper().startswith("I") else "V")
    return {
        "texto": "\n".join(text),
        "ignorados": ignorados,
        "avisos": warnings,
        "nos": nodes,
        "fontes": refs_sources,
        "eixo": {"nome": eixo[0], "unidade": eixo[1]} if eixo else None,
    }


# --- Leitura do resultado (raw do ngspice, ASCII ou binário) -------------------------------------


def read_raw(dados: bytes) -> list[dict[str, Any]]:
    """Gráficos do raw: `[{nome, complexo, variaveis:[(nome, tipo)], valores:[[...] por var]}]`."""
    graphics: list[dict[str, Any]] = []
    lines = dados.split(b"\n")
    i = 0
    pos = 0  # deslocamento em bytes do início da linha i (para o bloco binário)
    while i < len(lines):
        header: dict[str, str] = {}
        variaveis: list[tuple[str, str]] = []
        mode = ""
        while i < len(lines):
            line = lines[i].decode("latin-1").rstrip("\r")
            pos += len(lines[i]) + 1
            i += 1
            key, _, rest = line.partition(":")
            key = key.strip().lower()
            if key == "variables":
                for _ in range(int(header.get("no. variables", 0))):
                    parts = (rest.split() if rest.strip() else None) or lines[i].decode(
                        "latin-1"
                    ).split()
                    if not rest.strip():
                        pos += len(lines[i]) + 1
                        i += 1
                    rest = ""
                    variaveis.append((parts[1], parts[2] if len(parts) > 2 else ""))
            elif key in ("values", "binary"):
                mode = key
                break
            elif line.strip():
                header[key] = rest.strip()
        if not mode:
            break
        nvar, npts = len(variaveis), int(header.get("no. points", 0))
        complexo = "complex" in header.get("flags", "").lower()
        values: list[list[Any]] = [[] for _ in variaveis]
        if mode == "binary":
            size = 16 if complexo else 8
            block = dados[pos : pos + npts * nvar * size]
            npts = len(block) // (nvar * size) if nvar else 0
            nums = struct.unpack(f"<{npts * nvar * size // 8}d", block[: npts * nvar * size])
            for k in range(npts * nvar):
                v = complex(nums[k * 2], nums[k * 2 + 1]) if complexo else nums[k]
                values[k % nvar].append(v)
            pos += npts * nvar * size
            # Recomeça a divisão em linhas depois do bloco binário.
            lines = dados[pos:].split(b"\n")
            i = 0
        else:
            cards: list[str] = []
            while i < len(lines) and len(cards) < npts * (nvar + 1):
                text = lines[i].decode("latin-1")
                if text.split(":")[0].strip().lower() in ("title", "plotname"):
                    break
                cards += text.split()
                pos += len(lines[i]) + 1
                i += 1
            for k, card in enumerate(cards):
                if k % (nvar + 1) == 0:
                    continue  # índice do ponto
                if complexo:
                    re_, _, im = card.partition(",")
                    v: Any = complex(float(re_), float(im or 0))
                else:
                    v = float(card)
                values[k % (nvar + 1) - 1].append(v)
        graphics.append(
            {
                "nome": header.get("plotname", ""),
                "complexo": complexo,
                "variaveis": variaveis,
                "valores": values,
            }
        )
    return graphics


def _label(nome: str, tipo: str, nodes: dict[str, str]) -> tuple[str, str] | None:
    """("V", rede) ou ("I", elemento) de uma variável do raw; None para nós internos."""
    n = nome.strip().lower()
    if tipo == "voltage" or n.startswith("v("):
        if m := re.fullmatch(r"v\((.+)\)", n):
            n = m[1]
        return ("V", nodes[n]) if n in nodes else None
    if tipo == "current" or n.startswith(("i(", "@")) or n.endswith("#branch"):
        if m := re.fullmatch(r"i\((.+)\)", n):
            n = m[1]
        n = n.removesuffix("#branch")
        if m := re.fullmatch(r"@([^\[]+)\[(\w+)\]", n):
            n = m[1] if m[2] == "i" else f"{m[1]}({m[2]})"
        if "." in n or ":" in n:
            return None  # dentro de subcircuito
        return ("I", n.upper())
    return None


def result(
    analise: str,
    graphics: list[dict[str, Any]],
    nodes: dict[str, str],
    eixo_info: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Para .op: `{analise, tensoes:{rede: V}, correntes:{elemento: A}}`; nas outras:
    `{analise, variaveis, eixo:{nome, unidade, valores}, series:{"v(rede)"|"i(elemento)": [...]}}`
    (AC: módulo linear em `series` e fase em graus em `fases`)."""
    if not graphics:
        raise ValueError("O ngspice não gerou resultado.")
    g = graphics[-1]
    pairs = list(zip(g["variaveis"], g["valores"], strict=True))
    if analise == "op":
        tensoes: dict[str, float] = {}
        correntes: dict[str, float] = {}
        for (name, kind), vals in pairs:
            if not vals or (r := _label(name, kind, nodes)) is None:
                continue
            (tensoes if r[0] == "V" else correntes)[r[1]] = float(
                abs(vals[0]) if g["complexo"] else vals[0]
            )
        return {"analise": analise, "tensoes": tensoes, "correntes": correntes}

    (name_eixo, _), eixo = pairs[0]
    eixo_info = eixo_info or {"nome": name_eixo, "unidade": ""}
    series: dict[str, list[float]] = {}
    fase: dict[str, list[float]] = {}
    for (name, kind), vals in pairs[1:]:
        if (r := _label(name, kind, nodes)) is None:
            continue
        key = f"{r[0].lower()}({r[1]})"
        if g["complexo"]:
            series[key] = [abs(v) for v in vals]
            fase[key] = [math.degrees(cmath.phase(v)) for v in vals]
        else:
            series[key] = [float(v) for v in vals]
    output: dict[str, Any] = {
        "analise": analise,
        "variaveis": list(series),
        "eixo": {
            **eixo_info,
            "valores": [float(v.real) if g["complexo"] else float(v) for v in eixo],
        },
        "series": series,
    }
    if g["complexo"]:
        output["fases"] = fase
    return output
