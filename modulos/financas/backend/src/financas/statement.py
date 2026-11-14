"""Importação de extratos (OFX dos bancos e CSV de extrato ou fatura) e categorização automática por
regras: a primeira regra cujo padrão aparece na descrição define categoria e contraparte; sem regra,
vale a categoria já usada antes para a mesma descrição."""

import csv
import hashlib
import io
import re
import unicodedata
from datetime import date, datetime
from typing import Any

from financas.warehouse import Armazem, Invalido


def normalizar(texto: str) -> str:
    sem_acento = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode()
    return re.sub(r"\s+", " ", sem_acento.lower()).strip()


# prefixos de extrato que não fazem parte do nome de quem recebeu/enviou
_PREFIXOS = re.compile(
    r"(?:(?:pix|ted|doc|boleto|transf\w*|transferencia|pagamento|pagto|pag|pg|compra|debito|credito|cartao|"
    r"enviad[oa]|recebid[oa]|qrcode|qr code|no|em conta|automatico|de|para|a|o)\b|[-*:/])\s*",
)
_RUIDO = re.compile(
    r"\b\d{2}/\d{2}(/\d{2,4})?\b|\b\d{2}:\d{2}\b|\b\d{6,}\b|\bparc(ela)? ?\d+/\d+\b"
)


def contraparte(descricao: str) -> str:
    """Melhor palpite de quem recebeu ou enviou o dinheiro (ex.: 'PIX ENVIADO Maria' → 'Maria')."""
    texto = _RUIDO.sub(" ", descricao)
    texto = re.sub(r"\s+", " ", texto).strip(" -*/")
    while (m := _PREFIXOS.match(normalizar(texto))) and m.end():
        texto = texto[m.end() :]
    texto = texto.strip(" -*/")
    return texto.title() if texto.isupper() or texto.islower() else texto


def numero_br(valor: str) -> float:
    v = valor.strip().replace("R$", "").replace(" ", "")
    negativo = v.endswith("-") or (v.startswith("(") and v.endswith(")"))
    v = v.strip("()-+") if negativo else v
    if "," in v:
        v = v.replace(".", "").replace(",", ".")
    n = float(v)
    return -n if negativo else n


def _data(valor: str) -> str:
    v = valor.strip()[:10]
    for fmt in ("%d/%m/%Y", "%Y-%m-%d", "%d/%m/%y", "%d-%m-%Y", "%Y%m%d"):
        try:
            return datetime.strptime(v, fmt).date().isoformat()
        except ValueError:
            continue
    raise Invalido(f"Data inválida no arquivo: {valor}")


def ler_ofx(texto: str) -> list[dict[str, Any]]:
    itens = []
    for bloco in re.findall(
        r"<STMTTRN>(.*?)(?:</STMTTRN>|(?=<STMTTRN>)|(?=</BANKTRANLIST>))", texto, re.S | re.I
    ):

        def campo(nome: str, b: str = bloco) -> str:
            m = re.search(rf"<{nome}>([^<\r\n]*)", b, re.I)
            return m.group(1).strip() if m else ""

        data = campo("DTPOSTED")[:8]
        valor = campo("TRNAMT").replace(",", ".")
        if not data or not valor:
            continue
        descricao = campo("MEMO") or campo("NAME") or campo("TRNTYPE")
        itens.append(
            {
                "data": date(int(data[:4]), int(data[4:6]), int(data[6:8])).isoformat(),
                "descricao": descricao,
                "valor": float(valor),
                "ref": campo("FITID"),
            }
        )
    return itens


# Cabeçalhos dos extratos dos bancos (já normalizados: minúsculas, sem acento). Exemplos:
# Nubank conta "Data,Valor,Identificador,Descrição"; Nubank cartão "date,title,amount";
# Inter "Data Lançamento;Histórico;Descrição;Valor;Saldo"; BB "Data;Lançamento;Detalhes;
# N° documento;Valor;Tipo Lançamento"; Mercado Pago "RELEASE_DATE;TRANSACTION_TYPE;REFERENCE_ID;
# TRANSACTION_NET_AMOUNT;PARTIAL_BALANCE"; Itaú (XLS) "data;lançamento;ag./origem;valor (R$)".
_COLUNAS = {
    "data": (
        "data",
        "date",
        "dt",
        "data lancamento",
        "data da compra",
        "data movimento",
        "release_date",
        "data do lancamento",
        "data de lancamento",
        "data movimentacao",
        "data da transacao",
    ),
    "descricao": (
        "descricao",
        "historico",
        "lancamento",
        "title",
        "estabelecimento",
        "description",
        "memo",
        "detalhes",
        "transaction_type",
        "tipo de transacao",
    ),
    # segundo texto do lançamento (Inter: Histórico + Descrição; BB: Lançamento + Detalhes)
    "complemento": ("descricao", "detalhes", "complemento"),
    "valor": (
        "valor",
        "amount",
        "valor (r$)",
        "valor r$",
        "quantia",
        "transaction_net_amount",
        "valor liquido",
        "valor da transacao",
    ),
    "credito": ("credito", "entrada"),
    "debito": ("debito", "saida"),
    # coluna que diz se é entrada ou saída quando o valor vem sem sinal (BB: "Tipo Lançamento")
    "sinal": ("tipo lancamento", "tipo de lancamento", "natureza", "d/c", "c/d"),
}

# linhas de saldo e totais que alguns bancos põem no meio do extrato
_NAO_LANCAMENTO = re.compile(r"^(s ?a ?l ?d ?o|saldo|total|resumo)\b")


def _indices(cab: list[str]) -> dict[str, int]:
    idx: dict[str, int] = {}
    for chave, nomes in _COLUNAS.items():
        for i, c in enumerate(cab):
            if chave == "complemento" and i == idx.get("descricao"):
                continue
            if c in nomes or any(c.startswith(n) for n in nomes if len(n) > 4):
                idx.setdefault(chave, i)
    return idx


def _completo(idx: dict[str, int]) -> bool:
    return (
        "data" in idx
        and "descricao" in idx
        and bool({"valor"} & idx.keys() or {"credito", "debito"} <= idx.keys())
    )


def ler_csv(texto: str, fatura: bool = False) -> list[dict[str, Any]]:
    """CSV com cabeçalho; aceita `;` ou `,`, número 1.234,56 e data dd/mm/aaaa. Em [fatura] (cartão)
    os valores positivos são gastos e viram negativos."""
    amostra = texto[:2000]
    delim = ";" if amostra.count(";") >= amostra.count(",") / 2 and ";" in amostra else ","
    linhas = list(csv.reader(io.StringIO(texto), delimiter=delim))
    # Inter e Mercado Pago põem conta, período e saldo antes do cabeçalho: procura a linha que tem
    # data, descrição e valor nas primeiras 40.
    inicio, idx = next(
        (
            (i, ix)
            for i, linha in enumerate(linhas[:40])
            if _completo(ix := _indices([normalizar(c) for c in linha]))
        ),
        (-1, {}),
    )
    if inicio < 0:
        raise Invalido("CSV sem colunas reconhecidas (precisa de data, descrição e valor)")
    itens = []
    for linha in linhas[inicio + 1 :]:
        if len(linha) <= max(idx.values()) or not linha[idx["data"]].strip():
            continue
        descricao = linha[idx["descricao"]].strip()
        if (
            "complemento" in idx
            and (extra := linha[idx["complemento"]].strip())
            and extra != descricao
        ):
            descricao = f"{descricao} - {extra}" if descricao else extra
        if not descricao or _NAO_LANCAMENTO.match(normalizar(descricao)):
            continue
        try:
            _data(linha[idx["data"]])
        except Invalido:
            continue  # rodapé, subtotal ou linha de texto
        try:
            if "valor" in idx:
                valor = numero_br(linha[idx["valor"]])
            else:
                cred = linha[idx["credito"]].strip()
                deb = linha[idx["debito"]].strip()
                valor = (numero_br(cred) if cred else 0) - (abs(numero_br(deb)) if deb else 0)
        except ValueError:
            continue
        if (
            "sinal" in idx
            and valor > 0
            and normalizar(linha[idx["sinal"]]) in ("saida", "debito", "d")
        ):
            valor = -valor
        itens.append(
            {
                "data": _data(linha[idx["data"]]),
                "descricao": descricao,
                "valor": -valor if fatura else valor,
                "ref": "",
            }
        )
    return itens


def planilha_para_csv(nome: str, conteudo: bytes) -> str:
    """XLSX/XLS (Itaú, Mercado Pago, Inter exportam assim) → texto CSV com `;` para o [ler_csv]."""
    linhas: list[list[Any]] = []
    if nome.lower().endswith(".xls"):
        import xlrd

        livro = xlrd.open_workbook(file_contents=conteudo)
        folha = livro.sheet_by_index(0)
        for r in range(folha.nrows):
            linha = []
            for c in folha.row(r):
                if c.ctype == xlrd.XL_CELL_DATE:
                    linha.append(xlrd.xldate_as_datetime(c.value, livro.datemode).date())
                else:
                    linha.append(c.value)
            linhas.append(linha)
    else:
        from openpyxl import load_workbook

        folha = load_workbook(io.BytesIO(conteudo), read_only=True, data_only=True).worksheets[0]
        linhas = [list(r) for r in folha.iter_rows(values_only=True)]

    def celula(v: Any) -> str:
        if v is None:
            return ""
        if isinstance(v, datetime):
            return v.date().isoformat()
        if isinstance(v, date):
            return v.isoformat()
        if isinstance(v, float):
            return f"{v:.2f}"
        return str(v).replace(";", ",").replace("\n", " ")

    return "\n".join(";".join(celula(v) for v in linha) for linha in linhas)


def texto_do_pdf(conteudo: bytes) -> str:
    """Texto de um extrato em PDF (pdftotext, do poppler), mantendo as colunas alinhadas."""
    import subprocess
    import tempfile

    with tempfile.NamedTemporaryFile(suffix=".pdf") as f:
        f.write(conteudo)
        f.flush()
        try:
            r = subprocess.run(
                ["pdftotext", "-layout", f.name, "-"], capture_output=True, timeout=60, check=True
            )
        except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
            raise Invalido(f"Não consegui ler o PDF ({e.__class__.__name__}).") from e
    texto = r.stdout.decode("utf-8", "ignore")
    if not texto.strip():
        raise Invalido("O PDF não tem texto (é imagem escaneada).")
    return texto


_FORMAS = [
    ("pix", r"\bpix\b"),
    ("boleto", r"\bboleto|\bpagamento de titulo|\bpag(amento|to)? tit"),
    ("ted", r"\bted\b|\btransf(erencia)? eletronica"),
    ("doc", r"\bdoc\b"),
    ("saque", r"\bsaque"),
    ("deposito", r"\bdeposito"),
    ("tarifa", r"\btarifa|\banuidade|\biof\b|\bjuros\b|\bmulta\b"),
    ("investimento", r"\baplicac|\bresgate|\bcdb\b|\btesouro|\brdb\b|\bcaixinha|\bpoupanca"),
    ("debito", r"\bdebito|\bcompra (no )?cartao de debito|\bcompra deb"),
    ("credito", r"\bcredito em cartao|\bcompra (no )?credito|\bfatura"),
    ("transferencia", r"\btransf"),
]


def forma_pagamento(descricao: str, conta_tipo: str = "") -> str:
    """Como o dinheiro entrou ou saiu, pelo texto do lançamento. O extrato de um banco digital
    mistura cartão, Pix e depósito mesmo na conta do cartão: o texto vale primeiro e só o que não
    diz nada vira `credito` no cartão."""
    d = normalizar(descricao)
    forma = next((forma for forma, padrao in _FORMAS if re.search(padrao, d)), "")
    return forma or ("credito" if conta_tipo == "cartao" else "")


def _decodificar(conteudo: bytes) -> str:
    for cod in ("utf-8-sig", "cp1252", "latin-1"):
        try:
            return conteudo.decode(cod)
        except UnicodeDecodeError:
            continue
    return conteudo.decode("utf-8", "ignore")


def regra_para(arm: Armazem, descricao: str) -> dict[str, Any] | None:
    alvo = normalizar(descricao)
    for r in sorted(arm.todos("regras"), key=lambda r: -r["prioridade"]):
        padrao = normalizar(r["padrao"])
        if padrao and padrao in alvo:
            return r
    return None


def categorizar(arm: Armazem, t: dict[str, Any], historico: dict[str, str] | None = None) -> bool:
    """Preenche categoria e contraparte de [t] se estiverem vazias. Devolve se mudou algo."""
    mudou = False
    r = regra_para(arm, t["descricao"])
    if r:
        if not t["categoria_id"] and r["categoria_id"]:
            t["categoria_id"] = r["categoria_id"]
            mudou = True
        if not t["contraparte"] and r["contraparte"]:
            t["contraparte"] = r["contraparte"]
            mudou = True
    if not t["categoria_id"] and historico:
        cat = historico.get(normalizar(t["descricao"]))
        if cat:
            t["categoria_id"] = cat
            mudou = True
    if not t["contraparte"]:
        t["contraparte"] = contraparte(t["descricao"])
        mudou = mudou or bool(t["contraparte"])
    return mudou


def _historico(arm: Armazem) -> dict[str, str]:
    return {
        normalizar(t["descricao"]): t["categoria_id"]
        for t in arm.todos("transacoes")
        if t["categoria_id"]
    }


class PrecisaIA(Invalido):
    """Formato que o código não lê (PDF, planilha ou CSV sem colunas conhecidas): o texto vai para a
    IA extrair os lançamentos."""

    def __init__(self, texto: str, motivo: str) -> None:
        super().__init__(motivo)
        self.texto = texto


def ler_arquivo(nome: str, conteudo: bytes, conta_tipo: str) -> list[dict[str, Any]]:
    """Lançamentos do arquivo pelo formato; [PrecisaIA] quando só a IA consegue ler."""
    baixo = nome.lower()
    if baixo.endswith(".pdf"):
        raise PrecisaIA(texto_do_pdf(conteudo), "PDF: a IA vai ler os lançamentos")
    if baixo.endswith((".xlsx", ".xls")):
        texto = planilha_para_csv(nome, conteudo)
    else:
        texto = _decodificar(conteudo)
        if baixo.endswith((".ofx", ".qfx")) or "<OFX>" in texto[:4000].upper():
            return ler_ofx(texto)
        if not baixo.endswith((".csv", ".txt")):
            raise Invalido("Formato não suportado: envie OFX, CSV, XLS/XLSX ou PDF")
    try:
        itens = ler_csv(texto)
    except Invalido as e:
        raise PrecisaIA(texto, f"{e}: a IA vai ler os lançamentos") from e
    # Fatura traz os gastos positivos; extrato completo (Pix, depósito, cartão) já vem com sinal,
    # mesmo quando a conta escolhida é o cartão. Só inverte se a maioria for positiva.
    if conta_tipo == "cartao" and sum(i["valor"] > 0 for i in itens) > len(itens) / 2:
        for i in itens:
            i["valor"] = -i["valor"]
    return itens


def importar(arm: Armazem, nome: str, conteudo: bytes, conta_id: str) -> dict[str, Any]:
    conta = arm.obter("contas", conta_id)
    return gravar_lancamentos(arm, ler_arquivo(nome, conteudo, conta["tipo"]), conta_id)


def gravar_lancamentos(arm: Armazem, itens: list[dict[str, Any]], conta_id: str) -> dict[str, Any]:
    """Grava os lançamentos lidos sem duplicar (mesmo hash), com parcela, forma de pagamento,
    categoria e contraparte."""
    conta = arm.obter("contas", conta_id)
    with arm.trava:
        existentes = {t["hash"] for t in arm.todos("transacoes") if t["hash"]}
        historico = _historico(arm)
        vistos: dict[str, int] = {}
        novas = []
        for it in itens:
            desc = normalizar(it["descricao"])
            chave = f"{conta_id}|{it['data']}|{it['valor']:.2f}|{desc}|{it['ref']}"
            vistos[chave] = (
                vistos.get(chave, 0) + 1
            )  # mesmas compras no mesmo dia continuam distintas
            h = hashlib.sha1(f"{chave}|{vistos[chave]}".encode()).hexdigest()[:16]
            if h in existentes:
                continue
            m = re.search(r"\b(\d{1,2})/(\d{1,2})\b\s*$", it["descricao"]) or re.search(
                r"\bparc(?:ela)?\.?\s*(\d{1,2})\s*(?:/|de)\s*(\d{1,2})\b", it["descricao"], re.I
            )
            t = arm.criar(
                "transacoes",
                {
                    "data": it["data"],
                    "descricao": it["descricao"],
                    "valor": it["valor"],
                    "conta_id": conta_id,
                    "hash": h,
                    "parcela": f"{m.group(1)}/{m.group(2)}"
                    if m and int(m.group(1)) <= int(m.group(2))
                    else "",
                    "forma_pagamento": forma_pagamento(it["descricao"], conta["tipo"]),
                },
                gravar=False,
            )
            categorizar(arm, t, historico)
            novas.append(t)
        arm.salvar("transacoes")
    return {
        "ids": [t["id"] for t in novas],
        "lidas": len(itens),
        "importadas": len(novas),
        "duplicadas": len(itens) - len(novas),
        "sem_categoria": sum(1 for t in novas if not t["categoria_id"]),
    }


def aplicar_regras(arm: Armazem) -> int:
    with arm.trava:
        historico = _historico(arm)
        contas = {c["id"]: c["tipo"] for c in arm.todos("contas")}
        n = 0
        for t in arm.todos("transacoes"):
            # `credito` no cartão pode ter vindo da regra antiga (tudo do cartão era crédito)
            if not t.get("forma_pagamento") or t["forma_pagamento"] == "credito":
                t["forma_pagamento"] = forma_pagamento(
                    t["descricao"], contas.get(t["conta_id"], "")
                ) or t.get("forma_pagamento", "")
            if not t["categoria_id"] and categorizar(arm, t, historico):
                n += 1
        arm.salvar("transacoes")
        return n


# Sentido pelo texto, para os lançamentos sem arquivo original (importados antes de guardar a
# cópia).
_ENTRADA = re.compile(
    r"\brecebid|\bdeposito|\bsalario|\brendimento|\bresgate|\bestorno|\breembolso"
)
_SAIDA = re.compile(
    r"\benviad|\bcompra (no |com )?(cartao de )?debito|\bsaque|\bpagamento (de |efetuad)|\baplicac"
)


def corrigir(arm: Armazem, originais: dict[str, list[tuple[str, bytes]]]) -> dict[str, int]:
    """Conserta o que a importação antiga gravou errado na conta do cartão: ela invertia o sinal de
    tudo (Pix recebido virava gasto) e marcava tudo como `credito`. O sinal certo vem dos arquivos
    originais ([originais] por conta, relidos com a regra nova); sem original, do texto. O hash é
    refeito para a reimportação do mesmo arquivo continuar sem duplicar."""
    sinais = 0
    with arm.trava:
        cartoes = [c for c in arm.todos("contas") if c["tipo"] == "cartao"]
        for conta in cartoes:
            certos: dict[tuple[str, str, float], float] = {}
            for nome, conteudo in originais.get(conta["id"], []):
                try:
                    itens = ler_arquivo(nome, conteudo, "cartao")
                except Invalido:
                    continue  # PDF e layout estranho (lidos pela IA, sem inversão) ficam como estão
                for it in itens:
                    chave = (it["data"], normalizar(it["descricao"]), round(abs(it["valor"]), 2))
                    certos[chave] = it["valor"]
            vistos: dict[str, int] = {}
            for t in arm.todos("transacoes"):
                if t["conta_id"] != conta["id"] or not t["valor"]:
                    continue
                desc = normalizar(t["descricao"])
                certo = certos.get((t["data"], desc, round(abs(t["valor"]), 2)))
                if certo is None:
                    entrada = _ENTRADA.search(desc) and t["valor"] < 0
                    if entrada or (_SAIDA.search(desc) and t["valor"] > 0):
                        certo = -t["valor"]
                if certo is None or (certo > 0) == (t["valor"] > 0):
                    continue
                t["valor"] = certo
                chave = f"{conta['id']}|{t['data']}|{certo:.2f}|{desc}|"
                vistos[chave] = vistos.get(chave, 0) + 1
                t["hash"] = hashlib.sha1(f"{chave}|{vistos[chave]}".encode()).hexdigest()[:16]
                sinais += 1
        arm.salvar("transacoes")
    formas = sum(
        1 for t in arm.todos("transacoes") if t.get("forma_pagamento") == "credito"
    )
    categorizadas = aplicar_regras(arm)
    formas -= sum(1 for t in arm.todos("transacoes") if t.get("forma_pagamento") == "credito")
    return {"sinais": sinais, "formas": formas, "categorizadas": categorizadas}
