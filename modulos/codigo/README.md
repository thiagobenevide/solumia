# Code (remote coding)

Ask for new features and modules from the app: the request goes to the VPS (`/api/codigo`) and the PC worker runs
Claude Code (`claude -p`, logged-in subscription) **inside this repository**, loading `CLAUDE.md`.

- **Tabs** = independent sessions (like separate terminals); several run at the same time. The
  tab's next message continues the conversation (`--resume`).
- **Reference images**: sent as base64, written on the PC to `~/agent-data/codigo/imagens/<tab>/`
  and passed to Claude by path.
- **Live steps**: the worker reads the `stream-json` (`worker/coding.py:stages`) and sends each step over the
  WebSocket (`evento`, channel `codigo`); the backend writes them to `~/agent-data/codigo/sessoes/<id>/eventos.jsonl`
  and the app fetches the new ones every 2 s (`?desde=`).
- **Commit and release**: the button asks the tab's Claude to commit only what it changed, `git push` and, if checked,
  `infra/scripts/publicar_app`.
- **Browse the code** (read-only): tree of the PC repository at a commit (default: the latest) via
  `codigo.arvore`/`codigo.arquivo` (`git ls-tree`/`git show`, hash only, never a ref). What the commit brought is
  highlighted: new/changed files in the tree and new lines in green in the file.

Permissions on the PC (`plataforma/worker`, `WORKER_CODIGO_*` variables): `bypassPermissions`, any command without
approval. To restrict to the `codigo_ferramentas` list (verificar, git, grep…), `WORKER_CODIGO_PERMISSAO=acceptEdits`.

Code: `backend/src/coding/` (`sessions.py`, `api.py`), `plataforma/worker/src/worker/coding.py`,
`app/lib/src/` (`code_screen.dart`, `browser_screen.dart`, `code_api.dart`, `models.dart`).
Validate: `infra/scripts/verificar modulos/codigo plataforma/worker`.
