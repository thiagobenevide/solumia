"""Visões compactas do projeto para o Claude ler e editar sem abrir os JSONs inteiros.

  resumo    uma linha por cena (só os campos de curadoria) em vez do plano.json completo
  palavras  tempo de cada palavra falada num intervalo, para preencher destaques
  ajustar   aplica edições parciais (JSON Lines) ao plano.json sem reescrevê-lo
"""

import json
import sys

from esteira.scenes import normalize

EDITABLE = {"busca_en", "busca", "tipo", "destaques", "movimento"}


def _ids(texto):
    return {int(x) for x in texto.split(",")} if texto else None


def summary(projeto, cenas=None, sem_texto=False):
    plano = projeto.carregar_json("plano.json")
    so = _ids(cenas)
    sem_midia = [c["id"] for c in plano["cenas"] if not c.get("midia")]
    print(f"{plano.get('titulo') or '(sem título)'} · {plano['duracao']:.0f}s · {len(plano['cenas'])} cenas"
          + (f" · sem mídia: {','.join(map(str, sem_midia))}" if sem_midia else ""))
    print("id ini tipo>obtido | busca_en | busca | destaques | texto   (* = busca_definida)")
    for c in plano["cenas"]:
        if so and c["id"] not in so:
            continue
        obtido = {"video": "v", "imagem": "i"}.get(c.get("midia_tipo"), "-") if c.get("midia") else "-"
        dest = ";".join(f"{d['texto']}@{d['inicio']:.1f}" for d in c.get("destaques", []))
        campos = [f"{c['id']}{'*' if c.get('busca_definida') else ''} {c['inicio']:.1f} {c['tipo'][0]}>{obtido}",
                  c.get("busca_en") or "", c.get("busca") or "", dest]
        if not sem_texto:
            campos.append(c["texto"])
        print(" | ".join(campos))


def _words(projeto):
    # alinhamento.json tem o texto do roteiro (grafia certa); a transcrição é o fallback.
    if projeto.caminho("alinhamento.json").exists():
        return projeto.carregar_json("alinhamento.json")
    return projeto.carregar_json("transcricao.json")["palavras"]


def words(projeto, de=0.0, ate=None):
    linha = []
    for p in _words(projeto):
        if p["ini"] >= de and (ate is None or p["ini"] <= ate):
            linha.append(f"{p['ini']:.1f} {p['p']}")
    print(" · ".join(linha))


def _start(palavras, texto, ini, fim):
    alvo = [normalize(w) for w in texto.split()]
    dentro = [p for p in palavras if ini - 0.5 <= p["ini"] <= fim + 0.5]
    for i, p in enumerate(dentro):
        if [normalize(q["p"]) for q in dentro[i:i + len(alvo)]] == alvo:
            return round(p["ini"], 3)
    return next((round(p["ini"], 3) for p in dentro if normalize(p["p"]) == alvo[0]), None)


def adjust(projeto, arquivo=None):
    """Uma linha JSON por cena: {"id": 3, "busca_en": "...", "tipo": "imagem", "destaques": ["piratas"]}.

    Só os campos informados mudam. Destaque pode ser texto puro: o início é achado nas palavras da cena.
    """
    entrada = open(arquivo, encoding="utf-8").read() if arquivo else sys.stdin.read()
    plano = projeto.carregar_json("plano.json")
    por_id = {c["id"]: c for c in plano["cenas"]}
    palavras_ = _words(projeto)
    erros, mudou = [], []
    for n, linha in enumerate(entrada.splitlines(), 1):
        linha = linha.strip()
        if not linha or linha.startswith("#"):
            continue
        try:
            ed = json.loads(linha)
        except json.JSONDecodeError as e:
            erros.append(f"linha {n}: JSON inválido ({e.msg})")
            continue
        c = por_id.get(ed.pop("id", None))
        if not c:
            erros.append(f"linha {n}: cena inexistente")
            continue
        proibidos = set(ed) - EDITABLE
        if proibidos:
            erros.append(f"cena {c['id']}: campos não editáveis {sorted(proibidos)}")
            continue
        if "tipo" in ed and ed["tipo"] not in ("video", "imagem"):
            erros.append(f"cena {c['id']}: tipo deve ser video|imagem")
            continue
        if c.get("busca_definida") and ({"busca_en", "busca"} & set(ed)):
            erros.append(f"cena {c['id']}: busca veio de [busca: ...] no roteiro; ignorada")
            ed.pop("busca_en", None), ed.pop("busca", None)
        if "destaques" in ed:
            lista = []
            for d in ed["destaques"]:
                d = {"texto": d} if isinstance(d, str) else d
                if d.get("inicio") is None:
                    d["inicio"] = _start(palavras_, d["texto"], c["inicio"], c["fim"])
                    if d["inicio"] is None:
                        erros.append(f"cena {c['id']}: '{d['texto']}' não é falado nesta cena; ignorado")
                        continue
                lista.append({"texto": d["texto"], "inicio": d["inicio"]})
            ed["destaques"] = lista
        c.update(ed)
        mudou.append(str(c["id"]))
    projeto.salvar_json("plano.json", plano)
    print(f"  {len(mudou)} cenas ajustadas" + (f": {','.join(mudou)}" if mudou else ""))
    for e in erros:
        print(f"  ! {e}")
