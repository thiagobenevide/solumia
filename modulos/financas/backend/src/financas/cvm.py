"""Dados oficiais das companhias abertas (Portal de Dados Abertos da CVM, sem chave): cadastro e
tickers (FCA), demonstrativos anuais (DFP: DRE, balanço, fluxo de caixa), trimestrais (ITR) e
documentos entregues (IPE: releases de resultado, apresentações, fatos relevantes), com o link de
cada documento para abrir ou baixar no RAD da CVM.

Os ZIPs (DFP ~13 MB/ano, ITR ~20 MB, FCA e IPE < 2 MB) ficam em cache em `<dados>/cvm/`: anos
fechados não mudam; o ano corrente é baixado de novo depois de [VALIDADE_DIAS].
"""

import csv
import difflib
import io
import itertools
import math
import re
import threading
import time
import unicodedata
import urllib.request
import zipfile
from datetime import date
from pathlib import Path
from typing import Any

BASE = "https://dados.cvm.gov.br/dados/CIA_ABERTA/DOC"
VALIDITY_DAYS = 3
YEARS_DFP = 5  # cada DFP traz o ano e o anterior: 5 arquivos = 6 anos

# Contas da DRE pela descrição (nível 2, `3.xx`): o código muda de plano para plano (bancos têm
# 3.09 como lucro; empresas comuns, 3.11), a descrição não. A ordem importa: a primeira que bate.
DRE_DESCRIPTION = (
    ("resultado antes do resultado financeiro", "ebit"),
    ("resultado antes dos tributos", "lucro_antes_ir"),
    ("resultado bruto", "lucro_bruto"),
    ("imposto de renda", "ir_csll"),
    ("resultado financeiro", "resultado_financeiro"),
    ("custo", "custo"),
    ("despesas da intermediacao", "custo"),
    ("despesas/receitas operacionais", "despesas_operacionais"),
)

# Nomes populares que não aparecem no nome empresarial da CVM (busca do app).
NICKNAMES = {
    "itau": "ITUB4",
    "magalu": "MGLU3",
    "magazine luiza": "MGLU3",
    "sabesp": "SBSP3",
    "eletrobras": "ELET3",
    "axia": "ELET3",
    "banco do brasil": "BBAS3",
    "bb": "BBAS3",
    "caixa seguridade": "CXSE3",
    "raia": "RADL3",
    "drogasil": "RADL3",
    "renner": "LREN3",
    "pao de acucar": "PCAR3",
    "assai": "ASAI3",
    "btg": "BPAC11",
    "xp": "XPBR31",
    "nubank": "ROXO34",
    "inter": "INBR32",
    "embraer": "EMBJ3",
    "taesa": "TAEE11",
    "klabin": "KLBN11",
    "suzano": "SUZB3",
    "ambev": "ABEV3",
    "copel": "CPLE6",
    "cemig": "CMIG4",
    "petrobras": "PETR4",
    "vale": "VALE3",
    "weg": "WEGE3",
    "bradesco": "BBDC4",
    "santander": "SANB11",
    "gerdau": "GGBR4",
    "localiza": "RENT3",
    "rumo": "RAIL3",
    "hapvida": "HAPV3",
    "natura": "NTCO3",
    "tim": "TIMS3",
    "vivo": "VIVT3",
}

# Palavras que não ajudam a distinguir nomes na busca aproximada.
_EMPTY = {
    "s.a.",
    "s.a",
    "sa",
    "s/a",
    "cia",
    "companhia",
    "de",
    "do",
    "da",
    "dos",
    "das",
    "e",
    "-",
    "fundo",
    "investimento",
    "imobiliario",
    "fii",
    "responsabilidade",
    "limitada",
    "holding",
}

CATEGORIES_IPE = ("Dados Econômico-Financeiros", "Fato Relevante", "Comunicado ao Mercado")


class ErrorCVM(RuntimeError):
    pass


# Resultados por empresa/fundo em memória: os arquivos mudam no máximo uma vez por dia e reler os
# CSVs (centenas de MB descompactados) a cada clique é o que deixava a ficha lenta.
_MEMO: dict[tuple[Any, ...], tuple[float, Any]] = {}
MEMO_SECONDS = 6 * 3600
# Uma trava por arquivo: duas consultas ao mesmo tempo não baixam o mesmo ZIP duas vezes.
_LOCKS: dict[str, threading.Lock] = {}
_LOCK = threading.Lock()


def _memo(chave: tuple[Any, ...], calcular: Any) -> Any:
    stored = _MEMO.get(chave)
    if stored and time.time() - stored[0] < MEMO_SECONDS:
        return stored[1]
    value = calcular()
    if len(_MEMO) >= 500:
        _MEMO.pop(next(iter(_MEMO)))
    _MEMO[chave] = (time.time(), value)
    return value


def _https(url: str) -> str:
    """A CVM publica os links em http://, que ela mesma recusa (e o Android bloqueia)."""
    return "https://" + url.split("://", 1)[1] if url.startswith("http://") else url


def _norm(t: str) -> str:
    return unicodedata.normalize("NFKD", t).encode("ascii", "ignore").decode().lower().strip()


def _cd(v: str) -> int:
    try:
        return int(v)
    except ValueError:
        return -1


class CVM:
    def __init__(self, pasta: Path) -> None:
        self.pasta = Path(pasta) / "cvm"
        self.pasta.mkdir(parents=True, exist_ok=True)

    # ---------- arquivos ----------

    def _zip(self, doc: str, year: int) -> zipfile.ZipFile:
        if doc == "FII_INF_MENSAL":
            name, path = (
                f"inf_mensal_fii_{year}.zip",
                "https://dados.cvm.gov.br/dados/FII/DOC/INF_MENSAL/DADOS",
            )
        else:
            name, path = f"{doc.lower()}_cia_aberta_{year}.zip", f"{BASE}/{doc}/DADOS"
        destination = self.pasta / name
        with _LOCK:
            lock = _LOCKS.setdefault(name, threading.Lock())
        with lock:
            return self._zip_baixado(doc, year, name, path, destination)

    def _zip_baixado(
        self, doc: str, year: int, nome: str, caminho: str, destination: Path
    ) -> zipfile.ZipFile:
        velho = (
            destination.exists()
            and year >= date.today().year - (1 if doc in ("DFP",) else 0)
            and (time.time() - destination.stat().st_mtime > VALIDITY_DAYS * 86400)
        )
        if not destination.exists() or velho:
            url = f"{caminho}/{nome}"
            try:
                with urllib.request.urlopen(
                    urllib.request.Request(url, headers={"User-Agent": "agent"}), timeout=120
                ) as r:
                    data = r.read()
            except OSError as e:
                if destination.exists():
                    return zipfile.ZipFile(destination)  # sem rede: usa o que tem
                raise ErrorCVM(f"Não baixei {nome} da CVM ({e}).") from e
            tmp = destination.with_suffix(".tmp")
            tmp.write_bytes(data)
            tmp.replace(destination)
        return zipfile.ZipFile(destination)

    @staticmethod
    def _lines(zf: zipfile.ZipFile, part: str, criteria: str = "") -> Any:
        """Linhas do CSV [parte]; com [filtro], só as que contêm o texto (descarta em bytes, antes
        do CSV, o que é muitas vezes mais rápido; quem chama ainda confere o campo exato). Não
        usar filtro em arquivo com texto livre de várias linhas (IPE)."""
        name = next((n for n in zf.namelist() if part in n), None)
        if name is None:
            return iter(())
        if not criteria:
            text = io.TextIOWrapper(zf.open(name), encoding="latin-1")
            return csv.DictReader(text, delimiter=";")
        raw, target = zf.open(name), criteria.encode("latin-1")
        lines = itertools.chain([raw.readline()], (x for x in raw if target in x))
        return csv.DictReader((x.decode("latin-1") for x in lines), delimiter=";")

    def _year_existente(self, doc: str, year: int) -> int:
        """O ano mais recente que a CVM já publicou para [doc] (o ano corrente pode não existir)."""
        for a in (year, year - 1):
            try:
                self._zip(doc, a)
                return a
            except ErrorCVM:
                continue
        raise ErrorCVM(f"CVM sem {doc} de {year - 1} nem {year}.")

    def aquecer(self) -> None:
        """Deixa baixados e em dia os ZIPs da ficha (o download é a parte lenta do clique)."""
        today = date.today().year
        for doc, year in (("FCA", today), ("ITR", today), ("IPE", today), ("FII_INF_MENSAL", today)):
            try:
                self._year_existente(doc, year)
            except ErrorCVM:
                continue
        try:
            last = self._year_existente("DFP", today - 1)
            for a in range(last - YEARS_DFP + 1, last):
                self._zip("DFP", a)
        except ErrorCVM:
            pass
        self.indice()

    # ---------- empresa ----------

    # ---------- índice e busca ----------

    def indice(self) -> list[dict[str, Any]]:
        """Todas as companhias com ticker (FCA) e todos os FIIs (informe mensal), para a busca
        enquanto digita. Fica em memória: montar lê dois CSVs inteiros."""
        return _memo(("indice", str(self.pasta)), self._index)

    def _index(self) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        try:
            zf = self._zip("FCA", self._year_existente("FCA", date.today().year))
            tickers: dict[str, set[str]] = {}
            for r in self._lines(zf, "valor_mobiliario"):
                cod = r["Codigo_Negociacao"].upper().strip()
                # só ações, units e BDRs negociados hoje (debêntures têm código de 6+ dígitos)
                if (
                    cod
                    and not r.get("Data_Fim_Negociacao")
                    and re.fullmatch(r"[A-Z0-9]{4}\d{1,2}", cod)
                ):
                    tickers.setdefault(r["CNPJ_Companhia"], set()).add(cod)
            for r in self._lines(zf, "geral"):
                ts = sorted(tickers.get(r["CNPJ_Companhia"], ()))
                if not ts:
                    continue
                items.append(
                    {
                        "tipo": "acao",
                        "nome": r["Nome_Empresarial"],
                        "anterior": r.get("Nome_Empresarial_Anterior") or "",
                        "cnpj": r["CNPJ_Companhia"],
                        "codigo_cvm": _cd(r["Codigo_CVM"]),
                        "setor": r["Setor_Atividade"],
                        "atividade": r["Descricao_Atividade"],
                        "site": r["Pagina_Web"],
                        "situacao": r["Situacao_Registro_CVM"],
                        "tickers": ts,
                    }
                )
        except ErrorCVM:
            pass
        fiis: dict[str, dict[str, Any]] = {}
        for a in (date.today().year, date.today().year - 1):
            try:
                zf = self._zip("FII_INF_MENSAL", a)
            except ErrorCVM:
                continue
            for r in self._lines(zf, "geral"):
                t = ticker_of_isin(r["Codigo_ISIN"])
                if t and (t not in fiis or r["Data_Referencia"] > fiis[t]["_ref"]):
                    fiis[t] = {
                        "tipo": "fii",
                        "nome": r["Nome_Fundo_Classe"],
                        "anterior": "",
                        "cnpj": r["CNPJ_Fundo_Classe"],
                        "setor": r["Segmento_Atuacao"],
                        "atividade": r["Mandato"],
                        "situacao": "Ativo",
                        "tickers": [t],
                        "_ref": r["Data_Referencia"],
                    }
            if fiis:
                break
        for f in fiis.values():
            f.pop("_ref")
            items.append(f)
        for x in items:
            x["_nome"] = _norm(f"{x['nome']} {x['anterior']}")
            x["_palavras"] = _words(x["nome"])
            x["_anteriores"] = _words(x["anterior"])
        return items

    def suggest(self, query: str, limite: int = 12) -> list[dict[str, Any]]:
        """Busca enquanto digita: ticker pelo começo (ITU → ITUB3, ITUB4), nome popular (Itaú,
        Magalu), palavra do nome pelo começo ou no meio e, por último, nome parecido (erro de
        digitação). Ações e FIIs juntos, os mais prováveis primeiro."""
        target = _norm(query)
        if not target:
            return []
        compact = re.sub(r"[^a-z0-9]", "", target).upper()
        nicknames = {t for name, t in NICKNAMES.items() if name.startswith(target) and len(target) >= 2}
        terms = [p for p in target.split() if p not in _EMPTY] or [target]
        found = []
        for x in self.indice():
            points = 0.0
            if compact in x["tickers"]:
                points = 100
            elif len(compact) >= 2 and any(t.startswith(compact) for t in x["tickers"]):
                points = 90
            elif nicknames & set(x["tickers"]):
                points = 85
            elif all(any(p.startswith(t) for p in x["_palavras"]) for t in terms):
                points = 75
            elif all(any(p.startswith(t) for p in x["_anteriores"]) for t in terms):
                points = 65  # nome antigo (Petrobras Distribuidora → Vibra)
            elif len(target) >= 3 and target in x["_nome"]:
                points = 60
            elif len(target) >= 3:
                # parecido: "itu" ~ "itau", "petrobas" ~ "petrobras"
                best = max(
                    (
                        difflib.SequenceMatcher(None, terms[0], p[: len(terms[0]) + 1]).ratio()
                        for p in x["_palavras"][:6] + [t.lower() for t in x["tickers"]]
                    ),
                    default=0,
                )
                if best >= 0.75:
                    points = 30 + 20 * best
            if points:
                points += 3 if x["situacao"] == "Ativo" else 0
                found.append((points, x))
        found.sort(key=lambda p: (-p[0], len(p[1]["nome"])))
        return [{k: v for k, v in x.items() if not k.startswith("_")} for _, x in found[:limite]]

    def fetch(self, query: str) -> list[dict[str, Any]]:
        """Companhias (só ações) por ticker, nome ou apelido, com CNPJ, código CVM, setor, site de
        RI e todos os tickers; a mais provável primeiro."""
        return [x for x in self.suggest(query, 20) if x["tipo"] == "acao"][:10]

    # ---------- demonstrativos ----------

    def statements(
        self, code_cvm: int, years: int = YEARS_DFP, ao_ano: Any = None
    ) -> list[dict[str, Any]]:
        """Anos fechados no formato de `analise.CONTAS` (R$ mil; `acoes` em mil), do
        consolidado. [ao_ano] recebe a lista parcial a cada arquivo lido, do mais novo para o mais
        antigo, para a ficha ir aparecendo."""
        return _memo(
            ("demonstrativos", str(self.pasta), code_cvm, years),
            lambda: self._statements(code_cvm, years, ao_ano),
        )

    def _statements(
        self, code_cvm: int, years: int, ao_ano: Any = None
    ) -> list[dict[str, Any]]:
        last = self._year_existente("DFP", date.today().year - 1)
        by_year: dict[int, dict[str, Any]] = {}
        cnpj = ""
        for year_file in range(last, last - years, -1):
            try:
                zf = self._zip("DFP", year_file)
            except ErrorCVM:
                continue
            for part in ("DRE_con", "BPA_con", "BPP_con", "DFC_MI_con", "DFC_MD_con"):
                for r in self._lines(zf, part, str(code_cvm)):
                    if _cd(r["CD_CVM"]) != code_cvm:
                        continue
                    cnpj = cnpj or r["CNPJ_CIA"]
                    year = int(r["DT_FIM_EXERC"][:4])
                    # cada ano vem do próprio arquivo; o "penúltimo" só serve ao ano mais antigo
                    if r["ORDEM_EXERC"] != "ÚLTIMO" and year > last - years:
                        continue
                    line = by_year.setdefault(year, {"ano": year})
                    scale = 1000 if r["ESCALA_MOEDA"].upper() == "UNIDADE" else 1
                    value = float(r["VL_CONTA"]) / scale
                    account, desc = r["CD_CONTA"], _norm(r["DS_CONTA"])
                    for key in _accounts(part, account, desc):
                        if key == "_divida":
                            line.setdefault("_divida", {})[account] = value
                        elif key == "_lpa":
                            if float(r["VL_CONTA"]):
                                line.setdefault("_lpa", float(r["VL_CONTA"]))
                        else:
                            line.setdefault(key, value)
                    if part.startswith("DFC"):
                        _flow(line, account, desc, value)
            if cnpj:
                for r in self._lines(zf, "composicao_capital", cnpj):
                    if r["CNPJ_CIA"] == cnpj and int(r["DT_REFER"][:4]) in by_year:
                        q = _num(r["QT_ACAO_TOTAL_CAP_INTEGR"]) or 0
                        q -= _num(r["QT_ACAO_TOTAL_TESOURO"]) or 0
                        by_year[int(r["DT_REFER"][:4])]["_qt"] = q
            if ao_ano is not None:
                ao_ano(_close(by_year))
        return _close(by_year)[-6:]

    # ---------- documentos e links ----------

    def documentos(self, code_cvm: int, ticker: str = "") -> dict[str, Any]:
        """Links para abrir/baixar: DFPs (anuais), ITRs (trimestrais), releases e apresentações de
        resultado, fatos relevantes; mais as páginas da empresa na CVM, B3 e Status Invest."""
        return _memo(
            ("documentos", str(self.pasta), code_cvm, ticker.upper()),
            lambda: self._documentos(code_cvm, ticker),
        )

    def _documentos(self, code_cvm: int, ticker: str) -> dict[str, Any]:
        today = date.today().year
        dfp, itr, ipe = [], [], []
        try:
            last = self._year_existente("DFP", today - 1)
            for a in range(last - YEARS_DFP + 1, last + 1):
                for r in self._lines(
                    self._zip("DFP", a), f"dfp_cia_aberta_{a}.csv", str(code_cvm)
                ):
                    if _cd(r["CD_CVM"]) == code_cvm:
                        dfp.append(
                            {
                                "referencia": r["DT_REFER"],
                                "entregue": r["DT_RECEB"],
                                "link": _https(r["LINK_DOC"]),
                            }
                        )
        except ErrorCVM:
            pass
        for a in (today, today - 1):
            try:
                for r in self._lines(
                    self._zip("ITR", a), f"itr_cia_aberta_{a}.csv", str(code_cvm)
                ):
                    if _cd(r["CD_CVM"]) == code_cvm:
                        itr.append(
                            {
                                "referencia": r["DT_REFER"],
                                "entregue": r["DT_RECEB"],
                                "link": _https(r["LINK_DOC"]),
                            }
                        )
            except ErrorCVM:
                continue
            try:
                for r in self._lines(self._zip("IPE", a), f"ipe_cia_aberta_{a}.csv"):
                    if _cd(r["Codigo_CVM"]) == code_cvm and r["Categoria"] in CATEGORIES_IPE:
                        ipe.append(
                            {
                                "data": r["Data_Entrega"],
                                "categoria": r["Categoria"],
                                "tipo": r["Tipo"] or r["Especie"],
                                "assunto": r["Assunto"],
                                "link": _https(r["Link_Download"]),
                            }
                        )
            except ErrorCVM:
                continue

        def ultimos(items: list[dict[str, Any]], chave: str, n: int) -> list[dict[str, Any]]:
            seen, output = set(), []
            for x in sorted(items, key=lambda x: x[chave], reverse=True):
                if x[chave] not in seen or chave == "data":
                    seen.add(x[chave])
                    output.append(x)
            return output[:n]

        t = ticker.upper()
        return {
            "anuais_dfp": ultimos(dfp, "referencia", 6),
            "trimestrais_itr": ultimos(itr, "referencia", 6),
            "releases_e_comunicados": ultimos(ipe, "data", 20),
            "paginas": {
                "cvm_rad": f"https://www.rad.cvm.gov.br/ENET/frmConsultaExternaCVM.aspx?codigoCVM={code_cvm}",
                "b3": f"https://sistemaswebb3-listados.b3.com.br/listedCompaniesPage/main/{code_cvm}/?language=pt-br",
                **(
                    {"status_invest": f"https://statusinvest.com.br/acoes/{t.lower()}"} if t else {}
                ),
            },
            "fonte": "CVM - Portal de Dados Abertos (DFP, ITR, IPE)",
        }


# ---------- fundos imobiliários ----------

COMPOSITION_FII = {
    "Imoveis_Renda_Acabados": "imóveis prontos para renda",
    "Imoveis_Renda_Construcao": "imóveis em construção",
    "Terrenos": "terrenos",
    "CRI": "CRI",
    "CRI_CRA": "CRI/CRA",
    "LCI": "LCI",
    "LCI_LCA": "LCI/LCA",
    "FII": "cotas de outros FIIs",
    "Fundos_Renda_Fixa": "fundos de renda fixa",
    "Titulos_Publicos": "títulos públicos",
    "Disponibilidades": "caixa",
}


def ticker_of_isin(isin: str) -> str:
    """BRMXRFCTF008 → MXRF11 (cota de FII na B3 é o código de 4 letras + 11)."""
    return (
        f"{isin[2:6]}11" if len(isin) == 12 and isin.startswith("BR") and isin[6:9] == "CTF" else ""
    )


def _num(v: str) -> float | None:
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def fii(cvm: "CVM", ticker: str) -> dict[str, Any] | None:
    """Informe mensal do FII (CVM): cadastro, os últimos 12 meses (PL, valor patrimonial da cota,
    DY e rentabilidade do mês, cotistas) e a composição da carteira no último mês."""
    t = ticker.upper().strip()
    return _memo(("fii", str(cvm.pasta), t), lambda: _fii(cvm, t))


def _fii(cvm: "CVM", t: str) -> dict[str, Any] | None:
    today = date.today().year
    zips = []
    for a in (today, today - 1):
        try:
            zips.append(cvm._zip("FII_INF_MENSAL", a))
        except ErrorCVM:
            continue
    cnpj, general = None, None
    for zf in zips:
        for r in cvm._lines(zf, "geral"):
            if ticker_of_isin(r["Codigo_ISIN"]) == t and (
                general is None or r["Data_Referencia"] > general["Data_Referencia"]
            ):
                cnpj, general = r["CNPJ_Fundo_Classe"], r
        if general:
            break
    if general is None:
        return None
    months: dict[str, dict[str, Any]] = {}
    composition: dict[str, float] = {}
    last_ap = ""
    for zf in zips:
        for r in cvm._lines(zf, "complemento", cnpj):
            if r["CNPJ_Fundo_Classe"] == cnpj:
                months[r["Data_Referencia"][:7]] = {
                    "mes": r["Data_Referencia"][:7],
                    "patrimonio_liquido": _num(r["Patrimonio_Liquido"]),
                    "cotas": _num(r["Cotas_Emitidas"]),
                    "valor_patrimonial_cota": _num(r["Valor_Patrimonial_Cotas"]),
                    "dy_mes_pct": _num(r["Percentual_Dividend_Yield_Mes"]),
                    "rentabilidade_mes_pct": _num(r["Percentual_Rentabilidade_Efetiva_Mes"]),
                    "cotistas": _num(r["Total_Numero_Cotistas"]),
                    "taxa_adm_pct": _num(r["Percentual_Despesas_Taxa_Administracao"]),
                }
        for r in cvm._lines(zf, "ativo_passivo", cnpj):
            if r["CNPJ_Fundo_Classe"] == cnpj and r["Data_Referencia"] >= last_ap:
                last_ap = r["Data_Referencia"]
                composition = {
                    label: v
                    for key, label in COMPOSITION_FII.items()
                    if (v := _num(r.get(key, ""))) and v > 0
                }
    serie = [months[m] for m in sorted(months)][-12:]
    for x in serie:  # a CVM publica em fração (0.0095 = 0,95%) em alguns meses e em % noutros
        for k in ("dy_mes_pct", "rentabilidade_mes_pct", "taxa_adm_pct"):
            if x[k] is not None and abs(x[k]) < 0.2:
                x[k] = round(x[k] * 100, 4)
    total = sum(composition.values()) or 1
    return {
        "ticker": t,
        "nome": general["Nome_Fundo_Classe"],
        "cnpj": cnpj,
        "segmento": general["Segmento_Atuacao"],
        "mandato": general["Mandato"],
        "gestao": general["Tipo_Gestao"],
        "administrador": general["Nome_Administrador"],
        "site": general["Site"],
        "inicio": general["Data_Funcionamento"],
        "meses": serie,
        "composicao": [
            {"item": k, "valor": v, "pct": round(v / total * 100, 1)}
            for k, v in sorted(composition.items(), key=lambda x: -x[1])
        ],
        "links": {
            # FNET (B3): relatórios gerenciais, informes mensais/trimestrais, fatos relevantes
            "relatorios_fnet": "https://fnet.bmfbovespa.com.br/fnet/publico/abrirGerenciadorDocumentosCVM"
            f"?cnpjFundo={re.sub(r'[^0-9]', '', cnpj)}",
            "status_invest": f"https://statusinvest.com.br/fundos-imobiliarios/{t.lower()}",
        },
        "fonte": "CVM - Informe mensal de FII",
    }


def _words(nome: str) -> list[str]:
    return [p for p in re.split(r"[\s/().,-]+", _norm(nome)) if p and p not in _EMPTY]


def _accounts(part: str, account: str, desc: str) -> list[str]:
    """Em que campo de `analise.CONTAS` entra a conta da CVM (vazio = nenhum). `_divida` soma
    empréstimos de curto e longo prazo; `_lpa` é o lucro por ação básico (acerta a escala das
    ações)."""
    level = account.count(".")
    if part == "DRE_con":
        if account == "3.01":
            return ["receita_liquida"]
        if level == 1:
            if "periodo" in desc and ("lucro" in desc or "prejuizo" in desc) and "acao" not in desc:
                return ["lucro_liquido"]
            return next(([c] for span, c in DRE_DESCRIPTION if span in desc), [])
        return ["_lpa"] if account.startswith("3.99.01.") and level == 3 else []
    if part == "BPA_con":
        if account == "1":
            return ["ativo_total"]
        if level == 1 and desc.startswith("ativo circulante"):
            return ["ativo_circulante"]
        return ["caixa"] if level <= 2 and desc.startswith("caixa e equivalentes") else []
    if part == "BPP_con":
        if level == 1 and desc.startswith("passivo circulante"):
            return ["passivo_circulante"]
        if level == 1 and "patrimonio liquido" in desc:
            return ["patrimonio_liquido"]
        if level == 2 and account[:4] in ("2.01", "2.02") and desc.startswith("empr"):
            return ["_divida"]
    return []


def _actions_thousand(qtd: float, lucro_thousand: float | None, lpa: float | None) -> float:
    """Ações em circulação, em mil (as contas estão em R$ mil). A CVM recebe a composição do
    capital ora em unidades, ora em milhares, sem dizer qual: o lucro por ação decide."""
    if lucro_thousand and lpa:
        estimado = abs(lucro_thousand * 1000 / lpa)
        if abs(math.log10(qtd * 1000 / estimado)) < abs(math.log10(qtd / estimado)):
            qtd *= 1000
    elif qtd < 1e7:  # companhia aberta com menos de 10 milhões de ações é raríssimo
        qtd *= 1000
    return round(qtd / 1000, 3)


def _close(by_year: dict[int, dict[str, Any]]) -> list[dict[str, Any]]:
    output = []
    for year in sorted(by_year):
        raw = by_year[year]
        line = {k: v for k, v in raw.items() if not k.startswith("_")}
        if "_divida" in raw:
            line["divida_bruta"] = sum(raw["_divida"].values())
        for k in ("capex", "dividendos", "depreciacao"):
            if k in line:
                line[k] = abs(line[k])
        if (qtd := raw.get("_qt")) and qtd > 0:
            line["acoes"] = _actions_thousand(qtd, line.get("lucro_liquido"), raw.get("_lpa"))
        output.append(line)
    return output


def _flow(line: dict[str, Any], account: str, desc: str, valor: float) -> None:
    """Fluxo de caixa: FCO (6.01), capex (aquisição de imobilizado/intangível em 6.02),
    dividendos e JCP pagos (6.03) e depreciação (ajuste em 6.01.01)."""
    if account == "6.01":
        line["fco"] = valor
    elif (
        account.startswith("6.02.") and valor < 0 and ("imobilizado" in desc or "intangivel" in desc)
    ):
        line["capex"] = line.get("capex", 0.0) + valor
    elif account.startswith("6.03.") and ("dividendo" in desc or "juros sobre" in desc) and valor < 0:
        line["dividendos"] = line.get("dividendos", 0.0) + valor
    elif (
        account.startswith("6.01.01.")
        and ("deprecia" in desc or "amortiza" in desc)
        and account.count(".") == 3
    ):
        line["depreciacao"] = line.get("depreciacao", 0.0) + valor
