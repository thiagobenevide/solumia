"""Claquete falada: o narrador marca cada parte do roteiro na gravação.

  "Corte parte 3"    → a tomada que acabou de ler da parte 3 está boa (vai do marcador anterior até aqui).
  "Cancela parte 3"  → a tomada que acabou de ler não serve.
  sem marcador       → não é usada (se uma parte ficar sem nenhum "corte", procura-se a leitura dela no que
                       não foi cancelado e fica um aviso).

Parte = parágrafo do roteiro (linha não vazia que não é título); `./dark partes <ep>` gera a lista numerada
para a leitura. "Corte parte N" dito mais de uma vez: vale o último. "Cancela parte N" logo depois de
"Corte parte N" (sem ler nada entre os dois) desfaz aquele corte.

Dentro da tomada confirmada as regras de `cortes.decidir` continuam (frase lida duas vezes, gaguejo,
bastidor); o que vem antes da primeira frase e depois da última sai. Sem marcadores na gravação, a esteira
usa o fluxo antigo.
"""
import re

from esteira import cortes as C

UNI = {"um": 1, "uma": 1, "dois": 2, "duas": 2, "tres": 3, "quatro": 4, "cinco": 5, "seis": 6, "sete": 7,
       "oito": 8, "nove": 9}
ESP = {"dez": 10, "onze": 11, "doze": 12, "treze": 13, "quatorze": 14, "catorze": 14, "quinze": 15,
       "dezesseis": 16, "dezasseis": 16, "dezessete": 17, "dezassete": 17, "dezoito": 18, "dezenove": 19,
       "dezanove": 19}
DEZ = {"vinte": 20, "trinta": 30, "quarenta": 40, "cinquenta": 50, "sessenta": 60, "setenta": 70,
       "oitenta": 80, "noventa": 90}
_alt = lambda d: "|".join(sorted(d, key=len, reverse=True))
NUM = rf"(?:\d+|(?:{_alt(DEZ)})(?: e (?:{_alt(UNI)}))?|{_alt(ESP)}|{_alt(UNI)}|cem)"
# variações que o Whisper escreve: "corta parte 1", "corte a parte um", "cancelo parte catorze", "porte 2"
RE_MARCA = re.compile(rf"\b(cort\w*|cancel\w*) (?:(?:a|o|da|de|na) )?(?:parte|partes|arte|porte|parti|parto) ({NUM})\b")
HOTWORDS = "Corte parte. Cancela parte."  # vício do Whisper para os marcadores (só na gravação bruta)


def numero(texto):
    p = texto.split()
    if p[0].isdigit():
        return int(p[0])
    if p[0] == "cem":
        return 100
    for d in (UNI, ESP):
        if p[0] in d:
            return d[p[0]]
    return DEZ[p[0]] + (UNI[p[-1]] if len(p) == 3 else 0)


def partes_do_roteiro(texto, capitulos=None):
    """Partes com as frases de cada uma; `f0` = índice global da primeira frase (o mesmo de
    `cortes.frases_do_roteiro` no roteiro inteiro). Com `capitulos` (as "## Parte N" do roteiro no vault,
    `roteiro.json`), cada parte junta as falas do seu capítulo; sem eles, parte = parágrafo."""
    falas, f0 = [], 0
    for linha in texto.splitlines():
        frases = C.frases_do_roteiro(linha)
        if frases:
            falas.append({"texto": linha.strip(), "frases": frases, "f0": f0})
            f0 += len(frases)
    if not capitulos:
        return [dict(f, n=k + 1) for k, f in enumerate(falas)]
    caps = sorted(capitulos, key=lambda c: c["fala"])
    partes = []
    for c, prox in zip(caps, caps[1:] + [None]):
        grupo = falas[c["fala"]:prox["fala"] if prox else len(falas)]
        if grupo:
            partes.append({"n": int(c["parte"]), "nome": c.get("nome", ""), "f0": grupo[0]["f0"],
                           "texto": "\n".join(g["texto"] for g in grupo),
                           "frases": [x for g in grupo for x in g["frases"]]})
    return partes


def do_projeto(projeto):
    import json
    rot = projeto.caminho("roteiro.json")
    caps = json.loads(rot.read_text()).get("capitulos") if rot.exists() else None
    return partes_do_roteiro(projeto.roteiro().read_text(), caps)


def texto_para_leitura(partes):
    return "\n\n".join(f"PARTE {p['n']}" + (f" — {p['nome']}" if p.get("nome") else "") + f"\n{p['texto']}"
                       for p in partes) + (
        "\n\n— Ao terminar cada parte bem lida: pausa, \"Corte parte N\", pausa.\n"
        "— Se errou: \"Cancela parte N\" (ou só recomece; sem marcador a leitura não é usada).\n")


def marcadores(palavras):
    """[{tipo: corte|cancela, parte, i0, i1}] — i0..i1 = palavras do marcador na transcrição."""
    idx, toks = [], []
    for k, p in enumerate(palavras):
        for w in re.split(r"[-\s]+", p["p"]):  # "corte-parte" vira duas palavras
            n = C.norm(w)
            if n:
                idx.append(k)
                toks.append(n)
    texto, inicio = "", []
    for t in toks:
        inicio.append(len(texto))
        texto += t + " "
    saida = []
    for m in RE_MARCA.finditer(texto):
        a = next(k for k, s in enumerate(inicio) if s >= m.start())
        b = max(k for k, s in enumerate(inicio) if s < m.end())
        saida.append({"tipo": "corte" if m.group(1).startswith("cort") else "cancela", "parte": numero(m.group(2)),
                      "i0": idx[a], "i1": idx[b] + 1})
    return saida


def _aparar(trechos, motivo):
    """Só fica o que está entre a primeira e a última frase da parte: conversa antes de começar e sobra
    antes do marcador saem. Improviso no meio da tomada confirmada fica (o narrador aprovou a leitura)."""
    nucleo = [k for k, t in enumerate(trechos) if t["manter"] and t["tipo"] in ("tomada", "reformulada")]
    if nucleo and nucleo[-1] + 1 < len(trechos):  # "Isso assusta muito." — colado no fim da última frase
        a, b = trechos[nucleo[-1]], trechos[nucleo[-1] + 1]
        if b["ini"] - a["fim"] <= 0.3 and b["j"] - b["i"] <= 3 and b["tipo"] in ("fora", "improviso"):
            b.update(manter=True, tipo="continuacao", confianca=0.8, motivo="colada no fim da leitura confirmada")
    for k, t in enumerate(trechos):
        if not nucleo or k < nucleo[0] or (k > nucleo[-1] and t["tipo"] != "continuacao"):
            t.update(manter=False, tipo="fora", por="claquete", confianca=1.0, motivo=f"{motivo}: fora da leitura")
        elif t["tipo"] == "improviso" and not t["manter"] and t["j"] - t["i"] >= 3:
            t.update(manter=True, confianca=max(t["confianca"], 0.75), motivo=t["motivo"] + " · dentro da tomada confirmada")


def _na_parte(parte, palavras, a, b, motivo):
    """cortes.decidir só com as frases da parte, nas palavras a..b; índices de volta para a gravação toda."""
    trechos, faltando = C.decidir(parte["frases"], palavras[a:b])
    for t in trechos:
        t["i"] += a
        t["j"] += a
        if "par" in t:
            t["par"] += a
        if "frase" in t:
            t["frase"] += parte["f0"]
        if "entre" in t:
            t["entre"] = [x + parte["f0"] for x in t["entre"]]
        t["parte"] = parte["n"]
        t["motivo"] = f"parte {parte['n']} · {t['motivo']}"
    _aparar(trechos, motivo)
    return trechos, faltando


def _cobertura(parte, palavras, a, b):
    escolhas, _, _ = C.escolher(parte["frases"], palavras[a:b])
    return sum(1 for e in escolhas if e) / len(parte["frases"])


def _conferir_numero(s, validas, palavras):
    """Número dito ou ouvido errado ("corte parte 7" depois de ler a 6): se o texto lido cobre mal a parte
    dita e bem uma vizinha, vale a vizinha."""
    n = s["parte"]
    if s["b"] - s["a"] < 2:
        return n
    dita = _cobertura(validas[n], palavras, s["a"], s["b"])
    if dita >= 0.6:
        return n
    viz = [(_cobertura(validas[m], palavras, s["a"], s["b"]), m) for m in (n - 1, n + 1) if m in validas]
    melhor = max(viz, default=(0, n))
    return melhor[1] if melhor[0] >= dita + 0.3 else n


def _descartado(palavras, a, b, motivo, tipo="descartado"):
    return {"ini": palavras[a]["ini"], "fim": palavras[b - 1]["fim"], "i": a, "j": b, "manter": False, "tipo": tipo,
            "motivo": motivo, "confianca": 1.0, "por": "claquete", "texto": " ".join(p["p"] for p in palavras[a:b])}


def decidir(partes, palavras):
    """None se a gravação não tem marcadores (fluxo antigo). Senão (trechos, faltando, avisos)."""
    marcas = marcadores(palavras)
    if not marcas:
        return None
    avisos, segs, ini = [], [], 0
    for m in marcas:
        segs.append(dict(m, a=ini, b=m["i0"]))
        ini = m["i1"]
    cauda = {"tipo": "sem marcador", "parte": None, "a": ini, "b": len(palavras), "i0": len(palavras),
             "i1": len(palavras)}
    for k, s in enumerate(segs):
        lido = sum(1 for p in palavras[s["a"]:s["b"]] if len(C.norm(p["p"])) >= 3)
        if s["tipo"] == "cancela" and k and lido < 3 and segs[k - 1]["tipo"] == "corte" \
                and segs[k - 1]["parte"] == s["parte"]:
            segs[k - 1]["tipo"] = "cancela"  # "Corte parte 3… Cancela parte 3": desfaz o corte
            avisos.append(f"parte {s['parte']}: corte desfeito logo depois")
    validas = {p["n"]: p for p in partes}
    escolhido = {}
    for s in segs:
        if s["parte"] not in validas:
            avisos.append(f"marcador \"{s['tipo']} parte {s['parte']}\" em {palavras[s['i0']]['ini']:.1f}s, mas o "
                          f"roteiro tem {len(partes)} partes: ignorado")
        elif s["tipo"] == "corte":
            n = _conferir_numero(s, validas, palavras)
            if n != s["parte"]:
                avisos.append(f"\"corte parte {s['parte']}\" em {palavras[s['i0']]['ini']:.0f}s, mas o texto lido é "
                              f"da parte {n}: usado como parte {n}")
                s["parte"] = n
            escolhido[s["parte"]] = s  # o último "corte" da parte vale

    trechos, faltando, usados = [], [], set()
    for p in partes:
        s = escolhido.get(p["n"])
        if s and s["b"] - s["a"] < 2:
            tr, falt = [], [f["texto"] for f in p["frases"]]
            usados.add(id(s))
            avisos.append(f"parte {p['n']}: \"corte\" sem nada lido antes")
        elif s:
            tr, falt = _na_parte(p, palavras, s["a"], s["b"], f"corte parte {p['n']}")
            usados.add(id(s))
        else:
            # sem "corte": procura a leitura no que não foi cancelado, da mais recente para a mais antiga
            melhor = None
            for s2 in reversed(segs + [cauda]):
                if s2["tipo"] == "cancela" or s2["b"] - s2["a"] < 2:
                    continue
                tr2, falt2 = _na_parte(p, palavras, s2["a"], s2["b"], f"parte {p['n']} sem marcador")
                if melhor is None or len(falt2) < len(melhor[1]):
                    melhor = (tr2, falt2, s2)
            if melhor and len(melhor[1]) <= len(p["frases"]) / 2:
                tr, falt, s2 = melhor
                usados.add(id(s2))
                avisos.append(f"parte {p['n']} sem \"corte\": usada a leitura em {palavras[s2['a']]['ini']:.0f}s "
                              f"(confira)")
            else:
                tr, falt = [], [f["texto"] for f in p["frases"]]
                avisos.append(f"parte {p['n']} sem tomada: nenhum \"corte parte {p['n']}\" e nenhuma leitura achada")
        trechos += tr
        faltando += falt

    for s in segs + [cauda]:
        if id(s) not in usados and s["b"] > s["a"]:
            motivo = {"cancela": f"cancelada (parte {s['parte']})", "sem marcador": "sem marcador no fim"}.get(
                s["tipo"], f"parte {s['parte']} lida de novo depois" if s["parte"] in validas else "parte inexistente")
            trechos.append(_descartado(palavras, s["a"], s["b"], motivo))
        if s is not cauda:
            trechos.append(_descartado(palavras, s["i0"], s["i1"], f"marcador: {s['tipo']} parte {s['parte']}",
                                       "marcador"))
    # uma palavra só pode estar num trecho mantido; trecho que sai e cobre palavra mantida não é listado
    trechos.sort(key=lambda t: (t["i"], not t["manter"]))
    mantidas, saida = set(), []
    for t in trechos:
        faixa = set(range(t["i"], t["j"]))
        if t["manter"] and faixa & mantidas:
            t.update(manter=False, tipo="fora", motivo=t["motivo"] + " · já usado em outra parte")
        if t["manter"]:
            mantidas |= faixa
        saida.append(t)
    saida = [t for t in saida if t["manter"] or t["tipo"] in ("descartado", "marcador")
             or not set(range(t["i"], t["j"])) & mantidas]
    return saida, faltando, avisos
