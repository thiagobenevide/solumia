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
VALIDADE_DIAS = 3
ANOS_DFP = 5  # cada DFP traz o ano e o anterior: 5 arquivos = 6 anos

# Contas da DRE pela descrição (nível 2, `3.xx`): o código muda de plano para plano (bancos têm
# 3.09 como lucro; empresas comuns, 3.11), a descrição não. A ordem importa: a primeira que bate.
DRE_DESCRICAO = (
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
APELIDOS = {
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
_VAZIAS = {
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

CATEGORIAS_IPE = ("Dados Econômico-Financeiros", "Fato Relevante", "Comunicado ao Mercado")


class ErroCVM(RuntimeError):
    pass


# Resultados por empresa/fundo em memória: os arquivos mudam no máximo uma vez por dia e reler os
# CSVs (centenas de MB descompactados) a cada clique é o que deixava a ficha lenta.
_MEMO: dict[tuple[Any, ...], tuple[float, Any]] = {}
MEMO_SEGUNDOS = 6 * 3600
# Uma trava por arquivo: duas consultas ao mesmo tempo não baixam o mesmo ZIP duas vezes.
_TRAVAS: dict[str, threading.Lock] = {}
_TRAVA = threading.Lock()


def _memo(chave: tuple[Any, ...], calcular: Any) -> Any:
    guardado = _MEMO.get(chave)
    if guardado and time.time() - guardado[0] < MEMO_SEGUNDOS:
        return guardado[1]
    valor = calcular()
    if len(_MEMO) >= 500:
        _MEMO.pop(next(iter(_MEMO)))
    _MEMO[chave] = (time.time(), valor)
    return valor


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

    def _zip(self, doc: str, ano: int) -> zipfile.ZipFile:
        if doc == "FII_INF_MENSAL":
            nome, caminho = (
                f"inf_mensal_fii_{ano}.zip",
                "https://dados.cvm.gov.br/dados/FII/DOC/INF_MENSAL/DADOS",
            )
        else:
            nome, caminho = f"{doc.lower()}_cia_aberta_{ano}.zip", f"{BASE}/{doc}/DADOS"
        destino = self.pasta / nome
        with _TRAVA:
            trava = _TRAVAS.setdefault(nome, threading.Lock())
        with trava:
            return self._zip_baixado(doc, ano, nome, caminho, destino)

    def _zip_baixado(
        self, doc: str, ano: int, nome: str, caminho: str, destino: Path
    ) -> zipfile.ZipFile:
        velho = (
            destino.exists()
            and ano >= date.today().year - (1 if doc in ("DFP",) else 0)
            and (time.time() - destino.stat().st_mtime > VALIDADE_DIAS * 86400)
        )
        if not destino.exists() or velho:
            url = f"{caminho}/{nome}"
            try:
                with urllib.request.urlopen(
                    urllib.request.Request(url, headers={"User-Agent": "agent"}), timeout=120
                ) as r:
                    dados = r.read()
            except OSError as e:
                if destino.exists():
                    return zipfile.ZipFile(destino)  # sem rede: usa o que tem
                raise ErroCVM(f"Não baixei {nome} da CVM ({e}).") from e
            tmp = destino.with_suffix(".tmp")
            tmp.write_bytes(dados)
            tmp.replace(destino)
        return zipfile.ZipFile(destino)

    @staticmethod
    def _linhas(zf: zipfile.ZipFile, parte: str, filtro: str = "") -> Any:
        """Linhas do CSV [parte]; com [filtro], só as que contêm o texto (descarta em bytes, antes
        do CSV, o que é muitas vezes mais rápido; quem chama ainda confere o campo exato). Não
        usar filtro em arquivo com texto livre de várias linhas (IPE)."""
        nome = next((n for n in zf.namelist() if parte in n), None)
        if nome is None:
            return iter(())
        if not filtro:
            texto = io.TextIOWrapper(zf.open(nome), encoding="latin-1")
            return csv.DictReader(texto, delimiter=";")
        bruto, alvo = zf.open(nome), filtro.encode("latin-1")
        linhas = itertools.chain([bruto.readline()], (x for x in bruto if alvo in x))
        return csv.DictReader((x.decode("latin-1") for x in linhas), delimiter=";")

    def _ano_existente(self, doc: str, ano: int) -> int:
        """O ano mais recente que a CVM já publicou para [doc] (o ano corrente pode não existir)."""
        for a in (ano, ano - 1):
            try:
                self._zip(doc, a)
                return a
            except ErroCVM:
                continue
        raise ErroCVM(f"CVM sem {doc} de {ano - 1} nem {ano}.")

    def aquecer(self) -> None:
        """Deixa baixados e em dia os ZIPs da ficha (o download é a parte lenta do clique)."""
        hoje = date.today().year
        for doc, ano in (("FCA", hoje), ("ITR", hoje), ("IPE", hoje), ("FII_INF_MENSAL", hoje)):
            try:
                self._ano_existente(doc, ano)
            except ErroCVM:
                continue
        try:
            ultimo = self._ano_existente("DFP", hoje - 1)
            for a in range(ultimo - ANOS_DFP + 1, ultimo):
                self._zip("DFP", a)
        except ErroCVM:
            pass
        self.indice()

    # ---------- empresa ----------

    # ---------- índice e busca ----------

    def indice(self) -> list[dict[str, Any]]:
        """Todas as companhias com ticker (FCA) e todos os FIIs (informe mensal), para a busca
        enquanto digita. Fica em memória: montar lê dois CSVs inteiros."""
        return _memo(("indice", str(self.pasta)), self._indice)

    def _indice(self) -> list[dict[str, Any]]:
        itens: list[dict[str, Any]] = []
        try:
            zf = self._zip("FCA", self._ano_existente("FCA", date.today().year))
            tickers: dict[str, set[str]] = {}
            for r in self._linhas(zf, "valor_mobiliario"):
                cod = r["Codigo_Negociacao"].upper().strip()
                # só ações, units e BDRs negociados hoje (debêntures têm código de 6+ dígitos)
                if (
                    cod
                    and not r.get("Data_Fim_Negociacao")
                    and re.fullmatch(r"[A-Z0-9]{4}\d{1,2}", cod)
                ):
                    tickers.setdefault(r["CNPJ_Companhia"], set()).add(cod)
            for r in self._linhas(zf, "geral"):
                ts = sorted(tickers.get(r["CNPJ_Companhia"], ()))
                if not ts:
                    continue
                itens.append(
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
        except ErroCVM:
            pass
        fiis: dict[str, dict[str, Any]] = {}
        for a in (date.today().year, date.today().year - 1):
            try:
                zf = self._zip("FII_INF_MENSAL", a)
            except ErroCVM:
                continue
            for r in self._linhas(zf, "geral"):
                t = ticker_do_isin(r["Codigo_ISIN"])
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
            itens.append(f)
        for x in itens:
            x["_nome"] = _norm(f"{x['nome']} {x['anterior']}")
            x["_palavras"] = _palavras(x["nome"])
            x["_anteriores"] = _palavras(x["anterior"])
        return itens

    def sugerir(self, consulta: str, limite: int = 12) -> list[dict[str, Any]]:
        """Busca enquanto digita: ticker pelo começo (ITU → ITUB3, ITUB4), nome popular (Itaú,
        Magalu), palavra do nome pelo começo ou no meio e, por último, nome parecido (erro de
        digitação). Ações e FIIs juntos, os mais prováveis primeiro."""
        alvo = _norm(consulta)
        if not alvo:
            return []
        compacto = re.sub(r"[^a-z0-9]", "", alvo).upper()
        apelidos = {t for nome, t in APELIDOS.items() if nome.startswith(alvo) and len(alvo) >= 2}
        termos = [p for p in alvo.split() if p not in _VAZIAS] or [alvo]
        achados = []
        for x in self.indice():
            pontos = 0.0
            if compacto in x["tickers"]:
                pontos = 100
            elif len(compacto) >= 2 and any(t.startswith(compacto) for t in x["tickers"]):
                pontos = 90
            elif apelidos & set(x["tickers"]):
                pontos = 85
            elif all(any(p.startswith(t) for p in x["_palavras"]) for t in termos):
                pontos = 75
            elif all(any(p.startswith(t) for p in x["_anteriores"]) for t in termos):
                pontos = 65  # nome antigo (Petrobras Distribuidora → Vibra)
            elif len(alvo) >= 3 and alvo in x["_nome"]:
                pontos = 60
            elif len(alvo) >= 3:
                # parecido: "itu" ~ "itau", "petrobas" ~ "petrobras"
                melhor = max(
                    (
                        difflib.SequenceMatcher(None, termos[0], p[: len(termos[0]) + 1]).ratio()
                        for p in x["_palavras"][:6] + [t.lower() for t in x["tickers"]]
                    ),
                    default=0,
                )
                if melhor >= 0.75:
                    pontos = 30 + 20 * melhor
            if pontos:
                pontos += 3 if x["situacao"] == "Ativo" else 0
                achados.append((pontos, x))
        achados.sort(key=lambda p: (-p[0], len(p[1]["nome"])))
        return [{k: v for k, v in x.items() if not k.startswith("_")} for _, x in achados[:limite]]

    def buscar(self, consulta: str) -> list[dict[str, Any]]:
        """Companhias (só ações) por ticker, nome ou apelido, com CNPJ, código CVM, setor, site de
        RI e todos os tickers; a mais provável primeiro."""
        return [x for x in self.sugerir(consulta, 20) if x["tipo"] == "acao"][:10]

    # ---------- demonstrativos ----------

    def demonstrativos(
        self, codigo_cvm: int, anos: int = ANOS_DFP, ao_ano: Any = None
    ) -> list[dict[str, Any]]:
        """Anos fechados no formato de `analise.CONTAS` (R$ mil; `acoes` em mil), do
        consolidado. [ao_ano] recebe a lista parcial a cada arquivo lido, do mais novo para o mais
        antigo, para a ficha ir aparecendo."""
        return _memo(
            ("demonstrativos", str(self.pasta), codigo_cvm, anos),
            lambda: self._demonstrativos(codigo_cvm, anos, ao_ano),
        )

    def _demonstrativos(
        self, codigo_cvm: int, anos: int, ao_ano: Any = None
    ) -> list[dict[str, Any]]:
        ultimo = self._ano_existente("DFP", date.today().year - 1)
        por_ano: dict[int, dict[str, Any]] = {}
        cnpj = ""
        for ano_arq in range(ultimo, ultimo - anos, -1):
            try:
                zf = self._zip("DFP", ano_arq)
            except ErroCVM:
                continue
            for parte in ("DRE_con", "BPA_con", "BPP_con", "DFC_MI_con", "DFC_MD_con"):
                for r in self._linhas(zf, parte, str(codigo_cvm)):
                    if _cd(r["CD_CVM"]) != codigo_cvm:
                        continue
                    cnpj = cnpj or r["CNPJ_CIA"]
                    ano = int(r["DT_FIM_EXERC"][:4])
                    # cada ano vem do próprio arquivo; o "penúltimo" só serve ao ano mais antigo
                    if r["ORDEM_EXERC"] != "ÚLTIMO" and ano > ultimo - anos:
                        continue
                    linha = por_ano.setdefault(ano, {"ano": ano})
                    escala = 1000 if r["ESCALA_MOEDA"].upper() == "UNIDADE" else 1
                    valor = float(r["VL_CONTA"]) / escala
                    conta, desc = r["CD_CONTA"], _norm(r["DS_CONTA"])
                    for chave in _contas(parte, conta, desc):
                        if chave == "_divida":
                            linha.setdefault("_divida", {})[conta] = valor
                        elif chave == "_lpa":
                            if float(r["VL_CONTA"]):
                                linha.setdefault("_lpa", float(r["VL_CONTA"]))
                        else:
                            linha.setdefault(chave, valor)
                    if parte.startswith("DFC"):
                        _fluxo(linha, conta, desc, valor)
            if cnpj:
                for r in self._linhas(zf, "composicao_capital", cnpj):
                    if r["CNPJ_CIA"] == cnpj and int(r["DT_REFER"][:4]) in por_ano:
                        q = _num(r["QT_ACAO_TOTAL_CAP_INTEGR"]) or 0
                        q -= _num(r["QT_ACAO_TOTAL_TESOURO"]) or 0
                        por_ano[int(r["DT_REFER"][:4])]["_qt"] = q
            if ao_ano is not None:
                ao_ano(_fechar(por_ano))
        return _fechar(por_ano)[-6:]

    # ---------- documentos e links ----------

    def documentos(self, codigo_cvm: int, ticker: str = "") -> dict[str, Any]:
        """Links para abrir/baixar: DFPs (anuais), ITRs (trimestrais), releases e apresentações de
        resultado, fatos relevantes; mais as páginas da empresa na CVM, B3 e Status Invest."""
        return _memo(
            ("documentos", str(self.pasta), codigo_cvm, ticker.upper()),
            lambda: self._documentos(codigo_cvm, ticker),
        )

    def _documentos(self, codigo_cvm: int, ticker: str) -> dict[str, Any]:
        hoje = date.today().year
        dfp, itr, ipe = [], [], []
        try:
            ultimo = self._ano_existente("DFP", hoje - 1)
            for a in range(ultimo - ANOS_DFP + 1, ultimo + 1):
                for r in self._linhas(
                    self._zip("DFP", a), f"dfp_cia_aberta_{a}.csv", str(codigo_cvm)
                ):
                    if _cd(r["CD_CVM"]) == codigo_cvm:
                        dfp.append(
                            {
                                "referencia": r["DT_REFER"],
                                "entregue": r["DT_RECEB"],
                                "link": _https(r["LINK_DOC"]),
                            }
                        )
        except ErroCVM:
            pass
        for a in (hoje, hoje - 1):
            try:
                for r in self._linhas(
                    self._zip("ITR", a), f"itr_cia_aberta_{a}.csv", str(codigo_cvm)
                ):
                    if _cd(r["CD_CVM"]) == codigo_cvm:
                        itr.append(
                            {
                                "referencia": r["DT_REFER"],
                                "entregue": r["DT_RECEB"],
                                "link": _https(r["LINK_DOC"]),
                            }
                        )
            except ErroCVM:
                continue
            try:
                for r in self._linhas(self._zip("IPE", a), f"ipe_cia_aberta_{a}.csv"):
                    if _cd(r["Codigo_CVM"]) == codigo_cvm and r["Categoria"] in CATEGORIAS_IPE:
                        ipe.append(
                            {
                                "data": r["Data_Entrega"],
                                "categoria": r["Categoria"],
                                "tipo": r["Tipo"] or r["Especie"],
                                "assunto": r["Assunto"],
                                "link": _https(r["Link_Download"]),
                            }
                        )
            except ErroCVM:
                continue

        def ultimos(lista: list[dict[str, Any]], chave: str, n: int) -> list[dict[str, Any]]:
            vistos, saida = set(), []
            for x in sorted(lista, key=lambda x: x[chave], reverse=True):
                if x[chave] not in vistos or chave == "data":
                    vistos.add(x[chave])
                    saida.append(x)
            return saida[:n]

        t = ticker.upper()
        return {
            "anuais_dfp": ultimos(dfp, "referencia", 6),
            "trimestrais_itr": ultimos(itr, "referencia", 6),
            "releases_e_comunicados": ultimos(ipe, "data", 20),
            "paginas": {
                "cvm_rad": f"https://www.rad.cvm.gov.br/ENET/frmConsultaExternaCVM.aspx?codigoCVM={codigo_cvm}",
                "b3": f"https://sistemaswebb3-listados.b3.com.br/listedCompaniesPage/main/{codigo_cvm}/?language=pt-br",
                **(
                    {"status_invest": f"https://statusinvest.com.br/acoes/{t.lower()}"} if t else {}
                ),
            },
            "fonte": "CVM - Portal de Dados Abertos (DFP, ITR, IPE)",
        }


# ---------- fundos imobiliários ----------

COMPOSICAO_FII = {
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


def ticker_do_isin(isin: str) -> str:
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
    hoje = date.today().year
    zips = []
    for a in (hoje, hoje - 1):
        try:
            zips.append(cvm._zip("FII_INF_MENSAL", a))
        except ErroCVM:
            continue
    cnpj, geral = None, None
    for zf in zips:
        for r in cvm._linhas(zf, "geral"):
            if ticker_do_isin(r["Codigo_ISIN"]) == t and (
                geral is None or r["Data_Referencia"] > geral["Data_Referencia"]
            ):
                cnpj, geral = r["CNPJ_Fundo_Classe"], r
        if geral:
            break
    if geral is None:
        return None
    meses: dict[str, dict[str, Any]] = {}
    composicao: dict[str, float] = {}
    ultimo_ap = ""
    for zf in zips:
        for r in cvm._linhas(zf, "complemento", cnpj):
            if r["CNPJ_Fundo_Classe"] == cnpj:
                meses[r["Data_Referencia"][:7]] = {
                    "mes": r["Data_Referencia"][:7],
                    "patrimonio_liquido": _num(r["Patrimonio_Liquido"]),
                    "cotas": _num(r["Cotas_Emitidas"]),
                    "valor_patrimonial_cota": _num(r["Valor_Patrimonial_Cotas"]),
                    "dy_mes_pct": _num(r["Percentual_Dividend_Yield_Mes"]),
                    "rentabilidade_mes_pct": _num(r["Percentual_Rentabilidade_Efetiva_Mes"]),
                    "cotistas": _num(r["Total_Numero_Cotistas"]),
                    "taxa_adm_pct": _num(r["Percentual_Despesas_Taxa_Administracao"]),
                }
        for r in cvm._linhas(zf, "ativo_passivo", cnpj):
            if r["CNPJ_Fundo_Classe"] == cnpj and r["Data_Referencia"] >= ultimo_ap:
                ultimo_ap = r["Data_Referencia"]
                composicao = {
                    rotulo: v
                    for chave, rotulo in COMPOSICAO_FII.items()
                    if (v := _num(r.get(chave, ""))) and v > 0
                }
    serie = [meses[m] for m in sorted(meses)][-12:]
    for x in serie:  # a CVM publica em fração (0.0095 = 0,95%) em alguns meses e em % noutros
        for k in ("dy_mes_pct", "rentabilidade_mes_pct", "taxa_adm_pct"):
            if x[k] is not None and abs(x[k]) < 0.2:
                x[k] = round(x[k] * 100, 4)
    total = sum(composicao.values()) or 1
    return {
        "ticker": t,
        "nome": geral["Nome_Fundo_Classe"],
        "cnpj": cnpj,
        "segmento": geral["Segmento_Atuacao"],
        "mandato": geral["Mandato"],
        "gestao": geral["Tipo_Gestao"],
        "administrador": geral["Nome_Administrador"],
        "site": geral["Site"],
        "inicio": geral["Data_Funcionamento"],
        "meses": serie,
        "composicao": [
            {"item": k, "valor": v, "pct": round(v / total * 100, 1)}
            for k, v in sorted(composicao.items(), key=lambda x: -x[1])
        ],
        "links": {
            # FNET (B3): relatórios gerenciais, informes mensais/trimestrais, fatos relevantes
            "relatorios_fnet": "https://fnet.bmfbovespa.com.br/fnet/publico/abrirGerenciadorDocumentosCVM"
            f"?cnpjFundo={re.sub(r'[^0-9]', '', cnpj)}",
            "status_invest": f"https://statusinvest.com.br/fundos-imobiliarios/{t.lower()}",
        },
        "fonte": "CVM - Informe mensal de FII",
    }


def _palavras(nome: str) -> list[str]:
    return [p for p in re.split(r"[\s/().,-]+", _norm(nome)) if p and p not in _VAZIAS]


def _contas(parte: str, conta: str, desc: str) -> list[str]:
    """Em que campo de `analise.CONTAS` entra a conta da CVM (vazio = nenhum). `_divida` soma
    empréstimos de curto e longo prazo; `_lpa` é o lucro por ação básico (acerta a escala das
    ações)."""
    nivel = conta.count(".")
    if parte == "DRE_con":
        if conta == "3.01":
            return ["receita_liquida"]
        if nivel == 1:
            if "periodo" in desc and ("lucro" in desc or "prejuizo" in desc) and "acao" not in desc:
                return ["lucro_liquido"]
            return next(([c] for trecho, c in DRE_DESCRICAO if trecho in desc), [])
        return ["_lpa"] if conta.startswith("3.99.01.") and nivel == 3 else []
    if parte == "BPA_con":
        if conta == "1":
            return ["ativo_total"]
        if nivel == 1 and desc.startswith("ativo circulante"):
            return ["ativo_circulante"]
        return ["caixa"] if nivel <= 2 and desc.startswith("caixa e equivalentes") else []
    if parte == "BPP_con":
        if nivel == 1 and desc.startswith("passivo circulante"):
            return ["passivo_circulante"]
        if nivel == 1 and "patrimonio liquido" in desc:
            return ["patrimonio_liquido"]
        if nivel == 2 and conta[:4] in ("2.01", "2.02") and desc.startswith("empr"):
            return ["_divida"]
    return []


def _acoes_mil(qtd: float, lucro_mil: float | None, lpa: float | None) -> float:
    """Ações em circulação, em mil (as contas estão em R$ mil). A CVM recebe a composição do
    capital ora em unidades, ora em milhares, sem dizer qual: o lucro por ação decide."""
    if lucro_mil and lpa:
        estimado = abs(lucro_mil * 1000 / lpa)
        if abs(math.log10(qtd * 1000 / estimado)) < abs(math.log10(qtd / estimado)):
            qtd *= 1000
    elif qtd < 1e7:  # companhia aberta com menos de 10 milhões de ações é raríssimo
        qtd *= 1000
    return round(qtd / 1000, 3)


def _fechar(por_ano: dict[int, dict[str, Any]]) -> list[dict[str, Any]]:
    saida = []
    for ano in sorted(por_ano):
        bruto = por_ano[ano]
        linha = {k: v for k, v in bruto.items() if not k.startswith("_")}
        if "_divida" in bruto:
            linha["divida_bruta"] = sum(bruto["_divida"].values())
        for k in ("capex", "dividendos", "depreciacao"):
            if k in linha:
                linha[k] = abs(linha[k])
        if (qtd := bruto.get("_qt")) and qtd > 0:
            linha["acoes"] = _acoes_mil(qtd, linha.get("lucro_liquido"), bruto.get("_lpa"))
        saida.append(linha)
    return saida


def _fluxo(linha: dict[str, Any], conta: str, desc: str, valor: float) -> None:
    """Fluxo de caixa: FCO (6.01), capex (aquisição de imobilizado/intangível em 6.02),
    dividendos e JCP pagos (6.03) e depreciação (ajuste em 6.01.01)."""
    if conta == "6.01":
        linha["fco"] = valor
    elif (
        conta.startswith("6.02.") and valor < 0 and ("imobilizado" in desc or "intangivel" in desc)
    ):
        linha["capex"] = linha.get("capex", 0.0) + valor
    elif conta.startswith("6.03.") and ("dividendo" in desc or "juros sobre" in desc) and valor < 0:
        linha["dividendos"] = linha.get("dividendos", 0.0) + valor
    elif (
        conta.startswith("6.01.01.")
        and ("deprecia" in desc or "amortiza" in desc)
        and conta.count(".") == 3
    ):
        linha["depreciacao"] = linha.get("depreciacao", 0.0) + valor
