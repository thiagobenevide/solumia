"""Fine-tune LoRA do modelo local com a base de aprovações (roda no `.venv-treino`, que tem unsloth + trl + datasets).

Uso: python treinar_lora.py <pasta com *.train.jsonl> <pasta de saída> [--base REPO] [--epocas N] [--quant q4_k_m]
                            [--so-adaptador]
Lê os `<tarefa>.train.jsonl` / `.val.jsonl` (mensagens de chat), treina só nas respostas (o prompt da produção não é
aprendido, só a resposta certa) e salva o LoRA. Com `--so-adaptador` (padrão das Craft Apps, um adaptador por app)
converte só o adaptador para GGUF (`convert_lora_to_gguf.py` do llama.cpp), que o roteador carrega sobre a base com
`lora` no preset; sem ele, exporta o modelo mesclado (fluxo antigo). Bases até 12B (decisão do plano).
Montar o ambiente uma vez:
    ~/.local/bin/uv venv .venv-treino --python 3.12 && ~/.local/bin/uv pip install --python .venv-treino/bin/python unsloth
"""
import argparse
import glob
import json
import os


# partes do template de chat que marcam a fala da pessoa e a do modelo (treino só na resposta)
TEMPLATES = {"gemma-4": ("<|turn>user\n", "<|turn>model\n"),
             "gemma": ("<start_of_turn>user\n", "<start_of_turn>model\n"),
             "qwen": ("<|im_start|>user\n", "<|im_start|>assistant\n"),
             "llama": ("<|start_header_id|>user<|end_header_id|>\n\n",
                       "<|start_header_id|>assistant<|end_header_id|>\n\n")}


def familia(base: str) -> str:
    b = base.lower()
    for f in TEMPLATES:
        if f in b:
            return f
    raise SystemExit(f"template de chat desconhecido para {base}: acrescente em TEMPLATES")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dados")
    ap.add_argument("saida")
    ap.add_argument("--base", default="unsloth/gemma-4-12b-it")
    ap.add_argument("--epocas", type=float, default=2.0)
    ap.add_argument("--quant", default="q4_k_m")
    ap.add_argument("--contexto", type=int, default=4096)
    ap.add_argument("--so-adaptador", action="store_true")
    ap.add_argument("--llama-cpp", default=os.path.expanduser("~/development/llama.cpp"))
    a = ap.parse_args()

    from datasets import load_dataset
    from trl import SFTConfig, SFTTrainer
    from unsloth import FastLanguageModel

    treino = sorted(glob.glob(os.path.join(a.dados, "*.train.jsonl")))
    val = [f for f in sorted(glob.glob(os.path.join(a.dados, "*.val.jsonl"))) if os.path.getsize(f)]
    treino = [f for f in treino if os.path.getsize(f)]
    if not treino:
        raise SystemExit("exportação sem casos de treino")
    modelo, tok = FastLanguageModel.from_pretrained(a.base, max_seq_length=a.contexto, load_in_4bit=True)
    modelo = FastLanguageModel.get_peft_model(
        modelo, r=16, lora_alpha=16, lora_dropout=0, bias="none", use_gradient_checkpointing="unsloth", random_state=3407,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"])
    arquivos = {"train": treino, **({"validation": val} if val else {})}
    ds = load_dataset("json", data_files=arquivos)
    ds = ds.map(lambda x: {"text": tok.apply_chat_template(x["messages"], tokenize=False)})
    import inspect  # o trl/transformers trocam nomes entre versões: só passa o que a versão instalada aceita
    aceitos = inspect.signature(SFTConfig.__init__).parameters
    kw = {"output_dir": os.path.join(a.saida, "passos"), "dataset_text_field": "text",
          ("max_length" if "max_length" in aceitos else "max_seq_length"): a.contexto,
          "per_device_train_batch_size": 1, "gradient_accumulation_steps": 8, "num_train_epochs": a.epocas,
          "learning_rate": 2e-4, "warmup_ratio": 0.05, "logging_steps": 10, "optim": "adamw_8bit", "seed": 3407,
          "report_to": "none", ("eval_strategy" if "eval_strategy" in aceitos else "evaluation_strategy"):
              "epoch" if val else "no"}
    if "warmup_ratio" not in aceitos:
        kw.pop("warmup_ratio")
        kw["warmup_steps"] = 5
    fora = [k for k in kw if k not in aceitos]
    if fora:
        print(f"aviso: parâmetros ignorados pela versão instalada: {fora}")
    cfg = SFTConfig(**{k: v for k, v in kw.items() if k in aceitos})
    tok_arg = "processing_class" if "processing_class" in inspect.signature(SFTTrainer.__init__).parameters else "tokenizer"
    trainer = SFTTrainer(model=modelo, train_dataset=ds["train"], eval_dataset=ds.get("validation"), args=cfg,
                         **{tok_arg: tok})
    try:  # treina só na resposta do modelo (o prompt da produção não é aprendido)
        from unsloth.chat_templates import train_on_responses_only
        inst, resp = TEMPLATES[familia(a.base)]
        trainer = train_on_responses_only(trainer, instruction_part=inst, response_part=resp)
    except Exception as e:  # noqa: BLE001 — outro template de chat: treina no texto inteiro
        print(f"aviso: treino no texto inteiro ({e})")
    r = trainer.train()
    lora = os.path.join(a.saida, "lora")
    modelo.save_pretrained(lora)
    tok.save_pretrained(lora)
    adaptador = None
    if a.so_adaptador:
        import subprocess
        import sys
        adaptador = os.path.join(a.saida, "adaptador.gguf")
        subprocess.run([sys.executable, os.path.join(a.llama_cpp, "convert_lora_to_gguf.py"), "--outfile", adaptador,
                        "--outtype", "f16", "--base-model-id", a.base, lora], check=True)
    else:
        modelo.save_pretrained_gguf(os.path.join(a.saida, "gguf"), tok, quantization_method=a.quant)
    perda_val = None
    if val:
        perda_val = trainer.evaluate().get("eval_loss")
    with open(os.path.join(a.saida, "treino.json"), "w") as f:
        json.dump({"base": a.base, "epocas": a.epocas, "arquivos": arquivos, "perda": r.training_loss,
                   "perda_val": perda_val, "adaptador": adaptador}, f, indent=1)
    print(f"ok perda {r.training_loss:.4f}")


if __name__ == "__main__":
    main()
