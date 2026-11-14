"""Dashboard numbers: month summary (income, expenses, budget, 50/30/20, personal indicators),
monthly cash flow, counterparty ranking, card bills, projection of the scheduled items and goal
progress. Convention: value > 0 comes in, value < 0 goes out; transfers stay out."""

import calendar
from collections import defaultdict
from datetime import date, timedelta
from typing import Any

from finance.warehouse import Invalid, Warehouse, data_iso


def _month(value: str) -> tuple[int, int]:
    try:
        a, m = value.split("-")[:2]
        year, month = int(a), int(m)
        if not 1 <= month <= 12:
            raise ValueError
        return year, month
    except ValueError as e:
        raise Invalid(f"Mês inválido: {value} (use AAAA-MM)") from e


def _add_up_months(year: int, month: int, n: int) -> tuple[int, int]:
    i = year * 12 + month - 1 + n
    return i // 12, i % 12 + 1


def _key(year: int, month: int) -> str:
    return f"{year:04d}-{month:02d}"


def _day(year: int, month: int, day: int) -> date:
    return date(year, month, min(max(day, 1), calendar.monthrange(year, month)[1]))


def _kinds(arm: Warehouse) -> dict[str, dict[str, Any]]:
    return {c["id"]: c for c in arm.todos("categorias")}


def _kind(t: dict[str, Any], cats: dict[str, dict[str, Any]]) -> str:
    """receita, despesa, investimento or transferencia; without a category the sign decides."""
    c = cats.get(t["categoria_id"])
    if c:
        return str(c["tipo"])
    return "receita" if t["valor"] > 0 else "despesa"


def _totals(
    transactions: list[dict[str, Any]], cats: dict[str, dict[str, Any]]
) -> dict[str, float]:
    tot = {"receitas": 0.0, "despesas": 0.0, "investimentos": 0.0}
    for t in transactions:
        kind = _kind(t, cats)
        if kind == "receita":
            tot["receitas"] += t["valor"]
        elif kind == "despesa":
            tot["despesas"] -= t["valor"]
        elif kind == "investimento":
            tot["investimentos"] -= t["valor"]
    tot["saldo"] = tot["receitas"] - tot["despesas"] - tot["investimentos"]
    return {k: round(v, 2) for k, v in tot.items()}


def _of_month(arm: Warehouse, year: int, month: int) -> list[dict[str, Any]]:
    p = _key(year, month)
    return [t for t in arm.todos("transacoes") if t["data"] and t["data"].startswith(p)]


def _pct(part: float, todo: float) -> float | None:
    return round(100 * part / todo, 1) if todo else None


def balances(arm: Warehouse) -> list[dict[str, Any]]:
    total: dict[str, float] = defaultdict(float)
    for t in arm.todos("transacoes"):
        total[t["conta_id"]] += t["valor"]
    return [
        {
            "id": c["id"],
            "nome": c["nome"],
            "tipo": c["tipo"],
            "limite": c["limite"],
            "saldo": round(c["saldo_inicial"] + total[c["id"]], 2),
        }
        for c in arm.todos("contas")
    ]


def summary(arm: Warehouse, month: str) -> dict[str, Any]:
    year, m = _month(month)
    cats = _kinds(arm)
    current = _of_month(arm, year, m)
    tot = _totals(current, cats)
    previous = _totals(_of_month(arm, *_add_up_months(year, m, -1)), cats)

    by_cat: dict[str, float] = defaultdict(float)
    for t in current:
        if _kind(t, cats) in ("despesa", "investimento", "receita"):
            by_cat[t["categoria_id"]] += t["valor"]
    categories = []
    for cid, value in by_cat.items():
        c = cats.get(
            cid,
            {
                "nome": "Sem categoria",
                "tipo": "receita" if value > 0 else "despesa",
                "orcamento_mensal": 0.0,
                "cor": "",
                "grupo": "",
            },
        )
        spent = abs(value)
        base = tot["receitas"] if c["tipo"] == "receita" else tot["despesas"] + tot["investimentos"]
        categories.append(
            {
                "id": cid,
                "nome": c["nome"],
                "tipo": c["tipo"],
                "cor": c["cor"],
                "valor": round(spent, 2),
                "pct": _pct(spent, base),
                "orcamento": c["orcamento_mensal"],
                "uso_orcamento": _pct(spent, c["orcamento_mensal"]),
            }
        )
    # categories with a budget and no spending also show up in the tracking
    for c in cats.values():
        if c["orcamento_mensal"] and c["id"] not in by_cat:
            categories.append(
                {
                    "id": c["id"],
                    "nome": c["nome"],
                    "tipo": c["tipo"],
                    "cor": c["cor"],
                    "valor": 0.0,
                    "pct": 0.0,
                    "orcamento": c["orcamento_mensal"],
                    "uso_orcamento": 0.0,
                }
            )
    categories.sort(key=lambda c: -c["valor"])

    groups = {"essencial": 0.0, "estilo": 0.0, "futuro": 0.0}
    for t in current:
        c = cats.get(t["categoria_id"])
        if c and c["grupo"] in groups and c["tipo"] in ("despesa", "investimento"):
            groups[c["grupo"]] -= t["valor"]

    today = date.today()
    days_month = calendar.monthrange(year, m)[1]
    days_passados = (
        days_month
        if (year, m) < (today.year, today.month)
        else (today.day if (year, m) == (today.year, today.month) else 0)
    )
    media_3 = (
        sum(
            _totals(_of_month(arm, *_add_up_months(year, m, -i)), cats)["despesas"]
            for i in range(1, 4)
        )
        / 3
    )
    accounts = balances(arm)
    liquidez = sum(
        c["saldo"] for c in accounts if c["tipo"] in ("corrente", "poupanca", "carteira")
    )
    investido = sum(c["saldo"] for c in accounts if c["tipo"] == "investimento")
    divida_cartao = -sum(c["saldo"] for c in accounts if c["tipo"] == "cartao" and c["saldo"] < 0)
    fixas = sum(
        -p["valor"]
        for p in arm.todos("programacoes")
        if p["ativa"] and p["valor"] < 0 and p["frequencia"] == "mensal"
    )
    spent_cartao = -sum(
        t["valor"]
        for t in current
        if t["valor"] < 0
        and any(c["id"] == t["conta_id"] and c["tipo"] == "cartao" for c in accounts)
    )
    pending = projection(arm, de=max(today, date(year, m, 1)), ate=date(year, m, days_month))

    maiores = sorted((t for t in current if _kind(t, cats) == "despesa"), key=lambda t: t["valor"])[
        :5
    ]
    return {
        "mes": _key(year, m),
        **tot,
        "anterior": previous,
        "variacao_despesas": _pct(tot["despesas"] - previous["despesas"], previous["despesas"]),
        "variacao_receitas": _pct(tot["receitas"] - previous["receitas"], previous["receitas"]),
        "categorias": categories,
        "regra_50_30_20": {
            k: {"valor": round(v, 2), "pct": _pct(v, tot["receitas"]), "ideal": i}
            for (k, v), i in zip(groups.items(), (50, 30, 20), strict=True)
        },
        "indicadores": {
            "taxa_poupanca": _pct(tot["receitas"] - tot["despesas"], tot["receitas"]),
            "comprometimento_despesas": _pct(tot["despesas"], tot["receitas"]),
            "taxa_investimento": _pct(tot["investimentos"], tot["receitas"]),
            "gasto_medio_diario": round(tot["despesas"] / days_passados, 2)
            if days_passados
            else None,
            "projecao_despesas_mes": round(tot["despesas"] / days_passados * days_month, 2)
            if days_passados
            else None,
            "despesa_media_3m": round(media_3, 2),
            "reserva_meses": round(liquidez / media_3, 1) if media_3 else None,
            "despesas_fixas": round(fixas, 2),
            "peso_fixas": _pct(fixas, tot["receitas"]),
            "gasto_cartao": round(spent_cartao, 2),
            "peso_cartao": _pct(spent_cartao, tot["receitas"]),
            "sem_categoria": sum(1 for t in current if not t["categoria_id"]),
        },
        "patrimonio": {
            "liquidez": round(liquidez, 2),
            "investido": round(investido, 2) + portfolio_value(arm),
            "dividas": round(divida_cartao, 2),
            "liquido": round(liquidez + investido + portfolio_value(arm) - divida_cartao, 2),
        },
        "contas": accounts,
        "maiores_despesas": maiores,
        "a_lancar": pending,
        "metas": goals(arm),
    }


def flow(arm: Warehouse, months: int = 12, ate: str | None = None) -> list[dict[str, Any]]:
    today = date.today()
    year, m = _month(ate) if ate else (today.year, today.month)
    cats = _kinds(arm)
    output = []
    acumulado = 0.0
    for i in range(months - 1, -1, -1):
        a, mm = _add_up_months(year, m, -i)
        tot = _totals(_of_month(arm, a, mm), cats)
        acumulado += tot["saldo"]
        output.append({"mes": _key(a, mm), **tot, "acumulado": round(acumulado, 2)})
    return output


def counterparts(
    arm: Warehouse, de: str | None, ate: str | None, limite: int = 15
) -> dict[str, Any]:
    cats = _kinds(arm)
    de, ate = (data_iso(de) if de else "0000"), (data_iso(ate) if ate else "9999")
    env: dict[str, list[float]] = defaultdict(lambda: [0.0, 0])
    rec: dict[str, list[float]] = defaultdict(lambda: [0.0, 0])
    for t in arm.todos("transacoes"):
        if not (de <= (t["data"] or "") <= ate) or _kind(t, cats) == "transferencia":
            continue
        name = t["contraparte"] or t["descricao"]
        target = rec if t["valor"] > 0 else env
        target[name][0] += abs(t["valor"])
        target[name][1] += 1

    def ranking(d: dict[str, list[float]]) -> list[dict[str, Any]]:
        total = sum(v[0] for v in d.values())
        items = sorted(d.items(), key=lambda kv: -kv[1][0])[:limite]
        return [
            {"nome": k, "valor": round(v[0], 2), "vezes": int(v[1]), "pct": _pct(v[0], total)}
            for k, v in items
        ]

    return {"enviado": ranking(env), "recebido": ranking(rec)}


def _invoice_of(day: date, closing: int) -> tuple[int, int]:
    """Bill month a purchase falls into: after the closing date it goes to next month's bill."""
    if closing and day.day > closing:
        return _add_up_months(day.year, day.month, 1)
    return day.year, day.month


def invoices(arm: Warehouse, account_id: str) -> dict[str, Any]:
    c = arm.obter("contas", account_id)
    if c["tipo"] != "cartao":
        raise Invalid("A conta não é um cartão de crédito")
    cats = _kinds(arm)
    by_month: dict[tuple[int, int], list[dict[str, Any]]] = defaultdict(list)
    for t in arm.todos("transacoes"):
        if t["conta_id"] == account_id and t["data"]:
            by_month[_invoice_of(date.fromisoformat(t["data"]), c["dia_fechamento"])].append(t)
    today = date.today()
    aberta = _invoice_of(today, c["dia_fechamento"])
    items = []
    for (a, m), itens in sorted(by_month.items(), reverse=True):
        gastos = -sum(
            t["valor"] for t in itens if t["valor"] < 0 and _kind(t, cats) != "transferencia"
        )
        pagos = sum(t["valor"] for t in itens if t["valor"] > 0)
        venc = None
        if c["dia_vencimento"]:
            va, vm = (
                (a, m) if c["dia_vencimento"] > c["dia_fechamento"] else _add_up_months(a, m, 1)
            )
            venc = _day(va, vm, c["dia_vencimento"]).isoformat()
        items.append(
            {
                "mes": _key(a, m),
                "total": round(gastos, 2),
                "pagamentos": round(pagos, 2),
                "vencimento": venc,
                "situacao": "aberta"
                if (a, m) == aberta
                else ("futura" if (a, m) > aberta else "fechada"),
                "itens": len(itens),
            }
        )
    used = (
        -sum(t["valor"] for t in arm.todos("transacoes") if t["conta_id"] == account_id)
        - c["saldo_inicial"]
    )
    return {
        "conta": c,
        "faturas": items,
        "limite": c["limite"],
        "usado": round(max(used, 0), 2),
        "disponivel": round(c["limite"] - max(used, 0), 2) if c["limite"] else None,
        "uso_limite": _pct(max(used, 0), c["limite"]),
    }


def _occurrences(p: dict[str, Any], de: date, ate: date) -> list[date]:
    if not p["inicio"] or not p["ativa"]:
        return []
    start = date.fromisoformat(p["inicio"])
    end = min(ate, date.fromisoformat(p["fim"])) if p["fim"] else ate
    datas: list[date] = []
    if p["frequencia"] == "unica":
        return [start] if de <= start <= end else []
    if p["frequencia"] == "semanal":
        d = start
        if d < de:
            d += timedelta(days=((de - d).days + 6) // 7 * 7)
        while d <= end:
            datas.append(d)
            d += timedelta(days=7)
        return datas
    step = 12 if p["frequencia"] == "anual" else 1
    n = 0
    while True:
        a, m = _add_up_months(start.year, start.month, n * step)
        d = _day(a, m, start.day)
        if d > end:
            return datas
        if d >= de:
            datas.append(d)
        n += 1


def projection(
    arm: Warehouse, de: date | None = None, ate: date | None = None, dias: int = 60
) -> list[dict[str, Any]]:
    """Occurrences of the scheduled items in the period that have not become entries yet."""
    de = de or date.today()
    ate = ate or de + timedelta(days=dias)
    lancadas = {
        (t["programacao_id"], t["data"]) for t in arm.todos("transacoes") if t["programacao_id"]
    }
    items = []
    for p in arm.todos("programacoes"):
        for d in _occurrences(p, de, ate):
            if (p["id"], d.isoformat()) not in lancadas:
                items.append(
                    {
                        "programacao_id": p["id"],
                        "data": d.isoformat(),
                        "descricao": p["descricao"],
                        "valor": p["valor"],
                        "conta_id": p["conta_id"],
                        "categoria_id": p["categoria_id"],
                    }
                )
    items.sort(key=lambda i: i["data"])
    return items


def projection_balance(arm: Warehouse, dias: int = 90) -> list[dict[str, Any]]:
    """Net balance (checking, savings and wallet accounts) day by day adding the scheduled items."""
    accounts = {c["id"]: c for c in arm.todos("contas")}
    liquidas = {i for i, c in accounts.items() if c["tipo"] in ("corrente", "poupanca", "carteira")}
    balance = sum(s["saldo"] for s in balances(arm) if s["id"] in liquidas)
    today = date.today()
    by_day: dict[str, float] = defaultdict(float)
    for i in projection(arm, de=today + timedelta(days=1), dias=dias):
        if i["conta_id"] in liquidas or not i["conta_id"]:
            by_day[i["data"]] += i["valor"]
    points = [{"data": today.isoformat(), "saldo": round(balance, 2)}]
    for n in range(1, dias + 1):
        d = (today + timedelta(days=n)).isoformat()
        if d in by_day:
            balance += by_day[d]
            points.append({"data": d, "saldo": round(balance, 2)})
    return points


def post(arm: Warehouse, programacao_id: str, data: str) -> dict[str, Any]:
    p = arm.obter("programacoes", programacao_id)
    return arm.criar(
        "transacoes",
        {
            "data": data,
            "descricao": p["descricao"],
            "valor": p["valor"],
            "conta_id": p["conta_id"],
            "categoria_id": p["categoria_id"],
            "contraparte": p["contraparte"],
            "programacao_id": p["id"],
        },
    )


def goals(arm: Warehouse) -> list[dict[str, Any]]:
    today = date.today()
    output = []
    for meta in arm.todos("metas"):
        aportes = 0.0
        if meta["categoria_id"]:
            aportes = -sum(
                t["valor"]
                for t in arm.todos("transacoes")
                if t["categoria_id"] == meta["categoria_id"]
            )
        current = meta["valor_inicial"] + aportes
        missing = max(meta["valor_alvo"] - current, 0)
        monthly = None
        if meta["prazo"] and missing:
            p = date.fromisoformat(meta["prazo"])
            months = (p.year - today.year) * 12 + p.month - today.month
            monthly = round(missing / months, 2) if months > 0 else round(missing, 2)
        output.append(
            {
                **meta,
                "atual": round(current, 2),
                "falta": round(missing, 2),
                "progresso": _pct(current, meta["valor_alvo"]),
                "aporte_mensal_necessario": monthly,
            }
        )
    return output


def portfolio_value(arm: Warehouse) -> float:
    from finance.analysis import portfolio  # evita import circular

    return float(portfolio(arm)["totais"]["valor_atual"])
