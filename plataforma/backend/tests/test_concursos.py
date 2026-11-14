from datetime import date, timedelta
from pathlib import Path
from typing import Any

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from concursos import schedule
from concursos.api import IA
from concursos.exams import Exams

HOJE = date(2026, 11, 2)  # segunda-feira
PROVA = date(2027, 1, 24)

ESTRUTURA: dict[str, Any] = {
    "resumo": "TJPB 2026",
    "data_prova": "2027-01-24",
    "horario_prova": "13h às 18h",
    "formato_prova": "60 objetivas + 1 discursiva",
    "prazos": [
        {
            "titulo": "Fim das inscrições",
            "data": "2026-11-18",
            "hora": "16:00",
            "tipo": "inscricao",
            "detalhe": "",
        },
        {
            "titulo": "Pagamento da GRJ",
            "data": "2026-11-19",
            "hora": "",
            "tipo": "pagamento",
            "detalhe": "",
        },
        {"titulo": "Data sem dia", "data": "a definir", "hora": "", "tipo": "outro", "detalhe": ""},
    ],
    "disciplinas": [
        {
            "nome": "Língua Portuguesa",
            "modulo": "gerais",
            "questoes": 10,
            "prioridade": 5,
            "topicos": [
                {
                    "titulo": "Interpretação",
                    "conteudo": "1. Compreensão",
                    "horas": 6,
                    "prioridade": "alta",
                },
                {"titulo": "Sintaxe", "conteudo": "5. Sintaxe", "horas": 8, "prioridade": "alta"},
            ],
        },
        {
            "nome": "Raciocínio Lógico",
            "modulo": "gerais",
            "questoes": 10,
            "prioridade": 4,
            "topicos": [
                {
                    "titulo": "Lógica proposicional",
                    "conteudo": "1. Estruturas",
                    "horas": 6,
                    "prioridade": "alta",
                },
            ],
        },
        {
            "nome": "Engenharia de Software",
            "modulo": "especificos",
            "questoes": 40,
            "prioridade": 5,
            "topicos": [
                {
                    "titulo": "Processos ágeis",
                    "conteudo": "Scrum",
                    "horas": 5,
                    "prioridade": "media",
                },
                {"titulo": "Testes", "conteudo": "TDD", "horas": 4, "prioridade": "media"},
            ],
        },
    ],
    "discursiva": {"descricao": "1 questão de 30 linhas", "temas_provaveis": ["LGPD"]},
    "estrategia": ["Questões da FGV"],
}


def _pdf() -> bytes:
    return b"%PDF-1.4 falso"


def test_cronograma_distribui_ate_uma_semana_antes() -> None:
    tasks, summary = schedule.generate(ESTRUTURA, HOJE, PROVA, 120, 240)
    datas = {t["data"] for t in tasks}
    content = [t for t in tasks if t["tipo"] == "conteudo"]
    assert summary["fator"] == 1.0 and summary["conteudo_pendente"] == 0
    assert max(t["data"] for t in content) <= (PROVA - timedelta(7)).isoformat()
    assert PROVA.isoformat() not in datas
    # ordem do fluxo: Interpretação antes de Sintaxe
    titulos = [t["titulo"] for t in content if t["disciplina"] == "Língua Portuguesa"]
    assert titulos[0].endswith("Interpretação (1/4)")
    # nenhum dia passa da capacidade
    for d in datas:
        day = date.fromisoformat(d)
        cap = 240 if day.weekday() >= 5 else 120
        assert sum(t["minutos"] for t in tasks if t["data"] == d) <= cap
    kinds = {t["tipo"] for t in tasks}
    assert {"conteudo", "revisao", "simulado", "discursiva", "final"} <= kinds
    assert any(t["titulo"].startswith("Véspera") and t["data"] == "2027-01-23" for t in tasks)


def test_cronograma_comprime_quando_falta_tempo() -> None:
    _, summary = schedule.generate(ESTRUTURA, PROVA - timedelta(21), PROVA, 60, 60)
    assert summary["fator"] < 1 and summary["conteudo_pendente"] == 0


@pytest.fixture
def app_concursos(tmp_path: Path) -> tuple[TestClient, list[dict[str, Any]]]:
    s = Settings(client_api_keys=CLIENT_API_KEY, concursos_dir=str(tmp_path))
    app = create_app(settings=s)
    requests: list[dict[str, Any]] = []

    async def executar(pedido: dict[str, Any]) -> dict[str, Any]:
        requests.append(pedido)
        return ESTRUTURA

    app.state.concursos = Exams(tmp_path, hoje=lambda: HOJE)
    app.state.concursos_ia = IA(executar, lambda: None)
    return TestClient(app, headers=AUTH_HEADERS), requests


def test_exige_chave(tmp_path: Path) -> None:
    s = Settings(client_api_keys=CLIENT_API_KEY, concursos_dir=str(tmp_path))
    assert TestClient(create_app(settings=s)).get("/api/concursos").status_code == 401


def test_fluxo_completo(
    app_concursos: tuple[TestClient, list[dict[str, Any]]], monkeypatch: pytest.MonkeyPatch
) -> None:
    api, requests = app_concursos
    monkeypatch.setattr("concursos.exams.text_pdf", lambda _: "EDITAL TJPB " * 100)
    c = api.post(
        "/api/concursos",
        json={"nome": "TJPB 2026", "cargo": "TI – Desenvolvimento", "banca": "FGV"},
    ).json()
    cid = c["id"]
    assert c["geracao"]["estado"] == "sem_plano"
    assert api.post(f"/api/concursos/{cid}/plano").status_code == 422  # sem edital
    assert (
        api.post(f"/api/concursos/{cid}/edital", files={"arquivo": ("e.txt", b"oi")}).status_code
        == 422
    )
    r = api.post(f"/api/concursos/{cid}/edital", files={"arquivo": ("edital.pdf", _pdf())})
    assert r.status_code == 200 and r.json()["edital"]["nome"] == "edital.pdf"

    r = api.post(f"/api/concursos/{cid}/plano")
    assert r.status_code == 202
    assert "TI – Desenvolvimento" in requests[0]["prompt"] and "EDITAL TJPB" in requests[0]["prompt"]
    c = api.get(f"/api/concursos/{cid}").json()
    assert c["geracao"]["estado"] == "pronto" and c["data_prova"] == "2027-01-24"
    assert [p["titulo"] for p in c["prazos"]] == ["Fim das inscrições", "Pagamento da GRJ"]
    assert c["tarefas"] and c["situacao"]["dias_para_prova"] == 83

    items = api.get("/api/concursos").json()
    assert items[0]["proximo_prazo"]["titulo"] == "Fim das inscrições"

    # marcar feita, adiantar o relógio e replanejar: a feita fica, o resto vai de hoje em diante
    primeira = c["tarefas"][0]
    assert api.patch(f"/api/concursos/{cid}/tarefas/{primeira['id']}", json={"feito": True}).json()[
        "feito"
    ]
    api.app.state.concursos.hoje = lambda: HOJE + timedelta(5)  # type: ignore[attr-defined]
    alerts = api.get("/api/concursos/alertas").json()
    assert any("atrasada" in a["texto"] for a in alerts)
    assert any("Fim das inscrições em 11 dias" in a["texto"] for a in alerts)
    c = api.post(f"/api/concursos/{cid}/replanejar").json()
    pending = [t for t in c["tarefas"] if not t["feito"]]
    assert min(t["data"] for t in pending) == (HOJE + timedelta(5)).isoformat()
    assert sum(1 for t in c["tarefas"] if t.get("chave") == primeira["chave"]) == 1

    p = api.post(
        f"/api/concursos/{cid}/prazos", json={"titulo": "Local de prova", "data": "2027-01-15"}
    ).json()
    assert api.delete(f"/api/concursos/{cid}/prazos/{p['id']}").status_code == 204
    assert api.delete(f"/api/concursos/{cid}").status_code == 204
    assert api.get(f"/api/concursos/{cid}").status_code == 404


def test_erro_do_claude_fica_no_concurso(
    app_concursos: tuple[TestClient, list[dict[str, Any]]], monkeypatch: pytest.MonkeyPatch
) -> None:
    api, _ = app_concursos
    monkeypatch.setattr("concursos.exams.text_pdf", lambda _: "EDITAL " * 200)

    async def falha(_: dict[str, Any]) -> dict[str, Any]:
        raise RuntimeError("Claude Code falhou: limite da assinatura")

    api.app.state.concursos_ia = IA(falha, lambda: None)  # type: ignore[attr-defined]
    cid = api.post("/api/concursos", json={"nome": "X", "cargo": "Y"}).json()["id"]
    api.post(f"/api/concursos/{cid}/edital", files={"arquivo": ("e.pdf", _pdf())})
    api.post(f"/api/concursos/{cid}/plano")
    g = api.get(f"/api/concursos/{cid}").json()["geracao"]
    assert g["estado"] == "erro" and "limite" in g["erro"]
