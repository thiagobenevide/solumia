"""Bank statements, payment method, installments and scenarios (with a fake AI)."""

import io
import json
import time
from datetime import date
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from finance import scenarios, statement

NUBANK_CONTA = (
    "Data,Valor,Identificador,Descrição\n"
    "05/09/2026,5000.00,abc,Transferência recebida pelo Pix - EMPRESA X\n"
    "06/09/2026,-120.50,def,Transferência enviada pelo Pix - Maria Silva\n"
)
NUBANK_CARTAO = (
    "date,title,amount\n2026-09-10,Uber *Trip,25.90\n2026-09-12,Loja ABC - Parcela 2/10,300.00\n"
)
INTER = (
    "Extrato Conta Corrente\nConta ;12345\nPeríodo ;01/09/2026 a 30/09/2026\nSaldo ;1.000,00\n\n"
    "Data Lançamento;Histórico;Descrição;Valor;Saldo\n"
    "10/09/2026;Pix enviado ;Padaria Bom Pão;-15,00;985,00\n"
    "11/09/2026;Pagamento efetuado;Boleto Energia;-230,10;754,90\n"
)
BB = (
    '"Data","Lançamento","Detalhes","N° documento","Valor","Tipo Lançamento"\n'
    '"01/09/2026","Saldo Anterior","","","1000,00",""\n'
    '"02/09/2026","Pix - Recebido","02/09 10:00 JOAO","123","200,00","Entrada"\n'
    '"03/09/2026","Compra com Cartão","03/09 12:00 MERCADO","456","85,40","Saída"\n'
    '"30/09/2026","S A L D O","","","1114,60",""\n'
)
MERCADO_PAGO = (
    "INITIAL_BALANCE;CREDITS;DEBITS;FINAL_BALANCE\n100,00;50,00;-30,00;120,00\n\n"
    "RELEASE_DATE;TRANSACTION_TYPE;REFERENCE_ID;TRANSACTION_NET_AMOUNT;PARTIAL_BALANCE\n"
    "15-09-2026;Pagamento com QR Pix Lanchonete;111;-30,00;70,00\n"
    "16-09-2026;Transferência Pix recebida;222;50,00;120,00\n"
)


@pytest.mark.parametrize(
    ("texto", "fatura", "esperado"),
    [
        (NUBANK_CONTA, False, [(5000.0, "pix"), (-120.5, "pix")]),
        (NUBANK_CARTAO, True, [(-25.9, "credito"), (-300.0, "credito")]),
        (INTER, False, [(-15.0, "pix"), (-230.1, "boleto")]),
        (BB, False, [(200.0, "pix"), (-85.4, "")]),
        (MERCADO_PAGO, False, [(-30.0, "pix"), (50.0, "pix")]),
    ],
)
def test_bank_formats(texto: str, fatura: bool, esperado: list[tuple[float, str]]) -> None:
    items = statement.read_csv(texto, fatura=fatura)
    kind = "cartao" if fatura else "corrente"
    assert [(i["valor"], statement.shape_payment(i["descricao"], kind)) for i in items] == esperado


def test_inter_joins_history_and_description() -> None:
    assert statement.read_csv(INTER)[0]["descricao"] == "Pix enviado - Padaria Bom Pão"


def test_itau_xlsx_spreadsheet() -> None:
    from openpyxl import Workbook

    book = Workbook()
    sheet = book.active
    sheet.append(["Extrato Itaú"])
    sheet.append(["data", "lançamento", "ag./origem", "valor (R$)"])
    sheet.append([date(2026, 9, 3), "PIX TRANSF JOSE", "", -50.0])
    sheet.append([date(2026, 9, 4), "SALARIO", "", 3000.0])
    buf = io.BytesIO()
    book.save(buf)
    items = statement.read_file("itau.xlsx", buf.getvalue(), "corrente")
    assert [(i["data"], i["valor"]) for i in items] == [
        ("2026-09-03", -50.0),
        ("2026-09-04", 3000.0),
    ]


def test_unknown_format_goes_to_ai() -> None:
    with pytest.raises(statement.NeedsAi):
        statement.read_file("x.csv", b"coluna;outra\n1;2\n", "corrente")


def test_price_and_sac_financing() -> None:
    price = scenarios.financing(40000, 0.24, 48, "price")
    assert price["primeira"] == price["ultima"] and 1250 < price["primeira"] < 1300
    sac = scenarios.financing(40000, 0.24, 48, "sac")
    assert sac["primeira"] > sac["ultima"] and sac["juros"] < price["juros"]


def test_mcmv_brackets() -> None:
    assert scenarios.band_mcmv(2500)["faixa"] == "Faixa 1"
    assert scenarios.band_mcmv(9000)["faixa"] == "Faixa 4"
    assert scenarios.band_mcmv(20000) is None


async def _fake_llm(mensagens: list[dict[str, str]]) -> str:
    system = mensagens[0]["content"]
    if "simulation parameters" in system:
        return (
            '<think>…</think>{"descricao": "EcoSport 2015", "tipo": "carro", "valor": 45000, '
            '"marca": "Ford", "modelo": "EcoSport", "ano": 2015}'
        )
    if "financial planner" in system:
        return "Em 11 meses você junta. Financiar custa juros."
    if "classify the bank statement entries" in system:
        request = json.loads(mensagens[1]["content"])
        spent = next(c["cat"] for c in request["categorias"] if c["nome"] == "Restaurantes")
        renda = next(c["cat"] for c in request["categorias"] if c["tipo"] == "receita")
        return json.dumps(
            {
                "itens": [
                    {
                        "n": t["n"],
                        "cat": renda if t["sentido"] == "entrada" else spent,
                        "forma": "debito",
                    }
                    for t in request["lancamentos"]
                ]
            }
        )
    return json.dumps(
        {"lancamentos": [{"data": "2026-09-20", "descricao": "Compra X", "valor": -10}]}
    )


class _InternetFalsa:
    """No network in tests: fixed CDI of 12% p.a. and the EcoSport FIPE."""

    async def use(self, nome: str, args: dict) -> dict:
        if nome == "indicadores":
            return {"indicadores": {"cdi_aa": {"valor": 12.0, "data": "hoje"}}}
        return {"marca": "Ford", "menor": 50000.0, "maior": 56000.0, "media": 53000.0,
                "fonte": "FIPE", "versoes": [{"modelo": "EcoSport", "ano": 2015, "valor": 53000.0,
                                               "referencia": "outubro de 2026"}]}


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(
        client_api_keys=CLIENT_API_KEY,
        financas_dir=str(tmp_path / "f"),
        arquivos_dir=str(tmp_path / "a"),
    )
    app = create_app(settings=s)
    app.state.financas_llms = {"local": _fake_llm}
    app.state.internet = _InternetFalsa()
    return TestClient(app, headers=AUTH_HEADERS)


def _wait(api: TestClient, tid: str) -> dict:
    for _ in range(100):
        r = api.get(f"/api/financas/tarefas/{tid}").json()
        if r["estado"] != "rodando":
            return r
        time.sleep(0.02)
    raise AssertionError("tarefa não terminou")


def _salary_and_expenses(api: TestClient, conta: str) -> None:
    today = date.today()
    lines = ["Data;Descrição;Valor"]
    for i in range(1, 7):  # six full months: 6,000 of income and 4,500 of spending
        a, m = divmod(today.month - 1 - i, 12)
        month = f"{today.year + a}-{m + 1:02d}"
        lines += [f"{month}-05;SALARIO;6000,00", f"{month}-10;MERCADO;-4500,00"]
    r = api.post(
        "/api/financas/importar",
        data={"conta_id": conta},
        files={"arquivo": ("e.csv", "\n".join(lines).encode())},
    )
    assert r.status_code == 200 and r.json()["importadas"] == 12


def test_import_keeps_original_in_files_and_pdf_goes_to_ai(api: TestClient) -> None:
    account = api.post("/api/financas/contas", json={"nome": "Nubank"}).json()["id"]
    r = api.post(
        "/api/financas/importar",
        data={"conta_id": account},
        files={"arquivo": ("nubank.csv", NUBANK_CONTA.encode())},
    )
    assert r.json()["importadas"] == 2
    files = api.get("/api/arquivos").json()
    assert [(a["nome_original"], a["pasta"], a["tipo"]) for a in files] == [
        ("nubank.csv", "Finanças/Extratos/Nubank", "planilha")
    ]
    # a format the code cannot read: AI task
    r = api.post(
        "/api/financas/importar",
        data={"conta_id": account},
        files={"arquivo": ("estranho.csv", b"a;b\n1;2\n")},
    )
    assert r.status_code == 202
    t = _wait(api, r.json()["tarefa"])
    assert t["estado"] == "pronto" and t["resultado"]["importadas"] == 1


def test_categorize_with_ai(api: TestClient) -> None:
    account = api.post("/api/financas/contas", json={"nome": "Inter"}).json()["id"]
    r = api.post(
        "/api/financas/importar",
        data={"conta_id": account},
        files={"arquivo": ("inter.csv", INTER.encode())},
    ).json()
    assert "ids" not in r
    t = _wait(api, r["categorizando"])  # the import already sends it to the AI
    assert t["resultado"]["categorizadas"] == 2
    ts = api.get("/api/financas/transacoes").json()
    assert all(x["categoria_id"] for x in ts)
    assert {x["forma_pagamento"] for x in ts} == {"pix", "boleto"}  # the code's one is not changed


def test_full_statement_on_card_account(api: TestClient) -> None:
    """Digital bank statement (Pix, deposit, card) imported into the card account: the sign stays
    and the method comes from the text, not everything is `credito`."""
    account = api.post("/api/financas/contas", json={"nome": "Nu", "tipo": "cartao"}).json()["id"]
    text = NUBANK_CONTA + (
        "07/09/2026,-50.00,ghi,Compra no débito - Padaria\n"
        "08/09/2026,-80.00,jkl,Uber Trip\n"
        "09/09/2026,300.00,mno,Depósito recebido\n"
    )
    r = api.post(
        "/api/financas/importar",
        data={"conta_id": account},
        files={"arquivo": ("nu.csv", text.encode())},
    )
    assert r.status_code == 200, r.text
    ts = api.get("/api/financas/transacoes").json()
    assert [(x["valor"], x["forma_pagamento"]) for x in ts] == [
        (300.0, "deposito"),
        (-80.0, "credito"),
        (-50.0, "debito"),
        (-120.5, "pix"),
        (5000.0, "pix"),
    ]


def test_fix_what_old_import_stored(api: TestClient) -> None:
    """Simulates the old import (everything flipped and `credito` on the card) and fixes it from
    the original stored in Files; reimporting the same file afterwards does not duplicate."""
    account = api.post("/api/financas/contas", json={"nome": "Nu", "tipo": "cartao"}).json()["id"]
    api.post(
        "/api/financas/importar",
        data={"conta_id": account},
        files={"arquivo": ("nu.csv", NUBANK_CONTA.encode())},
    )
    arm = api.app.state.financas
    for t in arm.todos("transacoes"):
        t.update(valor=-t["valor"], forma_pagamento="credito", categoria_id="")
    arm.salvar("transacoes")
    t = _wait(api, api.post("/api/financas/corrigir").json()["tarefa"])
    assert t["estado"] == "pronto", t
    assert (t["resultado"]["sinais"], t["resultado"]["formas"]) == (2, 2)
    ts = api.get("/api/financas/transacoes").json()
    pairs = sorted((x["valor"], x["forma_pagamento"]) for x in ts)
    assert pairs == [(-120.5, "pix"), (5000.0, "pix")]
    assert all(x["categoria_id"] for x in ts)
    r = api.post(
        "/api/financas/importar",
        data={"conta_id": account},
        files={"arquivo": ("nu.csv", NUBANK_CONTA.encode())},
    ).json()
    assert r["duplicadas"] == 2


def test_installments(api: TestClient) -> None:
    body = {"nome": "Cartão", "tipo": "cartao"}
    account = api.post("/api/financas/contas", json=body).json()["id"]
    today = date.today()
    lines = ["date,title,amount"]
    for n in (1, 2, 3):
        a, m = divmod(today.month - 1 - (3 - n), 12)
        lines.append(f"{today.year + a}-{m + 1:02d}-12,Notebook Loja - Parcela {n}/10,350.00")
    api.post(
        "/api/financas/importar",
        data={"conta_id": account},
        files={"arquivo": ("fatura.csv", "\n".join(lines).encode())},
    )
    [p] = api.get("/api/financas/parcelamentos").json()
    assert (p["pagas"], p["restantes"], p["valor_restante"], p["ativo"]) == (3, 7, 2450.0, True)


def test_ecosport_save_or_finance(api: TestClient) -> None:
    account = api.post("/api/financas/contas", json={"nome": "BB", "saldo_inicial": 10000}).json()[
        "id"
    ]
    _salary_and_expenses(api, account)
    r = api.post("/api/financas/cenarios/simular", json={"valor": 45000, "tipo": "carro"}).json()
    assert r["realidade"]["sobra_media"] == 1500.0
    assert r["realidade"]["reserva"] == 19000.0  # 10.000 + 6 × 1.500
    assert 14 <= r["juntar"]["meses"] <= 18
    assert r["financiar"]["cabe"] is False  # installment ~R$ 1,400 + costs > surplus of R$ 1,500
    assert r["alertas"]
    # free question: the AI extracts the parameters, Python simulates, the AI explains
    t = _wait(
        api,
        api.post(
            "/api/financas/cenarios/perguntar",
            json={"pergunta": "Quero um EcoSport 2015 de 45 mil"},
        ).json()["tarefa"],
    )
    assert t["estado"] == "pronto"
    assert t["resultado"]["parametros"]["valor"] == 45000
    res = t["resultado"]
    # today's CDI becomes the reserve yield; the FIPE goes into the analysis
    assert res["parametros"]["rendimento_mensal"] == res["dados_atuais"]["rendimento_mensal"]
    assert res["dados_atuais"]["fipe"]["media"] == 53000.0
    assert abs(res["resultado"]["juntar"]["meses"] - r["juntar"]["meses"]) <= 1
    assert "meses" in t["resultado"]["analise"]


def test_conversation_uses_data_and_fast_mode(api: TestClient) -> None:
    account = api.post("/api/financas/contas", json={"nome": "BB", "saldo_inicial": 10000}).json()[
        "id"
    ]
    _salary_and_expenses(api, account)
    seen: list[list[dict[str, str]]] = []

    async def rapido(mensagens: list[dict[str, str]]) -> str:
        seen.append(mensagens)
        return "Sobra uns 1.500 por mês."

    api.app.state.financas_llms["local_rapido"] = rapido
    assert "local_rapido" not in api.get("/api/financas/ia/provedores").json()
    r = api.post(
        "/api/financas/cenarios/conversar",
        json={
            "mensagens": [{"role": "user", "content": "Quanto sobra por mês?"}],
            "cenario": {"pergunta": "EcoSport de 45 mil", "analise": "Leva 15 meses."},
        },
    )
    assert r.json() == {"resposta": "Sobra uns 1.500 por mês."}
    system = seen[0][0]["content"]
    assert '"sobra": 1500.0' in system and "EcoSport de 45 mil" in system
    assert seen[0][-1] == {"role": "user", "content": "Quanto sobra por mês?"}
    empty = api.post("/api/financas/cenarios/conversar", json={"mensagens": []})
    assert empty.status_code == 422
