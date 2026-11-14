"""Exportação do dataset (`docs/PLANO-DATASET.md` §4 e F6): registro → visões de treino e avaliação.

`exportacoes/<data>/`: `sft/<tarefa>.{train,val}.jsonl` (mensagens de chat; resposta = só o JSON do N1),
`dpo/<tarefa>.jsonl` (prompt, chosen, rejected), `eval/<tarefa>.jsonl` (casos do ouro), `esquemas/` (JSON Schema do
N1 de cada app, que vira gramática no llama.cpp) e `manifesto.json` (hash de cada arquivo, contagens e versões).
O prompt é montado aqui, do contexto estruturado, com o modelo de prompt da época da exportação. A montagem entra por
trecho de ~45 s (cabe no contexto do modelo local e multiplica os exemplos). A divisão é por grupo (sha1), nunca
por registro: variações e ajustes de uma peça ficam do mesmo lado. O ouro nunca entra no treino.
"""
import hashlib
import json
from datetime import datetime
from pathlib import Path

from esteira.dataset import registry as R

def _folders():  # seguem R.PASTA em tempo de execução (os testes a redirecionam)
    return R.FOLDER / "exportacoes", R.FOLDER / "ouro"

VALIDATION, FRACTION_GOLD, SPAN = 0.1, 0.08, 45.0
TASKS = ("peca_animar", "montar", "corrigir_montagem", "thumb_compor", "foto_tratar")

INSTRUCTIONS = {
    "peca_animar": "Escreva a peça de motion graphics desta ficha como documento N1 do EffectCraft.",
    "montar": "Monte este trecho do episódio no FilmCraft: responda com as operações N1 da montagem.",
    "corrigir_montagem": "Corrija a montagem: responda só com as operações N1 de correção.",
    "thumb_compor": "Componha a thumbnail do episódio no PhotoCraft como documento N1.",
    "foto_tratar": "Decida o tratamento desta foto (foco, recorte, separar planos); a receita do canal faz o resto.",
}


def schema(tarefa: str):
    from esteira.n1 import effectcraft, filmcraft, photocraft
    return {"peca_animar": effectcraft.Piece, "montar": filmcraft.Assembly, "corrigir_montagem": filmcraft.Assembly,
            "thumb_compor": photocraft.Composition, "foto_tratar": photocraft.PhotoDecision}[tarefa]


def _fraction(chave: str) -> float:
    return int(hashlib.sha1(chave.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF


def _context(r: dict) -> dict:
    c = r["contexto"]
    return R.read_artifact(c["ref"]) if set(c) == {"ref"} else c


def answer(r: dict):
    """A saída que o modelo aprende (N1 ou N2), sem os anexos do registro."""
    s = R.read_artifact(r["saida"]["n1"])
    if r["tarefa"] == "peca_animar":
        return s.get("peca_n1") or None
    return s


def context_model(r: dict) -> dict:
    """O que o modelo recebe (sem campos de controle)."""
    c = dict(_context(r))
    if r["tarefa"] == "peca_animar":
        s = R.read_artifact(r["saida"]["n1"])
        ficha = {k: v for k, v in (s.get("ficha") or {}).items()
                 if k not in ("estado", "versao", "origem", "notas", "id", "motor")}
        return {"ficha": ficha, "pedido": c.get("pedido"), "modo": c.get("modo"), "comentario": c.get("comentario")}
    if r["tarefa"] == "corrigir_montagem" and isinstance(c.get("montagem"), str):
        c["montagem"] = R.read_artifact(c["montagem"])
    return c


def prompt(tarefa: str, contexto: dict, exemplos=()) -> str:
    partes = [INSTRUCTIONS[tarefa], "Responda só com JSON válido no esquema. Nada de texto fora do JSON."]
    for k, (cx, rx) in enumerate(exemplos, 1):
        partes.append(f"<exemplo {k}>\n<contexto>{json.dumps(cx, ensure_ascii=False)}</contexto>\n"
                      f"<resposta>{json.dumps(rx, ensure_ascii=False)}</resposta>\n</exemplo {k}>")
    partes.append(f"<contexto>{json.dumps(contexto, ensure_ascii=False)}</contexto>")
    return "\n\n".join(partes)


def _system(tarefa: str) -> str:
    # curto de propósito: o formato é garantido pela gramática do esquema na inferência; o JSON Schema inteiro
    # incharia cada exemplo e estouraria o contexto do treino (16 GB de VRAM)
    app = R.TASKS[tarefa]
    return f"Você opera o {app} pela linguagem N1 v1 e responde só com o JSON do esquema da tarefa {tarefa}."


# ---------- montagem por trecho ----------

def spans_assembly(ctx: dict, doc: dict) -> list[tuple[dict, dict]]:
    """Divide uma montagem em janelas de ~TRECHO s: (contexto do trecho, ops do trecho). As operações globais
    (sequência, narração, cor, música, legendas) ficam no primeiro trecho."""
    dur = ctx.get("duracao") or max((o.get("em", 0) + (o.get("dur") or 0) for o in doc["ops"]), default=0)
    if dur <= SPAN * 1.5:
        return [(ctx, doc)]
    janelas, a = [], 0.0
    while a < dur:
        janelas.append((a, min(dur, a + SPAN)))
        a += SPAN
    nomes_de = {}
    for o in doc["ops"]:
        if o["op"] in ("colocar", "texto"):
            k = next((i for i, (x, y) in enumerate(janelas) if x <= o["em"] < y), len(janelas) - 1)
            nomes_de[o["id"]] = k
    saida = []
    for i, (x, y) in enumerate(janelas):
        ops = [o for o in doc["ops"] if nomes_de.get(o.get("id") or o.get("alvo"), 0) == i]
        cx = {**{k: v for k, v in ctx.items() if k not in ("cenas", "graficos", "chaves")}, "trecho": [x, y],
              "cenas": [c for c in ctx.get("cenas", []) if x <= (c.get("inicio") or 0) < y],
              "graficos": [g for g in ctx.get("graficos", []) if x <= (g.get("inicio") or 0) < y],
              "chaves": [k for k in ctx.get("chaves", []) if x <= (k.get("inicio") or 0) < y]}
        saida.append((cx, {"versao": 1, "ops": ops}))
    return saida


# ---------- ouro ----------

def gold(tarefa: str) -> set[str]:
    """Ids do ouro da tarefa. Sem arquivo, escolhe os grupos pelo sha1 (≈8%, ao menos 1 com 5+ grupos) e grava."""
    arq = _folders()[1] / R.TASKS[tarefa] / f"{tarefa}.jsonl"
    if arq.exists():
        return {json.loads(x)["id"] for x in arq.read_text().splitlines() if x.strip()}
    bons = [r for r in R.records(tarefa) if r["uso"] == "sft"]
    grupos = sorted({r["grupo"] for r in bons}, key=lambda g: _fraction("ouro:" + g))
    if len(grupos) < 5:
        return set()
    escolhidos = {g for g in grupos if _fraction("ouro:" + g) < FRACTION_GOLD} or {grupos[0]}
    ids = [r["id"] for r in bons if r["grupo"] in escolhidos]
    arq.parent.mkdir(parents=True, exist_ok=True)
    arq.write_text("".join(json.dumps({"id": i, "auto": True}) + "\n" for i in ids))
    return set(ids)


def mark_gold(tarefa: str, ids: list[str]) -> None:
    arq = _folders()[1] / R.TASKS[tarefa] / f"{tarefa}.jsonl"
    atuais = gold(tarefa) if arq.exists() else set()
    arq.parent.mkdir(parents=True, exist_ok=True)
    with open(arq, "a") as f:
        for i in ids:
            if i not in atuais:
                f.write(json.dumps({"id": i, "auto": False}) + "\n")


# ---------- exportação ----------

def _pairs(tarefa: str) -> list[tuple[dict, dict]]:
    """(contexto, resposta) de cada registro bom; a montagem vira trechos."""
    out = []
    for r in R.records(tarefa):
        if r["uso"] != "sft":
            continue
        resp = answer(r)
        if resp is None:
            continue
        cx = context_model(r)
        if tarefa == "montar":
            out += [(r, c, d) for c, d in spans_assembly(cx, resp)]
        else:
            out.append((r, cx, resp))
    return out


def cases_eval(tarefa: str) -> list[dict]:
    ids = gold(tarefa)
    casos = []
    for r, cx, resp in _pairs(tarefa):
        if r["id"] in ids:
            casos.append({"id": r["id"], "tarefa": tarefa, "contexto": cx, "referencia": resp})
    return casos


def _dpo(tarefa: str) -> list[dict]:
    """Pares do mesmo grupo: bom × ruim. Nas thumbs, a escolhida × as outras candidatas do mesmo episódio."""
    por: dict[str, dict[str, list]] = {}
    for r in R.records(tarefa):
        lado = ("bom" if r["uso"] == "sft" else "ruim" if r["uso"] == "dpo_ruim"
                else "ruim" if tarefa == "thumb_compor" and r["uso"] == "pendente" else None)
        if lado:
            por.setdefault(r["grupo"], {"bom": [], "ruim": []})[lado].append(r)
    saida = []
    for g in por.values():
        for b in g["bom"]:
            for m in g["ruim"]:
                rb, rm = answer(b), answer(m)
                if rb is None or rm is None or rb == rm:
                    continue
                saida.append({"grupo": b["grupo"], "prompt": prompt(tarefa, context_model(b)),
                              "chosen": json.dumps(rb, ensure_ascii=False), "rejected": json.dumps(rm, ensure_ascii=False)})
    return saida


def export(tarefas=None) -> dict:
    from esteira.n1 import save_schemas
    destino = _folders()[0] / datetime.now().strftime("%Y%m%d-%H%M%S")
    resumo = {"em": datetime.now().isoformat(timespec="seconds"), "pasta": str(destino), "tarefas": {}}
    arquivos = save_schemas(destino / "esquemas")
    for t in tarefas or TASKS:
        ids_ouro = gold(t)
        sft = {"train": [], "val": []}
        avaliacao = []
        for r, cx, resp in _pairs(t):
            if r["id"] in ids_ouro:
                avaliacao.append({"id": r["id"], "contexto": cx, "referencia": resp})
                continue
            linha = {"id": r["id"], "tarefa": t, "grupo": r["grupo"], "messages": [
                {"role": "system", "content": _system(t)},
                {"role": "user", "content": prompt(t, cx)},
                {"role": "assistant", "content": json.dumps(resp, ensure_ascii=False)}]}
            sft["val" if _fraction(r["grupo"]) < VALIDATION else "train"].append(linha)
        dpo = _dpo(t)
        for nome, linhas in (("sft/" + t + ".train.jsonl", sft["train"]), ("sft/" + t + ".val.jsonl", sft["val"]),
                             ("dpo/" + t + ".jsonl", dpo), ("eval/" + t + ".jsonl", avaliacao)):
            arq = destino / nome
            arq.parent.mkdir(parents=True, exist_ok=True)
            arq.write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in linhas))
            arquivos.append(arq)
        resumo["tarefas"][t] = {"sft": len(sft["train"]), "val": len(sft["val"]), "dpo": len(dpo),
                                "eval": len(avaliacao)}
    resumo["manifesto"] = {str(a.relative_to(destino)): hashlib.sha256(a.read_bytes()).hexdigest() for a in arquivos}
    (destino / "manifesto.json").write_text(json.dumps(resumo, ensure_ascii=False, indent=1))
    return resumo


def last() -> Path | None:
    base = _folders()[0]
    pastas = sorted(base.glob("*/manifesto.json")) if base.exists() else []
    return pastas[-1].parent if pastas else None


def hash_export(pasta: Path) -> str:
    return hashlib.sha256((Path(pasta) / "manifesto.json").read_bytes()).hexdigest()[:16]
