"""Opções escolhidas no painel (menu Opções), guardadas em `cache/opcoes.json` e lidas por todo `./dark`:

- `motor`: quem faz as tarefas de LLM por padrão. "local" (llama.cpp na GPU, Claude só como escalonamento) ou
  "claude" (toda pergunta de LLM vai ao Claude; Whisper, SDXL e render continuam na máquina). `--motor` na
  linha de comando tem prioridade.
- `operacoes`: por operação (cortes, curadoria, avaliação…), o motor ("padrao", "local", "claude") e o modelo
  local de texto e/ou de visão. Vazio = o padrão (`local.TEXTO` / `local.VISAO`).
- `modelo_claude` e os tetos de custo: sobrepõem `[claude]` do config.toml.
"""
import json

from esteira.projeto import CACHE

ARQ = CACHE / "opcoes.json"
MODELOS = [("claude-sonnet-5-5", "Sonnet 5.5", "equilíbrio entre qualidade e custo"),
           ("claude-opus-5-5", "Opus 5.5", "mais capaz, mais caro"),
           ("claude-haiku-5-5", "Haiku 5.5", "mais rápido e barato"),
           ("claude-fable-5-1", "Fable 5.1", "")]
# operação → (nome, o que o LLM faz nela, tipos de modelo que ela usa)
OPERACOES = {
    "limpar": ("Cortes da narração", "decide se trechos em dúvida (improviso, retake) ficam ou saem", ["texto"]),
    "curar": ("Curadoria", "termo de busca, tipo de mídia e clima de cada cena", ["texto"]),
    "avaliar": ("Avaliação visual", "dá nota à mídia de cada cena olhando o quadro", ["visao"]),
    "graficos": ("Gráficos animados", "acha números, citações e notas que viram gráfico", ["texto"]),
    "thumb": ("Thumbnail", "cria os conceitos (texto) e avalia as thumbs prontas (visão)", ["texto", "visao"]),
    "acervo": ("Descrição do acervo", "descreve as imagens baixadas para reaproveitar depois", ["visao"]),
    "roteiro": ("Roteiros", "escreve os roteiros do vault a partir das fontes", ["texto"]),
    "editor": ("Assistente do editor", "sugere textos e ajustes no editor de gráficos e thumbs", ["texto"]),
    "estudio_cena": ("Estúdio · diretor", "escolhe a cena de cada frase seguindo o estilo do canal", ["texto"]),
    "direcao": ("Estúdio · direção por bloco", "lê cada bloco, escolhe 1 de 5 peças do acervo e preenche os encaixes",
                ["texto"]),
    "estudio_visao": ("Estúdio · conferência", "confere os quadros do vídeo final (texto cortado, sobreposição…)", ["visao"]),
}
# sugestões para baixar (Hugging Face → llama.cpp, `usuario/repo:QUANT`); cabem nos 16 GB de VRAM. Qualquer repo
# GGUF do Hugging Face também vale; com projetor (mmproj) o modelo lê imagens.
SUGESTOES = [("unsloth/gemma-4-12b-it-GGUF:UD-Q4_K_XL", "texto e visão", "melhor equilíbrio na bancada (rápido, lê imagens)"),
             ("unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL", "texto e visão", "o que mais acerta na bancada, mais lento (parte na RAM)"),
             ("unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q3_K_XL", "texto e visão", "MoE: bom no corte e na legenda"),
             ("unsloth/Qwen3-14B-GGUF:Q4_K_M", "texto", "padrão antigo de texto (qwen3-14b)"),
             ("unsloth/Qwen3-8B-GGUF:Q4_K_M", "texto", "mais rápido, um pouco pior"),
             ("ggml-org/gemma-3-12b-it-GGUF:Q4_K_M", "texto e visão", "Google, lê imagens"),
             ("unsloth/phi-4-GGUF:Q4_K_M", "texto", "Microsoft"),
             ("ggml-org/Qwen2.5-VL-7B-Instruct-GGUF:Q4_K_M", "visão", "padrão atual de visão (qwen2.5vl-7b)"),
             ("ggml-org/MiniCPM-V-2_6-GGUF:Q4_K_M", "visão", "leve")]
# direcao: "blocos" (direção nova por bloco, acervo de peças; docs/PLANO-ACERVO.md) ou "frases" (diretor antigo)
# socorro_claude: o diretor do Estúdio manda ao Claude o que a IA local errou duas vezes (desligado = regra fixa, custo zero)
PADRAO = {"motor": "local", "modelo_claude": None, "teto_episodio_usd": None, "teto_dia_usd": None, "operacoes": {},
          "socorro_claude": False, "direcao": "blocos",
          "limite_cota": None}  # fração da cota da assinatura em que a esteira para de chamar o Claude (None = 0,90)


def ler():
    try:
        return {**PADRAO, **json.loads(ARQ.read_text())}
    except (OSError, ValueError):
        return json.loads(json.dumps(PADRAO))


def salvar(**novas):
    d = ler()
    d.update({k: v for k, v in novas.items() if k in PADRAO})
    ARQ.parent.mkdir(exist_ok=True)
    ARQ.write_text(json.dumps(d, ensure_ascii=False, indent=1))
    return d


def operacao(op):
    """{"motor": "padrao"|"local"|"claude", "texto": modelo|None, "visao": modelo|None} da operação."""
    return {"motor": "padrao", "texto": None, "visao": None, **(ler()["operacoes"].get(op) or {})}


def claude(c):
    """`[claude]` do config com as escolhas do painel por cima."""
    o = ler()
    c = dict(c)
    if o["modelo_claude"]:
        c["modelo"] = o["modelo_claude"]
    for k in ("teto_episodio_usd", "teto_dia_usd"):
        if o[k] is not None:
            c[k] = o[k]
    return c
