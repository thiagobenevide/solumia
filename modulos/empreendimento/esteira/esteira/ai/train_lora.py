"""LoRA fine-tune of the local model on the approvals base (runs in `.venv-treino`, which has unsloth + trl + datasets).

Usage: python train_lora.py <folder with *.train.jsonl> <output folder> [--base REPO] [--epochs N] [--quant q4_k_m]
                            [--adapter-only]
Reads the `<task>.train.jsonl` / `.val.jsonl` (chat messages), trains only on the answers (the production prompt is
not learned, only the right answer) and saves the LoRA. With `--adapter-only` (default of the Craft Apps, one
adapter per app) it converts only the adapter to GGUF (`convert_lora_to_gguf.py` from llama.cpp), which the router
loads over the base with `lora` in the preset; without it, it exports the merged model (old flow). Bases up to 12B
(decision of the plan). Set up the environment once:
    ~/.local/bin/uv venv .venv-treino --python 3.12 && ~/.local/bin/uv pip install --python .venv-treino/bin/python unsloth
"""
import argparse
import glob
import json
import os


# parts of the chat template that mark the user turn and the model turn (training only on the answer)
TEMPLATES = {"gemma-4": ("<|turn>user\n", "<|turn>model\n"),
             "gemma": ("<start_of_turn>user\n", "<start_of_turn>model\n"),
             "qwen": ("<|im_start|>user\n", "<|im_start|>assistant\n"),
             "llama": ("<|start_header_id|>user<|end_header_id|>\n\n",
                       "<|start_header_id|>assistant<|end_header_id|>\n\n")}


def family(base: str) -> str:
    b = base.lower()
    for f in TEMPLATES:
        if f in b:
            return f
    raise SystemExit(f"unknown chat template for {base}: add it to TEMPLATES")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data")
    ap.add_argument("output")
    ap.add_argument("--base", default="unsloth/gemma-4-12b-it")
    ap.add_argument("--epochs", type=float, default=2.0)
    ap.add_argument("--quant", default="q4_k_m")
    ap.add_argument("--context", type=int, default=4096)
    ap.add_argument("--adapter-only", action="store_true")
    ap.add_argument("--llama-cpp", default=os.path.expanduser("~/development/llama.cpp"))
    a = ap.parse_args()

    from datasets import load_dataset
    from trl import SFTConfig, SFTTrainer
    from unsloth import FastLanguageModel

    train_files = sorted(glob.glob(os.path.join(a.data, "*.train.jsonl")))
    val = [f for f in sorted(glob.glob(os.path.join(a.data, "*.val.jsonl"))) if os.path.getsize(f)]
    train_files = [f for f in train_files if os.path.getsize(f)]
    if not train_files:
        raise SystemExit("export without training cases")
    model, tok = FastLanguageModel.from_pretrained(a.base, max_seq_length=a.context, load_in_4bit=True)
    model = FastLanguageModel.get_peft_model(
        model, r=16, lora_alpha=16, lora_dropout=0, bias="none", use_gradient_checkpointing="unsloth", random_state=3407,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"])
    files = {"train": train_files, **({"validation": val} if val else {})}
    ds = load_dataset("json", data_files=files)
    ds = ds.map(lambda x: {"text": tok.apply_chat_template(x["messages"], tokenize=False)})
    import inspect  # trl/transformers rename things across versions: pass only what the installed version accepts
    accepted = inspect.signature(SFTConfig.__init__).parameters
    kw = {"output_dir": os.path.join(a.output, "steps"), "dataset_text_field": "text",
          ("max_length" if "max_length" in accepted else "max_seq_length"): a.context,
          "per_device_train_batch_size": 1, "gradient_accumulation_steps": 8, "num_train_epochs": a.epochs,
          "learning_rate": 2e-4, "warmup_ratio": 0.05, "logging_steps": 10, "optim": "adamw_8bit", "seed": 3407,
          "report_to": "none", ("eval_strategy" if "eval_strategy" in accepted else "evaluation_strategy"):
              "epoch" if val else "no"}
    if "warmup_ratio" not in accepted:
        kw.pop("warmup_ratio")
        kw["warmup_steps"] = 5
    ignored = [k for k in kw if k not in accepted]
    if ignored:
        print(f"warning: parameters ignored by the installed version: {ignored}")
    cfg = SFTConfig(**{k: v for k, v in kw.items() if k in accepted})
    tok_arg = "processing_class" if "processing_class" in inspect.signature(SFTTrainer.__init__).parameters else "tokenizer"
    trainer = SFTTrainer(model=model, train_dataset=ds["train"], eval_dataset=ds.get("validation"), args=cfg,
                         **{tok_arg: tok})
    try:  # trains only on the model answer (the production prompt is not learned)
        from unsloth.chat_templates import train_on_responses_only
        inst, resp = TEMPLATES[family(a.base)]
        trainer = train_on_responses_only(trainer, instruction_part=inst, response_part=resp)
    except Exception as e:  # noqa: BLE001 — another chat template: trains on the whole text
        print(f"warning: training on the whole text ({e})")
    r = trainer.train()
    lora = os.path.join(a.output, "lora")
    model.save_pretrained(lora)
    tok.save_pretrained(lora)
    adapter = None
    if a.adapter_only:
        import subprocess
        import sys
        adapter = os.path.join(a.output, "adapter.gguf")
        subprocess.run([sys.executable, os.path.join(a.llama_cpp, "convert_lora_to_gguf.py"), "--outfile", adapter,
                        "--outtype", "f16", "--base-model-id", a.base, lora], check=True)
    else:
        model.save_pretrained_gguf(os.path.join(a.output, "gguf"), tok, quantization_method=a.quant)
    val_loss = None
    if val:
        val_loss = trainer.evaluate().get("eval_loss")
    with open(os.path.join(a.output, "training.json"), "w") as f:
        json.dump({"base": a.base, "epochs": a.epochs, "files": files, "loss": r.training_loss,
                   "val_loss": val_loss, "adapter": adapter}, f, indent=1)
    print(f"ok loss {r.training_loss:.4f}")


if __name__ == "__main__":
    main()
