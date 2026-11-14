# Código (codificação a distância)

Pedir recursos e módulos novos pelo app: o pedido vai à VPS (`/api/codigo`) e o worker do PC roda o
Claude Code (`claude -p`, assinatura logada) **dentro deste repositório**, carregando o `CLAUDE.md`.

- **Abas** = sessões independentes (como terminais separados); várias rodam ao mesmo tempo. A
  mensagem seguinte da aba continua a conversa (`--resume`).
- **Imagens de referência**: enviadas em base64, gravadas no PC em `~/agent-data/codigo/imagens/<aba>/`
  e passadas ao Claude pelo caminho.
- **Etapas ao vivo**: o worker lê o `stream-json` (`worker/codigo.py:etapas`) e manda cada etapa pelo
  WebSocket (`evento`, canal `codigo`); o backend grava em `~/agent-data/codigo/sessoes/<id>/eventos.jsonl`
  e o app busca as novas a cada 2 s (`?desde=`).
- **Commit e versão**: o botão pede ao Claude da aba commit só do que ele mudou, `git push` e, se marcado,
  `infra/scripts/publicar_app`.
- **Navegar no código** (só leitura): árvore do repositório do PC num commit (padrão: o último) via
  `codigo.arvore`/`codigo.arquivo` (`git ls-tree`/`git show`, só hash, nunca ref). O que o commit trouxe fica
  em destaque: arquivos novos/alterados na árvore e linhas novas em verde no arquivo.

Permissões no PC (`plataforma/worker`, variáveis `WORKER_CODIGO_*`): `bypassPermissions`, qualquer comando sem
aprovação. Para restringir à lista `codigo_ferramentas` (verificar, git, grep…), `WORKER_CODIGO_PERMISSAO=acceptEdits`.

Código: `backend/src/codigo/` (`sessoes.py`, `api.py`), `plataforma/worker/src/worker/codigo.py`,
`app/lib/src/` (`codigo_tela.dart`, `navegador_tela.dart`, `api_codigo.dart`, `modelos.dart`).
Validar: `infra/scripts/verificar modulos/codigo plataforma/worker`.
