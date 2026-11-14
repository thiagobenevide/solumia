# Process and Routine Management

Kanban (pending, in progress, done), a timer per task and quick natural-language answers from an LLM.

## Layout

```
rotinas/
├── backend/   Python package: FastAPI API, models and rules (runs on the VPS)
├── worker/    heavy LLM/GPU jobs (runs on the GPU PC)
└── app/       Flutter package with the module screens
```

Each part only exists once there is code for it. The platform (`plataforma/`) registers the
backend router, dispatches the worker jobs and mounts the app screens.
