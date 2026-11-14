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

## Configurador — módulos (`configurador/core/src/solumia_configurador/`)

motor → engine, pastas → folders, gerar → generate, manifesto → manifest, nomes → names, plataforma →
platform_setup, papeis → roles, segredos → secret_store, apps_solumia → solumia_apps, cofre → vault, verificacao →
verification. Testes: test_pastas → test_folders, test_motor_gerar → test_engine_generate, test_manifesto_cofre →
test_manifest_vault. Nomes internos (funções, classes, constantes, locais, atributos, testes) em inglês: mapa em `infra/tools/english_migration/overrides_configurador.txt`. Ficam como contrato: chaves JSON/TOML, rotas, subcomandos (`servir`, `verificar`) e nomes de segredos no cofre.

## Configurador — app Flutter (`configurador/app/lib/`)

nucleo.dart → core.dart, plano.dart → plan.dart, tema.dart → theme.dart, telas/ → screens/ (inicio → home, conta → account, pastas → folders, registro → run_log, apps_solumia → solumia_apps). Localização: `textos.dart`/`Textos` → `app_text.dart`/`AppText`; chaves dos ARB em inglês (textos da tela seguem traduzidos). Classes: Nucleo → Core, ErroNucleo → CoreError, Tela* → *Screen.

Pendente em todo o repositório: métodos e campos de classes, parâmetros que são contrato (rotas, nomes passados por
palavra-chave), chaves JSON/frontmatter/WebSocket, rotas, comentários, docstrings, mensagens, prompts, testes
(nomes dos arquivos e das funções da plataforma), nomes internos do configurador, `capture`, e os apps Flutter.

## App de notas (`plataforma/app_notas/`)

Arquivos: `api_notas` → `notes_api`, `controlador` → `open_note`, `modelos` → `models`, `modulo_notas` →
`notes_module`, `telas/` → `screens/`, `editor_nota` → `note_editor`, `notas_tela` → `notes_screen`,
`painel_analise` → `analysis_panel`, `painel_relacoes` → `relations_panel`. Pacote `agent_notas` e `offline.dart`
mantidos. Classes: `ApiNotas` → `NotesApi`, `EspelhoNotas` → `NotesMirror`, `NotaAberta` → `OpenNote`, `Nota` →
`Note`, `NotaResumo` → `NoteSummary`, `TipoNota` → `NoteType`, `Campo` → `NoteField`, `Ligacao` → `NoteLink`,
`Analise` → `NoteAnalysis`, `ModuloNotas` → `NotesModule`, `NotasTela` → `NotesScreen`, `EditorNota` →
`NoteEditor`, `PainelAnalise` → `AnalysisPanel`, `PainelRelacoes` → `RelationsPanel`, `escolherNota` → `pickNote`.
Ficam em português (contrato/dados): chaves JSON, rotas, ops da fila offline (`criar`/`salvar`/`excluir`),
caminhos do armazém `notas/`, id do módulo `notas`, nomes vindos do `agent_core` e o texto da tela.

## App Rotinas (`modulos/rotinas/app/`)

Arquivos: `api_rotinas` → `routines_api`, `modelos` → `models`, `modulo_rotinas` → `routines_module`, `telas/` →
`screens/` (`assistente` → `assistant`, `cartao_tarefa` → `task_card`, `editor_tarefa` → `task_editor`,
`rotinas_tela` → `routines_screen`). Classes: `ApiRotinas` → `RoutinesApi`, `Tarefa` → `Task`, `Coluna` →
`BoardColumn`, `Resumo` → `BoardSummary`, `CartaoTarefa` → `TaskCard`, `ConversaAssistente` → `AssistantChat`,
`Assistente` → `Assistant`, `RotinasTela` → `RoutinesScreen`, `ModuloRotinas` → `RoutinesModule`. Os valores de
`BoardColumn` (`pendente`, `execucao`, `concluida`) ficam: vão para a API via `.name`.

## App Painel (`modulos/painel/app/`)

Arquivos: `api_painel` → `panel_api`, `modelos` → `models`, `modulo_painel` → `panel_module`, `vigia` →
`coach_watcher`, `telas/` → `screens/` (`chat_cobrador` → `coach_chat`, `dashboard_llms` → `llm_dashboard`,
`painel_tela` → `panel_screen`). Classes: `ApiPainel` → `PanelApi`, `Bloco` → `ScheduleBlock`, `Alerta` → `Alert`,
`Disciplina` → `Discipline`, `Meta` → `Goal`, `Executada` → `ExecutedAction`, `Resposta` → `CoachReply`,
`UsoProvedor` → `ProviderUsage`, `ChatCobrador` → `CoachChat`, `ConversaCobrador` → `CoachConversation`,
`ConversaSalva` → `SavedConversation`, `VigiaCobrador` → `CoachWatcher`, `DashboardLlms` → `LlmDashboard`,
`PainelTela` → `PanelScreen`, `ModuloPainel` → `PanelModule`. "Cobrador" = coach.

## App Código (`modulos/codigo/app/`)

Arquivos: `api_codigo` → `code_api`, `codigo_tela` → `code_screen`, `contas_claude` → `claude_accounts`, `modelos` →
`models`, `modulo_codigo` → `code_module`, `navegador_tela` → `browser_screen`, `realce` → `highlight`. Classes:
`ApiCodigo` → `CodeApi`, `AbaCodigo` → `CodeTab`, `Etapa` → `SessionStep`, `ArvoreCodigo` → `CodeTree`,
`ArquivoCodigo` → `CodeFile`, `CommitCodigo` → `CodeCommit`, `Tipo` → `TokenKind`, `Linguagem` → `Language`,
`Trecho` → `Span`, `CodigoTela` → `CodeScreen`, `NavegadorTela` → `BrowserScreen`, `SessaoVista` → `SessionView`,
`ModuloCodigo` → `CodeModule`.

## App Concursos (`modulos/concursos/app/`)

Arquivos: `api_concursos` → `exams_api`, `modelos` → `models`, `modulo_concursos` → `exams_module`, `telas/` →
`screens/` (`concursos_tela` → `exams_screen`, `concurso_tela` → `exam_screen`, `radar_tela` → `radar_screen`,
`rumores_tela` → `rumors_screen`, `simulados_tela` → `mock_exams_screen`). "Concurso" = exam; "edital" = notice;
"simulado" = mock exam; "banca" = board; "vaga" = opening; "esfera" = sphere. Classes: `ApiConcursos` →
`ExamsApi`, `Concurso` → `Exam`, `Simulado` → `MockExam`, `Questao` → `Question`, `Topico` → `Topic`, `Prazo` →
`Deadline`, `Rota` → `TravelRoute`, `VagaTI` → `ItJob`, `Rumores` → `Rumors`, `ModuloConcursos` → `ExamsModule`.

## App Eletrônica (`modulos/eletronica/app/`)

Arquivos: `api_eletronica` → `electronics_api`, `calculos` → `calculations`, `modelos` → `models`,
`modulo_eletronica` → `electronics_module`, `simulacao` → `simulation`, `cad/` (`cad_tela` → `cad_screen`,
`exportar` → `export`, `paineis` → `panels`, `pintura` → `painting`), `telas/` → `screens/` (`bibliotecas_tela` →
`libraries_screen`, `bom_tela` → `bom_screen`, `calculadoras_tela` → `calculators_screen`, `grafico` → `chart`,
`projetos_tela` → `projects_screen`, `simulacao_tela` → `simulation_screen`). Classes: `Componente` → `Component`,
`Fio` → `Wire`, `Folha` → `Sheet`, `Pino` → `Pin`, `Rotulo` → `NetLabel`, `Sonda` → `Probe`, `Simbolo` →
`Symbol`, `Biblioteca` → `Library`, `Projeto` → `Project`, `Camada` → `Layer`, `Ferramenta` → `Tool`, `Direcao` →
`Direction`, `Analise` → `Analysis`, `Curvas` → `SimCurves`, `Resultado` → `SimulationResult`. Os valores de
`Direction` (`d`, `e`, `c`, `b`) e de `Analysis` (`op`, `tran`, `ac`, `dc`) ficam: vão para a API.

## Pacotes Python dos módulos (import) e nomes de pasta combinados

Pacotes renomeados (`modulos/<m>/backend/src/<pacote>`): saude → health, financas → finance, estudos → studies,
concursos → exams, eletronica → electronics, painel → panel, rotinas → routines, codigo → coding (`code` colide com a
stdlib); design fica. Comentários e docstrings dos backends, da plataforma e do worker em inglês. Continuam como
contrato: rotas (`/api/saude`…), chaves JSON, nomes de tarefa do worker (`codigo.enviar`…) e chaves de `app.state`.
Combinado entre os chats para a mudança de pastas, feita de uma vez num ponto marcado pelo usuário: os mesmos nomes
para `modulos/<m>/`, arquivos → files, empreendimento → business, esteira → pipeline, modulos → modules,
plataforma → platform; distribuições `agent-<m>` e `uv.lock` mudam junto.

## App Estudos (`modulos/estudos/app/`)

Arquivos: `api_estudos` → `studies_api`, `layout_grafo` → `graph_layout`, `modelos` → `models`, `modelos_conhecimento`
→ `knowledge_models`, `modulo_estudos` → `studies_module`, `telas/` → `screens/` (`grafo_tela` → `graph_screen`,
`idiomas_tela` → `foreign_languages_screen`, `leituras_tela` → `readings_screen`, `linguagem_tela` →
`language_screen`, `mapeamento_painel` → `mapping_panel`, `projetos_tela` → `projects_screen`, `trilhas_tela` →
`tracks_screen`). Classes: `ApiEstudos` → `StudiesApi`, `Leitura` → `Reading`, `Trilha` → `Track`,
`TrilhaConhecimento` → `KnowledgeTrack`, `EtapaTrilha` → `TrackStep`, `ProjetoLeitura` → `ReadingProject`, `Matriz` →
`Matrix`, `TrabalhoMatriz` → `MatrixPaper`, `ItemMatriz` → `MatrixItem`, `TracoMao` → `HandStroke`, `NoGrafo` →
`GraphNode`, `Aresta` → `Edge`, `Opcoes` → `StudyOptions`, `ModuloEstudos` → `StudiesModule`.

## App Empreendimento (`modulos/empreendimento/app`)

Arquivos: `modelos` → `models`, `modulo_empreendimento` → `business_module`, `telas/` → `screens/` (`empreendimento_tela` →
`business_screen`, `*_aba` → `*_tab`, `grafo` → `graph`, `serie_temporal` → `time_series`, `episodio/` → `episode/`,
`editor/campos` → `editor/fields`), `estudio/` → `studio/` (`estilo_tela`/`estilo_abas` → `style_screen`/`style_tabs`,
`fabrica_tela` → `factory_screen`, `previa_peca` → `piece_preview`, `linha_tempo` → `timeline`), `vagas/` → `jobs/`
(`api_vagas` → `jobs_api`, `curriculos_tela` → `resumes_screen`, `mapa_vagas` → `jobs_map`), `youtube/` (`api_youtube` →
`youtube_api`, `canal_tela` → `channel_screen`, `formulario` → `form`, `youtube_aba` → `youtube_tab`).
Classes: Canal → Channel, Roteiro → Script, Episodio/EpisodioResumo → Episode/EpisodeSummary, Etapa → Stage,
Fila → ProductionQueue (não `Queue`, do dart:collection), Selo → Pill (não `Badge`, do Material), Campo* → *Field
(CampoTexto → TextInputField), *Tela → *Screen, *Aba → *Tab, ApiVagas → ApiJobs. ModuloEmpreendimento → BusinessModule (`urlEsteira:` → `pipelineUrl:`). Ficam:
`ApiEsteira`/`api_esteira.dart` (seguem o nome novo da esteira) e o
pacote `agent_empreendimento` (renomeado junto com as pastas da raiz). Chaves JSON e rotas não mudaram.

## App Finanças (`modulos/financas/app/`)

Arquivos: `api_financas` → `finance_api`, `formato` → `format`, `modulo_financas` → `finance_module`, `telas/` →
`screens/` (`cenarios_tela` → `scenarios_screen`, `comuns` → `common`, `contas_tela` → `accounts_screen`,
`conversa_financas` → `finance_chat`, `empresa_tela` → `company_screen`, `estudo_tela` → `finance_study_screen`,
`extrato_tela` → `statement_screen`, `graficos` → `charts`, `investimentos_tela` → `investments_screen`,
`mercado_tela` → `market_screen`, `noticias_tela` → `news_screen`, `painel_tela` → `dashboard_screen`,
`planejamento_tela` → `planning_screen`). Classes: `ApiFinancas` → `FinanceApi`, `Campo` → `FormFieldSpec`,
`TipoCampo` → `FieldKind`, `Indicador` → `Indicator`, `Rosca` → `Donut`, `Fatia` → `Slice`, `ModuloFinancas` →
`FinanceModule`. Nomes do pacote do `arquivos` ficam até ele ser migrado.

## App Saúde (`modulos/saude/app/`)

Arquivos: `api_saude` → `health_api`, `aviso_treino` → `workout_notice`, `consumo_nativo` → `native_usage`, `datas` →
`dates`, `modelos` → `models`, `modulo_saude` → `health_module`, `sessao` → `session`, `sincronizacao` → `sync`,
`telas/` → `screens/` (`analise_tela` → `analysis_screen`, `biblioteca_exercicios` → `exercise_library`,
`calendario` → `calendar`, `comuns` → `common`, `consumo_tela` → `usage_screen`, `dialogos` → `dialogs`,
`espiritual_tela` → `spiritual_screen`, `guia_treino_tela` → `workout_guide_screen`, `mental_tela` →
`mental_screen`, `relogio_tela` → `watch_screen`, `treinos_tela` → `workouts_screen`). "Relógio" = watch; "consumo" =
usage; "treino" = workout; "série" = set. Classes: `ApiSaude` → `HealthApi`, `Exercicio` → `Exercise`,
`SessaoTreino` → `WorkoutSession`, `AvisoTreino` → `WorkoutNotice`, `LeitorHealthConnect` → `HealthConnectReader`,
`PontoSaude` → `HealthPoint`, `ConsumoNativo` → `NativeUsage`, `ModuloSaude` → `HealthModule`. Nomes de
MethodChannel, métodos e argumentos do lado Android ficam (são strings).
Testes da plataforma (`plataforma/backend/tests`, `plataforma/worker/tests`): arquivos e funções em inglês
(`test_saude_sessoes` → `test_health_sessions`, `test_concursos` → `test_exams`, `test_voz` → `test_voice`…;
`test_youtube.py` fica com o chat do YouTube). Fixtures curtas (`api`, `cliente`, `pasta`) ficaram como estavam.

## App Design (`modulos/design/app/`)

Arquivos: `api_design` → `design_api`, `modelos` → `models`, `modulo_design` → `design_module`, `rotas` → `routing`,
`caderno/` → `notebook/` (`caderno_tela` → `notebook_screen`, `caneta` → `pen`, `papel_dialogo` → `paper_dialog`,
`referencias` → `references`), `quadro/` → `board/` (`busca_bing` → `bing_search`, `entrada` → `input`, `estojo` →
`toolbox`, `exportar` → `export`, `fluxo` → `flow`, `imagens` → `images`, `menu_caneta` → `pen_menu`, `paineis` →
`panels`, `pintura` → `painting`, `quadro_tela` → `board_screen`, `tabela` → `table`), `telas/` → `screens/`
(`design_tela` → `design_screen`, `galeria_tela` → `gallery_screen`), `wireframe/` (`galeria` → `gallery`, `modelo` →
`model`, `pintura` → `painting`, `wireframe_tela` → `wireframe_screen`). Classes: `Quadro` → `Board`, `Pagina` →
`BoardPage`, `Ligacao` → `Connector`, `NoFluxo` → `FlowNode`, `Tabela` → `BoardTable`, `Imagem` → `BoardImage`,
`Texto` → `BoardText`, `Nota` → `StickyNote`, `Papel` → `Paper`, `Prancha` → `Artboard`, `Componente` →
`WfComponent`, `Ferramenta` → `Tool`, `Estojo` → `Toolbox`. Os valores dos enums gravados nos quadros (`Fundo`,
`Pincel`, `TipoForma`, `TipoNo`, `TipoLinha`, `TipoPonta`, `EstadoWf`, `_Lado`) ficam, e por isso variáveis locais
com os mesmos nomes (`fim`, `inicio`, `pontos`…) também.

## App Arquivos (`modulos/arquivos/app/`)

Arquivos: `api_arquivos` → `files_api`, `modelos` → `models`, `modulo_arquivos` → `files_module`, `editores/` →
`editors/` (`apresentacao_tela` → `presentation_screen`, `collabora_tela` → `collabora_screen`, `documento_tela` →
`document_screen`, `exportar` → `export`, `planilha_tela` → `spreadsheet_screen`, `reescrita` → `rewrite`),
`externo/` → `external/`, `leitor/` → `reader/` (`anotador` → `annotator`, `camada_pagina` → `page_layer`,
`dados_tela` → `data_screen`, `diagramacao` → `layout`, `estojo` → `toolbox`, `geometria` → `geometry`,
`leitor_tela` → `reader_screen`, `leitura_guiada` → `guided_reading`, `pintura` → `painting`, `previa_tela` →
`preview_screen`, `traducao` → `translation`, `traducao_pagina` → `page_translation`), `telas/` → `screens/`
(`acoes_destaque` → `highlight_actions`, `biblioteca_tela` → `library_screen`, `destaques_aba` → `highlights_tab`,
`projetos_leitura` → `reading_projects`). Classes: `ApiArquivos` → `FilesApi`, `Arquivo` → `FileItem`, `Anotacoes` →
`Annotations`, `Anotador` → `Annotator`, `Destaque` → `Highlight`, `Traco` → `InkStroke`, `LeitorTela` →
`ReaderScreen`, `LeituraGuiada` → `GuidedReading`, `AcervoOffline` → `OfflineVault`, `ModuloArquivos` →
`FilesModule`. Os valores de `Brush` (`caneta`, `lapis`, `caligrafia`, `marcador`) ficam: vão para o JSON.
