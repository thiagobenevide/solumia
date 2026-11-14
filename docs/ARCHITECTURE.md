# Architecture — Centralized Productivity and Knowledge System

> Status: v0.3 · 2026-10-27 · module layout; `esteira-dark` and `llm_gateway` migrated

## 1. Goal

All-in-one, autonomous, local-first platform that centralizes projects, routines, finances,
studies and content production. LLMs run on the user's machine (cost ≈ zero per token) and
the data syncs between PC, laptop, tablet and phone.

## 2. Existing assets brought into the project

| Asset | Where it is today | What it is | Destination |
|---|---|---|---|
| **esteira-dark** | `~/Documents/github/llm/esteira-dark` | Full pipeline for dark videos (~12k lines of Python): vault + WAV → Whisper → cuts → scenes → LLM curation → media (Pexels, Pixabay, Openverse + FTS5 library) → EffectCraft graphics → FilmCraft editing → thumbnails (PhotoCraft + RealVisXL). `./dark` CLI, FastAPI + htmx panel, 5 channel profiles, tests | `modulos/empreendimento/esteira/`, migrated **without a rewrite** ✅ |
| **llm_gateway** | `~/Documents/github/llm_gateway` | VPS with an OpenAI-compatible API + a Worker that connects inside-out over WebSocket, with worker authentication. LM Studio provider. Stage 3 of 12 of its own roadmap | `plataforma/backend` + `plataforma/worker` + `plataforma/shared`: **it is the Cloud Bridge** ✅ |
| **Obsidian vault** | `~/Documents/github/obsidian` | 1,050 notes, channel scripts, PDF articles, `artigo`/`pdf`/`vault` scripts and Claude skills | stays its own repository; it is the **data source** for the knowledge and content modules |

Channels (esteira profiles): `finlumia`, `benehistory`, `cosmoatomico`, `embarcados`, `thiagobenevide`.

## 3. Decisions

| # | Decision | Reason |
|---|---|---|
| D1 | **Flutter for every interface** (Android, iOS, tablet, Linux desktop) | A single codebase |
| D1a | *Temporary exception:* the esteira htmx panel stays up for the **visual editor** (graphics/thumbnails with live preview), cuts and scenes. Production tracking (episodes, scripts, queue, machine) is already in Flutter, through the JSON API `esteira/web/api.py` (`/api/v1`) | Rewriting the editor now would delay everything; the rest has already moved |
| D0 | **Organization by module**: each domain module (`modulos/<m>/`) holds its `backend/`, `worker/` and `app/`; `plataforma/` provides the common core (bridge, auth, sync, queue, main app) and mounts the modules. Everything in a single repository | Write a domain's backend and frontend in the same place |
| D2 | **Python 3.12**; **`uv` workspace** at the root with the platform and each module's backend/worker; ruff, mypy and pytest with the `llm_gateway` configuration. The esteira stays **outside** the workspace, with its own `.venv` and `.venv-img` (CUDA, torch) | One environment for the light packages, without dragging GPU dependencies to the VPS |
| D3 | **VPS + PostgreSQL** for structured data (tasks, goals, finances, queue, logs). **Notes and scripts stay as Markdown in the vault**, and Postgres only indexes them | The vault is already the user's writing flow and feeds the esteira |
| D4 | **Bridge = `llm_gateway`**: the worker opens a WebSocket to the VPS, and the VPS never starts a connection to the house. Replaces the WireGuard idea | Already implemented and tested; no port open at home |
| D5 | The **WebSocket protocol gains job messages** (`job_offer`, `job_progress`, `job_result`) besides `chat_request`, and the queue lives in the VPS Postgres | The same channel carries chat and pipeline jobs |
| D6 | The worker uses **only llama.cpp** (`LlamaCppProvider`): it starts/swaps `llama-server` with the `.gguf` files in `WORKER_MODELOS_DIR`. The app swaps the model at `/api/llm` (AI Model screen), forbidden while another module uses the LLM (409) | No LM Studio; swap models without a rebuild or `.env` |
| D7 | On the GPU PC, the esteira **calls llama.cpp directly** (`esteira/ia/llama.py`, the same router as the worker; using it blocks the model swap in the app) and escalates to Claude within the `[claude]` caps. The trace (`nucleo/rastro.py`) and the events feed the Dashboard | Avoids a round trip to the VPS; keeps what already works |
| D8 | **Media editing through headless Craft Apps** (`<app>-cli`, MCP), as the esteira already does | — |
| D9 | **Heavy data outside git**, in `$AGENT_DATA/<module>/` (default `~/agent-data`). Empreendimento: `projetos/` (16 GB), `acervo/` (2.8 GB), `cache/`. The esteira reads the path in `esteira/project.py` (`DADOS`, `PROJETOS`, `CACHE`) | Light repository; the data can live on an external drive |
| D10 | The **`.venv-img`** (PyTorch, 7.6 GB) is **recreated** from `requirements-img.txt`, not copied | Reproducible environment; venvs do not survive folder moves well |
| D11 | `llm_gateway` comes in through **`git subtree`** (keeps the commits); the esteira, which has no commits, comes in as a copy in a single commit | History kept where it exists |
| D12 | Secrets: `.env` never goes to git; each package has a `.env.example` | — |
| D13 | Single user for now, but **every table carries `user_id`** | Open to more users later without a painful migration |

## 4. Topology

```
 Flutter (phone, tablet, desktop)        OpenAI-compatible clients (Claude Code, Cursor…)
        │ HTTPS (JWT)                              │ HTTPS (sk_...)
        ▼                                          ▼
 ┌──────────────────────────────────────────────────────────────┐
 │ VPS — Nginx (TLS) → backend/ (FastAPI, ex-llm_gateway)       │
 │   /v1/* (OpenAI-compatible)   /api/* (domains)    /sync      │
 │   PostgreSQL: tasks, goals, finances, job queue, logs        │
 │   Scheduler + Cobrador → push (FCM)                          │
 └───────────────────────────────▲──────────────────────────────┘
                                 │ WebSocket opened by the worker
 ┌───────────────────────────────┴──────────────────────────────┐
 │ PC at home — RTX 5060 Ti 16 GB                               │
 │   worker/   providers: llama.cpp · job executor              │
 │   content/  esteira (./dark, panel :8765) ──┬─ llama.cpp     │
 │                                             ├─ faster-whisper│
 │                                             ├─ Craft Apps CLI│
 │                                             └─ RealVisXL     │
 │   ~/Documents/github/obsidian (vault)   ~/agent-data (media) │
 └──────────────────────────────────────────────────────────────┘
```

GPU: the esteira already serializes heavy work (`core/locks.py`, one slot at a time) and frees
VRAM before Whisper and SDXL (`liberar_gpu()`). The worker now honors the same lock:
quick answers (chat) only wait if the slot is taken by a heavy job.

## 5. Domain modules

| Module | Folder | Data | AI / GPU |
|---|---|---|---|
| Files (study library) | `modulos/arquivos` + `backend/files` | PDF/DOCX/PPTX, strokes, highlights with text | — (LibreOffice converts) |
| Empreendimento (YouTube ×5) | `modulos/empreendimento` (+ `youtube/` at `/api/youtube`) | episodes, library, profiles; channels/themes/stories/scripts/plans/methods as vault notes | full pipeline (`esteira/`) |
| Studies (knowledge + languages) | `modulos/estudos` | vault index, backlinks, embeddings, A1–C2 tracks | summaries, RAG, exercises, schedules |
| Health (spiritual, physical, mental) | `modulos/saude` | readings, workouts, loads, habits, journal | reflections, workout adjustments |
| Routines (Kanban + timer) | `modulos/rotinas` | boards, tasks, time sessions | quick answers |
| Design (whiteboard) | `modulos/design` (`/api/design`) | boards: pressure-sensitive vector strokes, shapes, text (JSON) | — |
| Electronics (circuit CAD) | `modulos/eletronica` (`/api/eletronica`) | projects: schematic (components, wires, labels, sheets), symbol library | ngspice simulation on the worker (phase 3) |
| Code (remote coding) | `modulos/codigo` (`/api/codigo`) | tabs: Claude Code steps (JSONL), reference images | Claude Code on the PC worker, in the repository |
| Finances | `modulos/financas` | transactions (OFX/CSV), companies, income statements (CVM) | categorization, indicators |
| Panel (Dashboard + Cobrador) | `modulos/painel` | gateway requests, esteira trace, goals, deviations | detects deviations, drafts reminders |

## 6. Repository layout

```
agent/
├── pyproject.toml · uv.lock      # uv workspace + ruff/mypy/pytest
├── pubspec.yaml · pubspec.lock   # Flutter pub workspace
├── plataforma/                   # common core, no domain rules
│   ├── backend/                  # FastAPI on the VPS (ex-llm_gateway/gateway; `backend` package)
│   ├── worker/                   # WS client on the GPU PC (ex-llm_gateway/worker)
│   ├── shared/                   # WS protocol and schemas (ex-llm_gateway/shared)
│   ├── app/                      # main Flutter app (web, Linux, Android): navigation between modules
│   ├── app_core/                 # shared Flutter package: Modulo, ApiCliente, Sondagem, theme
│   └── app_notas/                # reusable notes (editor, relations, analysis); backend in backend/notas
├── modulos/
│   ├── empreendimento/
│   │   ├── esteira/              # ex-esteira-dark: ./dark, panel + /api/v1 API, profiles, tests (own venv)
│   │   └── app/                  # Flutter screens: production, scripts, queue, machine, episode
│   ├── estudos/  saude/  rotinas/  design/  financas/  painel/
│   │   └── (each one)  backend/  worker/  app/   ← created when there is code
├── infra/
│   ├── docker/                   # compose, backend Dockerfile, nginx
│   └── scripts/                  # run_gateway / run_worker / llm_gateway (.sh and .ps1)
└── docs/
    ├── ARCHITECTURE.md
    └── gateway/                  # docs inherited from llm_gateway
```

Contracts between the platform and the modules:
- **Backend:** each `modulos/<m>/backend` is a uv workspace package (`agent-<m>`) that exposes an
  `APIRouter`; the platform mounts it at `/api/<m>`. A single Alembic migration, with one versions
  folder per module.
- **Worker:** each `modulos/<m>/worker` registers executors per job type (`<m>.<action>`); the platform
  worker receives the job over the WebSocket and dispatches it. For the esteira, the executor calls `./dark`.
- **App:** each `modulos/<m>/app` is a Flutter package (`agent_<m>`) that exports its routes; the platform
  app joins them all in a pub workspace.

## 7. Roadmap

| Phase | Delivery | Done when |
|---|---|---|
| **0a. Migration** ✅ | merge of `llm_gateway` with history; esteira in `modulos/empreendimento/esteira`; `AGENT_DATA`; uv workspace | 20 platform tests and 32 esteira tests passing; `./dark status` lists the episodes; FilmCraft opens the migrated projects |
| **Empreendimento app** ✅ | Flutter app (shell + `app_core` + Empreendimento screens) on top of the esteira JSON API | production, scripts, queue and machine with real data; web running |
| **0b. Bridge** | OllamaProvider; Postgres + Alembic (gateway stage 6); job messages | a chat from the phone is answered by the home GPU; `./dark all` triggered by the queue |
| 1. Routine | Kanban, timer, Cobrador, basic Dashboard in Flutter | real daily use |
| 2. Knowledge | vault index, backlinks, graph, RAG, languages | — |
| 3. Content on the platform | queue, status and human approval in Flutter; upload through the YouTube Data API | 5 channels publishing with human review |
| 4. Others | finances, health, whiteboard with S-Pen; visual editor in Flutter | — |

## 8. External constraints

- YouTube Data API: 10,000 units/day by default, and each upload costs about 1,600, which
  gives about 6 uploads/day; ask for a quota increase early.
- YouTube monetization policy against repetitive content: human review is mandatory.
- Openverse without a key: 200 searches/day.
