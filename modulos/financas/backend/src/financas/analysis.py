"""Análise de empresas: indicadores por ano a partir dos demonstrativos (DRE, balanço e fluxo de
caixa, em R$ mil ou na unidade que o usuário preferir, desde que seja a mesma em todos), análise
vertical e horizontal da DRE, nota do questionário e checagens automáticas, que juntas dão o
veredito de aporte. Também a carteira: posições, preço médio, resultado e proventos a partir das
operações."""

from collections import defaultdict
from typing import Any

from financas.warehouse import Warehouse, Invalid
from financas.patterns import FIT, WATCH

# contas aceitas em cada ano de `demonstrativos`
ACCOUNTS = [
    # DRE
    "receita_liquida",
    "custo",
    "lucro_bruto",
    "despesas_operacionais",
    "ebit",
    "depreciacao",
    "resultado_financeiro",
    "lucro_antes_ir",
    "ir_csll",
    "lucro_liquido",
    # balanço
    "ativo_total",
    "ativo_circulante",
    "caixa",
    "passivo_circulante",
    "divida_bruta",
    "patrimonio_liquido",
    # fluxo de caixa e acionistas
    "fco",
    "capex",
    "dividendos",
    "acoes",
]
DRE_VERTICAL = [
    "receita_liquida",
    "custo",
    "lucro_bruto",
    "despesas_operacionais",
    "ebit",
    "resultado_financeiro",
    "lucro_antes_ir",
    "ir_csll",
    "lucro_liquido",
]


def _div(a: float | None, b: float | None, scale: float = 1) -> float | None:
    if a is None or not b:
        return None
    return round(a / b * scale, 2)


def clean_statements(items: list[Any]) -> list[dict[str, Any]]:
    years = {}
    for d in items:
        if not isinstance(d, dict) or "ano" not in d:
            raise Invalid("Cada demonstrativo precisa do ano")
        try:
            year = int(d["ano"])
            line: dict[str, Any] = {"ano": year}
            for c in ACCOUNTS:
                v = d.get(c)
                line[c] = None if v in (None, "") else float(v)
        except (TypeError, ValueError) as e:
            raise Invalid(f"Valor inválido no ano {d.get('ano')}") from e
        years[year] = line
    return [years[a] for a in sorted(years)]


def _complete(d: dict[str, Any]) -> dict[str, Any]:
    """Deriva o que faltar (lucro bruto, EBIT) quando dá para calcular."""
    d = dict(d)
    if d["lucro_bruto"] is None and d["receita_liquida"] is not None and d["custo"] is not None:
        d["lucro_bruto"] = d["receita_liquida"] - abs(d["custo"])
    if (
        d["ebit"] is None
        and d["lucro_bruto"] is not None
        and d["despesas_operacionais"] is not None
    ):
        d["ebit"] = d["lucro_bruto"] - abs(d["despesas_operacionais"])
    return d


def indicators_year(
    d: dict[str, Any], ant: dict[str, Any] | None, company: dict[str, Any]
) -> dict[str, Any]:
    d = _complete(d)
    rec, ll, pl = d["receita_liquida"], d["lucro_liquido"], d["patrimonio_liquido"]
    ebitda = d["ebit"] + abs(d["depreciacao"] or 0) if d["ebit"] is not None else None
    div_liq = d["divida_bruta"] - (d["caixa"] or 0) if d["divida_bruta"] is not None else None
    fcl = d["fco"] - abs(d["capex"] or 0) if d["fco"] is not None else None
    nopat = d["ebit"] * 0.66 if d["ebit"] is not None else None
    capital = (pl or 0) + (div_liq or 0)
    actions = d["acoes"] or company["acoes"] or None
    i: dict[str, Any] = {
        "ano": d["ano"],
        "ebitda": ebitda,
        "divida_liquida": div_liq,
        "fcl": fcl,
        "margem_bruta": _div(d["lucro_bruto"], rec, 100),
        "margem_ebit": _div(d["ebit"], rec, 100),
        "margem_ebitda": _div(ebitda, rec, 100),
        "margem_liquida": _div(ll, rec, 100),
        "roe": _div(ll, pl, 100),
        "roa": _div(ll, d["ativo_total"], 100),
        "roic": _div(nopat, capital, 100) if capital > 0 else None,
        "giro_ativo": _div(rec, d["ativo_total"]),
        "liquidez_corrente": _div(d["ativo_circulante"], d["passivo_circulante"]),
        "divida_liquida_ebitda": _div(div_liq, ebitda),
        "divida_liquida_pl": _div(div_liq, pl),
        "payout": _div(d["dividendos"], ll, 100),
        "conversao_caixa": _div(d["fco"], ll, 100),
        "lpa": _div(ll, actions),
        "vpa": _div(pl, actions),
        "cresc_receita": None,
        "cresc_lucro": None,
    }
    # Banco e seguradora (plano da CVM sem ativo/passivo circulante): EBITDA, margem bruta, ROIC
    # e dívida/EBITDA não têm sentido; o que vale é ROE, P/L, P/VP e dividendos.
    sector = str(company.get("setor") or "").lower()
    i["financeira"] = d["ativo_circulante"] is None and any(
        s in sector for s in ("banco", "intermedia", "segurad", "arrendamento")
    )
    if i["financeira"] and rec is not None:
        for k in ("ebitda", "fcl", "margem_bruta", "margem_ebit", "margem_ebitda", "roic"):
            i[k] = None
        i["divida_liquida_ebitda"] = i["giro_ativo"] = None
    if ant:
        a = _complete(ant)
        if a["receita_liquida"]:
            i["cresc_receita"] = _div(
                (rec or 0) - a["receita_liquida"], abs(a["receita_liquida"]), 100
            )
        if a["lucro_liquido"]:
            i["cresc_lucro"] = _div((ll or 0) - a["lucro_liquido"], abs(a["lucro_liquido"]), 100)
    return i


def _cagr(primeiro: float | None, last: float | None, years: int) -> float | None:
    if not primeiro or not last or primeiro <= 0 or last <= 0 or years <= 0:
        return None
    return round(((last / primeiro) ** (1 / years) - 1) * 100, 2)


def valuation(
    company: dict[str, Any], ult: dict[str, Any] | None, ind: dict[str, Any] | None
) -> dict[str, Any]:
    preco = company["cotacao"] or None
    actions = (ult or {}).get("acoes") or company["acoes"] or None
    mcap = preco * actions if preco and actions else None
    ev = mcap + (ind["divida_liquida"] or 0) if mcap is not None and ind else None
    v: dict[str, Any] = {
        "cotacao": preco,
        "valor_mercado": round(mcap, 2) if mcap else None,
        "ev": round(ev, 2) if ev else None,
        "pl": _div(preco, ind["lpa"]) if ind else None,
        "pvp": _div(preco, ind["vpa"]) if ind else None,
        "ev_ebitda": _div(ev, ind["ebitda"]) if ind else None,
        "ev_ebit": _div(ev, (ult or {}).get("ebit")) if ind else None,
        "psr": _div(mcap, (ult or {}).get("receita_liquida")),
        "dy": _div((ult or {}).get("dividendos"), mcap, 100),
        "fcl_yield": _div(ind["fcl"], mcap, 100) if ind else None,
    }
    lpa, vpa = (ind or {}).get("lpa"), (ind or {}).get("vpa")
    # Graham: raiz(22,5 · LPA · VPA); Bazin: dividendo por ação / 6%
    v["preco_graham"] = (
        round((22.5 * lpa * vpa) ** 0.5, 2) if lpa and vpa and lpa > 0 and vpa > 0 else None
    )
    dpa = _div((ult or {}).get("dividendos"), actions)
    v["preco_bazin"] = round(dpa / 0.06, 2) if dpa else None
    v["preco_teto"] = company["preco_teto"] or None
    v["margem_seguranca"] = _div(
        (company["preco_teto"] - preco) if company["preco_teto"] and preco else None,
        company["preco_teto"],
        100,
    )
    return v


def summary_card(dem: list[dict[str, Any]], preco: float | None, sector: str = "") -> dict[str, Any]:
    """Indicadores por ano, valuation e crescimento da ficha do Mercado (sem empresa cadastrada:
    só os demonstrativos da CVM e a cotação do dia)."""
    dem = clean_statements(dem)
    if not dem:
        return {"indicadores": [], "valuation": {}, "cagr_receita": None, "cagr_lucro": None}
    serie = [
        indicators_year(d, dem[i - 1] if i else None, {"acoes": 0, "setor": sector})
        for i, d in enumerate(dem)
    ]
    val = valuation({"cotacao": preco or 0, "acoes": 0, "preco_teto": 0}, dem[-1], serie[-1])
    years = len(dem) - 1
    return {
        "indicadores": serie,
        "valuation": val,
        "cagr_receita": _cagr(dem[0]["receita_liquida"], dem[-1]["receita_liquida"], years),
        "cagr_lucro": _cagr(dem[0]["lucro_liquido"], dem[-1]["lucro_liquido"], years),
    }


def run_checks(serie: list[dict[str, Any]], val: dict[str, Any]) -> list[dict[str, Any]]:
    """Regras objetivas de qualidade e preço; `ok` None quando faltam dados."""
    ult = serie[-1] if serie else {}
    ult5 = serie[-5:]

    def regra(nome: str, ok: bool | None, valor: Any = None) -> dict[str, Any]:
        return {"nome": nome, "ok": ok, "valor": valor}

    def todos(field: str, cond: Any) -> bool | None:
        vals = [s[field] for s in ult5 if s[field] is not None]
        return all(cond(v) for v in vals) if len(vals) >= 2 else None

    roe, ml, dle, lc = (
        ult.get("roe"),
        ult.get("margem_liquida"),
        ult.get("divida_liquida_ebitda"),
        ult.get("liquidez_corrente"),
    )
    return [
        regra("ROE acima de 15%", None if roe is None else roe >= 15, roe),
        regra("Margem líquida acima de 10%", None if ml is None else ml >= 10, ml),
        regra("Dívida líquida/EBITDA abaixo de 2,5", None if dle is None else dle <= 2.5, dle),
        regra("Liquidez corrente acima de 1", None if lc is None else lc >= 1, lc),
        regra("Lucro positivo em todos os últimos anos", todos("margem_liquida", lambda v: v > 0)),
        regra(
            "Receita crescendo na maioria dos anos",
            None
            if len([s for s in ult5 if s["cresc_receita"] is not None]) < 2
            else sum(1 for s in ult5 if (s["cresc_receita"] or 0) > 0) * 2
            > len([s for s in ult5 if s["cresc_receita"] is not None]),
        ),
        regra(
            "Lucro vira caixa (FCO ≥ 80% do lucro)",
            None if ult.get("conversao_caixa") is None else ult["conversao_caixa"] >= 80,
            ult.get("conversao_caixa"),
        ),
        regra("P/L entre 0 e 15", None if val["pl"] is None else 0 < val["pl"] <= 15, val["pl"]),
        regra("P/VP abaixo de 2", None if val["pvp"] is None else val["pvp"] <= 2, val["pvp"]),
        regra(
            "Dividend yield acima de 5%", None if val["dy"] is None else val["dy"] >= 5, val["dy"]
        ),
        regra(
            "Preço abaixo do preço teto",
            None if val["margem_seguranca"] is None else val["margem_seguranca"] >= 0,
            val["margem_seguranca"],
        ),
    ]


def note_questionnaire(
    perguntas: list[dict[str, Any]], respostas: dict[str, Any], target: str
) -> dict[str, Any]:
    valid = [p for p in perguntas if p["alvo"] == target]
    points = total = 0.0
    blocks: dict[str, list[float]] = defaultdict(lambda: [0.0, 0.0])
    respondidas = 0
    for p in valid:
        r = respostas.get(p["id"])
        if r is None:
            continue
        note = min(max(float(r), 0), 5)
        respondidas += 1
        points += note * p["peso"]
        total += 5 * p["peso"]
        blocks[p["bloco"]][0] += note * p["peso"]
        blocks[p["bloco"]][1] += 5 * p["peso"]
    return {
        "nota": round(100 * points / total, 1) if total else None,
        "respondidas": respondidas,
        "total": len(valid),
        "blocos": {b: round(100 * v[0] / v[1], 1) if v[1] else None for b, v in blocks.items()},
    }


def verdict(note: float | None) -> str:
    if note is None:
        return "sem dados"
    return "apta para aporte" if note >= FIT else ("observar" if note >= WATCH else "evitar")


def analyze(arm: Warehouse, company: dict[str, Any]) -> dict[str, Any]:
    dem = clean_statements(company["demonstrativos"])
    serie = [indicators_year(d, dem[i - 1] if i else None, company) for i, d in enumerate(dem)]
    ult_d = dem[-1] if dem else None
    ult_i = serie[-1] if serie else None
    val = valuation(company, ult_d, ult_i)
    checks = run_checks(serie, val)
    avaliadas = [c for c in checks if c["ok"] is not None]
    note_auto = (
        round(100 * sum(1 for c in avaliadas if c["ok"]) / len(avaliadas), 1) if avaliadas else None
    )

    perguntas = arm.questionnaire()
    quest = note_questionnaire(perguntas, company["respostas"], "empresa")
    sector = next(
        (s for s in arm.todos("setores") if s["nome"].lower() == company["setor"].lower()), None
    )
    quest_sector = note_questionnaire(perguntas, sector["respostas"], "setor") if sector else None

    # pesos: questionário da empresa 50%, indicadores 30%, setor 20% (redistribui o que faltar)
    parts = [
        (quest["nota"], 0.5),
        (note_auto, 0.3),
        (quest_sector["nota"] if quest_sector else None, 0.2),
    ]
    weight = sum(p for n, p in parts if n is not None)
    final = round(sum(n * p for n, p in parts if n is not None) / weight, 1) if weight else None

    vertical = [
        {
            "ano": d["ano"],
            **{c: _div(_complete(d)[c], d["receita_liquida"], 100) for c in DRE_VERTICAL},
        }
        for d in dem
    ]
    years = len(dem) - 1
    return {
        "empresa": company,
        "contas": ACCOUNTS,
        "demonstrativos": dem,
        "indicadores": serie,
        "vertical": vertical,
        "valuation": val,
        "cagr_receita": _cagr(dem[0]["receita_liquida"], dem[-1]["receita_liquida"], years)
        if dem
        else None,
        "cagr_lucro": _cagr(dem[0]["lucro_liquido"], dem[-1]["lucro_liquido"], years)
        if dem
        else None,
        "checagens": checks,
        "nota_indicadores": note_auto,
        "questionario": quest,
        "setor": {"id": sector["id"], "nome": sector["nome"], **(quest_sector or {})}
        if sector
        else None,
        "nota_final": final,
        "veredito": verdict(final),
    }


def ranking(arm: Warehouse) -> list[dict[str, Any]]:
    output = []
    for e in arm.todos("empresas"):
        try:
            a = analyze(arm, e)
        except Invalid:
            continue
        ult = a["indicadores"][-1] if a["indicadores"] else {}
        output.append(
            {
                "id": e["id"],
                "ticker": e["ticker"],
                "nome": e["nome"],
                "setor": e["setor"],
                "status": e["status"],
                "cotacao": e["cotacao"],
                "nota_final": a["nota_final"],
                "veredito": a["veredito"],
                "roe": ult.get("roe"),
                "margem_liquida": ult.get("margem_liquida"),
                "pl": a["valuation"]["pl"],
                "pvp": a["valuation"]["pvp"],
                "dy": a["valuation"]["dy"],
                "margem_seguranca": a["valuation"]["margem_seguranca"],
            }
        )
    output.sort(key=lambda r: -(r["nota_final"] or -1))
    return output


def sector_analysis(arm: Warehouse, sector: dict[str, Any]) -> dict[str, Any]:
    q = note_questionnaire(arm.questionnaire(), sector["respostas"], "setor")
    empresas = [r for r in ranking(arm) if r["setor"].lower() == sector["nome"].lower()]
    return {
        "setor": sector,
        "questionario": q,
        "veredito": verdict(q["nota"]),
        "empresas": empresas,
    }


def portfolio(arm: Warehouse) -> dict[str, Any]:
    cotacoes = {e["ticker"]: e for e in arm.todos("empresas")}
    pos: dict[str, dict[str, float]] = defaultdict(
        lambda: {
            "quantidade": 0.0,
            "custo": 0.0,
            "realizado": 0.0,
            "proventos": 0.0,
            "aportado": 0.0,
        }
    )
    for o in sorted(arm.todos("operacoes"), key=lambda o: o["data"] or ""):
        p = pos[o["ticker"].upper()]
        if o["tipo"] == "compra":
            total = o["quantidade"] * o["preco"] + o["taxas"]
            p["quantidade"] += o["quantidade"]
            p["custo"] += total
            p["aportado"] += total
        else:
            if p["quantidade"] <= 0:
                continue
            medio = p["custo"] / p["quantidade"]
            qtd = min(o["quantidade"], p["quantidade"])
            p["realizado"] += qtd * (o["preco"] - medio) - o["taxas"]
            p["quantidade"] -= qtd
            p["custo"] -= qtd * medio
    for pr in arm.todos("proventos"):
        pos[pr["ticker"].upper()]["proventos"] += pr["valor"]

    items = []
    for ticker, p in pos.items():
        e = cotacoes.get(ticker)
        preco = e["cotacao"] if e and e["cotacao"] else None
        medio = p["custo"] / p["quantidade"] if p["quantidade"] > 0 else None
        current = preco * p["quantidade"] if preco is not None else p["custo"]
        items.append(
            {
                "ticker": ticker,
                "empresa_id": e["id"] if e else None,
                "setor": e["setor"] if e else "",
                "quantidade": round(p["quantidade"], 6),
                "preco_medio": round(medio, 4) if medio else None,
                "cotacao": preco,
                "custo": round(p["custo"], 2),
                "valor_atual": round(current, 2),
                "resultado_aberto": round(current - p["custo"], 2),
                "rentabilidade": _div(current - p["custo"], p["custo"], 100),
                "realizado": round(p["realizado"], 2),
                "proventos": round(p["proventos"], 2),
                "yield_on_cost": _div(p["proventos"], p["aportado"], 100),
            }
        )
    total = sum(i["valor_atual"] for i in items if i["quantidade"] > 0)
    by_sector: dict[str, float] = defaultdict(float)
    for i in items:
        i["peso"] = _div(i["valor_atual"], total, 100) if i["quantidade"] > 0 else 0.0
        if i["quantidade"] > 0:
            by_sector[i["setor"] or "Sem setor"] += i["valor_atual"]
    items.sort(key=lambda i: -i["valor_atual"])
    cost = sum(i["custo"] for i in items if i["quantidade"] > 0)
    dividends_month: dict[str, float] = defaultdict(float)
    for pr in arm.todos("proventos"):
        dividends_month[(pr["data"] or "")[:7]] += pr["valor"]
    return {
        "posicoes": items,
        "por_setor": [
            {"setor": s, "valor": round(v, 2), "pct": _div(v, total, 100)}
            for s, v in sorted(by_sector.items(), key=lambda kv: -kv[1])
        ],
        "proventos_mes": [
            {"mes": m, "valor": round(v, 2)} for m, v in sorted(dividends_month.items())
        ],
        "totais": {
            "valor_atual": round(total, 2),
            "custo": round(cost, 2),
            "resultado_aberto": round(total - cost, 2),
            "rentabilidade": _div(total - cost, cost, 100),
            "realizado": round(sum(i["realizado"] for i in items), 2),
            "proventos": round(sum(i["proventos"] for i in items), 2),
        },
    }
