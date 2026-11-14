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

Estado da migração da esteira: `core/` feito (código, arquivos em `cache/`, `log/events.jsonl`, painel e app lendo as
chaves novas). Ainda em português, cada um no seu passo: nomes das etapas/comandos da CLI (inclusive os valores de
`stage` e os ids das operações nas opções), chaves próprias da API web (`processos`, `vagas`, `etapas`…), chaves de
`[claude]` no `config.toml`, as métricas que `ia/` grava nas chamadas (`tokens_saida`, `custo_usd`…) e o nome do
pacote `esteira`. O script `artigo` do vault ainda grava a barra externa com `rotulo`/`feito`/`unidade`
(`grafo._tarefa_externa` converte).
