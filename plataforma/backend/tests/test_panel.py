import json
from datetime import datetime
from pathlib import Path
from typing import Any

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from panel.api import LLMUnavailable
from panel.nagger import Nagger

HOJE = "2026-10-28"


@pytest.fixture
def app(tmp_path: Path):  # type: ignore[no-untyped-def]
    s = Settings(
        client_api_keys=CLIENT_API_KEY,
        painel_dir=str(tmp_path / "painel"),
        rotinas_dir=str(tmp_path / "rotinas"),
        notas_dir=str(tmp_path / "notas"),
    )
    return create_app(settings=s)


@pytest.fixture
def api(app) -> TestClient:  # type: ignore[no-untyped-def]
    return TestClient(app, headers=AUTH_HEADERS)


def test_exige_chave(app) -> None:  # type: ignore[no-untyped-def]
    assert TestClient(app).get("/api/painel/metas").status_code == 401


def test_suggested_agenda_and_pushback(api: TestClient) -> None:
    api.post("/api/rotinas/tarefas", json={"titulo": "Baixa", "prioridade": "baixa"})
    api.post(
        "/api/rotinas/tarefas", json={"titulo": "Entrega", "prioridade": "alta", "prazo": HOJE}
    )
    ag = api.post(f"/api/painel/agenda/{HOJE}/sugerir").json()
    assert [b["titulo"] for b in ag["blocos"]] == ["Entrega", "Baixa"]
    assert ag["blocos"][0]["inicio"] == "08:00"

    # pushing the priority to the end of the day gets pushback
    entrega, baixa = ag["blocos"]
    entrega |= {"inicio": "17:00", "fim": "17:50"}
    r = api.put(
        f"/api/painel/agenda/{HOJE}", json={"blocos": [baixa, entrega], "motivo": "reunião"}
    )
    assert r.status_code == 200 and "17:00" in r.json()["contestacoes"][0]

    # removing it from the day too
    r = api.put(f"/api/painel/agenda/{HOJE}", json={"blocos": [baixa]}).json()
    assert "tirou" in r["contestacoes"][0] and len(r["alteracoes"]) == 2

    block = api.post(f"/api/painel/agenda/{HOJE}/blocos/{baixa['id']}/feito").json()
    assert block["feito"] is True
    invalid = {"blocos": [{"titulo": "x", "inicio": "10:00", "fim": "09:00"}]}
    assert api.put(f"/api/painel/agenda/{HOJE}", json=invalid).status_code == 422


def test_goals_and_discipline(tmp_path: Path) -> None:
    c = Nagger(tmp_path)
    reading = c.create_meta(
        {"titulo": "Ler", "frequencia": "diaria", "alvo": 2, "unidade": "capítulo"}
    )
    c.register_action(reading["id"])
    tasks = [
        {
            "id": "t1",
            "titulo": "Relatório",
            "prioridade": "alta",
            "prazo": "2000-01-01",
            "coluna": "pendente",
        }
    ]
    c.suggest(c.agora().date().isoformat(), tasks)

    night = c.agora().replace(hour=19, minute=0)
    d = c.disciplina(tasks, night)
    assert d["blocos"] == {"total": 1, "vencidos": 1, "feitos": 0}
    assert d["metas"] == {"total": 1, "no_ritmo": 0}
    assert d["indice"] == 0 and d["dentro"] is False
    texts = " ".join(a["texto"] for a in d["alertas"])
    assert "Relatório" in texts and "Ler" in texts
    assert "Relatório" in c.contexto(tasks)


def test_weekly_goal_pace(tmp_path: Path) -> None:
    c = Nagger(tmp_path)
    m = c.create_meta({"titulo": "Treino", "frequencia": "semanal", "alvo": 7})
    quarta = datetime(2026, 10, 28).date()
    assert c.metas(quarta)[0]["esperado"] == 3.0
    assert c.metas(quarta)[0]["id"] == m["id"]


def test_chat_note_search_and_chat(app, api: TestClient) -> None:  # type: ignore[no-untyped-def]
    seen: list[list[dict[str, str]]] = []

    async def falso(mensagens: list[dict[str, str]]) -> str:
        seen.append(mensagens)
        return "ok"

    app.state.painel_llms = {"local": falso}
    r = api.post(
        "/api/painel/conversar", json={"mensagem": "anote que o fornecedor de áudio é a Loja X"}
    )
    assert r.json()["acao"] == "nota" and r.json()["nota"]["tags"] == ["cobrador"]

    r = api.post(
        "/api/painel/conversar", json={"mensagem": "pesquise na base fornecedor de áudio"}
    ).json()
    assert r["acao"] == "pesquisa" and len(r["notas"]) == 1
    assert "Loja X" in seen[-1][0]["content"]

    r = api.post("/api/painel/conversar", json={"mensagem": "o que faço agora?"}).json()
    assert (
        r == {"resposta": "ok", "acao": None, "executadas": []}
        and "Cobrador" in seen[-1][0]["content"]
    )

    api.post("/api/painel/conversar", json={"mensagem": "o que é isso?", "imagem": "QUJD"})
    assert seen[-1][-1]["content"][1] == {
        "type": "image_url",
        "image_url": {"url": "data:image/jpeg;base64,QUJD"},
    }

    assert (
        api.post("/api/painel/conversar", json={"mensagem": "oi", "provedor": "claude"}).status_code
        == 422
    )

    async def fora(_: list[dict[str, str]]) -> str:
        raise LLMUnavailable("sem worker")

    app.state.painel_llms = {"local": fora}
    assert api.post("/api/painel/conversar", json={"mensagem": "oi"}).status_code == 503
    assert api.get("/api/painel/provedores").json() == ["local"]


def test_agent_runs_actions(app, api: TestClient) -> None:  # type: ignore[no-untyped-def]
    meta = api.post("/api/painel/metas", json={"titulo": "Ler", "alvo": 2}).json()
    answer = (
        "Feito. Encaixei o relatório.\n```acoes\n"
        '[{"tipo": "criar_tarefa", "titulo": "Relatório", "prioridade": "alta"},'
        ' {"tipo": "adicionar_bloco", "titulo": "Relatório", "inicio": "09:00", "fim": "09:50",'
        ' "prioridade": "alta"},'
        ' {"tipo": "registrar_meta", "meta": "ler"},'
        ' {"tipo": "remover_bloco", "titulo": "Inexistente"}]\n```'
    )

    async def falso(_: list[dict[str, str]]) -> str:
        return answer

    app.state.painel_llms = {"local": falso}
    r = api.post("/api/painel/conversar", json={"mensagem": "encaixa o relatório às 9"}).json()
    assert r["resposta"] == "Feito. Encaixei o relatório." and r["acao"] == "agente"
    assert [a["ok"] for a in r["executadas"]] == [True, True, True, False]
    assert api.get("/api/rotinas/tarefas").json()[0]["titulo"] == "Relatório"
    assert api.get("/api/painel/metas").json()[0]["feito"] == 1 and meta["id"]

    # moving the priority to the end of the day: it runs, but comes back with pushback
    movida = answer.split("```acoes")[0] + (
        '```acoes\n[{"tipo": "mover_bloco", "titulo": "Relatório", "inicio": "17:00",'
        ' "fim": "17:50"}]\n```'
    )

    async def mover(_: list[dict[str, str]]) -> str:
        return movida

    app.state.painel_llms = {"local": mover}
    r = api.post("/api/painel/conversar", json={"mensagem": "joga pro fim do dia"}).json()
    assert "contestado" in r["executadas"][0]["detalhe"]


def test_agent_commands_the_pc(app, api: TestClient) -> None:  # type: ignore[no-untyped-def]
    requests: list[dict[str, Any]] = []

    async def pc(pedido: dict[str, Any]) -> dict[str, Any]:
        requests.append(pedido)
        return {"ok": True, "detalhe": "Abri"}

    async def falso(_: list[dict[str, str]]) -> str:
        return (
            'Abrindo.\n```acoes\n[{"tipo": "pesquisar_no_pc", "consulta": "Flamengo",'
            ' "onde": "google"}]\n```'
        )

    app.state.painel_llms = {"local": falso}
    app.state.painel_pc = pc
    # "notícias" would go to the internet shortcut; with "Brave" it goes to the agent
    msg = "abre o Brave e pesquisa notícias do Flamengo"
    r = api.post("/api/painel/conversar", json={"mensagem": msg}).json()
    assert r["acao"] == "agente" and r["executadas"][0]["ok"]
    assert requests == [{"consulta": "Flamengo", "onde": "google", "acao": "pesquisar"}]

    assert api.post("/api/painel/pc", json={"acao": "desligar"}).json()["detalhe"] == "Abri"
    assert requests[-1] == {"acao": "desligar", "minutos": 0}
    assert api.post("/api/painel/pc", json={"acao": "rm -rf"}).status_code == 422


def test_agent_query_and_performance(app, api: TestClient) -> None:  # type: ignore[no-untyped-def]
    t = api.post("/api/rotinas/tarefas", json={"titulo": "Relatório", "prazo": "2020-01-01"})
    api.post("/api/notas", json={"titulo": "Clientes", "corpo": "Ana paga em dia."})
    seen: list[str] = []

    async def falso(msgs: list[dict[str, str]]) -> str:
        question = msgs[-1]["content"]
        seen.append(msgs[0]["content"] + question)
        if "[Results" not in question:
            return (
                'Vou ver.\n```acoes\n[{"tipo": "pesquisar_notas", "consulta": "clientes"},'
                ' {"tipo": "analisar_desempenho", "dias": 7}]\n```'
            )
        return (
            'Ana paga em dia.\n```acoes\n[{"tipo": "concluir_tarefa", "titulo": "relatorio"},'
            ' {"tipo": "criar_nota", "titulo": "Plano", "corpo": "# Plano",'
            ' "tags": ["plano"]}]\n```'
        )

    app.state.painel_llms = {"local": falso}
    r = api.post("/api/painel/conversar", json={"mensagem": "e os clientes?"}).json()
    assert r["resposta"] == "Ana paga em dia."
    assert [e["tipo"] for e in r["executadas"]] == [
        "pesquisar_notas",
        "analisar_desempenho",
        "concluir_tarefa",
        "criar_nota",
    ]
    assert all(e["ok"] for e in r["executadas"])
    assert "Ana paga em dia" in seen[1] and "Performance from" in seen[1]
    assert api.get("/api/rotinas/tarefas").json()[0]["coluna"] == "concluida" and t.json()["id"]

    d = api.get("/api/painel/desempenho", params={"dias": 7}).json()
    assert d["tarefas"]["concluidas"] == 1 and d["tarefas"]["fora_do_prazo"] == 1

    r = api.post("/api/painel/conversar", json={"mensagem": "como está meu desempenho?"}).json()
    assert r["desempenho"]["tarefas"]["concluidas"] == 1
    assert "How to analyze performance" in seen[-1]

    # streaming: the progress notice comes out before the final answer
    lines = api.post("/api/painel/conversar/fluxo", json={"mensagem": "e os clientes?"}).text
    events = [json.loads(x) for x in lines.splitlines() if x.strip()]
    assert [e["evento"] for e in events] == ["aviso", "aviso", "fim"]
    assert events[0]["texto"] == "Vou procurar nas suas notas."
    assert events[-1]["resposta"] == "Ana paga em dia."


def test_voice_transcribes_and_speaks(app, api: TestClient) -> None:  # type: ignore[no-untyped-def]
    from panel.api import Voice

    async def transcrever(audio: bytes, mime: str, idioma: str) -> str:
        return f"anote {audio.decode()}"

    async def falar(texto: str) -> bytes:
        return b"RIFF" + texto.encode()

    app.state.painel_voz = Voice(transcrever, falar)
    r = api.post("/api/painel/voz", files={"audio": ("a.wav", b"comprar cabo", "audio/wav")})
    assert r.json()["transcricao"] == "anote comprar cabo" and r.json()["acao"] == "nota"
    so = api.post("/api/painel/transcrever", files={"audio": ("a.wav", b"x", "audio/wav")})
    assert so.json() == {"texto": "anote x"}
    flow = api.post("/api/painel/voz/fluxo", files={"audio": ("a.wav", b"pao", "audio/wav")})
    events = [json.loads(x) for x in flow.text.splitlines() if x.strip()]
    assert events[0] == {"evento": "transcricao", "texto": "anote pao"}
    assert events[-1]["evento"] == "fim" and events[-1]["acao"] == "nota"
    speech = api.post("/api/painel/falar", json={"texto": "oi"})
    assert speech.headers["content-type"] == "audio/wav" and speech.content == b"RIFFoi"


def test_dashboard_measures_requests(app, api: TestClient) -> None:  # type: ignore[no-untyped-def]
    m = app.state.medidor
    m.registrar({"provedor": "local", "tarefa": "chat", "modelo": "q", "ms": 100, "erro": None})
    m.registrar({"provedor": "local", "tarefa": "chat", "modelo": "q", "ms": 300, "erro": "x"})
    m.registrar({"provedor": "claude", "ms": 50, "erro": None, "tokens_saida": 7})
    d = api.get("/api/painel/dashboard").json()
    assert d["provedores"]["local"]["disponibilidade_pct"] == 50.0
    assert d["provedores"]["claude"]["tokens_saida"] == 7
    assert d["recentes"][0]["provedor"] == "claude" and d["workers"] == []
    # the file persists: a new meter rereads the requests
    from panel.meter import Meter

    assert Meter(m.root).resumo()["provedores"]["local"]["pedidos"] == 2


def test_notifier_sends_each_alert_once(tmp_path: Path) -> None:
    from panel.notifier import Notifier

    enviados: list[tuple[str, str, str]] = []
    c = Nagger(tmp_path)
    tasks = [
        {
            "id": "t",
            "titulo": "Imposto",
            "prioridade": "alta",
            "prazo": "2000-01-01",
            "coluna": "pendente",
        }
    ]
    n = Notifier(c, lambda: tasks, "https://ntfy.sh/x", send=lambda *a: enviados.append(a))
    assert n.verify() and any("Imposto" in e[1] and e[2] == "high" for e in enviados)
    total = len(enviados)
    assert n.verify() == [] and len(enviados) == total


def test_agent_creates_in_other_modules(tmp_path: Path) -> None:
    s = Settings(
        client_api_keys=CLIENT_API_KEY,
        painel_dir=str(tmp_path / "painel"),
        rotinas_dir=str(tmp_path / "rotinas"),
        notas_dir=str(tmp_path / "notas"),
        design_dir=str(tmp_path / "design"),
        estudos_dir=str(tmp_path / "estudos"),
    )
    app = create_app(settings=s)
    api = TestClient(app, headers=AUTH_HEADERS)
    seen: list[list[dict[str, Any]]] = []

    async def falso(mensagens: list[dict[str, Any]]) -> str:
        seen.append(mensagens)
        if "flowcharts" in mensagens[0]["content"]:  # the flow request, made by the action
            return (
                '{"titulo": "Compra", "nos": [{"id": "a", "tipo": "inicio", "texto": "Início"},'
                ' {"id": "b", "tipo": "fim", "texto": "Fim"}],'
                ' "ligacoes": [{"de": "a", "para": "b"}]}'
            )
        return (
            "Pronto.\n```acoes\n["
            '{"tipo": "criar_caderno", "titulo": "Diário"},'
            '{"tipo": "criar_fluxograma", "titulo": "Compra", "descricao": "fluxo de compra"},'
            '{"tipo": "criar_projeto_estudo", "nome": "Economia", "secoes": ["Macro"]},'
            '{"tipo": "criar_leitura", "titulo": "O Capital", "area": "Economia"},'
            '{"tipo": "criar_meta", "titulo": "Ler 20 páginas", "unidade": "sessão"}'
            "]\n```"
        )

    app.state.painel_llms = {"local": falso}
    r = api.post("/api/painel/conversar", json={"mensagem": "crie um caderno e o resto"}).json()
    assert [e["ok"] for e in r["executadas"]] == [True] * 5, r["executadas"]
    assert r["resposta"] == "Pronto."
    # stable system prompt (without the time) and the time only in the user message, for the prompt
    # cache
    system, question = seen[0][0]["content"], seen[0][-1]["content"]
    assert "criar_caderno" in system and ", now " not in system.split("# Snapshot of the day")[1]
    assert question.startswith("[Today ") and question.endswith("crie um caderno e o resto")

    assert [c["titulo"] for c in app.state.cadernos_design.list_all()] == ["Diário"]
    flow = app.state.quadros_design.list_all()[0]
    elements = app.state.quadros_design.obter(flow["id"])["elementos"]
    assert {e["tipo"] for e in elements} == {"no", "ligacao"}
    assert app.state.studies.list_projects()[0]["secoes"] == ["Macro"]
    assert app.state.studies.list_readings()[0]["titulo"] == "O Capital"
    assert any(m["titulo"] == "Ler 20 páginas" for m in app.state.nagger.metas())
