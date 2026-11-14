from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from electronics.erc import erc
from electronics.library import POR_ID, G, U

FOLHAS = [{"id": "f1", "nome": "Folha 1"}]


def _component(
    id_: str, simbolo: str, ref: str, x: int, y: int, **extra: object
) -> dict[str, object]:
    simb = POR_ID.get(simbolo, {"valor": "", "encapsulamento": ""})
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


def _wire(id_: str, *pontos: tuple[int, int]) -> dict[str, object]:
    return {"id": id_, "folha": "f1", "pontos": [list(p) for p in pontos]}


def _label(id_: str, nome: str, x: int, y: int) -> dict[str, object]:
    return {"id": id_, "folha": "f1", "nome": nome, "x": x, "y": y}


def _codes(problemas: list[dict[str, object]]) -> list[object]:
    return sorted(p["codigo"] for p in problemas)


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, eletronica_dir=str(tmp_path))
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def test_connected_circuit_has_no_problems() -> None:
    # R1 and R2 in series between VCC and GND.
    p = {
        "componentes": [
            _component("a", "resistor", "R1", 0, 0),
            _component("b", "resistor", "R2", 6 * G, 0),
            _component("v", "vcc", "#PWR1", -3 * G, 0),
            _component("g", "gnd", "#PWR2", 9 * G, 0),
        ]
    }
    assert erc(p) == []


def test_loose_pin_loose_wire_and_single_label() -> None:
    p = {
        "componentes": [_component("a", "resistor", "R1", 0, 0)],
        "fios": [_wire("w1", (3 * G, 0), (6 * G, 0))],
        "rotulos": [_label("l1", "SINAL", -3 * G, 0)],
    }
    problems = erc(p)
    assert _codes(problems) == ["fio_solto", "pino_solto", "rede_um_pino", "rotulo_unico"]
    solto = next(x for x in problems if x["codigo"] == "pino_solto")
    assert solto["nivel"] == "erro" and solto["pinos"] == [{"ref": "R1", "pino": "2", "nome": ""}]
    fio = next(x for x in problems if x["codigo"] == "fio_solto")
    assert (fio["nivel"], fio["folha"], fio["x"], fio["y"]) == ("aviso", "f1", 6 * G, 0)
    assert problems[0]["nivel"] == "erro"


def test_shorted_outputs_undriven_inputs_and_unsourced_power() -> None:
    # Two op-amp outputs tied together; the inputs tied only to each other (the
    # wire goes through the - input of U1); V+/V- without a source.
    a = _component("a", "amp_op", "U1", 0, 0)
    b = _component("b", "amp_op", "U2", 0, 10 * U)
    p = {
        "componentes": [a, b],
        "fios": [
            _wire("w1", (3 * U, 0), (3 * U, 10 * U)),  # outputs
            _wire("w2", (-3 * U, -U), (-3 * U, 9 * U)),  # + inputs
        ],
    }
    problems = erc(p)
    codigos = _codes(problems)
    assert codigos.count("saidas_em_curto") == 1
    assert codigos.count("entrada_sem_acionamento") == 1
    assert codigos.count("alimentacao_sem_fonte") == 4
    short = next(x for x in problems if x["codigo"] == "saidas_em_curto")
    assert short["refs"] == ["U1", "U2"] and short["rede"].startswith("N$")


def test_power_with_symbol_does_not_warn() -> None:
    a = _component("a", "amp_op", "U1", 0, 0)
    p = {
        "componentes": [
            a,
            _component("v", "vcc", "#PWR1", 0, -2 * U),
            _component("g", "gnd", "#PWR2", 0, 2 * U),
        ]
    }
    assert "alimentacao_sem_fonte" not in _codes(erc(p))


def test_duplicate_ref_except_same_ic_units_and_overlap() -> None:
    symbols = {
        "Amp:LM358:1": {**POR_ID["amp_op"], "id": "Amp:LM358:1", "pinos": []},
        "Amp:LM358:2": {**POR_ID["amp_op"], "id": "Amp:LM358:2", "pinos": []},
    }

    def busca(id_: str) -> dict[str, object] | None:
        return symbols.get(id_) or POR_ID.get(id_)

    p = {
        "componentes": [
            _component("a", "Amp:LM358:1", "U1", 0, 0),
            _component("b", "Amp:LM358:2", "U1", 20 * G, 0),
            _component("c", "resistor", "R1", 0, 20 * G),
            _component("d", "resistor", "R1", 0, 20 * G),
        ],
        "fios": [_wire("w1", (-3 * G, 20 * G), (3 * G, 20 * G))],
    }
    problems = erc(p, busca)  # type: ignore[arg-type]
    assert _codes(problems) == ["componentes_sobrepostos", "ref_duplicada"]
    assert next(x for x in problems if x["codigo"] == "ref_duplicada")["refs"] == ["R1"]


def test_erc_route(api: TestClient) -> None:
    p = api.post("/api/eletronica/projetos", json={"titulo": "ERC"}).json()
    url = f"/api/eletronica/projetos/{p['id']}"
    body = {"versao": 1, "folhas": FOLHAS, "componentes": [_component("a", "resistor", "R1", 0, 0)]}
    assert api.put(f"{url}/esquematico", json=body).status_code == 200
    problems = api.get(f"{url}/erc").json()
    assert [x["codigo"] for x in problems] == ["pino_solto", "pino_solto"]
    assert api.get("/api/eletronica/projetos/" + "0" * 32 + "/erc").status_code == 404
