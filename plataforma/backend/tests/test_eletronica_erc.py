from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from eletronica.biblioteca import POR_ID, G, U
from eletronica.erc import erc

FOLHAS = [{"id": "f1", "nome": "Folha 1"}]


def _comp(id_: str, simbolo: str, ref: str, x: int, y: int, **extra: object) -> dict[str, object]:
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


def _fio(id_: str, *pontos: tuple[int, int]) -> dict[str, object]:
    return {"id": id_, "folha": "f1", "pontos": [list(p) for p in pontos]}


def _rotulo(id_: str, nome: str, x: int, y: int) -> dict[str, object]:
    return {"id": id_, "folha": "f1", "nome": nome, "x": x, "y": y}


def _codigos(problemas: list[dict[str, object]]) -> list[object]:
    return sorted(p["codigo"] for p in problemas)


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, eletronica_dir=str(tmp_path))
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def test_circuito_ligado_nao_tem_problemas() -> None:
    # R1 e R2 em série entre VCC e GND.
    p = {
        "componentes": [
            _comp("a", "resistor", "R1", 0, 0),
            _comp("b", "resistor", "R2", 6 * G, 0),
            _comp("v", "vcc", "#PWR1", -3 * G, 0),
            _comp("g", "gnd", "#PWR2", 9 * G, 0),
        ]
    }
    assert erc(p) == []


def test_pino_solto_fio_solto_e_rotulo_unico() -> None:
    p = {
        "componentes": [_comp("a", "resistor", "R1", 0, 0)],
        "fios": [_fio("w1", (3 * G, 0), (6 * G, 0))],
        "rotulos": [_rotulo("l1", "SINAL", -3 * G, 0)],
    }
    problemas = erc(p)
    assert _codigos(problemas) == ["fio_solto", "pino_solto", "rede_um_pino", "rotulo_unico"]
    solto = next(x for x in problemas if x["codigo"] == "pino_solto")
    assert solto["nivel"] == "erro" and solto["pinos"] == [{"ref": "R1", "pino": "2", "nome": ""}]
    fio = next(x for x in problemas if x["codigo"] == "fio_solto")
    assert (fio["nivel"], fio["folha"], fio["x"], fio["y"]) == ("aviso", "f1", 6 * G, 0)
    assert problemas[0]["nivel"] == "erro"


def test_saidas_em_curto_entradas_sem_acionamento_e_alimentacao_sem_fonte() -> None:
    # Duas saídas de amp-op ligadas; as entradas ligadas só entre si (o fio
    # passa pela entrada - de U1); V+/V- sem fonte.
    a = _comp("a", "amp_op", "U1", 0, 0)
    b = _comp("b", "amp_op", "U2", 0, 10 * U)
    p = {
        "componentes": [a, b],
        "fios": [
            _fio("w1", (3 * U, 0), (3 * U, 10 * U)),  # saídas
            _fio("w2", (-3 * U, -U), (-3 * U, 9 * U)),  # entradas +
        ],
    }
    problemas = erc(p)
    codigos = _codigos(problemas)
    assert codigos.count("saidas_em_curto") == 1
    assert codigos.count("entrada_sem_acionamento") == 1
    assert codigos.count("alimentacao_sem_fonte") == 4
    curto = next(x for x in problemas if x["codigo"] == "saidas_em_curto")
    assert curto["refs"] == ["U1", "U2"] and curto["rede"].startswith("N$")


def test_alimentacao_com_simbolo_nao_avisa() -> None:
    a = _comp("a", "amp_op", "U1", 0, 0)
    p = {
        "componentes": [
            a,
            _comp("v", "vcc", "#PWR1", 0, -2 * U),
            _comp("g", "gnd", "#PWR2", 0, 2 * U),
        ]
    }
    assert "alimentacao_sem_fonte" not in _codigos(erc(p))


def test_ref_duplicada_menos_unidades_do_mesmo_ci_e_sobreposicao() -> None:
    simbolos = {
        "Amp:LM358:1": {**POR_ID["amp_op"], "id": "Amp:LM358:1", "pinos": []},
        "Amp:LM358:2": {**POR_ID["amp_op"], "id": "Amp:LM358:2", "pinos": []},
    }

    def busca(id_: str) -> dict[str, object] | None:
        return simbolos.get(id_) or POR_ID.get(id_)

    p = {
        "componentes": [
            _comp("a", "Amp:LM358:1", "U1", 0, 0),
            _comp("b", "Amp:LM358:2", "U1", 20 * G, 0),
            _comp("c", "resistor", "R1", 0, 20 * G),
            _comp("d", "resistor", "R1", 0, 20 * G),
        ],
        "fios": [_fio("w1", (-3 * G, 20 * G), (3 * G, 20 * G))],
    }
    problemas = erc(p, busca)  # type: ignore[arg-type]
    assert _codigos(problemas) == ["componentes_sobrepostos", "ref_duplicada"]
    assert next(x for x in problemas if x["codigo"] == "ref_duplicada")["refs"] == ["R1"]


def test_rota_erc(api: TestClient) -> None:
    p = api.post("/api/eletronica/projetos", json={"titulo": "ERC"}).json()
    url = f"/api/eletronica/projetos/{p['id']}"
    corpo = {"versao": 1, "folhas": FOLHAS, "componentes": [_comp("a", "resistor", "R1", 0, 0)]}
    assert api.put(f"{url}/esquematico", json=corpo).status_code == 200
    problemas = api.get(f"{url}/erc").json()
    assert [x["codigo"] for x in problemas] == ["pino_solto", "pino_solto"]
    assert api.get("/api/eletronica/projetos/" + "0" * 32 + "/erc").status_code == 404
