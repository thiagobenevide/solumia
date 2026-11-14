# Architecture — LLM Gateway

## Overview

The LLM Gateway lets any client compatible with the OpenAI API
(Claude Code, Cursor, Continue.dev, Cline, Roo Code, Open WebUI, official
SDKs, etc.) use models running on a personal machine (through LM
Studio, Ollama, vLLM, llama.cpp, ...) without exposing that machine
directly to the internet.

```
OpenAI-compatible client
        │  HTTPS
        ▼
      Nginx (VPS)
        │
        ▼
  LLM Gateway (VPS)
        │  WebSocket (opened by the Worker)
        ▼
   Worker (personal machine)
        │
        ▼
     LM Studio / Ollama / vLLM / ...
```

The central point of the design: **the VPS never starts a connection to the personal
machine**. It is always the Worker that connects to the VPS, authenticates and keeps a
WebSocket open. The Gateway exposes the public API and routes requests to the
right Worker through that already established connection.

## Monorepo modules

| Module         | Where it runs     | Responsibility                                                 | Status  |
|----------------|-------------------|----------------------------------------------------------------|---------|
| `gateway/`     | VPS               | OpenAI-compatible API, auth, rate limit, routing, dashboard backend | Stage 1 (foundation) |
| `worker/`      | Personal machine  | Connects to the Gateway, discovers models, forwards requests   | Next stages |
| `providers/`   | Inside the Worker | Abstraction over LM Studio / Ollama / vLLM / llama.cpp         | Next stages |
| `shared/`      | Both              | Contracts (Pydantic schemas) shared by Gateway and Worker      | Next stages |
| `dashboard/`   | VPS (served by Gateway/Nginx) | React/Vite/TS observability UI                     | Next stages |
| `docker/`      | VPS               | Dockerfiles and docker-compose                                 | Stage 1 (partial) |
| `tests/`       | CI / dev          | Automated tests for every module                               | Stage 1 (partial) |
| `sdk-python/`  | Clients           | Convenience Python SDK                                         | Next stages |
| `sdk-js/`      | Clients           | Convenience Node/JS SDK                                        | Next stages |

## Architecture principles

- **Clean Architecture**: each module separates `api` (HTTP/WS transport),
  `core` (config, cross-cutting concerns), `domain` (entities and business
  rules) and `infrastructure` (database, cache, external providers). Inner
  layers do not depend on outer layers.
- **Provider Pattern**: the Worker never talks directly to "LM Studio" —
  it talks to a `Provider` interface. `LMStudioProvider` is the first
  implementation; `OllamaProvider`, `VLLMProvider`, `LlamaCppProvider` and
  `OpenAICompatibleProvider` are added later without changing the rest
  of the system.
- **Own Worker↔Gateway protocol**: typed messages over WebSocket
  (`{"type": "chat_request", "request_id": "...", "payload": {...}}`),
  designed to support streaming, heartbeat and multiple simultaneous
  workers.
- **Strict OpenAI compatibility**: the request/response JSON format of the
  public endpoints (`/v1/chat/completions`, `/v1/models`, `/v1/responses`,
  `/v1/embeddings`) must be byte-for-byte compatible with the OpenAI API, so
  that no client needs to know it is talking to this Gateway.
- **Async end to end**: FastAPI + `asyncio` + `httpx` in the Gateway;
  `websockets`/`asyncio` in the Worker.

## Stage roadmap

1. **Project foundation and basic Gateway** *(this stage)* — monorepo
   layout, FastAPI app configured through env, structured logging,
   request-id middleware, health check, Gateway Docker, tests and
   tooling (ruff/mypy/pytest).
2. **OpenAI-compatible endpoints (mock)** — `GET /v1/models` and
   `POST /v1/chat/completions` (non-streaming and SSE streaming) served by
   a fake provider, to settle the API contract before a Worker exists.
3. **Worker↔Gateway protocol over WebSocket** — WS server in the Gateway,
   WS client in the Worker, worker authentication, heartbeat, reconnection with
   exponential backoff.
4. **Provider Pattern + LMStudioProvider** — `Provider` abstraction,
   real LM Studio implementation, automatic model discovery.
5. **Routing real requests** — the Gateway forwards
   `chat_request`/`chat_response` end to end through the WebSocket to
   LM Studio and back to the client, with streaming.
6. **Persistence (PostgreSQL + Alembic)** — `workers`, `api_keys`,
   `requests`, `logs`, `models`, `users` models; Repository Pattern.
7. **Authentication and authorization** — client API keys (`sk_live_...`),
   worker keys (`worker_...`), JWT where it makes sense.
8. **Redis** — cache, queues, rate limit, online worker presence.
9. **Balancing across multiple workers** — selection by model, GPU,
   latency, load.
10. **Dashboard (React/Vite/TS)**.
11. **Nginx + full Docker Compose + final scripts** (`ia_llm.sh` to
    start the Gateway on the VPS, `ia_llm.ps1` to start the local Worker).
12. **Production hardening**: rate limit, retries, timeouts, CORS,
    full structured logging, `/v1/embeddings`, `/v1/responses`,
    function/tool calling, images.

Each stage delivers something runnable and testable before moving on to the
next.

## Directory layout (after this stage)

```
llm-gateway/
├── gateway/
│   ├── pyproject.toml
│   ├── .env.example
│   └── src/gateway/
│       ├── main.py
│       ├── core/
│       │   ├── config.py
│       │   └── logging.py
│       ├── middleware/
│       │   └── request_id.py
│       └── api/
│           ├── deps.py
│           ├── health.py
│           └── v1/
│               └── router.py
├── docker/
│   ├── docker-compose.yml
│   └── gateway/Dockerfile
├── tests/
│   └── gateway/
│       └── test_health.py
├── scripts/
│   ├── run_gateway.sh
│   ├── run_gateway.ps1
│   ├── llm_gateway.sh
│   └── llm_gateway.ps1
├── docs/
│   └── ARCHITECTURE.md
├── pyproject.toml
├── LICENSE
└── README.md
```

Directories such as `worker/`, `providers/`, `shared/`, `dashboard/`,
`sdk-python/` and `sdk-js/` will be created when the matching roadmap
stage uses them, to avoid dead code in the repository.
