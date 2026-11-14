# agent

Monorepo local-first: `plataforma/` (backend FastAPI na VPS, worker no PC com GPU, `shared/`, app Flutter
`app/` + `app_core/` + `app_notas/`; notas = `backend/notas/` em `/api/notas`, Markdown com frontmatter
YAML compatível com o Obsidian) e `modulos/<m>/` (backend/worker/app de cada domínio). Só `empreendimento` tem código:
`esteira/` (pipeline de vídeos, venv próprio, tem `CLAUDE.md` próprio), `youtube/` (canais como notas do cofre,
`/api/youtube`; importa do vault com `python -m youtube.importar`) e `app/` (telas Flutter, `CLAUDE.md` próprio).
Decisões em `docs/ARCHITECTURE.md` (ler só a seção pedida, por `grep -n '^## '`).

## Comandos

- Validar: `infra/scripts/verificar [caminhos]` — ruff, pytest e `flutter analyze` só do que mudou, saída
  compacta. É a única validação padrão; não rodar as ferramentas soltas com saída cheia.
- Flutter fora do PATH: `~/development/flutter/bin/flutter`. Pub workspace na raiz (`flutter pub get` na raiz).
- Python da plataforma: `.venv/bin/python` (workspace `uv`); esteira: `modulos/empreendimento/esteira/.venv`.

## Economia de tokens (regra fixa, vale para todo pedido)

Processo para cada pedido:
1. **Escopo**: entender o pedido e já agir. Perguntar só se a resposta mudar o que será feito. Sem plano
   escrito para tarefa pequena; para tarefa grande, plano de 3–6 linhas e seguir.
2. **Localizar** com `grep -n`/`rg -n` (nome de classe, rota, chave JSON) e `wc -l` antes de abrir. Usar os
   mapas dos `CLAUDE.md` em vez de listar pastas.
3. **Ler só o trecho**: `Read` com `offset/limit` ou `sed -n 'A,Bp'`. Arquivo inteiro só se tiver < 150 linhas
   ou se a mudança atravessar o arquivo. Nunca reler o que já está no contexto nem o que acabou de editar.
4. **Editar** com `Edit` (troca mínima). `Write` só para arquivo novo ou reescrita real. Várias edições
   independentes no mesmo turno, em paralelo.
5. **Validar uma vez** no fim com `infra/scripts/verificar`; se falhar, corrigir e rodar de novo só o caminho.
6. **Responder curto**: o que mudou (arquivo:linha), o que falhou, próximo passo. Sem colar código já
   escrito, sem repetir saída de comando, sem resumo do que o usuário pediu.

Proibido sem pedido explícito:
- Subagentes (`Agent`/Explore/Plan), skills de auditoria (`cartographer`, `code-review max/ultra`) e buscas
  na web: cada uma recomeça o contexto do zero.
- Ler arquivos gerados ou de dados: `*.lock`, `build/`, `.dart_tool/`, `.venv*/`, `__pycache__/`,
  `linux/flutter/generated_*`, `tests/dados/`, `$AGENT_DATA` (`~/agent-data`). Para JSON grande:
  `jq` com filtro ou `head -c 2000`; para logs: `tail -n 50` ou `grep`.
- `git log -p`, `git diff` sem `--stat` em mudança grande (ver `--stat` primeiro e depois o arquivo).
- Rodar o app ou servidores para "ver se funciona" quando `verificar` basta.

Saída de comandos: sempre o modo quieto (`-q`, `--quiet`, `--no-header`, `| tail -n 30`). Teste falhando:
rodar só ele (`pytest caminho::teste -q`).

## Claude no sistema

Todo uso de Claude é pelo Claude Code headless (`claude -p`, assinatura do PC), nunca pela API da
Anthropic (SDK `anthropic`/chave): padrão em `plataforma/shared/src/shared/claude_code.py`, rodando no worker.

## Estilo

- Código, nomes, comentários e mensagens em inglês (migração em andamento: ao tocar num arquivo ainda em
  português, seguir o padrão do arquivo). Comentário só onde a regra não é óbvia.
- Contratos ficam como estão até decisão explícita: chaves JSON da API, frontmatter das notas, nomes de
  tarefas do worker e campos do protocolo WebSocket.
- Estrutura simples: laço `for`/`while` comum em vez de comprehension, `map`/`where` com lambda ou
  cadeias de streams; sem função dentro de função; sem ternário aninhado; funções pequenas e nomeadas.
- Mudança mínima que resolve o pedido; nada de refatorar ou "melhorar" vizinhos sem pedido.

## Compact instructions

Ao compactar, manter: pedido atual, arquivos tocados (caminho:linha), decisões tomadas e falhas pendentes do
`verificar`. Descartar saídas de comandos, conteúdo de arquivos lidos e tentativas já descartadas.
