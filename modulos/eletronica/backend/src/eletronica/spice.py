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

from eletronica.biblioteca import POR_ID
from eletronica.netlist import netlist
from eletronica.projetos import BuscaSimbolo

ANALISES = ("op", "tran", "ac", "dc")

# --- Valores --------------------------------------------------------------------------------------

_PREFIXOS = {
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
_FATOR = {
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
_UNIDADE = r"(?:ohms?|Ω|Hz|F|H|V|A|s|W)?"
# "4u7", "4k7", "10k", "2.2nF", "1mA", "1M" (mega, como no esquemático).
_COM_PREFIXO = re.compile(rf"([+-]?\d+(?:[.,]\d+)?)\s*((?i:meg)|[pnuµμmkKMGT])?(\d+)?\s*{_UNIDADE}")
# "1R5", "5V1", "0Ω47": a letra é a vírgula e não multiplica.
_LETRA_VIRGULA = re.compile(r"([+-]?\d+)[RrVvΩ](\d+)")
_EXPOENTE = re.compile(rf"([+-]?\d+(?:\.\d+)?[eE][+-]?\d+)\s*{_UNIDADE}")


def valor_spice(texto: str) -> str | None:
    """Valor do esquemático em notação SPICE ("4u7" → "4.7u", "1M" → "1Meg", "5V" → "5")."""
    t = texto.strip()
    if m := _LETRA_VIRGULA.fullmatch(t):
        return f"{m[1]}.{m[2]}"
    if m := _EXPOENTE.fullmatch(t):
        return m[1]
    m = _COM_PREFIXO.fullmatch(t)
    if not m:
        return None
    numero, prefixo, resto = m[1].replace(",", "."), m[2] or "", m[3]
    if resto and "." in numero:
        return None
    sufixo = "Meg" if prefixo.lower() == "meg" else _PREFIXOS.get(prefixo, "")
    return f"{numero}{'.' + resto if resto else ''}{sufixo}"


def numero(spice: str) -> float:
    """Número de um valor já em notação SPICE ("4.7u" → 4.7e-6)."""
    m = re.fullmatch(r"([+-]?[\d.]+(?:[eE][+-]?\d+)?)(meg|[fpnumkgt])?", spice.strip(), re.I)
    if not m:
        raise ValueError(f"Valor inválido: {spice}")
    return float(m[1]) * _FATOR.get((m[2] or "").lower(), 1.0)


def _fonte(texto: str) -> str | None:
    """Especificação de fonte: "5V" → "DC 5"; "SIN(0 1V 1kHz)" → "SIN(0 1 1k)"; "DC 5 AC 1"."""
    t = texto.strip()
    if (v := valor_spice(t)) is not None:
        return f"DC {v}"
    if not re.match(r"(DC|AC|SIN|PULSE|PWL|EXP|SFFM)\b|(SIN|PULSE|PWL|EXP|SFFM)\(", t, re.I):
        return None

    def trocar(m: re.Match[str]) -> str:
        return valor_spice(m[0]) or m[0]

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


def classe(simb: dict[str, Any]) -> str | None:
    """Tipo de elemento SPICE do símbolo (base ou importado do KiCad), ou None sem modelo."""
    id_ = simb["id"]
    if id_ in _BASE:
        return _BASE[id_]
    if ":" not in id_:
        return None
    lib, nome = id_.split(":")[:2]
    texto = f"{nome} {simb.get('descricao', '')}".upper()
    if lib == "Device":
        return next((c for padrao, c in _DEVICE if re.fullmatch(padrao, nome)), None)
    if lib == "Transistor_BJT":
        return "PNP" if "PNP" in texto else "NPN"
    if lib == "Transistor_FET":
        if "JFET" in texto:
            return None
        return "PMOS" if re.search(r"P-CHANNEL|P-MOS|PMOS", texto) else "NMOS"
    if lib == "Diode":
        return "DZ" if "ZENER" in texto else "DS" if "SCHOTTKY" in texto else "D"
    if lib == "Simulation_SPICE":
        return {"V": "V", "I": "I", "D": "D"}.get(nome[:1])
    if lib == "Amplifier_Operational":
        return "AMPOP"
    return None


# Terminais por tipo: pelo nome do pino; sem nome, pelo número.
_TERMINAIS: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "R": ((), ("1", "2")),
    "C": (("+", "-"), ("1", "2")),
    "L": ((), ("1", "2")),
    "D": (("A", "K"), ("2", "1")),
    "Q": (("C", "B", "E"), ()),
    "M": (("D", "G", "S"), ()),
    "V": (("+", "-"), ("1", "2")),
    "I": ((), ("1", "2")),
}
_LETRA = {
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

_MODELOS = {
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
_SUBCIRCUITOS = {
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


def _modelo_led(valor: str) -> str:
    v = valor.lower()
    if re.search(r"azul|blue|branco|white|uv", v):
        return "LED_AZUL"
    if re.search(r"verde|green", v):
        return "LED_VERDE"
    return "LED_VERMELHO"


def _modelo_zener(valor: str, modelos: dict[str, str]) -> str:
    m = re.search(r"(\d+)V(\d*)", valor, re.I)
    bv = float(f"{m[1]}.{m[2] or 0}") if m else 5.1
    nome = f"DZ_{bv:g}".replace(".", "V")
    modelos[nome] = f".model {nome} D(IS=1n RS=1 N=1.5 BV={bv:g} IBV=1m CJO=50p)"
    return nome


# --- Geração --------------------------------------------------------------------------------------


def eh_terra(rede: str) -> bool:
    return bool(re.fullmatch(r"0|[ADP]?GND\w*", rede.strip().upper()))


def _saneado(texto: str) -> str:
    t = texto.strip()
    t = re.sub(r"^\+", "P", re.sub(r"^-", "N", t))
    return re.sub(r"\W", "_", t) or "_"


def _parametros(analise: str, p: dict[str, Any], fontes: dict[str, str]) -> str:
    def valor(chave: str, padrao: str | None = None) -> str:
        bruto = p.get(chave, padrao)
        if bruto is None or str(bruto).strip() == "":
            raise ValueError(f"Falta o parâmetro '{chave}' da análise {analise}.")
        v = valor_spice(str(bruto))
        if v is None:
            raise ValueError(f"Parâmetro '{chave}' inválido: {bruto}")
        return v

    if analise == "op":
        return ".op"
    if analise == "tran":
        linha = f".tran {valor('passo')} {valor('fim')}"
        if p.get("inicio") not in (None, ""):
            linha += f" {valor('inicio')}"
        if numero(valor("passo")) <= 0 or numero(valor("fim")) <= 0:
            raise ValueError("Passo e fim do transiente precisam ser maiores que zero.")
        return linha
    if analise == "ac":
        try:
            pontos = int(p.get("pontos", 20))
        except (TypeError, ValueError) as e:
            raise ValueError("Pontos da análise AC devem ser um número inteiro.") from e
        if not 1 <= pontos <= 10_000:
            raise ValueError("Pontos da análise AC devem ficar entre 1 e 10000.")
        return f".ac dec {pontos} {valor('inicio', '1')} {valor('fim', '1Meg')}"
    if analise == "dc":
        ref = str(p.get("fonte", "")).strip()
        elemento = fontes.get(ref.upper())
        if elemento is None:
            raise ValueError(f"Fonte '{ref}' da varredura DC não existe no circuito.")
        return f".dc {elemento} {valor('inicio')} {valor('fim')} {valor('passo')}"
    raise ValueError(f"Análise desconhecida: {analise} (use {', '.join(ANALISES)}).")


def gerar(
    projeto: dict[str, Any],
    simbolo: BuscaSimbolo = POR_ID.get,
    analise: str = "op",
    parametros: dict[str, Any] | None = None,
    rede: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """`{texto, ignorados:[{ref, simbolo, motivo}], avisos, nos:{nó: rede}}`.

    [rede] é a netlist já calculada (`netlist()`); sem ela, é calculada do esquemático.
    Levanta ValueError com parâmetros de análise inválidos.
    """
    if analise not in ANALISES:
        raise ValueError(f"Análise desconhecida: {analise} (use {', '.join(ANALISES)}).")
    rede = rede if rede is not None else netlist(projeto, simbolo)
    nos: dict[str, str] = {}  # nó SPICE (minúsculas) → rede
    no_da_rede: dict[str, str] = {}

    def no(nome_rede: str) -> str:
        if eh_terra(nome_rede):
            return "0"
        if nome_rede not in no_da_rede:
            base = n = _saneado(nome_rede)
            i = 1
            while n.lower() in nos or n == "0":
                i += 1
                n = f"{base}_{i}"
            no_da_rede[nome_rede] = n
            nos[n.lower()] = nome_rede
        return no_da_rede[nome_rede]

    no_do_pino: dict[tuple[str, str], str] = {}
    for r in rede["redes"]:
        for p in r["pinos"]:
            no_do_pino[(p["ref"], p["pino"])] = no(r["nome"])
    for p in rede["soltos"]:
        no_do_pino[(p["ref"], p["pino"])] = no(f"NC_{p['ref']}_{p['pino']}")

    componentes = [
        (c, s) for c in projeto.get("componentes", []) if (s := simbolo(c["simbolo"])) is not None
    ]
    # Pinos por nome de todas as unidades de cada ref (os trilhos do op-amp ficam noutra unidade).
    por_ref: dict[str, dict[str, str]] = {}
    for c, s in componentes:
        for p in s["pinos"]:
            if (k := (c.get("ref", "?"), p["n"])) in no_do_pino and p["nome"]:
                por_ref.setdefault(k[0], {})[p["nome"].upper()] = no_do_pino[k]

    linhas: list[str] = []
    ignorados: list[dict[str, Any]] = []
    avisos: list[str] = []
    modelos: dict[str, str] = {}
    subcircuitos: set[str] = set()
    usados: set[str] = set()
    fontes: dict[str, str] = {}  # ref ou elemento (maiúsculas) → elemento V/I
    refs_fontes: list[str] = []  # refs das fontes do esquemático (para a varredura DC)
    nos_com_fonte: set[str] = set()
    alimentacoes: dict[str, str] = {}
    linhas_v: list[int] = []

    def nome_elemento(letra: str, ref: str) -> str:
        base = _saneado(ref)
        base = base if base.upper().startswith(letra) else letra + base
        nome, i = base, 1
        while nome.upper() in usados:
            i += 1
            nome = f"{base}_{i}"
        usados.add(nome.upper())
        return nome

    def ignorar(c: dict[str, Any], s: dict[str, Any], motivo: str) -> None:
        ref = c.get("ref", "?")
        ignorados.append({"ref": ref, "simbolo": s["id"], "motivo": motivo})
        linhas.append(f"* ignorado: {ref} ({s['id']}) — {motivo}")

    for c, s in componentes:
        ref = c.get("ref", "?")
        if s["tipo"] == "alimentacao":
            nome_rede = (c.get("valor") or s["valor"]).strip()
            if not eh_terra(nome_rede):
                alimentacoes[nome_rede] = no(nome_rede)
            continue
        tipo = classe(s)
        if tipo is None:
            ignorar(c, s, "sem modelo SPICE")
            continue
        letra = _LETRA[tipo]
        valor = str(c.get("valor") or s.get("valor") or "")
        pinos = {p["n"]: p for p in s["pinos"]}
        nomes = {p["nome"].upper(): p["n"] for p in s["pinos"] if p["nome"]}

        if tipo == "AMPOP":
            fora = {"+", "-", "V+", "V-"}
            saida = [n for n, p in pinos.items() if p["nome"].upper() not in fora]
            if "+" not in nomes or "-" not in nomes or len(saida) != 1:
                if not ({"+", "-"} & nomes.keys()):
                    continue  # unidade só de alimentação do op-amp
                ignorar(c, s, "pinos do amplificador não reconhecidos")
                continue
            nomes_no = [
                no_do_pino.get((ref, nomes["+"])),
                no_do_pino.get((ref, nomes["-"])),
                no_do_pino.get((ref, saida[0])),
            ]
            trilhos = por_ref.get(ref, {})
            sub = "AMPOP_SEM_ALIM"
            if "V+" in trilhos and "V-" in trilhos:
                nomes_no += [trilhos["V+"], trilhos["V-"]]
                sub = "AMPOP"
            if None in nomes_no:
                ignorar(c, s, "pino sem ligação")
                continue
            unidade = s["id"].split(":")[2] if s["id"].count(":") == 2 else ""
            elemento = nome_elemento(
                "X", ref + (chr(64 + int(unidade)) if unidade.isdigit() else "")
            )
            subcircuitos.add(sub)
            linhas.append(f"{elemento} {' '.join(str(n) for n in nomes_no)} {sub}")
            continue

        por_nome, por_numero = _TERMINAIS[letra]
        if por_nome and all(n in nomes for n in por_nome):
            terminais = [nomes[n] for n in por_nome]
        elif por_numero and all(n in pinos for n in por_numero):
            terminais = list(por_numero)
        else:
            ignorar(c, s, "pinos não reconhecidos")
            continue
        nos_el = [no_do_pino.get((ref, t)) for t in terminais]
        if None in nos_el:
            ignorar(c, s, "pino sem ligação")
            continue
        args = " ".join(str(n) for n in nos_el)

        if letra in "RCL":
            v = valor_spice(valor)
            if v is None:
                ignorar(c, s, f"valor '{valor}' não reconhecido")
                continue
            linhas.append(f"{nome_elemento(letra, ref)} {args} {v}")
        elif letra in "VI":
            spec = _fonte(valor)
            if spec is None:
                ignorar(c, s, f"valor de fonte '{valor}' não reconhecido")
                continue
            elemento = nome_elemento(letra, ref)
            fontes[ref.upper()] = fontes[elemento.upper()] = elemento
            refs_fontes.append(ref)
            if letra == "V":
                nos_com_fonte.update(str(n) for n in nos_el)
                linhas_v.append(len(linhas))
            linhas.append(f"{elemento} {args} {spec}")
        elif letra == "D":
            if tipo == "LED":
                modelo = _modelo_led(valor)
            elif tipo == "DZ":
                modelo = _modelo_zener(valor, modelos)
            else:
                modelo = "DSCHOTTKY" if tipo == "DS" else "D1N4148"
            modelos.setdefault(modelo, _MODELOS.get(modelo, ""))
            linhas.append(f"{nome_elemento('D', ref)} {args} {modelo}")
        elif letra == "Q":
            modelo = "BC557" if tipo == "PNP" else "BC547"
            modelos[modelo] = _MODELOS[modelo]
            linhas.append(f"{nome_elemento('Q', ref)} {args} {modelo}")
        else:  # M: corpo ligado à fonte
            modelo = "PMOS_GEN" if tipo == "PMOS" else "NMOS_GEN"
            modelos[modelo] = _MODELOS[modelo]
            linhas.append(f"{nome_elemento('M', ref)} {args} {nos_el[2]} {modelo}")

    # Alimentação com tensão no nome (+5V, +3V3, -12V) vira fonte quando nada alimenta a rede.
    for nome_rede, n in sorted(alimentacoes.items()):
        if n in nos_com_fonte:
            continue
        m = re.fullmatch(r"([+-]?)(\d+)V(\d*)", nome_rede, re.I)
        if m is None:
            avisos.append(f"Rede {nome_rede} sem fonte de tensão: coloque uma fonte nela.")
            continue
        tensao = f"{m[1] if m[1] == '-' else ''}{m[2]}{'.' + m[3] if m[3] else ''}"
        elemento = nome_elemento("V", f"ALIM_{n}")
        fontes[elemento.upper()] = elemento
        linhas_v.append(len(linhas))
        linhas.append(f"{elemento} {n} 0 DC {tensao}")
        avisos.append(f"Fonte automática de {tensao} V na rede {nome_rede}.")

    if analise == "ac" and not any(re.search(r"(?i)\bAC\b", linhas[i]) for i in linhas_v):
        if linhas_v:
            linhas[linhas_v[0]] += " AC 1"
            avisos.append(f"Sinal AC de 1 V aplicado em {linhas[linhas_v[0]].split()[0]}.")
        else:
            avisos.append("Nenhuma fonte de tensão para a análise AC.")

    analise_linha = _parametros(analise, parametros or {}, fontes)
    titulo = str(projeto.get("titulo") or "Circuito").replace("\n", " ")
    texto = [f"* {titulo} — netlist gerada pelo módulo Eletrônica", *linhas]
    texto += [m for _, m in sorted(modelos.items())]
    texto += [_SUBCIRCUITOS[s] for s in sorted(subcircuitos)]
    if analise == "op":
        texto.append(".options savecurrents")
    texto += [analise_linha, ".end", ""]
    eixo = {"tran": ("tempo", "s"), "ac": ("frequência", "Hz")}.get(analise)
    if analise == "dc":
        ref = str((parametros or {}).get("fonte", "")).strip()
        eixo = (ref, "A" if fontes[ref.upper()].upper().startswith("I") else "V")
    return {
        "texto": "\n".join(texto),
        "ignorados": ignorados,
        "avisos": avisos,
        "nos": nos,
        "fontes": refs_fontes,
        "eixo": {"nome": eixo[0], "unidade": eixo[1]} if eixo else None,
    }


# --- Leitura do resultado (raw do ngspice, ASCII ou binário) -------------------------------------


def ler_raw(dados: bytes) -> list[dict[str, Any]]:
    """Gráficos do raw: `[{nome, complexo, variaveis:[(nome, tipo)], valores:[[...] por var]}]`."""
    graficos: list[dict[str, Any]] = []
    linhas = dados.split(b"\n")
    i = 0
    pos = 0  # deslocamento em bytes do início da linha i (para o bloco binário)
    while i < len(linhas):
        cab: dict[str, str] = {}
        variaveis: list[tuple[str, str]] = []
        modo = ""
        while i < len(linhas):
            linha = linhas[i].decode("latin-1").rstrip("\r")
            pos += len(linhas[i]) + 1
            i += 1
            chave, _, resto = linha.partition(":")
            chave = chave.strip().lower()
            if chave == "variables":
                for _ in range(int(cab.get("no. variables", 0))):
                    partes = (resto.split() if resto.strip() else None) or linhas[i].decode(
                        "latin-1"
                    ).split()
                    if not resto.strip():
                        pos += len(linhas[i]) + 1
                        i += 1
                    resto = ""
                    variaveis.append((partes[1], partes[2] if len(partes) > 2 else ""))
            elif chave in ("values", "binary"):
                modo = chave
                break
            elif linha.strip():
                cab[chave] = resto.strip()
        if not modo:
            break
        nvar, npts = len(variaveis), int(cab.get("no. points", 0))
        complexo = "complex" in cab.get("flags", "").lower()
        valores: list[list[Any]] = [[] for _ in variaveis]
        if modo == "binary":
            tam = 16 if complexo else 8
            bloco = dados[pos : pos + npts * nvar * tam]
            npts = len(bloco) // (nvar * tam) if nvar else 0
            nums = struct.unpack(f"<{npts * nvar * tam // 8}d", bloco[: npts * nvar * tam])
            for k in range(npts * nvar):
                v = complex(nums[k * 2], nums[k * 2 + 1]) if complexo else nums[k]
                valores[k % nvar].append(v)
            pos += npts * nvar * tam
            # Recomeça a divisão em linhas depois do bloco binário.
            linhas = dados[pos:].split(b"\n")
            i = 0
        else:
            fichas: list[str] = []
            while i < len(linhas) and len(fichas) < npts * (nvar + 1):
                texto = linhas[i].decode("latin-1")
                if texto.split(":")[0].strip().lower() in ("title", "plotname"):
                    break
                fichas += texto.split()
                pos += len(linhas[i]) + 1
                i += 1
            for k, ficha in enumerate(fichas):
                if k % (nvar + 1) == 0:
                    continue  # índice do ponto
                if complexo:
                    re_, _, im = ficha.partition(",")
                    v: Any = complex(float(re_), float(im or 0))
                else:
                    v = float(ficha)
                valores[k % (nvar + 1) - 1].append(v)
        graficos.append(
            {
                "nome": cab.get("plotname", ""),
                "complexo": complexo,
                "variaveis": variaveis,
                "valores": valores,
            }
        )
    return graficos


def _rotulo(nome: str, tipo: str, nos: dict[str, str]) -> tuple[str, str] | None:
    """("V", rede) ou ("I", elemento) de uma variável do raw; None para nós internos."""
    n = nome.strip().lower()
    if tipo == "voltage" or n.startswith("v("):
        if m := re.fullmatch(r"v\((.+)\)", n):
            n = m[1]
        return ("V", nos[n]) if n in nos else None
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


def resultado(
    analise: str,
    graficos: list[dict[str, Any]],
    nos: dict[str, str],
    eixo_info: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Para .op: `{analise, tensoes:{rede: V}, correntes:{elemento: A}}`; nas outras:
    `{analise, variaveis, eixo:{nome, unidade, valores}, series:{"v(rede)"|"i(elemento)": [...]}}`
    (AC: módulo linear em `series` e fase em graus em `fases`)."""
    if not graficos:
        raise ValueError("O ngspice não gerou resultado.")
    g = graficos[-1]
    pares = list(zip(g["variaveis"], g["valores"], strict=True))
    if analise == "op":
        tensoes: dict[str, float] = {}
        correntes: dict[str, float] = {}
        for (nome, tipo), vals in pares:
            if not vals or (r := _rotulo(nome, tipo, nos)) is None:
                continue
            (tensoes if r[0] == "V" else correntes)[r[1]] = float(
                abs(vals[0]) if g["complexo"] else vals[0]
            )
        return {"analise": analise, "tensoes": tensoes, "correntes": correntes}

    (nome_eixo, _), eixo = pares[0]
    eixo_info = eixo_info or {"nome": nome_eixo, "unidade": ""}
    series: dict[str, list[float]] = {}
    fase: dict[str, list[float]] = {}
    for (nome, tipo), vals in pares[1:]:
        if (r := _rotulo(nome, tipo, nos)) is None:
            continue
        chave = f"{r[0].lower()}({r[1]})"
        if g["complexo"]:
            series[chave] = [abs(v) for v in vals]
            fase[chave] = [math.degrees(cmath.phase(v)) for v in vals]
        else:
            series[chave] = [float(v) for v in vals]
    saida: dict[str, Any] = {
        "analise": analise,
        "variaveis": list(series),
        "eixo": {
            **eixo_info,
            "valores": [float(v.real) if g["complexo"] else float(v) for v in eixo],
        },
        "series": series,
    }
    if g["complexo"]:
        saida["fases"] = fase
    return saida
