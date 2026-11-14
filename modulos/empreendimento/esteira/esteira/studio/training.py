"""Base de aprovações → fine-tune do modelo local (`docs/PLANO-ACERVO.md`, "Aprendizado").

Cada escolha e cada correção da pessoa já vira caso no gabarito da bancada (`$AGENT_DATA/.../bancada/gabarito/`):
`bloco_peca` (momento + 5 candidatas → a peça aprovada/trocada), `preencher` (momento + peça → encaixes que ficaram),
`corte` (trecho em dúvida → fica/sai) e `legenda` (Whisper → texto certo). Aqui eles viram conversas de treino no
formato de chat (o mesmo prompt que a IA local recebe na produção + a resposta certa), divididas em treino/validação
(90/10, fixo por caso) em `$AGENT_DATA/.../treino/<data>/`. O treino LoRA em si (`ai/train_lora.py`, num
`.venv-treino` com unsloth) parte desse diretório e entrega um GGUF para o roteador do llama.cpp.
"""
import hashlib
import json
from datetime import datetime

from esteira.project import DATA

FOLDER = DATA / "treino"
MINIMUM = {"bloco_peca": 150, "preencher": 150, "corte": 300, "legenda": 300}  # casos para valer a pena treinar
VALIDATION = 0.1


def _cases(task):
    from esteira import bench
    return bench.cases(task)


def _prompt_bench(task, instance):
    from esteira import bench
    text, _, _ = bench.TASKS[task][0](instance)
    return str(text)


def _fill(instance):
    """Prompt de preenchimento reconstruído com a ficha atual da peça (a peça pode ter saído do acervo: pula)."""
    from esteira.studio import direction as D
    from esteira.studio import piece as P
    try:
        f = P.load(instance["peca"])
    except (KeyError, ValueError):
        return None
    spoken = sorted(D.spoken(instance["texto"]))
    text = D.local.prompt(
        "direction_fill", peca=f.id, comunica=f.comunica, texto=instance["texto"], numeros=", ".join(spoken) or "nenhum",
        datas="nenhuma", nomes="nenhum", encaixes=D._describe_fits(f),
        botoes="\n".join(f"- {b.nome}: {b.valores} (padrão {b.padrao})" for b in f.botoes) or "(nenhum)", erros="")
    if P.validate_data(f, instance["encaixes"], instance.get("botoes") or {}):
        return None  # o que ficou não passa mais na ficha atual: não ensina
    return str(text), {"encaixes": instance["encaixes"], "botoes": instance.get("botoes") or {}}


def examples(task):
    """[(id, prompt, resposta JSON)] de uma tarefa (casos repetidos: vale o último)."""
    output = {}
    for c in _cases(task):
        if task == "bloco_peca":
            pair = (_prompt_bench(task, c), {"escolha": c["aceitas"][0], "motivo": "a que a pessoa aprovou"})
        elif task == "preencher":
            pair = _fill(c)
        elif task == "corte":
            pair = (_prompt_bench(task, c), {"manter": c["manter"], "motivo": "decisão revisada", "confianca": 1.0})
        elif task == "legenda":
            pair = (_prompt_bench(task, c), {"texto": c["certo"]})
        else:
            pair = None
        if pair:
            output[c.get("id") or hashlib.sha1(pair[0].encode()).hexdigest()[:12]] = pair
    return [(k, p, r) for k, (p, r) in output.items()]


def _validation(id_):
    return int(hashlib.sha1(str(id_).encode()).hexdigest()[:8], 16) / 0xFFFFFFFF < VALIDATION


def export(tasks=tuple(MINIMUM)):
    """Escreve `<tarefa>.train.jsonl` / `.val.jsonl` (mensagens de chat) e `resumo.json`. → o resumo."""
    destination = FOLDER / datetime.now().strftime("%Y%m%d-%H%M")
    destination.mkdir(parents=True, exist_ok=True)
    summary = {"em": datetime.now().isoformat(timespec="seconds"), "pasta": str(destination), "tarefas": {}}
    for t in tasks:
        ex = examples(t)
        parts = {"train": [], "val": []}
        for id_, prompt, answer in ex:
            line = {"id": id_, "tarefa": t, "messages": [
                {"role": "user", "content": prompt},
                {"role": "assistant", "content": json.dumps(answer, ensure_ascii=False)}]}
            parts["val" if _validation(id_) else "train"].append(line)
        for name, lines in parts.items():
            (destination / f"{t}.{name}.jsonl").write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in lines))
        summary["tarefas"][t] = {"treino": len(parts["train"]), "validacao": len(parts["val"]), "minimo": MINIMUM.get(t, 0),
                                "pronta": len(ex) >= MINIMUM.get(t, 0)}
    summary["pronta"] = any(x["pronta"] for x in summary["tarefas"].values())
    (destination / "resumo.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    return summary


def status():
    """Quantos casos há por tarefa (sem exportar) e a última exportação."""
    last = sorted(FOLDER.glob("*/resumo.json"))[-1:] if FOLDER.exists() else []
    return {"casos": {t: len(_cases(t)) for t in MINIMUM}, "minimo": MINIMUM,
            "ultima": json.loads(last[0].read_text()) if last else None}


# ---------------------------------------------------------------- treino LoRA (GPU)

def environment():
    from esteira.project import ROOT
    return ROOT / ".venv-treino" / "bin" / "python"


def train(base="unsloth/gemma-4-12b-it", epochs=2.0, quant="q4_k_m"):
    """Treina o LoRA com a última exportação (`ai/train_lora.py` no `.venv-treino`) e põe o GGUF na pasta de modelos
    do roteador como `agente-<data>.gguf` (escolha-o em Opções → modelo por operação). → nome do modelo."""
    import shutil
    import subprocess

    from esteira.ai import llama, local
    from esteira.project import ROOT
    py = environment()
    if not py.exists():
        raise SystemExit("ambiente de treino ausente: ~/.local/bin/uv venv .venv-treino --python 3.12 && "
                         "~/.local/bin/uv pip install --python .venv-treino/bin/python unsloth")
    s = status()
    if not s["ultima"]:
        raise SystemExit("exporte a base antes (aba Estúdio → Dependências → Base de treino)")
    data = s["ultima"]["pasta"]
    name = f"agente-{datetime.now():%Y%m%d-%H%M}"
    output = FOLDER / "modelos" / name
    output.mkdir(parents=True, exist_ok=True)
    local.free_gpu()
    subprocess.run([str(py), str(ROOT / "esteira/ai/train_lora.py"), data, str(output), "--base", base,
                    "--epochs", str(epochs), "--quant", quant], check=True)
    gguf = next(iter(sorted((output / "gguf").glob("*.gguf"))), None)
    if not gguf:
        raise SystemExit("o treino não gerou GGUF")
    shutil.copy(gguf, llama.MODELS_DIR / f"{name}.gguf")
    llama.server()
    return name
