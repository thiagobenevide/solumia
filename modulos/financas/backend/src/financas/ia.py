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

from financas.armazem import Armazem, Invalido
from financas.extrato import _data, forma_pagamento, normalizar

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]

PEDACO = 9000  # caracteres de extrato por pedido (cabe no contexto do LLM local com folga)
LOTE_CATEGORIAS = 25  # lote menor: o LLM local erra menos e a segunda chance sai barata


def extrair_json(resposta: str) -> Any:
    """Primeiro objeto/lista JSON da resposta (ignora <think>, cercas e texto em volta)."""
    texto = re.sub(r"<think>.*?</think>", "", resposta, flags=re.DOTALL)
    inicio = min((i for i in (texto.find("{"), texto.find("[")) if i >= 0), default=-1)
    if inicio < 0:
        raise Invalido("A IA não devolveu JSON.")
    try:
        dados, _ = json.JSONDecoder().raw_decode(texto[inicio:])
    except json.JSONDecodeError as e:
        raise Invalido(f"A IA devolveu um JSON inválido: {e.msg}.") from e
    return dados


async def _pedir_json(llm: ChatLLM, sistema: str, usuario: str) -> Any:
    mensagens = [{"role": "system", "content": sistema}, {"role": "user", "content": usuario}]
    resposta = await llm(mensagens)
    try:
        return extrair_json(resposta)
    except Invalido as e:
        mensagens += [
            {"role": "assistant", "content": resposta[:3000]},
            {"role": "user", "content": f"{e} Responda de novo SOMENTE com o JSON."},
        ]
        return extrair_json(await llm(mensagens))


# ---------- extratos ----------

SISTEMA_EXTRATO = """Você extrai lançamentos de extratos bancários brasileiros (Nubank, Inter,
Banco do Brasil, Itaú, Mercado Pago e outros). Responda SOMENTE com JSON:
{"lancamentos": [{"data": "AAAA-MM-DD", "descricao": "...", "valor": -123.45}]}
Regras: saídas (compras, pagamentos, Pix enviado, tarifas) com valor NEGATIVO; entradas (salário,
Pix recebido, estorno) POSITIVO. Ignore linhas de saldo, totais, cabeçalhos e propaganda. Mantenha
a descrição como está no extrato, inclusive "Parcela 2/10". Se o ano não aparecer na linha, use o
do período do extrato."""

SISTEMA_FATURA = (
    SISTEMA_EXTRATO
    + """
Este arquivo é FATURA DE CARTÃO: compras são NEGATIVAS; pagamento da fatura, estorno e crédito são
POSITIVOS."""
)


def _pedacos(texto: str) -> list[str]:
    linhas, atual, saida = texto.splitlines(), [], []
    tamanho = 0
    for linha in linhas:
        if tamanho + len(linha) > PEDACO and atual:
            saida.append("\n".join(atual))
            atual, tamanho = [], 0
        atual.append(linha)
        tamanho += len(linha) + 1
    if atual:
        saida.append("\n".join(atual))
    return saida


async def extrair_lancamentos(
    llm: ChatLLM, texto: str, fatura: bool = False
) -> list[dict[str, Any]]:
    itens: list[dict[str, Any]] = []
    cabecalho = "\n".join(texto.splitlines()[:15])  # período e banco, para o ano das datas
    for i, pedaco in enumerate(_pedacos(texto)):
        contexto = f"Início do extrato (contexto):\n{cabecalho}\n\n" if i else ""
        dados = await _pedir_json(
            llm,
            SISTEMA_FATURA if fatura else SISTEMA_EXTRATO,
            f"{contexto}Trecho do extrato:\n{pedaco}",
        )
        lista = dados.get("lancamentos", []) if isinstance(dados, dict) else dados
        for it in lista if isinstance(lista, list) else []:
            try:
                itens.append(
                    {
                        "data": _data(str(it["data"])),
                        "descricao": str(it["descricao"]).strip()[:200],
                        "valor": round(float(it["valor"]), 2),
                        "ref": "",
                    }
                )
            except (KeyError, TypeError, ValueError, Invalido):
                continue
    if not itens:
        raise Invalido("A IA não achou lançamentos no arquivo.")
    return itens


# ---------- categorias ----------
# Para o LLM local entender melhor, o Python faz o trabalho de base: calcula as pistas de cada
# lançamento (sentido, pessoa física ou empresa, forma já detectada, parcela), troca os ids longos
# por códigos curtos (c1, n1), mostra o que o próprio usuário já pôs em cada categoria e os
# lançamentos parecidos já classificados (exemplos, por palavras raras em comum) e confere a
# resposta: categoria inexistente ou do sentido errado volta para a IA uma vez, com o motivo.

SISTEMA_CATEGORIAS = """Você classifica lançamentos do extrato bancário de UMA pessoa no Brasil.

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

FORMAS = {
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

EXEMPLOS = 20  # exemplos do histórico por pedido
_VOLTA = re.compile(r"\bestorn|\breembols|\bcashback|\bdevoluc|\bcancelad")
_EMPRESA = re.compile(
    r"\b(ltda|eireli|s\.?a|me|epp|cia|comercio|servicos|industria|loja|lojas|mercado|supermercado|"
    r"posto|farmacia|drogaria|restaurante|lanchonete|padaria|bar|pet|shop|store|pagamentos|digital|"
    r"tecnologia|ifood|uber|amazon|google|apple|netflix|spotify)\b"
)
_CPF = re.compile(r"\*{3}\.?\d{3}\.?\d{3}-?\*{2}|\b\d{3}\.\d{3}\.\d{3}-\d{2}\b")
_PARA_PESSOA = re.compile(r"\bpix\b|\bted\b|\bdoc\b|\btransf")
# palavras do extrato que aparecem em tudo e não ajudam a achar lançamentos parecidos
_GENERICAS = {
    "pix", "ted", "doc", "compra", "pagamento", "pagto", "enviado", "enviada", "recebido",
    "recebida", "transferencia", "transf", "para", "cartao", "debito", "credito", "parcela",
    "qrcode", "conta", "via", "com", "dos", "das", "ltda",
}  # fmt: skip


def coerente(tipo_categoria: str, t: dict[str, Any]) -> bool:
    """Categoria do sentido certo: saída em despesa, entrada em receita (estorno e reembolso podem
    voltar para a despesa); transferência e investimento valem nos dois sentidos."""
    if tipo_categoria in ("transferencia", "investimento") or not t["valor"]:
        return True
    if t["valor"] < 0:
        return tipo_categoria == "despesa"
    return tipo_categoria == "receita" or (
        tipo_categoria == "despesa" and bool(_VOLTA.search(normalizar(t["descricao"])))
    )


def _sentido(t: dict[str, Any]) -> str:
    return "entrada" if t["valor"] > 0 else "saida" if t["valor"] < 0 else "zero"


def _pessoa(t: dict[str, Any]) -> str:
    """'fisica' só com CPF ou nome de gente num Pix/TED; 'empresa' pelo nome; '' na dúvida (pista
    errada atrapalha mais que nenhuma)."""
    if _CPF.search(t["descricao"]):
        return "fisica"
    quem = normalizar(t.get("contraparte") or "")
    if not quem:
        return ""
    if _EMPRESA.search(quem):
        return "empresa"
    palavras = quem.split()
    if _PARA_PESSOA.search(normalizar(t["descricao"])) and 2 <= len(palavras) <= 5:
        return "fisica" if all(p.isalpha() for p in palavras) else ""
    return ""


def _tokens(t: dict[str, Any]) -> set[str]:
    texto = normalizar(f"{t.get('contraparte', '')} {t['descricao']}")
    return {p for p in re.findall(r"[a-z]{3,}", texto) if p not in _GENERICAS}


@dataclass
class _Contexto:
    codigo: dict[str, str]  # id da categoria → c1, c2...
    tipos: dict[str, str]  # id da categoria → tipo
    contas: dict[str, str]  # id da conta → tipo
    lista: list[dict[str, Any]]
    base: list[tuple[dict[str, Any], set[str]]]  # classificados pelo usuário, um por contraparte
    raridade: Counter[str]  # em quantos lançamentos da base cada palavra aparece

    @property
    def por_codigo(self) -> dict[str, str]:
        return {v: k for k, v in self.codigo.items()}


def _contexto(arm: Armazem, excluir: set[str]) -> _Contexto:
    cats = arm.todos("categorias")
    codigo = {c["id"]: f"c{i}" for i, c in enumerate(cats, 1)}
    # Exemplos só do que o usuário (ou a regra dele) classificou; o mais recente por contraparte.
    unicas: dict[str, dict[str, Any]] = {}
    for t in sorted(arm.todos("transacoes"), key=lambda t: t["data"] or ""):
        if t["categoria_id"] in codigo and t["id"] not in excluir and not t.get("categoria_ia"):
            unicas[normalizar(t.get("contraparte") or t["descricao"])] = t
    usos: dict[str, Counter[str]] = {}
    for t in unicas.values():
        nome = (t.get("contraparte") or t["descricao"])[:40]
        usos.setdefault(t["categoria_id"], Counter())[nome] += 1
    lista = []
    for c in cats:
        item: dict[str, Any] = {"cat": codigo[c["id"]], "nome": c["nome"], "tipo": c["tipo"]}
        if c["id"] in usos:
            item["ex"] = [n for n, _ in usos[c["id"]].most_common(4)]
        lista.append(item)
    base = [(t, _tokens(t)) for t in unicas.values()]
    raridade: Counter[str] = Counter(p for _, tk in base for p in tk)
    return _Contexto(
        codigo,
        {c["id"]: c["tipo"] for c in cats},
        {c["id"]: c["tipo"] for c in arm.todos("contas")},
        lista,
        base,
        raridade,
    )


def _exemplos(lote: list[dict[str, Any]], ctx: _Contexto) -> list[dict[str, Any]]:
    """Até 2 classificados parecidos por lançamento; palavra rara em comum vale mais que comum."""
    escolhidos: dict[str, dict[str, Any]] = {}
    for t in lote:
        alvo = _tokens(t)
        notas = [
            (sum(1 / ctx.raridade[p] for p in alvo & tk), f) for f, tk in ctx.base if alvo & tk
        ]
        for _, f in sorted(notas, key=lambda p: -p[0])[:2]:
            escolhidos.setdefault(
                f["id"],
                {
                    "texto": f["descricao"][:80],
                    "sentido": _sentido(f),
                    "cat": ctx.codigo[f["categoria_id"]],
                },
            )
    return list(escolhidos.values())[:EXEMPLOS]


def _pistas(n: int, t: dict[str, Any], ctx: _Contexto, motivo: str) -> dict[str, Any]:
    item: dict[str, Any] = {
        "n": n,
        "texto": t["descricao"][:120],
        "quem": t.get("contraparte", ""),
        "sentido": _sentido(t),
        "valor": round(abs(t["valor"]), 2),
        "conta": ctx.contas.get(t["conta_id"], ""),
    }
    extras = {
        "pessoa": _pessoa(t),
        "forma_detectada": forma_pagamento(t["descricao"]),
        "parcela": t.get("parcela", ""),
        "obs": t.get("observacao", "")[:80],
        "atual": ctx.codigo.get(t["categoria_id"], ""),
        "corrija": motivo,
    }
    item.update({k: v for k, v in extras.items() if v})
    return item


async def _classificar(
    llm: ChatLLM, lote: list[dict[str, Any]], ctx: _Contexto, motivos: dict[str, str]
) -> dict[str, dict[str, Any]]:
    """Resposta da IA por id da transação ({"cat": "c3", "forma": "pix"})."""
    pedido = {
        "categorias": ctx.lista,
        "exemplos": _exemplos(lote, ctx),
        "lancamentos": [
            _pistas(n, t, ctx, motivos.get(t["id"], "")) for n, t in enumerate(lote, 1)
        ],
    }
    dados = await _pedir_json(llm, SISTEMA_CATEGORIAS, json.dumps(pedido, ensure_ascii=False))
    itens = dados.get("itens", []) if isinstance(dados, dict) else dados
    saida: dict[str, dict[str, Any]] = {}
    for r in itens if isinstance(itens, list) else []:
        try:
            n = int(r["n"])
        except (KeyError, TypeError, ValueError):
            continue
        if 1 <= n <= len(lote):
            saida[lote[n - 1]["id"]] = r
    return saida


def _motivo(t: dict[str, Any], r: dict[str, Any] | None, ctx: _Contexto) -> str:
    """Por que a resposta não serve ('' = serve); categoria vazia é resposta válida."""
    if r is None:
        return "faltou a resposta deste lançamento"
    cat = str(r.get("cat") or "")
    if not cat:
        return ""
    cat_id = ctx.por_codigo.get(cat)
    if cat_id is None:
        return f"o código {cat} não existe; use um da lista de categorias"
    tipo = ctx.tipos[cat_id]
    if cat_id != t["categoria_id"] and not coerente(tipo, t):
        return f"{cat} é de {tipo}, mas o lançamento é {_sentido(t)}"
    return ""


def _forma(t: dict[str, Any], conta_tipo: str, sugerida: Any) -> str:
    """Forma sempre definida: a gravada (se não for `outro`), a do texto, a da IA e, por fim,
    crédito no cartão ou `outro`."""
    atual = t.get("forma_pagamento") or ""
    if atual and atual != "outro":
        return atual
    return (
        forma_pagamento(t["descricao"], conta_tipo)
        or (sugerida if sugerida in FORMAS else "")
        or ("credito" if conta_tipo == "cartao" else "outro")
    )


async def categorizar(
    llm: ChatLLM,
    arm: Armazem,
    limite: int = 400,
    ids: list[str] | None = None,
    revisar: bool = False,
) -> dict[str, int]:
    """Categoriza com a IA os lançamentos sem categoria e sempre define a forma de pagamento (o tipo
    do lançamento); com [ids], só esses (os recém-importados). Com [revisar] (reconferência), também
    reavalia o que a IA categorizou antes e o que está na categoria do sentido errado; a IA vê a
    categoria atual e a mantém ou troca. O que o usuário escolheu e está coerente não é tocado."""
    if not arm.todos("categorias"):
        raise Invalido("Cadastre as categorias antes de categorizar com a IA.")
    tipos = {c["id"]: c["tipo"] for c in arm.todos("categorias")}
    filtro = set(ids) if ids is not None else None

    def precisa_categoria(t: dict[str, Any]) -> bool:
        if not t["categoria_id"] or t["categoria_id"] not in tipos:
            return True
        return revisar and (
            bool(t.get("categoria_ia")) or not coerente(tipos[t["categoria_id"]], t)
        )

    def pendente(t: dict[str, Any]) -> bool:
        if filtro is not None and t["id"] not in filtro:
            return False
        forma = t.get("forma_pagamento") or ""
        return precisa_categoria(t) or not forma or (revisar and forma == "outro")

    pendentes = sorted(
        (t for t in arm.todos("transacoes") if pendente(t)), key=lambda t: bool(t["categoria_id"])
    )[:limite]
    ctx = _contexto(arm, {t["id"] for t in pendentes})
    feito = {"analisadas": len(pendentes), "categorizadas": 0, "trocadas": 0, "formas": 0}
    for i in range(0, len(pendentes), LOTE_CATEGORIAS):
        lote = pendentes[i : i + LOTE_CATEGORIAS]
        respostas = await _classificar(llm, lote, ctx, {})
        motivos = {t["id"]: m for t in lote if (m := _motivo(t, respostas.get(t["id"]), ctx))}
        if motivos:  # segunda chance só para o que veio faltando ou incoerente
            de_novo = await _classificar(llm, [t for t in lote if t["id"] in motivos], ctx, motivos)
            for id_, r in de_novo.items():
                if not _motivo(arm.obter("transacoes", id_), r, ctx):
                    respostas[id_] = r
        with arm.trava:
            for t in lote:
                r = respostas.get(t["id"]) or {}
                atual = arm.obter("transacoes", t["id"])  # o usuário pode ter mexido no meio
                cat_id = ctx.por_codigo.get(str(r.get("cat") or ""))
                if (
                    cat_id
                    and cat_id != atual["categoria_id"]
                    and precisa_categoria(atual)
                    and not _motivo(atual, r, ctx)
                ):
                    feito["trocadas" if atual["categoria_id"] else "categorizadas"] += 1
                    atual["categoria_id"] = cat_id
                    atual["categoria_ia"] = True
                forma = _forma(atual, ctx.contas.get(atual["conta_id"], ""), r.get("forma"))
                if forma != atual.get("forma_pagamento"):
                    atual["forma_pagamento"] = forma
                    feito["formas"] += 1
            arm.salvar("transacoes")
    return feito


# ---------- cenários ----------

SISTEMA_PERGUNTA = """Você transforma um desejo de compra em parâmetros de simulação. Responda
SOMENTE com JSON: {"descricao": "...", "tipo": "carro|moto|terreno|imovel|mcmv|outro",
"valor": 45000, "entrada": null, "prazo_meses": null, "taxa_anual": null, "sistema": null,
"custo_mensal_extra": null, "aporte_mensal": null, "marca": null, "modelo": null, "ano": null}
Use null no que a pessoa não disse (o sistema usa padrões de mercado). taxa_anual em fração
(0.24 = 24% a.a.). "Minha Casa Minha Vida" é tipo "mcmv". Valores em reais, sem texto.
Para carro/moto preencha marca, modelo e ano (EcoSport → Ford); sem valor dito, valor null (o
sistema busca na tabela FIPE)."""

SISTEMA_ANALISE = """Você é um planejador financeiro pessoal brasileiro, direto e honesto.
Explique em português, para leigo, em até 250 palavras e em tópicos curtos, o resultado da
simulação abaixo: quanto tempo leva para juntar, se o financiamento cabe e se compensa, os riscos
(alertas) e 2 ou 3 ações práticas para chegar lá mais rápido (cortar categorias, aumentar entrada,
prazo). Use SÓ os números dados; não invente taxas nem valores. Termine lembrando que taxas e
faixas são referências e devem ser confirmadas com o banco."""


async def interpretar(llm: ChatLLM, pergunta: str) -> dict[str, Any]:
    dados = await _pedir_json(llm, SISTEMA_PERGUNTA, pergunta)
    if not isinstance(dados, dict):
        raise Invalido("Não entendi o pedido: diga o que quer comprar e quanto custa.")
    return {k: v for k, v in dados.items() if v is not None}


async def dados_atuais(internet: Any, parametros: dict[str, Any]) -> dict[str, Any]:
    """FIPE do veículo e CDI de hoje pela internet da plataforma; completa o valor (se faltou) e o
    rendimento da reserva (CDI líquido de ~15% de IR). Sem internet, devolve vazio."""
    if internet is None:
        return {}
    import asyncio

    tarefas = {"indicadores": internet.usar("indicadores", {})}
    if parametros.get("tipo") in ("carro", "moto") and parametros.get("modelo"):
        tarefas["fipe"] = internet.usar("fipe", {
            "marca": parametros.get("marca", ""),
            "modelo": parametros["modelo"],
            "ano": str(parametros.get("ano") or ""),
            "tipo": "motos" if parametros.get("tipo") == "moto" else "carros",
        })
    feitos = dict(zip(tarefas, await asyncio.gather(*tarefas.values()), strict=True))
    saida: dict[str, Any] = {}
    cdi = feitos["indicadores"].get("indicadores", {}).get("cdi_aa", {}).get("valor")
    if cdi:
        saida["cdi_aa"] = cdi
        saida["rendimento_mensal"] = round((1 + cdi / 100 * 0.85) ** (1 / 12) - 1, 5)
    fipe = feitos.get("fipe") or {}
    if fipe.get("media"):
        saida["fipe"] = {k: fipe[k] for k in ("marca", "menor", "maior", "media", "fonte")}
        saida["fipe"]["referencia"] = fipe["versoes"][0]["referencia"]
        saida["fipe"]["versoes"] = [
            f"{v['modelo']} {v['ano']}: R$ {v['valor']:.0f}" for v in fipe["versoes"][:6]
        ]
    elif fipe.get("erro"):
        saida["fipe_erro"] = fipe["erro"]
    return saida


def _resumo_para_ia(r: dict[str, Any]) -> dict[str, Any]:
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


async def analisar(
    llm: ChatLLM, pergunta: str, resultado: dict[str, Any], atuais: dict[str, Any] | None = None
) -> str:
    extra = (
        "\n\nDados de hoje da internet (FIPE, CDI): "
        + json.dumps(atuais, ensure_ascii=False)
        + "\nCompare o valor pedido com a FIPE e cite a referência."
        if atuais
        else ""
    )
    texto = await llm(
        [
            {"role": "system", "content": SISTEMA_ANALISE},
            {
                "role": "user",
                "content": f"Pergunta: {pergunta}\n\nSimulação:\n"
                + json.dumps(_resumo_para_ia(resultado), ensure_ascii=False)
                + extra,
            },
        ]
    )
    return re.sub(r"<think>.*?</think>", "", texto, flags=re.DOTALL).strip()


# ---------- conversa (texto ou voz) ----------

SISTEMA_CONVERSA = """Você é um planejador financeiro pessoal brasileiro numa conversa por voz com a
dona destes dados. Responda em português, curto e falado: no máximo 3 frases (até 60 palavras),
sem listas, sem markdown, valores arredondados ("uns 2 mil e 300 reais"). Use SÓ os dados abaixo;
se faltar o dado, diga que ele não está nos extratos importados. Seja direto e honesto.

Dados financeiros (JSON):
"""


def contexto_financeiro(arm: Armazem, hoje: date | None = None) -> dict[str, Any]:
    """O que a IA sabe na conversa: os últimos 6 meses, as categorias do último mês fechado,
    reserva e parcelas em aberto. Compacto para o prompt ser lido rápido."""
    from financas import cenarios, relatorios

    hoje = hoje or date.today()
    meses = cenarios.historico_mensal(arm, 6, hoje)
    ultimo = meses[-1]["mes"] if meses else hoje.isoformat()[:7]
    mes = relatorios.resumo(arm, ultimo)
    parcs = [p for p in cenarios.parcelamentos(arm, hoje) if p["ativo"]]
    return {
        "hoje": hoje.isoformat(),
        "meses": meses,
        "reserva_atual": round(cenarios.reserva_atual(arm), 2),
        f"categorias_{ultimo}": [
            {k: c[k] for k in ("nome", "tipo", "valor", "orcamento")}
            for c in mes["categorias"][:12]
            if c["valor"] or c["orcamento"]
        ],
        "indicadores": mes["indicadores"],
        "parcelas_em_aberto": {
            "quantidade": len(parcs),
            "por_mes": round(sum(p["valor_parcela"] for p in parcs), 2),
            "restante": round(sum(p["valor_restante"] for p in parcs), 2),
        },
    }


async def conversar(
    llm: ChatLLM,
    mensagens: list[dict[str, str]],
    contexto: dict[str, Any],
    cenario: dict[str, Any] | None = None,
) -> str:
    """Uma resposta curta da conversa; [cenario] (`pergunta`, `analise`) é a simulação aberta."""
    sistema = SISTEMA_CONVERSA + json.dumps(contexto, ensure_ascii=False)
    if cenario and cenario.get("pergunta"):
        sistema += (
            f"\n\nSimulação aberta na tela: {cenario['pergunta']}\n"
            f"Análise já mostrada: {str(cenario.get('analise') or '')[:2500]}"
        )
    texto = await llm([{"role": "system", "content": sistema}, *mensagens[-12:]])
    return re.sub(r"<think>.*?</think>", "", texto, flags=re.DOTALL).strip()
