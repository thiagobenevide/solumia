# ruff: noqa: E501  (XML de exemplo do draw.io: as linhas são o próprio arquivo)
import base64
import zlib
from pathlib import Path
from urllib.parse import quote

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from design import drawio

MODELO = """<mxGraphModel><root><mxCell id="0"/><mxCell id="1" parent="0"/>
<mxCell id="raia" value="POST /verbas" style="swimlane;startSize=20;" vertex="1" parent="1">
  <mxGeometry x="100" y="100" width="400" height="300" as="geometry"/></mxCell>
<mxCell id="ini" value="Tela: nova verba" style="rounded=1;arcSize=50;fillColor=#e1d5e7;strokeColor=#9673a6;" vertex="1" parent="raia">
  <mxGeometry x="20" y="40" width="160" height="40" as="geometry"/></mxCell>
<mxCell id="dec" value="Tipo &lt;b&gt;válido&lt;/b&gt;?" style="rhombus;whiteSpace=wrap;html=1;fillColor=#fff2cc;" vertex="1" parent="raia">
  <mxGeometry x="20" y="120" width="160" height="80" as="geometry"/></mxCell>
<UserObject label="Erro 400" id="err"><mxCell style="rounded=0;fillColor=#f8cecc;" vertex="1" parent="raia">
  <mxGeometry x="240" y="140" width="120" height="40" as="geometry"/></mxCell></UserObject>
<mxCell id="nota" value="Atenção:&lt;br&gt;não sobrescreve" style="shape=note;" vertex="1" parent="1">
  <mxGeometry x="600" y="100" width="150" height="60" as="geometry"/></mxCell>
<mxCell id="db" value="Banco" style="shape=cylinder3;" vertex="1" parent="1">
  <mxGeometry x="600" y="200" width="80" height="80" as="geometry"/></mxCell>
<mxCell id="t" value="Título do diagrama" style="text;fontSize=16;" vertex="1" parent="1">
  <mxGeometry x="100" y="40" width="300" height="30" as="geometry"/></mxCell>
<mxCell id="e1" style="edgeStyle=orthogonalEdgeStyle;" edge="1" parent="raia" source="ini" target="dec">
  <mxGeometry relative="1" as="geometry"/></mxCell>
<mxCell id="e2" value="Não" style="edgeStyle=orthogonalEdgeStyle;strokeColor=#b85450;" edge="1" parent="raia" source="dec" target="err">
  <mxGeometry relative="1" as="geometry"/></mxCell>
</root></mxGraphModel>"""


def _comprimido(xml: str) -> str:
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return base64.b64encode(c.compress(quote(xml).encode()) + c.flush()).decode()


ARQUIVO = (
    f'<mxfile><diagram id="a" name="1. Investimento">{MODELO}</diagram>'
    f'<diagram id="b" name="2. Verbas">{_comprimido(MODELO)}</diagram></mxfile>'
)


def test_le_paginas_formas_cores_e_contêiner() -> None:
    r = drawio.read(ARQUIVO)
    assert [p["nome"] for p in r["paginas"]] == ["1. Investimento", "2. Verbas"]
    pag1 = [e for e in r["elementos"] if e["pagina"] == r["paginas"][0]["id"]]
    pag2 = [e for e in r["elementos"] if e["pagina"] == r["paginas"][1]["id"]]
    assert len(pag1) == len(pag2) == 9  # a página comprimida lê igual
    nodes = {e["id"].split(".")[1]: e for e in pag1 if e["tipo"] == "no"}
    assert {k: v["no"] for k, v in nodes.items()} == {
        "raia": "container",
        "ini": "inicio",
        "dec": "decisao",
        "err": "quadrado",
        "nota": "nota",
        "db": "banco",
    }
    assert nodes["dec"]["texto"] == "Tipo **válido**?"
    assert nodes["nota"]["texto"] == "Atenção:\nnão sobrescreve"
    assert nodes["dec"]["a"] == [120.0, 220.0]  # filho do contêiner: posição somada à do pai
    assert nodes["dec"]["fundo"] == 0xFFFFF2CC and nodes["ini"]["cor"] == 0xFF9673A6
    assert pag1[0]["no"] == "container"  # contêiner atrás dos blocos
    setas = [e for e in pag1 if e["tipo"] == "ligacao"]
    assert [(s["rotulo"], s["ortogonal"]) for s in setas] == [("", True), ("Não", True)]
    [text] = [e for e in pag1 if e["tipo"] == "texto"]
    assert text["texto"] == "Título do diagrama"


def test_ida_e_volta() -> None:
    r = drawio.read(ARQUIVO)
    of_new = drawio.read(drawio.write({"titulo": "x", **r}))
    assert [p["nome"] for p in of_new["paginas"]] == ["1. Investimento", "2. Verbas"]
    assert sorted((e["tipo"], e.get("no", "")) for e in of_new["elementos"]) == sorted(
        (e["tipo"], e.get("no", "")) for e in r["elementos"]
    )
    dec = next(e for e in of_new["elementos"] if e.get("no") == "decisao")
    assert dec["texto"] == "Tipo **válido**?" and dec["fundo"] == 0xFFFFF2CC


def test_arquivo_invalido() -> None:
    with pytest.raises(drawio.FileInvalid):
        drawio.read("<html></html>")


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, design_dir=str(tmp_path))
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def test_rotas(api: TestClient) -> None:
    r = api.post(
        "/api/design/quadros/importar-drawio",
        files={"arquivo": ("hub-verbas.drawio", ARQUIVO.encode())},
    )
    assert r.status_code == 201, r.text
    q = r.json()
    assert (q["titulo"], q["total"], len(q["paginas"])) == ("hub-verbas", 18, 2)
    complete = api.get(f"/api/design/quadros/{q['id']}").json()
    # blocos e setas de fluxograma agora gravam (antes o servidor recusava `no`/`ligacao`)
    salvo = api.put(
        f"/api/design/quadros/{q['id']}/elementos",
        json={"versao": complete["versao"], "elementos": complete["elementos"]},
    )
    assert salvo.status_code == 200
    assert (
        api.patch(
            f"/api/design/quadros/{q['id']}",
            json={"paginas": [*q["paginas"], {"id": "c", "nome": "3. Nova"}]},
        ).status_code
        == 200
    )
    x = api.get(f"/api/design/quadros/{q['id']}/drawio")
    assert x.status_code == 200 and "hub-verbas.drawio" in x.headers["content-disposition"]
    assert x.text.count("<diagram") == 3
    assert (
        api.post(
            "/api/design/quadros/importar-drawio", files={"arquivo": ("a.drawio", b"lixo")}
        ).status_code
        == 422
    )


REFERENCIA = Path(__file__).parents[3] / "modulo-verbas-atual.drawio"


@pytest.mark.skipif(
    not REFERENCIA.exists(), reason="arquivo de referência do usuário fora do repositório"
)
def test_arquivo_de_referencia_ida_e_volta() -> None:
    """O .drawio real (10 páginas): tudo vira bloco/seta/texto e volta igual na exportação."""
    r = drawio.read(REFERENCIA.read_text("utf-8"))
    assert len(r["paginas"]) == 10 and r["ignorados"] == 0
    setas = [e for e in r["elementos"] if e["tipo"] == "ligacao"]
    assert len(setas) >= 170 and any(s["tracejada"] for s in setas)
    assert any(e.get("esquerda") for e in r["elementos"] if e["tipo"] == "no")
    lap = drawio.read(drawio.write({"titulo": "x", **r}))
    assert [p["nome"] for p in lap["paginas"]] == [p["nome"] for p in r["paginas"]]
    assert len(lap["elementos"]) == len(r["elementos"])
    assert sum(1 for e in lap["elementos"] if e.get("tracejada")) == sum(
        1 for s in setas if s["tracejada"]
    )
