"""Claquete falada: o narrador marca cada parte do roteiro na gravação.

  "Corte parte 3"    → a tomada que acabou de ler da parte 3 está boa (vai do marcador anterior até aqui).
  "Cancela parte 3"  → a tomada que acabou de ler não serve.
  sem marcador       → não é usada (se uma parte ficar sem nenhum "corte", procura-se a leitura dela no que
                       não foi cancelado e fica um aviso).

Parte = parágrafo do roteiro (linha não vazia que não é título); `./dark parts <ep>` gera a lista numerada
para a leitura. "Corte parte N" dito mais de uma vez: vale o último. "Cancela parte N" logo depois de
"Corte parte N" (sem ler nada entre os dois) desfaz aquele corte.

Dentro da tomada confirmada as regras de `cortes.decidir` continuam (frase lida duas vezes, gaguejo,
bastidor); o que vem antes da primeira frase e depois da última sai. Sem marcadores na gravação, a esteira
usa o fluxo antigo.
"""
import re

from esteira import cuts as C

UNI = {"um": 1, "uma": 1, "dois": 2, "duas": 2, "tres": 3, "quatro": 4, "cinco": 5, "seis": 6, "sete": 7,
       "oito": 8, "nove": 9}
ESP = {"dez": 10, "onze": 11, "doze": 12, "treze": 13, "quatorze": 14, "catorze": 14, "quinze": 15,
       "dezesseis": 16, "dezasseis": 16, "dezessete": 17, "dezassete": 17, "dezoito": 18, "dezenove": 19,
       "dezanove": 19}
TEN = {"vinte": 20, "trinta": 30, "quarenta": 40, "cinquenta": 50, "sessenta": 60, "setenta": 70,
       "oitenta": 80, "noventa": 90}
_alt = lambda d: "|".join(sorted(d, key=len, reverse=True))
NUM = rf"(?:\d+|(?:{_alt(TEN)})(?: e (?:{_alt(UNI)}))?|{_alt(ESP)}|{_alt(UNI)}|cem)"
# variações que o Whisper escreve: "corta parte 1", "corte a parte um", "cancelo parte catorze", "porte 2"
RE_MARK = re.compile(rf"\b(cort\w*|cancel\w*) (?:(?:a|o|da|de|na) )?(?:parte|partes|arte|porte|parti|parto) ({NUM})\b")
HOTWORDS = "Corte parte. Cancela parte."  # vício do Whisper para os marcadores (só na gravação bruta)


def number(texto):
    p = texto.split()
    if p[0].isdigit():
        return int(p[0])
    if p[0] == "cem":
        return 100
    for d in (UNI, ESP):
        if p[0] in d:
            return d[p[0]]
    return TEN[p[0]] + (UNI[p[-1]] if len(p) == 3 else 0)


def parts_of_script(texto, chapters=None):
    """Partes com as frases de cada uma; `f0` = índice global da primeira frase (o mesmo de
    `cortes.frases_do_roteiro` no roteiro inteiro). Com `capitulos` (as "## Parte N" do roteiro no vault,
    `roteiro.json`), cada parte junta as falas do seu capítulo; sem eles, parte = parágrafo."""
    speeches, f0 = [], 0
    for line in texto.splitlines():
        sentences = C.sentences_of_script(line)
        if sentences:
            speeches.append({"texto": line.strip(), "frases": sentences, "f0": f0})
            f0 += len(sentences)
    if not chapters:
        return [dict(f, n=k + 1) for k, f in enumerate(speeches)]
    caps = sorted(chapters, key=lambda c: c["fala"])
    parts = []
    for c, prox in zip(caps, caps[1:] + [None]):
        group = speeches[c["fala"]:prox["fala"] if prox else len(speeches)]
        if group:
            parts.append({"n": int(c["parte"]), "nome": c.get("nome", ""), "f0": group[0]["f0"],
                           "texto": "\n".join(g["texto"] for g in group),
                           "frases": [x for g in group for x in g["frases"]]})
    return parts


def of_project(project):
    import json
    rot = project.caminho("roteiro.json")
    caps = json.loads(rot.read_text()).get("capitulos") if rot.exists() else None
    return parts_of_script(project.roteiro().read_text(), caps)


def text_to_read(parts):
    return "\n\n".join(f"PARTE {p['n']}" + (f" — {p['nome']}" if p.get("nome") else "") + f"\n{p['texto']}"
                       for p in parts) + (
        "\n\n— Ao terminar cada parte bem lida: pausa, \"Corte parte N\", pausa.\n"
        "— Se errou: \"Cancela parte N\" (ou só recomece; sem marcador a leitura não é usada).\n")


def markers(palavras):
    """[{tipo: corte|cancela, parte, i0, i1}] — i0..i1 = palavras do marcador na transcrição."""
    idx, toks = [], []
    for k, p in enumerate(palavras):
        for w in re.split(r"[-\s]+", p["p"]):  # "corte-parte" vira duas palavras
            n = C.norm(w)
            if n:
                idx.append(k)
                toks.append(n)
    text, start = "", []
    for t in toks:
        start.append(len(text))
        text += t + " "
    output = []
    for m in RE_MARK.finditer(text):
        a = next(k for k, s in enumerate(start) if s >= m.start())
        b = max(k for k, s in enumerate(start) if s < m.end())
        output.append({"tipo": "corte" if m.group(1).startswith("cort") else "cancela", "parte": number(m.group(2)),
                      "i0": idx[a], "i1": idx[b] + 1})
    return output


def _trim(trechos, motivo):
    """Só fica o que está entre a primeira e a última frase da parte: conversa antes de começar e sobra
    antes do marcador saem. Improviso no meio da tomada confirmada fica (o narrador aprovou a leitura)."""
    core = [k for k, t in enumerate(trechos) if t["manter"] and t["tipo"] in ("tomada", "reformulada")]
    if core and core[-1] + 1 < len(trechos):  # "Isso assusta muito." — colado no fim da última frase
        a, b = trechos[core[-1]], trechos[core[-1] + 1]
        if b["ini"] - a["fim"] <= 0.3 and b["j"] - b["i"] <= 3 and b["tipo"] in ("fora", "improviso"):
            b.update(manter=True, tipo="continuacao", confianca=0.8, motivo="colada no fim da leitura confirmada")
    for k, t in enumerate(trechos):
        if not core or k < core[0] or (k > core[-1] and t["tipo"] != "continuacao"):
            t.update(manter=False, tipo="fora", por="claquete", confianca=1.0, motivo=f"{motivo}: fora da leitura")
        elif t["tipo"] == "improviso" and not t["manter"] and t["j"] - t["i"] >= 3:
            t.update(manter=True, confianca=max(t["confianca"], 0.75), motivo=t["motivo"] + " · dentro da tomada confirmada")


def _in_part(part, palavras, a, b, motivo):
    """cortes.decidir só com as frases da parte, nas palavras a..b; índices de volta para a gravação toda."""
    spans, missing = C.decide(part["frases"], palavras[a:b])
    for t in spans:
        t["i"] += a
        t["j"] += a
        if "par" in t:
            t["par"] += a
        if "frase" in t:
            t["frase"] += part["f0"]
        if "entre" in t:
            t["entre"] = [x + part["f0"] for x in t["entre"]]
        t["parte"] = part["n"]
        t["motivo"] = f"parte {part['n']} · {t['motivo']}"
    _trim(spans, motivo)
    return spans, missing


def _coverage(part, palavras, a, b):
    choices, _, _ = C.choose(part["frases"], palavras[a:b])
    return sum(1 for e in choices if e) / len(part["frases"])


def _cross_check_number(s, valid, palavras):
    """Número dito ou ouvido errado ("corte parte 7" depois de ler a 6): se o texto lido cobre mal a parte
    dita e bem uma vizinha, vale a vizinha."""
    n = s["parte"]
    if s["b"] - s["a"] < 2:
        return n
    spoken = _coverage(valid[n], palavras, s["a"], s["b"])
    if spoken >= 0.6:
        return n
    viz = [(_coverage(valid[m], palavras, s["a"], s["b"]), m) for m in (n - 1, n + 1) if m in valid]
    best = max(viz, default=(0, n))
    return best[1] if best[0] >= spoken + 0.3 else n


def _discarded(palavras, a, b, motivo, tipo="descartado"):
    return {"ini": palavras[a]["ini"], "fim": palavras[b - 1]["fim"], "i": a, "j": b, "manter": False, "tipo": tipo,
            "motivo": motivo, "confianca": 1.0, "por": "claquete", "texto": " ".join(p["p"] for p in palavras[a:b])}


def decide(parts, palavras):
    """None se a gravação não tem marcadores (fluxo antigo). Senão (trechos, faltando, avisos)."""
    marks = markers(palavras)
    if not marks:
        return None
    warnings, segs, start = [], [], 0
    for m in marks:
        segs.append(dict(m, a=start, b=m["i0"]))
        start = m["i1"]
    tail = {"tipo": "sem marcador", "parte": None, "a": start, "b": len(palavras), "i0": len(palavras),
             "i1": len(palavras)}
    for k, s in enumerate(segs):
        read = sum(1 for p in palavras[s["a"]:s["b"]] if len(C.norm(p["p"])) >= 3)
        if s["tipo"] == "cancela" and k and read < 3 and segs[k - 1]["tipo"] == "corte" \
                and segs[k - 1]["parte"] == s["parte"]:
            segs[k - 1]["tipo"] = "cancela"  # "Corte parte 3… Cancela parte 3": desfaz o corte
            warnings.append(f"parte {s['parte']}: corte desfeito logo depois")
    valid = {p["n"]: p for p in parts}
    chosen = {}
    for s in segs:
        if s["parte"] not in valid:
            warnings.append(f"marcador \"{s['tipo']} parte {s['parte']}\" em {palavras[s['i0']]['ini']:.1f}s, mas o "
                          f"roteiro tem {len(parts)} partes: ignorado")
        elif s["tipo"] == "corte":
            n = _cross_check_number(s, valid, palavras)
            if n != s["parte"]:
                warnings.append(f"\"corte parte {s['parte']}\" em {palavras[s['i0']]['ini']:.0f}s, mas o texto lido é "
                              f"da parte {n}: usado como parte {n}")
                s["parte"] = n
            chosen[s["parte"]] = s  # o último "corte" da parte vale

    spans, missing, used = [], [], set()
    for p in parts:
        s = chosen.get(p["n"])
        if s and s["b"] - s["a"] < 2:
            tr, falt = [], [f["texto"] for f in p["frases"]]
            used.add(id(s))
            warnings.append(f"parte {p['n']}: \"corte\" sem nada lido antes")
        elif s:
            tr, falt = _in_part(p, palavras, s["a"], s["b"], f"corte parte {p['n']}")
            used.add(id(s))
        else:
            # sem "corte": procura a leitura no que não foi cancelado, da mais recente para a mais antiga
            best = None
            for s2 in reversed(segs + [tail]):
                if s2["tipo"] == "cancela" or s2["b"] - s2["a"] < 2:
                    continue
                tr2, falt2 = _in_part(p, palavras, s2["a"], s2["b"], f"parte {p['n']} sem marcador")
                if best is None or len(falt2) < len(best[1]):
                    best = (tr2, falt2, s2)
            if best and len(best[1]) <= len(p["frases"]) / 2:
                tr, falt, s2 = best
                used.add(id(s2))
                warnings.append(f"parte {p['n']} sem \"corte\": usada a leitura em {palavras[s2['a']]['ini']:.0f}s "
                              f"(confira)")
            else:
                tr, falt = [], [f["texto"] for f in p["frases"]]
                warnings.append(f"parte {p['n']} sem tomada: nenhum \"corte parte {p['n']}\" e nenhuma leitura achada")
        spans += tr
        missing += falt

    for s in segs + [tail]:
        if id(s) not in used and s["b"] > s["a"]:
            reason = {"cancela": f"cancelada (parte {s['parte']})", "sem marcador": "sem marcador no fim"}.get(
                s["tipo"], f"parte {s['parte']} lida de novo depois" if s["parte"] in valid else "parte inexistente")
            spans.append(_discarded(palavras, s["a"], s["b"], reason))
        if s is not tail:
            spans.append(_discarded(palavras, s["i0"], s["i1"], f"marcador: {s['tipo']} parte {s['parte']}",
                                       "marcador"))
    # uma palavra só pode estar num trecho mantido; trecho que sai e cobre palavra mantida não é listado
    spans.sort(key=lambda t: (t["i"], not t["manter"]))
    kept, output = set(), []
    for t in spans:
        band = set(range(t["i"], t["j"]))
        if t["manter"] and band & kept:
            t.update(manter=False, tipo="fora", motivo=t["motivo"] + " · já usado em outra parte")
        if t["manter"]:
            kept |= band
        output.append(t)
    output = [t for t in output if t["manter"] or t["tipo"] in ("descartado", "marcador")
             or not set(range(t["i"], t["j"])) & kept]
    return output, missing, warnings
