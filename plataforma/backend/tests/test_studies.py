from datetime import date
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from studies.languages import level_of_hours, milestones, schedule


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, estudos_dir=str(tmp_path), notas_dir=str(tmp_path))
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def test_exige_chave(tmp_path: Path) -> None:
    s = Settings(client_api_keys=CLIENT_API_KEY, estudos_dir=str(tmp_path))
    assert TestClient(create_app(settings=s)).get("/api/estudos/leituras").status_code == 401


def test_readings(api: TestClient) -> None:
    r = api.post("/api/estudos/leituras", json={"titulo": "Clean Code", "area": "Tecnologia"})
    assert r.status_code == 201
    lid = r.json()["id"]
    api.post(
        "/api/estudos/leituras", json={"titulo": "Ações", "area": "Finanças", "status": "lendo"}
    )
    assert [x["titulo"] for x in api.get("/api/estudos/leituras").json()] == ["Ações", "Clean Code"]
    assert len(api.get("/api/estudos/leituras?area=Tecnologia").json()) == 1

    r = api.patch(f"/api/estudos/leituras/{lid}", json={"pagina_atual": 40, "status": "lido"})
    assert r.json()["pagina_atual"] == 40
    assert api.patch(f"/api/estudos/leituras/{lid}", json={"status": "x"}).status_code == 422
    assert api.delete(f"/api/estudos/leituras/{lid}").status_code == 204


def test_track_schedule_and_sessions(api: TestClient) -> None:
    r = api.post(
        "/api/estudos/idiomas",
        json={
            "idioma": "fr",
            "minutos_por_dia": 60,
            "dias_semana": [1, 3, 5],
            "inicio": "2026-11-02",
        },
    )
    assert r.status_code == 201
    t = r.json()
    assert (t["nome"], t["nivel_atual"], t["horas"]) == ("Francês", "A1", 0)
    assert [m["nivel"] for m in t["marcos"]] == ["A1", "A2", "B1", "B2", "C1", "C2"]

    days = api.get(f"/api/estudos/idiomas/{t['id']}/cronograma?de=2026-11-02&ate=2026-11-08").json()
    assert [d["data"] for d in days] == ["2026-11-02", "2026-11-04", "2026-11-06"]
    assert sum(b["minutos"] for b in days[0]["blocos"]) == 60
    assert days[0]["blocos"][1]["habilidade"] == "gramatica"

    t = api.post(
        f"/api/estudos/idiomas/{t['id']}/sessoes", json={"data": "2026-11-02", "minutos": 90}
    )
    assert t.json()["horas"] == 1.5
    assert api.post("/api/estudos/idiomas", json={"idioma": "de"}).status_code == 422


def test_levels_and_milestones() -> None:
    assert (
        level_of_hours(0) == "A1" and level_of_hours(250) == "B1" and level_of_hours(5000) == "C2"
    )
    track = {
        "idioma": "en",
        "nivel_inicial": "B1",
        "nivel_alvo": "B2",
        "minutos_por_dia": 60,
        "dias_semana": [1, 2, 3, 4, 5],
        "inicio": "2026-01-05",
        "sessoes": {},
    }
    m = milestones(track, date(2026, 1, 5))
    assert [x["concluido"] for x in m] == [True, True, False, False]
    assert m[-1]["horas_faltando"] == 400 and m[-1]["previsao"] == "2027-07-19"
    assert schedule(track, date(2026, 1, 3), date(2026, 1, 4)) == []


def test_reading_projects_matrix_and_export(tmp_path: Path) -> None:
    import io

    from openpyxl import load_workbook

    pdf = (
        b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
        b"2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
        b"3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\n"
        b"trailer<</Root 1 0 R>>\n%%EOF\n"
    )
    s = Settings(
        client_api_keys=CLIENT_API_KEY,
        estudos_dir=str(tmp_path / "e"),
        arquivos_dir=str(tmp_path / "a"),
        notas_dir=str(tmp_path / "n"),
    )
    api = TestClient(create_app(settings=s), headers=AUTH_HEADERS)
    pid = api.post("/api/estudos/projetos", json={"nome": "Pré-TCC", "secoes": ["1 Introdução"]})
    pid = pid.json()["id"]
    outro = api.post("/api/estudos/projetos", json={"nome": "Vídeo"}).json()["id"]
    file = api.post("/api/arquivos", files={"arquivo": ("Artigo.pdf", pdf)}).json()
    api.post(
        "/api/estudos/leituras",
        json={"titulo": "Recuperação", "area": "Tecnologia", "autor": "Araújo, W. C. O.",
              "ano": "2020", "arquivo_id": file["id"]},
    )
    r = api.put(
        f"/api/arquivos/{file['id']}/anotacoes",
        json={
            "versao_base": 0,
            "destaques": [
                {"id": "d1", "pagina": 10, "texto": "Search strategy", "cor": 1,
                 "retangulos": [], "comentario": "Base do método", "traducao": "Estratégia",
                 "criado": "2026-01-01T00:00:00Z", "projetos": [pid, outro]},
                {"id": "d2", "pagina": 1, "texto": "Fora", "cor": 1, "retangulos": []},
            ],
            "tracos": [
                {"id": "t1", "pagina": 2, "pincel": "caneta", "cor": 1, "espessura": 2,
                 "pontos": [0, 0, 1, 5, 5, 1], "projetos": [pid]},
            ],
            "textos": [{"id": "x1", "pagina": 2, "x": 1, "y": 1, "texto": "Ideia", "cor": 1,
                        "tamanho": 14, "projetos": [pid]}],
        },
    )
    assert r.status_code == 200, r.text

    m = api.get(f"/api/estudos/projetos/{pid}/matriz").json()
    assert [t["codigo"] for t in m["trabalhos"]] == ["T001"]
    assert {i["tipo"] for i in m["itens"]} == {"destaque", "texto", "manuscrito"}
    d = next(i for i in m["itens"] if i["id"] == "d1")
    assert d["citacao_parentetica"] == "[Araújo 2020]"
    assert d["citacao_narrativa"] == "Araújo (2020)"
    assert d["traducao"] == "Estratégia"
    assert d["classificacao"]["status_uso"] == "Não usado"
    assert len(api.get(f"/api/estudos/projetos/{outro}/matriz").json()["itens"]) == 1

    r = api.patch(f"/api/estudos/projetos/{pid}/itens/d1", json={"status_uso": "Usado",
                                                                "secao": "1 Introdução"})
    assert r.json()["status_uso"] == "Usado"
    items = {p["id"]: p for p in api.get("/api/estudos/projetos").json()}
    assert items[pid]["trechos"] == 1 and items[pid]["manuscritos"] == 1

    r = api.get(f"/api/estudos/projetos/{pid}/exportar")
    assert r.status_code == 200
    wb = load_workbook(io.BytesIO(r.content))
    assert wb.sheetnames == ["Trabalhos", "Trechos", "Painel", "Referências"]
    spans = [c.value for line in wb["Trechos"].iter_rows(min_row=5) for c in line]
    assert "Search strategy" in spans and "Estratégia" in spans and "Usado" in spans
    assert api.delete(f"/api/estudos/projetos/{pid}").status_code == 204


def test_knowledge_track(api: TestClient) -> None:
    [summary] = api.get("/api/estudos/conhecimento/trilhas").json()
    assert summary["id"] == "arquiteto-software" and summary["progresso"] == 0
    assert summary["proxima"]["etapa_id"] == "mentalidade"

    t = api.get("/api/estudos/conhecimento/trilhas/arquiteto-software?frente=Dados").json()
    assert t["etapas"] and all("Dados" in e["frentes"] for e in t["etapas"])
    assert "IA e LLMs" in t["frentes"]

    url = "/api/estudos/conhecimento/trilhas/arquiteto-software/etapas/mentalidade"
    for i in range(3):
        e = api.post(url, json={"leitura": i}).json()
    assert e["progresso"] < 1 and not e["concluida"]
    t = api.get("/api/estudos/conhecimento/trilhas/arquiteto-software").json()
    assert t["proxima"]["tipo"] == "pratica"
    e = api.post(url, json={"pratica": True, "nota_id": "n1"}).json()
    assert e["concluida"] and e["nota_id"] == "n1"
    assert api.post(url, json={"leitura": 99}).status_code == 404

    # without the book on the shelf, the next one asks to get it; linking creates the reading
    books = "/api/estudos/conhecimento/livros"
    assert api.patch(f"{books}/codigo-limpo", json={"tenho": False}).json()["tenho"] is False
    t = api.get("/api/estudos/conhecimento/trilhas/arquiteto-software").json()
    assert t["proxima"]["tipo"] == "leitura"  # chapter 7 of The Pragmatic Programmer
    book = api.post(f"{books}/codigo-limpo/leitura").json()
    assert book["tenho"] and book["leitura"]["status"] == "quero ler"
    assert api.get("/api/estudos/leituras?area=Tecnologia").json()[0]["titulo"] == "Código Limpo"
    of_new = api.post(f"{books}/codigo-limpo/leitura").json()
    assert of_new["leitura"]["id"] == book["leitura"]["id"]
    assert api.get(f"{books}").json()[0]["indicacoes"] > 0
