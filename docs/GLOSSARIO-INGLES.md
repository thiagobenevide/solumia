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
| rastro | trace | `nucleo/rastro.py` |
