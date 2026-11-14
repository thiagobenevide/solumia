from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.files.rewrite import Rewrite
from backend.main import create_app
from shared.claude_code import InvalidRewriteRequest, build_rewrite_prompt


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(
        client_api_keys=CLIENT_API_KEY, arquivos_dir=str(tmp_path), notas_dir=str(tmp_path)
    )
    app = create_app(settings=s)
    requests: list[dict] = []

    async def executar(pedido: dict) -> dict:
        requests.append(pedido)
        return {"texto": "Realizou-se o teste.", "mudancas": [], "observacoes": ""}

    app.state.reescrita = Rewrite(executar, lambda: None)
    app.state.requests = requests
    return TestClient(app, headers=AUTH_HEADERS)


def test_prompt_brings_context_feedback_and_excerpt() -> None:
    p = build_rewrite_prompt(
        {
            "trecho": "a gente testou",
            "objetivo": "feedback",
            "feedback": "seja impessoal",
            "contexto": "Cap. 1",
        }
    )
    assert p.index("<documento>") < p.index("seja impessoal") < p.index("<trecho>")
    with pytest.raises(InvalidRewriteRequest):
        build_rewrite_prompt({"trecho": "x", "objetivo": "feedback"})
    with pytest.raises(InvalidRewriteRequest):
        build_rewrite_prompt({"trecho": "x", "objetivo": "inventado"})


def test_route_rewrites_and_validates(api: TestClient) -> None:
    assert api.get("/api/arquivos/reescrita").json()["indisponivel"] is None
    r = api.post(
        "/api/arquivos/reescrever", json={"trecho": "a gente testou", "objetivo": "formal"}
    )
    assert r.status_code == 200 and r.json()["texto"] == "Realizou-se o teste."
    assert (
        api.post(
            "/api/arquivos/reescrever", json={"trecho": "x", "objetivo": "feedback"}
        ).status_code
        == 422
    )
    assert (
        api.post("/api/arquivos/reescrever", json={"trecho": "x", "arquivo_id": "nao"}).status_code
        == 404
    )
    assert len(api.app.state.requests) == 1  # type: ignore[attr-defined]


def test_page_translation_aligns_sentences_and_uses_cache(tmp_path: Path) -> None:
    s = Settings(
        client_api_keys=CLIENT_API_KEY, arquivos_dir=str(tmp_path), notas_dir=str(tmp_path)
    )
    app = create_app(settings=s)
    requests: list[dict] = []

    async def executar_json(pedido: dict) -> dict:
        requests.append(pedido)
        # out of order and without the 2nd: alignment is by number, the missing one comes back empty
        return {"traducoes": [{"n": 3, "pt": "Fim."}, {"n": 1, "pt": "Olá, mundo."}]}

    async def executar(pedido: dict) -> dict:
        return {}

    app.state.reescrita = Rewrite(executar, lambda: None, executar_json)
    api = TestClient(app, headers=AUTH_HEADERS)
    meta = api.post("/api/arquivos", files={"arquivo": ("a.csv", b"a;b\n")}).json()
    body = {
        "paginas": [
            {"pagina": 0, "segmentos": ["Hello, world.", "Second one."]},
            {"pagina": 1, "segmentos": ["End."]},
        ]
    }
    r = api.post(f"/api/arquivos/{meta['id']}/traducao", json=body).json()
    assert r["0"]["traducoes"] == ["Olá, mundo.", ""]
    assert r["1"]["traducoes"] == ["Fim."]
    assert "[1] Hello, world." in requests[0]["prompt"]
    api.post(f"/api/arquivos/{meta['id']}/traducao", json=body)
    assert len(requests) == 1  # same sentences: it came from the cache
    assert api.get(f"/api/arquivos/{meta['id']}/traducao").json()["1"]["segmentos"] == ["End."]


def test_translate_excerpt_uses_local_llm_even_without_claude(api: TestClient) -> None:
    local_names: list[dict] = []

    async def local(pedido: dict) -> dict:
        local_names.append(pedido)
        return {"texto": "O método funciona.", "mudancas": [], "observacoes": ""}

    api.app.state.reescrita = Rewrite(  # type: ignore[attr-defined]
        api.app.state.reescrita.executar,  # type: ignore[attr-defined]
        lambda: "sem worker",
        traducao_json=local,
    )
    body = {"trecho": "The method works.", "objetivo": "traduzir"}
    r = api.post("/api/arquivos/reescrever", json=body)
    assert r.status_code == 200 and r.json()["texto"] == "O método funciona."
    first = local_names[0]
    assert "<trecho>" in first["prompt"] and first["esquema"]["required"][0] == "texto"
    assert not api.app.state.requests  # type: ignore[attr-defined]
    body["objetivo"] = "formal"
    assert api.post("/api/arquivos/reescrever", json=body).status_code == 503
