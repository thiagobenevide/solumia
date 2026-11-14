from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from eletronica.library import POR_ID, SIMBOLOS, G
from eletronica.netlist import bom, netlist, posicao_pino

FOLHAS = [{"id": "f1", "nome": "Folha 1"}, {"id": "f2", "nome": "Fonte"}]


def _comp(id_: str, simbolo: str, ref: str, x: int, y: int, **extra: object) -> dict[str, object]:
    simb = POR_ID[simbolo]
    return {
        "id": id_,
        "folha": "f1",
        "simbolo": simbolo,
        "ref": ref,
        "valor": simb["valor"],
        "encapsulamento": simb["encapsulamento"],
        "x": x,
        "y": y,
        "rot": 0,
        "espelho": False,
        **extra,
    }


def _fio(id_: str, *pontos: tuple[int, int], folha: str = "f1") -> dict[str, object]:
    return {"id": id_, "folha": folha, "pontos": [list(p) for p in pontos]}


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, eletronica_dir=str(tmp_path))
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def test_pinos_da_biblioteca_ficam_na_grade() -> None:
    for s in SIMBOLOS:
        assert s["pinos"], s["id"]
        for p in s["pinos"]:
            assert p["x"] % G == 0 and p["y"] % G == 0, (s["id"], p)


def test_posicao_pino_gira_no_sentido_horario_e_espelha() -> None:
    pino = {"x": -3 * G, "y": 0}
    c = {"x": 100, "y": 200, "rot": 90}
    assert posicao_pino(c, pino) == (100, 200 - 3 * G)
    assert posicao_pino({**c, "rot": 0, "espelho": True}, pino) == (100 + 3 * G, 200)


def test_divisor_de_tensao_com_rotulo_entre_folhas() -> None:
    # R1 e R2 em série por um fio; a ponta esquerda de R1 vai ao rótulo VIN, a direita de R2 ao GND.
    r1 = _comp("a", "resistor", "R1", 0, 0)
    r2 = _comp("b", "resistor", "R2", 10 * G, 0)
    gnd = _comp("g", "gnd", "#PWR1", 13 * G, 0)
    p = {
        "folhas": FOLHAS,
        "componentes": [r1, r2, gnd, {**_comp("c", "conector_2", "J1", 0, 0), "folha": "f2"}],
        "fios": [
            _fio("w1", (3 * G, 0), (7 * G, 0)),
            _fio("w2", (-3 * G, 0), (-3 * G, -4 * G)),
            # Na outra folha, o pino 1 do conector (-5080, -1270) vai ao rótulo VIN.
            _fio("w3", (-4 * G, -G), (-6 * G, -G), folha="f2"),
        ],
        "rotulos": [
            {"id": "l1", "folha": "f1", "nome": "VIN", "x": -3 * G, "y": -4 * G},
            {"id": "l2", "folha": "f2", "nome": "VIN", "x": -6 * G, "y": -G},
        ],
    }
    n = netlist(p)
    redes = {r["nome"]: {(x["ref"], x["pino"]) for x in r["pinos"]} for r in n["redes"]}
    assert redes["VIN"] == {("R1", "1"), ("J1", "1")}
    assert redes["GND"] == {("R2", "2")}
    assert redes["N$1"] == {("R1", "2"), ("R2", "1")}
    assert n["soltos"] == [{"ref": "J1", "pino": "2", "nome": ""}]


def test_ponta_no_meio_do_fio_liga_e_cruzamento_nao() -> None:
    r1 = _comp("a", "resistor", "R1", 0, 0)
    r2 = _comp("b", "resistor", "R2", 3 * G, -6 * G, rot=90)  # pinos em (3G, -9G) e (3G, -3G)
    p = {
        "folhas": FOLHAS[:1],
        "componentes": [r1, r2],
        "fios": [
            _fio("w1", (3 * G, 0), (8 * G, 0)),
            _fio("w2", (3 * G, -3 * G), (3 * G, 0)),
            _fio("w3", (5 * G, -2 * G), (5 * G, 2 * G)),  # só cruza w1
            _fio("w4", (5 * G, 2 * G), (6 * G, 2 * G)),
        ],
    }
    [rede] = netlist(p)["redes"]
    assert {(x["ref"], x["pino"]) for x in rede["pinos"]} == {("R1", "2"), ("R2", "2")}


def test_bom_agrupa_por_valor_e_ignora_alimentacao() -> None:
    p = {
        "componentes": [
            _comp("a", "resistor", "R10", 0, 0),
            _comp("b", "resistor", "R2", 0, 0),
            _comp("c", "resistor", "R3", 0, 0, valor="1k"),
            _comp("g", "gnd", "#PWR1", 0, 0),
        ]
    }
    linhas = bom(p)
    assert [(linha["refs"], linha["valor"]) for linha in linhas] == [
        (["R2", "R10"], "10k"),
        (["R3"], "1k"),
    ]


def test_criar_salvar_conflito_e_bom(api: TestClient) -> None:
    assert api.get("/api/eletronica/biblioteca").json()[0]["id"] == "resistor"
    p = api.post("/api/eletronica/projetos", json={"titulo": "Fonte 5V"}).json()
    assert p["versao"] == 1 and p["folhas"][0]["id"] == "f1"

    url = f"/api/eletronica/projetos/{p['id']}"
    corpo = {"versao": 1, "folhas": FOLHAS[:1], "componentes": [_comp("a", "resistor", "R1", 0, 0)]}
    r = api.put(f"{url}/esquematico", json=corpo)
    assert r.status_code == 200 and r.json()["versao"] == 2 and r.json()["total"] == 1

    r = api.put(f"{url}/esquematico", json=corpo)
    assert r.status_code == 409 and r.json()["projeto"]["versao"] == 2

    assert api.get(f"{url}/bom").json()[0]["refs"] == ["R1"]
    assert "R1" in api.get(f"{url}/bom.csv").text
    [resumo] = api.get("/api/eletronica/projetos").json()
    assert "componentes" not in resumo


def test_rejeita_simbolo_desconhecido_e_folha_inexistente(api: TestClient) -> None:
    p = api.post("/api/eletronica/projetos", json={}).json()
    url = f"/api/eletronica/projetos/{p['id']}/esquematico"
    ruim = {**_comp("a", "resistor", "R1", 0, 0), "simbolo": "flux_capacitor"}
    assert (
        api.put(url, json={"versao": 1, "folhas": FOLHAS, "componentes": [ruim]}).status_code == 422
    )
    fora = {**_comp("a", "resistor", "R1", 0, 0), "folha": "f9"}
    assert (
        api.put(url, json={"versao": 1, "folhas": FOLHAS, "componentes": [fora]}).status_code == 422
    )


# ---------- Importador do KiCad ----------

KICAD = r"""(kicad_symbol_lib
  (version 20241209)
  (symbol "R" (pin_numbers (hide yes)) (pin_names (offset 0) (hide yes))
    (property "Reference" "R" (at 2.032 0 90))
    (property "Value" "R" (at 0 0 90))
    (property "Footprint" "" (at -1.778 0 90))
    (property "Description" "Resistor" (at 0 0 0))
    (property "ki_keywords" "R res resistor" (at 0 0 0))
    (symbol "R_0_1" (rectangle (start -1.016 -2.54) (end 1.016 2.54) (fill (type none))))
    (symbol "R_1_1"
      (pin passive line (at 0 3.81 270) (length 1.27) (name "~") (number "1"))
      (pin passive line (at 0 -3.81 90) (length 1.27) (name "~") (number "2"))))
  (symbol "R_US" (extends "R") (property "Value" "R_US" (at 0 0 0))
    (property "Description" "Resistor US"))
  (symbol "L" (symbol "L_0_1"
      (arc (start 0 2.54) (mid 0.6323 1.905) (end 0 1.27)))
    (symbol "L_1_1" (pin passive line (at 0 3.81 270) (length 1.27) (name "1") (number "1")))
    (property "Reference" "L" (at 0 0 0)))
  (symbol "LM358" (property "Reference" "U" (at 0 5.08 0)) (property "Value" "LM358" (at 0 -5.08 0))
    (property "Description" "Dual \"op-amp\"")
    (symbol "LM358_1_1" (polyline (pts (xy -5.08 5.08) (xy 5.08 0) (xy -5.08 -5.08) (xy -5.08 5.08))
        (fill (type background)))
      (pin output line (at 7.62 0 180) (length 2.54) (name "~") (number "1"))
      (pin input line (at -7.62 2.54 0) (length 2.54) (name "+") (number "3")))
    (symbol "LM358_2_1"
      (pin output line (at 7.62 0 180) (length 2.54) (name "~") (number "7")))
    (symbol "LM358_3_1"
      (pin power_in line (at -2.54 7.62 270) (length 3.81) (name "V+") (number "8")))
    (symbol "LM358_1_2"
      (pin output line (at 9 9 180) (length 2.54) (name "demorgan") (number "1"))))
  (symbol "GND" (power) (property "Reference" "#PWR" (at 0 -6.35 0))
    (property "Value" "GND" (at 0 -3.81 0))
    (symbol "GND_1_1"
      (pin power_in line (at 0 0 270) (length 0) (hide yes) (name "GND") (number "1"))))
)"""


def test_kicad_converte_eixos_unidades_extends_e_arco() -> None:
    from eletronica.kicad import ler_biblioteca

    s = {x["id"]: x for x in ler_biblioteca(KICAD, "Teste")}
    r = s["Teste:R"]
    assert [(p["n"], p["x"], p["y"], p["dir"], p["comp"]) for p in r["pinos"]] == [
        ("1", 0, -3810, "b", 1270),
        ("2", 0, 3810, "c", 1270),
    ]
    assert r["desenho"][0] == {"t": "ret", "a": [-1016, 2540], "b": [1016, -2540], "cheio": False}
    assert r["prefixo"] == "R" and not r["nomes_pinos"] and not r["numeros_pinos"]
    assert r["campos"]["ref"] == [2032, 0] and r["pinos"][0]["nome"] == ""
    us = s["Teste:R_US"]
    assert us["valor"] == "R_US" and us["descricao"] == "Resistor US" and len(us["pinos"]) == 2
    arco = s["Teste:L"]["desenho"][0]
    assert arco["r"] == 635 and arco["var"] == pytest.approx(179.46, abs=0.5)
    # Três unidades; o estilo De Morgan (_1_2) não entra.
    assert [x for x in s if x.startswith("Teste:LM358")] == [f"Teste:LM358:{u}" for u in (1, 2, 3)]
    a = s["Teste:LM358:1"]
    assert a["nome"] == "LM358 (A)" and [p["n"] for p in a["pinos"]] == ["1", "3"]
    assert a["pinos"][0]["tipo"] == "saida" and a["descricao"] == 'Dual "op-amp"'
    assert s["Teste:LM358:3"]["pinos"][0]["tipo"] == "alimentacao"
    gnd = s["Teste:GND"]
    assert gnd["tipo"] == "alimentacao" and gnd["pinos"][0]["oculto"]


def test_kicad_rejeita_o_que_nao_e_biblioteca() -> None:
    from eletronica.kicad import ArquivoInvalido, ler_biblioteca

    for ruim in ["(kicad_pcb (version 1))", "(kicad_symbol_lib (symbol", "texto solto"]:
        with pytest.raises(ArquivoInvalido):
            ler_biblioteca(ruim, "X")


def test_importar_buscar_usar_no_projeto_e_remover(api: TestClient) -> None:
    r = api.post(
        "/api/eletronica/bibliotecas/importar",
        files={"arquivo": ("Teste.kicad_sym", KICAD.encode(), "application/octet-stream")},
    )
    assert r.status_code == 201 and r.json()["total"] == 7
    assert [b["nome"] for b in api.get("/api/eletronica/bibliotecas").json()] == ["Teste"]

    achados = api.get("/api/eletronica/biblioteca/busca", params={"q": "resistor"}).json()
    assert [s["id"] for s in achados] == ["Teste:R", "Teste:R_US"]
    assert api.get("/api/eletronica/biblioteca/busca", params={"q": "op-amp"}).json()
    ids = {"ids": ["Teste:L", "resistor", "Teste:nada"]}
    assert [s["id"] for s in api.post("/api/eletronica/biblioteca/simbolos", json=ids).json()] == [
        "Teste:L",
        "resistor",
    ]

    # Duas unidades do mesmo CI contam uma vez na lista de peças.
    p = api.post("/api/eletronica/projetos", json={}).json()
    url = f"/api/eletronica/projetos/{p['id']}"
    comps = [
        {**_comp("a", "resistor", "U1", 0, 0), "simbolo": "Teste:LM358:1", "valor": "LM358"},
        {**_comp("b", "resistor", "U1", 0, 0), "simbolo": "Teste:LM358:2", "valor": "LM358"},
    ]
    r = api.put(f"{url}/esquematico", json={"versao": 1, "folhas": FOLHAS, "componentes": comps})
    assert r.status_code == 200 and r.json()["total"] == 2
    [linha] = api.get(f"{url}/bom").json()
    assert linha["refs"] == ["U1"] and linha["descricao"] == "LM358"

    assert api.delete("/api/eletronica/bibliotecas/Teste").status_code == 204
    assert api.get("/api/eletronica/bibliotecas").json() == []
    assert api.get(f"{url}/netlist").status_code == 200  # símbolo sumido não derruba


def test_baixar_do_kicad_usa_a_versao_configurada(
    api: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    import httpx

    from eletronica import api as rotas

    pedidos: list[str] = []

    async def falso(self: httpx.AsyncClient, url: str, **_: object) -> httpx.Response:
        pedidos.append(url)
        if url.endswith("/Device.kicad_sym"):
            return httpx.Response(200, text=KICAD)
        return httpx.Response(404, text="Not Found")

    monkeypatch.setattr(rotas.httpx.AsyncClient, "get", falso)
    r = api.post("/api/eletronica/bibliotecas/kicad", json={"nomes": ["Device", "Nada", "../x"]})
    device, nada, ruim = r.json()
    assert device["total"] == 7 and device["origem"] == "kicad 9.0.9"
    assert "HTTP 404" in nada["erro"] and "inválido" in ruim["erro"]
    assert pedidos[0].endswith("/-/raw/9.0.9/Device.kicad_sym") and len(pedidos) == 2
    assert "Device" in api.get("/api/eletronica/bibliotecas/kicad").json()["sugeridas"]


def test_sondas_acham_a_rede_e_validam(api: TestClient) -> None:
    r1 = _comp("a", "resistor", "R1", 0, 0)
    r2 = _comp("b", "resistor", "R2", 10 * G, 0)
    p = {
        "folhas": FOLHAS[:1],
        "componentes": [r1, r2],
        "fios": [_fio("w1", (3 * G, 0), (7 * G, 0))],
        "rotulos": [{"id": "l1", "folha": "f1", "nome": "VIN", "x": -3 * G, "y": 0}],
        "sondas": [
            {"id": "s1", "folha": "f1", "tipo": "v", "x": 5 * G, "y": 0},  # meio do fio
            {"id": "s2", "folha": "f1", "tipo": "v", "x": -3 * G, "y": 0},  # no rótulo
            {"id": "s3", "folha": "f1", "tipo": "v", "x": 0, "y": 9 * G},  # no vazio
            {"id": "s4", "folha": "f1", "tipo": "i", "ref": "R1", "x": 0, "y": 0},
        ],
    }
    sondas = {s["id"]: s for s in netlist(p)["sondas"]}
    assert sondas["s1"]["rede"] == "N$1" and sondas["s2"]["rede"] == "VIN"
    assert sondas["s3"]["rede"] is None and sondas["s4"] == {"id": "s4", "tipo": "i", "ref": "R1"}

    q = api.post("/api/eletronica/projetos", json={}).json()
    url = f"/api/eletronica/projetos/{q['id']}/esquematico"
    assert api.put(url, json={"versao": 1, **p}).status_code == 200
    ruim = {**p, "sondas": [{"id": "x", "folha": "f1", "tipo": "w", "x": 0, "y": 0}]}
    assert api.put(url, json={"versao": 2, **ruim}).status_code == 422
    sondas = api.get(f"/api/eletronica/projetos/{q['id']}/netlist").json()["sondas"]
    assert [s["id"] for s in sondas] == ["s1", "s2", "s3", "s4"]
