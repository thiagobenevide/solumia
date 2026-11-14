"""Direção por bloco (`docs/PLANO-ACERVO.md`, "Direção"): roteiro → blocos → tratamento → 5 candidatas → escolha →
preenchimento. Substitui o diretor por frase (`diretor.py`) quando Opções → `direcao = "blocos"` (padrão).

1. Blocos = parágrafos do roteiro (falas do `roteiro.txt` casadas com os trechos falados); sem roteiro, pausas e o
   tamanho de bloco do perfil. Cada bloco se divide em momentos do tamanho da virada do perfil (`virada_s`: ~30 s no
   longo, ~3 s no curto); um número dito abre momento próprio. O momento é a unidade que ganha uma peça.
2. Leitura (IA local, 1 chamada por bloco, prompt `direcao_leitura`): intenção, tom, entidades e tratamento de cada
   momento (só voz com motion, mídia com motion, câmera cheia, câmera + peça, 2,5D sobre a câmera, 3D); o código
   corrige o que o modo não permite e quebra três tratamentos iguais seguidos.
3. Candidatas (código): peças aprovadas do canal (`peca.no_canal`), no formato e na duração, filtradas pelo
   tratamento; ordem = semelhança do momento com os `exemplos_sim` (menos os `exemplos_nao`) por embeddings locais
   (`ai/embeddings.py`; sem o modelo, palavras em comum), + intenção que bate, − peça usada há pouco
   (anti-repetição) e cotas (3D, só texto). Saem 5.
4. Escolha (IA local, `direcao_escolha`): 1 das 5 com motivo; fora da lista = a primeira.
5. Preenchimento (IA local, `direcao_preencher`): encaixes + botões; o código valida (limites da ficha, número que
   não foi dito) e devolve o erro; 2ª falha → próxima candidata; sem nenhuma, o momento fica na mídia.
Apontamento da pessoa e gatilhos do estilo fixam a peça (a IA só preenche). Depois: perfil de ritmo (sem capítulos,
gancho, conferência) e o mapa no formato do kit (`encaixes`, `botoes`, `batidas`).
"""
import json
import re

from pydantic import BaseModel, Field

from esteira.bench import ChoicePiece as Escolha
from esteira.bench import normalize, numbers
from esteira.core import events
from esteira.studio import piece as P
from esteira.studio import rhythm as R
from esteira.ai import local

TREATMENTS = ("voz_motion", "midia_motion", "camera_cheia", "camera_peca", "camera_2_5d", "3d")
SO_PRESENTER = {"camera_cheia", "camera_peca", "camera_2_5d"}
RULES_TREATMENT = {
    "dark": "voz_motion = a peça ocupa a tela (dado forte, virada, pergunta); midia_motion = a imagem/vídeo do "
            "assunto com a peça por cima (a maioria); 3d só se a fala pedir um objeto no espaço.",
    "apresentador": "camera_cheia = o apresentador fala sem peça (opinião, conversa); camera_peca = câmera ao lado de "
                    "uma peça (dado, comparação); camera_2_5d = peça em perspectiva sobre a câmera; voz_motion = só a "
                    "peça na tela (virada forte); midia_motion = B-roll com peça por cima.",
}
N_CANDIDATES = 5
WEIGHT_NAO, BONUS_INTENT, PENALTY_RECENT, PENALTY_NEAR = 0.3, 0.12, 0.25, 0.1
EMPTY = re.compile(r"\b(unknown|desconhecid[oa]s?|n/a|n\.a\.|não informad[oa]|não disponível|null)\b", re.I)
STUDY = re.compile(r"\b(estudos?|pesquisa\w*|publicaram|artigo|levantamento|relatorio|autores)\b")
CALL = re.compile(r"\b(comenta|comentarios|inscrev|link na descricao|me segue|compartilh|curt[ae])")
QUOTA_TEXT = 0.4   # peças só de texto até 40% das escolhas (a cota de 3D é do perfil de ritmo: `cota_3d_s`)


class Entities(BaseModel):
    numeros: list[str] = Field(default_factory=list)
    datas: list[str] = Field(default_factory=list)
    nomes: list[str] = Field(default_factory=list)


class ReadingMoment(BaseModel):
    intencao: str
    tom: str = "didatica"
    tratamento: str = "midia_motion"
    entidades: Entities = Field(default_factory=Entities)


class ReadingBlock(BaseModel):
    momentos: list[ReadingMoment]


class Verification(BaseModel):
    fiel: bool
    problema: str = ""


class Filling(BaseModel):
    encaixes: dict = Field(default_factory=dict)
    botoes: dict = Field(default_factory=dict)


# ---------------------------------------------------------------- números falados

UNITS = {"zero": 0, "um": 1, "uma": 1, "dois": 2, "duas": 2, "tres": 3, "quatro": 4, "cinco": 5, "seis": 6,
            "sete": 7, "oito": 8, "nove": 9, "dez": 10, "onze": 11, "doze": 12, "treze": 13, "catorze": 14,
            "quatorze": 14, "quinze": 15, "dezesseis": 16, "dezessete": 17, "dezoito": 18, "dezenove": 19}
TENS = {"vinte": 20, "trinta": 30, "quarenta": 40, "cinquenta": 50, "sessenta": 60, "setenta": 70, "oitenta": 80,
           "noventa": 90}
HUNDREDS = {"cem": 100, "cento": 100, "duzentos": 200, "duzentas": 200, "trezentos": 300, "trezentas": 300,
            "quatrocentos": 400, "quinhentos": 500, "seiscentos": 600, "setecentos": 700, "oitocentos": 800,
            "novecentos": 900}


def spoken(texto):
    """Números do que foi falado como dígitos (`bancada.numeros`), inclusive os por extenso ("oito em cada dez" →
    8 e 10; "vinte e cinco" → 25; "três mil" → 3000), para a conferência de número inventado."""
    output = set(numbers(texto))
    ws = normalize(texto).split() + ["."]
    value, ativo = 0, False
    for k, w in enumerate(ws):
        n = UNITS.get(w, TENS.get(w, HUNDREDS.get(w)))
        if w in ("um", "uma") and not ativo and ws[k + 1] not in ("mil", "milhao", "milhoes", "bilhao"):
            n = None  # artigo ("um dia"), não número
        if w == "cento" and k and ws[k - 1] == "por":
            n = None  # "por cento"
        if n is not None:
            value, ativo = value + n, True
        elif w == "mil":
            value, ativo = (value or 1) * 1000, True
        elif w == "e" and ativo:
            continue
        else:
            if ativo:
                output.add(str(value))
            value, ativo = 0, False
    return output


# ---------------------------------------------------------------- 1. blocos e momentos

def _words_norm(t):
    return [w for w in normalize(t).split() if w]


def blocks(trechos, falas, profile):
    """Trechos (com tempo) agrupados por fala do roteiro (parágrafo); sem roteiro, por pausa > 1,2 s ou pelo tamanho
    máximo de bloco do perfil. → [{i, ini, fim, texto, trechos: [índices]}]."""
    groups = []
    if falas:
        target = [len(_words_norm(f)) for f in falas if _words_norm(f)]
        k, acc, current = 0, 0, []
        for n, t in enumerate(trechos):
            current.append(n)
            acc += len(_words_norm(t["texto"]))
            if k < len(target) and acc >= 0.85 * target[k]:
                groups.append(current)
                current, acc, k = [], 0, k + 1
        if current:
            groups.append(current)
    else:
        current = []
        for n, t in enumerate(trechos):
            if current and (t["ini"] - trechos[current[-1]]["fim"] > 1.2
                          or t["fim"] - trechos[current[0]]["ini"] > profile.bloco_s[1]):
                groups.append(current)
                current = []
            current.append(n)
        if current:
            groups.append(current)
    return [{"i": i, "ini": trechos[g[0]]["ini"], "fim": trechos[g[-1]]["fim"],
             "texto": " ".join(trechos[n]["texto"] for n in g), "trechos": g} for i, g in enumerate(groups)]


def moments(block, trechos, profile):
    """Momentos do bloco no tamanho da virada do perfil; um trecho com número abre momento novo se o atual já tem um."""
    output, current = [], []
    for n in block["trechos"]:
        t = trechos[n]
        duration = (t["fim"] - trechos[current[0]]["ini"]) if current else 0
        has_num = any(spoken(trechos[x]["texto"]) for x in current)
        if current and (duration > profile.virada_s[1]
                      or (spoken(t["texto"]) and has_num)
                      or trechos[current[-1]]["fim"] - trechos[current[0]]["ini"] >= profile.virada_s[0]):
            output.append(current)
            current = []
        current.append(n)
    if current:
        output.append(current)
    return [{"bloco": block["i"], "j": j, "ini": trechos[m[0]]["ini"], "fim": trechos[m[-1]]["fim"],
             "texto": " ".join(trechos[n]["texto"] for n in m), "trechos": m} for j, m in enumerate(output)]


# ---------------------------------------------------------------- 2. leitura e tratamento

def _rule(m):
    """Leitura sem IA (plano B): número → numero, pergunta → pergunta, resto → destaque."""
    t = m["texto"]
    intent = "numero" if spoken(t) else "pergunta" if t.strip().endswith("?") else "destaque"
    return ReadingMoment(intencao=intent, tratamento="voz_motion" if intent == "numero" else "midia_motion",
                          entidades=Entities(numeros=sorted(spoken(t))))


def read(block, ms, modo, profile, antes=""):
    trat = [t for t in TREATMENTS if modo == "apresentador" or t not in SO_PRESENTER]
    text = local.prompt("direcao_leitura", intencoes=", ".join(P.INTENTS), tratamentos=", ".join(trat),
                         regras_tratamento=RULES_TREATMENT.get(modo, RULES_TREATMENT["dark"]), modo=modo,
                         ritmo=profile.id, antes=antes[-300:], n=len(ms),
                         momentos="\n".join(f"{k + 1}. {m['texto']}" for k, m in enumerate(ms)))
    r = local.ask(text, ReadingBlock, max_tokens=300 + 160 * len(ms), operation="direction")
    if not r or len(r.momentos) != len(ms):
        return [_rule(m) for m in ms], "regra"
    return [_fix(x, m) for x, m in zip(r.momentos, ms, strict=True)], "local"


def _fix(x: ReadingMoment, m):
    if x.intencao not in P.INTENTS:
        x.intencao = _rule(m).intencao
    if x.tratamento not in TREATMENTS:
        x.tratamento = "midia_motion"
    # número que a IA não viu: o código põe (a peça precisa do dado)
    falados = spoken(m["texto"])
    if falados and not x.entidades.numeros:
        x.entidades.numeros = sorted(falados)
    return x


def treat(readings, modo):
    """Tratamento possível no modo; o mesmo três vezes seguidas troca o terceiro (variedade)."""
    output = []
    for x in readings:
        t = x.tratamento
        if modo != "apresentador" and t in SO_PRESENTER:
            t = "voz_motion" if t == "camera_peca" else "midia_motion"
        if len(output) >= 2 and output[-1] == output[-2] == t:
            t = {"midia_motion": "voz_motion", "voz_motion": "midia_motion", "camera_cheia": "camera_peca",
                 "camera_peca": "camera_cheia"}.get(t, "midia_motion")
        output.append(t)
    return output


# ---------------------------------------------------------------- 3. candidatas

def _vectors_cards(cards):
    """{id: (vetor dos exemplos_sim, vetor dos exemplos_nao)} pelos embeddings; None sem o modelo."""
    from esteira.ai import embeddings as E
    texts = sorted({x for f in cards for x in f.exemplos_sim + f.exemplos_nao + [f.comunica]})
    vs = E.vectors(texts, E.DOCUMENT) if texts else []
    if vs is None:
        return None
    d = dict(zip(texts, vs, strict=True))
    return {f.id: (E.mean([d[x] for x in f.exemplos_sim + [f.comunica]]), E.mean([d[x] for x in f.exemplos_nao]))
            for f in cards}


def _similarity_words(texto, f):
    """Plano B sem embeddings: proporção de radicais do momento que aparecem nos exemplos da ficha."""
    def rad(t):
        return {w[:5] for w in _words_norm(t) if len(w) > 3}
    m = rad(texto)
    if not m:
        return 0.0
    sim = rad(" ".join(f.exemplos_sim + [f.comunica]))
    nao = rad(" ".join(f.exemplos_nao))
    return len(m & sim) / len(m) - WEIGHT_NAO * len(m & nao) / len(m)


def _fits(f, tratamento, dur, formatos):
    if not set(formatos) <= set(f.formatos) or dur < f.duracao_min * 0.8:
        return False
    if tratamento == "3d":
        return f.peso == "3d"
    if tratamento == "camera_2_5d":
        return f.peso == "2_5d" or f.rosto == "sobre_camera"
    if tratamento in ("voz_motion", "camera_peca"):
        return f.tela_cheia
    if tratamento == "midia_motion":
        return not f.tela_cheia
    return True


def candidates(m, reading, tratamento, cards, vet_m, vet_f, used, formatos, profile, chosen):
    """As N_CANDIDATAS melhores [(pontos, ficha)] para o momento. `usadas`: {peça: último t}; `escolhidas`: [(ficha,
    t)] já escolhidas no vídeo (cotas). Se o tratamento deixar menos de 5, completa com as outras que cabem no formato."""
    from esteira.ai import embeddings as E
    duration = m["fim"] - m["ini"]
    text_n = sum(1 for f, _ in chosen if f.peso == "texto")
    last_3d = max((t for f, t in chosen if f.peso == "3d"), default=-1e9)

    def pontos(f):
        if vet_m is not None and vet_f is not None:
            sim, nao = vet_f[f.id]
            s = E.cosine(vet_m, sim) - (WEIGHT_NAO * E.cosine(vet_m, nao) if nao else 0.0)
        else:
            s = _similarity_words(m["texto"], f)
        if reading.intencao in f.intencoes:
            s += BONUS_INTENT
        t0 = used.get(f.id)
        if t0 is not None:
            s -= PENALTY_RECENT if m["ini"] - t0 < profile.anti_repeticao_s else (
                PENALTY_NEAR if m["ini"] - t0 < 2 * profile.anti_repeticao_s else 0.0)
        if f.peso == "3d" and m["ini"] - last_3d < profile.cota_3d_s:
            s -= 1.0
        if f.peso == "texto" and chosen and text_n / len(chosen) > QUOTA_TEXT:
            s -= 0.1
        return round(s, 4)

    certas = [f for f in cards if _fits(f, tratamento, duration, formatos)]
    order = sorted(certas, key=pontos, reverse=True)[:N_CANDIDATES]
    if len(order) < N_CANDIDATES:
        rest = [f for f in cards if f not in order and set(formatos) <= set(f.formatos) and duration >= f.duracao_min * 0.8]
        order += sorted(rest, key=pontos, reverse=True)[:N_CANDIDATES - len(order)]
    return [(pontos(f), f) for f in order]


# ---------------------------------------------------------------- 4–5. escolha e preenchimento

def lines_candidates(cards):
    return "\n".join(f"- {f.id}: {f.comunica} (serve para: \"{f.exemplos_sim[0]}\"; \"{f.exemplos_sim[1]}\")"
                     for f in cards)


def choose(m, reading, tratamento, cands):
    if len(cands) == 1:
        return cands[0][1], "única candidata", "regra"
    lines = lines_candidates([f for _, f in cands])
    text = local.prompt("direcao_escolha", texto=m["texto"], intencao=reading.intencao, tom=reading.tom,
                         tratamento=tratamento, numeros=", ".join(reading.entidades.numeros) or "nenhum",
                         candidatas=lines)
    r = local.ask(text, Escolha, max_tokens=200, operation="direction")
    by_id = {f.id: f for _, f in cands}
    if r and r.escolha in by_id:
        return by_id[r.escolha], r.motivo[:200], "local"
    return cands[0][1], "fora da lista: ficou a mais parecida", "regra"


def _describe_fits(f):
    lines = []
    for e in f.encaixes:
        limit = {"itens": f"{e.min_itens}–{e.max_itens} itens de até {e.max_car} caracteres",
               "pares": f"{e.min_itens}–{e.max_itens} pares (rótulo até {e.max_car}, valor até {e.max_valor})",
               "pagina": "não preencha (vem do PDF)"}.get(e.tipo, f"até {e.max_car} caracteres")
        extra = f"; opções: {e.opcoes}" if e.opcoes else ""
        lines.append(f"- {e.nome} ({e.tipo}, {limit}, {'obrigatório' if e.obrigatorio else 'opcional'}{extra}): "
                      f"{e.descricao} · exemplo: {json.dumps(e.exemplo, ensure_ascii=False)}")
    return "\n".join(lines)


def problems(f, enc, bot, texto):
    """Erros do preenchimento: limites da ficha + número que não foi dito no momento."""
    errors = P.validate_data(f, enc, bot)
    values = json.dumps(enc, ensure_ascii=False)
    of_number = bool(f.intencoes) and f.intencoes[0] == "numero"
    if of_number and spoken(texto) and not numbers(values):
        errors.append("peça de número sem o número dito: ponha o valor como foi falado")
    if of_number and not spoken(texto):
        errors.append("peça de número, mas nenhum número foi dito neste momento")
    invented = numbers(values) - spoken(texto)
    if invented:
        errors.append(f"números que não foram ditos: {', '.join(sorted(invented))}")
    if EMPTY.search(values):
        errors.append("campo com marcador vazio (Unknown, N/A...): deixe de fora o que não foi dito")
    for e in f.encaixes:
        if e.tipo == "pares" and isinstance(enc.get(e.nome), list):
            rotulos = [str(x.get("rotulo", "")).strip() for x in enc[e.nome] if isinstance(x, dict)]
            if any(len(r.replace("*", "")) < 3 for r in rotulos):
                errors.append(f"{e.nome}: cada rótulo é um item completo, não um pedaço da frase")
    if "valor_a" in enc and str(enc["valor_a"]) == str(enc.get("valor_b")):
        errors.append("comparação de dois valores iguais não compara nada: use outra peça")
    pairs = [str(x.get("valor", "")) for x in enc.get("valores") or [] if isinstance(x, dict)]
    if f.id.startswith("barras") and (not all(re.search(r"\d", v) for v in pairs) or len(set(pairs)) < 2):
        errors.append("barras precisam de números diferentes ditos na fala: use outra peça")
    if f.id == "citacao_estudo" and not STUDY.search(normalize(texto)):
        errors.append("a fala não cita estudo nenhum: use outra peça")
    if f.id == "cta" and not CALL.search(normalize(texto)):
        errors.append("a fala não chama o público para nada: use outra peça")
    if f.id == "passo_a_passo" and re.match(r"\W*passo\s*:", str(enc.get("titulo", "")), re.I):
        errors.append("titulo: sem 'Passo:' quando não há número de passo")
    return errors


def cross_check(f, enc, m, contexto):
    """Segunda passada da LLM local: o texto de tela diz o que a fala diz? Sem resposta, passa."""
    r = local.ask(local.prompt("direcao_conferir", texto=m["texto"], contexto=contexto[-300:], peca=f.id,
                                     comunica=f.comunica, tela=json.dumps(enc, ensure_ascii=False)),
                        Verification, max_tokens=300, operation="direction")
    return [f"o texto de tela não bate com a fala: {r.problema}"] if getattr(r, "fiel", True) is False else []


def quotes(project):
    """Blocos [!cite] do roteiro, com a fala em que aparecem: a única fonte de trecho, autor e ano."""
    file = project.pasta / "roteiro.json"
    if not file.exists():
        return []
    speeches = _speeches(project)
    cits = [c for c in json.loads(file.read_text()).get("citacoes", []) if c.get("ok") and c.get("en")]
    return [{**c, "palavras": set(_words_norm(speeches[c["fala"]]))} for c in cits if 0 <= c["fala"] < len(speeches)]


def _quote_of(m, cits):
    """Citação cuja fala contém o momento, ou None (o momento não cita estudo nenhum)."""
    spoken = set(_words_norm(m["texto"]))
    notes = [(len(spoken & c["palavras"]) / max(len(spoken), 1), n) for n, c in enumerate(cits)]
    note, n = max(notes, default=(0, 0))
    return cits[n] if note >= 0.6 else None


def _fit(texto, limite):
    if len(texto) <= limite:
        return texto
    sentence = re.match(r".+?[.!?](?=\s|$)", texto)
    if sentence and len(sentence[0]) <= limite:
        return sentence[0]
    return texto[:limite - 1].rsplit(" ", 1)[0].rstrip(" ,;:") + "…"


def _fill_quote(f, m, cits):
    """Peça de citação vem do bloco [!cite], nunca da LLM (que inventa trecho e autor). Sem citação no momento → None."""
    c = _quote_of(m, cits)
    if not c:
        return None
    source = {"trecho_en": c["en"], "traducao": c.get("pt", ""), "autor": c.get("autores", ""),
             "autores": c.get("autores", ""), "ano": str(c.get("ano", ""))[:4], "revista": c.get("revista", ""),
             "titulo": c.get("titulo", "")}
    enc = {e.nome: _fit(source[e.nome], e.max_car) for e in f.encaixes if source.get(e.nome)}
    return None if P.validate_data(f, enc, {}) else (enc, {})


def fill(f, m, reading, cits=(), contexto=""):
    """(encaixes, botões) válidos ou None depois de duas tentativas."""
    if any(e.nome == "trecho_en" for e in f.encaixes):
        return _fill_quote(f, m, cits)
    errors = []
    for _ in range(2):
        text = local.prompt(
            "direcao_preencher", peca=f.id, comunica=f.comunica, texto=m["texto"],
            numeros=", ".join(reading.entidades.numeros) or "nenhum", datas=", ".join(reading.entidades.datas) or "nenhuma",
            nomes=", ".join(reading.entidades.nomes) or "nenhum", encaixes=_describe_fits(f),
            botoes="\n".join(f"- {b.nome}: {b.valores} (padrão {b.padrao})" for b in f.botoes) or "(nenhum)",
            erros=("\nSua resposta anterior foi recusada: " + "; ".join(errors) + ". Corrija.\n") if errors else "")
        r = local.ask(text, Filling, max_tokens=500, operation="direction")
        if not r:
            errors = ["resposta vazia"]
            continue
        enc = {k: v for k, v in r.encaixes.items() if v not in (None, "", [])}
        bot = {k: v for k, v in r.botoes.items() if any(b.nome == k for b in f.botoes)}
        errors = problems(f, enc, bot, m["texto"]) or cross_check(f, enc, m, contexto)
        if not errors:
            return enc, bot
    return None


def beats(f, enc, m, palavras):
    """Instante (s) em que a palavra de cada encaixe de `batidas` é dita dentro do momento."""
    output = {}
    spoken = [w for w in palavras if m["ini"] - 0.05 <= w["ini"] <= m["fim"] + 0.05]
    for name in f.batidas:
        v = enc.get(name)
        target = None
        if isinstance(v, str):
            ns = sorted(numbers(v))  # o valor escrito em dígitos; a fala pode estar por extenso (casa pelo radical)
            target = ns[0] if ns else next((w for w in _words_norm(v) if len(w) > 3), None)
        if not target:
            continue
        for w in spoken:
            if target in normalize(w["p"]).replace(" ", "") or normalize(w["p"]).startswith(target[:5]):
                output[name] = round(max(m["ini"], w["ini"] - 0.05), 3)
                break
    return output


# ---------------------------------------------------------------- mapa

def redo_scene(cena, ficha):
    """Troca a peça de uma cena do mapa (linha do tempo do app): preenche a nova pela IA local com a mesma validação
    da direção; se não der, aproveita título/valores que a cena já tinha. → a cena atualizada (ou ValueError)."""
    m = {"ini": cena["t"], "fim": cena["ate"], "texto": cena.get("frase", "")}
    reading = ReadingMoment(intencao=cena.get("intencao") or "destaque", tratamento=cena.get("tratamento", "midia_motion"),
                             entidades=Entities(numeros=sorted(spoken(m["texto"]))))
    filled = fill(ficha, m, reading)
    if not filled:
        enc = P.legacy({"titulo": cena.get("titulo", ""), "valores": cena.get("valores", [])}, ficha)
        if problems(ficha, enc, {}, m["texto"]):
            raise ValueError(f"{ficha.id} não serve para este momento (a IA não preencheu e o que havia não cabe)")
        filled = (enc, {})
    enc, bot = filled
    duration = min(max(cena["ate"] - cena["t"], ficha.duracao_min), ficha.duracao_max)
    cena.update(cena=ficha.id, encaixes=enc, botoes={**P.defaults(ficha), **bot}, takeover=ficha.tela_cheia,
                titulo=str(enc.get("titulo", ""))[:80], valores=enc.get("valores", []), sfx=ficha.sfx.get("entrada"),
                ate=round(cena["t"] + duration, 3), manual=True, por="voce", motivo="trocada na linha do tempo")
    return cena


def answer_key(ep, cena, aceita, origem):
    """Caso da tarefa `bloco_peca` da bancada (momento + as 5 candidatas → a peça que a pessoa aprovou/trocou)."""
    from esteira.bench import ANSWER_KEY
    ids = cena.get("candidatas") or []
    if not ids:
        return False
    cards = []
    for i in dict.fromkeys(ids + [aceita]):
        try:
            cards.append(P.load(i))
        except (KeyError, ValueError):
            continue
    ANSWER_KEY.mkdir(parents=True, exist_ok=True)
    instance = {"id": f"{origem}:{ep}:{cena.get('bloco')}:{cena.get('momento')}", "texto": cena.get("frase", ""),
            "intencao": cena.get("intencao", ""), "tratamento": cena.get("tratamento", ""),
            "numeros": ", ".join(sorted(spoken(cena.get("frase", "")))), "candidatas": lines_candidates(cards),
            "aceitas": [aceita], "ia": cena.get("cena") if origem == "troca" else None}
    with open(ANSWER_KEY / "bloco_peca.jsonl", "a") as f:
        f.write(json.dumps(instance, ensure_ascii=False) + "\n")
    return True


def answer_key_fill(ep, cena, origem):
    """Caso de preenchimento (momento + peça → encaixes e botões que ficaram): treino da tarefa `preencher`."""
    from esteira.bench import ANSWER_KEY
    if not cena.get("encaixes"):
        return False
    ANSWER_KEY.mkdir(parents=True, exist_ok=True)
    instance = {"id": f"{origem}:{ep}:{cena.get('bloco')}:{cena.get('momento')}:{cena['cena']}", "texto": cena.get("frase", ""),
            "peca": cena["cena"], "intencao": cena.get("intencao", ""), "encaixes": cena["encaixes"],
            "botoes": cena.get("botoes") or {}}
    with open(ANSWER_KEY / "preencher.jsonl", "a") as f:
        f.write(json.dumps(instance, ensure_ascii=False) + "\n")
    return True


def approve_map(ep, mapping):
    """Mapa aprovado: cada peça escolhida pela IA (não fixada) vira acerto no gabarito, e cada preenchimento que ficou
    vira caso de preenchimento. → quantos casos de escolha."""
    for c in mapping.get("cenas", []):
        if c.get("por") in ("local", "regra", "voce", "gatilho") and c.get("encaixes"):
            answer_key_fill(ep, c, "aprovado")
    return sum(answer_key(ep, c, c["cena"], "aprovado") for c in mapping.get("cenas", [])
               if c.get("candidatas") and c.get("por") in ("local", "regra") and not c.get("manual"))


def _speeches(project):
    file = project.pasta / "roteiro.txt"
    if not file.exists():
        return []
    return [x.strip() for x in file.read_text().splitlines() if x.strip() and not x.startswith("#")]


def _fixed(m, marks, gat, cards_id):
    """Peça fixada no momento pela pessoa (apontamento) ou por gatilho do estilo → (id, por) ou None."""
    for n in m["trechos"]:
        if (c := marks.get(n)) and c in cards_id:
            return c, "voce"
    for n in m["trechos"]:
        d = gat.get(n)
        if d and d["gatilho"].peca in cards_id:
            return d["gatilho"].peca, "gatilho"
    return None


def direct(project, estilo, profile=None, formatos=None):
    """Escreve `<ep>/estudio/mapa.json` pela direção por bloco; devolve o mapa."""
    from esteira.studio import marking, cut, director, triggers
    from esteira.ai import embeddings as E
    profile = profile or R.profile_of(project)
    formatos = formatos or estilo.formatos
    folder = project.pasta / "estudio"
    folder.mkdir(exist_ok=True)
    sentences, words = cut.sentences(project), cut.words(project)
    duration = sentences[-1]["fim"] + 1.0 if sentences else 0
    words_d = [{"p": w["p"], "ini": w["ini"]} for w in words]
    spans = director.spans(sentences, words, estilo.regras.trecho_max_s)
    marks = marking.marks(project, spans)
    gat = triggers.aplicar(spans, estilo.gatilhos)
    cards = [f for f in P.in_channel(P.list_all(), estilo) if f.motor in ("html", "effectcraft")]
    if not cards:
        raise SystemExit("acervo vazio para o canal: aprove peças na Fábrica ou tire do filtro do canal")
    by_id = {f.id: f for f in cards}
    cits = quotes(project)
    bls = blocks(spans, _speeches(project), profile)
    ms_by_block = [moments(b, spans, profile) for b in bls]
    everything = [m for ms in ms_by_block for m in ms]
    vet_f = _vectors_cards(cards)
    vet_m = E.vectors([m["texto"] for m in everything], E.QUERY) if vet_f is not None else None
    if vet_f is None:
        events.warning("direção: sem o modelo de embeddings; candidatas por palavras em comum")
    vet_by = {id(m): (vet_m[k] if vet_m else None) for k, m in enumerate(everything)}
    scenes, used, chosen, decisoes = [], {}, [], {"local": 0, "regra": 0, "voce": 0, "gatilho": 0, "midia": 0}
    before = ""
    for b, ms in zip(bls, ms_by_block, strict=True):
        events.progress(b["i"] + 1, len(bls), f"bloco {b['i'] + 1}: {b['texto'][:50]}")
        readings, origin = read(b, ms, estilo.modo, profile, before)
        before = b["texto"]
        trats = treat(readings, estilo.modo)
        for m, lt, tr in zip(ms, readings, trats, strict=True):
            if tr == "camera_cheia":
                decisoes["midia"] += 1
                continue
            fixed = _fixed(m, marks, gat, by_id)
            reserva = []
            if fixed:
                cands = [(1.0, by_id[fixed[0]])]
                if fixed[1] == "gatilho":  # o gatilho sugere; se a peça não preencher, a direção escolhe outra
                    reserva = candidates(m, lt, tr, cards, vet_by[id(m)], vet_f, used, formatos, profile, chosen)
            else:
                cands = candidates(m, lt, tr, cards, vet_by[id(m)], vet_f, used, formatos, profile, chosen)
            if not cands:
                decisoes["midia"] += 1
                continue
            f, reason, por = choose(m, lt, tr, cands)
            por = fixed[1] if fixed else por
            order = [f] + [x for _, x in cands + reserva if x.id != f.id]
            filled = None
            for target in order[:3]:
                filled = fill(target, m, lt, cits, b["texto"])
                if filled:
                    if target.id != f.id:
                        reason = f"{f.id} não preencheu; ficou {target.id}"
                        por = "local" if por == "gatilho" else por
                    f = target
                    break
            if not filled:
                decisoes["midia"] += 1
                events.warning(f"direção: nenhuma peça preenchida em {m['ini']:.1f}s; fica a mídia")
                continue
            enc, bot = filled
            dur = min(m["fim"] - m["ini"] + 0.3, f.duracao_max, profile.peca_s[1])
            t = max(0.0, m["ini"] - 0.08)
            if dur < max(f.duracao_min, profile.peca_s[0]) * 0.8:
                decisoes["midia"] += 1
                continue
            bat = beats(f, enc, m, words_d)
            t = max(t, bat.get("valor", 0) - 0.5)  # peça de número abre quando ele é dito, não vazia antes
            decisoes[por] = decisoes.get(por, 0) + 1
            used[f.id] = m["ini"]
            chosen.append((f, m["ini"]))
            scenes.append({"t": round(t, 3), "ate": round(t + dur, 3), "cena": f.id, "encaixes": enc,
                          "botoes": {**P.defaults(f), **bot}, "batidas": bat,
                          "takeover": f.tela_cheia, "frase": m["texto"], "titulo": str(enc.get("titulo", ""))[:80],
                          "valores": enc.get("valores", []), "ancora": "", "por": por, "motivo": reason,
                          "tratamento": tr, "intencao": lt.intencao, "leitura": origin, "bloco": b["i"], "momento": m["j"],
                          "candidatas": [x.id for _, x in cands], "pontos": [p for p, _ in cands],
                          "sfx": f.sfx.get("entrada"), "frase_i": m["trechos"][0],
                          **({"layout_pedido": "split"} if tr in ("camera_peca", "camera_2_5d") else {})})
    for a, b in zip(scenes, scenes[1:], strict=False):
        a["ate"] = round(min(a["ate"], b["t"] - 0.05), 3)
    scenes = [c for c in scenes if c["ate"] - c["t"] >= 0.6]
    scenes = R.without_chapters(scenes, profile)
    scenes = R.hook(scenes, profile, spans)
    for n, c in enumerate(scenes):
        c["id"] = n
        c.setdefault("takeover", by_id[c["cena"]].tela_cheia if c["cena"] in by_id else False)
    warnings = R.cross_check(scenes, director._media_times(project), duration, profile)
    mapping = {"estilo": estilo.id, "versao": estilo.versao, "duracao": duration, "direcao": "blocos",
            "decisoes": decisoes, "cenas": scenes, "ritmo": {"perfil": profile.id, "avisos": warnings},
            "blocos": [{"i": b["i"], "ini": b["ini"], "fim": b["fim"], "texto": b["texto"][:120]} for b in bls],
            "embeddings": vet_f is not None}
    (folder / "mapa.json").write_text(json.dumps(mapping, ensure_ascii=False, indent=1))
    print(f"  direção: {len(bls)} blocos · {len(everything)} momentos · {len(scenes)} peças · decisões {decisoes} · "
          f"ritmo {profile.id} ({len(warnings)} aviso(s))" + ("" if vet_f is not None else " · sem embeddings"))
    return mapping

