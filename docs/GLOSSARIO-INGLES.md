# Glossário da migração para inglês

Fonte única dos nomes em inglês dos contratos (chaves JSON, rotas, comandos da CLI, campos gravados em
disco). Todo módulo migrado usa estes nomes; termo novo entra aqui antes de entrar no código.

Regra: motor (código, JSON, rotas, prompts, comandos MCP) em inglês; conteúdo (corpo das notas, texto
na tela do vídeo) no idioma do usuário — pt-BR no canal, traduzido no momento final da escrita.

Dados gravados (`$AGENT_DATA`) com chaves antigas passam por um script de migração por módulo
(`python -m <modulo>.migrate_english`), que reescreve os arquivos uma vez; o código novo não lê as chaves
antigas.

## Esteira — etapas (comandos `./dark <etapa>` e chave `etapa` → `stage`)

| pt | en |
|---|---|
| transcrever | transcribe |
| limpar | clean |
| cenas | scenes |
| curar | curate |
| buscar | fetch |
| avaliar | evaluate |
| graficos | graphics |
| montar | assemble |
| quadros | frames |
| thumb | thumb |
| roteiro | script |
| partes | parts |
| tudo | all |
| revisar | review |
| resumo, palavras, ajustar | summary, words, adjust |
| abrir, exportar, importar | open, export, import |
| roteiros | scripts |
| acervo (`buscar`, `importar`, `descrever`) | library (`search`, `import`, `describe`) |
| painel | panel |
| estudio, estudio-corte, estudio-instalar | studio, studio-cut, studio-install |
| estudio-estilo, estudio-fabrica, estudio-amostra | studio-style, studio-factory, studio-sample |
| estudio-peca-previa, estudio-prova-canais, estudio-bloco | studio-piece-preview, studio-channel-proof, studio-block |
| treino (`exportar`, `treinar`) | training (`export`, `train`) |
| bancada (`ver`, `gerar`, `rodar`) | bench (`show`, `generate`, `run`) |
| dataset (`situacao`, `reindexar`, `exportar`, `traduzir`, `edicoes`, `treinar`, `promover`) | dataset (`status`, `reindex`, `export`, `translate`, `edits`, `train`, `promote`) |

Flags: `--refazer` → `--redo`, `--motor` → `--engine`, `--cenas` → `--scenes`, `--so-render` → `--render-only`,
`--sem-exportar` → `--no-export`, `--sem-texto` → `--no-text`, `--de`/`--ate` → `--from`/`--to`, `--estilo(s)` →
`--style(s)`, `--formato(s)` → `--format(s)`, `--etapas` → `--stages`, `--etapa` → `--stage`, `--sem-portao` →
`--no-gate`, `--intensidade` → `--intensity`, `--nicho` → `--niche`, `--sem-visao` → `--no-vision`, `--bloco` →
`--block`, `--epocas` → `--epochs`, `--tarefas` → `--tasks`, `--modelos` → `--models`, `--forcar` → `--force`,
`--nome` → `--name`, `--modo` → `--mode`, `--erros` → `--errors`, `--porta` → `--port`.

Ids das operações nas opções (`operations`): os das etapas acima mais `acervo` → `library`, `estudio_cena` →
`studio_scene`, `direcao` → `direction`, `estudio_visao` → `studio_vision`, `fabrica` → `factory`.
Variáveis de ambiente: `ESTEIRA_MOTOR` → `ESTEIRA_ENGINE`, `ESTEIRA_MOTOR_FIXO` → `ESTEIRA_ENGINE_FIXED`,
`ESTEIRA_VAGA` → `ESTEIRA_SLOT`.

## Esteira — núcleo (`esteira/nucleo/` → `esteira/core/`)

| pt | en | onde |
|---|---|---|
| vaga (`maquina`, `claude`) | slot (`machine`, `claude`) | travas → `locks.py` |
| comando, desde, proc | command, since, process | dono da vaga, processos |
| motor (`local`, `claude`, `padrao`) | engine (`local`, `claude`, `default`) | opções, processos |
| modelo_claude | claude_model | `cache/opcoes.json` → `cache/options.json` |
| teto_episodio_usd / teto_dia_usd | episode_cap_usd / daily_cap_usd | opções |
| operacoes | operations | opções |
| texto / visao (tipo de modelo) | text / vision | opções |
| socorro_claude | claude_fallback | opções |
| direcao (`blocos`, `frases`) | direction (`blocks`, `sentences`) | opções |
| limite_cota | quota_limit | opções |
| estado (`rodando`, `ok`, `erro`, `cancelado`, `interrompido`, `abortado`) | state (`running`, `ok`, `error`, `cancelled`, `interrupted`, `aborted`) | processos, status |
| ev / tipo (`inicio`, `fim`, `progresso`, `saida`, `aviso`, `erro`, `debug`) | event / kind (`start`, `end`, `progress`, `output`, `warning`, `error`, `debug`) | `log/eventos.jsonl` → `log/events.jsonl` |
| inicio, fim, dur, msg, resta, avisos | start, end, duration, message, remaining, warnings | eventos, processos |
| alvo, fila, saida | target, queue, output | processos |
| rastro | trace | `core/trace.py`, `cache/rastro.jsonl` → `cache/trace.jsonl` |
| ao_vivo | live | `cache/ao_vivo/` → `cache/live/` |
| travas | locks | `cache/travas/` → `cache/locks/` |
| processos | processes | `core/processes.py`, `cache/processos.jsonl` → `cache/processes.jsonl` |
| eventos, opcoes, tela | events, options, display | módulos de `core/` |
| etapa (chave do evento) | stage | eventos |
| fluxo, no, detalhe, desde | flow, node, detail, since | rastro |
| chamada, tarefas, progresso | call, tasks, progress | rastro |
| rotulo, feito, unidade | label, done, unit | tarefas do rastro |
| entrada, saida, parcial, esquema, primeiro | input, output, partial, schema, first | chamada de LLM no rastro |
| custo, seg | cost, seconds | evento `claude`, chamada do rastro |
| ESTEIRA_PROC, ESTEIRA_FILA | ESTEIRA_PROCESS, ESTEIRA_QUEUE | variáveis de ambiente |

## Esteira — IA (`esteira/ia/` → `esteira/ai/`)

| pt | en | onde |
|---|---|---|
| perguntar, liberar_gpu, TEXTO, VISAO | ask, free_gpu, TEXT, VISION | `ai/local.py` |
| esquema, modelo, imagens, pensar, temperatura, operacao | schema, model, images, think, temperature, operation | argumentos de `local.ask` |
| consultar, gasto, cota, cota_cheia, limite_cota | query, spent, quota, quota_full, quota_limit | `ai/claude.py` |
| motivo, custo, resposta | reason, cost, answer | `cache/claude.jsonl` |
| cota_claude.json | claude_quota.json | `cache/` |
| modelos, servidor, reiniciar, carregados, descarregar, visao, baixar | models, server, restart, loaded, unload, vision, download | `ai/llama.py` |
| disponivel, vetores, cosseno, media | available, vectors, cosine, mean | `ai/embeddings.py` |
| alinhar_ctc.py (`palavras`, `modelo`) | ctc_align.py (`words`, `model`) | pedido do alinhamento |
| treinar_lora.py (`--epocas`, `--contexto`, `--so-adaptador`) | train_lora.py (`--epochs`, `--context`, `--adapter-only`) | treino LoRA |
| treino.json (`epocas`, `arquivos`, `perda`, `perda_val`, `adaptador`), adaptador.gguf | training.json (`epochs`, `files`, `loss`, `val_loss`, `adapter`), adapter.gguf | saída do treino |
| tokens_entrada, tokens_saida, geracao_s, carga_s, custo_usd, cache_lido, tentativa | input_tokens, output_tokens, generation_s, load_s, cost_usd, cache_read, attempt | chamada de LLM no rastro |
| LLAMA_MODELOS_DIR, EMBEDDINGS_MODELO | LLAMA_MODELS_DIR, EMBEDDINGS_MODEL | variáveis de ambiente |

Os prompts (`ai/prompts/*.md`: nome do arquivo, texto, campos e o esquema da resposta) migram junto com o módulo
dono de cada um, porque os campos e as chaves do JSON de resposta são do módulo.

## Esteira — módulos (nomes de arquivo)

Raiz do pacote: acervo → library, alinhamento → alignment, avaliar → evaluate, bancada → bench, bordas → edges,
cenas → scenes, claquete → clapper, cortes → cuts, curadoria → curation, descricao → description, fotos → photos,
grafo → graph, grafo_dados → graph_data, midia → media, monitor_processo → process_monitor, montar → assemble,
pacote → package, producao → production, projeto → project, resumo → summary, roteirista → scriptwriter,
transcrever → transcribe. Pacotes: fontes → sources (gravacoes → recordings, importar → importer), graficos →
graphics (artigos → articles, chaves → keywords, pecas → pieces, plano → plan), imagem → image (gerar_sdxl →
generate_sdxl), estudio → studio (amostra → sample, apontamento → marking, compilar → compiler, corte → cut,
direcao → direction, diretor → director, estilo → style, fabrica → factory, fontes → fonts, gatilhos → triggers,
identidade → identity, moldes → molds, motor → engine, peca → piece, ritmo → rhythm, treino → training), dataset
(edicoes → edits, exportar → export, indice → index, inferir → infer, registro → registry, traduzir → translate,
treino_app → app_training), web (fila → queue, quadros → frames, api_estudio → api_studio, api_sistema →
api_system). Testes seguem o módulo (`test_cortes` → `test_cuts`, `test_etapaN` → `test_stageN`).
Pastas de dados do pacote ainda com o nome antigo: `graphics/fontes`, `graphics/modelos`, `studio/pecas`,
`studio/kit`, `studio/estilos`, `studio/ritmos`, `ai/prompts/*.md`, `tests/dados`.

## Esteira — nomes de nível de módulo (funções, classes, constantes)

Renomeados em bloco, palavra por palavra, pelo dicionário abaixo (o nome composto mantém a ordem das palavras:
`cota_cheia` → `quota_full`, `PASTA` → `FOLDER`, `PecaGerada` → `PieceGenerated`). Principais termos do domínio:
acervo → library, bancada → bench, cena → scene, corte → cut, peca → piece, ficha → card, folha → sheet, estilo →
style, gatilho → trigger, portao → gate, fabrica → factory, pedido → request, lacuna → gap, roteiro → script, fala →
speech, frase → sentence, trecho → span, tomada → take, borda → edge, soco → punch, selo → badge, pele → skin,
molde → mold, teto → cap, piso → floor, freio → brake, socorro → fallback, situacao → status, gabarito →
answer_key, legenda → caption, trilha → track, quadro → frame, previa → preview, pasta → folder, arquivo/arq →
file, gravar/escrever → write, carregar → load, listar → list_all, compilar → build, registro → record.
Ainda em português dentro dos módulos: métodos e campos de classes (os campos Pydantic são chaves JSON), parâmetros,
variáveis locais, comentários, docstrings e mensagens.

Estado da migração da esteira: `core/`, `ai/` e a CLI (`esteira.py`: comandos, flags, ids das etapas e das operações)
feitos, com painel, fila, grafo do monitor e app usando os nomes novos. Ainda em português, cada um no seu passo:
o interior dos módulos fora de `core/` e `ai/` (métodos, campos, parâmetros, variáveis, comentários e mensagens; nomes de arquivo e nomes de nível de módulo já estão em inglês), as etapas internas do Estúdio (`dirigir`,
`compilar`… e os eventos `estudio-<etapa>`), rótulos de alvo da fila (`fabrica:`, `peca:`, `treino:`, `roteiro:`),
valores de `--mode`/`--intensity`, chaves próprias da API web (`processos`, `vagas`, `etapas`…) e da fila
(`comando`, `vaga`, `estado`), chaves do `config.toml`, os prompts de `ai/prompts/` e o nome do pacote `esteira`. O script `artigo` do vault ainda grava a barra externa com
`rotulo`/`feito`/`unidade` (`grafo._tarefa_externa` converte). O serviço do painel instalado por
`infra/scripts/conectar_vps` precisa ser reinstalado: o comando agora é `dark panel --port 8765`.

## Plataforma e backends dos módulos

Mesmo processo mecânico da esteira (arquivos → nomes de nível de módulo → parâmetros e variáveis locais), nos
pacotes `backend`, `worker`, `shared`, `codigo`, `concursos`, `design`, `eletronica`, `estudos`, `financas`, `painel`,
`rotinas`, `saude` e `youtube`. Os nomes dos pacotes dos módulos e as rotas (`/api/notas`, `/api/estudos/...`) não
mudaram. Arquivos: `backend/notas` → `backend/notes` (cofre → vault, tipos → note_types), `backend/arquivos` →
`backend/files` (biblioteca → library, mapeamento → mapping, reescrita → rewrite, baixar_referencias →
download_references), `auth/seguranca` → `auth/security`, `core/modelo_llm` → `core/llm_model`,
`internet/ferramentas` → `internet/tools`, `middleware/cabecalhos` → `middleware/headers`, `api/atualizacoes` →
`api/updates`; worker: codigo → coding, contas_claude → claude_accounts, pronuncia → pronunciation, recursos →
resources, voz → voice; módulos: sessoes → sessions, vagas → jobs, concursos → exams, cronograma → schedule,
curriculos → resumes, estudo → study, plano_ia → ai_plan, rumores → rumors, cadernos → notebooks, fluxos → flows,
imagens → images, quadros → boards, wireframe_ia → ai_wireframe, simulacao → simulation, biblioteca(s) →
library/libraries, projetos → projects, linguagem → language, idiomas → languages, conhecimento → knowledge,
catalogo_tecnologia → technology_catalog, analise → analysis, armazem → warehouse, cenarios → scenarios, extrato →
statement, ia → ai, padroes → patterns, relatorios → reports, agente → agent, cobrador → nagger, desempenho →
performance, medidor → meter, notificador → notifier, quadro → board, bem_estar → wellbeing, consumo → consumption,
relogio → watch, treinos → workouts, catalogo → catalog, canais → channels, esquema → schema, importar → importer
(`python -m youtube.importer`). `infra/scripts/instalar_vps` chama `backend.auth.security.generate_hash_password`
e `generate_secret_totp`.

Pendente em todo o repositório: métodos e campos de classes, parâmetros que são contrato (rotas, nomes passados por
palavra-chave), chaves JSON/frontmatter/WebSocket, rotas, comentários, docstrings, mensagens, prompts, testes
(nomes dos arquivos e das funções da plataforma), o configurador, `capture`, e os apps Flutter.
