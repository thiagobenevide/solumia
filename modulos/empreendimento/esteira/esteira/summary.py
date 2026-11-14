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


def summary(project, cenas=None, without_text=False):
    plan = project.load_json("plano.json")
    so = _ids(cenas)
    without_media = [c["id"] for c in plan["cenas"] if not c.get("midia")]
    print(f"{plan.get('titulo') or '(sem título)'} · {plan['duracao']:.0f}s · {len(plan['cenas'])} cenas"
          + (f" · sem mídia: {','.join(map(str, without_media))}" if without_media else ""))
    print("id ini tipo>obtido | busca_en | busca | destaques | texto   (* = busca_definida)")
    for c in plan["cenas"]:
        if so and c["id"] not in so:
            continue
        obtido = {"video": "v", "imagem": "i"}.get(c.get("midia_tipo"), "-") if c.get("midia") else "-"
        dest = ";".join(f"{d['texto']}@{d['inicio']:.1f}" for d in c.get("destaques", []))
        fields = [f"{c['id']}{'*' if c.get('busca_definida') else ''} {c['inicio']:.1f} {c['tipo'][0]}>{obtido}",
                  c.get("busca_en") or "", c.get("busca") or "", dest]
        if not without_text:
            fields.append(c["texto"])
        print(" | ".join(fields))


def _words(project):
    # alinhamento.json tem o texto do roteiro (grafia certa); a transcrição é o fallback.
    if project.caminho("alinhamento.json").exists():
        return project.load_json("alinhamento.json")
    return project.load_json("transcricao.json")["palavras"]


def words(project, de=0.0, ate=None):
    line = []
    for p in _words(project):
        if p["ini"] >= de and (ate is None or p["ini"] <= ate):
            line.append(f"{p['ini']:.1f} {p['p']}")
    print(" · ".join(line))


def _start(palavras, texto, ini, fim):
    target = [normalize(w) for w in texto.split()]
    inside = [p for p in palavras if ini - 0.5 <= p["ini"] <= fim + 0.5]
    for i, p in enumerate(inside):
        if [normalize(q["p"]) for q in inside[i:i + len(target)]] == target:
            return round(p["ini"], 3)
    return next((round(p["ini"], 3) for p in inside if normalize(p["p"]) == target[0]), None)


def adjust(project, arquivo=None):
    """Uma linha JSON por cena: {"id": 3, "busca_en": "...", "tipo": "imagem", "destaques": ["piratas"]}.

    Só os campos informados mudam. Destaque pode ser texto puro: o início é achado nas palavras da cena.
    """
    entry = open(arquivo, encoding="utf-8").read() if arquivo else sys.stdin.read()
    plan = project.load_json("plano.json")
    by_id = {c["id"]: c for c in plan["cenas"]}
    words_ = _words(project)
    errors, mudou = [], []
    for n, line in enumerate(entry.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            ed = json.loads(line)
        except json.JSONDecodeError as e:
            errors.append(f"linha {n}: JSON inválido ({e.msg})")
            continue
        c = by_id.get(ed.pop("id", None))
        if not c:
            errors.append(f"linha {n}: cena inexistente")
            continue
        proibidos = set(ed) - EDITABLE
        if proibidos:
            errors.append(f"cena {c['id']}: campos não editáveis {sorted(proibidos)}")
            continue
        if "tipo" in ed and ed["tipo"] not in ("video", "imagem"):
            errors.append(f"cena {c['id']}: tipo deve ser video|imagem")
            continue
        if c.get("busca_definida") and ({"busca_en", "busca"} & set(ed)):
            errors.append(f"cena {c['id']}: busca veio de [busca: ...] no roteiro; ignorada")
            ed.pop("busca_en", None), ed.pop("busca", None)
        if "destaques" in ed:
            items = []
            for d in ed["destaques"]:
                d = {"texto": d} if isinstance(d, str) else d
                if d.get("inicio") is None:
                    d["inicio"] = _start(words_, d["texto"], c["inicio"], c["fim"])
                    if d["inicio"] is None:
                        errors.append(f"cena {c['id']}: '{d['texto']}' não é falado nesta cena; ignorado")
                        continue
                items.append({"texto": d["texto"], "inicio": d["inicio"]})
            ed["destaques"] = items
        c.update(ed)
        mudou.append(str(c["id"]))
    project.save_json("plano.json", plan)
    print(f"  {len(mudou)} cenas ajustadas" + (f": {','.join(mudou)}" if mudou else ""))
    for e in errors:
        print(f"  ! {e}")
