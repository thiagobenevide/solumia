import io
import zipfile
from datetime import date, timedelta
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, saude_dir=str(tmp_path))
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def _csv(tipo: str, cabecalho: str, *linhas: str) -> tuple[str, str]:
    return f"samsunghealth/{tipo}.20261101120000.csv", "\n".join(
        [f"{tipo},1,1", cabecalho, *linhas]
    )


def _zip(*arquivos: tuple[str, str]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name, text in arquivos:
            z.writestr(name, text)
    return buf.getvalue()


def test_health_connect_and_summary(api: TestClient) -> None:
    days = [
        {"data": "2026-11-01", "passos": 9000, "sono_min": 450, "fc_repouso": 58, "x": 1},
        {
            "data": "2026-11-02",
            "passos": 4000,
            "sono_min": 330,
            "exercicios": [{"tipo": "WALKING", "minutos": 40, "lixo": 1}],
        },
    ]
    assert api.put("/api/saude/relogio/dias", json={"dias": days}).json() == {"dias": 2}
    items = api.get("/api/saude/relogio/dias?de=2026-11-01&ate=2026-11-30").json()
    # without the export score: estimated by duration only (7h30 → 88; 5h30 → 38)
    assert items[0]["sono_pontuacao"] == 88 and items[0]["sono_pontuacao_estimada"] is True
    assert items[1]["sono_pontuacao"] == 38
    assert "x" not in items[0] and items[1]["exercicios"] == [{"tipo": "WALKING", "minutos": 40}]
    r = api.get("/api/saude/relogio/resumo?de=2026-11-01&ate=2026-11-30").json()
    assert r["medias"]["passos"] == 6500
    assert r["metas"]["passos"] == {"meta": 8000, "batidos": 1, "dias": 2}
    assert "health_connect" in api.get("/api/saude/relogio/estado").json()
    bad = api.put("/api/saude/relogio/dias", json={"dias": [{"data": "ontem", "passos": 1}]})
    assert bad.status_code == 422


def test_sleep_score_from_stages() -> None:
    from health.watch import score_sleep

    otima = {"sono_min": 480, "sono_acordado_min": 20, "sono_profundo_min": 96, "sono_rem_min": 106}
    assert score_sleep(otima) == 100
    bad = {"sono_min": 300, "sono_acordado_min": 100, "sono_profundo_min": 15, "sono_rem_min": 24}
    assert score_sleep(bad) == 10
    assert score_sleep({"sono_min": 30}) is None and score_sleep({}) is None


def test_imports_samsung_export(api: TestClient) -> None:
    api.put("/api/saude/relogio/dias", json={"dias": [{"data": "2026-11-02", "passos": 7777}]})
    content = _zip(
        _csv(
            "com.samsung.shealth.tracker.pedometer_day_summary",
            "day_time,step_count,distance,calorie,active_time,",
            "1762041600000,5000,3800,210,3600000,",  # 2025-11-02 00:00 UTC
            "1762041600000,4200,3000,180,3000000,",
            "1793577600000,1234,900,50,600000,",
        ),  # 2026-11-02: Health Connect already brought it
        _csv(
            "com.samsung.shealth.sleep",
            "com.samsung.health.sleep.start_time,com.samsung.health.sleep.end_time,time_offset,sleep_score",
            "2025-11-02 02:00:00.000,2025-11-02 09:30:00.000,UTC-0300,82",
            "2025-11-02 17:00:00.000,2025-11-02 17:30:00.000,UTC-0300,",
        ),
        _csv(
            "com.samsung.health.sleep_stage",
            "start_time,end_time,stage,time_offset",
            "2025-11-02 03:00:00.000,2025-11-02 04:00:00.000,40003,UTC-0300",
        ),
        _csv(
            "com.samsung.shealth.tracker.heart_rate",
            "com.samsung.health.heart_rate.start_time,com.samsung.health.heart_rate.heart_rate,"
            "com.samsung.health.heart_rate.min,com.samsung.health.heart_rate.max,time_offset",
            "2025-11-02 12:00:00.000,70,60,80,UTC-0300",
            "2025-11-02 13:00:00.000,90,85,120,UTC-0300",
        ),
        _csv(
            "com.samsung.shealth.stress",
            "start_time,score,time_offset",
            "2025-11-02 12:00:00.000,40,UTC-0300",
            "2025-11-02 15:00:00.000,60,UTC-0300",
        ),
        _csv(
            "com.samsung.health.weight",
            "start_time,weight,body_fat,time_offset",
            "2025-11-02 10:00:00.000,80.4,22.1,UTC-0300",
        ),
        _csv(
            "com.samsung.shealth.exercise",
            "start_time,duration,exercise_type,calorie,distance,time_offset",
            "2025-11-02 21:00:00.000,1800000,1001,150,2500,UTC-0300",
        ),
        ("leiame.txt", "nada"),
    )
    r = api.post("/api/saude/relogio/importar", files={"arquivo": ("export.zip", content)})
    assert r.status_code == 200, r.text
    assert r.json()["dias"] == 2
    d, new = api.get("/api/saude/relogio/dias?de=2025-11-01&ate=2026-11-30").json()
    assert d["data"] == "2025-11-02" and d["passos"] == 5000 and d["distancia_km"] == 3.8
    assert d["minutos_ativos"] == 60
    assert d["sono_min"] == 480 and d["sono_inicio"] == "23:00" and d["sono_fim"] == "06:30"
    assert d["sono_pontuacao"] == 82 and d["sono_profundo_min"] == 60
    assert (d["fc_media"], d["fc_min"], d["fc_max"]) == (80, 60, 120)
    assert d["estresse"] == 50 and d["peso_kg"] == 80.4 and d["gordura_pct"] == 22.1
    assert d["exercicios"] == [
        {
            "tipo": "caminhada",
            "inicio": "18:00",
            "minutos": 30,
            "calorias": 150,
            "distancia_km": 2.5,
        }
    ]
    assert new["passos"] == 7777  # the export does not overwrite what the phone sent
    bad = api.post("/api/saude/relogio/importar", files={"arquivo": ("a.zip", b"nao e zip")})
    assert bad.status_code == 422


def test_analysis_by_local_llm(api: TestClient) -> None:
    today = date.today()
    ontem = (today - timedelta(days=1)).isoformat()
    api.put(
        "/api/saude/relogio/dias", json={"dias": [{"data": ontem, "sono_min": 300, "passos": 2000}]}
    )
    api.put(f"/api/saude/mental/diario/{ontem}", json={"humor": 2, "ansiedade": 8})
    recebido: list[list[dict[str, str]]] = []

    async def llm(mensagens: list[dict[str, str]]) -> str:
        recebido.append(mensagens)
        return "## Resumo do período\nDormiu pouco."

    app = api.app
    app.state.saude_llm = llm  # type: ignore[attr-defined]
    app.state.saude_contexto = lambda de, ate: "## Gastos por dia (R$)\n- x: 10.00"  # type: ignore[attr-defined]
    r = api.post("/api/saude/relogio/analises", json={"dias": 7, "pergunta": "Durmo bem?"})
    assert r.status_code == 200, r.text
    assert r.json()["texto"].startswith("## Resumo")
    user = recebido[0][1]["content"]
    assert f"{ontem}: watch: sono 5h00, nota sono 25, passos 2000" in user
    assert "humor 2, ansiedade 8" in user and "Gastos por dia" in user
    assert user.endswith("The user's question: Durmo bem?")
    assert len(api.get("/api/saude/relogio/analises").json()) == 1
