import asyncio
import base64
import shutil
from pathlib import Path
from typing import Any

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from eletronica import spice
from eletronica.biblioteca import POR_ID
from shared.ngspice import run_ngspice

NGSPICE = shutil.which("ngspice") is not None


def _c(simbolo: str, ref: str, valor: str | None = None) -> dict[str, Any]:
    return {"simbolo": simbolo, "ref": ref, "valor": valor or POR_ID[simbolo]["valor"]}


def _rede(nome: str, *pinos: tuple[str, str]) -> dict[str, Any]:
    return {"nome": nome, "pinos": [{"ref": r, "pino": p, "nome": ""} for r, p in pinos]}


DIVISOR = {
    "titulo": "Divisor",
    "componentes": [_c("fonte_tensao", "V1", "5V"), _c("resistor", "R1"), _c("resistor", "R2")],
}
REDES_DIVISOR = {
    "redes": [
        _rede("VIN", ("V1", "1"), ("R1", "1")),
        _rede("VOUT", ("R1", "2"), ("R2", "1")),
        _rede("GND", ("V1", "2"), ("R2", "2")),
    ],
    "soltos": [],
}

RAW_OP = b"""Title: * Divisor
Date: Thu Oct 30 10:00:00  2026
Plotname: Operating Point
Flags: real
No. Variables: 4
No. Points: 1
Variables:
\t0\tv(vin)\tvoltage
\t1\tv(vout)\tvoltage
\t2\ti(v1)\tcurrent
\t3\t@r1[i]\tcurrent
Values:
 0\t5.000000000000000e+00
\t2.500000000000000e+00
\t-2.500000000000000e-04
\t2.500000000000000e-04
"""

RAW_AC = b"""Title: * RC
Plotname: AC Analysis
Flags: complex
No. Variables: 2
No. Points: 2
Variables:
\t0\tfrequency\tfrequency\tgrid=3
\t1\tv(vout)\tvoltage
Values:
 0\t1.0e+01,0.0e+00
\t1.0e+00,0.0e+00
 1\t1.0e+03,0.0e+00
\t5.0e-01,-5.0e-01
"""


@pytest.fixture
def app(tmp_path: Path) -> Any:
    return create_app(
        settings=Settings(client_api_keys=CLIENT_API_KEY, eletronica_dir=str(tmp_path))
    )


@pytest.fixture
def api(app: Any) -> TestClient:
    return TestClient(app, headers=AUTH_HEADERS)


def test_valores_em_notacao_spice() -> None:
    casos = {
        "10k": "10k",
        "100n": "100n",
        "4u7": "4.7u",
        "4k7": "4.7k",
        "1R5": "1.5",
        "5V": "5",
        "1mA": "1m",
        "1M": "1Meg",
        "2.2nF": "2.2n",
        "100µF": "100u",
        "5V1": "5.1",
        "10 kΩ": "10k",
        "1e-6": "1e-6",
        "1kHz": "1k",
        "2,2u": "2.2u",
    }
    assert {t: spice.valor_spice(t) for t in casos} == casos
    assert spice.valor_spice("NTC 10k") is None
    assert spice.numero("4.7u") == pytest.approx(4.7e-6)
    assert spice.numero("1Meg") == 1e6


def test_divisor_resistivo_vira_netlist_com_gnd_no_zero() -> None:
    g = spice.gerar(DIVISOR, rede=REDES_DIVISOR)
    linhas = g["texto"].splitlines()
    assert "V1 VIN 0 DC 5" in linhas
    assert "R1 VIN VOUT 10k" in linhas
    assert "R2 VOUT 0 10k" in linhas
    assert linhas[-2:] == [".op", ".end"]
    assert g["fontes"] == ["V1"] and g["ignorados"] == []
    assert g["nos"] == {"vin": "VIN", "vout": "VOUT"}


def test_rc_transiente_ac_e_componente_sem_modelo() -> None:
    projeto = {
        "componentes": [
            _c("fonte_tensao", "V1", "PULSE(0 5V 0 1n 1n 2.5ms 5ms)"),
            _c("resistor", "R1", "1k"),
            _c("capacitor", "C1", "100n"),
            _c("ne555", "U1"),
            _c("mais_5v", "#PWR1"),
            _c("led", "D1", "Verde"),
        ],
    }
    redes = {
        "redes": [
            _rede("N$1", ("V1", "1"), ("R1", "1")),
            _rede("VOUT", ("R1", "2"), ("C1", "1")),
            _rede("GND", ("V1", "2"), ("C1", "2"), ("U1", "1"), ("D1", "1")),
            _rede("+5V", ("U1", "8"), ("D1", "2")),
        ],
        "soltos": [],
    }
    g = spice.gerar(projeto, analise="tran", parametros={"passo": "1u", "fim": "5m"}, rede=redes)
    linhas = g["texto"].splitlines()
    assert "V1 N_1 0 PULSE(0 5 0 1n 1n 2.5m 5m)" in linhas
    assert "C1 VOUT 0 100n" in linhas
    assert "D1 P5V 0 LED_VERDE" in linhas
    assert any(lin.startswith(".model LED_VERDE D(") for lin in linhas)
    assert "VALIM_P5V P5V 0 DC 5" in linhas
    assert ".tran 1u 5m" in linhas
    assert [i["ref"] for i in g["ignorados"]] == ["U1"]
    assert g["eixo"] == {"nome": "tempo", "unidade": "s"}

    ac = spice.gerar(
        projeto, analise="ac", parametros={"pontos": 10, "inicio": "10", "fim": "100k"}, rede=redes
    )
    assert ".ac dec 10 10 100k" in ac["texto"]
    assert "PULSE(0 5 0 1n 1n 2.5m 5m) AC 1" in ac["texto"]
    dc = spice.gerar(
        projeto,
        analise="dc",
        rede=redes,
        parametros={"fonte": "V1", "inicio": "0", "fim": "5", "passo": "0.1"},
    )
    assert ".dc V1 0 5 0.1" in dc["texto"] and dc["eixo"] == {"nome": "V1", "unidade": "V"}
    with pytest.raises(ValueError, match="Fonte"):
        spice.gerar(projeto, analise="dc", parametros={"fonte": "V9"}, rede=redes)


def test_le_raw_ascii_do_ngspice() -> None:
    nos = {"vin": "VIN", "vout": "VOUT"}
    op = spice.resultado("op", spice.ler_raw(RAW_OP), nos)
    assert op == {
        "analise": "op",
        "tensoes": {"VIN": 5.0, "VOUT": 2.5},
        "correntes": {"V1": -2.5e-4, "R1": 2.5e-4},
    }
    eixo = {"nome": "frequência", "unidade": "Hz"}
    ac = spice.resultado("ac", spice.ler_raw(RAW_AC), nos, eixo)
    assert ac["eixo"] == {**eixo, "valores": [10.0, 1000.0]}
    assert ac["series"]["v(VOUT)"] == pytest.approx([1.0, 0.5**0.5])
    assert ac["fases"]["v(VOUT)"] == pytest.approx([0.0, -45.0])


def test_rotas_spice_e_simulacao_com_executor_falso(app: Any, api: TestClient) -> None:
    p = api.post("/api/eletronica/projetos", json={"titulo": "R"}).json()
    url = f"/api/eletronica/projetos/{p['id']}"
    r = api.get(f"{url}/spice")
    assert r.status_code == 200 and r.json()["texto"].splitlines()[-1] == ".end"
    assert api.post(f"{url}/simular", json={"analise": "tran"}).status_code == 422
    assert api.get("/api/eletronica/projetos/nada/spice").status_code == 404

    async def falso(netlist: str) -> dict[str, Any]:
        return {"raw_b64": base64.b64encode(RAW_OP).decode(), "log": "ok", "codigo": 0}

    sims = app.state.simulacoes_eletronica
    sims.executar, sims.disponivel = falso, lambda: None
    r = api.post(f"{url}/simular", json={"analise": "op"})
    assert r.status_code == 202 and r.json()["estado"] == "fila"
    t = api.get(f"/api/eletronica/simulacoes/{r.json()['id']}").json()
    assert t["estado"] == "pronto" and t["resultado"]["analise"] == "op"
    assert api.get("/api/eletronica/simulacoes/nada").status_code == 404


@pytest.mark.skipif(NGSPICE, reason="com ngspice instalado o backend simula localmente")
def test_sem_worker_nem_ngspice_responde_503(api: TestClient) -> None:
    p = api.post("/api/eletronica/projetos", json={}).json()
    r = api.post(f"/api/eletronica/projetos/{p['id']}/simular", json={"analise": "op"})
    assert r.status_code == 503 and "ngspice" in r.json()["detail"]


@pytest.mark.skipif(not NGSPICE, reason="ngspice não instalado")
def test_divisor_no_ngspice_de_verdade() -> None:
    g = spice.gerar(DIVISOR, rede=REDES_DIVISOR)
    r = asyncio.run(run_ngspice(g["texto"], 30))
    res = spice.resultado("op", spice.ler_raw(base64.b64decode(r["raw_b64"])), g["nos"])
    assert res["tensoes"]["VOUT"] == pytest.approx(2.5)
