import asyncio
import json
from datetime import date
from pathlib import Path
from typing import Any

import httpx
import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient
from test_concursos import ESTRUTURA, HOJE

from backend.core.config import Settings
from backend.main import create_app
from concursos.api import IA
from concursos.exams import Exams
from concursos.radar import Radar, sphere_of_agency, read_listing

LISTA = """<div id="PB" class="ua"><div class="uf">PARAÍBA</div></div>
<div class="ea" data-url="https://www.pciconcursos.com.br/noticias/tre-pb-abre-concurso" style="x">
<div class="ca"><a href="https://www.pciconcursos.com.br/noticias/tre-pb-abre-concurso"
 title="TRE PB abre concurso" rel="bookmark">TRE - Tribunal Regional Eleitoral da Paraíba</a>
<div class="cc">PB</div>
<div class="cd">12 vagas até R$ 13.994,78<br>
<span>Analista Judiciário - Tecnologia da Informação<br>
<span>Superior</span></span></div><div class="ce"><span>30/11/2026</span></div>
<div class="clear"></div></div>
<div class="ea" data-url="https://www.pciconcursos.com.br/noticias/prefeitura-x" style="x">
<div class="ca"><a href="https://www.pciconcursos.com.br/noticias/prefeitura-x"
 title="Pref X">Prefeitura X</a>
<div class="cc">BA</div>
<div class="cd">3 vagas<br><span>Gari<br><span>Fundamental</span></span></div>
<div class="ce"><span>30/11/2026</span></div><div class="clear"></div></div>"""

NOTICIA = """<nav>Apostilas de Informática</nav><div itemprop="articleBody"><p>O TRE-PB abre
vagas de
Analista Judiciário - Tecnologia da Informação. Inscrições em www.tre-pb.jus.br/concurso2026.</p>
</div><div id="preparacao">x</div><ul><li class="li_provas"><a href="https://www.pciconcursos.com.br/provas/cebraspe">P</a>
</li></ul>"""

MUNICIPIOS = """codigo_ibge,nome,latitude,longitude,capital,codigo_uf,siafi_id,ddd,fuso_horario
2605103,Custódia,-8.08546,-37.6443,0,26,2401,87,America/Sao_Paulo
2507507,João Pessoa,-7.11509,-34.8641,1,25,2051,83,America/Sao_Paulo
2504009,Campina Grande,-7.23072,-35.8817,0,25,1981,83,America/Sao_Paulo
"""

DETALHE = {
    "ti": True,
    "banca": "Cebraspe",
    "edital_url": "https://x/edital.pdf",
    "link_inscricao": "",
    "inscricoes_inicio": "2026-11-01",
    "inscricoes_fim": "2026-11-30",
    "data_prova": "2027-02-14",
    "horario_prova": "8h às 12h",
    "taxa": "R$ 85",
    "sede": {"cidade": "João Pessoa", "uf": "PB"},
    "cidades_prova": [
        {"cidade": "João Pessoa", "uf": "PB"},
        {"cidade": "Campina Grande", "uf": "PB"},
    ],
    "vagas_ti": [
        {
            "cargo": "Analista Judiciário – TI",
            "vagas": 12,
            "cadastro_reserva": True,
            "salario": 13994.78,
            "requisitos": "Superior em TI",
        }
    ],
    "resumo": "Concurso do TRE-PB.",
}


def _transporte() -> httpx.MockTransport:
    def responder(r: httpx.Request) -> httpx.Response:
        u = str(r.url)
        if "/concursos/" in u:
            return httpx.Response(200, text=LISTA if "nordeste" in u else "")
        if "municipios.csv" in u:
            return httpx.Response(200, text=MUNICIPIOS)
        if "tre-pb-abre" in u:
            return httpx.Response(200, text=NOTICIA)
        if "tre-pb.jus.br" in u:
            return httpx.Response(
                200,
                text='<a href="/arquivos/edital-tre.pdf">Edital de abertura</a>',
                headers={"content-type": "text/html"},
            )
        if "router.project-osrm.org" in u:
            km = 180_000 if "-35.88" in u else 390_000
            return httpx.Response(
                200,
                json={
                    "routes": [
                        {
                            "distance": km,
                            "duration": 9000,
                            "geometry": {
                                "coordinates": [[-37.64, -8.08], [-36.5, -7.6], [-35.88, -7.23]]
                            },
                        }
                    ]
                },
            )
        return httpx.Response(404)

    return httpx.MockTransport(responder)


def test_ler_listagem() -> None:
    items = read_listing(LISTA, "nordeste")
    assert [i["uf"] for i in items] == ["PB", "BA"]
    assert items[0]["inscricao_ate"] == "2026-11-30"
    assert items[0]["cargos_txt"].startswith("Analista Judiciário - Tecnologia")


def test_radar_detalha_e_acha_o_local_mais_proximo(tmp_path: Path) -> None:
    requests: list[str] = []

    async def llm(m: list[dict[str, str]]) -> str:
        requests.append(m[1]["content"])
        return "Aqui está: " + json.dumps(DETALHE)

    radar = Radar(tmp_path, llm, transporte=_transporte(), hoje=lambda: HOJE)
    r = asyncio.run(radar.atualizar())
    assert r == {"novos": 1, "detalhados": 1}  # a prefeitura (gari) nem entra
    items = radar.list_all()
    assert items["origem"]["cidade"] == "Custódia"
    item = items["itens"][0]
    assert item["total_vagas_ti"] == 12 and item["salario_max"] == 13994.78
    assert item["mais_proximo"]["cidade"] == "Campina Grande" and item["mais_proximo"]["km"] == 180
    # a LLM citou um PDF que não estava na página oficial: fica o 1º PDF de edital do site
    assert item["edital_url"] == "https://www.tre-pb.jus.br/arquivos/edital-tre.pdf"
    assert item["provas_url"] == "https://www.pciconcursos.com.br/provas/cebraspe"
    assert "edital-tre.pdf" in requests[0]
    route = asyncio.run(radar.route(item["id"]))
    assert route is not None and len(route["linha"]) >= 2
    # segunda coleta não chama a LLM de novo
    asyncio.run(radar.atualizar())
    assert len(requests) == 1


def test_radar_tenta_de_novo_quando_a_llm_falha(tmp_path: Path) -> None:
    falhar = [True]

    async def llm(m: list[dict[str, str]]) -> str:
        if falhar[0]:
            raise RuntimeError("worker desligado")
        return json.dumps(DETALHE)

    radar = Radar(tmp_path, llm, transporte=_transporte(), hoje=lambda: HOJE)
    asyncio.run(radar.atualizar())
    items = radar.list_all()
    assert items["itens"] == [] and items["falhas"] == 1
    assert "worker desligado" in items["erro"]
    falhar[0] = False
    asyncio.run(radar.atualizar())
    items = radar.list_all()
    assert len(items["itens"]) == 1 and items["falhas"] == 0 and items["erro"] == ""


def test_radar_pesquisa_com_o_claude(tmp_path: Path) -> None:
    requests: list[dict] = []

    async def executar(p: dict) -> dict:
        requests.append(p)
        return {
            "concursos": [
                {**DETALHE, "orgao": "TRE-PB", "uf": "pb", "situacao": "previsto",
                 "fonte_url": "https://exemplo.com.br/tre", "inscricoes_fim": ""},
                {**DETALHE, "orgao": "Velho", "uf": "PE", "situacao": "aberto",
                 "fonte_url": "", "inscricoes_fim": "2020-01-01"},
            ]
        }

    radar = Radar(tmp_path, None, transporte=_transporte(), hoje=lambda: HOJE)
    assert asyncio.run(radar.search_claude(executar)) == {"achados": 1}
    # uma rodada por esfera
    assert [p["prompt"].count("FEDERAIS") for p in requests] == [1, 0, 0]
    assert "WebSearch" in requests[0]["ferramentas"]
    items = radar.list_all()
    item = items["itens"][0]
    assert item["id"] == "claude-tre-pb-pb" and item["fonte"] == "claude"
    assert item["situacao"] == "previsto" and item["mais_proximo"]["cidade"] == "Campina Grande"
    assert items["claude"]["achados"] == 1 and not items["pesquisando_claude"]


def test_radar_federal_sem_cidades_vai_para_as_capitais(tmp_path: Path) -> None:
    async def executar(p: dict) -> dict:
        if "FEDERAIS" not in p["prompt"]:
            raise RuntimeError("limite da assinatura")
        return {
            "concursos": [
                {**DETALHE, "orgao": "Dataprev", "uf": "BR", "situacao": "aberto",
                 "fonte_url": "https://x", "sede": {"cidade": "", "uf": ""},
                 "cidades_prova": []},
            ]
        }

    radar = Radar(tmp_path, None, transporte=_transporte(), hoje=lambda: HOJE)
    assert asyncio.run(radar.search_claude(executar)) == {"achados": 1}
    items = radar.list_all()
    item = items["itens"][0]
    assert item["esfera"] == "federal" and item["mais_proximo"]["cidade"] == "João Pessoa"
    assert "estadual: limite" in items["claude"]["erro"]
    assert sphere_of_agency("Prefeitura de Custódia") == "municipal"
    assert sphere_of_agency("Ministério Público do Estado de PE") == "estadual"
    assert sphere_of_agency("TRT 6ª Região") == "federal"


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, concursos_dir=str(tmp_path))
    app = create_app(settings=s)
    app.state.concursos = Exams(tmp_path, hoje=lambda: HOJE)

    async def executar(p: dict[str, Any]) -> dict[str, Any]:
        if p["esquema"] is not ESTRUTURA and "questoes" in p["esquema"]["properties"]:
            return {
                "questoes": [
                    {
                        "disciplina": "Língua Portuguesa",
                        "topico": "Sintaxe",
                        "enunciado": f"Q{i}",
                        "alternativas": list("ABCDE"),
                        "correta": i % 5,
                        "comentario": "porque",
                    }
                    for i in range(5)
                ]
            }
        return ESTRUTURA

    async def busca(q: str) -> dict[str, Any]:
        return {
            "resultados": [
                {"titulo": "Prova FGV 2024", "url": "https://p/fgv.pdf", "trecho": "prova"},
                {"titulo": "Loja", "url": "https://loja", "trecho": "compre"},
            ]
        }

    async def llm(_: list[dict[str, str]]) -> str:
        return (
            '{"itens": [{"n": 0, "util": true, "tipo": "prova", "disciplina": "", '
            '"descricao": "Prova"},'
            ' {"n": 1, "util": false}]}'
        )

    app.state.concursos_ia = IA(executar, lambda: None)
    app.state.concursos_busca = busca
    app.state.concursos_llm = llm
    return TestClient(app, headers=AUTH_HEADERS)


def _concurso_com_plano(api: TestClient) -> str:
    c = api.app.state.concursos  # type: ignore[attr-defined]
    cid = c.criar({"nome": "TJPB", "cargo": "TI", "banca": "FGV"})["id"]
    c.apply_structure(cid, ESTRUTURA)
    return str(cid)


def test_simulado_gera_esconde_gabarito_e_corrige(api: TestClient) -> None:
    cid = _concurso_com_plano(api)
    r = api.post(f"/api/concursos/{cid}/simulados", json={"questoes": 5})
    assert r.status_code == 202
    s = api.get(f"/api/concursos/{cid}/simulados").json()["simulados"][0]
    assert s["estado"] == "pronto" and "correta" not in s["questoes"][0]
    res = api.post(
        f"/api/concursos/{cid}/simulados/{s['id']}/respostas",
        json={"respostas": [0, 1, 2, 0, None], "segundos": 600},
    ).json()
    assert res["resultado"]["acertos"] == 3 and res["resultado"]["em_branco"] == 1
    assert res["questoes"][0]["comentario"] == "porque"
    d = api.get(f"/api/concursos/{cid}/simulados").json()["desempenho"]
    assert d["disciplinas"][0] == {
        "disciplina": "Língua Portuguesa",
        "acertos": 3,
        "total": 5,
        "pct": 60,
    }
    assert (
        api.post(
            f"/api/concursos/{cid}/simulados", json={"questoes": 5, "disciplina": "X"}
        ).status_code
        == 422
    )


def test_materiais_filtra_pela_llm(api: TestClient) -> None:
    cid = _concurso_com_plano(api)
    assert api.post(f"/api/concursos/{cid}/materiais/buscar").status_code == 202
    m = api.get(f"/api/concursos/{cid}/materiais").json()
    assert m["estado"] == "pronto"
    urls = [i["url"] for i in m["itens"]]
    assert urls == ["https://www.pciconcursos.com.br/provas/fgv", "https://p/fgv.pdf"]


def test_acompanhar_do_radar(
    api: TestClient, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def llm(_: list[dict[str, str]]) -> str:
        return json.dumps(DETALHE)

    radar = Radar(tmp_path, llm, transporte=_transporte(), hoje=lambda: HOJE)
    asyncio.run(radar.atualizar())
    api.app.state.concursos_radar = radar  # type: ignore[attr-defined]
    monkeypatch.setattr("concursos.api._download", lambda _: b"%PDF-1.4")
    monkeypatch.setattr("concursos.exams.text_pdf", lambda _: "EDITAL TRE " * 100)
    assert api.get("/api/concursos/radar").json()["itens"][0]["orgao"].startswith("TRE")
    iid = radar.list_all()["itens"][0]["id"]
    c = api.post(
        f"/api/concursos/radar/{iid}/acompanhar", json={"cargo": "Analista Judiciário – TI"}
    ).json()
    c = api.get(f"/api/concursos/{c['id']}").json()
    assert c["radar"]["mais_proximo"]["cidade"] == "Campina Grande"
    assert c["geracao"]["estado"] == "pronto" and c["banca"] == "Cebraspe"
    assert any(p["titulo"].startswith("Fim das inscrições") for p in c["prazos"])
    assert date.fromisoformat(c["data_prova"]) == date(2027, 2, 14)  # a do radar fica


def test_baixar_recusa_rede_interna_e_outros_esquemas():
    import urllib.error

    from concursos.api import _download

    for url in ("http://127.0.0.1:48080/health", "http://169.254.169.254/", "file:///etc/passwd",
                "http://collabora:9980/", "http://[::1]/"):
        with pytest.raises(OSError):
            _download(url)
    with pytest.raises(urllib.error.URLError, match="interno"):
        _download("http://localhost/edital.pdf")
