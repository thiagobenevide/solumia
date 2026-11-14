from datetime import date
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app

OFX = b"""OFXHEADER:100
<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>
<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20261005120000<TRNAMT>5000.00<FITID>a1<MEMO>SALARIO EMPRESA X
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261006120000<TRNAMT>-120.50<FITID>a2<MEMO>PIX ENVIADO Maria Silva
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261007120000<TRNAMT>-80.00<FITID>a3<MEMO>COMPRA IFOOD
</BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>"""

CSV_FATURA = (
    "Data;Descrição;Valor\n03/10/2026;UBER TRIP;25,90\n20/10/2026;LOJA ABC 1/3;300,00\n".encode()
)


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, financas_dir=str(tmp_path))
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def _cat(api: TestClient, nome: str) -> str:
    return next(c["id"] for c in api.get("/api/financas/categorias").json() if c["nome"] == nome)


def test_exige_chave(tmp_path: Path) -> None:
    s = Settings(client_api_keys=CLIENT_API_KEY, financas_dir=str(tmp_path))
    assert TestClient(create_app(settings=s)).get("/api/financas/contas").status_code == 401


def test_colecao_desconhecida_e_validacao(api: TestClient) -> None:
    assert api.get("/api/financas/xyz").status_code == 404
    assert api.post("/api/financas/contas", json={}).status_code == 422
    assert api.post("/api/financas/contas", json={"nome": "X", "tipo": "foo"}).status_code == 422


def test_importa_ofx_com_regra_e_sem_duplicar(api: TestClient) -> None:
    account = api.post("/api/financas/contas", json={"nome": "Banco", "saldo_inicial": 100}).json()
    market = _cat(api, "Restaurantes")
    api.post(
        "/api/financas/regras",
        json={"padrao": "ifood", "categoria_id": market, "contraparte": "iFood"},
    )
    r = api.post(
        "/api/financas/importar", data={"conta_id": account["id"]}, files={"arquivo": ("e.ofx", OFX)}
    )
    assert r.json()["importadas"] == 3
    r = api.post(
        "/api/financas/importar", data={"conta_id": account["id"]}, files={"arquivo": ("e.ofx", OFX)}
    )
    assert r.json() == {"lidas": 3, "importadas": 0, "duplicadas": 3, "sem_categoria": 0}

    ts = api.get("/api/financas/transacoes", params={"q": "ifood"}).json()
    assert ts[0]["categoria_id"] == market and ts[0]["contraparte"] == "iFood"
    pix = api.get("/api/financas/transacoes", params={"q": "maria"}).json()[0]
    assert pix["contraparte"] == "Maria Silva"

    # categoriza em lote criando regra
    salario = _cat(api, "Salário")
    sem = api.get("/api/financas/transacoes", params={"sem_categoria": True}).json()
    target = [t["id"] for t in sem if "SALARIO" in t["descricao"]]
    r = api.post(
        "/api/financas/transacoes/lote",
        json={"ids": target, "dados": {"categoria_id": salario}, "regra": "salario"},
    )
    assert r.json() == {"alteradas": 1}

    res = api.get("/api/financas/resumo", params={"mes": "2026-10"}).json()
    assert res["receitas"] == 5000 and res["despesas"] == 200.5
    assert res["indicadores"]["taxa_poupanca"] == pytest.approx(96.0, abs=0.1)
    assert next(c for c in res["contas"] if c["id"] == account["id"])["saldo"] == pytest.approx(
        4899.5
    )
    top = api.get("/api/financas/contrapartes").json()
    assert top["enviado"][0]["nome"] == "Maria Silva" and top["recebido"][0]["valor"] == 5000


def test_fatura_do_cartao(api: TestClient) -> None:
    cartao = api.post(
        "/api/financas/contas",
        json={
            "nome": "Cartão",
            "tipo": "cartao",
            "limite": 2000,
            "dia_fechamento": 15,
            "dia_vencimento": 22,
        },
    ).json()
    r = api.post(
        "/api/financas/importar",
        data={"conta_id": cartao["id"]},
        files={"arquivo": ("f.csv", CSV_FATURA)},
    )
    assert r.json()["importadas"] == 2
    f = api.get(f"/api/financas/faturas/{cartao['id']}").json()
    months = {x["mes"]: x for x in f["faturas"]}
    assert months["2026-10"]["total"] == 25.9 and months["2026-10"]["vencimento"] == "2026-10-22"
    assert months["2026-11"]["total"] == 300
    assert f["usado"] == 325.9 and f["disponivel"] == 1674.1
    loja = api.get("/api/financas/transacoes", params={"q": "loja"}).json()[0]
    assert loja["parcela"] == "1/3" and loja["valor"] == -300


def test_programacao_projeta_e_lanca(api: TestClient) -> None:
    today = date.today()
    p = api.post(
        "/api/financas/programacoes",
        json={
            "descricao": "Aluguel",
            "valor": -1500,
            "inicio": today.replace(day=1).isoformat(),
        },
    ).json()
    items = api.get("/api/financas/projecao", params={"dias": 70}).json()["itens"]
    assert len(items) >= 2 and all(i["programacao_id"] == p["id"] for i in items)
    r = api.post(f"/api/financas/programacoes/{p['id']}/lancar", json={"data": items[0]["data"]})
    assert r.status_code == 201
    after = api.get("/api/financas/projecao", params={"dias": 70}).json()["itens"]
    assert items[0]["data"] not in {i["data"] for i in after}


def test_meta_com_aportes(api: TestClient) -> None:
    reserve = _cat(api, "Reserva de emergência")
    api.post(
        "/api/financas/transacoes",
        json={"data": "2026-01-10", "descricao": "Aporte", "valor": -1000, "categoria_id": reserve},
    )
    api.post(
        "/api/financas/metas",
        json={
            "nome": "Reserva",
            "valor_alvo": 10000,
            "valor_inicial": 500,
            "categoria_id": reserve,
        },
    )
    m = api.get("/api/financas/metas/progresso").json()[0]
    assert m["atual"] == 1500 and m["progresso"] == 15.0


def test_analise_de_empresa_e_carteira(api: TestClient) -> None:
    api.post("/api/financas/setores", json={"nome": "Energia", "respostas": {"s1": 5, "s2": 5}})
    e = api.post(
        "/api/financas/empresas",
        json={
            "ticker": "taee11",
            "nome": "Taesa",
            "setor": "Energia",
            "cotacao": 35,
            "acoes": 1000,
            "demonstrativos": [
                {
                    "ano": 2024,
                    "receita_liquida": 3000,
                    "custo": 1000,
                    "despesas_operacionais": 500,
                    "lucro_liquido": 900,
                    "patrimonio_liquido": 5000,
                },
                {
                    "ano": 2025,
                    "receita_liquida": 3300,
                    "lucro_bruto": 2300,
                    "ebit": 1800,
                    "depreciacao": 200,
                    "lucro_liquido": 1000,
                    "patrimonio_liquido": 5500,
                    "divida_bruta": 3000,
                    "caixa": 1000,
                    "dividendos": 2500,
                    "fco": 1200,
                    "ativo_total": 12000,
                },
            ],
            "respostas": {"n1": 5, "n2": 4},
        },
    ).json()
    assert e["ticker"] == "TAEE11"
    assert api.post("/api/financas/empresas", json={"ticker": "TAEE11"}).status_code == 422
    a = api.get(f"/api/financas/empresas/{e['id']}/analise").json()
    ult = a["indicadores"][-1]
    assert ult["roe"] == pytest.approx(18.18) and ult["divida_liquida_ebitda"] == 1.0
    assert ult["cresc_receita"] == 10.0 and a["vertical"][0]["lucro_bruto"] == pytest.approx(66.67)
    assert a["valuation"]["pl"] == 35.0 and a["valuation"]["dy"] == pytest.approx(7.14)
    assert a["setor"]["nota"] == 100 and a["nota_final"] is not None and a["veredito"]
    assert api.get("/api/financas/empresas/ranking").json()[0]["ticker"] == "TAEE11"

    api.post(
        "/api/financas/operacoes",
        json={"data": "2026-01-02", "ticker": "TAEE11", "quantidade": 10, "preco": 30},
    )
    api.post(
        "/api/financas/operacoes",
        json={"data": "2026-02-02", "ticker": "TAEE11", "quantidade": 10, "preco": 40},
    )
    api.post(
        "/api/financas/operacoes",
        json={
            "data": "2026-03-02",
            "ticker": "TAEE11",
            "tipo": "venda",
            "quantidade": 5,
            "preco": 45,
        },
    )
    api.post(
        "/api/financas/proventos", json={"data": "2026-03-10", "ticker": "TAEE11", "valor": 20}
    )
    c = api.get("/api/financas/carteira").json()
    p = c["posicoes"][0]
    assert p["quantidade"] == 15 and p["preco_medio"] == 35 and p["realizado"] == 50
    assert (
        p["valor_atual"] == 525 and p["proventos"] == 20 and c["por_setor"][0]["setor"] == "Energia"
    )


def test_questionario_editavel(api: TestClient) -> None:
    q = api.get("/api/financas/questionario").json()
    assert {p["alvo"] for p in q} == {"empresa", "setor"}
    new = api.put(
        "/api/financas/questionario", json=[*q, {"texto": "Paga dividendos há 10 anos?", "peso": 2}]
    ).json()
    assert len(new) == len(q) + 1 and new[-1]["alvo"] == "empresa"


def test_excluir_conta_limpa_referencias(api: TestClient) -> None:
    account = api.post("/api/financas/contas", json={"nome": "X"}).json()
    t = api.post(
        "/api/financas/transacoes",
        json={"data": "2026-01-01", "descricao": "a", "valor": 1, "conta_id": account["id"]},
    ).json()
    assert api.delete(f"/api/financas/contas/{account['id']}").status_code == 204
    assert api.get(f"/api/financas/transacoes/{t['id']}").json()["conta_id"] == ""


def test_excluir_em_lote(api: TestClient) -> None:
    account = api.post("/api/financas/contas", json={"nome": "Banco"}).json()
    api.post(
        "/api/financas/importar", data={"conta_id": account["id"]}, files={"arquivo": ("e.ofx", OFX)}
    )
    ids = [t["id"] for t in api.get("/api/financas/transacoes").json()]
    assert ids
    r = api.post("/api/financas/transacoes/excluir-lote", json={"ids": ids})
    assert r.status_code == 200, r.text
    assert r.json() == {"excluidas": len(ids)}
    assert api.get("/api/financas/transacoes").json() == []


def test_trilha_de_estudos(api: TestClient) -> None:
    t = api.get("/api/financas/estudo").json()
    assert t["objetivo"]["id"] == "investidor" and t["progresso"]["total"] > 0
    book = next(x for x in t["livros"] if x["id"] == "investidor_inteligente")
    assert book["tenho"] and book["capitulos"][0]["n"] == "1"
    # capítulo lido aparece na etapa que pede esse capítulo
    api.patch(
        "/api/financas/estudo/itens",
        json={"item": "cap:investidor_inteligente:8", "status": "feito"},
    )
    t = api.put("/api/financas/estudo/objetivo", json={"objetivo": "renda"}).json()
    assert t["objetivo"]["id"] == "renda"
    stage = t["niveis"][0]["etapas"][0]
    assert stage["leituras"][0]["lidos"] == 1
    assert (
        api.put("/api/financas/estudo/livros/fisher/tenho", json={"tenho": True}).status_code == 200
    )
    new = api.post("/api/financas/estudo/livros", json={"titulo": "Meu livro"}).json()
    t = api.get("/api/financas/estudo").json()
    have = {x["id"] for x in t["livros"] if x["tenho"]}
    assert {"fisher", new["id"]} <= have
