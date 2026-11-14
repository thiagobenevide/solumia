import json
import time
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from design import flows

FLUXO = {
    "titulo": "Venda a prazo",
    "nos": [
        {"id": "i", "tipo": "inicio", "texto": "Pedido recebido"},
        {"id": "d", "tipo": "decisão", "texto": "Cliente tem crédito?"},
        {"id": "a", "tipo": "processo", "texto": "Aprovar venda"},
        {"id": "r", "tipo": "processo", "texto": "Pedir análise manual"},
        {"id": "f", "tipo": "fim", "texto": "Fim"},
    ],
    "ligacoes": [
        {"de": "i", "para": "d"},
        {"de": "d", "para": "a", "rotulo": "Sim"},
        {"de": "d", "para": "r", "rotulo": "Não"},
        {"de": "r", "para": "d", "rotulo": "reavaliar"},  # laço de volta
        {"de": "a", "para": "f"},
        {"de": "a", "para": "x"},  # nó inexistente: descartada
    ],
}


def test_extrai_json_de_resposta_com_think_e_cerca() -> None:
    answer = (
        "<think>pensando {não é json}</think>\nAqui está:\n```json\n" + json.dumps(FLUXO) + "\n```"
    )
    assert flows.extract_json(answer)["titulo"] == "Venda a prazo"
    with pytest.raises(flows.FlowInvalid):
        flows.extract_json("sem fluxo")


def test_valida_e_posiciona_em_camadas() -> None:
    f = flows.position(flows.validate(FLUXO))
    nodes = {n["id"]: n for n in f["nos"]}
    assert nodes["d"]["tipo"] == "decisao"
    assert len(f["ligacoes"]) == 5
    # início em cima, decisão abaixo, os dois ramos lado a lado abaixo dela, o fim por último
    assert nodes["i"]["y"] < nodes["d"]["y"] < nodes["a"]["y"] == nodes["r"]["y"] < nodes["f"]["y"]
    assert (
        nodes["a"]["x"] + nodes["a"]["w"] <= nodes["r"]["x"]
        or nodes["r"]["x"] + nodes["r"]["w"] <= nodes["a"]["x"]
    )


def test_mensagens_levam_codigo_cortado_e_fluxo_atual() -> None:
    m = flows.assemble_messages(
        "detalhe",
        codigo="x" * (flows.MAX_CODE + 10),
        arquivo="a.py",
        atual=flows.position(flows.validate(FLUXO)),
    )
    user = m[1]["content"]
    assert "código cortado" in user and "a.py" in user and '"Cliente tem crédito?"' in user
    assert '"x":' not in user  # posições não vão para a IA


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, design_dir=str(tmp_path))
    app = create_app(settings=s)
    answers = ["não sei", json.dumps(FLUXO)]  # a primeira falha e a rota pede de novo

    async def llm(mensagens: list[dict[str, str]]) -> str:
        return answers.pop(0)

    app.state.design_llms = {"local": llm}
    return TestClient(app, headers=AUTH_HEADERS)


def test_rota_gera_por_tarefa(api: TestClient) -> None:
    assert api.get("/api/design/fluxos/provedores").json() == ["local"]
    assert api.post("/api/design/fluxos/gerar", json={}).status_code == 422
    assert (
        api.post("/api/design/fluxos/gerar", json={"pedido": "x", "provedor": "claude"}).status_code
        == 503
    )
    t = api.post("/api/design/fluxos/gerar", json={"pedido": "venda a prazo"})
    assert t.status_code == 202
    for _ in range(50):
        r = api.get(f"/api/design/fluxos/tarefas/{t.json()['id']}").json()
        if r["estado"] != "gerando":
            break
        time.sleep(0.02)
    assert r["estado"] == "pronto" and len(r["fluxo"]["nos"]) == 5
    assert api.get("/api/design/fluxos/tarefas/nada").status_code == 404
