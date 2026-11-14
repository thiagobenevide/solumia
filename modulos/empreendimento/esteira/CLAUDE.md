# Esteira de vídeos dark

Roteiro do vault Obsidian + WAV → vídeo final (cortes, cenas, mídia, gráficos animados, FilmCraft, thumbs).
Entrada: `./dark <etapa> <projeto>` (`./dark -h` lista tudo); painel: `./dark painel`. Episódios em
`projetos/<canal>/<NNN>/` (id na CLI: `canal-NNN`); configuração: `config.toml` ← `perfis/<canal>.toml` ← `config.toml` do projeto.
Dados fora do repositório: `projetos/`, `acervo/` e `cache/` ficam em `$AGENT_DATA/empreendimento/` (padrão `~/agent-data`, ver `esteira/projeto.py`); todo caminho `projetos/...` ou `cache/...` abaixo é relativo a ela.
Para produzir um episódio, usar a skill `produzir-episodio`. Plano e decisões: `docs/PLANO.md`.
Craft Apps por N1 (`docs/PLANO-DATASET.md`): `esteira/n1/{filmcraft,photocraft,effectcraft}.py` = esquema (Pydantic → JSON
Schema/gramática) + executor/compilador N1 → comandos; `montar` e a thumb geram N1 e executam; peça EC com
`peca.n1.json` é compilada (`ec.corpo`; guia `pecas/GUIA_N1_EC.md`); fotos pela receita `[foto]` (`esteira/fotos.py`).
Dataset em `$AGENT_DATA/.../dataset/` (`esteira/dataset/`: `registro` JSONL que só cresce, `indice` SQLite, `exportar`,
`edicoes` (edição à mão → N1), `traduzir`, `inferir`, `treino_app` (LoRA por app, ≤12B, promoção pela bancada
`n1_*`)); CLI `./dark dataset [situacao|exportar|traduzir|edicoes|treinar|promover]`. Os testes usam dataset temporário (`tests/conftest.py`).
Formatos: `[video] formato = "16:9" | "9:16"` (Shorts do vault em `<canal>/Shorts/`, id `canal-NNNx`;
sobrescritas em `[vertical.*]` do `config.toml`). Citações vêm dos blocos `> [!cite]` do roteiro (PDF, página,
trecho EN, tradução PT; gerados por `.claude/scripts/artigo` no vault); sem bloco, o código tenta achar.
Modos (`[producao] modo` ou `modo:` no roteiro): `dark` (narração + bancos) ou `apresentador` (vídeo da
câmera na V1 cortado igual à narração, WAV sincronizado por correlação, B-roll dos bancos na V2 em ~45% do
tempo; `esteira/producao.py`). Mídia: `esteira/acervo.py` guarda todo download com metadados (SQLite/FTS5
em `acervo/`) e é consultado antes das APIs; notas do modelo de visão ficam no acervo e não são refeitas.
Ver com `./dark acervo [buscar termos]`, nunca abrindo `acervo.db`.
Editor do painel (`esteira/editor.py`): gráficos (dados, tempo, efeitos de entrada/saída, caixas de texto livres
com *destaque*, presets das citações do roteiro) e thumbs (texto, layout, fundo enviado, caixas, vagas A/B), com
prévia ao vivo e assistente de IA (`[editor] motor_ia`). Gráfico salvo vira `manual: true` (o replanejamento o mantém).
Monitor do painel (`/monitor`, `esteira/monitor.py` + `esteira/grafo.py`): GPU/CPU/energia e grafo da operação; o
rastro vem de `esteira/nucleo/rastro.py` (`cache/ao_vivo/<pid>.json` e `cache/rastro.jsonl`), gravado por
`local.perguntar` (stream), `claude.consultar`, `eventos.etapa` e `roteirista`. Não ler esses arquivos inteiros.
Vagas (`esteira/nucleo/travas.py`): só um `./dark` pesado por vez na máquina; `--motor claude` em `curar`/`roteiro`
usa a vaga "claude" e roda em paralelo. A fila do painel tem as duas pistas. Cada processo pesado fica em
`cache/processos.jsonl` (`esteira/nucleo/processos.py`); monitor individual em `/processos/<id>` (`esteira/monitor_processo.py`).
Opções de IA (painel → Opções, `esteira/nucleo/opcoes.py`, `cache/opcoes.json`): motor padrão local/Claude, modelo
e tetos do Claude, motor e modelo local por operação (`local.perguntar` resolve pela etapa/prompt) e download
de modelos GGUF do Hugging Face (`llama.baixar`). `--motor` explícito vale para tudo. `./dark tudo <ep> --refazer` (botão "Refazer tudo
do zero") retranscreve, refaz cortes e curadoria; com estilo do canal no Estúdio, troca
graficos+montar pelo corte pelo som + `estudio.produzir` (acervo de peças, sem os portões; para se o corte cortar palavra). Cortes: `transcrever._refinar` retranscreve regiões com palavras
esticadas (retakes que o Whisper engoliu); `cortes.repeticoes` corta retakes que sobraram na narração editada.
Bordas dos cortes caem no silêncio real (`cortes.envelope` com limiar local + `_borda_ini/_borda_fim`, pausa conforme a pontuação)
e passam pela regra de ouro de `esteira/bordas.py` (nunca dentro do núcleo de palavra mantida; tempos do alinhamento forçado
`esteira/alinhamento.py` no `.venv-img`, `[cortes] alinhamento`; palavra cortada trava o portão do corte);
números partidos pelo Whisper ("12" ",5" "%") são juntados no alinhamento (`cortes._tokens`, `cenas.alinhar`).
Gráficos de número/lista entram quando o número é DITO (`plano._instante_numero`, `ancora`); números seguidos fazem
fila (o anterior encurta). Citação: duração pelo tempo de leitura EN+PT, autor em destaque, selo "link na
descrição"; `descricao.txt` (montar) traz as fontes com DOI. Testes das regras: `tests/test_sincronia.py`.
Gaguejos de 1–3 palavras dentro da tomada saem (`cortes._gaguejos`); o comparador de pares do LLM nunca tira uma
tomada do roteiro; o fim de `cortes.txt` traz a conferência da narração editada (frases faltando/incompletas).
Claquete falada (`esteira/claquete.py`): na gravação, "Corte parte N" confirma a leitura da parte N (parágrafo do
roteiro; `./dark partes <ep>` → `partes.txt` numerado), "Cancela parte N" descarta, sem marcador não usa; vale o
último corte. Com marcadores, `cortes.aplicar` usa esse caminho; sem eles, o antigo. Narração nova (`narracao.*`
que não é a editada, ver `narracao.render.json`) manda a bruta anterior para `gravacoes_anteriores/<data>/`.
O limpar puxa sozinho o WAV mais novo do episódio em `~/Music/Youtube/<Canal>/` (`gravacoes.atualizar`, origem em
`origem_audio.json`; não no modo apresentador).
Busca de mídia: a curadoria dá `chave_en` (o que TEM de aparecer) + `alternativas`; `midia.ordenar` põe os
candidatos de todos os bancos e do acervo por relevância (chave nas tags/descrição) e vídeo sem nada relevante cai
para foto. Pixabay: `PIXABAY_API_KEY_IMAGE`/`_VIDEO`, cache de 24 h em `cache/pixabay/`, termo em inglês com lang en.
Dinamismo: todo número com unidade dito vira gráfico (`plano._numeros_da_frase`, fora do teto de cobertura);
`graficos/chaves.py` escolhe 1–2 palavras-chave por frase (LLM, prompt `chaves`) → `chaves.json` → texto com
"pop" na V3 no instante dito, fora dos gráficos; o montar dá "socos" de zoom (`_ken_burns(socos)`) nesses instantes.
Direção por bloco (padrão; `estudio/direcao.py`, embeddings em `ia/embeddings.py` na porta 8082): blocos do roteiro →
momentos → leitura → 5 candidatas do acervo → escolha → preenchimento validado; tarefa `bloco_peca` na bancada.
Estúdio (`esteira/estudio/`, plano em `docs/PLANO-ESTUDIO.md`): vídeo + estilo → corte pelo som da narração editada
(`estudio/corte.py`, `./dark estudio-corte`; emendas com reversão; tempos remapeados por `corte.palavras/frases/novo`) → portão do corte → apontamento (`estudio/apontamento.py`: cena por trecho marcada pela pessoa; confirmar libera) → `diretor` (frase/trecho →
cena do cardápio, IA local; erro volta ao modelo, 2ª falha vai ao Claude em lote) → `compilar` (HyperFrames: `kit/`
estudio.js/css + mapa + mídia curada do plano) → render na GPU → loudnorm −14 LUFS → `verificar` (folha + visão local).
Gatilhos (`estudio/gatilhos.py`, dado do estilo): padrão da fala → layout + peça + cor, prioridade menor vence; o diretor
fixa a peça do gatilho (a IA local só preenche) e `testar` decupa um roteiro sem IA (`POST /estudio/estilos/<id>/testar`).
Estilo também guarda `movimento`, `layouts`, `presenca`, `regras_cor`, `pecas` (ajuste por peça), lidos pelo kit;
`regras.filtro` = o que o canal NÃO usa (cardápio = `regras.cardapio()`); na produção vale o `modo:` do episódio e o
perfil de ritmo (`estudio/ritmo.py`: `ritmo:` do roteiro ou curto para Short, longo para o resto).
Acervo de peças (`docs/PLANO-ACERVO.md`): `estudio/pecas/<id>/` (peca.js + peca.css + ficha.json), contrato em
`estudio/pecas/GUIA.md`, esquema e portão de entrada em `estudio/peca.py` (`/api/v1/estudio/pecas`). Fábrica
(`estudio/fabrica.py`, `./dark estudio-fabrica fabrica:<pedido>`, vaga "claude"; dados em `$AGENT_DATA/.../estudio/fabrica/`):
o Claude gera peça + ficha, portão + visão local, revisão no app (aba Estúdio → Fábrica de peças). As cenas do
cardápio (`bancada.CENAS`) são peças `origem: kit` em `estudio/pecas/`; o `kit/` tem só o núcleo comum. Motor
EffectCraft das peças: `peca.jsx` + `pecas/_ec/` + `estudio/ec.py` (`GUIA_EC.md`); na produção vira WebM com alfa na
camada `#ec`; comparação e decisão de motor por intenção em `fabrica.comparacao`/`aplicar_motores`. Ampliação
contínua do acervo pelas lacunas: `fabrica.ampliar` (relógio de 15 min em `web/fila.py`; ligada no app). Render só
do bloco: `./dark estudio-bloco <ep> --bloco N` (`compilar.render_trecho` + `emendar`); troca de peça na linha do
tempo: `POST /producoes/<ep>/cenas/<id>/trocar`.
Modo apresentador (`estudio/camera.py`, estilo com `modo: apresentador`): câmera cortada igual ao áudio, rosto (OpenCV) e
layouts FULL/SPLIT/B-roll/tela por trecho, na camada `#cam` do kit. Estilo = template: fontes por papel (`estudio/fontes.py`, catálogo OFL + enviadas), legenda e intensidade
baixa/média/alta de som, motion e efeitos (`estilo.NIVEIS`; `--intensidade` por produção). Estilos são dados (`estudio/estilo.py`, `$AGENT_DATA/.../estudio/estilos/*.json`, semente `estudio/estilos/`;
cada salvamento é versão guardada em `estilos/versoes/<id>/vN.json`, ref `id@N`; exemplo de 30 s por versão em
`estudio/amostra.py`, `./dark estudio-amostra id@N`; template do episódio em `<ep>/estudio/template.json`, escolhido
na aba Roteiros; `previa.mp4` 540p ao lado de cada `final.mp4` para o player do app); Fluxo A
(`identidade.py`) = Claude propõe só dados pelas referências (pele, `regras.visual`, guia, exemplos); por vídeo, zero Claude (socorro do diretor só com `opcoes.socorro_claude`). CLI: `./dark estudio <ep>`, `estudio-instalar`,
`estudio-estilo <id>`; API em `web/api_estudio.py` (`/api/v1/estudio`); app: `lib/src/estudio/`. Motor (Node,
HyperFrames, Chromium) em `estudio/motor.py`. Bancada de LLM: `esteira/bancada.py` (`./dark bancada [gerar|rodar]`,
gabarito em `$AGENT_DATA/.../bancada/`).
Edição manual: `./dark abrir <ep>` → FilmCraft; `./dark exportar <ep>` reexporta; `montar` guarda o
`.fcproj` editado à mão como `projeto.manual-*.fcproj` antes de gerar outro.

## Divisão do trabalho

- Código (Python) primeiro; LLM local (`esteira/ia/local.py`, llama.cpp `gemma-4-12b` para texto e visão; o diretor do Estúdio usa `qwen3.8-27b` pelas Opções) para
  decisões operacionais; Claude (`esteira/ia/claude.py`, `claude -p` com teto em `[claude]`) só como
  escalonamento automático. Prompts em `esteira/ia/prompts/*.md`; respostas em cache (`cache/`).
- Toda etapa grava eventos em `<ep>/log/eventos.jsonl` (`esteira/nucleo/eventos.py`): ler com
  `./dark status` / `./dark log`, nunca o arquivo inteiro.

## Economia de tokens (prioridade)

- Ler dados do episódio só pelas visões compactas: `./dark resumo <ep> [--cenas 3,5] [--sem-texto]`,
  `./dark palavras <ep> --de S --ate S`. Editar o plano só com `./dark ajustar <ep>` (JSON Lines, um
  comando para várias cenas). Nunca Read/cat em `plano.json`, `transcricao.json`, `alinhamento.json`.
- Imagens: uma folha por vez (`revisao_NN.jpg`, `quadros.jpg`); após refazer, revisar só as cenas
  refeitas. Não extrair quadros soltos com ffmpeg.
- Código: `grep -n` e ler só o trecho necessário; não reler arquivo que acabou de ser editado.
- Respostas curtas: o que foi feito, o que falhou, próximo passo. Sem repetir saída de comandos.

## Notas técnicas

- FilmCraft via `filmcraft-cli mcp` (cliente `esteira/filmcraft.py`); IDs de clipes vêm das respostas,
  nunca fixos. 254016000000 ticks/s. `filmcraft-cli commands` lista os comandos.
- Sem `PEXELS_API_KEY`/`PIXABAY_API_KEY` no `.env` só há fotos do Openverse (200 buscas/dia).
- Transcrição: faster-whisper large-v3 na GPU (RTX 5060 Ti), libs CUDA via pip.
- Sem pip no sistema: `~/.local/bin/uv pip install --python .venv/bin/python ...` e registrar em
  `requirements.txt`.
- ffmpeg 6.1: dimensões ímpares com yuv420 abortam o processo (`malloc(): corrupted top size`).
- Gráficos: `esteira/graficos/effectcraft.jsx` monta cada peça como `.ecproj` (EffectCraft, camadas nomeadas) e
  `effectcraft-cli render` gera ProRes 4444 com alfa na V4; `.ecproj` salvo à mão é renderizado como está
  (`manual_ec`). `[graficos] motor = "html"` volta ao Chromium (`modelos/*.html`, também usados na prévia do editor).
- Thumbs: `esteira/photocraft.py` monta `.pcraft` em camadas ao lado do PNG (`[thumb] motor`); `.pcraft` salvo à mão
  refaz o PNG ao abrir a aba Thumbs. Fontes do projeto instaladas como TTF em `~/.local/share/fonts` (Inter Var,
  Playfair Display, JetBrains Mono): sem elas o EffectCraft/PhotoCraft trocam a fonte.
- Geração de imagem (thumbs): RealVisXL em `.venv-img` (PyTorch cu128), chamado por subprocesso.
- llama.cpp em modo roteador (`esteira/ia/llama.py`): um `llama-server` em :8081, compartilhado com o worker da
  plataforma, serve os GGUF de `~/agent-data/modelos` (visão = subpasta com `mmproj-*`); binário em
  `~/development/llama.cpp/build/bin`. `liberar_gpu()` antes do Whisper/SDXL (16 GB de VRAM).

## Compact instructions

Ao compactar, manter: episódio em andamento, etapa atual, cenas pendentes de revisão (ids) e decisões
de busca já tomadas. Descartar saídas de comandos e descrições de imagens já avaliadas.
