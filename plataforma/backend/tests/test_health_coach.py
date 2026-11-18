from datetime import date
from pathlib import Path
from typing import Any

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from health.coach import Ai, image_ref_lines, index_refs, targets, week_end
from shared.claude_code import _save_images

CALLS: list[tuple[dict[str, Any], str]] = []


async def _fake(request: dict[str, Any], provider: str) -> dict[str, Any]:
    CALLS.append((request, provider))
    if "itens" in request["esquema"]["properties"]:
        return {"itens": [{"nome": "Arroz", "quantidade": "150 g", "kcal": 190, "proteina_g": 4,
                           "carboidrato_g": 42, "gordura_g": 0.4}],
                "kcal": 600, "proteina_g": 45, "carboidrato_g": 60, "gordura_g": 18,
                "confianca": "media", "comentario": "ok"}
    return {
        "resumo": "semana", "nutricao": "2400 kcal",
        "novos_exercicios": [{"id": "bulgaro-cadeira", "nome": "Búlgaro na cadeira",
                              "area": "Pernas", "grupo": "Quadríceps", "equipamento": "Cadeira",
                              "instrucoes": "pé de trás na cadeira",
                              "ref": "Split_Squat_with_Dumbbells"},
                             {"id": "inventado", "nome": "Inventado", "area": "Pernas",
                              "grupo": "", "equipamento": "", "instrucoes": "",
                              "ref": "Nao_Existe"}],
        "dias": [
            {"data": "2026-11-17", "foco": "Empurrar", "itens": [
                {"exercicio_id": "flexao", "series": 4, "repeticoes": "10-12", "carga_kg": None,
                 "observacao": "2 s na descida"},
                {"exercicio_id": "inexistente", "series": 3, "repeticoes": "10", "carga_kg": None,
                 "observacao": ""},
            ]},
            {"data": "2026-11-18", "foco": "Pernas", "itens": [
                {"exercicio_id": "bulgaro-cadeira", "series": 3, "repeticoes": "10",
                 "carga_kg": 10, "observacao": ""},
            ]},
            {"data": "2026-12-30", "foco": "fora", "itens": []},
        ],
    }


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    CALLS.clear()
    s = Settings(client_api_keys=CLIENT_API_KEY, saude_dir=str(tmp_path),
                 saude_baixar_imagens=False)
    app = create_app(settings=s)
    client = TestClient(app, headers=AUTH_HEADERS)
    client.__enter__()
    app.state.saude_coach_ia = Ai(_fake, lambda provider: None)
    return client


def test_profile_and_weight(api: TestClient) -> None:
    perfil = api.get("/api/saude/coach/perfil").json()
    assert perfil["ia"] == "claude" and "Barra W" in perfil["materiais"]
    perfil = api.patch("/api/saude/coach/perfil", json={"altura_cm": 180, "idade": 30}).json()
    assert perfil["altura_cm"] == 180
    assert api.patch("/api/saude/coach/perfil", json={"ia": "gpt"}).status_code == 400
    api.put("/api/saude/coach/peso/2026-11-17", json={"peso_kg": 92})
    api.put("/api/saude/coach/peso/2026-11-17", json={"peso_kg": 91.8})
    pesos = api.get("/api/saude/coach/peso?de=2026-11-01&ate=2026-11-30").json()
    assert pesos == [{"data": "2026-11-17", "peso_kg": 91.8}]
    dia = api.get("/api/saude/coach/dia/2026-11-17").json()
    assert dia["metas"]["proteina_g"] == 184 and dia["metas"]["imc"] == 28.3


def test_plan_goes_to_agenda(api: TestClient, tmp_path: Path) -> None:
    (tmp_path / "imagens" / "ref").mkdir(parents=True, exist_ok=True)
    (tmp_path / "imagens" / "ref" / "indice.json").write_text(
        '{"Split_Squat_with_Dumbbells": "dumbbell / quadriceps"}'
    )
    api.post("/api/saude/agenda", json={"data": "2026-11-18", "exercicio_id": "prancha"})
    plano = api.post("/api/saude/coach/planos", json={"inicio": "2026-11-17"}).json()
    assert plano["agendados"] == 2 and plano["ia"] == "claude"
    assert set(plano["ignorados"]) == {"inexistente", "2026-12-30"}
    request = CALLS[0][0]
    assert "Barra W" in request["prompt"] and "2026-11-22" in request["prompt"]
    agenda = api.get("/api/saude/agenda?de=2026-11-17&ate=2026-11-22").json()
    assert [i["exercicio_id"] for i in agenda] == ["flexao", "bulgaro-na-cadeira"]
    assert api.get("/api/saude/coach/planos").json()[0]["resumo"] == "semana"
    # only Tuesday: Wednesday keeps what was there, today comes from the app (not the UTC clock)
    api.post("/api/saude/agenda", json={"data": "2026-11-19", "exercicio_id": "prancha"})
    plano = api.post(
        "/api/saude/coach/planos", json={"datas": ["2026-11-17"], "hoje": "2026-11-17"}
    ).json()
    assert plano["datas"] == ["2026-11-17"] and plano["agendados"] == 1
    prompt = CALLS[-1][0]["prompt"]
    assert "today is 2026-11-17" in prompt and "Prancha (Abdômen)" in prompt
    assert "- 2026-11-18 (qua)" not in prompt.split("# Days to plan")[1]
    agenda = api.get("/api/saude/agenda?de=2026-11-17&ate=2026-11-22").json()
    assert [i["exercicio_id"] for i in agenda] == [
        "flexao", "bulgaro-na-cadeira", "prancha"]
    assert "dumbbell / quadriceps: Split_Squat_with_Dumbbells" in request["prompt"]
    exercicios = {e["id"]: e for e in api.get("/api/saude/exercicios").json()["exercicios"]}
    assert exercicios["bulgaro-na-cadeira"]["ref"] == "Split_Squat_with_Dumbbells"
    assert exercicios["inventado"]["ref"] is None


def test_meal_with_photo(api: TestClient) -> None:
    r = api.post(
        "/api/saude/coach/refeicoes",
        data={"data": "2026-11-17", "tipo": "almoço", "ia": "local"},
        files={"foto": ("prato.jpg", b"\xff\xd8jpeg", "image/jpeg")},
    )
    m = r.json()
    assert m["analise"]["kcal"] == 600 and m["analise"]["ia"] == "local"
    assert CALLS[0][0]["imagens"][0]["tipo"] == "image/jpeg"
    assert api.get(f"/api/saude/coach/refeicoes/{m['id']}/foto").content == b"\xff\xd8jpeg"
    assert api.get("/api/saude/coach/dia/2026-11-17").json()["total"]["kcal"] == 600
    r = api.post(f"/api/saude/coach/refeicoes/{m['id']}/analisar", json={"correcao": "2 conchas"})
    assert "2 conchas" in CALLS[1][0]["prompt"]
    assert api.post("/api/saude/coach/refeicoes", data={}).status_code == 400
    assert api.delete(f"/api/saude/coach/refeicoes/{m['id']}").status_code == 204


def test_index_refs() -> None:
    entries = [
        {"id": "A", "equipment": "barbell", "primaryMuscles": ["chest"], "images": ["A/0.jpg"]},
        {"id": "B", "equipment": "machine", "primaryMuscles": ["chest"], "images": ["B/0.jpg"]},
        {"id": "C", "equipment": "barbell", "primaryMuscles": ["chest"], "images": ["C/0.jpg"]},
    ]
    refs = index_refs(entries)
    assert refs == {"A": "barbell / chest", "C": "barbell / chest"}
    assert image_ref_lines(refs) == ["barbell / chest: A, C"]


def test_helpers(tmp_path: Path) -> None:
    assert week_end(date(2026, 11, 17)) == date(2026, 11, 22)
    assert targets({"altura_cm": 180, "idade": 30, "sexo": "M"}, 92)["kcal"] == 2500
    prompt = _save_images(tmp_path, [{"nome": "x.png", "base64": "aGk="}], "p")
    assert (tmp_path / "imagem-1.png").read_bytes() == b"hi" and prompt.endswith("p")
