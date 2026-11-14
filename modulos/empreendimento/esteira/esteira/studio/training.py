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


def _cases(tarefa):
    from esteira import bench
    return bench.cases(tarefa)


def _prompt_bench(tarefa, caso):
    from esteira import bench
    texto, _, _ = bench.TASKS[tarefa][0](caso)
    return str(texto)


def _fill(caso):
    """Prompt de preenchimento reconstruído com a ficha atual da peça (a peça pode ter saído do acervo: pula)."""
    from esteira.studio import direction as D
    from esteira.studio import piece as P
    try:
        f = P.load(caso["peca"])
    except (KeyError, ValueError):
        return None
    ditos = sorted(D.spoken(caso["texto"]))
    texto = D.local.prompt(
        "direcao_preencher", peca=f.id, comunica=f.comunica, texto=caso["texto"], numeros=", ".join(ditos) or "nenhum",
        datas="nenhuma", nomes="nenhum", encaixes=D._describe_fits(f),
        botoes="\n".join(f"- {b.nome}: {b.valores} (padrão {b.padrao})" for b in f.botoes) or "(nenhum)", erros="")
    if P.validate_data(f, caso["encaixes"], caso.get("botoes") or {}):
        return None  # o que ficou não passa mais na ficha atual: não ensina
    return str(texto), {"encaixes": caso["encaixes"], "botoes": caso.get("botoes") or {}}


def examples(tarefa):
    """[(id, prompt, resposta JSON)] de uma tarefa (casos repetidos: vale o último)."""
    saida = {}
    for c in _cases(tarefa):
        if tarefa == "bloco_peca":
            par = (_prompt_bench(tarefa, c), {"escolha": c["aceitas"][0], "motivo": "a que a pessoa aprovou"})
        elif tarefa == "preencher":
            par = _fill(c)
        elif tarefa == "corte":
            par = (_prompt_bench(tarefa, c), {"manter": c["manter"], "motivo": "decisão revisada", "confianca": 1.0})
        elif tarefa == "legenda":
            par = (_prompt_bench(tarefa, c), {"texto": c["certo"]})
        else:
            par = None
        if par:
            saida[c.get("id") or hashlib.sha1(par[0].encode()).hexdigest()[:12]] = par
    return [(k, p, r) for k, (p, r) in saida.items()]


def _validation(id_):
    return int(hashlib.sha1(str(id_).encode()).hexdigest()[:8], 16) / 0xFFFFFFFF < VALIDATION


def export(tarefas=tuple(MINIMUM)):
    """Escreve `<tarefa>.train.jsonl` / `.val.jsonl` (mensagens de chat) e `resumo.json`. → o resumo."""
    destino = FOLDER / datetime.now().strftime("%Y%m%d-%H%M")
    destino.mkdir(parents=True, exist_ok=True)
    resumo = {"em": datetime.now().isoformat(timespec="seconds"), "pasta": str(destino), "tarefas": {}}
    for t in tarefas:
        ex = examples(t)
        partes = {"train": [], "val": []}
        for id_, prompt, resposta in ex:
            linha = {"id": id_, "tarefa": t, "messages": [
                {"role": "user", "content": prompt},
                {"role": "assistant", "content": json.dumps(resposta, ensure_ascii=False)}]}
            partes["val" if _validation(id_) else "train"].append(linha)
        for nome, linhas in partes.items():
            (destino / f"{t}.{nome}.jsonl").write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in linhas))
        resumo["tarefas"][t] = {"treino": len(partes["train"]), "validacao": len(partes["val"]), "minimo": MINIMUM.get(t, 0),
                                "pronta": len(ex) >= MINIMUM.get(t, 0)}
    resumo["pronta"] = any(x["pronta"] for x in resumo["tarefas"].values())
    (destino / "resumo.json").write_text(json.dumps(resumo, ensure_ascii=False, indent=1))
    return resumo


def status():
    """Quantos casos há por tarefa (sem exportar) e a última exportação."""
    ultima = sorted(FOLDER.glob("*/resumo.json"))[-1:] if FOLDER.exists() else []
    return {"casos": {t: len(_cases(t)) for t in MINIMUM}, "minimo": MINIMUM,
            "ultima": json.loads(ultima[0].read_text()) if ultima else None}


# ---------------------------------------------------------------- treino LoRA (GPU)

def environment():
    from esteira.project import ROOT
    return ROOT / ".venv-treino" / "bin" / "python"


def train(base="unsloth/gemma-4-12b-it", epocas=2.0, quant="q4_k_m"):
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
    dados = s["ultima"]["pasta"]
    nome = f"agente-{datetime.now():%Y%m%d-%H%M}"
    saida = FOLDER / "modelos" / nome
    saida.mkdir(parents=True, exist_ok=True)
    local.free_gpu()
    subprocess.run([str(py), str(ROOT / "esteira/ai/train_lora.py"), dados, str(saida), "--base", base,
                    "--epochs", str(epocas), "--quant", quant], check=True)
    gguf = next(iter(sorted((saida / "gguf").glob("*.gguf"))), None)
    if not gguf:
        raise SystemExit("o treino não gerou GGUF")
    shutil.copy(gguf, llama.MODELS_DIR / f"{nome}.gguf")
    llama.server()
    return nome
