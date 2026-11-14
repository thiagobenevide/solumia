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
    resposta = (
        "<think>pensando {não é json}</think>\nAqui está:\n```json\n" + json.dumps(FLUXO) + "\n```"
    )
    assert flows.extrair_json(resposta)["titulo"] == "Venda a prazo"
    with pytest.raises(flows.FluxoInvalido):
        flows.extrair_json("sem fluxo")


def test_valida_e_posiciona_em_camadas() -> None:
    f = flows.posicionar(flows.validar(FLUXO))
    nos = {n["id"]: n for n in f["nos"]}
    assert nos["d"]["tipo"] == "decisao"
    assert len(f["ligacoes"]) == 5
    # início em cima, decisão abaixo, os dois ramos lado a lado abaixo dela, o fim por último
    assert nos["i"]["y"] < nos["d"]["y"] < nos["a"]["y"] == nos["r"]["y"] < nos["f"]["y"]
    assert (
        nos["a"]["x"] + nos["a"]["w"] <= nos["r"]["x"]
        or nos["r"]["x"] + nos["r"]["w"] <= nos["a"]["x"]
    )


def test_mensagens_levam_codigo_cortado_e_fluxo_atual() -> None:
    m = flows.montar_mensagens(
        "detalhe",
        codigo="x" * (flows.MAX_CODIGO + 10),
        arquivo="a.py",
        atual=flows.posicionar(flows.validar(FLUXO)),
    )
    usuario = m[1]["content"]
    assert "código cortado" in usuario and "a.py" in usuario and '"Cliente tem crédito?"' in usuario
    assert '"x":' not in usuario  # posições não vão para a IA


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, design_dir=str(tmp_path))
    app = create_app(settings=s)
    respostas = ["não sei", json.dumps(FLUXO)]  # a primeira falha e a rota pede de novo

    async def llm(mensagens: list[dict[str, str]]) -> str:
        return respostas.pop(0)

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
