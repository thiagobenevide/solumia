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

IGUAL, PARECIDA, TROCA, FALTA, SOBRA = 1.0, 0.7, -0.6, -0.7, -0.25
BOA, REFORMULADA = 0.62, 0.35     # nota mínima (por palavra do roteiro) de uma tomada / de uma reformulação
QUASE_MELHOR = 0.12              # entre tomadas com nota até isto abaixo da melhor, fica a mais tardia
MAX_RECUO = 90                   # s: a tomada de uma frase não pode estar mais longe que isto da seguinte
PAUSA_FALA = 0.55                # s: pausa que separa duas falas no que sobra entre tomadas
NUMEROS = dict(zip("0 1 2 3 4 5 6 7 8 9 10".split(),
                   "zero um dois tres quatro cinco seis sete oito nove dez".split()))
RE_BASTIDOR = re.compile(
    r"\b(vamos (fazer|gravar|de novo|la)|nova gravacao|de novo|gravando|repet\w*|errei|desculp\w*|"
    r"eita|opa|pera(i)?|agua|ok\b|beleza|deixa eu|pronto|tá bom|ta bom|hum+|ah+|eh+|"
    r"droga|merda|porra|caramba|putz|corta|cortar|perai|nao foi|ficou ruim)\b")


def norm(p):
    s = unicodedata.normalize("NFKD", p.lower())
    s = re.sub(r"[^\w]", "", "".join(c for c in s if not unicodedata.combining(c)))
    return NUMEROS.get(s, s)


def _radical(palavra):
    """Compara pelo começo da palavra: "começa" = "começar", "ganha" = "ganhar", "2" = "dois"."""
    return norm(palavra)[:5]


def frases_do_roteiro(texto):
    frases = []
    for linha in texto.splitlines():
        linha = linha.strip()
        if not linha or linha.startswith("#"):
            continue
        linha = re.sub(r"\[[^\]]*\]", "", linha).replace("*", "")
        for f in re.split(r"(?<=[.?!:;])\s+", linha):
            palavras = [_radical(w) for w in f.split()]
            palavras = [w for w in palavras if w]
            if palavras:
                frases.append({"texto": f.strip(), "norm": palavras})
    return frases


class _Tok:
    __slots__ = ("n", "r")

    def __init__(self, palavra):
        self.n = norm(palavra)
        self.r = self.n[:5]

    def __bool__(self):
        return bool(self.n)


_cache = {}
RE_FRAGMENTO = re.compile(r"^[.,]\d")


def _tokens(palavras):
    """Palavras da transcrição → _Tok. O Whisper parte números ("12", ",5", "%"), o roteiro escreve "12,5%":
    o pedaço decimal é juntado à palavra anterior ("125") e fica vazio (palavra vazia não custa no alinhamento).
    Sem isso o número não casa com o roteiro e a tomada começa depois dele (o número era cortado)."""
    toks = [_Tok(p["p"]) for p in palavras]
    for k in range(1, len(toks)):
        if RE_FRAGMENTO.match(palavras[k]["p"].strip()) and toks[k - 1].n[-1:].isdigit():
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


def alinhar(frase, trans, ini, fim):
    """Frase inteira × trecho trans[ini:fim] com início/fim livres no trecho. → (nota, i, j, casadas)."""
    n, m = len(frase), fim - ini
    ant = [0.0] * (m + 1)  # linha 0: começar em qualquer ponto do trecho é grátis
    orig = list(range(m + 1))  # onde começou o alinhamento que chega em (i, j)
    for i in range(1, n + 1):
        cur, cori = [FALTA * i] + [0.0] * m, [0] + [0] * m
        for j in range(1, m + 1):
            s = _sim(frase[i - 1], trans[ini + j - 1])
            diag = ant[j - 1] + (IGUAL if s == 1 else PARECIDA if s else TROCA)
            cima, esq = ant[j] + FALTA, cur[j - 1] + (SOBRA if trans[ini + j - 1].n else 0)
            if diag >= cima and diag >= esq:
                cur[j], cori[j] = diag, orig[j - 1]
            elif cima >= esq:
                cur[j], cori[j] = cima, orig[j]
            else:
                cur[j], cori[j] = esq, cori[j - 1]
        ant, orig = cur, cori
    j = max(range(1, m + 1), key=lambda x: ant[x]) if m else 0
    return ant[j] / n, ini + orig[j], ini + j


def candidatos(frase, trans, ate):
    """Tomadas possíveis da frase antes do índice `ate`: [(nota, i, j)] sem repetição."""
    n = len(frase)
    inicios = {f.n for f in frase[:3]}
    vistos, saida = set(), []
    for i in range(ate):
        if trans[i].n not in inicios and not any(_sim(trans[i], f) for f in frase[:3]):
            continue
        fim = min(ate, i + int(n * 1.6) + 4)
        nota, a, b = alinhar(frase, trans, i, fim)
        if b > a and (a, b) not in vistos and nota >= REFORMULADA:
            vistos.add((a, b))
            saida.append((nota, a, b))
    return saida


def _ultimo_reinicio(frase, trans, i, j, nota):
    """Tomada que contém um recomeço ("Em 2012, os pesquisadores… Em 2012, os pesquisadores David…")
    passa a começar no último recomeço que mantém a nota."""
    for s in range(i + 1, j):
        if any(_sim(trans[s], f) == 1 for f in frase[:2]):
            n2, a, b = alinhar(frase, trans, s, j)
            if n2 >= nota - 0.05 and b - a >= len(frase) * 0.6:
                i, j, nota = a, b, n2
    return i, j, nota


def escolher(frases, palavras):
    """[(i, j, nota, tipo)] por frase do roteiro (None se não achou)."""
    trans = _tokens(palavras)
    toks = [[t for t in map(_Tok, f["texto"].split()) if t] for f in frases]
    escolhas = [None] * len(frases)
    limite = len(palavras)
    for k in range(len(frases) - 1, -1, -1):
        if not toks[k]:
            continue
        cands = candidatos(toks[k], trans, limite)
        if limite < len(palavras):
            cands = [c for c in cands if palavras[limite]["ini"] - palavras[c[2] - 1]["fim"] <= MAX_RECUO]
        if not cands:
            continue
        melhor = max(c[0] for c in cands)
        piso = max(melhor - QUASE_MELHOR, BOA if melhor >= BOA else REFORMULADA)
        nota, i, j = max((c for c in cands if c[0] >= piso), key=lambda c: c[2])
        i, j, nota = _ultimo_reinicio(toks[k], trans, i, j, nota)
        while j < min(len(palavras), limite) and not trans[j] and palavras[j]["ini"] - palavras[j - 1]["fim"] < 0.4:
            j += 1  # o pedaço do número que foi juntado (",7%") vai junto com a tomada
        escolhas[k] = (i, j, round(nota, 3), "tomada" if nota >= BOA else "reformulada")
        limite = i
    return escolhas, trans, toks


def _falas(palavras, ini, fim):
    """Divide palavras[ini:fim] em falas pelas pausas e pela pontuação do Whisper."""
    falas, atual = [], []
    for k in range(ini, fim):
        if atual and (palavras[k]["ini"] - palavras[k - 1]["fim"] > PAUSA_FALA
                      or palavras[k - 1]["p"].rstrip()[-1:] in ".?!"):
            falas.append(atual)
            atual = []
        atual.append(k)
    return falas + ([atual] if atual else [])


def _partir_retakes(falas, viz, trans):
    """Fala longa com uma frase do roteiro inteira dentro (retake que o Whisper juntou a outra fala) é
    partida: o pedaço que repete a frase vira uma fala própria (que a cobertura depois marca como retake)."""
    saida = []
    for fala in falas:
        pedacos, ini = [], fala[0]
        if len(fala) >= 6:
            for f in viz:
                if len(f) < 4:
                    continue
                nota, a, b = alinhar(f, trans, ini, fala[-1] + 1)
                if nota >= BOA and b - a >= 3:
                    pedacos += [list(range(ini, a)), list(range(a, b))]
                    ini = b
        pedacos.append(list(range(ini, fala[-1] + 1)))
        saida += [p for p in pedacos if p]
    return saida


def _cobertura(fala, toks_vizinhas, trans):
    """Fração das palavras da fala que repetem alguma frase vizinha (retake/começo falso)."""
    fala = [k for k in fala if trans[k]]
    if not fala:
        return 1.0
    melhor = 0.0
    for f in toks_vizinhas:
        sm = sum(1 for k in fala if any(_sim(trans[k], t) for t in f))
        melhor = max(melhor, sm / len(fala))
    return melhor


def _dedup_improvisos(sobras, trans, janela=120):
    """Improviso regravado: a versão anterior cobre-se pela seguinte (até `janela` s depois) e sai."""
    imp = [s for s in sobras if s["tipo"] == "improviso"]
    for a in imp:
        depois = [[trans[k] for k in range(b["i"], b["j"]) if trans[k]] for b in imp
                  if b is not a and a["fim"] <= b["ini"] <= a["fim"] + janela]
        cob = _cobertura(list(range(a["i"], a["j"])), depois, trans) if depois else 0
        if cob >= 0.6:
            a.update(manter=False, tipo="retake", confianca=round(min(0.9, cob), 2),
                     motivo="improviso regravado logo depois")


def classificar_sobras(frases, palavras, escolhas, trans, toks):
    """Trechos fora das tomadas escolhidas, com decisão provisória."""
    usados = [(e[0], e[1], k) for k, e in enumerate(escolhas) if e]
    usados.sort()
    saida = []
    fronteiras = [(0, 0, -1)] + usados + [(len(palavras), len(palavras), len(frases))]
    for (_, a, ka), (b, _, kb) in zip(fronteiras, fronteiras[1:]):
        if b <= a:
            continue
        viz = [toks[k] for k in range(max(ka - 3, 0), min(kb + 4, len(frases))) if toks[k]]
        for fala in _partir_retakes(_falas(palavras, a, b), viz, trans):
            texto = " ".join(palavras[k]["p"] for k in fala).strip()
            t = norm_texto(texto)
            cob = _cobertura(fala, viz, trans)
            if RE_BASTIDOR.search(t) and len(fala) <= 12:
                tipo, manter, conf, motivo = "bastidor", False, 0.9, "fala de bastidor"
            elif cob >= 0.6:
                tipo, manter, conf, motivo = "retake", False, round(min(0.95, cob), 2), "repete frase vizinha"
            elif ka < 0 or kb >= len(frases):
                tipo, manter, conf, motivo = "fora", False, 0.8, "antes/depois do roteiro"
            else:
                manter = len(fala) >= 4
                tipo, conf, motivo = "improviso", 0.5, "fala fora do roteiro entre tomadas"
            saida.append({"ini": palavras[fala[0]]["ini"], "fim": palavras[fala[-1]]["fim"], "i": fala[0],
                          "j": fala[-1] + 1, "manter": manter, "tipo": tipo, "motivo": motivo,
                          "confianca": conf, "texto": texto, "entre": [ka, kb]})
    return saida


def norm_texto(t):
    return " ".join(norm(w) for w in t.split())


def _duplicados(trechos, trans, janela=75):
    """Improviso/reformulação mantido cujas palavras de conteúdo já estão nas tomadas mantidas por perto
    (antes ou depois, somadas) sai: a mesma ideia dita duas vezes na edição final."""
    tomadas = [t for t in trechos if t["tipo"] == "tomada" and t["manter"]]
    for a in trechos:
        if not a["manter"] or a["tipo"] == "tomada" or a["j"] - a["i"] < 3:
            continue
        if a["tipo"] == "reformulada" and not any(t is not a and t["manter"] and t.get("frase") == a.get("frase")
                                                  for t in trechos):
            continue  # única versão de uma frase do roteiro: palavras em comum com outras frases não a tornam repetida
        conteudo = [trans[k].r for k in range(a["i"], a["j"]) if len(trans[k].n) >= 4]
        perto = {trans[k].r for t in tomadas if abs(t["ini"] - a["ini"]) <= janela for k in range(t["i"], t["j"])}
        cob = sum(r in perto for r in conteudo) / len(conteudo) if conteudo else 0
        if 0.35 <= cob < 0.7 and a["tipo"] == "improviso":
            # mesma ideia em outra versão? o LLM compara com a tomada mais parecida
            alvo = max((t for t in tomadas if abs(t["ini"] - a["ini"]) <= janela),
                       key=lambda t: len(set(conteudo) & {trans[k].r for k in range(t["i"], t["j"])}))
            a["par"] = alvo["i"]
            a["confianca"] = min(a["confianca"], 0.5)
        if cob >= 0.7:
            a.update(manter=False, tipo="retake", confianca=round(min(0.9, cob), 2),
                     motivo="repete uma tomada mantida", por="regra")


def _continuacoes(trechos, palavras):
    """Fala curta colada no fim de um trecho mantido (ex.: "fecha aspas") continua a frase."""
    for a, b in zip(trechos, trechos[1:]):
        if (a["manter"] and not b["manter"] and b["tipo"] == "improviso"
                and b["ini"] - a["fim"] <= 0.3 and b["j"] - b["i"] <= 3):
            b.update(manter=True, tipo="continuacao", confianca=0.6, motivo="colada no fim da frase anterior")


def _conteudo(texto):
    return {norm(w)[:5] for w in texto.split() if len(norm(w)) >= 4}


def _reformuladas(frases, escolhas, sobras):
    """Frase do roteiro sem tomada: um improviso entre as frases vizinhas que divide as palavras de
    conteúdo com ela é a versão reformulada (o LLM confirma depois)."""
    for k, e in enumerate(escolhas):
        if e:
            continue
        alvo = _conteudo(frases[k]["texto"])
        if not alvo:
            continue
        for s in sobras:
            if s["tipo"] in ("improviso", "retake") and s["motivo"] != "fala de bastidor" and s["entre"][0] < k < s["entre"][1]:
                comum = len(alvo & _conteudo(s["texto"])) / len(alvo)
                # frase curta que o Whisper ouviu errado ("inadimplente" → "E nada implante"): compara as letras
                letras = SequenceMatcher(None, norm_texto(frases[k]["texto"]).replace(" ", ""),
                                         norm_texto(s["texto"]).replace(" ", "")).ratio()
                if comum >= 0.5 or (len(frases[k]["norm"]) <= 4 and letras >= 0.7):
                    s.update(manter=True, tipo="reformulada", confianca=0.45, frase=k,
                             motivo=f"versão própria de: {frases[k]['texto'][:60]}")


def _gaguejos(trechos, palavras, trans, frases):
    """Palavra repetida colada dentro de uma tomada ("eram Eram 81", "é é de longe", "um um método") que o roteiro
    não repete: a primeira sai (vira um trecho próprio, cortado no ponto menos audível)."""
    saida = []
    for t in trechos:
        if not (t["manter"] and t["tipo"] in ("tomada", "reformulada")):
            saida.append(t)
            continue
        rot = norm_texto(frases[t["frase"]]["texto"]) if t.get("frase") is not None else ""
        cortes, k = [], t["i"]  # [(início, fim)] da 1ª cópia de 1–3 palavras repetidas em seguida
        while k < t["j"] - 1:
            for n in (3, 2, 1):
                a, b = [x.n for x in trans[k:k + n]], [x.n for x in trans[k + n:k + 2 * n]]
                if (k + 2 * n <= t["j"] and all(a) and a == b and " ".join(a + a) not in rot
                        and palavras[k + n]["ini"] - palavras[k + n - 1]["fim"] < 0.6):
                    cortes.append((k, k + n))
                    k += n
                    break
            else:
                k += 1
        ini = t["i"]
        for k0, k1 in cortes:
            if k0 > ini:
                saida.append(dict(t, i=ini, j=k0, ini=palavras[ini]["ini"], fim=palavras[k0 - 1]["fim"],
                                  texto=" ".join(p["p"] for p in palavras[ini:k0])))
            saida.append({"ini": palavras[k0]["ini"], "fim": palavras[k1 - 1]["fim"], "i": k0, "j": k1, "manter": False,
                          "tipo": "retake", "motivo": "gaguejo: palavra repetida", "confianca": 0.95, "por": "regra",
                          "texto": " ".join(p["p"] for p in palavras[k0:k1])})
            ini = k1
        if ini < t["j"]:
            saida.append(dict(t, i=ini, ini=palavras[ini]["ini"], texto=" ".join(p["p"] for p in palavras[ini:t["j"]])))
    return saida


def decidir(frases, palavras):
    escolhas, trans, toks = escolher(frases, palavras)
    trechos = []
    for k, e in enumerate(escolhas):
        if e:
            i, j, nota, tipo = e
            trechos.append({"ini": palavras[i]["ini"], "fim": palavras[j - 1]["fim"], "i": i, "j": j,
                            "manter": True, "tipo": tipo, "motivo": f"frase {k + 1} ({nota:.2f})",
                            "confianca": nota, "frase": k, "texto": " ".join(p["p"] for p in palavras[i:j])})
    sobras = classificar_sobras(frases, palavras, escolhas, trans, toks)
    _dedup_improvisos(sobras, trans)
    _reformuladas(frases, escolhas, sobras)
    trechos = _gaguejos(trechos, palavras, trans, frases) + sobras
    trechos.sort(key=lambda t: t["i"])
    _continuacoes(trechos, palavras)
    _duplicados(trechos, trans)
    achadas = {t.get("frase") for t in trechos if t["manter"]}
    faltando = [f["texto"] for k, f in enumerate(frases) if k not in achadas]
    return trechos, faltando


def _comecos_abandonados(trechos):
    """Fala que sai e é recomeçada logo depois ("Ou seja, os dados não surgiram com a..." → "Ou seja, os dados
    não sugeriram…"): as primeiras palavras repetem o começo do próximo trecho mantido, ou a fala termina em
    reticências. É retake com certeza; não vai para o LLM (que tendia a achar que "completa a frase seguinte")."""
    for k, t in enumerate(trechos):
        if t["manter"] and t["tipo"] not in ("improviso", "retake", "continuacao") or t.get("por") == "claquete":
            continue
        meu = [w for w in norm_texto(t["texto"]).split() if w]
        prox = next((x for x in trechos[k + 1:] if x["manter"] and x["tipo"] != "continuacao"), None)
        if not meu or not prox or prox["ini"] - t["fim"] > 20:
            continue
        seguinte = [w for w in norm_texto(" ".join(x["texto"] for x in trechos[trechos.index(prox):][:2])).split() if w]
        n = min(3, len(meu))
        recomeca = len(meu) >= 2 and meu[:n] == seguinte[:n] and len(meu) <= len(seguinte) + 2
        apos = trechos[k + 1] if k + 1 < len(trechos) else None
        xingou = apos is not None and apos["tipo"] == "bastidor" and apos["ini"] - t["fim"] < 2
        cortada = t["texto"].rstrip().endswith(("...", "…")) and t["tipo"] in ("retake", "improviso")
        if recomeca or cortada or (xingou and t["tipo"] in ("retake", "improviso")):
            t.update(manter=False, tipo="retake", confianca=0.95, por="regra",
                     motivo="começo abandonado: recomeçado logo depois" if recomeca else
                     "fala interrompida (...)" if cortada else "seguida de bastidor (\"droga\")")


DUVIDA = 0.7  # trechos com confiança abaixo disto (fora tomadas e bastidor) vão para o LLM local


def _leitura_unica(trechos):
    """A LLM tira a versão do narrador como "tentativa abandonada" mesmo sem outra leitura da frase, e a frase some do
    vídeo. Reformulada que é a única leitura de uma frase do roteiro fica (a última, se houver duas), com a fala
    que a completa logo depois; só sai a que é gaguejo de verdade ("uma matéria que é uma matéria que é...")."""
    lido = {}  # palavras mantidas por frase: "Resumindo," sozinho não cobre "Resumindo: a matemática diz avalanche"
    for t in trechos:
        if t["manter"] and "frase" in t:
            lido[t["frase"]] = max(lido.get(t["frase"], 0), len(t["texto"].split()))
    for t in reversed(trechos):
        p = t["texto"].lower().split()
        gaguejo = len(set(p)) < 0.6 * len(p) and len(p) <= 5.5 * (t["fim"] - t["ini"])  # mais rápido é o Whisper em laço
        if t["manter"] or t["tipo"] != "reformulada" or lido.get(t.get("frase"), 0) >= 0.5 * min(len(p), 8) or gaguejo:
            continue
        lido[t["frase"]] = len(p)
        t.update(manter=True, por="regra", garantida=True, motivo=t["motivo"] + " → única leitura da frase: fica")
    for k, t in enumerate(trechos[:-1]):
        seguinte = trechos[k + 1]
        if t["manter"] and t["tipo"] == "reformulada" and not re.search(r"[.?!:…]$", t["texto"].strip()) \
                and not seguinte["manter"] and seguinte["tipo"] in ("improviso", "continuacao"):
            seguinte.update(manter=True, por="regra", garantida=True,
                            motivo=seguinte["motivo"] + " → completa a frase anterior: fica")


def _outra_tomada(t, palavras):
    """Retake só existe com outra leitura: a mesma fala de `t` por perto na narração editada ("Um estudo com dados de"
    numa frase e, minutos depois, "um estudo do México, com dados de" são falas diferentes)."""
    alvo = {x for x in (norm(w) for w in t["texto"].split()) if x}
    fora = [norm(p["p"]) for p in palavras if abs(p["ini"] - t["ini"]) < 90 and (p["fim"] <= t["ini"] or p["ini"] >= t["fim"])]
    n = len(alvo) + 2
    return any(len(alvo & set(fora[i:i + n])) >= 0.7 * len(alvo) for i in range(max(len(fora) - n + 1, 1)))


def revisar_com_llm(trechos, frases):
    """O LLM local confirma ou inverte as decisões incertas. Sem LLM, fica a regra."""
    from pydantic import BaseModel, Field

    from esteira.ia import local
    from esteira.nucleo import eventos

    class Decisao(BaseModel):
        manter: bool
        motivo: str = Field(max_length=120)
        confianca: float = Field(ge=0, le=1)

    class Par(BaseModel):
        fica: str = Field(pattern="^(A|B|ambos)$")
        motivo: str = Field(max_length=120)
        confianca: float = Field(ge=0, le=1)

    por_i = {t["i"]: t for t in trechos}
    for t in [t for t in trechos if t.get("par") is not None and t["manter"]]:
        a = por_i.get(t["par"])
        if not a:
            continue
        k = trechos.index(t)
        depois = next((x["texto"] for x in trechos[k + 1:] if x["manter"]), "")
        r = local.perguntar(local.prompt("corte_par", a=a["texto"], b=t["texto"],
                                         depois=" ".join(depois.split()[:20])), Par)
        if r:
            # a tomada do roteiro (A) nunca sai por esta comparação: o par é escolhido por palavras em comum e às
            # vezes junta falas sem relação ("Ter parcela a pagar…" × "Que você ganha ali líquido…")
            a.update(por="llm", motivo=a["motivo"] + f" → LLM (par): {r.motivo}")
            t.update(manter=r.fica in ("B", "ambos"), por="llm", confianca=round(r.confianca, 2),
                     motivo=t["motivo"] + f" → LLM (par): fica {r.fica}, {r.motivo}")
            t.pop("par")
    _comecos_abandonados(trechos)
    duvidas = [t for t in trechos if t["tipo"] in ("improviso", "continuacao", "reformulada", "retake")
               and t["confianca"] < DUVIDA and t.get("por") != "llm"]
    for n, t in enumerate(duvidas, 1):
        eventos.progresso(n, len(duvidas), t["texto"][:40])
        k = trechos.index(t)
        antes = next((x["texto"] for x in reversed(trechos[:k]) if x["manter"]), "")
        depois = next((x["texto"] for x in trechos[k + 1:] if x["manter"]), "")
        ka, kb = t.get("entre", [t.get("frase", 0)] * 2)
        regiao = [frases[i]["texto"] for i in range(max(ka, 0), min(kb + 1, len(frases)))][:4]
        d = local.perguntar(local.prompt("corte", antes=" ".join(antes.split()[-25:]),
                                         depois=" ".join(depois.split()[:25]), roteiro=json.dumps(regiao, ensure_ascii=False),
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
    _leitura_unica(trechos)
    return duvidas


def escalar_ao_claude(trechos, projeto):
    """Uma chamada em lote com o que o LLM local deixou incerto (confiança < 0.5 ou sem LLM)."""
    from pydantic import BaseModel

    from esteira.ia import claude

    duvidas = [t for t in trechos if not t.get("garantida")
               and (t.get("por") == "regra" and len(t["texto"].split()) >= 2
                    or t.get("por") == "llm" and t["confianca"] < 0.5)]
    if not duvidas:
        return 0

    class Item(BaseModel):
        id: int
        manter: bool
        motivo: str

    class Resposta(BaseModel):
        decisoes: list[Item]

    linhas = []
    for n, t in enumerate(duvidas):
        k = trechos.index(t)
        antes = next((x["texto"] for x in reversed(trechos[:k]) if x["manter"] and x is not t), "")
        depois = next((x["texto"] for x in trechos[k + 1:] if x["manter"]), "")
        linhas.append(f'{n}. ANTES: "…{" ".join(antes.split()[-18:])}" | TRECHO: "{t["texto"]}" | '
                      f'DEPOIS: "{" ".join(depois.split()[:18])}…" | provisório: {"fica" if t["manter"] else "sai"} '
                      f'({t["motivo"][-80:]})')
    dossie = ("Edição da narração de um vídeo: o narrador lê um roteiro e às vezes improvisa, erra ou repete. "
              "Para cada TRECHO (transcrição automática), decida se FICA (completa a frase, acréscimo útil, "
              "versão própria de uma frase) ou SAI (bastidor, começo abandonado, repetição, palavra solta). "
              "A fala final deve ser contínua e sem frases quebradas.\n\n" + "\n".join(linhas))
    r = claude.consultar(dossie, Resposta, projeto.cfg, projeto.ep, f"cortes: {len(duvidas)} trechos incertos")
    if not r:
        return 0
    for d in r.decisoes:
        if 0 <= d.id < len(duvidas):
            duvidas[d.id].update(manter=d.manter, por="claude", confianca=0.9,
                                 motivo=duvidas[d.id]["motivo"] + f" → Claude: {d.motivo}")
    return len(r.decisoes)


PAD_INI, PAD_FIM = 0.08, 0.22   # folga antes/depois de cada trecho (o Whisper marca o fim cedo)
MAX_PAUSA = 1.2                 # s: pausa maior dentro de um trecho mantido é encurtada
JUNTAR = 0.7                    # pausas naturais menores que isto entre trechos ficam como estão


def repeticoes(palavras, frases, janela=20, maximo=15):
    """Na narração já editada: a mesma sequência de 4+ palavras dita duas vezes em até `janela` s ("Segundo
    motivo, entender o crédito é difícil. Segundo motivo, entender o crédito…") sem que o roteiro a repita
    é um retake que passou. Sai a tentativa anterior (até `maximo` s), fica a última."""
    rot = [w for f in frases for w in (norm(x) for x in f["texto"].split()) if w]
    no_rot = {}
    for k in range(len(rot) - 2):
        no_rot[tuple(rot[k:k + 3])] = no_rot.get(tuple(rot[k:k + 3]), 0) + 1
    w = [norm(p["p"]) for p in palavras]
    saida, k = [], 0
    while k < len(w) - 2:
        g = tuple(w[k:k + 3])
        achou = None
        if all(g) and sum(map(len, g)) >= 9 and no_rot.get(g, 0) < 2:
            for j in range(k + 3, len(w) - 2):
                if palavras[j]["ini"] - palavras[k]["ini"] > min(janela, maximo):
                    break
                if tuple(w[j:j + 3]) == g and j + 3 < len(w) and w[j + 3] == w[k + 3] and w[k + 3]:
                    achou = j  # 4+ palavras seguidas iguais ("com o dinheiro" duas vezes numa frase não conta)
                    break
        if achou is None:
            k += 1
            continue
        while k > 0 and w[k - 1] and w[k - 1] == w[achou - 1] and achou - 1 > k:  # "Ou" de "Ou seja…"
            k, achou = k - 1, achou - 1
        saida.append({"ini": palavras[k]["ini"], "fim": min(palavras[achou - 1]["fim"], palavras[achou]["ini"] - 0.2),
                      "i": k, "j": achou, "tipo": "retake", "confianca": 0.9,
                      "texto": " ".join(p["p"] for p in palavras[k:achou])})
        k = achou
    return saida


def _subtrair(intervalos, excluir):
    for x0, x1 in excluir:
        novo = []
        for a, b in intervalos:
            if x1 <= a or x0 >= b:
                novo.append([a, b])
            else:
                if x0 - a > 0.05:
                    novo.append([a, x0])
                if b - x1 > 0.05:
                    novo.append([x1, b])
        intervalos = novo
    return intervalos


def _para_bruto(t, intervalos):
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
SILENCIO_MIN = 0.12                       # s abaixo do limiar para contar como pausa (fecho de "p/t/k" é mais curto)
ESTENDE_FIM, ESTENDE_INI = 0.5, 0.3       # quanto a borda pode passar do tempo do Whisper procurando o silêncio
PAUSAS = {"frase": 0.45, "virgula": 0.28, "meio": 0.14}   # pausa total que fica numa junção


def envelope(arq):
    """Energia (dB) a cada 10 ms da gravação e o limiar de silêncio de cada quadro: 28 dB abaixo do nível típico
    da fala medido numa janela de ~10 s (o volume muda ao longo de 15–45 min; um limiar do arquivo inteiro fazia
    o fim fraco das palavras dos trechos baixos virar "silêncio"). O silêncio digital do noise gate fica fora."""
    import numpy as np

    from esteira import bordas
    from esteira.transcrever import _decodificar
    x = _decodificar(arq)
    n = len(x) // 160
    db = 10 * np.log10((x[:n * 160].reshape(n, 160) ** 2).mean(axis=1) + 1e-10)
    validos = db > -95
    lim = bordas.piso(db, 60, validos=validos) - 28 if validos.any() else np.full(n, -50.0)
    return {"db": db, "lim": lim}


def _lim(env):
    import numpy as np
    return np.broadcast_to(env["lim"], env["db"].shape)


def _pausa(palavra):
    p = palavra.rstrip()[-1:]
    return PAUSAS["frase"] if p in ".?!…" else PAUSAS["virgula"] if p in ",;:" else PAUSAS["meio"]


def _silencio(env, t, limite):
    """Primeira pausa (≥ SILENCIO_MIN) andando de t até limite (para trás se limite < t) → (ini, fim) ou None."""
    db, lim, n = env["db"], _lim(env), len(env["db"])
    passo = 1 if limite >= t else -1
    k, fim_k, corrida = int(t / Q), int(limite / Q), 0
    precisa = int(SILENCIO_MIN / Q)
    while 0 <= k < n and (k <= fim_k if passo > 0 else k >= fim_k):
        corrida = corrida + 1 if db[k] < lim[k] else 0
        if corrida >= precisa:
            a = k - passo * (corrida - 1)          # onde a pausa começou (no sentido da busca)
            b = k
            while 0 <= b + passo < n and db[b + passo] < lim[b + passo]:  # vai até o fim da pausa
                b += passo
            ini, fim = sorted((a, b))
            return ini * Q, (fim + 1) * Q
        k += passo
    return None


def _vale(env, a, b):
    """Instante de menor energia entre a e b (sem pausa à vista: o ponto menos audível para cortar)."""
    db = env["db"]
    i, f = max(int(a / Q), 0), min(int(b / Q) + 1, len(db))
    return (i + int(db[i:f].argmin())) * Q if f > i else a


def _borda_fim(env, fim_w, prox_ini, folga):
    limite = min(fim_w + ESTENDE_FIM, max(prox_ini, fim_w + 0.05))
    s = _silencio(env, fim_w, limite)
    return s[0] + min(folga, s[1] - s[0]) if s else _vale(env, fim_w, limite)


def _borda_ini(env, ini_w, ant_fim, folga):
    limite = max(ini_w - ESTENDE_INI, min(ant_fim, ini_w - 0.05))
    s = _silencio(env, ini_w, limite)  # começar dentro da palavra lia um "s" inicial fraco como pausa
    return s[1] - min(folga, s[1] - s[0]) if s else _vale(env, limite, ini_w)


def _intervalos(trechos, palavras, excluir=(), env=None):
    """Trechos mantidos → intervalos de áudio (s) na gravação, sem pausas longas. Com `env` (envelope da
    gravação), cada borda cai no silêncio real; sem ele, folga fixa em volta do tempo do Whisper."""
    blocos = []  # [primeira, última] palavra de cada pedaço contínuo mantido
    for t in sorted((t for t in trechos if t["manter"]), key=lambda t: t["i"]):
        for k in range(t["i"], t["j"]):
            # só emenda palavras vizinhas: uma palavra cortada no meio nunca entra por estar perto
            if (blocos and k == blocos[-1][1] + 1
                    and palavras[k]["ini"] - palavras[k - 1]["fim"] <= (JUNTAR if k == t["i"] else MAX_PAUSA)):
                blocos[-1][1] = k
            else:
                blocos.append([k, k])
    saida = []
    for n, (ki, kf) in enumerate(blocos):
        if env is None:
            saida.append([max(palavras[ki]["ini"] - PAD_INI, 0.0), palavras[kf]["fim"] + PAD_FIM])
            continue
        prox = palavras[kf + 1]["ini"] if kf + 1 < len(palavras) else palavras[kf]["fim"] + 2
        ant = palavras[ki - 1]["fim"] if ki else 0.0
        pausa_ant = _pausa(palavras[blocos[n - 1][1]]["p"]) if n else PAUSAS["frase"]
        a = _borda_ini(env, palavras[ki]["ini"], ant, pausa_ant * 0.4)
        b = _borda_fim(env, palavras[kf]["fim"], prox, _pausa(palavras[kf]["p"]) * 0.6)
        saida.append([max(a, 0.0), max(b, a + 0.05)])
    for x, y in zip(saida, saida[1:]):
        x[1] = min(x[1], y[0])
    if env is None:
        return _subtrair(saida, excluir)
    # exclusões (retakes achados na narração editada) também cortam no ponto menos audível
    excluir = [[_vale(env, x0 - 0.25, x0 + 0.1), _vale(env, x1 - 0.1, x1 + 0.25)] for x0, x1 in excluir]
    saida = _subtrair(saida, excluir)
    # regra de ouro (esteira/bordas.py): nenhuma borda dentro do núcleo de uma palavra mantida
    from esteira import bordas
    som = env["db"] >= _lim(env)
    fica = [(palavras[k]["ini"], palavras[k]["fim"]) for ki, kf in blocos for k in range(ki, kf + 1)]
    fica = [(a, b) for a, b in fica
            if sum(max(0.0, min(b, y) - max(a, x)) for x, y in excluir) < 0.5 * max(b - a, 1e-3)]
    todas = [(w["ini"], w["fim"]) for w in palavras]
    return bordas.validar(saida, bordas.nucleos(fica, som, todas), len(env["db"]) * Q)


def _alinhadas(projeto, bruta, palavras):
    """Palavras da bruta com ini/fim do alinhamento forçado (`esteira/alinhamento.py`); sem ele, as do Whisper."""
    from esteira import alinhamento
    lista = [[w["ini"], w["fim"], w["p"]] for w in palavras]
    al = alinhamento.refinar(bruta, lista, projeto.caminho("bordas_palavras.json"), projeto.cfg)
    return [{**w, "ini": a, "fim": b} for w, (a, b, _) in zip(palavras, al, strict=True)]


def renderizar_audio(entrada, intervalos, destino, pasta_tmp):
    filtros = [f"[0:a]atrim={a:.3f}:{b:.3f},asetpts=PTS-STARTPTS,"
               f"afade=t=in:d=0.01,afade=t=out:st={b - a - 0.015:.3f}:d=0.015[s{n}]"
               for n, (a, b) in enumerate(intervalos)]
    filtros.append("".join(f"[s{n}]" for n in range(len(intervalos))) + f"concat=n={len(intervalos)}:v=0:a=1")
    script = pasta_tmp / "cortes.filtro"
    script.write_text(";\n".join(filtros))
    import subprocess
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", entrada, "-filter_complex_script",
                    script, "-ac", "1", "-c:a", "pcm_s16le", destino], check=True)
    script.unlink()


def relatorio(trechos, faltando, destino, dur_bruta, dur_final, avisos=()):
    marca = {"tomada": "  ", "reformulada": "R ", "continuacao": "C ", "improviso": "I ", "retake": "↺ ",
             "bastidor": "B ", "fora": "F ", "descartado": "X ", "marcador": "M "}
    with open(destino, "w") as f:
        f.write(f"bruta {dur_bruta:.0f}s → editada {dur_final:.0f}s\n"
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
            f.write(f"{t['ini']:7.1f}s {'+' if t['manter'] else '-'} {marca.get(t['tipo'], '? ')}[{por}] "
                    f"{t['texto'][:110]}\n          {t['motivo'][:150]}\n")


def _gravacao_nova(projeto):
    """Narração nova posta na pasta (narracao.*) depois de um limpar: não é a editada que a esteira gerou.
    A gravação bruta anterior e as decisões dela vão para gravacoes_anteriores/<data>/."""
    from datetime import datetime

    from esteira.projeto import AUDIO_EXT
    from esteira.nucleo import eventos
    reg = projeto.caminho("narracao.render.json")
    tj = projeto.caminho("transcricao.json")
    nova = None
    for p in sorted(projeto.pasta.glob("narracao.*")):
        if p.suffix.lower() not in AUDIO_EXT:
            continue
        st = p.stat()
        if reg.exists():
            gerada = p.suffix == ".wav" and json.loads(reg.read_text()) == [st.st_size, st.st_mtime_ns]
        else:  # episódio antigo: a editada é sempre seguida da transcrição dela
            gerada = p.suffix == ".wav" and tj.exists() and st.st_mtime <= tj.stat().st_mtime + 2
        if not gerada:
            nova = p
    if not nova:
        return False
    destino = projeto.caminho("gravacoes_anteriores") / datetime.now().strftime("%Y%m%d-%H%M")
    destino.mkdir(parents=True, exist_ok=True)
    for nome in [b.name for b in projeto.pasta.glob("narracao_bruta.*")] + [
            "transcricao_bruta.json", "cortes.json", "cortes.txt", "narracao.render.json"]:
        if projeto.caminho(nome).exists():
            projeto.caminho(nome).rename(destino / nome)
    if nova.suffix != ".wav" and projeto.caminho("narracao.wav").exists():
        projeto.caminho("narracao.wav").unlink()  # editada da gravação anterior (Projeto.audio a pegaria antes)
    eventos.aviso(f"gravação nova ({nova.name}): a anterior e os cortes dela foram para {destino.relative_to(projeto.pasta)}")
    print(f"  gravação nova: anterior guardada em {destino.relative_to(projeto.pasta)}")
    return True


def aplicar(projeto, refazer=False):
    """Etapa limpar: gravação bruta → narracao.wav + cortes.json/cortes.txt + transcricao.json."""
    from esteira.nucleo import eventos
    from esteira.transcrever import transcrever

    from esteira.fontes import gravacoes
    from esteira.fontes.importar import atualizar_roteiro
    if atualizar_roteiro(projeto):  # o narrador lê o roteiro do vault: tem de ser o mesmo texto
        print("  roteiro atualizado do vault")
        eventos.aviso("roteiro mudou no vault desde a importação: reimportado")
        refazer = True
    puxado = gravacoes.atualizar(projeto)  # WAV mais novo do episódio em ~/Music/Youtube/<Canal>/
    if puxado:
        print(f"  gravação nova encontrada: {puxado}")
        eventos.aviso(f"gravação nova puxada de {puxado}")
    bruta = next(iter(sorted(projeto.pasta.glob("narracao_bruta.*"))), None)
    if bruta and _gravacao_nova(projeto):
        bruta = None  # a anterior foi para gravacoes_anteriores/; cortes decididos do zero
        refazer = True
    if not bruta:
        atual = projeto.audio()
        bruta = atual.with_name(f"narracao_bruta{atual.suffix}")
        atual.rename(bruta)
    if not projeto.roteiro():
        raise SystemExit("limpar precisa do roteiro.txt")
    tb = projeto.caminho("transcricao_bruta.json")
    # transcrição anterior à retranscrição das palavras esticadas (retakes escondidos): refaz com --refazer
    if not tb.exists() or (refazer and not projeto.carregar_json("transcricao_bruta.json").get("refinada")):
        transcrever(projeto, projeto.cfg, audio=bruta, saida_json="transcricao_bruta.json")
    transc = projeto.carregar_json("transcricao_bruta.json")
    from esteira import claquete
    frases = frases_do_roteiro(projeto.roteiro().read_text())
    partes = claquete.do_projeto(projeto)
    palavras = transc["palavras"]
    avisos = []

    arq = projeto.caminho("cortes.json")
    if arq.exists() and not refazer:  # decisões já tomadas (e talvez ajustadas na tela) são reaproveitadas
        dados = json.loads(arq.read_text())
        trechos, faltando, avisos = dados["trechos"], dados["faltando"], dados.get("avisos", [])
        print(f"  usando cortes.json existente ({len(trechos)} trechos); --refazer para decidir de novo")
    else:
        r = claquete.decidir(partes, palavras)
        if r:  # gravação com "corte/cancela parte N": a escolha das tomadas é do narrador
            trechos, faltando, avisos = r
            n = sum(1 for t in trechos if t["tipo"] == "marcador")
            print(f"  claquete: {n} marcadores, {len(partes)} partes no roteiro")
            for a in avisos:
                eventos.aviso(a)
        else:
            trechos, faltando = decidir(frases, palavras)
        duvidas = revisar_com_llm(trechos, frases)
        print(f"  {len(trechos)} trechos; {len(duvidas)} dúvidas revisadas pelo LLM local")
        _duplicados(trechos, _tokens(palavras))
        n = escalar_ao_claude(trechos, projeto)
        if n:
            print(f"  {n} trechos decididos pelo Claude")
        arq.write_text(json.dumps({"trechos": trechos, "faltando": faltando, "avisos": avisos},
                                  ensure_ascii=False, indent=1))
        dados = {}

    excluir = dados.get("excluir", []) if arq.exists() and not refazer else []
    destino = projeto.caminho("narracao.wav")
    env = envelope(bruta)  # energia da gravação: as bordas dos cortes caem no silêncio
    palavras = _alinhadas(projeto, bruta, palavras)  # tempos certos só para as bordas (decisões já tomadas)
    # Passadas: renderiza, transcreve a narração editada e procura retakes que o Whisper escondeu na
    # gravação bruta (palavras "esticadas" sobre um retake). Cada um achado volta para o tempo da bruta
    # como exclusão em cortes.json e o áudio é refeito.
    for passada in range(1, 5):
        intervalos = _intervalos(trechos, palavras, excluir, env)
        renderizar_audio(bruta, intervalos, destino, projeto.pasta)
        st = destino.stat()
        projeto.caminho("narracao.render.json").write_text(json.dumps([st.st_size, st.st_mtime_ns]))
        novo = transcrever(projeto, projeto.cfg)  # transcricao.json passa a ser da narração editada
        t2, falta_editada = decidir(frases, novo["palavras"])
        ocultos = [t for t in t2 if t["tipo"] == "retake" and t["confianca"] >= 0.8 and t["j"] - t["i"] >= 3]
        ocultos += [r for r in repeticoes(novo["palavras"], frases)
                    if not any(o["ini"] < r["fim"] and r["ini"] < o["fim"] for o in ocultos)]
        falsos = [t for t in ocultos if not _outra_tomada(t, novo["palavras"])]
        for t in falsos:
            eventos.debug("retake sem outra tomada: fica", editado=t["ini"], texto=t["texto"][:80])
        ocultos = [t for t in ocultos if t not in falsos]
        if not ocultos or passada == 4:
            for t in ocultos:
                eventos.aviso(f"possível retake na narração editada em {t['ini']:.1f}s: {t['texto'][:70]}")
            break
        for t in ocultos:
            excluir.append([round(_para_bruto(t["ini"] - 0.05, intervalos), 3),
                            round(_para_bruto(t["fim"] + 0.15, intervalos), 3)])
            eventos.debug("retake oculto", editado=t["ini"], bruto=excluir[-1], texto=t["texto"][:80])
        print(f"  passada {passada}: {len(ocultos)} retakes ocultos achados; refazendo o áudio")
        arq.write_text(json.dumps({"trechos": trechos, "faltando": faltando, "excluir": excluir},
                                  ensure_ascii=False, indent=1))
    # Intervalos mantidos (tempo da gravação bruta): no modo apresentador a câmera é cortada igual ao áudio.
    atual = json.loads(arq.read_text()) if arq.exists() else {}  # mantém marcas do painel (editado_no_painel)
    atual.update(trechos=trechos, faltando=faltando, excluir=excluir, avisos=avisos,
                 intervalos=[[round(a, 4), round(b, 4)] for a, b in intervalos])
    arq.write_text(json.dumps(atual, ensure_ascii=False, indent=1))
    relatorio(trechos, faltando, projeto.caminho("cortes.txt"), transc["duracao"], novo["duracao"], avisos)
    # conferência: frases do roteiro que não estão inteiras na narração editada (palavra ou número cortado)
    quebradas = [t for t in t2 if t["tipo"] in ("tomada", "reformulada") and t["confianca"] < 0.75]
    with open(projeto.caminho("cortes.txt"), "a") as f:
        f.write("\nCONFERÊNCIA DA NARRAÇÃO EDITADA (tempo no vídeo)\n")
        for x in falta_editada:
            f.write(f"  falta: {x}\n")
        for t in quebradas:
            f.write(f"  {t['ini']:7.1f}s incompleta ({t['confianca']:.2f}): {t['texto'][:100]}\n")
        if not falta_editada and not quebradas:
            f.write("  todas as frases do roteiro estão inteiras\n")
    from esteira import bordas
    fica = [(palavras[k]["ini"], palavras[k]["fim"], palavras[k]["p"]) for t in trechos if t["manter"]
            for k in range(t["i"], t["j"])]
    fica = [w for w in fica if sum(max(0.0, min(w[1], y) - max(w[0], x)) for x, y in excluir) < 0.5 * (w[1] - w[0])]
    cortadas = bordas.perdas([w[:2] for w in fica], intervalos, [w[2] for w in fica])
    with open(projeto.caminho("cortes.txt"), "a") as f:
        for c in cortadas:
            f.write(f"  {c['t']:7.1f}s (bruta) palavra cortada ({c['perdeu']:.0%} fora): {c['texto']}\n")
    if cortadas:
        eventos.aviso(f"{len(cortadas)} palavra(s) mantida(s) cortada(s) nas bordas (ver o fim de cortes.txt)")
    if falta_editada or quebradas:
        eventos.aviso(f"narração editada: {len(falta_editada)} frases faltando e {len(quebradas)} incompletas "
                      f"(ver o fim de cortes.txt)")
    cortados = sum(1 for t in trechos if not t["manter"])
    print(f"  bruta {transc['duracao']:.0f}s → editada {novo['duracao']:.0f}s ({cortados} trechos e "
          f"{len(excluir)} retakes ocultos cortados); {len(faltando)} frases sem tomada → cortes.txt")
