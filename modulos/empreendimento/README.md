# Business and Content Scaling

Management of the five YouTube channels (goal: one video per channel per day): ideation, scripts backed by scientific articles, local-LLM curation and validation, media search in open banks, editing, effects and thumbnails through the Craft Apps, publishing.

- `esteira/`: dark video pipeline (ex-`llm/esteira-dark`), with its own `./dark` CLI and panel; data in `$AGENT_DATA/empreendimento/`.
- Channels: `finlumia`, `benehistory`, `cosmoatomico`, `embarcados`, `thiagobenevide` (`esteira/perfis/`).

## Layout

```
empreendimento/
├── backend/   Python package: FastAPI API, models and rules (runs on the VPS)
├── worker/    heavy LLM/GPU jobs (runs on the GPU PC)
└── app/       Flutter package with the module screens
```

Each part only exists once there is code for it. The platform (`plataforma/`) registers the
backend router, dispatches the worker jobs and mounts the app screens.
