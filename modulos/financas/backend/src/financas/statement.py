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

from financas.warehouse import Warehouse, Invalid


def normalize(text: str) -> str:
    without_accent = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"\s+", " ", without_accent.lower()).strip()


# prefixos de extrato que não fazem parte do nome de quem recebeu/enviou
_PREFIXES = re.compile(
    r"(?:(?:pix|ted|doc|boleto|transf\w*|transferencia|pagamento|pagto|pag|pg|compra|debito|credito|cartao|"
    r"enviad[oa]|recebid[oa]|qrcode|qr code|no|em conta|automatico|de|para|a|o)\b|[-*:/])\s*",
)
_NOISE = re.compile(
    r"\b\d{2}/\d{2}(/\d{2,4})?\b|\b\d{2}:\d{2}\b|\b\d{6,}\b|\bparc(ela)? ?\d+/\d+\b"
)


def counterpart(description: str) -> str:
    """Melhor palpite de quem recebeu ou enviou o dinheiro (ex.: 'PIX ENVIADO Maria' → 'Maria')."""
    text = _NOISE.sub(" ", description)
    text = re.sub(r"\s+", " ", text).strip(" -*/")
    while (m := _PREFIXES.match(normalize(text))) and m.end():
        text = text[m.end() :]
    text = text.strip(" -*/")
    return text.title() if text.isupper() or text.islower() else text


def number_br(valor: str) -> float:
    v = valor.strip().replace("R$", "").replace(" ", "")
    negative = v.endswith("-") or (v.startswith("(") and v.endswith(")"))
    v = v.strip("()-+") if negative else v
    if "," in v:
        v = v.replace(".", "").replace(",", ".")
    n = float(v)
    return -n if negative else n


def _data(valor: str) -> str:
    v = valor.strip()[:10]
    for fmt in ("%d/%m/%Y", "%Y-%m-%d", "%d/%m/%y", "%d-%m-%Y", "%Y%m%d"):
        try:
            return datetime.strptime(v, fmt).date().isoformat()
        except ValueError:
            continue
    raise Invalid(f"Data inválida no arquivo: {valor}")


def read_ofx(text: str) -> list[dict[str, Any]]:
    items = []
    for block in re.findall(
        r"<STMTTRN>(.*?)(?:</STMTTRN>|(?=<STMTTRN>)|(?=</BANKTRANLIST>))", text, re.S | re.I
    ):

        def campo(nome: str, b: str = block) -> str:
            m = re.search(rf"<{nome}>([^<\r\n]*)", b, re.I)
            return m.group(1).strip() if m else ""

        data = campo("DTPOSTED")[:8]
        value = campo("TRNAMT").replace(",", ".")
        if not data or not value:
            continue
        description = campo("MEMO") or campo("NAME") or campo("TRNTYPE")
        items.append(
            {
                "data": date(int(data[:4]), int(data[4:6]), int(data[6:8])).isoformat(),
                "descricao": description,
                "valor": float(value),
                "ref": campo("FITID"),
            }
        )
    return items


# Cabeçalhos dos extratos dos bancos (já normalizados: minúsculas, sem acento). Exemplos:
# Nubank conta "Data,Valor,Identificador,Descrição"; Nubank cartão "date,title,amount";
# Inter "Data Lançamento;Histórico;Descrição;Valor;Saldo"; BB "Data;Lançamento;Detalhes;
# N° documento;Valor;Tipo Lançamento"; Mercado Pago "RELEASE_DATE;TRANSACTION_TYPE;REFERENCE_ID;
# TRANSACTION_NET_AMOUNT;PARTIAL_BALANCE"; Itaú (XLS) "data;lançamento;ag./origem;valor (R$)".
_COLUMNS = {
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
_NAO_ENTRY = re.compile(r"^(s ?a ?l ?d ?o|saldo|total|resumo)\b")


def _indexes(header: list[str]) -> dict[str, int]:
    idx: dict[str, int] = {}
    for key, names in _COLUMNS.items():
        for i, c in enumerate(header):
            if key == "complemento" and i == idx.get("descricao"):
                continue
            if c in names or any(c.startswith(n) for n in names if len(n) > 4):
                idx.setdefault(key, i)
    return idx


def _complete(idx: dict[str, int]) -> bool:
    return (
        "data" in idx
        and "descricao" in idx
        and bool({"valor"} & idx.keys() or {"credito", "debito"} <= idx.keys())
    )


def read_csv(text: str, fatura: bool = False) -> list[dict[str, Any]]:
    """CSV com cabeçalho; aceita `;` ou `,`, número 1.234,56 e data dd/mm/aaaa. Em [fatura] (cartão)
    os valores positivos são gastos e viram negativos."""
    sample = text[:2000]
    delim = ";" if sample.count(";") >= sample.count(",") / 2 and ";" in sample else ","
    lines = list(csv.reader(io.StringIO(text), delimiter=delim))
    # Inter e Mercado Pago põem conta, período e saldo antes do cabeçalho: procura a linha que tem
    # data, descrição e valor nas primeiras 40.
    start, idx = next(
        (
            (i, ix)
            for i, line in enumerate(lines[:40])
            if _complete(ix := _indexes([normalize(c) for c in line]))
        ),
        (-1, {}),
    )
    if start < 0:
        raise Invalid("CSV sem colunas reconhecidas (precisa de data, descrição e valor)")
    items = []
    for line in lines[start + 1 :]:
        if len(line) <= max(idx.values()) or not line[idx["data"]].strip():
            continue
        description = line[idx["descricao"]].strip()
        if (
            "complemento" in idx
            and (extra := line[idx["complemento"]].strip())
            and extra != description
        ):
            description = f"{description} - {extra}" if description else extra
        if not description or _NAO_ENTRY.match(normalize(description)):
            continue
        try:
            _data(line[idx["data"]])
        except Invalid:
            continue  # rodapé, subtotal ou linha de texto
        try:
            if "valor" in idx:
                value = number_br(line[idx["valor"]])
            else:
                cred = line[idx["credito"]].strip()
                deb = line[idx["debito"]].strip()
                value = (number_br(cred) if cred else 0) - (abs(number_br(deb)) if deb else 0)
        except ValueError:
            continue
        if (
            "sinal" in idx
            and value > 0
            and normalize(line[idx["sinal"]]) in ("saida", "debito", "d")
        ):
            value = -value
        items.append(
            {
                "data": _data(line[idx["data"]]),
                "descricao": description,
                "valor": -value if fatura else value,
                "ref": "",
            }
        )
    return items


def spreadsheet_to_csv(nome: str, content: bytes) -> str:
    """XLSX/XLS (Itaú, Mercado Pago, Inter exportam assim) → texto CSV com `;` para o [ler_csv]."""
    lines: list[list[Any]] = []
    if nome.lower().endswith(".xls"):
        import xlrd

        book = xlrd.open_workbook(file_contents=content)
        sheet = book.sheet_by_index(0)
        for r in range(sheet.nrows):
            line = []
            for c in sheet.row(r):
                if c.ctype == xlrd.XL_CELL_DATE:
                    line.append(xlrd.xldate_as_datetime(c.value, book.datemode).date())
                else:
                    line.append(c.value)
            lines.append(line)
    else:
        from openpyxl import load_workbook

        sheet = load_workbook(io.BytesIO(content), read_only=True, data_only=True).worksheets[0]
        lines = [list(r) for r in sheet.iter_rows(values_only=True)]

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

    return "\n".join(";".join(celula(v) for v in line) for line in lines)


def text_of_pdf(content: bytes) -> str:
    """Texto de um extrato em PDF (pdftotext, do poppler), mantendo as colunas alinhadas."""
    import subprocess
    import tempfile

    with tempfile.NamedTemporaryFile(suffix=".pdf") as f:
        f.write(content)
        f.flush()
        try:
            r = subprocess.run(
                ["pdftotext", "-layout", f.name, "-"], capture_output=True, timeout=60, check=True
            )
        except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
            raise Invalid(f"Não consegui ler o PDF ({e.__class__.__name__}).") from e
    text = r.stdout.decode("utf-8", "ignore")
    if not text.strip():
        raise Invalid("O PDF não tem texto (é imagem escaneada).")
    return text


_SHAPES = [
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


def shape_payment(description: str, account_kind: str = "") -> str:
    """Como o dinheiro entrou ou saiu, pelo texto do lançamento. O extrato de um banco digital
    mistura cartão, Pix e depósito mesmo na conta do cartão: o texto vale primeiro e só o que não
    diz nada vira `credito` no cartão."""
    d = normalize(description)
    shape = next((shape for shape, default in _SHAPES if re.search(default, d)), "")
    return shape or ("credito" if account_kind == "cartao" else "")


def _decode(content: bytes) -> str:
    for cod in ("utf-8-sig", "cp1252", "latin-1"):
        try:
            return content.decode(cod)
        except UnicodeDecodeError:
            continue
    return content.decode("utf-8", "ignore")


def rule_for(arm: Warehouse, description: str) -> dict[str, Any] | None:
    target = normalize(description)
    for r in sorted(arm.todos("regras"), key=lambda r: -r["prioridade"]):
        default = normalize(r["padrao"])
        if default and default in target:
            return r
    return None


def categorize(arm: Warehouse, t: dict[str, Any], historico: dict[str, str] | None = None) -> bool:
    """Preenche categoria e contraparte de [t] se estiverem vazias. Devolve se mudou algo."""
    mudou = False
    r = rule_for(arm, t["descricao"])
    if r:
        if not t["categoria_id"] and r["categoria_id"]:
            t["categoria_id"] = r["categoria_id"]
            mudou = True
        if not t["contraparte"] and r["contraparte"]:
            t["contraparte"] = r["contraparte"]
            mudou = True
    if not t["categoria_id"] and historico:
        cat = historico.get(normalize(t["descricao"]))
        if cat:
            t["categoria_id"] = cat
            mudou = True
    if not t["contraparte"]:
        t["contraparte"] = counterpart(t["descricao"])
        mudou = mudou or bool(t["contraparte"])
    return mudou


def _history(arm: Warehouse) -> dict[str, str]:
    return {
        normalize(t["descricao"]): t["categoria_id"]
        for t in arm.todos("transacoes")
        if t["categoria_id"]
    }


class NeedsAi(Invalid):
    """Formato que o código não lê (PDF, planilha ou CSV sem colunas conhecidas): o texto vai para a
    IA extrair os lançamentos."""

    def __init__(self, text: str, motivo: str) -> None:
        super().__init__(motivo)
        self.texto = text


def read_file(nome: str, content: bytes, account_kind: str) -> list[dict[str, Any]]:
    """Lançamentos do arquivo pelo formato; [PrecisaIA] quando só a IA consegue ler."""
    baixo = nome.lower()
    if baixo.endswith(".pdf"):
        raise NeedsAi(text_of_pdf(content), "PDF: a IA vai ler os lançamentos")
    if baixo.endswith((".xlsx", ".xls")):
        text = spreadsheet_to_csv(nome, content)
    else:
        text = _decode(content)
        if baixo.endswith((".ofx", ".qfx")) or "<OFX>" in text[:4000].upper():
            return read_ofx(text)
        if not baixo.endswith((".csv", ".txt")):
            raise Invalid("Formato não suportado: envie OFX, CSV, XLS/XLSX ou PDF")
    try:
        items = read_csv(text)
    except Invalid as e:
        raise NeedsAi(text, f"{e}: a IA vai ler os lançamentos") from e
    # Fatura traz os gastos positivos; extrato completo (Pix, depósito, cartão) já vem com sinal,
    # mesmo quando a conta escolhida é o cartão. Só inverte se a maioria for positiva.
    if account_kind == "cartao" and sum(i["valor"] > 0 for i in items) > len(items) / 2:
        for i in items:
            i["valor"] = -i["valor"]
    return items


def run_import(arm: Warehouse, nome: str, content: bytes, account_id: str) -> dict[str, Any]:
    account = arm.obter("contas", account_id)
    return write_entries(arm, read_file(nome, content, account["tipo"]), account_id)


def write_entries(arm: Warehouse, items: list[dict[str, Any]], account_id: str) -> dict[str, Any]:
    """Grava os lançamentos lidos sem duplicar (mesmo hash), com parcela, forma de pagamento,
    categoria e contraparte."""
    account = arm.obter("contas", account_id)
    with arm.trava:
        existentes = {t["hash"] for t in arm.todos("transacoes") if t["hash"]}
        history = _history(arm)
        seen: dict[str, int] = {}
        new = []
        for it in items:
            desc = normalize(it["descricao"])
            key = f"{account_id}|{it['data']}|{it['valor']:.2f}|{desc}|{it['ref']}"
            seen[key] = (
                seen.get(key, 0) + 1
            )  # mesmas compras no mesmo dia continuam distintas
            h = hashlib.sha1(f"{key}|{seen[key]}".encode()).hexdigest()[:16]
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
                    "conta_id": account_id,
                    "hash": h,
                    "parcela": f"{m.group(1)}/{m.group(2)}"
                    if m and int(m.group(1)) <= int(m.group(2))
                    else "",
                    "forma_pagamento": shape_payment(it["descricao"], account["tipo"]),
                },
                gravar=False,
            )
            categorize(arm, t, history)
            new.append(t)
        arm.salvar("transacoes")
    return {
        "ids": [t["id"] for t in new],
        "lidas": len(items),
        "importadas": len(new),
        "duplicadas": len(items) - len(new),
        "sem_categoria": sum(1 for t in new if not t["categoria_id"]),
    }


def apply_rules(arm: Warehouse) -> int:
    with arm.trava:
        history = _history(arm)
        accounts = {c["id"]: c["tipo"] for c in arm.todos("contas")}
        n = 0
        for t in arm.todos("transacoes"):
            # `credito` no cartão pode ter vindo da regra antiga (tudo do cartão era crédito)
            if not t.get("forma_pagamento") or t["forma_pagamento"] == "credito":
                t["forma_pagamento"] = shape_payment(
                    t["descricao"], accounts.get(t["conta_id"], "")
                ) or t.get("forma_pagamento", "")
            if not t["categoria_id"] and categorize(arm, t, history):
                n += 1
        arm.salvar("transacoes")
        return n


# Sentido pelo texto, para os lançamentos sem arquivo original (importados antes de guardar a
# cópia).
_INPUT = re.compile(
    r"\brecebid|\bdeposito|\bsalario|\brendimento|\bresgate|\bestorno|\breembolso"
)
_OUTPUT = re.compile(
    r"\benviad|\bcompra (no |com )?(cartao de )?debito|\bsaque|\bpagamento (de |efetuad)|\baplicac"
)


def fix(arm: Warehouse, originais: dict[str, list[tuple[str, bytes]]]) -> dict[str, int]:
    """Conserta o que a importação antiga gravou errado na conta do cartão: ela invertia o sinal de
    tudo (Pix recebido virava gasto) e marcava tudo como `credito`. O sinal certo vem dos arquivos
    originais ([originais] por conta, relidos com a regra nova); sem original, do texto. O hash é
    refeito para a reimportação do mesmo arquivo continuar sem duplicar."""
    sinais = 0
    with arm.trava:
        cartoes = [c for c in arm.todos("contas") if c["tipo"] == "cartao"]
        for account in cartoes:
            certos: dict[tuple[str, str, float], float] = {}
            for name, content in originais.get(account["id"], []):
                try:
                    items = read_file(name, content, "cartao")
                except Invalid:
                    continue  # PDF e layout estranho (lidos pela IA, sem inversão) ficam como estão
                for it in items:
                    key = (it["data"], normalize(it["descricao"]), round(abs(it["valor"]), 2))
                    certos[key] = it["valor"]
            seen: dict[str, int] = {}
            for t in arm.todos("transacoes"):
                if t["conta_id"] != account["id"] or not t["valor"]:
                    continue
                desc = normalize(t["descricao"])
                right = certos.get((t["data"], desc, round(abs(t["valor"]), 2)))
                if right is None:
                    entry = _INPUT.search(desc) and t["valor"] < 0
                    if entry or (_OUTPUT.search(desc) and t["valor"] > 0):
                        right = -t["valor"]
                if right is None or (right > 0) == (t["valor"] > 0):
                    continue
                t["valor"] = right
                key = f"{account['id']}|{t['data']}|{right:.2f}|{desc}|"
                seen[key] = seen.get(key, 0) + 1
                t["hash"] = hashlib.sha1(f"{key}|{seen[key]}".encode()).hexdigest()[:16]
                sinais += 1
        arm.salvar("transacoes")
    shapes = sum(
        1 for t in arm.todos("transacoes") if t.get("forma_pagamento") == "credito"
    )
    categorizadas = apply_rules(arm)
    shapes -= sum(1 for t in arm.todos("transacoes") if t.get("forma_pagamento") == "credito")
    return {"sinais": sinais, "formas": shapes, "categorizadas": categorizadas}
