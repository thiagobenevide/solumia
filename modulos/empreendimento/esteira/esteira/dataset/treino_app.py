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

from esteira.dataset import exportar as X
from esteira.dataset import indice
from esteira.dataset import registro as R

BASE = "unsloth/gemma-4-12b-it"
BASE_GGUF = "gemma-4-12b-it-ud-q4_k_xl"  # a mesma base, quantizada, no roteador
MAX_B = 12  # decisão do plano: só se treinam bases de até 12B
TAREFAS_APP = {"effectcraft": ["peca_animar"], "filmcraft": ["montar", "corrigir_montagem"],
               "photocraft": ["thumb_compor", "foto_tratar"]}
SIGLA = {"effectcraft": "ec", "filmcraft": "fc", "photocraft": "pc"}


def _pasta():
    from esteira.ia import llama
    return llama.MODELOS / "adaptadores"


def bilhoes(base: str) -> float | None:
    m = re.search(r"(\d+(?:\.\d+)?)b\b", base.lower())
    return float(m.group(1)) if m else None


def _versao(app: str) -> int:
    nums = [int(m.group(1)) for a in _pasta().glob(f"{SIGLA[app]}-v*.gguf")
            if (m := re.match(rf"{SIGLA[app]}-v(\d+)\.gguf$", a.name))]
    return max(nums, default=0) + 1


def _parar_servicos() -> list[str]:
    """Para os serviços do PC que seguram VRAM durante o treino. → os que estavam ativos (religados no fim)."""
    parados = []
    for s in ("agent-worker",):
        if subprocess.run(["systemctl", "--user", "is-active", "--quiet", s]).returncode == 0:
            subprocess.run(["systemctl", "--user", "stop", s], check=False)
            parados.append(s)
    return parados


def faltam(app: str) -> dict[str, int]:
    s = indice.situacao()
    return {t: max(0, indice.MINIMO[t] - s.get(t, {}).get("sft", 0)) for t in TAREFAS_APP[app]}


def treinar(app: str, base: str = BASE, epocas: float = 2.0, forcar: bool = False) -> dict:
    from esteira.estudio import treino
    from esteira.ia import local
    from esteira.nucleo import travas
    from esteira.projeto import RAIZ
    if (b := bilhoes(base)) is None or b > MAX_B:
        raise SystemExit(f"base {base}: só se treinam modelos de até {MAX_B}B")
    if not forcar and any(faltam(app).values()):
        raise SystemExit(f"{app}: faltam casos para o mínimo de treino {faltam(app)} (use forcar só no teste)")
    py = treino.ambiente()
    if not py.exists():
        raise SystemExit("ambiente de treino ausente: ~/.local/bin/uv venv .venv-treino --python 3.12 && "
                         "~/.local/bin/uv pip install --python .venv-treino/bin/python unsloth gguf")
    exp = X.ultima() or Path(X.exportar()["pasta"])
    nome = f"{SIGLA[app]}-v{_versao(app)}"
    saida = R.PASTA / "treinos" / nome
    dados = saida / "dados"
    dados.mkdir(parents=True, exist_ok=True)
    n = 0
    for t in TAREFAS_APP[app]:
        for lado in ("train", "val"):
            arq = exp / "sft" / f"{t}.{lado}.jsonl"
            if arq.exists() and arq.stat().st_size:
                shutil.copy(arq, dados / arq.name)
                n += lado == "train" and sum(1 for _ in arq.open())
    if not n:
        raise SystemExit(f"{app}: a exportação {exp.name} não tem casos de treino")
    if "maquina" not in travas._seguras:  # o `./dark` já ocupa a vaga ao iniciar; segunda trava no mesmo processo trava
        travas.ocupar("maquina", f"treino {nome}")
    local.liberar_gpu()
    parados = _parar_servicos()  # worker da plataforma (+ voz XTTS) ocupa ~3 GB de VRAM
    try:
        subprocess.run([str(py), str(RAIZ / "esteira/ia/treinar_lora.py"), str(dados), str(saida), "--base", base,
                        "--epocas", str(epocas), "--so-adaptador"], check=True,
                       env={**__import__("os").environ, "PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True"})
    finally:
        for s in parados:
            subprocess.run(["systemctl", "--user", "start", s], check=False)
    info = json.loads((saida / "treino.json").read_text())
    destino = _pasta() / f"{nome}.gguf"
    destino.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(info["adaptador"], destino)
    from esteira.n1 import effectcraft, filmcraft, photocraft
    manifesto = {"nome": nome, "app": app, "base": base, "base_gguf": BASE_GGUF, "em": datetime.now().isoformat(),
                 "exportacao": exp.name, "hash_exportacao": X.hash_exportacao(exp), "casos_treino": n,
                 "n1": {"filmcraft": filmcraft.VERSAO, "photocraft": photocraft.VERSAO,
                        "effectcraft": effectcraft.VERSAO}[app],
                 "perda": info.get("perda"), "perda_val": info.get("perda_val"), "forcado": forcar, "promovido": False}
    destino.with_suffix(".json").write_text(json.dumps(manifesto, ensure_ascii=False, indent=1))
    return manifesto


def _base_gguf() -> Path:
    from esteira.ia import llama
    return next((llama.MODELOS / BASE_GGUF).glob("*.gguf")) if (llama.MODELOS / BASE_GGUF).is_dir() \
        else llama.MODELOS / f"{BASE_GGUF}.gguf"


def _escrever_presets(entradas: dict[str, Path]) -> None:
    from esteira.ia import llama
    base = next(p for p in _base_gguf().parent.glob("*.gguf") if not p.name.startswith("mmproj")) \
        if _base_gguf().parent.is_dir() else _base_gguf()
    linhas = ["; gerado por esteira/dataset/treino_app.py: base + adaptador LoRA por app", ""]
    for nome, adaptador in sorted(entradas.items()):
        linhas += [f"[{nome}]", f"model = {base}", f"lora = {adaptador}", ""]
    llama.PRESETS.parent.mkdir(parents=True, exist_ok=True)
    llama.PRESETS.write_text("\n".join(linhas))


def _ler_presets() -> dict[str, Path]:
    from esteira.ia import llama
    if not llama.PRESETS.exists():
        return {}
    saida, atual = {}, None
    for linha in llama.PRESETS.read_text().splitlines():
        if m := re.match(r"^\[(.+)\]$", linha.strip()):
            atual = m.group(1)
        elif atual and linha.startswith("lora = "):
            saida[atual] = Path(linha.split("=", 1)[1].strip())
    return saida


def promovido(app: str) -> str | None:
    nome = f"{SIGLA[app]}-atual"
    return nome if nome in _ler_presets() else None


def promover(app: str, nome: str, n: int | None = None) -> dict:
    """Portão de promoção: base × candidato no ouro das tarefas da app (bancada). Promove só se ganhar."""
    from esteira import bancada
    from esteira.ia import llama
    adaptador = _pasta() / f"{nome}.gguf"
    if not adaptador.exists():
        raise SystemExit(f"adaptador inexistente: {adaptador}")
    presets = _ler_presets()
    candidato = f"{nome}-candidato"
    _escrever_presets({**presets, candidato: adaptador})
    if not llama.reiniciar():
        raise SystemExit("o roteador não voltou com o preset novo")
    tarefas = [f"n1_{t}" for t in TAREFAS_APP[app] if bancada.casos(f"n1_{t}")]
    if not tarefas:
        raise SystemExit(f"{app}: sem casos no ouro para comparar")
    res = bancada.rodar([BASE_GGUF, candidato], tarefas, n)
    nota = {m: sum(x["nota"] for x in info["tarefas"].values()) / max(len(info["tarefas"]), 1)
            for m, info in res["modelos"].items()}
    ganhou = nota.get(candidato, 0) > nota.get(BASE_GGUF, 0)
    presets.pop(candidato, None)
    if ganhou:
        presets[f"{SIGLA[app]}-atual"] = adaptador
    _escrever_presets(presets)
    llama.reiniciar()
    man = adaptador.with_suffix(".json")
    if man.exists():
        d = json.loads(man.read_text())
        d.update(promovido=ganhou, bancada={"base": nota.get(BASE_GGUF), "adaptador": nota.get(candidato),
                                            "tarefas": tarefas, "em": datetime.now().isoformat()})
        man.write_text(json.dumps(d, ensure_ascii=False, indent=1))
    return {"nome": nome, "promovido": ganhou, "notas": nota}
