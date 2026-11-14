"""Mercado e dados oficiais: ações (CVM: cadastro, DRE, links) e FIIs (informe mensal), sem rede."""

import csv
import io
import time
import zipfile
from datetime import date
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from financas.cvm import CVM, fii, ticker_of_isin

ANO = date.today().year


def _csv(cab: list[str], linhas: list[list[str]]) -> bytes:
    buf = io.StringIO()
    w = csv.writer(buf, delimiter=";")
    w.writerow(cab)
    w.writerows(linhas)
    return buf.getvalue().encode("latin-1")


def _zip(destino: Path, arquivos: dict[str, bytes]) -> None:
    with zipfile.ZipFile(destino, "w") as z:
        for name, content in arquivos.items():
            z.writestr(name, content)


DEM = [
    "CNPJ_CIA",
    "DT_REFER",
    "VERSAO",
    "DENOM_CIA",
    "CD_CVM",
    "GRUPO_DFP",
    "MOEDA",
    "ESCALA_MOEDA",
    "ORDEM_EXERC",
    "DT_INI_EXERC",
    "DT_FIM_EXERC",
    "CD_CONTA",
    "DS_CONTA",
    "VL_CONTA",
    "ST_CONTA_FIXA",
]


def _contas(ano: int, ordem: str, contas: list[tuple[str, str, float]]) -> list[list[str]]:
    return [
        [
            "11.111.111/0001-11",
            f"{ano}-12-31",
            "1",
            "EMPRESA X",
            "009999",
            "g",
            "REAL",
            "MIL",
            ordem,
            f"{ano}-01-01",
            f"{ano}-12-31",
            c,
            d,
            str(v),
            "S",
        ]
        for c, d, v in contas
    ]


@pytest.fixture
def pasta(tmp_path: Path) -> Path:
    cvm = tmp_path / "cvm"
    cvm.mkdir()
    for a in range(ANO - 6, ANO + 1):  # todos os anos que a rota pode pedir: nada vai para a rede
        dre = _contas(a, "ÚLTIMO", [("3.01", "Receita", 1000.0 + a), ("3.11", "Lucro", 100.0)])
        bpp = _contas(
            a,
            "ÚLTIMO",
            [
                ("2.03", "PL", 500.0),
                ("2.01.04", "Emprést CP", 50.0),
                ("2.02.01", "Emprést LP", 150.0),
            ],
        )
        dfc = _contas(
            a,
            "ÚLTIMO",
            [
                ("6.01", "FCO", 300.0),
                ("6.02.01", "Aquisição de imobilizado", -80.0),
                ("6.03.02", "Dividendos pagos", -40.0),
            ],
        )
        idx = _csv(
            [
                "CNPJ_CIA",
                "DT_REFER",
                "VERSAO",
                "DENOM_CIA",
                "CD_CVM",
                "CATEG_DOC",
                "ID_DOC",
                "DT_RECEB",
                "LINK_DOC",
            ],
            [
                [
                    "11.111.111/0001-11",
                    f"{a}-12-31",
                    "1",
                    "EMPRESA X",
                    "009999",
                    "DFP",
                    "1",
                    f"{a + 1}-03-01",
                    f"http://www.rad.cvm.gov.br/dfp{a}",
                ]
            ],
        )
        _zip(
            cvm / f"dfp_cia_aberta_{a}.zip",
            {
                f"dfp_cia_aberta_{a}.csv": idx,
                f"dfp_cia_aberta_DRE_con_{a}.csv": _csv(DEM, dre),
                f"dfp_cia_aberta_BPA_con_{a}.csv": _csv(DEM, []),
                f"dfp_cia_aberta_BPP_con_{a}.csv": _csv(DEM, bpp),
                f"dfp_cia_aberta_DFC_MI_con_{a}.csv": _csv(DEM, dfc),
            },
        )
        _zip(cvm / f"itr_cia_aberta_{a}.zip", {f"itr_cia_aberta_{a}.csv": idx})
        _zip(
            cvm / f"ipe_cia_aberta_{a}.zip",
            {
                f"ipe_cia_aberta_{a}.csv": _csv(
                    [
                        "CNPJ_Companhia",
                        "Nome_Companhia",
                        "Codigo_CVM",
                        "Data_Referencia",
                        "Categoria",
                        "Tipo",
                        "Especie",
                        "Assunto",
                        "Data_Entrega",
                        "Tipo_Apresentacao",
                        "Protocolo_Entrega",
                        "Versao",
                        "Link_Download",
                    ],
                    [
                        [
                            "11.111.111/0001-11",
                            "EMPRESA X",
                            "9999",
                            f"{a}-08-01",
                            "Dados Econômico-Financeiros",
                            "Release",
                            "",
                            f"Resultado 2T{a % 100}",
                            f"{a}-08-05",
                            "",
                            "",
                            "1",
                            f"https://www.rad.cvm.gov.br/ipe{a}",
                        ]
                    ],
                )
            },
        )
        _zip(
            cvm / f"inf_mensal_fii_{a}.zip",
            {
                f"inf_mensal_fii_geral_{a}.csv": _csv(
                    [
                        "CNPJ_Fundo_Classe",
                        "Data_Referencia",
                        "Codigo_ISIN",
                        "Nome_Fundo_Classe",
                        "Segmento_Atuacao",
                        "Mandato",
                        "Tipo_Gestao",
                        "Nome_Administrador",
                        "Site",
                        "Data_Funcionamento",
                    ],
                    [
                        [
                            "22.222.222/0001-22",
                            f"{a}-09-01",
                            "BRFUNDCTF001",
                            "FII FUNDO",
                            "Logística",
                            "Renda",
                            "Ativa",
                            "ADM",
                            "www.adm.com",
                            "2015-01-01",
                        ]
                    ],
                ),
                f"inf_mensal_fii_complemento_{a}.csv": _csv(
                    [
                        "CNPJ_Fundo_Classe",
                        "Data_Referencia",
                        "Patrimonio_Liquido",
                        "Cotas_Emitidas",
                        "Valor_Patrimonial_Cotas",
                        "Percentual_Dividend_Yield_Mes",
                        "Percentual_Rentabilidade_Efetiva_Mes",
                        "Total_Numero_Cotistas",
                        "Percentual_Despesas_Taxa_Administracao",
                    ],
                    [
                        [
                            "22.222.222/0001-22",
                            f"{a}-{m:02d}-01",
                            "1000000",
                            "100000",
                            "10.0",
                            "0.0085",
                            "0.01",
                            "5000",
                            "0.001",
                        ]
                        for m in range(1, 10)
                    ],
                ),
                f"inf_mensal_fii_ativo_passivo_{a}.csv": _csv(
                    [
                        "CNPJ_Fundo_Classe",
                        "Data_Referencia",
                        "Imoveis_Renda_Acabados",
                        "CRI",
                        "Disponibilidades",
                    ],
                    [["22.222.222/0001-22", f"{a}-09-01", "700000", "250000", "50000"]],
                ),
            },
        )
    _zip(
        cvm / f"fca_cia_aberta_{ANO}.zip",
        {
            f"fca_cia_aberta_valor_mobiliario_{ANO}.csv": _csv(
                ["CNPJ_Companhia", "Codigo_Negociacao", "Data_Fim_Negociacao"],
                [["11.111.111/0001-11", "EMPX3", ""], ["11.111.111/0001-11", "EMPX4", ""]],
            ),
            f"fca_cia_aberta_geral_{ANO}.csv": _csv(
                [
                    "CNPJ_Companhia",
                    "Nome_Empresarial",
                    "Codigo_CVM",
                    "Setor_Atividade",
                    "Descricao_Atividade",
                    "Pagina_Web",
                    "Situacao_Registro_CVM",
                ],
                [
                    [
                        "11.111.111/0001-11",
                        "EMPRESA X S.A.",
                        "009999",
                        "Energia",
                        "Geração",
                        "ri.x.com",
                        "Ativo",
                    ]
                ],
            ),
        },
    )
    return tmp_path


def test_isin_do_fii() -> None:
    assert ticker_of_isin("BRMXRFCTF008") == "MXRF11"
    assert ticker_of_isin("BRPETRACNPR6") == ""


def test_empresa_demonstrativos_e_links(pasta: Path) -> None:
    c = CVM(pasta)
    [e] = c.fetch("EMPX4")
    assert (e["codigo_cvm"], e["tickers"]) == (9999, ["EMPX3", "EMPX4"])
    years = c.statements(9999)
    last = years[-1]
    assert last["receita_liquida"] == 1000.0 + last["ano"]
    assert (last["divida_bruta"], last["capex"], last["dividendos"]) == (200.0, 80.0, 40.0)
    docs = c.documentos(9999, "EMPX4")
    assert docs["anuais_dfp"] and docs["releases_e_comunicados"][0]["assunto"].startswith(
        "Resultado"
    )
    assert "codigoCVM=9999" in docs["paginas"]["cvm_rad"]


def test_sugerir_enquanto_digita(pasta: Path) -> None:
    c = CVM(pasta)
    # ticker pelo começo, palavra do nome, nome parecido e FII juntos
    assert c.suggest("EMP")[0]["tickers"] == ["EMPX3", "EMPX4"]
    assert c.suggest("empresa")[0]["nome"] == "EMPRESA X S.A."
    assert c.suggest("emprsa x")[0]["tickers"] == ["EMPX3", "EMPX4"]
    assert c.suggest("FUND")[0] | {"tipo": "fii"} == c.suggest("FUND")[0]
    assert c.suggest("zzzz") == []


def test_fii(pasta: Path) -> None:
    f = fii(CVM(pasta), "FUND11")
    assert f["segmento"] == "Logística" and len(f["meses"]) == 12
    assert f["meses"][-1]["dy_mes_pct"] == 0.85  # fração da CVM vira %
    assert [x["item"] for x in f["composicao"]] == ["imóveis prontos para renda", "CRI", "caixa"]
    assert "cnpjFundo=22222222000122" in f["links"]["relatorios_fnet"]


class _InternetFalsa:
    async def use(self, nome: str, args: dict) -> dict:
        if nome == "mercado":
            return {"altas": [{"ticker": "EMPX4", "variacao_pct": 3.2}], "baixas": []}
        if nome == "noticias":
            return {"tema": args["tema"], "noticias": [{"titulo": "Ibovespa sobe"}]}
        if nome == "acoes":
            return {"cotacoes": {t: {"preco": 12.0, "variacao_pct": 1.0} for t in args["tickers"]}}
        return {"total_12m": 1.2, "dy_12m_pct": 10.0}


@pytest.fixture
def api(pasta: Path):
    s = Settings(client_api_keys=CLIENT_API_KEY, financas_dir=str(pasta))
    app = create_app(settings=s)
    app.state.internet = _InternetFalsa()
    # `with`: o loop do app fica vivo entre os pedidos e as tarefas em segundo plano terminam
    with TestClient(app, headers=AUTH_HEADERS) as c:
        yield c


def _esperar(api: TestClient, tid: str) -> dict:
    for _ in range(200):
        r = api.get(f"/api/financas/tarefas/{tid}").json()
        if r["estado"] != "rodando":
            return r
        time.sleep(0.02)
    raise AssertionError("tarefa não terminou")


def test_rotas_mercado(api: TestClient) -> None:
    assert api.get("/api/financas/mercado/destaques").json()["altas"][0]["ticker"] == "EMPX4"
    assert api.get("/api/financas/mercado/noticias?tema=fiis").json()["tema"] == "fiis"
    action = _esperar(
        api, api.post("/api/financas/mercado/ativo", json={"q": "empx4"}).json()["tarefa"]
    )
    assert action["estado"] == "pronto", action
    r = action["resultado"]
    assert (r["tipo"], r["ticker"], r["cotacao"]["preco"]) == ("acao", "EMPX4", 12.0)
    assert r["demonstrativos"] and r["documentos"]["releases_e_comunicados"]
    background = _esperar(
        api, api.post("/api/financas/mercado/ativo", json={"q": "FUND11"}).json()["tarefa"]
    )
    assert background["resultado"]["tipo"] == "fii" and background["resultado"]["p_vp"] == 1.2
    # importar a DRE da CVM para a empresa cadastrada
    emp = api.post("/api/financas/empresas", json={"ticker": "EMPX4"}).json()
    t = _esperar(api, api.post(f"/api/financas/empresas/{emp['id']}/importar-cvm").json()["tarefa"])
    assert t["estado"] == "pronto" and t["resultado"]["empresa"]["nome"] == "EMPRESA X S.A."
    assert len(t["resultado"]["empresa"]["demonstrativos"]) >= 5
    assert (
        api.post("/api/financas/mercado/guardar", json={"url": "https://x.com/a"}).status_code
        == 422
    )


def test_pdf_de_dentro_do_pacote_e_link_https() -> None:
    from financas.api import link_safe, pdf_of_document

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("009512DFP.xml", "<x/>")
        z.writestr("pequeno.pdf", b"%PDF-1.4 pequeno")
        z.writestr("155122_009512.pdf", b"%PDF-1.4 " + b"x" * 5000)
    assert pdf_of_document(buf.getvalue()).startswith(b"%PDF-1.4 xxx")  # o maior PDF do pacote
    assert pdf_of_document(b"%PDF-1.6 release") == b"%PDF-1.6 release"
    assert pdf_of_document(b"<html>") is None
    assert (
        link_safe("http://www.rad.cvm.gov.br/ENETCONSULTA/x")
        == "https://www.rad.cvm.gov.br/ENETCONSULTA/x"
    )


def test_noticias_do_rss() -> None:
    import asyncio

    import httpx

    from backend.internet.tools import news

    rss = """<rss><channel>
    <item><title>Selic fica em 10% - Valor</title><link>https://a/1</link>
      <pubDate>Wed, 28 Oct 2026 10:00:00 GMT</pubDate><source>Valor</source></item>
    <item><title>IFIX bate recorde - InfoMoney</title><link>https://a/2</link>
      <pubDate>Wed, 28 Oct 2026 12:00:00 GMT</pubDate><source>InfoMoney</source></item>
    <item><title>Selic fica em 10% - G1</title><link>https://a/3</link><source>G1</source></item>
    </channel></rss>"""

    async def rodar() -> dict:
        t = httpx.MockTransport(lambda r: httpx.Response(200, text=rss))
        async with httpx.AsyncClient(transport=t) as c:
            return await news(c, "fiis")

    d = asyncio.run(rodar())
    assert [n["titulo"] for n in d["noticias"]] == ["IFIX bate recorde", "Selic fica em 10%"]
    assert d["noticias"][0]["fonte"] == "InfoMoney"


def test_moedas_cai_para_o_yahoo_quando_a_awesomeapi_recusa() -> None:
    import asyncio

    import httpx

    from backend.internet.tools import currencies

    def responder(r: httpx.Request) -> httpx.Response:
        if "awesomeapi" in r.url.host:
            return httpx.Response(429)  # a AwesomeAPI recusa o IP da VPS
        assert r.url.path.endswith("/USDBRL=X")
        meta = {"regularMarketPrice": 5.59, "chartPreviousClose": 5.5, "currency": "BRL"}
        return httpx.Response(200, json={"chart": {"result": [{"meta": meta}]}})

    async def rodar() -> dict:
        async with httpx.AsyncClient(transport=httpx.MockTransport(responder)) as c:
            return await currencies(c, ["USD-BRL"])

    d = asyncio.run(rodar())
    assert d["fonte"] == "Yahoo Finance" and d["cotacoes"]["USD-BRL"]["venda"] == 5.59
