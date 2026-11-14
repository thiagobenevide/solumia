"""Análise preditiva: o que acontece com o seu dinheiro se você comprar um bem (carro, terreno,
imóvel, Minha Casa Minha Vida) juntando antes ou financiando agora.

Tudo sai do extrato: a sobra mensal é a média recente de receitas menos despesas (com a tendência
dos últimos meses), descontadas as parcelas que ainda faltam pagar; a reserva é o saldo das contas
de dinheiro e investimento. Taxas e faixas padrão são referências de mercado (2025) e podem ser
trocadas no pedido.
"""

import re
from collections import defaultdict
from datetime import date
from typing import Any

from financas.warehouse import Warehouse
from financas.statement import normalize

# Referências (a.a.) quando o pedido não traz a taxa: financiamento de veículo usado, de terreno e
# imobiliário pelo SFH. Custo mensal extra do carro: IPVA (~4%) + seguro (~3%) ao ano sobre o valor.
RATE_DEFAULT = {
    "carro": 0.24,
    "moto": 0.26,
    "terreno": 0.15,
    "imovel": 0.115,
    "mcmv": 0.07,
    "outro": 0.20,
}
DEADLINE_DEFAULT = {"carro": 48, "moto": 36, "terreno": 120, "imovel": 360, "mcmv": 360, "outro": 24}
SYSTEM_DEFAULT = {
    "carro": "price",
    "moto": "price",
    "terreno": "price",
    "imovel": "sac",
    "mcmv": "sac",
}
EXTRA_YEARLY = {"carro": 0.07, "moto": 0.06}
INCOME_RESERVE = 0.0075  # ao mês, líquido (~CDI menos IR)
LIMIT_COMMITMENT = 0.30  # parcela + custos fixos do bem até 30% da renda

# Minha Casa Minha Vida (referência 2025; a Caixa confirma): renda bruta familiar mensal até, taxa
# de juros a.a. e valor máximo do imóvel.
BANDS_MCMV = [
    ("Faixa 1", 2850.0, 0.045, 264_000.0),
    ("Faixa 2", 4700.0, 0.065, 264_000.0),
    ("Faixa 3", 8600.0, 0.0816, 350_000.0),
    ("Faixa 4", 12000.0, 0.105, 500_000.0),
]


def _brl(v: float, casas: int = 2) -> str:
    """1673.08 → '1.673,08' (formato brasileiro nos textos)."""
    return f"{v:,.{casas}f}".replace(",", "_").replace(".", ",").replace("_", ".")


def _month(d: str) -> str:
    return d[:7]


def _add_up_months(month: str, n: int) -> str:
    a, m = int(month[:4]), int(month[5:7]) - 1 + n
    return f"{a + m // 12:04d}-{m % 12 + 1:02d}"


def _kinds(arm: Warehouse) -> dict[str, str]:
    return {c["id"]: c["tipo"] for c in arm.todos("categorias")}


def history_monthly(
    arm: Warehouse, months: int = 12, hoje: date | None = None
) -> list[dict[str, Any]]:
    """Receitas, despesas e investimentos dos últimos [meses] meses completos (sem o mês atual),
    fora as transferências entre contas."""
    hoje = hoje or date.today()
    current = hoje.isoformat()[:7]
    start = _add_up_months(current, -months)
    kinds = _kinds(arm)
    by_month: dict[str, dict[str, float]] = defaultdict(
        lambda: {"receitas": 0.0, "despesas": 0.0, "investimentos": 0.0}
    )
    for t in arm.todos("transacoes"):
        month = _month(t["data"] or "")
        if not (start <= month < current):
            continue
        kind = kinds.get(t["categoria_id"], "")
        if kind == "transferencia":
            continue
        if kind == "investimento":
            by_month[month]["investimentos"] += -t["valor"]
        elif t["valor"] > 0:
            by_month[month]["receitas"] += t["valor"]
        else:
            by_month[month]["despesas"] += -t["valor"]
    output = []
    for i in range(months):
        month = _add_up_months(start, i)
        v = by_month.get(month)
        if v is None:
            continue  # mês sem extrato importado não conta como mês zerado
        output.append(
            {
                "mes": month,
                **{k: round(x, 2) for k, x in v.items()},
                "sobra": round(v["receitas"] - v["despesas"], 2),
            }
        )
    return output


def _trend(values: list[float]) -> float:
    """Inclinação (por mês) da reta de mínimos quadrados."""
    n = len(values)
    if n < 3:
        return 0.0
    mx, my = (n - 1) / 2, sum(values) / n
    num = sum((i - mx) * (v - my) for i, v in enumerate(values))
    den = sum((i - mx) ** 2 for i in range(n))
    return num / den if den else 0.0


_INSTALLMENT = re.compile(r"\s*\b(?:parc(?:ela)?\.?\s*)?\d{1,2}\s*(?:/|de)\s*\d{1,2}\b\s*", re.I)


def installment_plans(arm: Warehouse, hoje: date | None = None) -> list[dict[str, Any]]:
    """Compras parceladas pelo `parcela` n/m dos lançamentos: quanto já foi, quanto falta e até
    quando."""
    hoje = hoje or date.today()
    groups: dict[tuple[str, str, float], list[dict[str, Any]]] = defaultdict(list)
    for t in arm.todos("transacoes"):
        if not t.get("parcela") or "/" not in t["parcela"]:
            continue
        base = normalize(_INSTALLMENT.sub(" ", t["descricao"])).strip()
        groups[(t["conta_id"], base, round(abs(t["valor"]), 2))].append(t)
    output = []
    for (account_id, _, value), ts in groups.items():
        n, total = (
            int(x)
            for x in max(ts, key=lambda t: int(t["parcela"].split("/")[0]))["parcela"].split("/")
        )
        last = max(t["data"] for t in ts)
        restantes = max(0, total - n)
        end = _add_up_months(_month(last), restantes)
        primeira = min(ts, key=lambda t: t["data"])
        output.append(
            {
                "descricao": _INSTALLMENT.sub(" ", primeira["descricao"]).strip(),
                "conta_id": account_id,
                "valor_parcela": value,
                "parcelas": total,
                "pagas": n,
                "restantes": restantes,
                "valor_total": round(value * total, 2),
                "valor_restante": round(value * restantes, 2),
                "ultima": last,
                "termina": end,
                "ativo": restantes > 0 and end >= hoje.isoformat()[:7],
            }
        )
    return sorted(output, key=lambda p: (not p["ativo"], p["termina"]))


def _installments_by_month(parcs: list[dict[str, Any]], month_inicial: str, months: int) -> list[float]:
    """Quanto das parcelas em aberto cai em cada um dos próximos [meses]."""
    output = [0.0] * months
    for p in parcs:
        if not p["ativo"]:
            continue
        for i in range(months):
            month = _add_up_months(month_inicial, i)
            if _month(p["ultima"]) < month <= p["termina"]:
                output[i] += p["valor_parcela"]
    return output


def reserve_current(arm: Warehouse) -> float:
    """Saldo das contas de dinheiro e investimento (corrente, poupança, carteira, investimento)."""
    accounts = {
        c["id"]: c for c in arm.todos("contas") if c["tipo"] != "cartao" and c.get("ativa", True)
    }
    balance = {i: c["saldo_inicial"] for i, c in accounts.items()}
    for t in arm.todos("transacoes"):
        if t["conta_id"] in balance:
            balance[t["conta_id"]] += t["valor"]
    return round(max(0.0, sum(balance.values())), 2)


def financing(
    valor: float, rate_yearly: float, months: int, system: str = "price"
) -> dict[str, Any]:
    """Parcelas pela tabela Price (fixas) ou SAC (amortização fixa, parcela caindo)."""
    i = (1 + rate_yearly) ** (1 / 12) - 1
    installments = []
    if valor <= 0 or months <= 0:
        return {
            "taxa_mensal": i,
            "parcelas": [],
            "primeira": 0.0,
            "ultima": 0.0,
            "total": 0.0,
            "juros": 0.0,
        }
    if system == "sac":
        amort = valor / months
        balance = valor
        for _ in range(months):
            installments.append(amort + balance * i)
            balance -= amort
    else:
        pmt = valor / months if i == 0 else valor * i / (1 - (1 + i) ** -months)
        installments = [pmt] * months
    total = sum(installments)
    return {
        "taxa_mensal": round(i, 6),
        "parcelas": [round(p, 2) for p in installments],
        "primeira": round(installments[0], 2),
        "ultima": round(installments[-1], 2),
        "total": round(total, 2),
        "juros": round(total - valor, 2),
    }


def band_mcmv(renda: float) -> dict[str, Any] | None:
    for name, cap, rate, imovel in BANDS_MCMV:
        if renda <= cap:
            return {
                "faixa": name,
                "renda_maxima": cap,
                "taxa_anual": rate,
                "imovel_maximo": imovel,
            }
    return None


def _months_to_join(
    target: float, reserve: float, leftovers: list[float], income: float = INCOME_RESERVE
) -> int | None:
    """Mês (1, 2, …) em que a reserva, rendendo e recebendo cada sobra, chega no [alvo]."""
    balance = reserve
    if balance >= target:
        return 0
    for month, leftover in enumerate(leftovers, start=1):
        balance = balance * (1 + income) + leftover
        if balance >= target:
            return month
    return None


def simulate(arm: Warehouse, p: dict[str, Any], hoje: date | None = None) -> dict[str, Any]:
    """Compra de um bem: juntar e pagar à vista × financiar agora, sobre a sua realidade do extrato.

    [p]: `valor` (obrigatório), `tipo` (carro|moto|terreno|imovel|mcmv|outro), `descricao`,
    `entrada`, `prazo_meses`, `taxa_anual`, `sistema` (price|sac), `custo_mensal_extra`,
    `renda_mensal`, `reserva`, `aporte_mensal` (sobra que você topa guardar; padrão: a sobra
    média)."""
    hoje = hoje or date.today()
    kind = p.get("tipo") or "outro"
    value = float(p["valor"])
    history = history_monthly(arm, 12, hoje)
    recent = history[-6:] or history
    renda = float(
        p.get("renda_mensal")
        or (sum(m["receitas"] for m in recent) / len(recent) if recent else 0)
    )
    leftover_media = sum(m["sobra"] for m in recent) / len(recent) if recent else 0.0
    trend = _trend([m["sobra"] for m in history])
    reserve = float(p["reserva"]) if p.get("reserva") is not None else reserve_current(arm)
    entry = min(float(p.get("entrada") or 0), value)

    mcmv = None
    rate_default = RATE_DEFAULT.get(kind, RATE_DEFAULT["outro"])
    if kind == "mcmv":
        mcmv = band_mcmv(renda)
        if mcmv:
            rate_default = mcmv["taxa_anual"]
    rate = float(p.get("taxa_anual") or rate_default)
    deadline = int(p.get("prazo_meses") or DEADLINE_DEFAULT.get(kind, 24))
    system = p.get("sistema") or SYSTEM_DEFAULT.get(kind, "price")
    extra = float(
        p["custo_mensal_extra"]
        if p.get("custo_mensal_extra") is not None
        else value * EXTRA_YEARLY.get(kind, 0) / 12
    )

    horizonte = min(480, max(deadline, 36) + 12)
    month0 = _add_up_months(hoje.isoformat()[:7], 1)
    parcs = installment_plans(arm, hoje)
    compromissos = _installments_by_month(parcs, month0, horizonte)
    # Sobra prevista: média recente + metade da tendência (amortecida, para não extrapolar demais),
    # mais o que as parcelas que vão acabando liberam em relação a hoje.
    today_installments = compromissos[0] if compromissos else 0.0
    aporte = p.get("aporte_mensal")
    leftovers = [
        (float(aporte) if aporte is not None else leftover_media + trend * 0.5 * min(i, 12))
        + (today_installments - compromissos[i])
        for i in range(horizonte)
    ]

    # Rendimento da reserva: o do pedido (ex.: CDI atual, líquido) ou a referência fixa.
    income = float(p.get("rendimento_mensal") or INCOME_RESERVE)
    # A) juntar e comprar à vista
    months_join = _months_to_join(value, reserve, leftovers, income)
    # B) financiar agora (a entrada sai da reserva)
    financiado = value - entry
    fin = financing(financiado, rate, deadline, system)
    commitment = (fin["primeira"] + extra) / renda if renda > 0 else None
    input_fits = entry <= reserve

    base, join, financiar = [], [], []
    s_base = s_join = reserve
    s_fin = reserve - entry
    for i in range(horizonte):
        s_base = s_base * (1 + income) + leftovers[i]
        s_join = s_join * (1 + income) + leftovers[i]
        if months_join is not None and i + 1 == max(months_join, 1):
            s_join -= value
        if months_join is not None and i + 1 > max(months_join, 1):
            s_join -= extra
        installment = fin["parcelas"][i] if i < len(fin["parcelas"]) else 0.0
        s_fin = s_fin * (1 + income) + leftovers[i] - installment - extra
        month = _add_up_months(month0, i)
        base.append({"mes": month, "saldo": round(s_base, 2)})
        join.append({"mes": month, "saldo": round(s_join, 2)})
        financiar.append({"mes": month, "saldo": round(s_fin, 2), "parcela": round(installment, 2)})
    negative_fin = next((x["mes"] for x in financiar if x["saldo"] < 0), None)

    alerts = []
    if leftover_media <= 0:
        alerts.append(
            "Nos últimos meses você gastou mais do que ganhou: sem sobra, não dá para juntar."
        )
    if commitment is not None and commitment > LIMIT_COMMITMENT:
        alerts.append(
            f"Parcela + custos do bem comprometem {commitment:.0%} da renda "
            "(o recomendado é até 30%)."
        )
    cost_monthly = fin["primeira"] + extra
    if financiado > 0 and cost_monthly > max(leftover_media, 0) + today_installments:
        alerts.append(
            f"Parcela + custos do bem (R$ {_brl(cost_monthly, 2)}/mês) passam da sua sobra mensal "
            f"(R$ {_brl(max(leftover_media, 0), 2)})."
        )
    if not input_fits:
        alerts.append(
            f"A entrada (R$ {_brl(entry, 2)}) é maior que a sua reserva atual "
            f"(R$ {_brl(reserve, 2)})."
        )
    if negative_fin:
        alerts.append(f"Financiando, seu saldo fica negativo a partir de {negative_fin}.")
    if entry < value * 0.2 and kind in ("carro", "moto", "imovel", "terreno"):
        alerts.append(
            "Entrada abaixo de 20% do valor: juros sobre quase tudo; juntar uma entrada maior "
            "reduz o custo."
        )
    if kind == "mcmv":
        if mcmv is None:
            alerts.append("Pela renda média, você passa da Faixa 4 do Minha Casa Minha Vida.")
        elif value > mcmv["imovel_maximo"]:
            alerts.append(
                f"O imóvel passa do teto da {mcmv['faixa']} (R$ {_brl(mcmv['imovel_maximo'], 0)})."
            )

    # Compensa financiar? Paga os juros para antecipar a compra em `meses_juntar` meses; cabe no
    # orçamento se a parcela + custos não passam da sobra nem de 30% da renda.
    fits = (
        commitment is not None
        and commitment <= LIMIT_COMMITMENT
        and fin["primeira"] + extra <= max(leftover_media, 0) + today_installments
        and input_fits
        and negative_fin is None
    )
    if months_join == 0:
        verdict = "Você já tem o valor: comprar à vista evita todos os juros."
    elif not fits:
        verdict = (
            "Financiar não cabe no seu orçamento hoje; o caminho é juntar (ou aumentar a entrada)."
        )
    elif months_join is not None and months_join <= 12:
        verdict = (
            f"Compensa juntar: em {months_join} meses você compra à vista e economiza "
            f"R$ {_brl(fin['juros'], 2)} de juros."
        )
    else:
        verdict = (
            f"Financiar cabe, mas custa R$ {_brl(fin['juros'], 2)} de juros para antecipar a compra"
            + (f" em {months_join} meses." if months_join else ".")
        )

    # Alternativa: usar a reserva como entrada, guardando 3 meses de despesas como emergência.
    despesa_media = sum(m["despesas"] for m in recent) / len(recent) if recent else 0.0
    emergencia = round(3 * despesa_media, 2)
    input_reserve = round(min(value, max(0.0, reserve - emergencia)), 2)
    with_reserve = None
    if input_reserve > entry and input_reserve < value:
        fin2 = financing(value - input_reserve, rate, deadline, system)
        cost2 = fin2["primeira"] + extra
        with_reserve = {
            "entrada": input_reserve,
            "emergencia_guardada": emergencia,
            "valor_financiado": round(value - input_reserve, 2),
            **{k: v for k, v in fin2.items() if k != "parcelas"},
            "cabe": cost2 <= max(leftover_media, 0) + today_installments
            and (renda <= 0 or cost2 / renda <= LIMIT_COMMITMENT),
        }

    return {
        "financiar_com_reserva": with_reserve,
        "pedido": {
            "descricao": p.get("descricao") or "",
            "tipo": kind,
            "valor": value,
            "entrada": entry,
            "prazo_meses": deadline,
            "taxa_anual": rate,
            "sistema": system,
            "custo_mensal_extra": round(extra, 2),
            "rendimento_mensal": round(income, 5),
        },
        "realidade": {
            "renda_media": round(renda, 2),
            "sobra_media": round(leftover_media, 2),
            "tendencia_mensal": round(trend, 2),
            "reserva": reserve,
            "parcelas_em_aberto": round(today_installments, 2),
            "meses_de_historico": len(history),
            "historico": history,
        },
        "juntar": {
            "meses": months_join,
            "data": _add_up_months(hoje.isoformat()[:7], months_join)
            if months_join is not None
            else None,
            "aporte_mensal": round(leftovers[0], 2) if leftovers else 0.0,
        },
        "financiar": {
            **{k: v for k, v in fin.items() if k != "parcelas"},
            "valor_financiado": round(financiado, 2),
            "comprometimento": round(commitment, 4) if commitment is not None else None,
            "cabe": fits,
        },
        "mcmv": mcmv,
        "veredito": verdict,
        "alertas": alerts,
        "projecao": {"sem_compra": base, "juntar": join, "financiar": financiar},
        "parcelamentos": [x for x in parcs if x["ativo"]],
    }
