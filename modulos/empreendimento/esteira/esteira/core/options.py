"""Options chosen in the panel (Options menu), stored in `cache/options.json` and read by every `./dark`:

- `engine`: who does the LLM tasks by default. "local" (llama.cpp on the GPU, Claude only as escalation) or
  "claude" (every LLM question goes to Claude; Whisper, SDXL and render stay on the machine). `--motor` on the
  command line takes priority.
- `operations`: per operation (cuts, curation, evaluation…), the engine ("default", "local", "claude") and the
  local text and/or vision model. Empty = the default (`local.TEXTO` / `local.VISAO`).
- `claude_model` and the cost caps: override `[claude]` from config.toml.

The operation ids are the stage names and the labels/descriptions are panel text (pt-BR).
"""
import contextlib
import json

from esteira.projeto import CACHE

FILE = CACHE / "options.json"
MODELS = [("claude-sonnet-5-5", "Sonnet 5.5", "equilíbrio entre qualidade e custo"),
          ("claude-opus-5-5", "Opus 5.5", "mais capaz, mais caro"),
          ("claude-haiku-5-5", "Haiku 5.5", "mais rápido e barato"),
          ("claude-fable-5-1", "Fable 5.1", "")]
# operation → (name, what the LLM does in it, model kinds it uses)
OPERATIONS = {
    "limpar": ("Cortes da narração", "decide se trechos em dúvida (improviso, retake) ficam ou saem", ["text"]),
    "curar": ("Curadoria", "termo de busca, tipo de mídia e clima de cada cena", ["text"]),
    "avaliar": ("Avaliação visual", "dá nota à mídia de cada cena olhando o quadro", ["vision"]),
    "graficos": ("Gráficos animados", "acha números, citações e notas que viram gráfico", ["text"]),
    "thumb": ("Thumbnail", "cria os conceitos (texto) e avalia as thumbs prontas (visão)", ["text", "vision"]),
    "acervo": ("Descrição do acervo", "descreve as imagens baixadas para reaproveitar depois", ["vision"]),
    "roteiro": ("Roteiros", "escreve os roteiros do vault a partir das fontes", ["text"]),
    "editor": ("Assistente do editor", "sugere textos e ajustes no editor de gráficos e thumbs", ["text"]),
    "estudio_cena": ("Estúdio · diretor", "escolhe a cena de cada frase seguindo o estilo do canal", ["text"]),
    "direcao": ("Estúdio · direção por bloco", "lê cada bloco, escolhe 1 de 5 peças do acervo e preenche os encaixes",
                ["text"]),
    "estudio_visao": ("Estúdio · conferência", "confere os quadros do vídeo final (texto cortado, sobreposição…)", ["vision"]),
}
# download suggestions (Hugging Face → llama.cpp, `user/repo:QUANT`); they fit in 16 GB of VRAM. Any Hugging Face
# GGUF repo also works; with a projector (mmproj) the model reads images.
SUGGESTIONS = [("unsloth/gemma-4-12b-it-GGUF:UD-Q4_K_XL", "texto e visão", "melhor equilíbrio na bancada (rápido, lê imagens)"),
               ("unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL", "texto e visão", "o que mais acerta na bancada, mais lento (parte na RAM)"),
               ("unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q3_K_XL", "texto e visão", "MoE: bom no corte e na legenda"),
               ("unsloth/Qwen3-14B-GGUF:Q4_K_M", "texto", "padrão antigo de texto (qwen3-14b)"),
               ("unsloth/Qwen3-8B-GGUF:Q4_K_M", "texto", "mais rápido, um pouco pior"),
               ("ggml-org/gemma-3-12b-it-GGUF:Q4_K_M", "texto e visão", "Google, lê imagens"),
               ("unsloth/phi-4-GGUF:Q4_K_M", "texto", "Microsoft"),
               ("ggml-org/Qwen2.5-VL-7B-Instruct-GGUF:Q4_K_M", "visão", "padrão atual de visão (qwen2.5vl-7b)"),
               ("ggml-org/MiniCPM-V-2_6-GGUF:Q4_K_M", "visão", "leve")]
# direction: "blocks" (new per-block direction, piece library; docs/PLANO-ACERVO.md) or "sentences" (old director)
# claude_fallback: the Studio director sends Claude what the local AI got wrong twice (off = fixed rule, zero cost)
# quota_limit: fraction of the subscription quota at which the pipeline stops calling Claude (None = 0.90)
DEFAULT = {"engine": "local", "claude_model": None, "episode_cap_usd": None, "daily_cap_usd": None, "operations": {},
           "claude_fallback": False, "direction": "blocks", "quota_limit": None}
# option key → key of `[claude]` in config.toml
_CLAUDE_CONFIG_KEYS = {"claude_model": "modelo", "episode_cap_usd": "teto_episodio_usd", "daily_cap_usd": "teto_dia_usd"}


def read():
    options = json.loads(json.dumps(DEFAULT))
    with contextlib.suppress(OSError, ValueError):
        options.update(json.loads(FILE.read_text()))
    return options


def save(**new):
    options = read()
    for key, value in new.items():
        if key in DEFAULT:
            options[key] = value
    FILE.parent.mkdir(exist_ok=True)
    FILE.write_text(json.dumps(options, ensure_ascii=False, indent=1))
    return options


def operation(op):
    """{"engine": "default"|"local"|"claude", "text": model|None, "vision": model|None} of the operation."""
    chosen = {"engine": "default", "text": None, "vision": None}
    chosen.update(read()["operations"].get(op) or {})
    return chosen


def claude(config):
    """`[claude]` from the config with the panel choices on top."""
    options = read()
    config = dict(config)
    if options["claude_model"]:
        config["modelo"] = options["claude_model"]
    for key in ("episode_cap_usd", "daily_cap_usd"):
        if options[key] is not None:
            config[_CLAUDE_CONFIG_KEYS[key]] = options[key]
    return config
