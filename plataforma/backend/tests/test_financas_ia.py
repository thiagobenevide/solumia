"""Extratos dos bancos, forma de pagamento, parcelamentos e cenários (com IA falsa)."""

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
from financas import cenarios, extrato

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
def test_formatos_dos_bancos(texto: str, fatura: bool, esperado: list[tuple[float, str]]) -> None:
    itens = extrato.ler_csv(texto, fatura=fatura)
    tipo = "cartao" if fatura else "corrente"
    assert [(i["valor"], extrato.forma_pagamento(i["descricao"], tipo)) for i in itens] == esperado


def test_inter_junta_historico_e_descricao() -> None:
    assert extrato.ler_csv(INTER)[0]["descricao"] == "Pix enviado - Padaria Bom Pão"


def test_planilha_xlsx_do_itau() -> None:
    from openpyxl import Workbook

    livro = Workbook()
    folha = livro.active
    folha.append(["Extrato Itaú"])
    folha.append(["data", "lançamento", "ag./origem", "valor (R$)"])
    folha.append([date(2026, 9, 3), "PIX TRANSF JOSE", "", -50.0])
    folha.append([date(2026, 9, 4), "SALARIO", "", 3000.0])
    buf = io.BytesIO()
    livro.save(buf)
    itens = extrato.ler_arquivo("itau.xlsx", buf.getvalue(), "corrente")
    assert [(i["data"], i["valor"]) for i in itens] == [
        ("2026-09-03", -50.0),
        ("2026-09-04", 3000.0),
    ]


def test_formato_desconhecido_vai_para_a_ia() -> None:
    with pytest.raises(extrato.PrecisaIA):
        extrato.ler_arquivo("x.csv", b"coluna;outra\n1;2\n", "corrente")


def test_financiamento_price_e_sac() -> None:
    price = cenarios.financiamento(40000, 0.24, 48, "price")
    assert price["primeira"] == price["ultima"] and 1250 < price["primeira"] < 1300
    sac = cenarios.financiamento(40000, 0.24, 48, "sac")
    assert sac["primeira"] > sac["ultima"] and sac["juros"] < price["juros"]


def test_faixas_mcmv() -> None:
    assert cenarios.faixa_mcmv(2500)["faixa"] == "Faixa 1"
    assert cenarios.faixa_mcmv(9000)["faixa"] == "Faixa 4"
    assert cenarios.faixa_mcmv(20000) is None


async def _llm_falso(mensagens: list[dict[str, str]]) -> str:
    sistema = mensagens[0]["content"]
    if "parâmetros de simulação" in sistema:
        return (
            '<think>…</think>{"descricao": "EcoSport 2015", "tipo": "carro", "valor": 45000, '
            '"marca": "Ford", "modelo": "EcoSport", "ano": 2015}'
        )
    if "planejador financeiro" in sistema:
        return "Em 11 meses você junta. Financiar custa juros."
    if "classifica lançamentos" in sistema:
        pedido = json.loads(mensagens[1]["content"])
        gasto = next(c["cat"] for c in pedido["categorias"] if c["nome"] == "Restaurantes")
        renda = next(c["cat"] for c in pedido["categorias"] if c["tipo"] == "receita")
        return json.dumps(
            {
                "itens": [
                    {
                        "n": t["n"],
                        "cat": renda if t["sentido"] == "entrada" else gasto,
                        "forma": "debito",
                    }
                    for t in pedido["lancamentos"]
                ]
            }
        )
    return json.dumps(
        {"lancamentos": [{"data": "2026-09-20", "descricao": "Compra X", "valor": -10}]}
    )


class _InternetFalsa:
    """Sem rede nos testes: CDI fixo de 12% a.a. e FIPE do EcoSport."""

    async def usar(self, nome: str, args: dict) -> dict:
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
    app.state.financas_llms = {"local": _llm_falso}
    app.state.internet = _InternetFalsa()
    return TestClient(app, headers=AUTH_HEADERS)


def _esperar(api: TestClient, tid: str) -> dict:
    for _ in range(100):
        r = api.get(f"/api/financas/tarefas/{tid}").json()
        if r["estado"] != "rodando":
            return r
        time.sleep(0.02)
    raise AssertionError("tarefa não terminou")


def _salario_e_gastos(api: TestClient, conta: str) -> None:
    hoje = date.today()
    linhas = ["Data;Descrição;Valor"]
    for i in range(1, 7):  # seis meses completos: 6.000 de receita e 4.500 de gasto
        a, m = divmod(hoje.month - 1 - i, 12)
        mes = f"{hoje.year + a}-{m + 1:02d}"
        linhas += [f"{mes}-05;SALARIO;6000,00", f"{mes}-10;MERCADO;-4500,00"]
    r = api.post(
        "/api/financas/importar",
        data={"conta_id": conta},
        files={"arquivo": ("e.csv", "\n".join(linhas).encode())},
    )
    assert r.status_code == 200 and r.json()["importadas"] == 12


def test_importar_guarda_original_no_arquivos_e_pdf_vai_para_ia(api: TestClient) -> None:
    conta = api.post("/api/financas/contas", json={"nome": "Nubank"}).json()["id"]
    r = api.post(
        "/api/financas/importar",
        data={"conta_id": conta},
        files={"arquivo": ("nubank.csv", NUBANK_CONTA.encode())},
    )
    assert r.json()["importadas"] == 2
    arquivos = api.get("/api/arquivos").json()
    assert [(a["nome_original"], a["pasta"], a["tipo"]) for a in arquivos] == [
        ("nubank.csv", "Finanças/Extratos/Nubank", "planilha")
    ]
    # formato que o código não lê: tarefa da IA
    r = api.post(
        "/api/financas/importar",
        data={"conta_id": conta},
        files={"arquivo": ("estranho.csv", b"a;b\n1;2\n")},
    )
    assert r.status_code == 202
    t = _esperar(api, r.json()["tarefa"])
    assert t["estado"] == "pronto" and t["resultado"]["importadas"] == 1


def test_categorizar_com_ia(api: TestClient) -> None:
    conta = api.post("/api/financas/contas", json={"nome": "Inter"}).json()["id"]
    r = api.post(
        "/api/financas/importar",
        data={"conta_id": conta},
        files={"arquivo": ("inter.csv", INTER.encode())},
    ).json()
    assert "ids" not in r
    t = _esperar(api, r["categorizando"])  # a importação já manda para a IA
    assert t["resultado"]["categorizadas"] == 2
    ts = api.get("/api/financas/transacoes").json()
    assert all(x["categoria_id"] for x in ts)
    assert {x["forma_pagamento"] for x in ts} == {"pix", "boleto"}  # a do código não é trocada


def test_extrato_completo_na_conta_do_cartao(api: TestClient) -> None:
    """Extrato do banco digital (Pix, depósito, cartão) importado na conta do cartão: o sinal fica
    e a forma vem do texto, não é tudo `credito`."""
    conta = api.post("/api/financas/contas", json={"nome": "Nu", "tipo": "cartao"}).json()["id"]
    texto = NUBANK_CONTA + (
        "07/09/2026,-50.00,ghi,Compra no débito - Padaria\n"
        "08/09/2026,-80.00,jkl,Uber Trip\n"
        "09/09/2026,300.00,mno,Depósito recebido\n"
    )
    r = api.post(
        "/api/financas/importar",
        data={"conta_id": conta},
        files={"arquivo": ("nu.csv", texto.encode())},
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


def test_corrigir_o_que_a_importacao_antiga_gravou(api: TestClient) -> None:
    """Simula a importação antiga (tudo invertido e `credito` no cartão) e conserta pelo original
    guardado no Arquivos; reimportar o mesmo arquivo depois não duplica."""
    conta = api.post("/api/financas/contas", json={"nome": "Nu", "tipo": "cartao"}).json()["id"]
    api.post(
        "/api/financas/importar",
        data={"conta_id": conta},
        files={"arquivo": ("nu.csv", NUBANK_CONTA.encode())},
    )
    arm = api.app.state.financas
    for t in arm.todos("transacoes"):
        t.update(valor=-t["valor"], forma_pagamento="credito", categoria_id="")
    arm.salvar("transacoes")
    t = _esperar(api, api.post("/api/financas/corrigir").json()["tarefa"])
    assert t["estado"] == "pronto", t
    assert (t["resultado"]["sinais"], t["resultado"]["formas"]) == (2, 2)
    ts = api.get("/api/financas/transacoes").json()
    pares = sorted((x["valor"], x["forma_pagamento"]) for x in ts)
    assert pares == [(-120.5, "pix"), (5000.0, "pix")]
    assert all(x["categoria_id"] for x in ts)
    r = api.post(
        "/api/financas/importar",
        data={"conta_id": conta},
        files={"arquivo": ("nu.csv", NUBANK_CONTA.encode())},
    ).json()
    assert r["duplicadas"] == 2


def test_parcelamentos(api: TestClient) -> None:
    conta = api.post("/api/financas/contas", json={"nome": "Cartão", "tipo": "cartao"}).json()["id"]
    hoje = date.today()
    linhas = ["date,title,amount"]
    for n in (1, 2, 3):
        a, m = divmod(hoje.month - 1 - (3 - n), 12)
        linhas.append(f"{hoje.year + a}-{m + 1:02d}-12,Notebook Loja - Parcela {n}/10,350.00")
    api.post(
        "/api/financas/importar",
        data={"conta_id": conta},
        files={"arquivo": ("fatura.csv", "\n".join(linhas).encode())},
    )
    [p] = api.get("/api/financas/parcelamentos").json()
    assert (p["pagas"], p["restantes"], p["valor_restante"], p["ativo"]) == (3, 7, 2450.0, True)


def test_ecosport_juntar_ou_financiar(api: TestClient) -> None:
    conta = api.post("/api/financas/contas", json={"nome": "BB", "saldo_inicial": 10000}).json()[
        "id"
    ]
    _salario_e_gastos(api, conta)
    r = api.post("/api/financas/cenarios/simular", json={"valor": 45000, "tipo": "carro"}).json()
    assert r["realidade"]["sobra_media"] == 1500.0
    assert r["realidade"]["reserva"] == 19000.0  # 10.000 + 6 × 1.500
    assert 14 <= r["juntar"]["meses"] <= 18
    assert r["financiar"]["cabe"] is False  # parcela ~R$ 1.400 + custos > sobra de R$ 1.500
    assert r["alertas"]
    # pergunta livre: IA tira os parâmetros, Python simula, IA explica
    t = _esperar(
        api,
        api.post(
            "/api/financas/cenarios/perguntar",
            json={"pergunta": "Quero um EcoSport 2015 de 45 mil"},
        ).json()["tarefa"],
    )
    assert t["estado"] == "pronto"
    assert t["resultado"]["parametros"]["valor"] == 45000
    res = t["resultado"]
    # CDI de hoje vira o rendimento da reserva; a FIPE vai para a análise
    assert res["parametros"]["rendimento_mensal"] == res["dados_atuais"]["rendimento_mensal"]
    assert res["dados_atuais"]["fipe"]["media"] == 53000.0
    assert abs(res["resultado"]["juntar"]["meses"] - r["juntar"]["meses"]) <= 1
    assert "meses" in t["resultado"]["analise"]


def test_conversa_usa_os_dados_e_o_modo_rapido(api: TestClient) -> None:
    conta = api.post("/api/financas/contas", json={"nome": "BB", "saldo_inicial": 10000}).json()[
        "id"
    ]
    _salario_e_gastos(api, conta)
    vistos: list[list[dict[str, str]]] = []

    async def rapido(mensagens: list[dict[str, str]]) -> str:
        vistos.append(mensagens)
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
    sistema = vistos[0][0]["content"]
    assert '"sobra": 1500.0' in sistema and "EcoSport de 45 mil" in sistema
    assert vistos[0][-1] == {"role": "user", "content": "Quanto sobra por mês?"}
    vazia = api.post("/api/financas/cenarios/conversar", json={"mensagens": []})
    assert vazia.status_code == 422
