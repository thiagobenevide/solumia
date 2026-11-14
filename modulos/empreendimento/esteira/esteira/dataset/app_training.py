"""Fine-tuning das Craft Apps (`docs/PLANO-DATASET.md` §5 e F7): um adaptador LoRA por app sobre uma base de até
12B, treinado com a última exportação do dataset, e promovido só se ganhar da base no ouro.

- `treinar(app)`: junta os SFT das tarefas da app, treina no `.venv-treino` (vaga pesada da máquina, llama-server
  parado), converte só o adaptador para GGUF e grava `~/agent-data/modelos/adaptadores/<app>-vN.gguf` + manifesto
  (hash da exportação, base, versão do N1, perdas). `forcar=True` ignora o mínimo de casos (teste de fumaça).
- `promover(app, nome)`: o adaptador entra no preset do roteador como candidato; a bancada mede base × candidato nas
  tarefas N1 da app; só com nota maior ele vira `<app>-atual` (o que `inferir.gerar` usa). O backup copia
  `modelos/adaptadores/`.
"""
import json
import re
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

from esteira.dataset import export as X
from esteira.dataset import index
from esteira.dataset import registry as R

BASE = "unsloth/gemma-4-12b-it"
BASE_GGUF = "gemma-4-12b-it-ud-q4_k_xl"  # a mesma base, quantizada, no roteador
MAX_B = 12  # decisão do plano: só se treinam bases de até 12B
TASKS_APP = {"effectcraft": ["peca_animar"], "filmcraft": ["montar", "corrigir_montagem"],
               "photocraft": ["thumb_compor", "foto_tratar"]}
ACRONYM = {"effectcraft": "ec", "filmcraft": "fc", "photocraft": "pc"}


def _folder():
    from esteira.ai import llama
    return llama.MODELS_DIR / "adaptadores"


def billions(base: str) -> float | None:
    m = re.search(r"(\d+(?:\.\d+)?)b\b", base.lower())
    return float(m.group(1)) if m else None


def _version(app: str) -> int:
    nums = [int(m.group(1)) for a in _folder().glob(f"{ACRONYM[app]}-v*.gguf")
            if (m := re.match(rf"{ACRONYM[app]}-v(\d+)\.gguf$", a.name))]
    return max(nums, default=0) + 1


def _stop_services() -> list[str]:
    """Para os serviços do PC que seguram VRAM durante o treino. → os que estavam ativos (religados no fim)."""
    stopped = []
    for s in ("agent-worker",):
        if subprocess.run(["systemctl", "--user", "is-active", "--quiet", s]).returncode == 0:
            subprocess.run(["systemctl", "--user", "stop", s], check=False)
            stopped.append(s)
    return stopped


def missing(app: str) -> dict[str, int]:
    s = index.status()
    return {t: max(0, index.MINIMUM[t] - s.get(t, {}).get("sft", 0)) for t in TASKS_APP[app]}


def train(app: str, base: str = BASE, epochs: float = 2.0, forcar: bool = False) -> dict:
    from esteira.core import locks
    from esteira.studio import training
    from esteira.ai import local
    from esteira.project import ROOT
    if (b := billions(base)) is None or b > MAX_B:
        raise SystemExit(f"base {base}: só se treinam modelos de até {MAX_B}B")
    if not forcar and any(missing(app).values()):
        raise SystemExit(f"{app}: faltam casos para o mínimo de treino {missing(app)} (use forcar só no teste)")
    py = training.environment()
    if not py.exists():
        raise SystemExit("ambiente de treino ausente: ~/.local/bin/uv venv .venv-treino --python 3.12 && "
                         "~/.local/bin/uv pip install --python .venv-treino/bin/python unsloth gguf")
    exp = X.last() or Path(X.export()["pasta"])
    name = f"{ACRONYM[app]}-v{_version(app)}"
    output = R.FOLDER / "treinos" / name
    data = output / "dados"
    data.mkdir(parents=True, exist_ok=True)
    n = 0
    for t in TASKS_APP[app]:
        for side in ("train", "val"):
            file = exp / "sft" / f"{t}.{side}.jsonl"
            if file.exists() and file.stat().st_size:
                shutil.copy(file, data / file.name)
                n += side == "train" and sum(1 for _ in file.open())
    if not n:
        raise SystemExit(f"{app}: a exportação {exp.name} não tem casos de treino")
    if "machine" not in locks._held:  # o `./dark` já ocupa a vaga ao iniciar; segunda trava no mesmo processo trava
        locks.acquire("machine", f"treino {name}")
    local.free_gpu()
    stopped = _stop_services()  # worker da plataforma (+ voz XTTS) ocupa ~3 GB de VRAM
    try:
        subprocess.run([str(py), str(ROOT / "esteira/ai/train_lora.py"), str(data), str(output), "--base", base,
                        "--epochs", str(epochs), "--adapter-only"], check=True,
                       env={**__import__("os").environ, "PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True"})
    finally:
        for s in stopped:
            subprocess.run(["systemctl", "--user", "start", s], check=False)
    info = json.loads((output / "training.json").read_text())
    destination = _folder() / f"{name}.gguf"
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(info["adapter"], destination)
    from esteira.n1 import effectcraft, filmcraft, photocraft
    manifesto = {"nome": name, "app": app, "base": base, "base_gguf": BASE_GGUF, "em": datetime.now().isoformat(),
                 "exportacao": exp.name, "hash_exportacao": X.hash_export(exp), "casos_treino": n,
                 "n1": {"filmcraft": filmcraft.VERSION, "photocraft": photocraft.VERSION,
                        "effectcraft": effectcraft.VERSION}[app],
                 "perda": info.get("loss"), "perda_val": info.get("val_loss"), "forcado": forcar, "promovido": False}
    destination.with_suffix(".json").write_text(json.dumps(manifesto, ensure_ascii=False, indent=1))
    return manifesto


def _base_gguf() -> Path:
    from esteira.ai import llama
    return next((llama.MODELS_DIR / BASE_GGUF).glob("*.gguf")) if (llama.MODELS_DIR / BASE_GGUF).is_dir() \
        else llama.MODELS_DIR / f"{BASE_GGUF}.gguf"


def _write_presets(inputs: dict[str, Path]) -> None:
    from esteira.ai import llama
    base = next(p for p in _base_gguf().parent.glob("*.gguf") if not p.name.startswith("mmproj")) \
        if _base_gguf().parent.is_dir() else _base_gguf()
    lines = ["; gerado por esteira/dataset/app_training.py: base + adaptador LoRA por app", ""]
    for name, adapter in sorted(inputs.items()):
        lines += [f"[{name}]", f"model = {base}", f"lora = {adapter}", ""]
    llama.PRESETS.parent.mkdir(parents=True, exist_ok=True)
    llama.PRESETS.write_text("\n".join(lines))


def _read_presets() -> dict[str, Path]:
    from esteira.ai import llama
    if not llama.PRESETS.exists():
        return {}
    output, current = {}, None
    for line in llama.PRESETS.read_text().splitlines():
        if m := re.match(r"^\[(.+)\]$", line.strip()):
            current = m.group(1)
        elif current and line.startswith("lora = "):
            output[current] = Path(line.split("=", 1)[1].strip())
    return output


def promoted(app: str) -> str | None:
    name = f"{ACRONYM[app]}-atual"
    return name if name in _read_presets() else None


def promote(app: str, nome: str, n: int | None = None) -> dict:
    """Portão de promoção: base × candidato no ouro das tarefas da app (bancada). Promove só se ganhar."""
    from esteira import bench
    from esteira.ai import llama
    adapter = _folder() / f"{nome}.gguf"
    if not adapter.exists():
        raise SystemExit(f"adaptador inexistente: {adapter}")
    presets = _read_presets()
    candidate = f"{nome}-candidato"
    _write_presets({**presets, candidate: adapter})
    if not llama.restart():
        raise SystemExit("o roteador não voltou com o preset novo")
    tasks = [f"n1_{t}" for t in TASKS_APP[app] if bench.cases(f"n1_{t}")]
    if not tasks:
        raise SystemExit(f"{app}: sem casos no ouro para comparar")
    res = bench.run([BASE_GGUF, candidate], tasks, n)
    note = {m: sum(x["nota"] for x in info["tarefas"].values()) / max(len(info["tarefas"]), 1)
            for m, info in res["modelos"].items()}
    won = note.get(candidate, 0) > note.get(BASE_GGUF, 0)
    presets.pop(candidate, None)
    if won:
        presets[f"{ACRONYM[app]}-atual"] = adapter
    _write_presets(presets)
    llama.restart()
    man = adapter.with_suffix(".json")
    if man.exists():
        d = json.loads(man.read_text())
        d.update(promovido=won, bancada={"base": note.get(BASE_GGUF), "adaptador": note.get(candidate),
                                            "tarefas": tasks, "em": datetime.now().isoformat()})
        man.write_text(json.dumps(d, ensure_ascii=False, indent=1))
    return {"nome": nome, "promovido": won, "notas": note}
