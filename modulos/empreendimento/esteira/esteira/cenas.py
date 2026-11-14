"""Etapa 2: alinha o roteiro à transcrição e divide a narração em cenas com termos de busca.

Marcações aceitas no roteiro:
  # Título do vídeo            primeira linha com # vira o título
  [busca: termo]               termo de busca da próxima frase (aceita inglês)
  [video: termo] [imagem: termo]   idem, forçando o tipo de mídia
  *palavra*                    palavra em destaque: aparece animada na tela
"""

import re
import unicodedata
from difflib import SequenceMatcher

STOPWORDS = set("""
a à ao aos aquela aquelas aquele aqueles aquilo as às até com como contra da das de dela delas dele deles
depois do dos e é ela elas ele eles em entre era eram essa essas esse esses esta está estão estas estava
estavam este estes eu foi foram há isso isto já lhe lhes mais mas me mesmo meu meus minha minhas muito
na nas nem no nos nós nossa nossas nosso nossos num numa o os ou para pela pelas pelo pelos por qual quando
que quem se sem ser seu seus só sua suas também te tem têm tinha tinham um uma umas uns você vocês vos
ainda alguns algumas outro outros outra outras sobre sendo seria tudo todo toda todos todas cada onde
havia hoje sempre nunca então porque pois assim aqui ali lá agora apenas bem mal muita muitas muitos pode
podem poderia fazer feito fez coisa coisas ninguém algo alguém mesma dizem falam acreditam acredita
continua continuam continuavam estava ainda durante naquela naquele única único maior maiores
""".split())

MOVIMENTOS = ["zoom_in", "pan_dir", "zoom_out", "pan_esq"]
RE_DIRETIVA = re.compile(r"\[(busca|video|vídeo|imagem)\s*:\s*([^\]]+)\]", re.I)


def normalizar(palavra):
    s = unicodedata.normalize("NFKD", palavra.lower())
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]", "", s)


def ler_roteiro(texto):
    """Devolve (titulo, frases); cada frase: {texto, destaques, busca, tipo}."""
    titulo, frases, pendente = None, [], None
    for linha in texto.splitlines():
        linha = linha.strip()
        if not linha:
            continue
        if linha.startswith("#"):
            titulo = titulo or linha.lstrip("#").strip()
            continue
        for m in RE_DIRETIVA.finditer(linha):
            tipo = {"busca": None, "imagem": "imagem"}.get(m.group(1).lower(), "video")
            pendente = {"busca": m.group(2).strip(), "tipo": tipo}
        linha = RE_DIRETIVA.sub("", linha).strip()
        if not linha:
            continue
        for frase in re.split(r"(?<=[.!?…])\s+", linha):
            if not frase.strip():
                continue
            item = {"texto": frase.replace("*", "").strip(), "destaques": re.findall(r"\*([^*]+)\*", frase),
                    "busca": None, "tipo": None}
            if pendente:
                item.update(pendente)
                pendente = None
            frases.append(item)
    return titulo, frases


def frases_da_transcricao(transc):
    frases, atual = [], []
    for w in transc["palavras"]:
        atual.append(w["p"])
        if re.search(r"[.!?…]$", w["p"]):
            frases.append(" ".join(atual))
            atual = []
    if atual:
        frases.append(" ".join(atual))
    return [{"texto": f, "destaques": [], "busca": None, "tipo": None} for f in frases]


def alinhar(frases, transc):
    """Dá a cada palavra do roteiro um tempo (ini) usando a transcrição; devolve lista por frase."""
    palavras_w = transc["palavras"]
    norm_w = [normalizar(w["p"]) for w in palavras_w]
    # número partido pelo Whisper ("12", ",5", "%") vira uma palavra só, como no roteiro ("12,5%" → "125")
    for k in range(1, len(norm_w)):
        if re.match(r"^[.,]\d", palavras_w[k]["p"].strip()) and norm_w[k - 1][-1:].isdigit():
            norm_w[k - 1], norm_w[k] = norm_w[k - 1] + norm_w[k], ""
    tokens = []  # (indice_frase, texto_original)
    for i, f in enumerate(frases):
        for p in f["texto"].split():
            if normalizar(p):
                tokens.append((i, p))
    norm_r = [normalizar(p) for _, p in tokens]

    tempos = [None] * len(tokens)
    fins = [None] * len(tokens)
    for bloco in SequenceMatcher(None, norm_r, norm_w, autojunk=False).get_matching_blocks():
        for k in range(bloco.size):
            w = palavras_w[bloco.b + k]
            tempos[bloco.a + k] = w["ini"]
            fins[bloco.a + k] = w["fim"]

    # Palavras do roteiro sem par na transcrição: interpola entre os vizinhos alinhados.
    duracao = transc["duracao"]
    conhecidos = [k for k, t in enumerate(tempos) if t is not None]
    if not conhecidos:
        raise SystemExit("o roteiro não bate com a narração (nenhuma palavra alinhada)")
    for k in range(len(tokens)):
        if tempos[k] is not None:
            continue
        ant = max((j for j in conhecidos if j < k), default=None)
        prox = min((j for j in conhecidos if j > k), default=None)
        t0, k0 = (fins[ant], ant) if ant is not None else (0.0, -1)
        t1, k1 = (tempos[prox], prox) if prox is not None else (duracao, len(tokens))
        tempos[k] = t0 + (t1 - t0) * (k - k0) / (k1 - k0)
        fins[k] = tempos[k]

    por_frase = [[] for _ in frases]
    for (i, p), t, f in zip(tokens, tempos, fins):
        por_frase[i].append({"p": p, "ini": t, "fim": f})
    return por_frase


def _inicio_destaque(palavras, destaque):
    """Momento em que a primeira palavra do destaque é falada, ou None se não está nestas palavras."""
    alvo = normalizar(destaque.split()[0])
    return next((p["ini"] for p in palavras if normalizar(p["p"]) == alvo), None)


def _dividir_longas(blocos, alvo, maximo):
    saida = []
    for b in blocos:
        fila = [b]
        while fila:
            atual = fila.pop(0)
            ps = atual["palavras"]
            dur = atual["fim"] - atual["ini"]
            if dur <= maximo or len(ps) < 4:
                saida.append(atual)
                continue
            # Corte perto do alvo, preferindo logo após uma vírgula.
            melhor, nota = None, None
            for k in range(2, len(ps) - 1):
                t = ps[k]["ini"]
                dist = abs((t - atual["ini"]) - alvo)
                if ps[k - 1]["p"].endswith((",", ";", ":")):
                    dist -= 1.5
                if nota is None or dist < nota:
                    melhor, nota = k, dist
            t = ps[melhor]["ini"]
            a = dict(atual, palavras=ps[:melhor], fim=t)
            b2 = dict(atual, palavras=ps[melhor:], ini=t, busca=None, tipo=None)
            # Cada destaque fica no pedaço que contém a palavra destacada.
            a["destaques"] = [d for d in atual["destaques"] if _inicio_destaque(a["palavras"], d) is not None]
            b2["destaques"] = [d for d in atual["destaques"] if d not in a["destaques"]]
            fila[:0] = [a, b2]
    return saida


def _juntar_curtas(blocos, minimo):
    saida = []
    for b in blocos:
        if saida and (saida[-1]["fim"] - saida[-1]["ini"]) < minimo:
            ant = saida[-1]
            ant["palavras"] += b["palavras"]
            ant["fim"] = b["fim"]
            ant["busca"] = ant["busca"] or b["busca"]
            ant["tipo"] = ant["tipo"] or b["tipo"]
            ant["destaques"] = ant["destaques"] + b["destaques"]
        else:
            saida.append(b)
    if len(saida) > 1 and saida[-1]["fim"] - saida[-1]["ini"] < minimo:
        ult = saida.pop()
        saida[-1]["palavras"] += ult["palavras"]
        saida[-1]["fim"] = ult["fim"]
        saida[-1]["destaques"] = saida[-1]["destaques"] + ult["destaques"]
    return saida


def palavras_chave(texto, freq, n=2):
    """Heurística local: palavras longas, nomes próprios e termos raros no roteiro."""
    candidatos = []
    for pos, bruto in enumerate(texto.split()):
        p = re.sub(r"[^\wÀ-ÿ-]", "", bruto)
        if len(p) < 4 or p.lower() in STOPWORDS or p.isdigit():
            continue
        nota = len(p) + (4 if pos > 0 and p[0].isupper() else 0) + 3.0 / freq.get(p.lower(), 1)
        candidatos.append((nota, pos, p.lower()))
    escolhidos = sorted(sorted(candidatos, reverse=True)[:n], key=lambda c: c[1])
    vistos = []
    for _, _, p in escolhidos:
        if p not in vistos:
            vistos.append(p)
    return " ".join(vistos)


def gerar_cenas(projeto):
    cfg = projeto.cfg["cenas"]
    transc = projeto.carregar_json("transcricao.json")
    arq = projeto.roteiro()
    if arq:
        titulo, frases = ler_roteiro(arq.read_text())
    else:
        print("  sem roteiro.txt: usando as frases da própria transcrição")
        titulo, frases = None, frases_da_transcricao(transc)

    por_frase = alinhar(frases, transc)
    # Tempo de cada frase do roteiro na narração editada: os gráficos entram no instante em que ela é falada.
    projeto.salvar_json("frases.json", [
        {"texto": f["texto"], "destaques": f["destaques"], "ini": ps[0]["ini"] if ps else None,
         "fim": ps[-1]["fim"] if ps else None} for f, ps in zip(frases, por_frase)])
    # Texto do roteiro com o tempo de cada palavra: as legendas usam isto (o Whisper erra palavras).
    projeto.salvar_json("alinhamento.json", [
        {"p": p["p"].replace("*", ""), "ini": round(p["ini"], 3), "fim": round(max(p["fim"], p["ini"] + 0.15), 3)}
        for ps in por_frase for p in ps])
    blocos = []
    for f, ps in zip(frases, por_frase):
        if ps:
            blocos.append(dict(f, palavras=ps, ini=ps[0]["ini"], fim=None))
    for a, b in zip(blocos, blocos[1:]):
        a["fim"] = b["ini"]
    blocos[-1]["fim"] = transc["duracao"]
    blocos[0]["ini"] = 0.0

    blocos = _dividir_longas(blocos, cfg["alvo_segundos"], cfg["max_segundos"])
    blocos = _juntar_curtas(blocos, cfg["min_segundos"])

    todo = " ".join(f["texto"] for f in frases).lower()
    freq = {}
    for p in re.findall(r"[\wÀ-ÿ]+", todo):
        freq[p] = freq.get(p, 0) + 1

    passo_video = round(5 * cfg["proporcao_video"])
    cenas = []
    for i, b in enumerate(blocos):
        texto = " ".join(p["p"] for p in b["palavras"]).replace("*", "")
        cenas.append({
            "id": i + 1,
            "inicio": round(b["ini"], 3),
            "fim": round(b["fim"], 3),
            "texto": texto,
            "busca": b["busca"] or palavras_chave(texto, freq),
            "tipo": b["tipo"] or ("video" if (i % 5) < passo_video else "imagem"),
            "destaques": [{"texto": d, "inicio": round(_inicio_destaque(b["palavras"], d) or b["ini"], 3)}
                          for d in b["destaques"]],
            "movimento": MOVIMENTOS[i % len(MOVIMENTOS)],
            "busca_definida": bool(b["busca"]),
            "midia": None,
        })

    # Rodar de novo (ex.: após mudar o roteiro) preserva o trabalho feito nas cenas que não mudaram.
    if projeto.caminho("plano.json").exists():
        antigo = projeto.carregar_json("plano.json")
        projeto.salvar_json("plano.anterior.json", antigo)
        por_tempo = {(c["inicio"], c["fim"]): c for c in antigo["cenas"]}
        for c in cenas:
            velha = por_tempo.get((c["inicio"], c["fim"]))
            if velha and velha["texto"] == c["texto"]:
                for k in ("busca", "busca_en", "tipo", "movimento", "midia", "midia_id", "midia_tipo",
                          "credito", "rejeitados", "busca_definida"):
                    if k in velha:
                        c[k] = velha[k]

    plano = {"titulo": titulo, "audio": transc["audio"], "duracao": transc["duracao"], "cenas": cenas}
    projeto.salvar_json("plano.json", plano)
    print(f"  {len(cenas)} cenas → plano.json (ver com: ./dark resumo {projeto.ep})")
    return plano
