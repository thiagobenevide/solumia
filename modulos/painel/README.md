# Dashboard and Accountability (Cobrador)

Operation logs, resource usage, LLM availability and latency; a coach (Cobrador) that tracks goals and actions and alerts when the plan drifts.

## Layout

```
painel/
├── backend/   Python package: FastAPI API, models and rules (runs on the VPS)
├── worker/    heavy LLM/GPU jobs (runs on the GPU PC)
└── app/       Flutter package with the module screens
```

Each part only exists once there is code for it. The platform (`plataforma/`) registers the
backend router, dispatches the worker jobs and mounts the app screens.

## Cobrador (done)

- `backend/` → `/api/painel`: goals (`/metas`, `/metas/{id}/acoes`), day agenda (`/agenda/{dia}`,
  `/sugerir`, `PUT` returns `contestacoes`, `/blocos/{id}/feito`), `/disciplina` (0–100 index and alerts),
  `/provedores` and `/conversar` (`local` = worker; `claude` with `GATEWAY_ANTHROPIC_API_KEY`).
  In the chat, "anote …" creates a note in the vault and "pesquise …" answers with the notes in the base.
- `app/`: Today tab (score, alerts, editable agenda), Cobrador (chat) and Goals.
- Agent: the LLM can end its answer with an ```acoes``` block (create task/note, change the
  agenda, record a goal, finish/move a task); the server runs it and returns `executadas`
  (`painel/agent.py`). Queries (`pesquisar_web`, `pesquisar_notas`, `analisar_desempenho`) go back
  to the LLM in a second round before the final answer.
- Other modules: `Fontes.modulos` (registered in `_acoes_modulos` in the platform `main.py`) gives
  the agent `criar_caderno`, `criar_quadro`, `criar_fluxograma` (Design) and `criar_projeto_estudo`,
  `criar_leitura` (Studies). A new module = one more entry there.
- Speed: the system prompt only has what barely changes (instructions, agenda, up to 40 open
  tasks); time and alerts go in the last message, so llama-server can reuse the cache.
- Performance: `GET /desempenho?dias=30` (`painel/performance.py`: done, on time, late,
  agenda adherence per weekday, goals); messages about "desempenho/produtividade" already bring the
  analysis into the prompt.
- Voice: `POST /voz` (WAV → transcription on the worker → conversation) and `POST /falar` (text → WAV). On the worker:
  `uv sync --extra voz` (faster-whisper) and Piper (`WORKER_PIPER_MODELO`) or `espeak-ng`.
- Notifications: in the app, `VigiaCobrador` shows new alerts in the system (Linux/Android) every
  5 min; with the app closed, `GATEWAY_PAINEL_NTFY_URL` sends a push through ntfy.
  On the Galaxy Watch, the `modulos/saude/wear` app shows the alerts, rings an alarm at the start of the blocks
  and talks to the coach by voice.
- Dashboard: `GET /dashboard` (requests, errors, p50/p95, tokens, log in `uso.jsonl`, workers' CPU/RAM/GPU
  via heartbeat); LLMs tab in the app.
