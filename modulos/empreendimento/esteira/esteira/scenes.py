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

MOTIONS = ["zoom_in", "pan_dir", "zoom_out", "pan_esq"]
RE_DIRECTIVE = re.compile(r"\[(busca|video|vídeo|imagem)\s*:\s*([^\]]+)\]", re.I)


def normalize(word):
    s = unicodedata.normalize("NFKD", word.lower())
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]", "", s)


def read_script(text):
    """Devolve (titulo, frases); cada frase: {texto, destaques, busca, tipo}."""
    title, sentences, pending = None, [], None
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            title = title or line.lstrip("#").strip()
            continue
        for m in RE_DIRECTIVE.finditer(line):
            kind = {"busca": None, "imagem": "imagem"}.get(m.group(1).lower(), "video")
            pending = {"busca": m.group(2).strip(), "tipo": kind}
        line = RE_DIRECTIVE.sub("", line).strip()
        if not line:
            continue
        for sentence in re.split(r"(?<=[.!?…])\s+", line):
            if not sentence.strip():
                continue
            item = {"texto": sentence.replace("*", "").strip(), "destaques": re.findall(r"\*([^*]+)\*", sentence),
                    "busca": None, "tipo": None}
            if pending:
                item.update(pending)
                pending = None
            sentences.append(item)
    return title, sentences


def sentences_of_transcript(transc):
    sentences, current = [], []
    for w in transc["palavras"]:
        current.append(w["p"])
        if re.search(r"[.!?…]$", w["p"]):
            sentences.append(" ".join(current))
            current = []
    if current:
        sentences.append(" ".join(current))
    return [{"texto": f, "destaques": [], "busca": None, "tipo": None} for f in sentences]


def align(sentences, transc):
    """Dá a cada palavra do roteiro um tempo (ini) usando a transcrição; devolve lista por frase."""
    words_w = transc["palavras"]
    norm_w = [normalize(w["p"]) for w in words_w]
    # número partido pelo Whisper ("12", ",5", "%") vira uma palavra só, como no roteiro ("12,5%" → "125")
    for k in range(1, len(norm_w)):
        if re.match(r"^[.,]\d", words_w[k]["p"].strip()) and norm_w[k - 1][-1:].isdigit():
            norm_w[k - 1], norm_w[k] = norm_w[k - 1] + norm_w[k], ""
    tokens = []  # (indice_frase, texto_original)
    for i, f in enumerate(sentences):
        for p in f["texto"].split():
            if normalize(p):
                tokens.append((i, p))
    norm_r = [normalize(p) for _, p in tokens]

    times = [None] * len(tokens)
    fins = [None] * len(tokens)
    for block in SequenceMatcher(None, norm_r, norm_w, autojunk=False).get_matching_blocks():
        for k in range(block.size):
            w = words_w[block.b + k]
            times[block.a + k] = w["ini"]
            fins[block.a + k] = w["fim"]

    # Palavras do roteiro sem par na transcrição: interpola entre os vizinhos alinhados.
    duration = transc["duracao"]
    known = [k for k, t in enumerate(times) if t is not None]
    if not known:
        raise SystemExit("o roteiro não bate com a narração (nenhuma palavra alinhada)")
    for k in range(len(tokens)):
        if times[k] is not None:
            continue
        ant = max((j for j in known if j < k), default=None)
        prox = min((j for j in known if j > k), default=None)
        t0, k0 = (fins[ant], ant) if ant is not None else (0.0, -1)
        t1, k1 = (times[prox], prox) if prox is not None else (duration, len(tokens))
        times[k] = t0 + (t1 - t0) * (k - k0) / (k1 - k0)
        fins[k] = times[k]

    by_sentence = [[] for _ in sentences]
    for (i, p), t, f in zip(tokens, times, fins):
        by_sentence[i].append({"p": p, "ini": t, "fim": f})
    return by_sentence


def _start_highlight(words, highlight):
    """Momento em que a primeira palavra do destaque é falada, ou None se não está nestas palavras."""
    target = normalize(highlight.split()[0])
    return next((p["ini"] for p in words if normalize(p["p"]) == target), None)


def _divide_long(blocks, target, maximum):
    output = []
    for b in blocks:
        queue = [b]
        while queue:
            current = queue.pop(0)
            ps = current["palavras"]
            duration = current["fim"] - current["ini"]
            if duration <= maximum or len(ps) < 4:
                output.append(current)
                continue
            # Corte perto do alvo, preferindo logo após uma vírgula.
            best, note = None, None
            for k in range(2, len(ps) - 1):
                t = ps[k]["ini"]
                dist = abs((t - current["ini"]) - target)
                if ps[k - 1]["p"].endswith((",", ";", ":")):
                    dist -= 1.5
                if note is None or dist < note:
                    best, note = k, dist
            t = ps[best]["ini"]
            a = dict(current, palavras=ps[:best], fim=t)
            b2 = dict(current, palavras=ps[best:], ini=t, busca=None, tipo=None)
            # Cada destaque fica no pedaço que contém a palavra destacada.
            a["destaques"] = [d for d in current["destaques"] if _start_highlight(a["palavras"], d) is not None]
            b2["destaques"] = [d for d in current["destaques"] if d not in a["destaques"]]
            queue[:0] = [a, b2]
    return output


def _join_short(blocks, minimum):
    output = []
    for b in blocks:
        if output and (output[-1]["fim"] - output[-1]["ini"]) < minimum:
            ant = output[-1]
            ant["palavras"] += b["palavras"]
            ant["fim"] = b["fim"]
            ant["busca"] = ant["busca"] or b["busca"]
            ant["tipo"] = ant["tipo"] or b["tipo"]
            ant["destaques"] = ant["destaques"] + b["destaques"]
        else:
            output.append(b)
    if len(output) > 1 and output[-1]["fim"] - output[-1]["ini"] < minimum:
        ult = output.pop()
        output[-1]["palavras"] += ult["palavras"]
        output[-1]["fim"] = ult["fim"]
        output[-1]["destaques"] = output[-1]["destaques"] + ult["destaques"]
    return output


def words_key(text, freq, n=2):
    """Heurística local: palavras longas, nomes próprios e termos raros no roteiro."""
    candidates = []
    for pos, raw in enumerate(text.split()):
        p = re.sub(r"[^\wÀ-ÿ-]", "", raw)
        if len(p) < 4 or p.lower() in STOPWORDS or p.isdigit():
            continue
        note = len(p) + (4 if pos > 0 and p[0].isupper() else 0) + 3.0 / freq.get(p.lower(), 1)
        candidates.append((note, pos, p.lower()))
    chosen = sorted(sorted(candidates, reverse=True)[:n], key=lambda c: c[1])
    seen = []
    for _, _, p in chosen:
        if p not in seen:
            seen.append(p)
    return " ".join(seen)


def generate_scenes(project):
    cfg = project.cfg["cenas"]
    transc = project.load_json("transcricao.json")
    file = project.script_path()
    if file:
        title, sentences = read_script(file.read_text())
    else:
        print("  sem roteiro.txt: usando as frases da própria transcrição")
        title, sentences = None, sentences_of_transcript(transc)

    by_sentence = align(sentences, transc)
    # Tempo de cada frase do roteiro na narração editada: os gráficos entram no instante em que ela é falada.
    project.save_json("frases.json", [
        {"texto": f["texto"], "destaques": f["destaques"], "ini": ps[0]["ini"] if ps else None,
         "fim": ps[-1]["fim"] if ps else None} for f, ps in zip(sentences, by_sentence)])
    # Texto do roteiro com o tempo de cada palavra: as legendas usam isto (o Whisper erra palavras).
    project.save_json("alinhamento.json", [
        {"p": p["p"].replace("*", ""), "ini": round(p["ini"], 3), "fim": round(max(p["fim"], p["ini"] + 0.15), 3)}
        for ps in by_sentence for p in ps])
    blocks = []
    for f, ps in zip(sentences, by_sentence):
        if ps:
            blocks.append(dict(f, palavras=ps, ini=ps[0]["ini"], fim=None))
    for a, b in zip(blocks, blocks[1:]):
        a["fim"] = b["ini"]
    blocks[-1]["fim"] = transc["duracao"]
    blocks[0]["ini"] = 0.0

    blocks = _divide_long(blocks, cfg["alvo_segundos"], cfg["max_segundos"])
    blocks = _join_short(blocks, cfg["min_segundos"])

    todo = " ".join(f["texto"] for f in sentences).lower()
    freq = {}
    for p in re.findall(r"[\wÀ-ÿ]+", todo):
        freq[p] = freq.get(p, 0) + 1

    step_video = round(5 * cfg["proporcao_video"])
    scenes = []
    for i, b in enumerate(blocks):
        text = " ".join(p["p"] for p in b["palavras"]).replace("*", "")
        scenes.append({
            "id": i + 1,
            "inicio": round(b["ini"], 3),
            "fim": round(b["fim"], 3),
            "texto": text,
            "busca": b["busca"] or words_key(text, freq),
            "tipo": b["tipo"] or ("video" if (i % 5) < step_video else "imagem"),
            "destaques": [{"texto": d, "inicio": round(_start_highlight(b["palavras"], d) or b["ini"], 3)}
                          for d in b["destaques"]],
            "movimento": MOTIONS[i % len(MOTIONS)],
            "busca_definida": bool(b["busca"]),
            "midia": None,
        })

    # Rodar de novo (ex.: após mudar o roteiro) preserva o trabalho feito nas cenas que não mudaram.
    if project.path_of("plano.json").exists():
        old = project.load_json("plano.json")
        project.save_json("plano.anterior.json", old)
        by_time = {(c["inicio"], c["fim"]): c for c in old["cenas"]}
        for c in scenes:
            velha = by_time.get((c["inicio"], c["fim"]))
            if velha and velha["texto"] == c["texto"]:
                for k in ("busca", "busca_en", "tipo", "movimento", "midia", "midia_id", "midia_tipo",
                          "credito", "rejeitados", "busca_definida"):
                    if k in velha:
                        c[k] = velha[k]

    plan = {"titulo": title, "audio": transc["audio"], "duracao": transc["duracao"], "cenas": scenes}
    project.save_json("plano.json", plan)
    print(f"  {len(scenes)} cenas → plano.json (ver com: ./dark summary {project.ep})")
    return plan
