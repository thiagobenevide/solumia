"""AI in the Finance module: reads statements the code does not recognize (PDF, odd layout),
categorizes what the rules missed and chats about purchase scenarios. The LLM only interprets text;
the math (balances, installments, deadlines) is always done in Python (`scenarios`)."""

import json
import re
from collections import Counter
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import date
from typing import Any

from finance.statement import _data, normalize, shape_payment
from finance.warehouse import Invalid, Warehouse

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]

CHUNK = 9000  # statement characters per request (fits the local LLM context with room to spare)
# smaller batch: the local LLM makes fewer mistakes and the second chance is cheap
BATCH_CATEGORIES = 25


def extract_json(answer: str) -> Any:
    """First JSON object/list of the answer (ignores <think>, fences and surrounding text)."""
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
            {"role": "user", "content": f"{e} Respond again ONLY with the JSON."},
        ]
        return extract_json(await llm(messages))


# ---------- extratos ----------

SYSTEM_STATEMENT = """You extract entries from Brazilian bank statements (Nubank, Inter, Banco do
Brasil, Itaú, Mercado Pago and others). Respond ONLY with JSON:
{"lancamentos": [{"data": "YYYY-MM-DD", "descricao": "...", "valor": -123.45}]}
Rules: outflows (purchases, payments, Pix sent, fees) with a NEGATIVE value; inflows (salary, Pix
received, refund) POSITIVE. Ignore balance lines, totals, headers and advertising. Keep the
description exactly as it is in the statement, including "Parcela 2/10". If the year does not
appear in the line, use the one of the statement period."""

SYSTEM_INVOICE = (
    SYSTEM_STATEMENT
    + """
This file is a CREDIT CARD BILL: purchases are NEGATIVE; bill payment, refund and credit are
POSITIVE."""
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
    cabecalho = "\n".join(text.splitlines()[:15])  # period and bank, for the year of the dates
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


# ---------- categories ----------
# To help the local LLM, Python does the groundwork: computes the hints of each entry
# (direction, person or company, payment method already detected, installment), replaces the long
# ids with short codes (c1, n1), shows what the user already put in each category and similar
# entries already classified (examples, by rare words in common) and checks the answer: a missing
# category or one of the wrong direction goes back to the AI once, with the reason.

SYSTEM_CATEGORIES = """You classify the bank statement entries of ONE person in Brazil.

Input (JSON):
- "categorias": code (c1, c2...), name, type (despesa, receita, investimento, transferencia) and
  "ex" = counterparties the user already put in it.
- "exemplos": similar entries the user already classified. Follow THE SAME criterion as the user.
- "lancamentos": n, texto (as it came from the bank), quem (deduced counterparty), sentido
  (entrada/saida), valor, conta (corrente, cartao, poupanca...) and, when present: pessoa
  (fisica/empresa), forma_detectada, parcela, obs (the user's note), atual (today's category, in
  a recheck) and corrija (error of the previous answer).

How to decide the category, in this order:
1. Example with the same counterparty or almost the same text → the example's category.
2. Known brand: iFood/Rappi → food; Uber/99 → transport; Netflix/Spotify/Google/Apple →
   subscriptions; Drogasil/Raia/Pague Menos → health or pharmacy; Shell/Ipiranga/BR/gas station →
   fuel; Amazon/Mercado Livre/Shopee/Magalu → shopping; Sabesp/Enel/Claro/Vivo → household bills.
3. Line of business in the name: padaria, mercado, supermercado, açougue, restaurante,
   lanchonete, auto peças, pet, academia, escola, clínica, ótica, loja.
4. The user's own money changing place is NEITHER expense NOR income: credit card bill payment,
   transfer between the user's accounts → transferencia; investment, redemption, CDB, caixinha,
   Tesouro, brokerage → investimento.
5. Pix/TED to an individual with no other clue → transferencia. Received from an individual →
   receita (or transferencia, if it looks like a return between accounts).
6. Fee, annual fee, IOF, interest, fine → the fees/charges/banks category, if there is one.
Direction rule: saida uses despesa; entrada uses receita; transferencia and investimento apply to
both. Refund, reimbursement and cashback may go back to the original expense's category.
If there is "atual" and it is right, repeat it. Use "" only if no category truly fits.
Match the category names, which are in Portuguese, by meaning.

Forma (the entry type): ALWAYS fill it with one of these: pix, debito, credito, boleto, ted, doc,
transferencia, saque, deposito, tarifa, investimento, dinheiro, outro. When there is
forma_detectada, repeat it. Purchase on the cartao account → credito; store purchase on the
corrente account with no other clue → debito.

Respond ONLY with JSON, one item per entry, with no explanations:
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

EXAMPLES = 20  # history examples per request
_LAP = re.compile(r"\bestorn|\breembols|\bcashback|\bdevoluc|\bcancelad")
_COMPANY = re.compile(
    r"\b(ltda|eireli|s\.?a|me|epp|cia|comercio|servicos|industria|loja|lojas|mercado|supermercado|"
    r"posto|farmacia|drogaria|restaurante|lanchonete|padaria|bar|pet|shop|store|pagamentos|digital|"
    r"tecnologia|ifood|uber|amazon|google|apple|netflix|spotify)\b"
)
_CPF = re.compile(r"\*{3}\.?\d{3}\.?\d{3}-?\*{2}|\b\d{3}\.\d{3}\.\d{3}-\d{2}\b")
_PARA_PERSON = re.compile(r"\bpix\b|\bted\b|\bdoc\b|\btransf")
# statement words that show up everywhere and do not help find similar entries
_GENERIC = {
    "pix", "ted", "doc", "compra", "pagamento", "pagto", "enviado", "enviada", "recebido",
    "recebida", "transferencia", "transf", "para", "cartao", "debito", "credito", "parcela",
    "qrcode", "conta", "via", "com", "dos", "das", "ltda",
}  # fmt: skip


def coherent(kind_category: str, t: dict[str, Any]) -> bool:
    """Category of the right direction: outflow as expense, inflow as income (chargebacks and
    refunds may go back to the expense); transfer and investment are valid both ways."""
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
    """'fisica' only with a CPF or a person's name in a Pix/TED; 'empresa' by the name; '' when in
    doubt (a wrong hint hurts more than none)."""
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
    codigo: dict[str, str]  # category id → c1, c2...
    tipos: dict[str, str]  # category id → type
    contas: dict[str, str]  # account id → type
    lista: list[dict[str, Any]]
    base: list[tuple[dict[str, Any], set[str]]]  # classified by the user, one per counterparty
    raridade: Counter[str]  # in how many entries of the base each word appears

    @property
    def by_code(self) -> dict[str, str]:
        return {v: k for k, v in self.codigo.items()}


def _context(arm: Warehouse, delete: set[str]) -> _Context:
    cats = arm.todos("categorias")
    code = {c["id"]: f"c{i}" for i, c in enumerate(cats, 1)}
    # Examples only of what the user (or their rule) classified; the most recent per counterparty.
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
    """Up to 2 similar classified entries per entry; a rare word in common counts more than a
    common one."""
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
    """AI answer per transaction id ({"cat": "c3", "forma": "pix"})."""
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
    """Why the answer is not usable ('' = usable); an empty category is a valid answer."""
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
    """Payment method always defined: the stored one (unless `outro`), the one from the text, the
    AI's and, last, card credit or `outro`."""
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
    """Categorizes the uncategorized entries with the AI and always sets the payment method (the
    entry type); with ids, only those (the just imported). With review (recheck), it also
    reassesses what the AI categorized before and what sits in a category of the wrong direction;
    the AI sees the current category and keeps or changes it. What the user chose and is coherent
    is not touched."""
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
        if motivos:  # second chance only for what came back missing or incoherent
            of_new = await _classify(llm, [t for t in batch if t["id"] in motivos], ctx, motivos)
            for id_, r in of_new.items():
                if not _reason(arm.obter("transacoes", id_), r, ctx):
                    answers[id_] = r
        with arm.lock:
            for t in batch:
                r = answers.get(t["id"]) or {}
                # the user may have changed things in the meantime
                current = arm.obter("transacoes", t["id"])
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


# ---------- scenarios ----------

SYSTEM_QUESTION = """You turn a purchase wish (in Brazilian Portuguese) into simulation parameters.
Respond ONLY with JSON: {"descricao": "...", "tipo": "carro|moto|terreno|imovel|mcmv|outro",
"valor": 45000, "entrada": null, "prazo_meses": null, "taxa_anual": null, "sistema": null,
"custo_mensal_extra": null, "aporte_mensal": null, "marca": null, "modelo": null, "ano": null}
Use null for whatever the person did not say (the system uses market defaults). taxa_anual as a
fraction (0.24 = 24% a year). "Minha Casa Minha Vida" is tipo "mcmv". Values in reais, no text.
"descricao" in Brazilian Portuguese. For carro/moto fill in marca, modelo and ano (EcoSport →
Ford); with no value said, valor null (the system looks it up in the FIPE table)."""

SYSTEM_ANALYSIS = """You are a Brazilian personal financial planner, direct and honest. Explain in
Brazilian Portuguese, for a layperson, in up to 250 words and in short bullet points, the result of
the simulation below: how long it takes to save up, whether the financing fits and pays off, the
risks (alerts) and 2 or 3 practical actions to get there faster (cut categories, raise the down
payment, term). Use ONLY the numbers given; do not invent rates or values. End by reminding that
rates and brackets are references and must be confirmed with the bank."""


async def interpret(llm: ChatLLM, pergunta: str) -> dict[str, Any]:
    data = await _ask_json(llm, SYSTEM_QUESTION, pergunta)
    if not isinstance(data, dict):
        raise Invalid("Não entendi o pedido: diga o que quer comprar e quanto custa.")
    return {k: v for k, v in data.items() if v is not None}


async def data_current(internet: Any, parameters: dict[str, Any]) -> dict[str, Any]:
    """Vehicle FIPE and today's CDI through the platform internet tools; fills the value (if
    missing) and the reserve yield (CDI net of ~15% income tax). Without internet, returns empty."""
    if internet is None:
        return {}
    import asyncio

    tasks = {"indicadores": internet.use("indicadores", {})}
    if parameters.get("tipo") in ("carro", "moto") and parameters.get("modelo"):
        tasks["fipe"] = internet.use("fipe", {
            "marca": parameters.get("marca", ""),
            "modelo": parameters["modelo"],
            "ano": str(parameters.get("ano") or ""),
            "tipo": "motos" if parameters.get("tipo") == "moto" else "carros",
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
    """The result without the long series (the AI only needs the key numbers)."""
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
        # already interpreted: the local model got percentage comparisons wrong
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
                "content": f"Question: {pergunta}\n\nSimulation:\n"
                + json.dumps(_summary_for_ai(resultado), ensure_ascii=False)
                + extra,
            },
        ]
    )
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()


# ---------- conversation (text or voice) ----------

SYSTEM_CONVERSATION = """You are a Brazilian personal financial planner in a voice conversation with
the owner of this data. Answer in Brazilian Portuguese, short and spoken: at most 3 sentences (up to
60 words), no lists, no markdown, rounded values ("uns 2 mil e 300 reais"). Use ONLY the data below;
if the data is missing, say it is not in the imported statements. Be direct and honest.

Financial data (JSON):
"""


def context_financial(arm: Warehouse, hoje: date | None = None) -> dict[str, Any]:
    """What the AI knows in the conversation: the last 6 months, the categories of the last closed
    month, reserve and open installments. Compact so the prompt is read quickly."""
    from finance import reports, scenarios

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
    """A short conversation answer; the scenario (`pergunta`, `analise`) is the open simulation."""
    system = SYSTEM_CONVERSATION + json.dumps(contexto, ensure_ascii=False)
    if cenario and cenario.get("pergunta"):
        system += (
            f"\n\nSimulação aberta na tela: {cenario['pergunta']}\n"
            f"Análise já mostrada: {str(cenario.get('analise') or '')[:2500]}"
        )
    text = await llm([{"role": "system", "content": system}, *messages[-12:]])
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()
