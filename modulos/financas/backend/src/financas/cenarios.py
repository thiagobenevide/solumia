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

from financas.armazem import Armazem
from financas.extrato import normalizar

# Referências (a.a.) quando o pedido não traz a taxa: financiamento de veículo usado, de terreno e
# imobiliário pelo SFH. Custo mensal extra do carro: IPVA (~4%) + seguro (~3%) ao ano sobre o valor.
TAXA_PADRAO = {
    "carro": 0.24,
    "moto": 0.26,
    "terreno": 0.15,
    "imovel": 0.115,
    "mcmv": 0.07,
    "outro": 0.20,
}
PRAZO_PADRAO = {"carro": 48, "moto": 36, "terreno": 120, "imovel": 360, "mcmv": 360, "outro": 24}
SISTEMA_PADRAO = {
    "carro": "price",
    "moto": "price",
    "terreno": "price",
    "imovel": "sac",
    "mcmv": "sac",
}
EXTRA_ANUAL = {"carro": 0.07, "moto": 0.06}
RENDIMENTO_RESERVA = 0.0075  # ao mês, líquido (~CDI menos IR)
LIMITE_COMPROMETIMENTO = 0.30  # parcela + custos fixos do bem até 30% da renda

# Minha Casa Minha Vida (referência 2025; a Caixa confirma): renda bruta familiar mensal até, taxa
# de juros a.a. e valor máximo do imóvel.
FAIXAS_MCMV = [
    ("Faixa 1", 2850.0, 0.045, 264_000.0),
    ("Faixa 2", 4700.0, 0.065, 264_000.0),
    ("Faixa 3", 8600.0, 0.0816, 350_000.0),
    ("Faixa 4", 12000.0, 0.105, 500_000.0),
]


def _brl(v: float, casas: int = 2) -> str:
    """1673.08 → '1.673,08' (formato brasileiro nos textos)."""
    return f"{v:,.{casas}f}".replace(",", "_").replace(".", ",").replace("_", ".")


def _mes(d: str) -> str:
    return d[:7]


def _somar_meses(mes: str, n: int) -> str:
    a, m = int(mes[:4]), int(mes[5:7]) - 1 + n
    return f"{a + m // 12:04d}-{m % 12 + 1:02d}"


def _tipos(arm: Armazem) -> dict[str, str]:
    return {c["id"]: c["tipo"] for c in arm.todos("categorias")}


def historico_mensal(
    arm: Armazem, meses: int = 12, hoje: date | None = None
) -> list[dict[str, Any]]:
    """Receitas, despesas e investimentos dos últimos [meses] meses completos (sem o mês atual),
    fora as transferências entre contas."""
    hoje = hoje or date.today()
    atual = hoje.isoformat()[:7]
    inicio = _somar_meses(atual, -meses)
    tipos = _tipos(arm)
    por_mes: dict[str, dict[str, float]] = defaultdict(
        lambda: {"receitas": 0.0, "despesas": 0.0, "investimentos": 0.0}
    )
    for t in arm.todos("transacoes"):
        mes = _mes(t["data"] or "")
        if not (inicio <= mes < atual):
            continue
        tipo = tipos.get(t["categoria_id"], "")
        if tipo == "transferencia":
            continue
        if tipo == "investimento":
            por_mes[mes]["investimentos"] += -t["valor"]
        elif t["valor"] > 0:
            por_mes[mes]["receitas"] += t["valor"]
        else:
            por_mes[mes]["despesas"] += -t["valor"]
    saida = []
    for i in range(meses):
        mes = _somar_meses(inicio, i)
        v = por_mes.get(mes)
        if v is None:
            continue  # mês sem extrato importado não conta como mês zerado
        saida.append(
            {
                "mes": mes,
                **{k: round(x, 2) for k, x in v.items()},
                "sobra": round(v["receitas"] - v["despesas"], 2),
            }
        )
    return saida


def _tendencia(valores: list[float]) -> float:
    """Inclinação (por mês) da reta de mínimos quadrados."""
    n = len(valores)
    if n < 3:
        return 0.0
    mx, my = (n - 1) / 2, sum(valores) / n
    num = sum((i - mx) * (v - my) for i, v in enumerate(valores))
    den = sum((i - mx) ** 2 for i in range(n))
    return num / den if den else 0.0


_PARCELA = re.compile(r"\s*\b(?:parc(?:ela)?\.?\s*)?\d{1,2}\s*(?:/|de)\s*\d{1,2}\b\s*", re.I)


def parcelamentos(arm: Armazem, hoje: date | None = None) -> list[dict[str, Any]]:
    """Compras parceladas pelo `parcela` n/m dos lançamentos: quanto já foi, quanto falta e até
    quando."""
    hoje = hoje or date.today()
    grupos: dict[tuple[str, str, float], list[dict[str, Any]]] = defaultdict(list)
    for t in arm.todos("transacoes"):
        if not t.get("parcela") or "/" not in t["parcela"]:
            continue
        base = normalizar(_PARCELA.sub(" ", t["descricao"])).strip()
        grupos[(t["conta_id"], base, round(abs(t["valor"]), 2))].append(t)
    saida = []
    for (conta_id, _, valor), ts in grupos.items():
        n, total = (
            int(x)
            for x in max(ts, key=lambda t: int(t["parcela"].split("/")[0]))["parcela"].split("/")
        )
        ultima = max(t["data"] for t in ts)
        restantes = max(0, total - n)
        fim = _somar_meses(_mes(ultima), restantes)
        primeira = min(ts, key=lambda t: t["data"])
        saida.append(
            {
                "descricao": _PARCELA.sub(" ", primeira["descricao"]).strip(),
                "conta_id": conta_id,
                "valor_parcela": valor,
                "parcelas": total,
                "pagas": n,
                "restantes": restantes,
                "valor_total": round(valor * total, 2),
                "valor_restante": round(valor * restantes, 2),
                "ultima": ultima,
                "termina": fim,
                "ativo": restantes > 0 and fim >= hoje.isoformat()[:7],
            }
        )
    return sorted(saida, key=lambda p: (not p["ativo"], p["termina"]))


def _parcelas_por_mes(parcs: list[dict[str, Any]], mes_inicial: str, meses: int) -> list[float]:
    """Quanto das parcelas em aberto cai em cada um dos próximos [meses]."""
    saida = [0.0] * meses
    for p in parcs:
        if not p["ativo"]:
            continue
        for i in range(meses):
            mes = _somar_meses(mes_inicial, i)
            if _mes(p["ultima"]) < mes <= p["termina"]:
                saida[i] += p["valor_parcela"]
    return saida


def reserva_atual(arm: Armazem) -> float:
    """Saldo das contas de dinheiro e investimento (corrente, poupança, carteira, investimento)."""
    contas = {
        c["id"]: c for c in arm.todos("contas") if c["tipo"] != "cartao" and c.get("ativa", True)
    }
    saldo = {i: c["saldo_inicial"] for i, c in contas.items()}
    for t in arm.todos("transacoes"):
        if t["conta_id"] in saldo:
            saldo[t["conta_id"]] += t["valor"]
    return round(max(0.0, sum(saldo.values())), 2)


def financiamento(
    valor: float, taxa_anual: float, meses: int, sistema: str = "price"
) -> dict[str, Any]:
    """Parcelas pela tabela Price (fixas) ou SAC (amortização fixa, parcela caindo)."""
    i = (1 + taxa_anual) ** (1 / 12) - 1
    parcelas = []
    if valor <= 0 or meses <= 0:
        return {
            "taxa_mensal": i,
            "parcelas": [],
            "primeira": 0.0,
            "ultima": 0.0,
            "total": 0.0,
            "juros": 0.0,
        }
    if sistema == "sac":
        amort = valor / meses
        saldo = valor
        for _ in range(meses):
            parcelas.append(amort + saldo * i)
            saldo -= amort
    else:
        pmt = valor / meses if i == 0 else valor * i / (1 - (1 + i) ** -meses)
        parcelas = [pmt] * meses
    total = sum(parcelas)
    return {
        "taxa_mensal": round(i, 6),
        "parcelas": [round(p, 2) for p in parcelas],
        "primeira": round(parcelas[0], 2),
        "ultima": round(parcelas[-1], 2),
        "total": round(total, 2),
        "juros": round(total - valor, 2),
    }


def faixa_mcmv(renda: float) -> dict[str, Any] | None:
    for nome, teto, taxa, imovel in FAIXAS_MCMV:
        if renda <= teto:
            return {
                "faixa": nome,
                "renda_maxima": teto,
                "taxa_anual": taxa,
                "imovel_maximo": imovel,
            }
    return None


def _meses_para_juntar(
    alvo: float, reserva: float, sobras: list[float], rendimento: float = RENDIMENTO_RESERVA
) -> int | None:
    """Mês (1, 2, …) em que a reserva, rendendo e recebendo cada sobra, chega no [alvo]."""
    saldo = reserva
    if saldo >= alvo:
        return 0
    for mes, sobra in enumerate(sobras, start=1):
        saldo = saldo * (1 + rendimento) + sobra
        if saldo >= alvo:
            return mes
    return None


def simular(arm: Armazem, p: dict[str, Any], hoje: date | None = None) -> dict[str, Any]:
    """Compra de um bem: juntar e pagar à vista × financiar agora, sobre a sua realidade do extrato.

    [p]: `valor` (obrigatório), `tipo` (carro|moto|terreno|imovel|mcmv|outro), `descricao`,
    `entrada`, `prazo_meses`, `taxa_anual`, `sistema` (price|sac), `custo_mensal_extra`,
    `renda_mensal`, `reserva`, `aporte_mensal` (sobra que você topa guardar; padrão: a sobra
    média)."""
    hoje = hoje or date.today()
    tipo = p.get("tipo") or "outro"
    valor = float(p["valor"])
    historico = historico_mensal(arm, 12, hoje)
    recentes = historico[-6:] or historico
    renda = float(
        p.get("renda_mensal")
        or (sum(m["receitas"] for m in recentes) / len(recentes) if recentes else 0)
    )
    sobra_media = sum(m["sobra"] for m in recentes) / len(recentes) if recentes else 0.0
    tendencia = _tendencia([m["sobra"] for m in historico])
    reserva = float(p["reserva"]) if p.get("reserva") is not None else reserva_atual(arm)
    entrada = min(float(p.get("entrada") or 0), valor)

    mcmv = None
    taxa_padrao = TAXA_PADRAO.get(tipo, TAXA_PADRAO["outro"])
    if tipo == "mcmv":
        mcmv = faixa_mcmv(renda)
        if mcmv:
            taxa_padrao = mcmv["taxa_anual"]
    taxa = float(p.get("taxa_anual") or taxa_padrao)
    prazo = int(p.get("prazo_meses") or PRAZO_PADRAO.get(tipo, 24))
    sistema = p.get("sistema") or SISTEMA_PADRAO.get(tipo, "price")
    extra = float(
        p["custo_mensal_extra"]
        if p.get("custo_mensal_extra") is not None
        else valor * EXTRA_ANUAL.get(tipo, 0) / 12
    )

    horizonte = min(480, max(prazo, 36) + 12)
    mes0 = _somar_meses(hoje.isoformat()[:7], 1)
    parcs = parcelamentos(arm, hoje)
    compromissos = _parcelas_por_mes(parcs, mes0, horizonte)
    # Sobra prevista: média recente + metade da tendência (amortecida, para não extrapolar demais),
    # mais o que as parcelas que vão acabando liberam em relação a hoje.
    hoje_parcelas = compromissos[0] if compromissos else 0.0
    aporte = p.get("aporte_mensal")
    sobras = [
        (float(aporte) if aporte is not None else sobra_media + tendencia * 0.5 * min(i, 12))
        + (hoje_parcelas - compromissos[i])
        for i in range(horizonte)
    ]

    # Rendimento da reserva: o do pedido (ex.: CDI atual, líquido) ou a referência fixa.
    rendimento = float(p.get("rendimento_mensal") or RENDIMENTO_RESERVA)
    # A) juntar e comprar à vista
    meses_juntar = _meses_para_juntar(valor, reserva, sobras, rendimento)
    # B) financiar agora (a entrada sai da reserva)
    financiado = valor - entrada
    fin = financiamento(financiado, taxa, prazo, sistema)
    comprometimento = (fin["primeira"] + extra) / renda if renda > 0 else None
    entrada_cabe = entrada <= reserva

    base, juntar, financiar = [], [], []
    s_base = s_juntar = reserva
    s_fin = reserva - entrada
    for i in range(horizonte):
        s_base = s_base * (1 + rendimento) + sobras[i]
        s_juntar = s_juntar * (1 + rendimento) + sobras[i]
        if meses_juntar is not None and i + 1 == max(meses_juntar, 1):
            s_juntar -= valor
        if meses_juntar is not None and i + 1 > max(meses_juntar, 1):
            s_juntar -= extra
        parcela = fin["parcelas"][i] if i < len(fin["parcelas"]) else 0.0
        s_fin = s_fin * (1 + rendimento) + sobras[i] - parcela - extra
        mes = _somar_meses(mes0, i)
        base.append({"mes": mes, "saldo": round(s_base, 2)})
        juntar.append({"mes": mes, "saldo": round(s_juntar, 2)})
        financiar.append({"mes": mes, "saldo": round(s_fin, 2), "parcela": round(parcela, 2)})
    negativo_fin = next((x["mes"] for x in financiar if x["saldo"] < 0), None)

    alertas = []
    if sobra_media <= 0:
        alertas.append(
            "Nos últimos meses você gastou mais do que ganhou: sem sobra, não dá para juntar."
        )
    if comprometimento is not None and comprometimento > LIMITE_COMPROMETIMENTO:
        alertas.append(
            f"Parcela + custos do bem comprometem {comprometimento:.0%} da renda "
            "(o recomendado é até 30%)."
        )
    custo_mensal = fin["primeira"] + extra
    if financiado > 0 and custo_mensal > max(sobra_media, 0) + hoje_parcelas:
        alertas.append(
            f"Parcela + custos do bem (R$ {_brl(custo_mensal, 2)}/mês) passam da sua sobra mensal "
            f"(R$ {_brl(max(sobra_media, 0), 2)})."
        )
    if not entrada_cabe:
        alertas.append(
            f"A entrada (R$ {_brl(entrada, 2)}) é maior que a sua reserva atual "
            f"(R$ {_brl(reserva, 2)})."
        )
    if negativo_fin:
        alertas.append(f"Financiando, seu saldo fica negativo a partir de {negativo_fin}.")
    if entrada < valor * 0.2 and tipo in ("carro", "moto", "imovel", "terreno"):
        alertas.append(
            "Entrada abaixo de 20% do valor: juros sobre quase tudo; juntar uma entrada maior "
            "reduz o custo."
        )
    if tipo == "mcmv":
        if mcmv is None:
            alertas.append("Pela renda média, você passa da Faixa 4 do Minha Casa Minha Vida.")
        elif valor > mcmv["imovel_maximo"]:
            alertas.append(
                f"O imóvel passa do teto da {mcmv['faixa']} (R$ {_brl(mcmv['imovel_maximo'], 0)})."
            )

    # Compensa financiar? Paga os juros para antecipar a compra em `meses_juntar` meses; cabe no
    # orçamento se a parcela + custos não passam da sobra nem de 30% da renda.
    cabe = (
        comprometimento is not None
        and comprometimento <= LIMITE_COMPROMETIMENTO
        and fin["primeira"] + extra <= max(sobra_media, 0) + hoje_parcelas
        and entrada_cabe
        and negativo_fin is None
    )
    if meses_juntar == 0:
        veredito = "Você já tem o valor: comprar à vista evita todos os juros."
    elif not cabe:
        veredito = (
            "Financiar não cabe no seu orçamento hoje; o caminho é juntar (ou aumentar a entrada)."
        )
    elif meses_juntar is not None and meses_juntar <= 12:
        veredito = (
            f"Compensa juntar: em {meses_juntar} meses você compra à vista e economiza "
            f"R$ {_brl(fin['juros'], 2)} de juros."
        )
    else:
        veredito = (
            f"Financiar cabe, mas custa R$ {_brl(fin['juros'], 2)} de juros para antecipar a compra"
            + (f" em {meses_juntar} meses." if meses_juntar else ".")
        )

    # Alternativa: usar a reserva como entrada, guardando 3 meses de despesas como emergência.
    despesa_media = sum(m["despesas"] for m in recentes) / len(recentes) if recentes else 0.0
    emergencia = round(3 * despesa_media, 2)
    entrada_reserva = round(min(valor, max(0.0, reserva - emergencia)), 2)
    com_reserva = None
    if entrada_reserva > entrada and entrada_reserva < valor:
        fin2 = financiamento(valor - entrada_reserva, taxa, prazo, sistema)
        custo2 = fin2["primeira"] + extra
        com_reserva = {
            "entrada": entrada_reserva,
            "emergencia_guardada": emergencia,
            "valor_financiado": round(valor - entrada_reserva, 2),
            **{k: v for k, v in fin2.items() if k != "parcelas"},
            "cabe": custo2 <= max(sobra_media, 0) + hoje_parcelas
            and (renda <= 0 or custo2 / renda <= LIMITE_COMPROMETIMENTO),
        }

    return {
        "financiar_com_reserva": com_reserva,
        "pedido": {
            "descricao": p.get("descricao") or "",
            "tipo": tipo,
            "valor": valor,
            "entrada": entrada,
            "prazo_meses": prazo,
            "taxa_anual": taxa,
            "sistema": sistema,
            "custo_mensal_extra": round(extra, 2),
            "rendimento_mensal": round(rendimento, 5),
        },
        "realidade": {
            "renda_media": round(renda, 2),
            "sobra_media": round(sobra_media, 2),
            "tendencia_mensal": round(tendencia, 2),
            "reserva": reserva,
            "parcelas_em_aberto": round(hoje_parcelas, 2),
            "meses_de_historico": len(historico),
            "historico": historico,
        },
        "juntar": {
            "meses": meses_juntar,
            "data": _somar_meses(hoje.isoformat()[:7], meses_juntar)
            if meses_juntar is not None
            else None,
            "aporte_mensal": round(sobras[0], 2) if sobras else 0.0,
        },
        "financiar": {
            **{k: v for k, v in fin.items() if k != "parcelas"},
            "valor_financiado": round(financiado, 2),
            "comprometimento": round(comprometimento, 4) if comprometimento is not None else None,
            "cabe": cabe,
        },
        "mcmv": mcmv,
        "veredito": veredito,
        "alertas": alertas,
        "projecao": {"sem_compra": base, "juntar": juntar, "financiar": financiar},
        "parcelamentos": [x for x in parcs if x["ativo"]],
    }
