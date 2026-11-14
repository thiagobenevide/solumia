"""Decisão de cortes da narração (substitui a escolha de tomadas do limpar.py).

1. Cada frase do roteiro é alinhada às janelas da transcrição bruta (alinhamento local por palavras:
   tolera palavra parecida, palavra a mais = improviso, palavra a menos).
2. De trás para frente, cada frase fica com a última tomada boa que termina antes da frase seguinte.
   Frase sem tomada boa, mas com uma versão reformulada (nota média), fica com a reformulada.
3. O que sobra entre as tomadas é dividido em falas e classificado: bastidor ("vamos gravar", "eita"),
   retake/começo falso (repete a frase vizinha) ou improviso. Improviso ambíguo vai para o LLM local
   (`ia.local`); sem LLM, fica se tiver 4+ palavras.

Saída: lista de trechos {ini, fim, manter, tipo, motivo, confianca, texto, frase}.
"""
import json
import re
import unicodedata
from difflib import SequenceMatcher

EQUAL, SIMILAR, SWAP, MISSING, LEFTOVER = 1.0, 0.7, -0.6, -0.7, -0.25
GOOD, REPHRASED = 0.62, 0.35     # nota mínima (por palavra do roteiro) de uma tomada / de uma reformulação
ALMOST_BEST = 0.12              # entre tomadas com nota até isto abaixo da melhor, fica a mais tardia
MAX_BACKOFF = 90                   # s: a tomada de uma frase não pode estar mais longe que isto da seguinte
PAUSE_SPEECH = 0.55                # s: pausa que separa duas falas no que sobra entre tomadas
NUMBERS = dict(zip("0 1 2 3 4 5 6 7 8 9 10".split(),
                   "zero um dois tres quatro cinco seis sete oito nove dez".split()))
RE_BACKSTAGE = re.compile(
    r"\b(vamos (fazer|gravar|de novo|la)|nova gravacao|de novo|gravando|repet\w*|errei|desculp\w*|"
    r"eita|opa|pera(i)?|agua|ok\b|beleza|deixa eu|pronto|tá bom|ta bom|hum+|ah+|eh+|"
    r"droga|merda|porra|caramba|putz|corta|cortar|perai|nao foi|ficou ruim)\b")


def norm(p):
    s = unicodedata.normalize("NFKD", p.lower())
    s = re.sub(r"[^\w]", "", "".join(c for c in s if not unicodedata.combining(c)))
    return NUMBERS.get(s, s)


def _stem(word):
    """Compara pelo começo da palavra: "começa" = "começar", "ganha" = "ganhar", "2" = "dois"."""
    return norm(word)[:5]


def sentences_of_script(texto):
    sentences = []
    for line in texto.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        line = re.sub(r"\[[^\]]*\]", "", line).replace("*", "")
        for f in re.split(r"(?<=[.?!:;])\s+", line):
            words = [_stem(w) for w in f.split()]
            words = [w for w in words if w]
            if words:
                sentences.append({"texto": f.strip(), "norm": words})
    return sentences


class _Tok:
    __slots__ = ("n", "r")

    def __init__(self, word):
        self.n = norm(word)
        self.r = self.n[:5]

    def __bool__(self):
        return bool(self.n)


_cache = {}
RE_FRAGMENT = re.compile(r"^[.,]\d")


def _tokens(palavras):
    """Palavras da transcrição → _Tok. O Whisper parte números ("12", ",5", "%"), o roteiro escreve "12,5%":
    o pedaço decimal é juntado à palavra anterior ("125") e fica vazio (palavra vazia não custa no alinhamento).
    Sem isso o número não casa com o roteiro e a tomada começa depois dele (o número era cortado)."""
    toks = [_Tok(p["p"]) for p in palavras]
    for k in range(1, len(toks)):
        if RE_FRAGMENT.match(palavras[k]["p"].strip()) and toks[k - 1].n[-1:].isdigit():
            toks[k - 1].n += re.sub(r"\D", "", palavras[k]["p"])  # dígitos crus ("5", não "cinco")
            toks[k - 1].r = toks[k - 1].n[:5]
            toks[k].n = toks[k].r = ""
    return toks


def _sim(a, b):
    if a.n == b.n or (len(a.n) >= 4 and a.r == b.r):
        return 1.0
    k = (a.n, b.n)
    if k not in _cache:
        _cache[k] = SequenceMatcher(None, a.n, b.n).ratio() >= 0.75 and min(len(a.n), len(b.n)) >= 4
    return 0.7 if _cache[k] else 0.0


def align(frase, trans, ini, fim):
    """Frase inteira × trecho trans[ini:fim] com início/fim livres no trecho. → (nota, i, j, casadas)."""
    n, m = len(frase), fim - ini
    ant = [0.0] * (m + 1)  # linha 0: começar em qualquer ponto do trecho é grátis
    orig = list(range(m + 1))  # onde começou o alinhamento que chega em (i, j)
    for i in range(1, n + 1):
        cur, cori = [MISSING * i] + [0.0] * m, [0] + [0] * m
        for j in range(1, m + 1):
            s = _sim(frase[i - 1], trans[ini + j - 1])
            diag = ant[j - 1] + (EQUAL if s == 1 else SIMILAR if s else SWAP)
            above, esq = ant[j] + MISSING, cur[j - 1] + (LEFTOVER if trans[ini + j - 1].n else 0)
            if diag >= above and diag >= esq:
                cur[j], cori[j] = diag, orig[j - 1]
            elif above >= esq:
                cur[j], cori[j] = above, orig[j]
            else:
                cur[j], cori[j] = esq, cori[j - 1]
        ant, orig = cur, cori
    j = max(range(1, m + 1), key=lambda x: ant[x]) if m else 0
    return ant[j] / n, ini + orig[j], ini + j


def candidates(frase, trans, ate):
    """Tomadas possíveis da frase antes do índice `ate`: [(nota, i, j)] sem repetição."""
    n = len(frase)
    starts = {f.n for f in frase[:3]}
    seen, output = set(), []
    for i in range(ate):
        if trans[i].n not in starts and not any(_sim(trans[i], f) for f in frase[:3]):
            continue
        end = min(ate, i + int(n * 1.6) + 4)
        note, a, b = align(frase, trans, i, end)
        if b > a and (a, b) not in seen and note >= REPHRASED:
            seen.add((a, b))
            output.append((note, a, b))
    return output


def _last_restart(frase, trans, i, j, nota):
    """Tomada que contém um recomeço ("Em 2012, os pesquisadores… Em 2012, os pesquisadores David…")
    passa a começar no último recomeço que mantém a nota."""
    for s in range(i + 1, j):
        if any(_sim(trans[s], f) == 1 for f in frase[:2]):
            n2, a, b = align(frase, trans, s, j)
            if n2 >= nota - 0.05 and b - a >= len(frase) * 0.6:
                i, j, nota = a, b, n2
    return i, j, nota


def choose(frases, palavras):
    """[(i, j, nota, tipo)] por frase do roteiro (None se não achou)."""
    trans = _tokens(palavras)
    toks = [[t for t in map(_Tok, f["texto"].split()) if t] for f in frases]
    choices = [None] * len(frases)
    limit = len(palavras)
    for k in range(len(frases) - 1, -1, -1):
        if not toks[k]:
            continue
        cands = candidates(toks[k], trans, limit)
        if limit < len(palavras):
            cands = [c for c in cands if palavras[limit]["ini"] - palavras[c[2] - 1]["fim"] <= MAX_BACKOFF]
        if not cands:
            continue
        best = max(c[0] for c in cands)
        floor = max(best - ALMOST_BEST, GOOD if best >= GOOD else REPHRASED)
        note, i, j = max((c for c in cands if c[0] >= floor), key=lambda c: c[2])
        i, j, note = _last_restart(toks[k], trans, i, j, note)
        while j < min(len(palavras), limit) and not trans[j] and palavras[j]["ini"] - palavras[j - 1]["fim"] < 0.4:
            j += 1  # o pedaço do número que foi juntado (",7%") vai junto com a tomada
        choices[k] = (i, j, round(note, 3), "tomada" if note >= GOOD else "reformulada")
        limit = i
    return choices, trans, toks


def _speeches(palavras, ini, fim):
    """Divide palavras[ini:fim] em falas pelas pausas e pela pontuação do Whisper."""
    speeches, current = [], []
    for k in range(ini, fim):
        if current and (palavras[k]["ini"] - palavras[k - 1]["fim"] > PAUSE_SPEECH
                      or palavras[k - 1]["p"].rstrip()[-1:] in ".?!"):
            speeches.append(current)
            current = []
        current.append(k)
    return speeches + ([current] if current else [])


def _split_retakes(falas, viz, trans):
    """Fala longa com uma frase do roteiro inteira dentro (retake que o Whisper juntou a outra fala) é
    partida: o pedaço que repete a frase vira uma fala própria (que a cobertura depois marca como retake)."""
    output = []
    for speech in falas:
        chunks, start = [], speech[0]
        if len(speech) >= 6:
            for f in viz:
                if len(f) < 4:
                    continue
                note, a, b = align(f, trans, start, speech[-1] + 1)
                if note >= GOOD and b - a >= 3:
                    chunks += [list(range(start, a)), list(range(a, b))]
                    start = b
        chunks.append(list(range(start, speech[-1] + 1)))
        output += [p for p in chunks if p]
    return output


def _coverage(fala, toks_neighbors, trans):
    """Fração das palavras da fala que repetem alguma frase vizinha (retake/começo falso)."""
    fala = [k for k in fala if trans[k]]
    if not fala:
        return 1.0
    best = 0.0
    for f in toks_neighbors:
        sm = sum(1 for k in fala if any(_sim(trans[k], t) for t in f))
        best = max(best, sm / len(fala))
    return best


def _dedup_improvisations(leftovers, trans, window=120):
    """Improviso regravado: a versão anterior cobre-se pela seguinte (até `janela` s depois) e sai."""
    imp = [s for s in leftovers if s["tipo"] == "improviso"]
    for a in imp:
        after = [[trans[k] for k in range(b["i"], b["j"]) if trans[k]] for b in imp
                  if b is not a and a["fim"] <= b["ini"] <= a["fim"] + window]
        cob = _coverage(list(range(a["i"], a["j"])), after, trans) if after else 0
        if cob >= 0.6:
            a.update(manter=False, tipo="retake", confianca=round(min(0.9, cob), 2),
                     motivo="improviso regravado logo depois")


def classify_leftovers(frases, palavras, choices, trans, toks):
    """Trechos fora das tomadas escolhidas, com decisão provisória."""
    used = [(e[0], e[1], k) for k, e in enumerate(choices) if e]
    used.sort()
    output = []
    boundaries = [(0, 0, -1)] + used + [(len(palavras), len(palavras), len(frases))]
    for (_, a, ka), (b, _, kb) in zip(boundaries, boundaries[1:]):
        if b <= a:
            continue
        viz = [toks[k] for k in range(max(ka - 3, 0), min(kb + 4, len(frases))) if toks[k]]
        for speech in _split_retakes(_speeches(palavras, a, b), viz, trans):
            text = " ".join(palavras[k]["p"] for k in speech).strip()
            t = norm_text(text)
            cob = _coverage(speech, viz, trans)
            if RE_BACKSTAGE.search(t) and len(speech) <= 12:
                kind, keep, conf, reason = "bastidor", False, 0.9, "fala de bastidor"
            elif cob >= 0.6:
                kind, keep, conf, reason = "retake", False, round(min(0.95, cob), 2), "repete frase vizinha"
            elif ka < 0 or kb >= len(frases):
                kind, keep, conf, reason = "fora", False, 0.8, "antes/depois do roteiro"
            else:
                keep = len(speech) >= 4
                kind, conf, reason = "improviso", 0.5, "fala fora do roteiro entre tomadas"
            output.append({"ini": palavras[speech[0]]["ini"], "fim": palavras[speech[-1]]["fim"], "i": speech[0],
                          "j": speech[-1] + 1, "manter": keep, "tipo": kind, "motivo": reason,
                          "confianca": conf, "texto": text, "entre": [ka, kb]})
    return output


def norm_text(t):
    return " ".join(norm(w) for w in t.split())


def _duplicates(trechos, trans, window=75):
    """Improviso/reformulação mantido cujas palavras de conteúdo já estão nas tomadas mantidas por perto
    (antes ou depois, somadas) sai: a mesma ideia dita duas vezes na edição final."""
    takes = [t for t in trechos if t["tipo"] == "tomada" and t["manter"]]
    for a in trechos:
        if not a["manter"] or a["tipo"] == "tomada" or a["j"] - a["i"] < 3:
            continue
        if a["tipo"] == "reformulada" and not any(t is not a and t["manter"] and t.get("frase") == a.get("frase")
                                                  for t in trechos):
            continue  # única versão de uma frase do roteiro: palavras em comum com outras frases não a tornam repetida
        content = [trans[k].r for k in range(a["i"], a["j"]) if len(trans[k].n) >= 4]
        near = {trans[k].r for t in takes if abs(t["ini"] - a["ini"]) <= window for k in range(t["i"], t["j"])}
        cob = sum(r in near for r in content) / len(content) if content else 0
        if 0.35 <= cob < 0.7 and a["tipo"] == "improviso":
            # mesma ideia em outra versão? o LLM compara com a tomada mais parecida
            target = max((t for t in takes if abs(t["ini"] - a["ini"]) <= window),
                       key=lambda t: len(set(content) & {trans[k].r for k in range(t["i"], t["j"])}))
            a["par"] = target["i"]
            a["confianca"] = min(a["confianca"], 0.5)
        if cob >= 0.7:
            a.update(manter=False, tipo="retake", confianca=round(min(0.9, cob), 2),
                     motivo="repete uma tomada mantida", por="regra")


def _continuations(trechos, palavras):
    """Fala curta colada no fim de um trecho mantido (ex.: "fecha aspas") continua a frase."""
    for a, b in zip(trechos, trechos[1:]):
        if (a["manter"] and not b["manter"] and b["tipo"] == "improviso"
                and b["ini"] - a["fim"] <= 0.3 and b["j"] - b["i"] <= 3):
            b.update(manter=True, tipo="continuacao", confianca=0.6, motivo="colada no fim da frase anterior")


def _content(texto):
    return {norm(w)[:5] for w in texto.split() if len(norm(w)) >= 4}


def _rephrased(frases, choices, leftovers):
    """Frase do roteiro sem tomada: um improviso entre as frases vizinhas que divide as palavras de
    conteúdo com ela é a versão reformulada (o LLM confirma depois)."""
    for k, e in enumerate(choices):
        if e:
            continue
        target = _content(frases[k]["texto"])
        if not target:
            continue
        for s in leftovers:
            if s["tipo"] in ("improviso", "retake") and s["motivo"] != "fala de bastidor" and s["entre"][0] < k < s["entre"][1]:
                common = len(target & _content(s["texto"])) / len(target)
                # frase curta que o Whisper ouviu errado ("inadimplente" → "E nada implante"): compara as letras
                letters = SequenceMatcher(None, norm_text(frases[k]["texto"]).replace(" ", ""),
                                         norm_text(s["texto"]).replace(" ", "")).ratio()
                if common >= 0.5 or (len(frases[k]["norm"]) <= 4 and letters >= 0.7):
                    s.update(manter=True, tipo="reformulada", confianca=0.45, frase=k,
                             motivo=f"versão própria de: {frases[k]['texto'][:60]}")


def _stutters(trechos, palavras, trans, frases):
    """Palavra repetida colada dentro de uma tomada ("eram Eram 81", "é é de longe", "um um método") que o roteiro
    não repete: a primeira sai (vira um trecho próprio, cortado no ponto menos audível)."""
    output = []
    for t in trechos:
        if not (t["manter"] and t["tipo"] in ("tomada", "reformulada")):
            output.append(t)
            continue
        rot = norm_text(frases[t["frase"]]["texto"]) if t.get("frase") is not None else ""
        cuts, k = [], t["i"]  # [(início, fim)] da 1ª cópia de 1–3 palavras repetidas em seguida
        while k < t["j"] - 1:
            for n in (3, 2, 1):
                a, b = [x.n for x in trans[k:k + n]], [x.n for x in trans[k + n:k + 2 * n]]
                if (k + 2 * n <= t["j"] and all(a) and a == b and " ".join(a + a) not in rot
                        and palavras[k + n]["ini"] - palavras[k + n - 1]["fim"] < 0.6):
                    cuts.append((k, k + n))
                    k += n
                    break
            else:
                k += 1
        start = t["i"]
        for k0, k1 in cuts:
            if k0 > start:
                output.append(dict(t, i=start, j=k0, ini=palavras[start]["ini"], fim=palavras[k0 - 1]["fim"],
                                  texto=" ".join(p["p"] for p in palavras[start:k0])))
            output.append({"ini": palavras[k0]["ini"], "fim": palavras[k1 - 1]["fim"], "i": k0, "j": k1, "manter": False,
                          "tipo": "retake", "motivo": "gaguejo: palavra repetida", "confianca": 0.95, "por": "regra",
                          "texto": " ".join(p["p"] for p in palavras[k0:k1])})
            start = k1
        if start < t["j"]:
            output.append(dict(t, i=start, ini=palavras[start]["ini"], texto=" ".join(p["p"] for p in palavras[start:t["j"]])))
    return output


def decide(frases, palavras):
    choices, trans, toks = choose(frases, palavras)
    spans = []
    for k, e in enumerate(choices):
        if e:
            i, j, note, kind = e
            spans.append({"ini": palavras[i]["ini"], "fim": palavras[j - 1]["fim"], "i": i, "j": j,
                            "manter": True, "tipo": kind, "motivo": f"frase {k + 1} ({note:.2f})",
                            "confianca": note, "frase": k, "texto": " ".join(p["p"] for p in palavras[i:j])})
    leftovers = classify_leftovers(frases, palavras, choices, trans, toks)
    _dedup_improvisations(leftovers, trans)
    _rephrased(frases, choices, leftovers)
    spans = _stutters(spans, palavras, trans, frases) + leftovers
    spans.sort(key=lambda t: t["i"])
    _continuations(spans, palavras)
    _duplicates(spans, trans)
    found = {t.get("frase") for t in spans if t["manter"]}
    missing = [f["texto"] for k, f in enumerate(frases) if k not in found]
    return spans, missing


def _starts_abandoned(trechos):
    """Fala que sai e é recomeçada logo depois ("Ou seja, os dados não surgiram com a..." → "Ou seja, os dados
    não sugeriram…"): as primeiras palavras repetem o começo do próximo trecho mantido, ou a fala termina em
    reticências. É retake com certeza; não vai para o LLM (que tendia a achar que "completa a frase seguinte")."""
    for k, t in enumerate(trechos):
        if t["manter"] and t["tipo"] not in ("improviso", "retake", "continuacao") or t.get("por") == "claquete":
            continue
        my = [w for w in norm_text(t["texto"]).split() if w]
        prox = next((x for x in trechos[k + 1:] if x["manter"] and x["tipo"] != "continuacao"), None)
        if not my or not prox or prox["ini"] - t["fim"] > 20:
            continue
        following = [w for w in norm_text(" ".join(x["texto"] for x in trechos[trechos.index(prox):][:2])).split() if w]
        n = min(3, len(my))
        restarts = len(my) >= 2 and my[:n] == following[:n] and len(my) <= len(following) + 2
        after = trechos[k + 1] if k + 1 < len(trechos) else None
        xingou = after is not None and after["tipo"] == "bastidor" and after["ini"] - t["fim"] < 2
        cut = t["texto"].rstrip().endswith(("...", "…")) and t["tipo"] in ("retake", "improviso")
        if restarts or cut or (xingou and t["tipo"] in ("retake", "improviso")):
            t.update(manter=False, tipo="retake", confianca=0.95, por="regra",
                     motivo="começo abandonado: recomeçado logo depois" if restarts else
                     "fala interrompida (...)" if cut else "seguida de bastidor (\"droga\")")


DOUBT = 0.7  # trechos com confiança abaixo disto (fora tomadas e bastidor) vão para o LLM local


def _reading_single(trechos):
    """A LLM tira a versão do narrador como "tentativa abandonada" mesmo sem outra leitura da frase, e a frase some do
    vídeo. Reformulada que é a única leitura de uma frase do roteiro fica (a última, se houver duas), com a fala
    que a completa logo depois; só sai a que é gaguejo de verdade ("uma matéria que é uma matéria que é...")."""
    read = {}  # palavras mantidas por frase: "Resumindo," sozinho não cobre "Resumindo: a matemática diz avalanche"
    for t in trechos:
        if t["manter"] and "frase" in t:
            read[t["frase"]] = max(read.get(t["frase"], 0), len(t["texto"].split()))
    for t in reversed(trechos):
        p = t["texto"].lower().split()
        stutter = len(set(p)) < 0.6 * len(p) and len(p) <= 5.5 * (t["fim"] - t["ini"])  # mais rápido é o Whisper em laço
        if t["manter"] or t["tipo"] != "reformulada" or read.get(t.get("frase"), 0) >= 0.5 * min(len(p), 8) or stutter:
            continue
        read[t["frase"]] = len(p)
        t.update(manter=True, por="regra", garantida=True, motivo=t["motivo"] + " → única leitura da frase: fica")
    for k, t in enumerate(trechos[:-1]):
        following = trechos[k + 1]
        if t["manter"] and t["tipo"] == "reformulada" and not re.search(r"[.?!:…]$", t["texto"].strip()) \
                and not following["manter"] and following["tipo"] in ("improviso", "continuacao"):
            following.update(manter=True, por="regra", garantida=True,
                            motivo=following["motivo"] + " → completa a frase anterior: fica")


def _other_take(t, palavras):
    """Retake só existe com outra leitura: a mesma fala de `t` por perto na narração editada ("Um estudo com dados de"
    numa frase e, minutos depois, "um estudo do México, com dados de" são falas diferentes)."""
    target = {x for x in (norm(w) for w in t["texto"].split()) if x}
    outside = [norm(p["p"]) for p in palavras if abs(p["ini"] - t["ini"]) < 90 and (p["fim"] <= t["ini"] or p["ini"] >= t["fim"])]
    n = len(target) + 2
    return any(len(target & set(outside[i:i + n])) >= 0.7 * len(target) for i in range(max(len(outside) - n + 1, 1)))


def review_with_llm(trechos, frases):
    """O LLM local confirma ou inverte as decisões incertas. Sem LLM, fica a regra."""
    from pydantic import BaseModel, Field

    from esteira.core import events
    from esteira.ai import local

    class Decisao(BaseModel):
        manter: bool
        motivo: str = Field(max_length=120)
        confianca: float = Field(ge=0, le=1)

    class Par(BaseModel):
        fica: str = Field(pattern="^(A|B|ambos)$")
        motivo: str = Field(max_length=120)
        confianca: float = Field(ge=0, le=1)

    by_i = {t["i"]: t for t in trechos}
    for t in [t for t in trechos if t.get("par") is not None and t["manter"]]:
        a = by_i.get(t["par"])
        if not a:
            continue
        k = trechos.index(t)
        after = next((x["texto"] for x in trechos[k + 1:] if x["manter"]), "")
        r = local.ask(local.prompt("corte_par", a=a["texto"], b=t["texto"],
                                         depois=" ".join(after.split()[:20])), Par)
        if r:
            # a tomada do roteiro (A) nunca sai por esta comparação: o par é escolhido por palavras em comum e às
            # vezes junta falas sem relação ("Ter parcela a pagar…" × "Que você ganha ali líquido…")
            a.update(por="llm", motivo=a["motivo"] + f" → LLM (par): {r.motivo}")
            t.update(manter=r.fica in ("B", "ambos"), por="llm", confianca=round(r.confianca, 2),
                     motivo=t["motivo"] + f" → LLM (par): fica {r.fica}, {r.motivo}")
            t.pop("par")
    _starts_abandoned(trechos)
    doubts = [t for t in trechos if t["tipo"] in ("improviso", "continuacao", "reformulada", "retake")
               and t["confianca"] < DOUBT and t.get("por") != "llm"]
    for n, t in enumerate(doubts, 1):
        events.progress(n, len(doubts), t["texto"][:40])
        k = trechos.index(t)
        before = next((x["texto"] for x in reversed(trechos[:k]) if x["manter"]), "")
        after = next((x["texto"] for x in trechos[k + 1:] if x["manter"]), "")
        ka, kb = t.get("entre", [t.get("frase", 0)] * 2)
        region = [frases[i]["texto"] for i in range(max(ka, 0), min(kb + 1, len(frases)))][:4]
        d = local.ask(local.prompt("corte", antes=" ".join(before.split()[-25:]),
                                         depois=" ".join(after.split()[:25]), roteiro=json.dumps(region, ensure_ascii=False),
                                         trecho=t["texto"], tipo=t["tipo"], motivo=t["motivo"]), Decisao)
        if d is None:
            t["por"] = "regra"
            continue
        if t["tipo"] == "retake" and d.manter and d.confianca < 0.8:
            # a regra viu a repetição; o LLM só a desfaz com certeza alta
            t.update(por="regra", motivo=f"{t['motivo']} → LLM queria manter ({d.motivo}), sem certeza: sai")
            continue
        t.update(manter=d.manter, confianca=round(d.confianca, 2), por="llm",
                 motivo=f"{t['motivo']} → LLM: {d.motivo}")
    _reading_single(trechos)
    return doubts


def escalate_to_claude(trechos, project):
    """Uma chamada em lote com o que o LLM local deixou incerto (confiança < 0.5 ou sem LLM)."""
    from pydantic import BaseModel

    from esteira.ai import claude

    doubts = [t for t in trechos if not t.get("garantida")
               and (t.get("por") == "regra" and len(t["texto"].split()) >= 2
                    or t.get("por") == "llm" and t["confianca"] < 0.5)]
    if not doubts:
        return 0

    class Item(BaseModel):
        id: int
        manter: bool
        motivo: str

    class Resposta(BaseModel):
        decisoes: list[Item]

    lines = []
    for n, t in enumerate(doubts):
        k = trechos.index(t)
        before = next((x["texto"] for x in reversed(trechos[:k]) if x["manter"] and x is not t), "")
        after = next((x["texto"] for x in trechos[k + 1:] if x["manter"]), "")
        lines.append(f'{n}. ANTES: "…{" ".join(before.split()[-18:])}" | TRECHO: "{t["texto"]}" | '
                      f'DEPOIS: "{" ".join(after.split()[:18])}…" | provisório: {"fica" if t["manter"] else "sai"} '
                      f'({t["motivo"][-80:]})')
    dossier = ("Edição da narração de um vídeo: o narrador lê um roteiro e às vezes improvisa, erra ou repete. "
              "Para cada TRECHO (transcrição automática), decida se FICA (completa a frase, acréscimo útil, "
              "versão própria de uma frase) ou SAI (bastidor, começo abandonado, repetição, palavra solta). "
              "A fala final deve ser contínua e sem frases quebradas.\n\n" + "\n".join(lines))
    r = claude.query(dossier, Resposta, project.cfg, project.ep, f"cortes: {len(doubts)} trechos incertos")
    if not r:
        return 0
    for d in r.decisoes:
        if 0 <= d.id < len(doubts):
            doubts[d.id].update(manter=d.manter, por="claude", confianca=0.9,
                                 motivo=doubts[d.id]["motivo"] + f" → Claude: {d.motivo}")
    return len(r.decisoes)


PAD_START, PAD_END = 0.08, 0.22   # folga antes/depois de cada trecho (o Whisper marca o fim cedo)
MAX_PAUSE = 1.2                 # s: pausa maior dentro de um trecho mantido é encurtada
JOIN = 0.7                    # pausas naturais menores que isto entre trechos ficam como estão


def repetitions(palavras, frases, window=20, maximum=15):
    """Na narração já editada: a mesma sequência de 4+ palavras dita duas vezes em até `janela` s ("Segundo
    motivo, entender o crédito é difícil. Segundo motivo, entender o crédito…") sem que o roteiro a repita
    é um retake que passou. Sai a tentativa anterior (até `maximo` s), fica a última."""
    rot = [w for f in frases for w in (norm(x) for x in f["texto"].split()) if w]
    node_rot = {}
    for k in range(len(rot) - 2):
        node_rot[tuple(rot[k:k + 3])] = node_rot.get(tuple(rot[k:k + 3]), 0) + 1
    w = [norm(p["p"]) for p in palavras]
    output, k = [], 0
    while k < len(w) - 2:
        g = tuple(w[k:k + 3])
        found = None
        if all(g) and sum(map(len, g)) >= 9 and node_rot.get(g, 0) < 2:
            for j in range(k + 3, len(w) - 2):
                if palavras[j]["ini"] - palavras[k]["ini"] > min(window, maximum):
                    break
                if tuple(w[j:j + 3]) == g and j + 3 < len(w) and w[j + 3] == w[k + 3] and w[k + 3]:
                    found = j  # 4+ palavras seguidas iguais ("com o dinheiro" duas vezes numa frase não conta)
                    break
        if found is None:
            k += 1
            continue
        while k > 0 and w[k - 1] and w[k - 1] == w[found - 1] and found - 1 > k:  # "Ou" de "Ou seja…"
            k, found = k - 1, found - 1
        output.append({"ini": palavras[k]["ini"], "fim": min(palavras[found - 1]["fim"], palavras[found]["ini"] - 0.2),
                      "i": k, "j": found, "tipo": "retake", "confianca": 0.9,
                      "texto": " ".join(p["p"] for p in palavras[k:found])})
        k = found
    return output


def _subtract(intervalos, excluir):
    for x0, x1 in excluir:
        new = []
        for a, b in intervalos:
            if x1 <= a or x0 >= b:
                new.append([a, b])
            else:
                if x0 - a > 0.05:
                    new.append([a, x0])
                if b - x1 > 0.05:
                    new.append([x1, b])
        intervalos = new
    return intervalos


def _to_raw(t, intervalos):
    """Instante na narração editada → instante na gravação bruta."""
    acc = 0.0
    for a, b in intervalos:
        if t <= acc + (b - a):
            return a + (t - acc)
        acc += b - a
    return intervalos[-1][1]


# ── Bordas dos cortes no silêncio ────────────────────────────────────────────────────────────────────────
# O tempo de palavra do Whisper erra 0,1–0,3 s (o fim da última palavra antes de uma pausa costuma vir cedo):
# cortar em "fim + folga fixa" engolia sílabas ("porcen…"). Cada borda procura, no envelope de energia da
# gravação, o silêncio real perto da palavra (técnica de edição de diálogo: cortar só em silêncio, com fade
# curto) e deixa nele uma pausa natural conforme a pontuação (fim de frase > vírgula > meio de frase).
Q = 0.01                                  # s por quadro do envelope
SILENCE_MIN = 0.12                       # s abaixo do limiar para contar como pausa (fecho de "p/t/k" é mais curto)
EXTENDS_END, EXTENDS_START = 0.5, 0.3       # quanto a borda pode passar do tempo do Whisper procurando o silêncio
PAUSES = {"frase": 0.45, "virgula": 0.28, "meio": 0.14}   # pausa total que fica numa junção


def envelope(file):
    """Energia (dB) a cada 10 ms da gravação e o limiar de silêncio de cada quadro: 28 dB abaixo do nível típico
    da fala medido numa janela de ~10 s (o volume muda ao longo de 15–45 min; um limiar do arquivo inteiro fazia
    o fim fraco das palavras dos trechos baixos virar "silêncio"). O silêncio digital do noise gate fica fora."""
    import numpy as np

    from esteira import edges
    from esteira.transcribe import _decode
    x = _decode(file)
    n = len(x) // 160
    db = 10 * np.log10((x[:n * 160].reshape(n, 160) ** 2).mean(axis=1) + 1e-10)
    valid = db > -95
    limit = edges.floor(db, 60, validos=valid) - 28 if valid.any() else np.full(n, -50.0)
    return {"db": db, "lim": limit}


def _limit(env):
    import numpy as np
    return np.broadcast_to(env["lim"], env["db"].shape)


def _pause(word):
    p = word.rstrip()[-1:]
    return PAUSES["frase"] if p in ".?!…" else PAUSES["virgula"] if p in ",;:" else PAUSES["meio"]


def _silence(env, t, limite):
    """Primeira pausa (≥ SILENCIO_MIN) andando de t até limite (para trás se limite < t) → (ini, fim) ou None."""
    db, limit, n = env["db"], _limit(env), len(env["db"])
    step = 1 if limite >= t else -1
    k, end_k, run = int(t / Q), int(limite / Q), 0
    needs = int(SILENCE_MIN / Q)
    while 0 <= k < n and (k <= end_k if step > 0 else k >= end_k):
        run = run + 1 if db[k] < limit[k] else 0
        if run >= needs:
            a = k - step * (run - 1)          # onde a pausa começou (no sentido da busca)
            b = k
            while 0 <= b + step < n and db[b + step] < limit[b + step]:  # vai até o fim da pausa
                b += step
            start, end = sorted((a, b))
            return start * Q, (end + 1) * Q
        k += step
    return None


def _applies(env, a, b):
    """Instante de menor energia entre a e b (sem pausa à vista: o ponto menos audível para cortar)."""
    db = env["db"]
    i, f = max(int(a / Q), 0), min(int(b / Q) + 1, len(db))
    return (i + int(db[i:f].argmin())) * Q if f > i else a


def _edge_end(env, end_w, prox_start, slack):
    limit = min(end_w + EXTENDS_END, max(prox_start, end_w + 0.05))
    s = _silence(env, end_w, limit)
    return s[0] + min(slack, s[1] - s[0]) if s else _applies(env, end_w, limit)


def _edge_start(env, start_w, ant_end, slack):
    limit = max(start_w - EXTENDS_START, min(ant_end, start_w - 0.05))
    s = _silence(env, start_w, limit)  # começar dentro da palavra lia um "s" inicial fraco como pausa
    return s[1] - min(slack, s[1] - s[0]) if s else _applies(env, limit, start_w)


def _intervals(trechos, palavras, excluir=(), env=None):
    """Trechos mantidos → intervalos de áudio (s) na gravação, sem pausas longas. Com `env` (envelope da
    gravação), cada borda cai no silêncio real; sem ele, folga fixa em volta do tempo do Whisper."""
    blocks = []  # [primeira, última] palavra de cada pedaço contínuo mantido
    for t in sorted((t for t in trechos if t["manter"]), key=lambda t: t["i"]):
        for k in range(t["i"], t["j"]):
            # só emenda palavras vizinhas: uma palavra cortada no meio nunca entra por estar perto
            if (blocks and k == blocks[-1][1] + 1
                    and palavras[k]["ini"] - palavras[k - 1]["fim"] <= (JOIN if k == t["i"] else MAX_PAUSE)):
                blocks[-1][1] = k
            else:
                blocks.append([k, k])
    output = []
    for n, (ki, kf) in enumerate(blocks):
        if env is None:
            output.append([max(palavras[ki]["ini"] - PAD_START, 0.0), palavras[kf]["fim"] + PAD_END])
            continue
        prox = palavras[kf + 1]["ini"] if kf + 1 < len(palavras) else palavras[kf]["fim"] + 2
        ant = palavras[ki - 1]["fim"] if ki else 0.0
        pause_ant = _pause(palavras[blocks[n - 1][1]]["p"]) if n else PAUSES["frase"]
        a = _edge_start(env, palavras[ki]["ini"], ant, pause_ant * 0.4)
        b = _edge_end(env, palavras[kf]["fim"], prox, _pause(palavras[kf]["p"]) * 0.6)
        output.append([max(a, 0.0), max(b, a + 0.05)])
    for x, y in zip(output, output[1:]):
        x[1] = min(x[1], y[0])
    if env is None:
        return _subtract(output, excluir)
    # exclusões (retakes achados na narração editada) também cortam no ponto menos audível
    excluir = [[_applies(env, x0 - 0.25, x0 + 0.1), _applies(env, x1 - 0.1, x1 + 0.25)] for x0, x1 in excluir]
    output = _subtract(output, excluir)
    # regra de ouro (esteira/edges.py): nenhuma borda dentro do núcleo de uma palavra mantida
    from esteira import edges
    sound = env["db"] >= _limit(env)
    stays = [(palavras[k]["ini"], palavras[k]["fim"]) for ki, kf in blocks for k in range(ki, kf + 1)]
    stays = [(a, b) for a, b in stays
            if sum(max(0.0, min(b, y) - max(a, x)) for x, y in excluir) < 0.5 * max(b - a, 1e-3)]
    everything = [(w["ini"], w["fim"]) for w in palavras]
    return edges.validate(output, edges.cores(stays, sound, everything), len(env["db"]) * Q)


def _aligned(project, raw, palavras):
    """Palavras da bruta com ini/fim do alinhamento forçado (`esteira/alignment.py`); sem ele, as do Whisper."""
    from esteira import alignment
    items = [[w["ini"], w["fim"], w["p"]] for w in palavras]
    al = alignment.refine(raw, items, project.caminho("bordas_palavras.json"), project.cfg)
    return [{**w, "ini": a, "fim": b} for w, (a, b, _) in zip(palavras, al, strict=True)]


def render_audio(entrada, intervalos, destino, folder_tmp):
    filters = [f"[0:a]atrim={a:.3f}:{b:.3f},asetpts=PTS-STARTPTS,"
               f"afade=t=in:d=0.01,afade=t=out:st={b - a - 0.015:.3f}:d=0.015[s{n}]"
               for n, (a, b) in enumerate(intervalos)]
    filters.append("".join(f"[s{n}]" for n in range(len(intervalos))) + f"concat=n={len(intervalos)}:v=0:a=1")
    script = folder_tmp / "cortes.filtro"
    script.write_text(";\n".join(filters))
    import subprocess
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", entrada, "-filter_complex_script",
                    script, "-ac", "1", "-c:a", "pcm_s16le", destino], check=True)
    script.unlink()


def report(trechos, faltando, destino, duration_raw, duration_final, avisos=()):
    mark = {"tomada": "  ", "reformulada": "R ", "continuacao": "C ", "improviso": "I ", "retake": "↺ ",
             "bastidor": "B ", "fora": "F ", "descartado": "X ", "marcador": "M "}
    with open(destino, "w") as f:
        f.write(f"bruta {duration_raw:.0f}s → editada {duration_final:.0f}s\n"
                "legenda: + fica · - sai · R reformulada · C continuação · I improviso · ↺ retake · B bastidor"
                " · X leitura descartada · M marcador\n"
                "quem decidiu: [r] regra · [l] LLM local · [c] Claude · [m] marcador falado\n\n")
        if avisos:
            f.write("CLAQUETE (corte/cancela parte N)\n" + "".join(f"  - {a}\n" for a in avisos) + "\n")
        if faltando:
            f.write("FRASES DO ROTEIRO SEM TOMADA\n" + "".join(f"  - {t}\n" for t in faltando) + "\n")
        for t in trechos:
            if t["tipo"] == "tomada" and t["confianca"] >= 0.85:
                continue  # tomada limpa: não precisa conferir
            if t["tipo"] == "marcador":
                continue
            por = {"llm": "l", "claude": "c", "claquete": "m"}.get(t.get("por"), "r")
            f.write(f"{t['ini']:7.1f}s {'+' if t['manter'] else '-'} {mark.get(t['tipo'], '? ')}[{por}] "
                    f"{t['texto'][:110]}\n          {t['motivo'][:150]}\n")


def _recording_new(project):
    """Narração nova posta na pasta (narracao.*) depois de um limpar: não é a editada que a esteira gerou.
    A gravação bruta anterior e as decisões dela vão para gravacoes_anteriores/<data>/."""
    from datetime import datetime

    from esteira.core import events
    from esteira.project import AUDIO_EXT
    reg = project.caminho("narracao.render.json")
    tj = project.caminho("transcricao.json")
    new = None
    for p in sorted(project.pasta.glob("narracao.*")):
        if p.suffix.lower() not in AUDIO_EXT:
            continue
        st = p.stat()
        if reg.exists():
            generated = p.suffix == ".wav" and json.loads(reg.read_text()) == [st.st_size, st.st_mtime_ns]
        else:  # episódio antigo: a editada é sempre seguida da transcrição dela
            generated = p.suffix == ".wav" and tj.exists() and st.st_mtime <= tj.stat().st_mtime + 2
        if not generated:
            new = p
    if not new:
        return False
    destination = project.caminho("gravacoes_anteriores") / datetime.now().strftime("%Y%m%d-%H%M")
    destination.mkdir(parents=True, exist_ok=True)
    for name in [b.name for b in project.pasta.glob("narracao_bruta.*")] + [
            "transcricao_bruta.json", "cortes.json", "cortes.txt", "narracao.render.json"]:
        if project.caminho(name).exists():
            project.caminho(name).rename(destination / name)
    if new.suffix != ".wav" and project.caminho("narracao.wav").exists():
        project.caminho("narracao.wav").unlink()  # editada da gravação anterior (Projeto.audio a pegaria antes)
    events.warning(f"gravação nova ({new.name}): a anterior e os cortes dela foram para {destination.relative_to(project.pasta)}")
    print(f"  gravação nova: anterior guardada em {destination.relative_to(project.pasta)}")
    return True


def aplicar(project, refazer=False):
    """Etapa limpar: gravação bruta → narracao.wav + cortes.json/cortes.txt + transcricao.json."""
    from esteira.core import events
    from esteira.sources import recordings
    from esteira.sources.importer import update_script
    from esteira.transcribe import transcribe
    if update_script(project):  # o narrador lê o roteiro do vault: tem de ser o mesmo texto
        print("  roteiro atualizado do vault")
        events.warning("roteiro mudou no vault desde a importação: reimportado")
        refazer = True
    pulled = recordings.update(project)  # WAV mais novo do episódio em ~/Music/Youtube/<Canal>/
    if pulled:
        print(f"  gravação nova encontrada: {pulled}")
        events.warning(f"gravação nova puxada de {pulled}")
    raw = next(iter(sorted(project.pasta.glob("narracao_bruta.*"))), None)
    if raw and _recording_new(project):
        raw = None  # a anterior foi para gravacoes_anteriores/; cortes decididos do zero
        refazer = True
    if not raw:
        current = project.audio()
        raw = current.with_name(f"narracao_bruta{current.suffix}")
        current.rename(raw)
    if not project.roteiro():
        raise SystemExit("limpar precisa do roteiro.txt")
    tb = project.caminho("transcricao_bruta.json")
    # transcrição anterior à retranscrição das palavras esticadas (retakes escondidos): refaz com --refazer
    if not tb.exists() or (refazer and not project.load_json("transcricao_bruta.json").get("refinada")):
        transcribe(project, project.cfg, audio=raw, saida_json="transcricao_bruta.json")
    transc = project.load_json("transcricao_bruta.json")
    from esteira import clapper
    sentences = sentences_of_script(project.roteiro().read_text())
    parts = clapper.of_project(project)
    words = transc["palavras"]
    warnings = []

    file = project.caminho("cortes.json")
    if file.exists() and not refazer:  # decisões já tomadas (e talvez ajustadas na tela) são reaproveitadas
        data = json.loads(file.read_text())
        spans, missing, warnings = data["trechos"], data["faltando"], data.get("avisos", [])
        print(f"  usando cortes.json existente ({len(spans)} trechos); --refazer para decidir de novo")
    else:
        r = clapper.decide(parts, words)
        if r:  # gravação com "corte/cancela parte N": a escolha das tomadas é do narrador
            spans, missing, warnings = r
            n = sum(1 for t in spans if t["tipo"] == "marcador")
            print(f"  claquete: {n} marcadores, {len(parts)} partes no roteiro")
            for a in warnings:
                events.warning(a)
        else:
            spans, missing = decide(sentences, words)
        doubts = review_with_llm(spans, sentences)
        print(f"  {len(spans)} trechos; {len(doubts)} dúvidas revisadas pelo LLM local")
        _duplicates(spans, _tokens(words))
        n = escalate_to_claude(spans, project)
        if n:
            print(f"  {n} trechos decididos pelo Claude")
        file.write_text(json.dumps({"trechos": spans, "faltando": missing, "avisos": warnings},
                                  ensure_ascii=False, indent=1))
        data = {}

    delete = data.get("excluir", []) if file.exists() and not refazer else []
    destination = project.caminho("narracao.wav")
    env = envelope(raw)  # energia da gravação: as bordas dos cortes caem no silêncio
    words = _aligned(project, raw, words)  # tempos certos só para as bordas (decisões já tomadas)
    # Passadas: renderiza, transcreve a narração editada e procura retakes que o Whisper escondeu na
    # gravação bruta (palavras "esticadas" sobre um retake). Cada um achado volta para o tempo da bruta
    # como exclusão em cortes.json e o áudio é refeito.
    for skip in range(1, 5):
        intervals = _intervals(spans, words, delete, env)
        render_audio(raw, intervals, destination, project.pasta)
        st = destination.stat()
        project.caminho("narracao.render.json").write_text(json.dumps([st.st_size, st.st_mtime_ns]))
        new = transcribe(project, project.cfg)  # transcricao.json passa a ser da narração editada
        t2, missing_edited = decide(sentences, new["palavras"])
        hidden = [t for t in t2 if t["tipo"] == "retake" and t["confianca"] >= 0.8 and t["j"] - t["i"] >= 3]
        hidden += [r for r in repetitions(new["palavras"], sentences)
                    if not any(o["ini"] < r["fim"] and r["ini"] < o["fim"] for o in hidden)]
        fake = [t for t in hidden if not _other_take(t, new["palavras"])]
        for t in fake:
            events.debug("retake sem outra tomada: fica", editado=t["ini"], texto=t["texto"][:80])
        hidden = [t for t in hidden if t not in fake]
        if not hidden or skip == 4:
            for t in hidden:
                events.warning(f"possível retake na narração editada em {t['ini']:.1f}s: {t['texto'][:70]}")
            break
        for t in hidden:
            delete.append([round(_to_raw(t["ini"] - 0.05, intervals), 3),
                            round(_to_raw(t["fim"] + 0.15, intervals), 3)])
            events.debug("retake oculto", editado=t["ini"], bruto=delete[-1], texto=t["texto"][:80])
        print(f"  passada {skip}: {len(hidden)} retakes ocultos achados; refazendo o áudio")
        file.write_text(json.dumps({"trechos": spans, "faltando": missing, "excluir": delete},
                                  ensure_ascii=False, indent=1))
    # Intervalos mantidos (tempo da gravação bruta): no modo apresentador a câmera é cortada igual ao áudio.
    current = json.loads(file.read_text()) if file.exists() else {}  # mantém marcas do painel (editado_no_painel)
    current.update(trechos=spans, faltando=missing, excluir=delete, avisos=warnings,
                 intervalos=[[round(a, 4), round(b, 4)] for a, b in intervals])
    file.write_text(json.dumps(current, ensure_ascii=False, indent=1))
    report(spans, missing, project.caminho("cortes.txt"), transc["duracao"], new["duracao"], warnings)
    # conferência: frases do roteiro que não estão inteiras na narração editada (palavra ou número cortado)
    broken = [t for t in t2 if t["tipo"] in ("tomada", "reformulada") and t["confianca"] < 0.75]
    with open(project.caminho("cortes.txt"), "a") as f:
        f.write("\nCONFERÊNCIA DA NARRAÇÃO EDITADA (tempo no vídeo)\n")
        for x in missing_edited:
            f.write(f"  falta: {x}\n")
        for t in broken:
            f.write(f"  {t['ini']:7.1f}s incompleta ({t['confianca']:.2f}): {t['texto'][:100]}\n")
        if not missing_edited and not broken:
            f.write("  todas as frases do roteiro estão inteiras\n")
    from esteira import edges
    stays = [(words[k]["ini"], words[k]["fim"], words[k]["p"]) for t in spans if t["manter"]
            for k in range(t["i"], t["j"])]
    stays = [w for w in stays if sum(max(0.0, min(w[1], y) - max(w[0], x)) for x, y in delete) < 0.5 * (w[1] - w[0])]
    cut = edges.losses([w[:2] for w in stays], intervals, [w[2] for w in stays])
    with open(project.caminho("cortes.txt"), "a") as f:
        for c in cut:
            f.write(f"  {c['t']:7.1f}s (bruta) palavra cortada ({c['perdeu']:.0%} fora): {c['texto']}\n")
    if cut:
        events.warning(f"{len(cut)} palavra(s) mantida(s) cortada(s) nas bordas (ver o fim de cortes.txt)")
    if missing_edited or broken:
        events.warning(f"narração editada: {len(missing_edited)} frases faltando e {len(broken)} incompletas "
                      f"(ver o fim de cortes.txt)")
    cortados = sum(1 for t in spans if not t["manter"])
    print(f"  bruta {transc['duracao']:.0f}s → editada {new['duracao']:.0f}s ({cortados} trechos e "
          f"{len(delete)} retakes ocultos cortados); {len(missing)} frases sem tomada → cortes.txt")
