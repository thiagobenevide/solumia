"""IA no módulo Finanças: ler extratos que o código não reconhece (PDF, layout estranho),
categorizar o que as regras não pegaram e conversar sobre cenários de compra. O LLM só interpreta
texto; as contas (saldos, parcelas, prazos) são sempre feitas em Python (`cenarios`)."""

import json
import re
from collections import Counter
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import date
from typing import Any

from financas.warehouse import Warehouse, Invalid
from financas.statement import _data, shape_payment, normalize

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]

CHUNK = 9000  # caracteres de extrato por pedido (cabe no contexto do LLM local com folga)
BATCH_CATEGORIES = 25  # lote menor: o LLM local erra menos e a segunda chance sai barata


def extract_json(answer: str) -> Any:
    """Primeiro objeto/lista JSON da resposta (ignora <think>, cercas e texto em volta)."""
    text = re.sub(r"<think>.*?</think>", "", answer, flags=re.DOTALL)
    start = min((i for i in (text.find("{"), text.find("[")) if i >= 0), default=-1)
    if start < 0:
        raise Invalid("A IA não devolveu JSON.")
    try:
        data, _ = json.JSONDecoder().raw_decode(text[start:])
    except json.JSONDecodeError as e:
        raise Invalid(f"A IA devolveu um JSON inválido: {e.msg}.") from e
    return data


async def _ask_json(llm: ChatLLM, system: str, usuario: str) -> Any:
    messages = [{"role": "system", "content": system}, {"role": "user", "content": usuario}]
    answer = await llm(messages)
    try:
        return extract_json(answer)
    except Invalid as e:
        messages += [
            {"role": "assistant", "content": answer[:3000]},
            {"role": "user", "content": f"{e} Responda de novo SOMENTE com o JSON."},
        ]
        return extract_json(await llm(messages))


# ---------- extratos ----------

SYSTEM_STATEMENT = """Você extrai lançamentos de extratos bancários brasileiros (Nubank, Inter,
Banco do Brasil, Itaú, Mercado Pago e outros). Responda SOMENTE com JSON:
{"lancamentos": [{"data": "AAAA-MM-DD", "descricao": "...", "valor": -123.45}]}
Regras: saídas (compras, pagamentos, Pix enviado, tarifas) com valor NEGATIVO; entradas (salário,
Pix recebido, estorno) POSITIVO. Ignore linhas de saldo, totais, cabeçalhos e propaganda. Mantenha
a descrição como está no extrato, inclusive "Parcela 2/10". Se o ano não aparecer na linha, use o
do período do extrato."""

SYSTEM_INVOICE = (
    SYSTEM_STATEMENT
    + """
Este arquivo é FATURA DE CARTÃO: compras são NEGATIVAS; pagamento da fatura, estorno e crédito são
POSITIVOS."""
)


def _chunks(text: str) -> list[str]:
    lines, current, output = text.splitlines(), [], []
    size = 0
    for line in lines:
        if size + len(line) > CHUNK and current:
            output.append("\n".join(current))
            current, size = [], 0
        current.append(line)
        size += len(line) + 1
    if current:
        output.append("\n".join(current))
    return output


async def extract_entries(
    llm: ChatLLM, text: str, fatura: bool = False
) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    cabecalho = "\n".join(text.splitlines()[:15])  # período e banco, para o ano das datas
    for i, chunk in enumerate(_chunks(text)):
        context = f"Início do extrato (contexto):\n{cabecalho}\n\n" if i else ""
        data = await _ask_json(
            llm,
            SYSTEM_INVOICE if fatura else SYSTEM_STATEMENT,
            f"{context}Trecho do extrato:\n{chunk}",
        )
        lista = data.get("lancamentos", []) if isinstance(data, dict) else data
        for it in lista if isinstance(lista, list) else []:
            try:
                items.append(
                    {
                        "data": _data(str(it["data"])),
                        "descricao": str(it["descricao"]).strip()[:200],
                        "valor": round(float(it["valor"]), 2),
                        "ref": "",
                    }
                )
            except (KeyError, TypeError, ValueError, Invalid):
                continue
    if not items:
        raise Invalid("A IA não achou lançamentos no arquivo.")
    return items


# ---------- categorias ----------
# Para o LLM local entender melhor, o Python faz o trabalho de base: calcula as pistas de cada
# lançamento (sentido, pessoa física ou empresa, forma já detectada, parcela), troca os ids longos
# por códigos curtos (c1, n1), mostra o que o próprio usuário já pôs em cada categoria e os
# lançamentos parecidos já classificados (exemplos, por palavras raras em comum) e confere a
# resposta: categoria inexistente ou do sentido errado volta para a IA uma vez, com o motivo.

SYSTEM_CATEGORIES = """Você classifica lançamentos do extrato bancário de UMA pessoa no Brasil.

Entrada (JSON):
- "categorias": código (c1, c2...), nome, tipo (despesa, receita, investimento, transferencia) e
  "ex" = contrapartes que o próprio usuário já pôs nela.
- "exemplos": lançamentos parecidos que o usuário já classificou. Siga o MESMO critério dele.
- "lancamentos": n, texto (como veio do banco), quem (contraparte deduzida), sentido
  (entrada/saida), valor, conta (corrente, cartao, poupanca...) e, quando houver: pessoa
  (fisica/empresa), forma_detectada, parcela, obs (anotação do usuário), atual (categoria de hoje,
  numa reconferência) e corrija (erro da resposta anterior).

Como decidir a categoria, nesta ordem:
1. Exemplo com a mesma contraparte ou texto quase igual → mesma categoria do exemplo.
2. Marca conhecida: iFood/Rappi → alimentação; Uber/99 → transporte; Netflix/Spotify/Google/Apple
   → assinaturas; Drogasil/Raia/Pague Menos → saúde ou farmácia; Shell/Ipiranga/BR/posto →
   combustível; Amazon/Mercado Livre/Shopee/Magalu → compras; Sabesp/Enel/Claro/Vivo → contas da
   casa.
3. Ramo no nome: padaria, mercado, supermercado, açougue, restaurante, lanchonete, auto peças,
   pet, academia, escola, clínica, ótica, loja.
4. Dinheiro do próprio usuário mudando de lugar NÃO é despesa nem receita: pagamento de fatura do
   cartão, transferência entre contas dele → transferencia; aplicação, resgate, CDB, caixinha,
   Tesouro, corretora → investimento.
5. Pix/TED para pessoa física sem outra pista → transferencia. Recebido de pessoa física → receita
   (ou transferencia, se parecer devolução entre contas).
6. Tarifa, anuidade, IOF, juros, multa → categoria de tarifas/taxas/bancos, se houver.
Regra do sentido: saida usa despesa; entrada usa receita; transferencia e investimento valem nos
dois. Estorno, reembolso e cashback podem voltar para a categoria da despesa original.
Se houver "atual" e ela estiver certa, repita-a. Use "" só se nenhuma categoria servir de verdade.

Forma (o tipo do lançamento): SEMPRE preencha com uma destas: pix, debito, credito, boleto, ted,
doc, transferencia, saque, deposito, tarifa, investimento, dinheiro, outro. Havendo
forma_detectada, repita-a. Compra na conta cartao → credito; compra em loja na conta corrente sem
outra pista → debito.

Responda SOMENTE com JSON, um item por lançamento, sem explicações:
{"itens": [{"n": 1, "cat": "c3", "forma": "pix"}]}"""

SHAPES = {
    "pix",
    "debito",
    "credito",
    "boleto",
    "ted",
    "doc",
    "transferencia",
    "saque",
    "deposito",
    "tarifa",
    "investimento",
    "dinheiro",
    "outro",
}

EXAMPLES = 20  # exemplos do histórico por pedido
_LAP = re.compile(r"\bestorn|\breembols|\bcashback|\bdevoluc|\bcancelad")
_COMPANY = re.compile(
    r"\b(ltda|eireli|s\.?a|me|epp|cia|comercio|servicos|industria|loja|lojas|mercado|supermercado|"
    r"posto|farmacia|drogaria|restaurante|lanchonete|padaria|bar|pet|shop|store|pagamentos|digital|"
    r"tecnologia|ifood|uber|amazon|google|apple|netflix|spotify)\b"
)
_CPF = re.compile(r"\*{3}\.?\d{3}\.?\d{3}-?\*{2}|\b\d{3}\.\d{3}\.\d{3}-\d{2}\b")
_PARA_PERSON = re.compile(r"\bpix\b|\bted\b|\bdoc\b|\btransf")
# palavras do extrato que aparecem em tudo e não ajudam a achar lançamentos parecidos
_GENERIC = {
    "pix", "ted", "doc", "compra", "pagamento", "pagto", "enviado", "enviada", "recebido",
    "recebida", "transferencia", "transf", "para", "cartao", "debito", "credito", "parcela",
    "qrcode", "conta", "via", "com", "dos", "das", "ltda",
}  # fmt: skip


def coherent(kind_category: str, t: dict[str, Any]) -> bool:
    """Categoria do sentido certo: saída em despesa, entrada em receita (estorno e reembolso podem
    voltar para a despesa); transferência e investimento valem nos dois sentidos."""
    if kind_category in ("transferencia", "investimento") or not t["valor"]:
        return True
    if t["valor"] < 0:
        return kind_category == "despesa"
    return kind_category == "receita" or (
        kind_category == "despesa" and bool(_LAP.search(normalize(t["descricao"])))
    )


def _direction(t: dict[str, Any]) -> str:
    return "entrada" if t["valor"] > 0 else "saida" if t["valor"] < 0 else "zero"


def _person(t: dict[str, Any]) -> str:
    """'fisica' só com CPF ou nome de gente num Pix/TED; 'empresa' pelo nome; '' na dúvida (pista
    errada atrapalha mais que nenhuma)."""
    if _CPF.search(t["descricao"]):
        return "fisica"
    who = normalize(t.get("contraparte") or "")
    if not who:
        return ""
    if _COMPANY.search(who):
        return "empresa"
    words = who.split()
    if _PARA_PERSON.search(normalize(t["descricao"])) and 2 <= len(words) <= 5:
        return "fisica" if all(p.isalpha() for p in words) else ""
    return ""


def _tokens(t: dict[str, Any]) -> set[str]:
    text = normalize(f"{t.get('contraparte', '')} {t['descricao']}")
    return {p for p in re.findall(r"[a-z]{3,}", text) if p not in _GENERIC}


@dataclass
class _Context:
    codigo: dict[str, str]  # id da categoria → c1, c2...
    tipos: dict[str, str]  # id da categoria → tipo
    contas: dict[str, str]  # id da conta → tipo
    lista: list[dict[str, Any]]
    base: list[tuple[dict[str, Any], set[str]]]  # classificados pelo usuário, um por contraparte
    raridade: Counter[str]  # em quantos lançamentos da base cada palavra aparece

    @property
    def by_code(self) -> dict[str, str]:
        return {v: k for k, v in self.codigo.items()}


def _context(arm: Warehouse, delete: set[str]) -> _Context:
    cats = arm.todos("categorias")
    code = {c["id"]: f"c{i}" for i, c in enumerate(cats, 1)}
    # Exemplos só do que o usuário (ou a regra dele) classificou; o mais recente por contraparte.
    unicas: dict[str, dict[str, Any]] = {}
    for t in sorted(arm.todos("transacoes"), key=lambda t: t["data"] or ""):
        if t["categoria_id"] in code and t["id"] not in delete and not t.get("categoria_ia"):
            unicas[normalize(t.get("contraparte") or t["descricao"])] = t
    uses: dict[str, Counter[str]] = {}
    for t in unicas.values():
        name = (t.get("contraparte") or t["descricao"])[:40]
        uses.setdefault(t["categoria_id"], Counter())[name] += 1
    items = []
    for c in cats:
        item: dict[str, Any] = {"cat": code[c["id"]], "nome": c["nome"], "tipo": c["tipo"]}
        if c["id"] in uses:
            item["ex"] = [n for n, _ in uses[c["id"]].most_common(4)]
        items.append(item)
    base = [(t, _tokens(t)) for t in unicas.values()]
    raridade: Counter[str] = Counter(p for _, tk in base for p in tk)
    return _Context(
        code,
        {c["id"]: c["tipo"] for c in cats},
        {c["id"]: c["tipo"] for c in arm.todos("contas")},
        items,
        base,
        raridade,
    )


def _examples(batch: list[dict[str, Any]], ctx: _Context) -> list[dict[str, Any]]:
    """Até 2 classificados parecidos por lançamento; palavra rara em comum vale mais que comum."""
    chosen: dict[str, dict[str, Any]] = {}
    for t in batch:
        target = _tokens(t)
        notes = [
            (sum(1 / ctx.raridade[p] for p in target & tk), f) for f, tk in ctx.base if target & tk
        ]
        for _, f in sorted(notes, key=lambda p: -p[0])[:2]:
            chosen.setdefault(
                f["id"],
                {
                    "texto": f["descricao"][:80],
                    "sentido": _direction(f),
                    "cat": ctx.codigo[f["categoria_id"]],
                },
            )
    return list(chosen.values())[:EXAMPLES]


def _hints(n: int, t: dict[str, Any], ctx: _Context, motivo: str) -> dict[str, Any]:
    item: dict[str, Any] = {
        "n": n,
        "texto": t["descricao"][:120],
        "quem": t.get("contraparte", ""),
        "sentido": _direction(t),
        "valor": round(abs(t["valor"]), 2),
        "conta": ctx.contas.get(t["conta_id"], ""),
    }
    extras = {
        "pessoa": _person(t),
        "forma_detectada": shape_payment(t["descricao"]),
        "parcela": t.get("parcela", ""),
        "obs": t.get("observacao", "")[:80],
        "atual": ctx.codigo.get(t["categoria_id"], ""),
        "corrija": motivo,
    }
    item.update({k: v for k, v in extras.items() if v})
    return item


async def _classify(
    llm: ChatLLM, batch: list[dict[str, Any]], ctx: _Context, motivos: dict[str, str]
) -> dict[str, dict[str, Any]]:
    """Resposta da IA por id da transação ({"cat": "c3", "forma": "pix"})."""
    request = {
        "categorias": ctx.lista,
        "exemplos": _examples(batch, ctx),
        "lancamentos": [
            _hints(n, t, ctx, motivos.get(t["id"], "")) for n, t in enumerate(batch, 1)
        ],
    }
    data = await _ask_json(llm, SYSTEM_CATEGORIES, json.dumps(request, ensure_ascii=False))
    items = data.get("itens", []) if isinstance(data, dict) else data
    output: dict[str, dict[str, Any]] = {}
    for r in items if isinstance(items, list) else []:
        try:
            n = int(r["n"])
        except (KeyError, TypeError, ValueError):
            continue
        if 1 <= n <= len(batch):
            output[batch[n - 1]["id"]] = r
    return output


def _reason(t: dict[str, Any], r: dict[str, Any] | None, ctx: _Context) -> str:
    """Por que a resposta não serve ('' = serve); categoria vazia é resposta válida."""
    if r is None:
        return "faltou a resposta deste lançamento"
    cat = str(r.get("cat") or "")
    if not cat:
        return ""
    cat_id = ctx.by_code.get(cat)
    if cat_id is None:
        return f"o código {cat} não existe; use um da lista de categorias"
    kind = ctx.tipos[cat_id]
    if cat_id != t["categoria_id"] and not coherent(kind, t):
        return f"{cat} é de {kind}, mas o lançamento é {_direction(t)}"
    return ""


def _shape(t: dict[str, Any], account_kind: str, sugerida: Any) -> str:
    """Forma sempre definida: a gravada (se não for `outro`), a do texto, a da IA e, por fim,
    crédito no cartão ou `outro`."""
    current = t.get("forma_pagamento") or ""
    if current and current != "outro":
        return current
    return (
        shape_payment(t["descricao"], account_kind)
        or (sugerida if sugerida in SHAPES else "")
        or ("credito" if account_kind == "cartao" else "outro")
    )


async def categorize(
    llm: ChatLLM,
    arm: Warehouse,
    limite: int = 400,
    ids: list[str] | None = None,
    revisar: bool = False,
) -> dict[str, int]:
    """Categoriza com a IA os lançamentos sem categoria e sempre define a forma de pagamento (o tipo
    do lançamento); com [ids], só esses (os recém-importados). Com [revisar] (reconferência), também
    reavalia o que a IA categorizou antes e o que está na categoria do sentido errado; a IA vê a
    categoria atual e a mantém ou troca. O que o usuário escolheu e está coerente não é tocado."""
    if not arm.todos("categorias"):
        raise Invalid("Cadastre as categorias antes de categorizar com a IA.")
    kinds = {c["id"]: c["tipo"] for c in arm.todos("categorias")}
    criteria = set(ids) if ids is not None else None

    def precisa_categoria(t: dict[str, Any]) -> bool:
        if not t["categoria_id"] or t["categoria_id"] not in kinds:
            return True
        return revisar and (
            bool(t.get("categoria_ia")) or not coherent(kinds[t["categoria_id"]], t)
        )

    def pendente(t: dict[str, Any]) -> bool:
        if criteria is not None and t["id"] not in criteria:
            return False
        shape = t.get("forma_pagamento") or ""
        return precisa_categoria(t) or not shape or (revisar and shape == "outro")

    pending = sorted(
        (t for t in arm.todos("transacoes") if pendente(t)), key=lambda t: bool(t["categoria_id"])
    )[:limite]
    ctx = _context(arm, {t["id"] for t in pending})
    done = {"analisadas": len(pending), "categorizadas": 0, "trocadas": 0, "formas": 0}
    for i in range(0, len(pending), BATCH_CATEGORIES):
        batch = pending[i : i + BATCH_CATEGORIES]
        answers = await _classify(llm, batch, ctx, {})
        motivos = {t["id"]: m for t in batch if (m := _reason(t, answers.get(t["id"]), ctx))}
        if motivos:  # segunda chance só para o que veio faltando ou incoerente
            of_new = await _classify(llm, [t for t in batch if t["id"] in motivos], ctx, motivos)
            for id_, r in of_new.items():
                if not _reason(arm.obter("transacoes", id_), r, ctx):
                    answers[id_] = r
        with arm.lock:
            for t in batch:
                r = answers.get(t["id"]) or {}
                current = arm.obter("transacoes", t["id"])  # o usuário pode ter mexido no meio
                cat_id = ctx.by_code.get(str(r.get("cat") or ""))
                if (
                    cat_id
                    and cat_id != current["categoria_id"]
                    and precisa_categoria(current)
                    and not _reason(current, r, ctx)
                ):
                    done["trocadas" if current["categoria_id"] else "categorizadas"] += 1
                    current["categoria_id"] = cat_id
                    current["categoria_ia"] = True
                shape = _shape(current, ctx.contas.get(current["conta_id"], ""), r.get("forma"))
                if shape != current.get("forma_pagamento"):
                    current["forma_pagamento"] = shape
                    done["formas"] += 1
            arm.salvar("transacoes")
    return done


# ---------- cenários ----------

SYSTEM_QUESTION = """Você transforma um desejo de compra em parâmetros de simulação. Responda
SOMENTE com JSON: {"descricao": "...", "tipo": "carro|moto|terreno|imovel|mcmv|outro",
"valor": 45000, "entrada": null, "prazo_meses": null, "taxa_anual": null, "sistema": null,
"custo_mensal_extra": null, "aporte_mensal": null, "marca": null, "modelo": null, "ano": null}
Use null no que a pessoa não disse (o sistema usa padrões de mercado). taxa_anual em fração
(0.24 = 24% a.a.). "Minha Casa Minha Vida" é tipo "mcmv". Valores em reais, sem texto.
Para carro/moto preencha marca, modelo e ano (EcoSport → Ford); sem valor dito, valor null (o
sistema busca na tabela FIPE)."""

SYSTEM_ANALYSIS = """Você é um planejador financeiro pessoal brasileiro, direto e honesto.
Explique em português, para leigo, em até 250 palavras e em tópicos curtos, o resultado da
simulação abaixo: quanto tempo leva para juntar, se o financiamento cabe e se compensa, os riscos
(alertas) e 2 ou 3 ações práticas para chegar lá mais rápido (cortar categorias, aumentar entrada,
prazo). Use SÓ os números dados; não invente taxas nem valores. Termine lembrando que taxas e
faixas são referências e devem ser confirmadas com o banco."""


async def interpret(llm: ChatLLM, pergunta: str) -> dict[str, Any]:
    data = await _ask_json(llm, SYSTEM_QUESTION, pergunta)
    if not isinstance(data, dict):
        raise Invalid("Não entendi o pedido: diga o que quer comprar e quanto custa.")
    return {k: v for k, v in data.items() if v is not None}


async def data_current(internet: Any, parametros: dict[str, Any]) -> dict[str, Any]:
    """FIPE do veículo e CDI de hoje pela internet da plataforma; completa o valor (se faltou) e o
    rendimento da reserva (CDI líquido de ~15% de IR). Sem internet, devolve vazio."""
    if internet is None:
        return {}
    import asyncio

    tasks = {"indicadores": internet.use("indicadores", {})}
    if parametros.get("tipo") in ("carro", "moto") and parametros.get("modelo"):
        tasks["fipe"] = internet.use("fipe", {
            "marca": parametros.get("marca", ""),
            "modelo": parametros["modelo"],
            "ano": str(parametros.get("ano") or ""),
            "tipo": "motos" if parametros.get("tipo") == "moto" else "carros",
        })
    done = dict(zip(tasks, await asyncio.gather(*tasks.values()), strict=True))
    output: dict[str, Any] = {}
    cdi = done["indicadores"].get("indicadores", {}).get("cdi_aa", {}).get("valor")
    if cdi:
        output["cdi_aa"] = cdi
        output["rendimento_mensal"] = round((1 + cdi / 100 * 0.85) ** (1 / 12) - 1, 5)
    fipe = done.get("fipe") or {}
    if fipe.get("media"):
        output["fipe"] = {k: fipe[k] for k in ("marca", "menor", "maior", "media", "fonte")}
        output["fipe"]["referencia"] = fipe["versoes"][0]["referencia"]
        output["fipe"]["versoes"] = [
            f"{v['modelo']} {v['ano']}: R$ {v['valor']:.0f}" for v in fipe["versoes"][:6]
        ]
    elif fipe.get("erro"):
        output["fipe_erro"] = fipe["erro"]
    return output


def _summary_for_ai(r: dict[str, Any]) -> dict[str, Any]:
    """O resultado sem as séries longas (a IA só precisa dos números-chave)."""
    proj = r["projecao"]
    return {
        **{
            k: r[k]
            for k in (
                "pedido",
                "juntar",
                "financiar",
                "financiar_com_reserva",
                "mcmv",
                "veredito",
                "alertas",
            )
        },
        "realidade": {k: v for k, v in r["realidade"].items() if k != "historico"},
        "saldo_em_12_meses": {
            k: (v[11]["saldo"] if len(v) > 11 else None) for k, v in proj.items()
        },
        "parcelamentos_ativos": len(r["parcelamentos"]),
        # já interpretado: o modelo local errava a comparação de percentuais
        "comprometimento_da_renda": (
            None
            if r["financiar"]["comprometimento"] is None
            else f"{r['financiar']['comprometimento']:.1%} da renda; limite recomendado 30%; "
            + (
                "ACIMA do limite"
                if r["financiar"]["comprometimento"] > 0.30
                else "dentro do limite"
            )
        ),
        "hoje": date.today().isoformat(),
    }


async def analyze(
    llm: ChatLLM, pergunta: str, resultado: dict[str, Any], current: dict[str, Any] | None = None
) -> str:
    extra = (
        "\n\nDados de hoje da internet (FIPE, CDI): "
        + json.dumps(current, ensure_ascii=False)
        + "\nCompare o valor pedido com a FIPE e cite a referência."
        if current
        else ""
    )
    text = await llm(
        [
            {"role": "system", "content": SYSTEM_ANALYSIS},
            {
                "role": "user",
                "content": f"Pergunta: {pergunta}\n\nSimulação:\n"
                + json.dumps(_summary_for_ai(resultado), ensure_ascii=False)
                + extra,
            },
        ]
    )
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()


# ---------- conversa (texto ou voz) ----------

SYSTEM_CONVERSATION = """Você é um planejador financeiro pessoal brasileiro numa conversa por voz com a
dona destes dados. Responda em português, curto e falado: no máximo 3 frases (até 60 palavras),
sem listas, sem markdown, valores arredondados ("uns 2 mil e 300 reais"). Use SÓ os dados abaixo;
se faltar o dado, diga que ele não está nos extratos importados. Seja direto e honesto.

Dados financeiros (JSON):
"""


def context_financial(arm: Warehouse, hoje: date | None = None) -> dict[str, Any]:
    """O que a IA sabe na conversa: os últimos 6 meses, as categorias do último mês fechado,
    reserva e parcelas em aberto. Compacto para o prompt ser lido rápido."""
    from financas import scenarios, reports

    hoje = hoje or date.today()
    months = scenarios.history_monthly(arm, 6, hoje)
    last = months[-1]["mes"] if months else hoje.isoformat()[:7]
    month = reports.summary(arm, last)
    parcs = [p for p in scenarios.installment_plans(arm, hoje) if p["ativo"]]
    return {
        "hoje": hoje.isoformat(),
        "meses": months,
        "reserva_atual": round(scenarios.reserve_current(arm), 2),
        f"categorias_{last}": [
            {k: c[k] for k in ("nome", "tipo", "valor", "orcamento")}
            for c in month["categorias"][:12]
            if c["valor"] or c["orcamento"]
        ],
        "indicadores": month["indicadores"],
        "parcelas_em_aberto": {
            "quantidade": len(parcs),
            "por_mes": round(sum(p["valor_parcela"] for p in parcs), 2),
            "restante": round(sum(p["valor_restante"] for p in parcs), 2),
        },
    }


async def chat(
    llm: ChatLLM,
    messages: list[dict[str, str]],
    contexto: dict[str, Any],
    cenario: dict[str, Any] | None = None,
) -> str:
    """Uma resposta curta da conversa; [cenario] (`pergunta`, `analise`) é a simulação aberta."""
    system = SYSTEM_CONVERSATION + json.dumps(contexto, ensure_ascii=False)
    if cenario and cenario.get("pergunta"):
        system += (
            f"\n\nSimulação aberta na tela: {cenario['pergunta']}\n"
            f"Análise já mostrada: {str(cenario.get('analise') or '')[:2500]}"
        )
    text = await llm([{"role": "system", "content": system}, *messages[-12:]])
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()
