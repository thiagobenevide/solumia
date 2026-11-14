"""Biblioteca base de símbolos do esquemático, em micrômetros (µm) com a origem no centro do
símbolo. Cada símbolo tem `desenho` (primitivas: `linha` com `p` [[x, y], …] e `fechada`, `ret` de
`a` a `b`, `circ` com centro `c` e raio `r`, `arco` com `c`, `r`, início `ini` e varredura `var` em
graus no sentido horário da tela, `texto` em `p`), `pinos` e a posição dos campos `ref` e `valor`. A
ponta do pino (`x`, `y`) fica sempre na grade de 1,27 mm (é onde o fio liga); `dir` aponta da ponta
para o corpo (`d` direita, `e` esquerda, `c` cima, `b` baixo) e `comp` é o comprimento da perna
desenhada. `tipo` do símbolo: `componente` entra na lista de peças; `alimentacao` não entra e dá à
rede o nome do `valor` (GND, VCC…)."""

from typing import Any

G = 1270  # grade de 50 mil
U = 2 * G  # 100 mil

KINDS_PIN = ("passivo", "entrada", "saida", "bidirecional", "alimentacao", "terra", "nc")


def _pin(
    n: str, x: int, y: int, d: str, comp: int, nome: str = "", tipo: str = "passivo"
) -> dict[str, Any]:
    return {"n": n, "nome": nome, "x": x, "y": y, "dir": d, "comp": comp, "tipo": tipo}


def _l(*p: tuple[int, int], fechada: bool = False, cheia: bool = False) -> dict[str, Any]:
    return {"t": "linha", "p": [list(q) for q in p], "fechada": fechada, "cheia": cheia}


def _ret(a: tuple[int, int], b: tuple[int, int], cheio: bool = False) -> dict[str, Any]:
    return {"t": "ret", "a": list(a), "b": list(b), "cheio": cheio}


def _circ(c: tuple[int, int], r: int, cheio: bool = False) -> dict[str, Any]:
    return {"t": "circ", "c": list(c), "r": r, "cheio": cheio}


def _arc(c: tuple[int, int], r: int, start: int, var: int) -> dict[str, Any]:
    return {"t": "arco", "c": list(c), "r": r, "ini": start, "var": var}


def _txt(p: tuple[int, int], s: str) -> dict[str, Any]:
    return {"t": "texto", "p": list(p), "s": s}


def _two_terminals(
    pins: tuple[str, str] = ("1", "2"), corpo: int = 3 * G
) -> list[dict[str, Any]]:
    """Pinos em ±3,81 mm na horizontal; a perna vai da ponta até ±[corpo]."""
    return [
        _pin(pins[0], -3 * G, 0, "d", 3 * G - corpo),
        _pin(pins[1], 3 * G, 0, "e", 3 * G - corpo),
    ]


def _symbol(
    id_: str,
    nome: str,
    categoria: str,
    prefixo: str,
    desenho: list[dict[str, Any]],
    pins: list[dict[str, Any]],
    valor: str = "",
    encapsulamento: str = "",
    ref: tuple[int, int] = (0, -2 * G),
    val: tuple[int, int] = (0, 2 * G),
    tipo: str = "componente",
    nomes_pinos: bool = False,
) -> dict[str, Any]:
    return {
        "id": id_,
        "nome": nome,
        "categoria": categoria,
        "prefixo": prefixo,
        "tipo": tipo,
        "valor": valor,
        "encapsulamento": encapsulamento,
        "desenho": desenho,
        "pinos": pins,
        "campos": {"ref": list(ref), "valor": list(val)},
        "nomes_pinos": nomes_pinos,
    }


def _ci(
    id_: str,
    nome: str,
    esquerda: list[str],
    direita: list[str],
    valor: str,
    encapsulamento: str,
    categoria: str = "CIs",
    prefixo: str = "U",
) -> dict[str, Any]:
    """Retângulo com pinos numerados de cima para baixo à esquerda e de baixo para cima à direita
    (como no DIP). Nome vazio = só o número."""
    lines = max(len(esquerda), len(direita))
    half = (lines - 1) * U // 2
    top, base = -half - G, half + G
    pins = []
    for i, name_pin in enumerate(esquerda):
        pins.append(_pin(str(i + 1), -3 * U, -half + i * U, "d", U, name_pin, "bidirecional"))
    for i, name_pin in enumerate(direita):
        n = len(esquerda) + i + 1
        y = half - i * U
        pins.append(_pin(str(n), 3 * U, y, "e", U, name_pin, "bidirecional"))
    return _symbol(
        id_,
        nome,
        categoria,
        prefixo,
        [_ret((-2 * U, top), (2 * U, base))],
        pins,
        valor,
        encapsulamento,
        ref=(0, top - G),
        val=(0, base + G),
        nomes_pinos=True,
    )


def _connector(n: int) -> dict[str, Any]:
    half = (n - 1) * U // 2
    pins = [_pin(str(i + 1), -2 * U, -half + i * U, "d", U) for i in range(n)]
    return _symbol(
        f"conector_{n}",
        f"Conector {n} vias",
        "Conectores",
        "J",
        [_ret((-U, -half - G), (0, half + G))],
        pins,
        f"Conn_{n}",
        f"PinHeader_1x{n:02d}_P2.54mm",
        ref=(-U, -half - 2 * G),
        val=(-U, half + 2 * G),
    )


def _nutrition(id_: str, valor: str) -> dict[str, Any]:
    if valor == "GND":
        desenho = [
            _l((0, 0), (0, G)),
            _l((-G, G), (G, G)),
            _l((-600, G + 500), (600, G + 500)),
            _l((-200, G + 1000), (200, G + 1000)),
        ]
        val = (0, 3 * G)
    else:
        desenho = [_l((0, 0), (0, -G)), _l((-G, -G), (G, -G))]
        val = (0, -2 * G)
    return _symbol(
        id_,
        valor,
        "Alimentação",
        "#PWR",
        desenho,
        [_pin("1", 0, 0, "b", 0, valor, "terra" if valor == "GND" else "alimentacao")],
        valor,
        ref=(0, 0),
        val=val,
        tipo="alimentacao",
    )


_TRIANGLE_DIODO = _l((-G, -G), (-G, G), (G, 0), fechada=True)
_PINS_DIODO = [_pin("2", -3 * G, 0, "d", 2 * G, "A"), _pin("1", 3 * G, 0, "e", 2 * G, "K")]


def _diodo(
    id_: str, nome: str, bar: list[dict[str, Any]], valor: str, enc: str
) -> dict[str, Any]:
    return _symbol(
        id_, nome, "Semicondutores", "D", [_TRIANGLE_DIODO, *bar], _PINS_DIODO, valor, enc
    )


def _bjt(id_: str, nome: str, pnp: bool) -> dict[str, Any]:
    arrow = (
        _l((-500, 1400), (-1270, 762), (-300, 900), fechada=True, cheia=True)
        if pnp
        else _l((1270, 2540), (300, 2300), (900, 1700), fechada=True, cheia=True)
    )
    return _symbol(
        id_,
        nome,
        "Semicondutores",
        "Q",
        [
            _circ((0, 0), 2900),
            _l((-1270, -1524), (-1270, 1524)),
            _l((-1270, -762), (1270, -2540)),
            _l((-1270, 762), (1270, 2540)),
            arrow,
        ],
        [
            _pin("1", -4 * G, 0, "d", 3 * G, "B", "entrada"),
            _pin("2", G, -3 * G, "b", G, "C"),
            _pin("3", G, 3 * G, "c", G, "E"),
        ],
        "BC557" if pnp else "BC547",
        "TO-92",
        ref=(3 * G, -G),
        val=(3 * G, G),
    )


def _mosfet(id_: str, nome: str, canal_p: bool) -> dict[str, Any]:
    arrow = (
        _l((300, 0), (-200, -400), (-200, 400), fechada=True, cheia=True)
        if canal_p
        else _l((-1016, 0), (-300, -400), (-300, 400), fechada=True, cheia=True)
    )
    return _symbol(
        id_,
        nome,
        "Semicondutores",
        "Q",
        [
            _l((-1778, -1524), (-1778, 1524)),
            _l((-1016, -1778), (-1016, -762)),
            _l((-1016, -508), (-1016, 508)),
            _l((-1016, 762), (-1016, 1778)),
            _l((-1016, -1270), (1270, -1270), (1270, -2540)),
            _l((-1016, 1270), (1270, 1270), (1270, 2540)),
            _l((-1016, 0), (1270, 0), (1270, 1270)),
            arrow,
        ],
        [
            _pin("1", -4 * G, 0, "d", 4 * G - 1778, "G", "entrada"),
            _pin("2", G, -3 * G, "b", G, "D"),
            _pin("3", G, 3 * G, "c", G, "S"),
        ],
        "AO3401" if canal_p else "AO3400",
        "SOT-23",
        ref=(3 * G, -G),
        val=(3 * G, G),
    )


def _coils(x0: int, n: int = 4, y: int = 0, vertical: bool = False) -> list[dict[str, Any]]:
    """[n] meias-voltas de raio 635 µm a partir de [x0] (ou de y=[x0] quando [vertical])."""
    if vertical:
        return [_arc((y, x0 + 635 + i * G), 635, 270, 180) for i in range(n)]
    return [_arc((x0 + 635 + i * G, y), 635, 180, 180) for i in range(n)]


def _build() -> list[dict[str, Any]]:
    body_r = [_ret((-2 * G, -400), (2 * G, 400))]
    placas = [_l((-400, -2 * G), (-400, 2 * G)), _l((400, -2 * G), (400, 2 * G))]
    s = [
        # ---------- Passivos ----------
        _symbol(
            "resistor",
            "Resistor",
            "Passivos",
            "R",
            body_r,
            _two_terminals(corpo=2 * G),
            "10k",
            "R_0603",
        ),
        _symbol(
            "potenciometro",
            "Potenciômetro",
            "Passivos",
            "RV",
            [
                *body_r,
                _l((0, -2 * G), (0, -400 - 200)),
                _l((-300, -1100), (0, -600), (300, -1100)),
            ],
            [*_two_terminals(corpo=2 * G), _pin("3", 0, -2 * G, "b", 0, "W")],
            "10k",
            "Potentiometer_Alps_RK09K",
            ref=(-3 * G, -2 * G),
        ),
        _symbol(
            "termistor",
            "Termistor NTC",
            "Passivos",
            "TH",
            [*body_r, _l((-2 * G, 2 * G), (-G, 2 * G), (2 * G, -2 * G))],
            _two_terminals(corpo=2 * G),
            "NTC 10k",
            "R_0603",
            val=(0, 3 * G),
        ),
        _symbol(
            "varistor",
            "Varistor",
            "Passivos",
            "RV",
            [*body_r, _l((-2 * G, G), (-G, G), (2 * G, -G))],
            _two_terminals(corpo=2 * G),
            "275V",
            "RV_Disc_D12mm",
        ),
        _symbol(
            "capacitor",
            "Capacitor",
            "Passivos",
            "C",
            placas,
            _two_terminals(corpo=400),
            "100n",
            "C_0603",
        ),
        _symbol(
            "capacitor_polarizado",
            "Capacitor eletrolítico",
            "Passivos",
            "C",
            [
                _l((-400, -2 * G), (-400, 2 * G)),
                _arc((2600, 0), 2200, 145, 70),
                _txt((-1300, -1300), "+"),
            ],
            _two_terminals(("1", "2"), corpo=400),
            "100u",
            "CP_Radial_D6.3mm",
        ),
        _symbol(
            "indutor",
            "Indutor",
            "Passivos",
            "L",
            _coils(-2 * G),
            _two_terminals(corpo=2 * G),
            "10u",
            "L_1210",
        ),
        _symbol(
            "ferrite",
            "Ferrite",
            "Passivos",
            "FB",
            [_ret((-2 * G, -500), (2 * G, 500), cheio=True)],
            _two_terminals(corpo=2 * G),
            "600R@100MHz",
            "L_0603",
        ),
        _symbol(
            "fusivel",
            "Fusível",
            "Passivos",
            "F",
            [_ret((-2 * G, -500), (2 * G, 500)), _l((-2 * G, 0), (2 * G, 0))],
            _two_terminals(corpo=2 * G),
            "1A",
            "Fuse_1206",
        ),
        _symbol(
            "cristal",
            "Cristal",
            "Passivos",
            "Y",
            [
                _ret((-500, -G), (500, G)),
                _l((-1000, -900), (-1000, 900)),
                _l((1000, -900), (1000, 900)),
            ],
            _two_terminals(corpo=1000),
            "16MHz",
            "Crystal_HC49-U",
        ),
        _symbol(
            "transformador",
            "Transformador",
            "Passivos",
            "T",
            [
                *_coils(-2 * G, vertical=True, y=-G),
                *_coils(-2 * G, vertical=True, y=G),
                _l((-300, -2 * G), (-300, 2 * G)),
                _l((300, -2 * G), (300, 2 * G)),
            ],
            [
                _pin("1", -3 * G, -2 * G, "d", 2 * G - 0),
                _pin("2", -3 * G, 2 * G, "d", 2 * G),
                _pin("3", 3 * G, -2 * G, "e", 2 * G),
                _pin("4", 3 * G, 2 * G, "e", 2 * G),
            ],
            "1:1",
            "Transformer_Toroid",
            ref=(0, -3 * G),
            val=(0, 3 * G),
        ),
        # ---------- Semicondutores ----------
        _diodo("diodo", "Diodo", [_l((G, -G), (G, G))], "1N4148", "D_SOD-123"),
        _diodo(
            "zener",
            "Diodo Zener",
            [_l((G - 400, -G - 300), (G, -G), (G, G), (G + 400, G + 300))],
            "5V1",
            "D_SOD-123",
        ),
        _diodo(
            "schottky",
            "Diodo Schottky",
            [
                _l(
                    (G - 500, -G + 400),
                    (G - 500, -G),
                    (G, -G),
                    (G, G),
                    (G + 500, G),
                    (G + 500, G - 400),
                )
            ],
            "SS34",
            "D_SMA",
        ),
        _diodo(
            "tvs",
            "Diodo TVS",
            [
                _l((G - 400, -G - 300), (G, -G), (G, G), (G + 400, G + 300)),
                _txt((0, -2 * G), "TVS"),
            ],
            "SMBJ5.0A",
            "D_SMB",
        ),
        _symbol(
            "led",
            "LED",
            "Semicondutores",
            "D",
            [
                _TRIANGLE_DIODO,
                _l((G, -G), (G, G)),
                _l((0, -1500), (1000, -2500)),
                _l((600, -2500), (1000, -2500), (1000, -2100)),
                _l((900, -1500), (1900, -2500)),
                _l((1500, -2500), (1900, -2500), (1900, -2100)),
            ],
            _PINS_DIODO,
            "Vermelho",
            "LED_0805",
            ref=(0, -3 * G),
        ),
        _symbol(
            "ponte_retificadora",
            "Ponte retificadora",
            "Semicondutores",
            "D",
            [
                _l((0, -2 * G), (2 * G, 0), (0, 2 * G), (-2 * G, 0), fechada=True),
                _txt((0, -700), "~"),
                _txt((0, 700), "~"),
                _txt((1500, -1500), "+"),
                _txt((-1500, -1500), "-"),
            ],
            [
                _pin("1", 0, -3 * G, "b", G, "~", "entrada"),
                _pin("2", 3 * G, 0, "e", G, "+", "saida"),
                _pin("3", 0, 3 * G, "c", G, "~", "entrada"),
                _pin("4", -3 * G, 0, "d", G, "-", "saida"),
            ],
            "KBP307",
            "Diode_Bridge_DIP-4",
            ref=(3 * G, -2 * G),
            val=(3 * G, 2 * G),
        ),
        _bjt("npn", "Transistor NPN", pnp=False),
        _bjt("pnp", "Transistor PNP", pnp=True),
        _mosfet("nmos", "MOSFET canal N", canal_p=False),
        _mosfet("pmos", "MOSFET canal P", canal_p=True),
        # ---------- CIs ----------
        _symbol(
            "amp_op",
            "Amplificador operacional",
            "CIs",
            "U",
            [
                _l((-2 * U, -2 * U), (-2 * U, 2 * U), (2 * U, 0), fechada=True),
                _txt((-4000, -U), "+"),
                _txt((-4000, U), "−"),
            ],
            [
                _pin("3", -3 * U, -U, "d", U, "+", "entrada"),
                _pin("2", -3 * U, U, "d", U, "-", "entrada"),
                _pin("1", 3 * U, 0, "e", U, "", "saida"),
                _pin("8", 0, -2 * U, "b", G, "V+", "alimentacao"),
                _pin("4", 0, 2 * U, "c", G, "V-", "alimentacao"),
            ],
            "NE5532",
            "SOIC-8",
            ref=(U, -2 * U),
            val=(U, 2 * U),
        ),
        _ci(
            "regulador_linear", "Regulador linear", ["IN", "GND"], ["OUT"], "AMS1117-3.3", "SOT-223"
        ),
        _ci(
            "regulador_ajustavel", "Regulador ajustável", ["IN"], ["OUT", "ADJ"], "LM317", "TO-220"
        ),
        _ci("tl431", "Referência TL431", ["REF"], ["A", "K"], "TL431", "SOT-23"),
        _ci("optoacoplador", "Optoacoplador", ["A", "K"], ["E", "C"], "PC817", "DIP-4"),
        _ci(
            "ne555",
            "Temporizador 555",
            ["GND", "TRIG", "OUT", "RESET"],
            ["CTRL", "THR", "DIS", "VCC"],
            "NE555",
            "DIP-8",
        ),
        _ci(
            "buck", "Conversor buck", ["VIN", "EN", "GND"], ["FB", "SW", "BST"], "MP1584", "SOIC-8"
        ),
        _ci(
            "amp_classe_d",
            "Amplificador classe D",
            ["IN+", "IN-", "SD", "GND"],
            ["OUT-", "OUT+", "PVCC", "VCC"],
            "TPA3116D2",
            "HTSSOP-32",
        ),
        _ci("ci_8", "CI genérico 8 pinos", ["", "", "", ""], ["", "", "", ""], "CI", "SOIC-8"),
        _ci("ci_14", "CI genérico 14 pinos", [""] * 7, [""] * 7, "CI", "SOIC-14"),
        _ci("ci_16", "CI genérico 16 pinos", [""] * 8, [""] * 8, "CI", "SOIC-16"),
        _ci(
            "memoria_spi",
            "Memória flash SPI",
            ["CS", "DO", "WP", "GND"],
            ["DI", "CLK", "HOLD", "VCC"],
            "W25Q128",
            "SOIC-8",
        ),
        _ci(
            "eeprom_i2c",
            "EEPROM I²C",
            ["A0", "A1", "A2", "GND"],
            ["SDA", "SCL", "WP", "VCC"],
            "24C02",
            "SOIC-8",
        ),
        # ---------- Eletromecânicos ----------
        _symbol(
            "chave",
            "Chave",
            "Eletromecânicos",
            "SW",
            [_circ((-G, 0), 250), _circ((G, 0), 250), _l((-G + 200, -150), (G, -G))],
            _two_terminals(corpo=G),
            "SPST",
            "SW_SPST",
        ),
        _symbol(
            "botao",
            "Botão",
            "Eletromecânicos",
            "SW",
            [
                _circ((-G, 0), 250),
                _circ((G, 0), 250),
                _l((-G - 200, -800), (G + 200, -800)),
                _l((0, -800), (0, -1600)),
            ],
            _two_terminals(corpo=G),
            "Push",
            "SW_PUSH_6mm",
            ref=(0, -3 * G),
        ),
        _symbol(
            "rele",
            "Relé",
            "Eletromecânicos",
            "K",
            [
                _ret((-3 * G, -G), (-G, G)),
                _l((-3 * G, G), (-G, -G)),
                _l((G, -2 * G), (G, 2 * G)),
                _l((G, 0), (3 * G, -G)),
            ],
            [
                _pin("1", -2 * G, -3 * G, "b", 2 * G, "A1"),
                _pin("2", -2 * G, 3 * G, "c", 2 * G, "A2"),
                _pin("3", G, 3 * G, "c", G, "COM"),
                _pin("4", 3 * G, -3 * G, "b", 2 * G, "NA"),
                _pin("5", G, -3 * G, "b", G, "NF"),
            ],
            "SRD-05VDC",
            "Relay_SPDT",
            ref=(4 * G, -G),
            val=(4 * G, G),
        ),
        _symbol(
            "alto_falante",
            "Alto-falante",
            "Eletromecânicos",
            "LS",
            [_ret((-G, -G), (0, G)), _l((0, -G), (G, -2 * G), (G, 2 * G), (0, G))],
            [_pin("1", -3 * G, -G, "d", 2 * G, "+"), _pin("2", -3 * G, G, "d", 2 * G, "-")],
            "8R",
            "Speaker",
            ref=(2 * G, -2 * G),
            val=(2 * G, 3 * G),
        ),
        _symbol(
            "microfone",
            "Microfone",
            "Eletromecânicos",
            "MK",
            [_circ((0, 0), G), _l((-G, -G), (-G, G))],
            [_pin("1", 0, -3 * G, "b", 2 * G, "+"), _pin("2", 0, 3 * G, "c", 2 * G, "-")],
            "Eletreto",
            "Microphone_D6mm",
            ref=(2 * G, -G),
            val=(2 * G, G),
        ),
        _symbol(
            "motor",
            "Motor / ventoinha",
            "Eletromecânicos",
            "M",
            [_circ((0, 0), 2 * G), _txt((0, 0), "M")],
            [_pin("1", 0, -3 * G, "b", G, "+"), _pin("2", 0, 3 * G, "c", G, "-")],
            "12V",
            "Fan_2pin",
            ref=(3 * G, -G),
            val=(3 * G, G),
        ),
        _symbol(
            "ponto_teste",
            "Ponto de teste",
            "Eletromecânicos",
            "TP",
            [_circ((0, -G - 500), 500)],
            [_pin("1", 0, 0, "c", G)],
            "TP",
            "TestPoint_Pad_D1.5mm",
            ref=(2 * G, -G - 500),
            val=(2 * G, -500),
        ),
        # ---------- Fontes ----------
        _symbol(
            "bateria",
            "Bateria",
            "Fontes",
            "BT",
            [_l((-400, -2 * G), (-400, 2 * G)), _l((400, -G), (400, G)), _txt((-1300, -1500), "+")],
            _two_terminals(("1", "2"), corpo=400),
            "3.7V",
            "Battery_18650",
        ),
        _symbol(
            "fonte_tensao",
            "Fonte de tensão",
            "Fontes",
            "V",
            [_circ((0, 0), 2 * G), _txt((0, -1200), "+"), _txt((0, 1200), "−")],
            [_pin("1", 0, -3 * G, "b", G, "+"), _pin("2", 0, 3 * G, "c", G, "-")],
            "5V",
            "",
            ref=(3 * G, -G),
            val=(3 * G, G),
        ),
        _symbol(
            "fonte_corrente",
            "Fonte de corrente",
            "Fontes",
            "I",
            [
                _circ((0, 0), 2 * G),
                _l((0, 1500), (0, -1500)),
                _l((-600, -800), (0, -1500), (600, -800)),
            ],
            [_pin("1", 0, -3 * G, "b", G), _pin("2", 0, 3 * G, "c", G)],
            "1mA",
            "",
            ref=(3 * G, -G),
            val=(3 * G, G),
        ),
        # ---------- Conectores ----------
        *(_connector(n) for n in (2, 3, 4, 6, 8)),
        _ci(
            "usb_c",
            "USB-C (alimentação)",
            ["VBUS", "CC1", "CC2", "GND"],
            ["D+", "D-", "SHIELD"],
            "USB_C_Receptacle",
            "USB_C_Receptacle_GCT_USB4105",
            categoria="Conectores",
            prefixo="J",
        ),
        _ci(
            "jack_p2",
            "Jack P2 (3,5 mm)",
            ["L", "R", "GND"],
            [],
            "AudioJack3",
            "Jack_3.5mm",
            categoria="Conectores",
            prefixo="J",
        ),
        # ---------- Alimentação ----------
        _nutrition("gnd", "GND"),
        _nutrition("vcc", "VCC"),
        _nutrition("mais_5v", "+5V"),
        _nutrition("mais_3v3", "+3V3"),
        _nutrition("mais_12v", "+12V"),
        _nutrition("menos_12v", "-12V"),
    ]
    return s


SYMBOLS: list[dict[str, Any]] = _build()
POR_ID: dict[str, dict[str, Any]] = {s["id"]: s for s in SYMBOLS}
