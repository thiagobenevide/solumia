# Esteira de vídeos dark

Roteiro do vault Obsidian + WAV da narração → vídeo editado, 3 thumbnails para teste A/B e projeto
editável no FilmCraft. Código + LLM local (llama.cpp) fazem o operacional; o Claude é chamado sozinho, com
teto de custo, só nos casos difíceis. Plano e decisões: `docs/PLANO.md`.

```
vault/<canal>/Roteiros/NNN.md + ~/Music/Youtube/<Canal>/.../*.wav
   │  importar   → projetos/<canal>/<NNN>/ (roteiro, capítulos, notas de cena, fontes com DOI, áudio)
   ├─ limpar     Whisper + alinhamento: tira retakes e bastidores → narracao.wav, cortes.json
   ├─ cenas      roteiro alinhado ao áudio, dividido em cenas
   ├─ curar      LLM local: busca, tipo de mídia e clima de cada cena
   ├─ buscar     mídia em paralelo (Pexels, Pixabay, Openverse)
   ├─ avaliar    visão local dá nota à mídia e troca a fraca
   ├─ graficos   HTML → ProRes com alfa: citações (página do PDF com marca-texto), números, capítulos…
   ├─ montar     FilmCraft: Ken Burns e transições por clima, cor dark, gráficos, trilha → final.mp4
   └─ thumb      conceitos (LLM) → RealVisXL → nota de impacto → Claude escolhe 3 → thumb_1..3.png
```

## Começar

Dados fora do repositório: `projetos/`, `acervo/` e `cache/` ficam em `$AGENT_DATA/empreendimento/` (padrão `~/agent-data`, ver `esteira/projeto.py`); todo caminho `projetos/...` ou `cache/...` deste README é relativo a ela.


```sh
~/.local/bin/uv venv --python 3.12 .venv
~/.local/bin/uv pip install --python .venv/bin/python -r requirements.txt
cp .env.example .env            # chaves do Pexels/Pixabay (sem elas, só fotos do Openverse)
./dark scripts finlumia        # roteiros do vault
./dark import finlumia:3      # → projetos/finlumia/003
./dark all finlumia-003        # ou pelo painel: ./dark panel → http://localhost:8765
```

Thumbs precisam do `.venv-img` (`requirements-img.txt`, PyTorch cu128). LLM local: llama.cpp em `~/development/llama.cpp` (roteador, modelos em `~/agent-data/modelos`).

## Configuração

`config.toml` (comentado) ← `perfis/<canal>.toml` (cores, transições) ← `config.toml` do episódio.

## Comandos

`./dark -h` lista tudo. Os principais:

| Comando | O que faz |
|---|---|
| `./dark import canal:NNN [--audio X.wav]` | cria `projetos/<canal>/<NNN>/` |
| `./dark all <ep>` | todas as etapas (diagnóstico automático se falhar) |
| `./dark status [<ep>]` / `./dark log <ep> [--errors]` | andamento e erros |
| `./dark clean <ep> [--redo]` | cortes; reaproveita `cortes.json` (editável no painel) |
| `./dark graphics <ep> [--render-only]` | replaneja e renderiza só o que mudou |
| `./dark summary` / `words` / `ajustar <ep>` | ver e editar o plano sem abrir o JSON |
| `./dark frames <ep>` | `quadros.jpg` com quadros do `final.mp4` |

`<ep>` é `canal-NNN` (ex.: `finlumia-003`).

## Licenças da mídia

Pexels e Pixabay: uso comercial livre. Openverse: Creative Commons comercial; os créditos ficam em
`creditos.txt`, para a descrição do vídeo.
