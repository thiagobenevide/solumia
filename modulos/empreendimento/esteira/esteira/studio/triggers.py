"""Gatilhos da fala: o que, dito na narração, vira cena — e em qual layout, com qual peça e com qual cor.

Gatilho é dado do estilo (nunca código): nome, grupo, prioridade (menor vence; 0 = estrutural, vence todos),
padrões da fala, exemplos que devem disparar, condições que impedem, layout, peça e regra de cor. O detector é
determinístico (regex sobre a frase sem acento); a IA local só preenche âncora, título e valores da peça escolhida
e usa os exemplos dos gatilhos como guia nas frases sem gatilho.

Padrão: texto literal com marcadores — `{número}`/`{n}`/`{m}` (número falado), `{ano}`, `{valor}` (R$ + número),
`{palavra}`, `…` (qualquer coisa no meio), `*` (fim de palavra livre: `endividad*`). Prefixo `re:` = regex pura.
"""
import re
import unicodedata

from pydantic import BaseModel, Field

GROUPS = ("credibilidade", "estrutura", "tom")
# layout pedido → layout da câmera (`camera.layouts`): peça cheia/capítulo/tipografia = sem o apresentador
# lateral/flutuante: dados soltos sobre a imagem (câmera ou mídia); sólido: card flutuante sobre fundo na cor do estilo;
# galeria: cards com as mídias do episódio flutuando em volta do apresentador
LAYOUTS = {"camera": "full", "split": "split", "peca": "tela", "capitulo": "tela", "tipografia": "tela",
           "broll": "broll", "midia_overlay": "broll", "lateral": "lateral", "flutuante": "flutuante",
           "solido": "solido", "galeria": "galeria"}
COLORS = ("destaque", "apoio", "acento")
# condições fixas que o motor sabe checar (as caixinhas do "Não disparar quando")
CONDITIONS = {
    "dentro_de_comparacao": "O número já está dentro de uma comparação ou cálculo",
    "numero_recente": "Outro número foi dito há menos de 2 s (junta na mesma peça)",
    "frase_longa": "A frase tem mais de 25 palavras (fica na câmera)",
}


class ColorRule(BaseModel):
    termos: list[str] = Field(default_factory=list)  # "endividad*", "queda"
    cor: str = Field("acento", pattern="^(destaque|apoio|acento)$")


class Trigger(BaseModel):
    id: str = Field(pattern=r"^[a-z0-9_]{2,40}$")
    nome: str
    grupo: str = Field("credibilidade", pattern="^(credibilidade|estrutura|tom)$")
    prioridade: int = Field(5, ge=0, le=99)
    ativo: bool = True
    padroes: list[str] = Field(default_factory=list)
    exemplos: list[str] = Field(default_factory=list)
    nao_disparar: list[str] = Field(default_factory=list)  # chaves de CONDICOES
    layout: str = Field("split", pattern="^(camera|split|peca|capitulo|tipografia|broll|midia_overlay|lateral|flutuante|solido|galeria)$")
    peca: str = ""  # cena do kit (bancada.CENAS); vazio = sem peça (fica na câmera ou na mídia)
    cor: str = Field("destaque", pattern="^(destaque|apoio|acento)$")
    cor_regras: list[ColorRule] = Field(default_factory=list)


def _g(id_, name, group, prio, defaults, examples, layout, piece, no_words=(), color_rules=()):
    return {"id": id_, "nome": name, "grupo": group, "prioridade": prio, "padroes": list(defaults),
            "exemplos": list(examples), "layout": layout, "peca": piece, "nao_disparar": list(no_words),
            "cor_regras": list(color_rules)}


NEGATIVE = {"termos": ["endividad*", "inadimpl*", "queda", "perd*", "divid*", "jur*", "golpe*"], "cor": "acento"}
POSITIVE = {"termos": ["ganh*", "lucr*", "economiz*", "rend*", "sobr*"], "cor": "apoio"}


def default():
    """Gatilhos de partida (os do wireframe do Estúdio); cada estilo edita os seus."""
    return [Trigger(**g) for g in [
        _g("estudo_citado", "Estudo citado", "credibilidade", 1,
           ["segundo {palavra}", "de acordo com", "pesquisa", "estudo", "levantamento", "relatorio"],
           ["Segundo a CNC, 81,7% das famílias estão endividadas"], "split", "citacao_estudo"),
        _g("conta", "Conta / cálculo", "credibilidade", 2,
           ["{n} vezes {m}", "{n} x {m}", "{n} por {palavra} durante {m}", "re:\\d.*\\b(da|dá|igual a|resulta em)\\b.*\\d"],
           ["200 reais por mês durante 5 anos dá 12 mil"], "split", "equacao", color_rules=[NEGATIVE]),
        _g("comparacao", "Comparação de 2", "credibilidade", 3,
           ["{número}…contra…{número}", "{número}…enquanto…{número}", "{número}…em vez de…{número}"],
           ["Os juros do rotativo passam de 400% ao ano, contra 12% da poupança"], "split", "versus",
           color_rules=[NEGATIVE]),
        _g("ranking", "Ranking (3+)", "credibilidade", 3,
           ["re:(\\d[\\d.,]*\\s*%?[^\\d]+){3,}", "em primeiro lugar", "ranking", "os tres maiores"],
           ["Cartão com 60%, cheque especial com 20% e consignado com 12%"], "peca", "ranking"),
        _g("evolucao", "Evolução no tempo", "credibilidade", 4,
           ["em {ano}…em {ano}", "de {ano} para {ano}", "desde {ano}", "subiu de", "caiu de", "cresceu"],
           ["Em 2019 eram 63%; em 2025, 78%"], "peca", "grafico_linha", color_rules=[NEGATIVE, POSITIVE]),
        _g("porcentagem", "Porcentagem", "credibilidade", 5,
           ["{número}%", "{número} por cento", "{n} em cada {m}"],
           ["81,7% das famílias estão endividadas", "8 em cada 10 brasileiros não têm reserva"],
           "split", "anel_percentual", no_words=["dentro_de_comparacao", "numero_recente"], color_rules=[NEGATIVE]),
        _g("valor", "Valor em R$", "credibilidade", 5, ["{valor}", "{número} reais", "{número} mil reais"],
           ["A fatura média é de R$ 1.200"], "split", "contador", no_words=["dentro_de_comparacao", "numero_recente"],
           color_rules=[NEGATIVE, POSITIVE]),
        _g("numero_solto", "Número solto", "credibilidade", 5, ["{número}"], ["São 77 milhões de pessoas"],
           "split", "contador", no_words=["dentro_de_comparacao", "numero_recente"]),
        _g("processo", "Processo", "estrutura", 6,
           ["passo", "etapa", "primeiro…depois", "sao {palavra} passos", "listar…negociar"],
           ["São três passos para sair dessa: listar, negociar e cortar"], "split", "passo_a_passo"),
        _g("lista", "Lista", "estrutura", 6, ["re:\\w+, \\w+ e \\w+"],
           ["Mercado, farmácia e transporte"], "split", "lista_itens"),
        _g("termo", "Termo técnico", "estrutura", 7,
           ["chamad*", "o que e", "significa", "conhecid* como", "rotativo", "juros compostos", "o cartao de credito"],
           ["O cartão de crédito.", "Isso se chama juros compostos"], "split", "termo_tecnico"),
        _g("mudanca", "Mudança de assunto", "estrutura", 0,
           ["agora vamos", "mas antes", "vamos falar", "parte {n}", "capitulo {n}"],
           ["Agora vamos ao que interessa"], "capitulo", "titulo_capitulo"),
        _g("alerta", "Alerta / dica", "tom", 8, ["cuidado", "atencao", "evite", "dica", "nunca", "nao caia"],
           ["Cuidado com o pagamento mínimo"], "split", "alerta", color_rules=[NEGATIVE]),
        _g("dia_a_dia", "Situação do dia a dia", "tom", 9,
           ["quando voce", "imagine", "no mercado", "todo mes", "no dia a dia"],
           ["Quando você passa o cartão no mercado, não sente o dinheiro saindo"], "broll", ""),
        _g("pergunta", "Pergunta", "tom", 10, ["re:\\?\\s*$"], ["E sabe qual é o maior vilão?"], "camera", ""),
        _g("impacto", "Frase de impacto", "tom", 10, ["re:^\\W*(\\w+\\W+){1,4}\\w+[.!]\\s*$", "isso muda tudo"],
           ["E isso muda tudo."], "camera", "lettering"),
        _g("cta", "Chamada para ação", "tom", 0,
           ["comenta", "se inscreve", "inscreva", "link na descricao", "me segue", "compartilha"],
           ["Comenta RESERVA que eu te mando a planilha"], "camera", "cta"),
    ]]


def _without_accent(s):
    s = unicodedata.normalize("NFKD", s.lower())
    return "".join(c for c in s if not unicodedata.combining(c))


NUM = r"\d[\d.]*(?:,\d+)?"
MARKS = {"{numero}": NUM, "{n}": NUM, "{m}": NUM, "{ano}": r"(?:19|20)\d\d", "{palavra}": r"\w+",
          "{valor}": r"r\$\s*" + NUM}


def build(p):
    """Padrão do gatilho → regex (sobre a frase minúscula e sem acento)."""
    if p.startswith("re:"):
        return re.compile(_without_accent(p[3:]))
    p = _without_accent(p.strip())
    parts = re.split(r"(\{[a-z]+\}|…|\.\.\.|\*)", p)
    rx = []
    for x in parts:
        if x in MARKS:
            rx.append(MARKS[x])
        elif x in ("…", "..."):
            rx.append(r".*?")
        elif x == "*":
            rx.append(r"\w*")
        elif x:
            rx.append(re.escape(x))
    body = "".join(rx)
    # palavra inteira nas pontas literais (evita "dica" dentro de "indica")
    if p[:1].isalpha():
        body = r"\b" + body
    if p[-1:].isalpha():
        body += r"\b"
    return re.compile(body)


def _numbers(s):
    return re.findall(NUM, s)


def matches(g: Trigger, sentence):
    """Primeiro trecho da frase que casa com algum padrão do gatilho (ou None)."""
    target = _without_accent(sentence)
    for p in g.padroes:
        try:
            m = build(p).search(target)
        except re.error:
            continue
        if m:
            return sentence[m.start():m.end()] or sentence
    return None


def blocked(g: Trigger, sentence, ctx):
    ns = _numbers(re.sub(r"\d+\s+(?:em|de)\s+cada\s+\d+", "1", sentence))  # "8 em cada 10" é um número só
    if "dentro_de_comparacao" in g.nao_disparar and len(ns) >= 2:
        return True
    if "numero_recente" in g.nao_disparar and ctx.get("numero_recente"):
        return True
    return "frase_longa" in g.nao_disparar and len(sentence.split()) > 25


def color(g: Trigger, sentence):
    target = _without_accent(sentence)
    for r in g.cor_regras:
        if any(build(t).search(target) for t in r.termos if t.strip()):
            return r.cor
    return g.cor


def detect(sentence, triggers, ctx=None):
    """{gatilho, trecho, cor, perdeu:[ids]} do gatilho vencedor (menor prioridade; 0 vence todos) ou None."""
    ctx = ctx or {}
    hits = []
    for g in triggers:
        if not g.ativo or blocked(g, sentence, ctx):
            continue
        t = matches(g, sentence)
        if t is not None:
            hits.append((g, t))
    if not hits:
        return None
    hits.sort(key=lambda x: x[0].prioridade)
    g, t = hits[0]
    return {"gatilho": g, "trecho": t, "cor": color(g, sentence), "perdeu": [h.id for h, _ in hits[1:]]}


def apply(sentences, triggers):
    """{i: detecção} para as frases com tempo (`ini`/`fim`); o contexto marca número dito há menos de 2 s."""
    output, last_num = {}, -99.0
    for i, f in enumerate(sentences):
        d = detect(f["texto"], triggers, {"numero_recente": f["ini"] - last_num < 2.0})
        if _numbers(f["texto"]):
            last_num = f["fim"]
        if d:
            output[i] = d
    return output


def sentences_of_text(text, words_s=2.6):
    """Roteiro colado → frases com tempo estimado (2,6 palavras/s) para o teste sem gravação. Frontmatter, títulos,
    citações (`>`) e marcações do Obsidian saem."""
    text = re.sub(r"\A---\n.*?\n---\n", "", text, flags=re.S)
    text = "\n".join(x for x in text.splitlines() if not x.lstrip().startswith(("#", ">", "![[", "%%")))
    text = re.sub(r"[*_`]|\[\[|\]\]", "", text)
    parts =[x.strip() for x in re.split(r"(?<=[.!?])\s+|\n+", text) if x.strip()]
    t, output = 0.0, []
    for x in parts:
        d = max(0.8, len(x.split()) / words_s)
        output.append({"texto": x, "ini": round(t, 2), "fim": round(t + d, 2)})
        t += d + 0.15
    return output


def test(sentences, style):
    """Decupagem do roteiro pelo estilo, sem IA: cena por frase, ritmo e avisos (o "Testar com roteiro")."""
    det = apply(sentences, style.gatilhos)
    scenes = []
    for i, f in enumerate(sentences):
        d = det.get(i)
        g = d["gatilho"] if d else None
        layout = g.layout if g else "camera"
        if style.modo != "apresentador" and layout == "camera":
            layout = "peca" if g and g.peca else "broll"
        scenes.append({"i": i, "t": f["ini"], "ate": f["fim"], "frase": f["texto"], "gatilho": g.id if g else "",
                      "gatilho_nome": g.nome if g else "", "trecho": d["trecho"] if d else "",
                      "perdeu": d["perdeu"] if d else [], "layout": layout, "peca": g.peca if g else "",
                      "cor": d["cor"] if d else ""})
    duration = (sentences[-1]["fim"] if sentences else 0) or 1
    pres = style.presenca
    warnings = []
    # peça parada: a mesma peça em frases seguidas passa do limite
    k = 0
    while k < len(scenes):
        j = k
        while j + 1 < len(scenes) and scenes[j + 1]["peca"] and scenes[j + 1]["peca"] == scenes[k]["peca"]:
            j += 1
        time = scenes[j]["ate"] - scenes[k]["t"]
        if scenes[k]["peca"] and time > pres.peca_parada_s:
            warnings.append({"tipo": "peca_parada", "i": k, "t": scenes[k]["t"],
                           "titulo": f"Peça parada por {time:.0f} s em {_mmss(scenes[k]['t'])}",
                           "texto": f"Limite do estilo é {pres.peca_parada_s:.0f} s. A fala continua no mesmo processo.",
                           "acoes": ["Avançar etapa por palavra", "Ajustar regra"]})
        k = j + 1
    outside = 0.0
    for c in scenes:
        outside = outside + (c["ate"] - c["t"]) if c["layout"] in ("peca", "capitulo", "tipografia", "broll") else 0.0
        if style.modo == "apresentador" and outside > pres.fora_max_s:
            warnings.append({"tipo": "fora", "i": c["i"], "t": c["t"],
                           "titulo": f"Apresentador fora da tela por {outside:.0f} s em {_mmss(c['t'])}",
                           "texto": f"Máximo do estilo: {pres.fora_max_s:.0f} s.", "acoes": ["Ajustar regra"]})
            outside = 0.0
    for c in scenes:
        if not c["gatilho"]:
            warnings.append({"tipo": "sem_gatilho", "i": c["i"], "t": c["t"], "titulo": f'"{c["frase"][:40]}" sem gatilho',
                           "texto": "Ficou em câmera cheia. Quer tratar como frase de impacto (punch-in)?",
                           "acoes": ["Sim, neste estilo", "Ignorar"]})
    rhythm = {}
    for c in scenes:
        rhythm[c["layout"]] = rhythm.get(c["layout"], 0) + (c["ate"] - c["t"])
    swaps = sum(1 for a, b in zip(scenes, scenes[1:], strict=False) if (a["layout"], a["peca"]) != (b["layout"], b["peca"]))
    return {"cenas": scenes, "duracao": round(duration, 1), "avisos": warnings,
            "ritmo": {k: round(v / duration, 2) for k, v in rhythm.items()},
            "troca_media_s": round(duration / max(swaps + 1, 1), 1)}


def _mmss(t):
    return f"{int(t) // 60:02d}:{int(t) % 60:02d}"
