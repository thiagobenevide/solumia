"""Números do painel: resumo do mês (receitas, despesas, orçamento, 50/30/20, indicadores pessoais),
fluxo de caixa mensal, ranking de contrapartes, faturas do cartão, projeção das programações e
progresso das metas. Convenção: valor > 0 entra, valor < 0 sai; transferências ficam fora."""

import calendar
from collections import defaultdict
from datetime import date, timedelta
from typing import Any

from financas.armazem import Armazem, Invalido, data_iso


def _mes(valor: str) -> tuple[int, int]:
    try:
        a, m = valor.split("-")[:2]
        ano, mes = int(a), int(m)
        if not 1 <= mes <= 12:
            raise ValueError
        return ano, mes
    except ValueError as e:
        raise Invalido(f"Mês inválido: {valor} (use AAAA-MM)") from e


def _somar_meses(ano: int, mes: int, n: int) -> tuple[int, int]:
    i = ano * 12 + mes - 1 + n
    return i // 12, i % 12 + 1


def _chave(ano: int, mes: int) -> str:
    return f"{ano:04d}-{mes:02d}"


def _dia(ano: int, mes: int, dia: int) -> date:
    return date(ano, mes, min(max(dia, 1), calendar.monthrange(ano, mes)[1]))


def _tipos(arm: Armazem) -> dict[str, dict[str, Any]]:
    return {c["id"]: c for c in arm.todos("categorias")}


def _tipo(t: dict[str, Any], cats: dict[str, dict[str, Any]]) -> str:
    """receita, despesa, investimento ou transferencia; sem categoria vale o sinal."""
    c = cats.get(t["categoria_id"])
    if c:
        return str(c["tipo"])
    return "receita" if t["valor"] > 0 else "despesa"


def _totais(transacoes: list[dict[str, Any]], cats: dict[str, dict[str, Any]]) -> dict[str, float]:
    tot = {"receitas": 0.0, "despesas": 0.0, "investimentos": 0.0}
    for t in transacoes:
        tipo = _tipo(t, cats)
        if tipo == "receita":
            tot["receitas"] += t["valor"]
        elif tipo == "despesa":
            tot["despesas"] -= t["valor"]
        elif tipo == "investimento":
            tot["investimentos"] -= t["valor"]
    tot["saldo"] = tot["receitas"] - tot["despesas"] - tot["investimentos"]
    return {k: round(v, 2) for k, v in tot.items()}


def _do_mes(arm: Armazem, ano: int, mes: int) -> list[dict[str, Any]]:
    p = _chave(ano, mes)
    return [t for t in arm.todos("transacoes") if t["data"] and t["data"].startswith(p)]


def _pct(parte: float, todo: float) -> float | None:
    return round(100 * parte / todo, 1) if todo else None


def saldos(arm: Armazem) -> list[dict[str, Any]]:
    soma: dict[str, float] = defaultdict(float)
    for t in arm.todos("transacoes"):
        soma[t["conta_id"]] += t["valor"]
    return [
        {
            "id": c["id"],
            "nome": c["nome"],
            "tipo": c["tipo"],
            "limite": c["limite"],
            "saldo": round(c["saldo_inicial"] + soma[c["id"]], 2),
        }
        for c in arm.todos("contas")
    ]


def resumo(arm: Armazem, mes: str) -> dict[str, Any]:
    ano, m = _mes(mes)
    cats = _tipos(arm)
    atuais = _do_mes(arm, ano, m)
    tot = _totais(atuais, cats)
    anterior = _totais(_do_mes(arm, *_somar_meses(ano, m, -1)), cats)

    por_cat: dict[str, float] = defaultdict(float)
    for t in atuais:
        if _tipo(t, cats) in ("despesa", "investimento", "receita"):
            por_cat[t["categoria_id"]] += t["valor"]
    categorias = []
    for cid, valor in por_cat.items():
        c = cats.get(
            cid,
            {
                "nome": "Sem categoria",
                "tipo": "receita" if valor > 0 else "despesa",
                "orcamento_mensal": 0.0,
                "cor": "",
                "grupo": "",
            },
        )
        gasto = abs(valor)
        base = tot["receitas"] if c["tipo"] == "receita" else tot["despesas"] + tot["investimentos"]
        categorias.append(
            {
                "id": cid,
                "nome": c["nome"],
                "tipo": c["tipo"],
                "cor": c["cor"],
                "valor": round(gasto, 2),
                "pct": _pct(gasto, base),
                "orcamento": c["orcamento_mensal"],
                "uso_orcamento": _pct(gasto, c["orcamento_mensal"]),
            }
        )
    # categorias com orçamento e nenhum gasto também aparecem no acompanhamento
    for c in cats.values():
        if c["orcamento_mensal"] and c["id"] not in por_cat:
            categorias.append(
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
    categorias.sort(key=lambda c: -c["valor"])

    grupos = {"essencial": 0.0, "estilo": 0.0, "futuro": 0.0}
    for t in atuais:
        c = cats.get(t["categoria_id"])
        if c and c["grupo"] in grupos and c["tipo"] in ("despesa", "investimento"):
            grupos[c["grupo"]] -= t["valor"]

    hoje = date.today()
    dias_mes = calendar.monthrange(ano, m)[1]
    dias_passados = (
        dias_mes
        if (ano, m) < (hoje.year, hoje.month)
        else (hoje.day if (ano, m) == (hoje.year, hoje.month) else 0)
    )
    media_3 = (
        sum(_totais(_do_mes(arm, *_somar_meses(ano, m, -i)), cats)["despesas"] for i in range(1, 4))
        / 3
    )
    contas = saldos(arm)
    liquidez = sum(c["saldo"] for c in contas if c["tipo"] in ("corrente", "poupanca", "carteira"))
    investido = sum(c["saldo"] for c in contas if c["tipo"] == "investimento")
    divida_cartao = -sum(c["saldo"] for c in contas if c["tipo"] == "cartao" and c["saldo"] < 0)
    fixas = sum(
        -p["valor"]
        for p in arm.todos("programacoes")
        if p["ativa"] and p["valor"] < 0 and p["frequencia"] == "mensal"
    )
    gasto_cartao = -sum(
        t["valor"]
        for t in atuais
        if t["valor"] < 0
        and any(c["id"] == t["conta_id"] and c["tipo"] == "cartao" for c in contas)
    )
    pendentes = projecao(arm, de=max(hoje, date(ano, m, 1)), ate=date(ano, m, dias_mes))

    maiores = sorted((t for t in atuais if _tipo(t, cats) == "despesa"), key=lambda t: t["valor"])[
        :5
    ]
    return {
        "mes": _chave(ano, m),
        **tot,
        "anterior": anterior,
        "variacao_despesas": _pct(tot["despesas"] - anterior["despesas"], anterior["despesas"]),
        "variacao_receitas": _pct(tot["receitas"] - anterior["receitas"], anterior["receitas"]),
        "categorias": categorias,
        "regra_50_30_20": {
            k: {"valor": round(v, 2), "pct": _pct(v, tot["receitas"]), "ideal": i}
            for (k, v), i in zip(grupos.items(), (50, 30, 20), strict=True)
        },
        "indicadores": {
            "taxa_poupanca": _pct(tot["receitas"] - tot["despesas"], tot["receitas"]),
            "comprometimento_despesas": _pct(tot["despesas"], tot["receitas"]),
            "taxa_investimento": _pct(tot["investimentos"], tot["receitas"]),
            "gasto_medio_diario": round(tot["despesas"] / dias_passados, 2)
            if dias_passados
            else None,
            "projecao_despesas_mes": round(tot["despesas"] / dias_passados * dias_mes, 2)
            if dias_passados
            else None,
            "despesa_media_3m": round(media_3, 2),
            "reserva_meses": round(liquidez / media_3, 1) if media_3 else None,
            "despesas_fixas": round(fixas, 2),
            "peso_fixas": _pct(fixas, tot["receitas"]),
            "gasto_cartao": round(gasto_cartao, 2),
            "peso_cartao": _pct(gasto_cartao, tot["receitas"]),
            "sem_categoria": sum(1 for t in atuais if not t["categoria_id"]),
        },
        "patrimonio": {
            "liquidez": round(liquidez, 2),
            "investido": round(investido, 2) + carteira_valor(arm),
            "dividas": round(divida_cartao, 2),
            "liquido": round(liquidez + investido + carteira_valor(arm) - divida_cartao, 2),
        },
        "contas": contas,
        "maiores_despesas": maiores,
        "a_lancar": pendentes,
        "metas": metas(arm),
    }


def fluxo(arm: Armazem, meses: int = 12, ate: str | None = None) -> list[dict[str, Any]]:
    hoje = date.today()
    ano, m = _mes(ate) if ate else (hoje.year, hoje.month)
    cats = _tipos(arm)
    saida = []
    acumulado = 0.0
    for i in range(meses - 1, -1, -1):
        a, mm = _somar_meses(ano, m, -i)
        tot = _totais(_do_mes(arm, a, mm), cats)
        acumulado += tot["saldo"]
        saida.append({"mes": _chave(a, mm), **tot, "acumulado": round(acumulado, 2)})
    return saida


def contrapartes(arm: Armazem, de: str | None, ate: str | None, limite: int = 15) -> dict[str, Any]:
    cats = _tipos(arm)
    de, ate = (data_iso(de) if de else "0000"), (data_iso(ate) if ate else "9999")
    env: dict[str, list[float]] = defaultdict(lambda: [0.0, 0])
    rec: dict[str, list[float]] = defaultdict(lambda: [0.0, 0])
    for t in arm.todos("transacoes"):
        if not (de <= (t["data"] or "") <= ate) or _tipo(t, cats) == "transferencia":
            continue
        nome = t["contraparte"] or t["descricao"]
        alvo = rec if t["valor"] > 0 else env
        alvo[nome][0] += abs(t["valor"])
        alvo[nome][1] += 1

    def ranking(d: dict[str, list[float]]) -> list[dict[str, Any]]:
        total = sum(v[0] for v in d.values())
        lista = sorted(d.items(), key=lambda kv: -kv[1][0])[:limite]
        return [
            {"nome": k, "valor": round(v[0], 2), "vezes": int(v[1]), "pct": _pct(v[0], total)}
            for k, v in lista
        ]

    return {"enviado": ranking(env), "recebido": ranking(rec)}


def _fatura_de(dia: date, fechamento: int) -> tuple[int, int]:
    """Mês da fatura em que cai uma compra: depois do fechamento vai para a do mês seguinte."""
    if fechamento and dia.day > fechamento:
        return _somar_meses(dia.year, dia.month, 1)
    return dia.year, dia.month


def faturas(arm: Armazem, conta_id: str) -> dict[str, Any]:
    c = arm.obter("contas", conta_id)
    if c["tipo"] != "cartao":
        raise Invalido("A conta não é um cartão de crédito")
    cats = _tipos(arm)
    por_mes: dict[tuple[int, int], list[dict[str, Any]]] = defaultdict(list)
    for t in arm.todos("transacoes"):
        if t["conta_id"] == conta_id and t["data"]:
            por_mes[_fatura_de(date.fromisoformat(t["data"]), c["dia_fechamento"])].append(t)
    hoje = date.today()
    aberta = _fatura_de(hoje, c["dia_fechamento"])
    lista = []
    for (a, m), itens in sorted(por_mes.items(), reverse=True):
        gastos = -sum(
            t["valor"] for t in itens if t["valor"] < 0 and _tipo(t, cats) != "transferencia"
        )
        pagos = sum(t["valor"] for t in itens if t["valor"] > 0)
        venc = None
        if c["dia_vencimento"]:
            va, vm = (a, m) if c["dia_vencimento"] > c["dia_fechamento"] else _somar_meses(a, m, 1)
            venc = _dia(va, vm, c["dia_vencimento"]).isoformat()
        lista.append(
            {
                "mes": _chave(a, m),
                "total": round(gastos, 2),
                "pagamentos": round(pagos, 2),
                "vencimento": venc,
                "situacao": "aberta"
                if (a, m) == aberta
                else ("futura" if (a, m) > aberta else "fechada"),
                "itens": len(itens),
            }
        )
    usado = (
        -sum(t["valor"] for t in arm.todos("transacoes") if t["conta_id"] == conta_id)
        - c["saldo_inicial"]
    )
    return {
        "conta": c,
        "faturas": lista,
        "limite": c["limite"],
        "usado": round(max(usado, 0), 2),
        "disponivel": round(c["limite"] - max(usado, 0), 2) if c["limite"] else None,
        "uso_limite": _pct(max(usado, 0), c["limite"]),
    }


def _ocorrencias(p: dict[str, Any], de: date, ate: date) -> list[date]:
    if not p["inicio"] or not p["ativa"]:
        return []
    inicio = date.fromisoformat(p["inicio"])
    fim = min(ate, date.fromisoformat(p["fim"])) if p["fim"] else ate
    datas: list[date] = []
    if p["frequencia"] == "unica":
        return [inicio] if de <= inicio <= fim else []
    if p["frequencia"] == "semanal":
        d = inicio
        if d < de:
            d += timedelta(days=((de - d).days + 6) // 7 * 7)
        while d <= fim:
            datas.append(d)
            d += timedelta(days=7)
        return datas
    passo = 12 if p["frequencia"] == "anual" else 1
    n = 0
    while True:
        a, m = _somar_meses(inicio.year, inicio.month, n * passo)
        d = _dia(a, m, inicio.day)
        if d > fim:
            return datas
        if d >= de:
            datas.append(d)
        n += 1


def projecao(
    arm: Armazem, de: date | None = None, ate: date | None = None, dias: int = 60
) -> list[dict[str, Any]]:
    """Ocorrências das programações no período que ainda não viraram lançamento."""
    de = de or date.today()
    ate = ate or de + timedelta(days=dias)
    lancadas = {
        (t["programacao_id"], t["data"]) for t in arm.todos("transacoes") if t["programacao_id"]
    }
    itens = []
    for p in arm.todos("programacoes"):
        for d in _ocorrencias(p, de, ate):
            if (p["id"], d.isoformat()) not in lancadas:
                itens.append(
                    {
                        "programacao_id": p["id"],
                        "data": d.isoformat(),
                        "descricao": p["descricao"],
                        "valor": p["valor"],
                        "conta_id": p["conta_id"],
                        "categoria_id": p["categoria_id"],
                    }
                )
    itens.sort(key=lambda i: i["data"])
    return itens


def projecao_saldo(arm: Armazem, dias: int = 90) -> list[dict[str, Any]]:
    """Saldo líquido (contas correntes, poupança e carteira) dia a dia somando as programações."""
    contas = {c["id"]: c for c in arm.todos("contas")}
    liquidas = {i for i, c in contas.items() if c["tipo"] in ("corrente", "poupanca", "carteira")}
    saldo = sum(s["saldo"] for s in saldos(arm) if s["id"] in liquidas)
    hoje = date.today()
    por_dia: dict[str, float] = defaultdict(float)
    for i in projecao(arm, de=hoje + timedelta(days=1), dias=dias):
        if i["conta_id"] in liquidas or not i["conta_id"]:
            por_dia[i["data"]] += i["valor"]
    pontos = [{"data": hoje.isoformat(), "saldo": round(saldo, 2)}]
    for n in range(1, dias + 1):
        d = (hoje + timedelta(days=n)).isoformat()
        if d in por_dia:
            saldo += por_dia[d]
            pontos.append({"data": d, "saldo": round(saldo, 2)})
    return pontos


def lancar(arm: Armazem, programacao_id: str, data: str) -> dict[str, Any]:
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


def metas(arm: Armazem) -> list[dict[str, Any]]:
    hoje = date.today()
    saida = []
    for meta in arm.todos("metas"):
        aportes = 0.0
        if meta["categoria_id"]:
            aportes = -sum(
                t["valor"]
                for t in arm.todos("transacoes")
                if t["categoria_id"] == meta["categoria_id"]
            )
        atual = meta["valor_inicial"] + aportes
        falta = max(meta["valor_alvo"] - atual, 0)
        mensal = None
        if meta["prazo"] and falta:
            p = date.fromisoformat(meta["prazo"])
            meses = (p.year - hoje.year) * 12 + p.month - hoje.month
            mensal = round(falta / meses, 2) if meses > 0 else round(falta, 2)
        saida.append(
            {
                **meta,
                "atual": round(atual, 2),
                "falta": round(falta, 2),
                "progresso": _pct(atual, meta["valor_alvo"]),
                "aporte_mensal_necessario": mensal,
            }
        )
    return saida


def carteira_valor(arm: Armazem) -> float:
    from financas.analise import carteira  # evita import circular

    return float(carteira(arm)["totais"]["valor_atual"])
