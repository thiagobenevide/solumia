import json
from datetime import datetime
from pathlib import Path
from typing import Any

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from painel.api import LLMIndisponivel
from painel.cobrador import Cobrador

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


def test_agenda_sugerida_e_contestacao(api: TestClient) -> None:
    api.post("/api/rotinas/tarefas", json={"titulo": "Baixa", "prioridade": "baixa"})
    api.post(
        "/api/rotinas/tarefas", json={"titulo": "Entrega", "prioridade": "alta", "prazo": HOJE}
    )
    ag = api.post(f"/api/painel/agenda/{HOJE}/sugerir").json()
    assert [b["titulo"] for b in ag["blocos"]] == ["Entrega", "Baixa"]
    assert ag["blocos"][0]["inicio"] == "08:00"

    # empurrar a prioridade para o fim do dia é contestado
    entrega, baixa = ag["blocos"]
    entrega |= {"inicio": "17:00", "fim": "17:50"}
    r = api.put(
        f"/api/painel/agenda/{HOJE}", json={"blocos": [baixa, entrega], "motivo": "reunião"}
    )
    assert r.status_code == 200 and "17:00" in r.json()["contestacoes"][0]

    # tirar do dia também
    r = api.put(f"/api/painel/agenda/{HOJE}", json={"blocos": [baixa]}).json()
    assert "tirou" in r["contestacoes"][0] and len(r["alteracoes"]) == 2

    bloco = api.post(f"/api/painel/agenda/{HOJE}/blocos/{baixa['id']}/feito").json()
    assert bloco["feito"] is True
    invalido = {"blocos": [{"titulo": "x", "inicio": "10:00", "fim": "09:00"}]}
    assert api.put(f"/api/painel/agenda/{HOJE}", json=invalido).status_code == 422


def test_metas_e_disciplina(tmp_path: Path) -> None:
    c = Cobrador(tmp_path)
    leitura = c.criar_meta(
        {"titulo": "Ler", "frequencia": "diaria", "alvo": 2, "unidade": "capítulo"}
    )
    c.registrar_acao(leitura["id"])
    tarefas = [
        {
            "id": "t1",
            "titulo": "Relatório",
            "prioridade": "alta",
            "prazo": "2000-01-01",
            "coluna": "pendente",
        }
    ]
    c.sugerir(c.agora().date().isoformat(), tarefas)

    noite = c.agora().replace(hour=19, minute=0)
    d = c.disciplina(tarefas, noite)
    assert d["blocos"] == {"total": 1, "vencidos": 1, "feitos": 0}
    assert d["metas"] == {"total": 1, "no_ritmo": 0}
    assert d["indice"] == 0 and d["dentro"] is False
    textos = " ".join(a["texto"] for a in d["alertas"])
    assert "Relatório" in textos and "Ler" in textos
    assert "Relatório" in c.contexto(tarefas)


def test_meta_semanal_ritmo(tmp_path: Path) -> None:
    c = Cobrador(tmp_path)
    m = c.criar_meta({"titulo": "Treino", "frequencia": "semanal", "alvo": 7})
    quarta = datetime(2026, 10, 28).date()
    assert c.metas(quarta)[0]["esperado"] == 3.0
    assert c.metas(quarta)[0]["id"] == m["id"]


def test_conversa_nota_pesquisa_e_chat(app, api: TestClient) -> None:  # type: ignore[no-untyped-def]
    vistos: list[list[dict[str, str]]] = []

    async def falso(mensagens: list[dict[str, str]]) -> str:
        vistos.append(mensagens)
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
    assert "Loja X" in vistos[-1][0]["content"]

    r = api.post("/api/painel/conversar", json={"mensagem": "o que faço agora?"}).json()
    assert (
        r == {"resposta": "ok", "acao": None, "executadas": []}
        and "Cobrador" in vistos[-1][0]["content"]
    )

    api.post("/api/painel/conversar", json={"mensagem": "o que é isso?", "imagem": "QUJD"})
    assert vistos[-1][-1]["content"][1] == {
        "type": "image_url",
        "image_url": {"url": "data:image/jpeg;base64,QUJD"},
    }

    assert (
        api.post("/api/painel/conversar", json={"mensagem": "oi", "provedor": "claude"}).status_code
        == 422
    )

    async def fora(_: list[dict[str, str]]) -> str:
        raise LLMIndisponivel("sem worker")

    app.state.painel_llms = {"local": fora}
    assert api.post("/api/painel/conversar", json={"mensagem": "oi"}).status_code == 503
    assert api.get("/api/painel/provedores").json() == ["local"]


def test_agente_executa_acoes(app, api: TestClient) -> None:  # type: ignore[no-untyped-def]
    meta = api.post("/api/painel/metas", json={"titulo": "Ler", "alvo": 2}).json()
    resposta = (
        "Feito. Encaixei o relatório.\n```acoes\n"
        '[{"tipo": "criar_tarefa", "titulo": "Relatório", "prioridade": "alta"},'
        ' {"tipo": "adicionar_bloco", "titulo": "Relatório", "inicio": "09:00", "fim": "09:50",'
        ' "prioridade": "alta"},'
        ' {"tipo": "registrar_meta", "meta": "ler"},'
        ' {"tipo": "remover_bloco", "titulo": "Inexistente"}]\n```'
    )

    async def falso(_: list[dict[str, str]]) -> str:
        return resposta

    app.state.painel_llms = {"local": falso}
    r = api.post("/api/painel/conversar", json={"mensagem": "encaixa o relatório às 9"}).json()
    assert r["resposta"] == "Feito. Encaixei o relatório." and r["acao"] == "agente"
    assert [a["ok"] for a in r["executadas"]] == [True, True, True, False]
    assert api.get("/api/rotinas/tarefas").json()[0]["titulo"] == "Relatório"
    assert api.get("/api/painel/metas").json()[0]["feito"] == 1 and meta["id"]

    # mover a prioridade para o fim do dia: executa, mas volta contestado
    movida = resposta.split("```acoes")[0] + (
        '```acoes\n[{"tipo": "mover_bloco", "titulo": "Relatório", "inicio": "17:00",'
        ' "fim": "17:50"}]\n```'
    )

    async def mover(_: list[dict[str, str]]) -> str:
        return movida

    app.state.painel_llms = {"local": mover}
    r = api.post("/api/painel/conversar", json={"mensagem": "joga pro fim do dia"}).json()
    assert "contestado" in r["executadas"][0]["detalhe"]


def test_agente_comanda_o_pc(app, api: TestClient) -> None:  # type: ignore[no-untyped-def]
    pedidos: list[dict[str, Any]] = []

    async def pc(pedido: dict[str, Any]) -> dict[str, Any]:
        pedidos.append(pedido)
        return {"ok": True, "detalhe": "Abri"}

    async def falso(_: list[dict[str, str]]) -> str:
        return (
            'Abrindo.\n```acoes\n[{"tipo": "pesquisar_no_pc", "consulta": "Flamengo",'
            ' "onde": "google"}]\n```'
        )

    app.state.painel_llms = {"local": falso}
    app.state.painel_pc = pc
    # "notícias" iria ao atalho da internet; com "Brave" vai ao agente
    msg = "abre o Brave e pesquisa notícias do Flamengo"
    r = api.post("/api/painel/conversar", json={"mensagem": msg}).json()
    assert r["acao"] == "agente" and r["executadas"][0]["ok"]
    assert pedidos == [{"consulta": "Flamengo", "onde": "google", "acao": "pesquisar"}]

    assert api.post("/api/painel/pc", json={"acao": "desligar"}).json()["detalhe"] == "Abri"
    assert pedidos[-1] == {"acao": "desligar", "minutos": 0}
    assert api.post("/api/painel/pc", json={"acao": "rm -rf"}).status_code == 422


def test_agente_consulta_e_desempenho(app, api: TestClient) -> None:  # type: ignore[no-untyped-def]
    t = api.post("/api/rotinas/tarefas", json={"titulo": "Relatório", "prazo": "2020-01-01"})
    api.post("/api/notas", json={"titulo": "Clientes", "corpo": "Ana paga em dia."})
    vistos: list[str] = []

    async def falso(msgs: list[dict[str, str]]) -> str:
        pergunta = msgs[-1]["content"]
        vistos.append(msgs[0]["content"] + pergunta)
        if "[Resultados" not in pergunta:
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
    assert "Ana paga em dia" in vistos[1] and "Desempenho de" in vistos[1]
    assert api.get("/api/rotinas/tarefas").json()[0]["coluna"] == "concluida" and t.json()["id"]

    d = api.get("/api/painel/desempenho", params={"dias": 7}).json()
    assert d["tarefas"]["concluidas"] == 1 and d["tarefas"]["fora_do_prazo"] == 1

    r = api.post("/api/painel/conversar", json={"mensagem": "como está meu desempenho?"}).json()
    assert r["desempenho"]["tarefas"]["concluidas"] == 1
    assert "Como analisar o desempenho" in vistos[-1]

    # em fluxo: o aviso de andamento sai antes da resposta final
    linhas = api.post("/api/painel/conversar/fluxo", json={"mensagem": "e os clientes?"}).text
    eventos = [json.loads(x) for x in linhas.splitlines() if x.strip()]
    assert [e["evento"] for e in eventos] == ["aviso", "aviso", "fim"]
    assert eventos[0]["texto"] == "Vou procurar nas suas notas."
    assert eventos[-1]["resposta"] == "Ana paga em dia."


def test_voz_transcreve_e_fala(app, api: TestClient) -> None:  # type: ignore[no-untyped-def]
    from painel.api import Voz

    async def transcrever(audio: bytes, mime: str, idioma: str) -> str:
        return f"anote {audio.decode()}"

    async def falar(texto: str) -> bytes:
        return b"RIFF" + texto.encode()

    app.state.painel_voz = Voz(transcrever, falar)
    r = api.post("/api/painel/voz", files={"audio": ("a.wav", b"comprar cabo", "audio/wav")})
    assert r.json()["transcricao"] == "anote comprar cabo" and r.json()["acao"] == "nota"
    so = api.post("/api/painel/transcrever", files={"audio": ("a.wav", b"x", "audio/wav")})
    assert so.json() == {"texto": "anote x"}
    fluxo = api.post("/api/painel/voz/fluxo", files={"audio": ("a.wav", b"pao", "audio/wav")})
    eventos = [json.loads(x) for x in fluxo.text.splitlines() if x.strip()]
    assert eventos[0] == {"evento": "transcricao", "texto": "anote pao"}
    assert eventos[-1]["evento"] == "fim" and eventos[-1]["acao"] == "nota"
    fala = api.post("/api/painel/falar", json={"texto": "oi"})
    assert fala.headers["content-type"] == "audio/wav" and fala.content == b"RIFFoi"


def test_dashboard_mede_os_pedidos(app, api: TestClient) -> None:  # type: ignore[no-untyped-def]
    m = app.state.medidor
    m.registrar({"provedor": "local", "tarefa": "chat", "modelo": "q", "ms": 100, "erro": None})
    m.registrar({"provedor": "local", "tarefa": "chat", "modelo": "q", "ms": 300, "erro": "x"})
    m.registrar({"provedor": "claude", "ms": 50, "erro": None, "tokens_saida": 7})
    d = api.get("/api/painel/dashboard").json()
    assert d["provedores"]["local"]["disponibilidade_pct"] == 50.0
    assert d["provedores"]["claude"]["tokens_saida"] == 7
    assert d["recentes"][0]["provedor"] == "claude" and d["workers"] == []
    # o arquivo persiste: um novo medidor relê os pedidos
    from painel.medidor import Medidor

    assert Medidor(m.raiz).resumo()["provedores"]["local"]["pedidos"] == 2


def test_notificador_envia_cada_alerta_uma_vez(tmp_path: Path) -> None:
    from painel.notificador import Notificador

    enviados: list[tuple[str, str, str]] = []
    c = Cobrador(tmp_path)
    tarefas = [
        {
            "id": "t",
            "titulo": "Imposto",
            "prioridade": "alta",
            "prazo": "2000-01-01",
            "coluna": "pendente",
        }
    ]
    n = Notificador(c, lambda: tarefas, "https://ntfy.sh/x", enviar=lambda *a: enviados.append(a))
    assert n.verificar() and any("Imposto" in e[1] and e[2] == "high" for e in enviados)
    total = len(enviados)
    assert n.verificar() == [] and len(enviados) == total


def test_agente_cria_nos_outros_modulos(tmp_path: Path) -> None:
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
    vistos: list[list[dict[str, Any]]] = []

    async def falso(mensagens: list[dict[str, Any]]) -> str:
        vistos.append(mensagens)
        if "fluxogramas" in mensagens[0]["content"]:  # o pedido do fluxo, feito pela ação
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
    # sistema estável (sem a hora) e a hora só na mensagem do usuário, para o cache do prompt
    sistema, pergunta = vistos[0][0]["content"], vistos[0][-1]["content"]
    assert "criar_caderno" in sistema and "agora" not in sistema.split("# Retrato do dia")[1]
    assert pergunta.startswith("[Hoje ") and pergunta.endswith("crie um caderno e o resto")

    assert [c["titulo"] for c in app.state.cadernos_design.listar()] == ["Diário"]
    fluxo = app.state.quadros_design.listar()[0]
    elementos = app.state.quadros_design.obter(fluxo["id"])["elementos"]
    assert {e["tipo"] for e in elementos} == {"no", "ligacao"}
    assert app.state.estudos.listar_projetos()[0]["secoes"] == ["Macro"]
    assert app.state.estudos.listar_leituras()[0]["titulo"] == "O Capital"
    assert any(m["titulo"] == "Ler 20 páginas" for m in app.state.cobrador.metas())
