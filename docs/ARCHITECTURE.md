# Arquitetura — Sistema Centralizado de Produtividade e Conhecimento

> Status: v0.3 · 2026-10-27 · layout por módulos; `esteira-dark` e `llm_gateway` migrados

## 1. Objetivo

Plataforma all-in-one, autônoma e local-first, que centraliza projetos, rotinas, finanças,
estudos e produção de conteúdo. LLMs rodam na máquina do usuário (custo ≈ zero por token) e
os dados sincronizam entre PC, notebook, tablet e celular.

## 2. Ativos existentes que entram no projeto

| Ativo | Onde está hoje | O que é | Destino |
|---|---|---|---|
| **esteira-dark** | `~/Documents/github/llm/esteira-dark` | Pipeline completo de vídeos dark (~12 mil linhas de Python): vault + WAV → Whisper → cortes → cenas → curadoria LLM → mídia (Pexels, Pixabay, Openverse + acervo FTS5) → gráficos EffectCraft → montagem FilmCraft → thumbs (PhotoCraft + RealVisXL). CLI `./dark`, painel FastAPI + htmx, 5 perfis de canal, testes | `modulos/empreendimento/esteira/`, migrada **sem reescrita** ✅ |
| **llm_gateway** | `~/Documents/github/llm_gateway` | VPS com API compatível com a OpenAI + Worker que se conecta de dentro para fora por WebSocket, com autenticação de worker. Provider LM Studio. Etapa 3 de 12 do roadmap próprio | `plataforma/backend` + `plataforma/worker` + `plataforma/shared`: **é a Cloud Bridge** ✅ |
| **Vault Obsidian** | `~/Documents/github/obsidian` | 1.050 notas, roteiros dos canais, artigos em PDF, scripts `artigo`/`pdf`/`vault` e skills do Claude | continua um repositório próprio; é a **fonte de dados** dos módulos de conhecimento e conteúdo |

Canais (perfis da esteira): `finlumia`, `benehistory`, `cosmoatomico`, `embarcados`, `thiagobenevide`.

## 3. Decisões

| # | Decisão | Motivo |
|---|---|---|
| D1 | **Flutter para todas as interfaces** (Android, iOS, tablet, Linux desktop) | Uma base de código só |
| D1a | *Exceção transitória:* o painel htmx da esteira continua no ar para o **editor visual** (gráficos/thumbs com prévia ao vivo), cortes e cenas. O acompanhamento da produção (episódios, roteiros, fila, máquina) já está no Flutter, pela API JSON `esteira/web/api.py` (`/api/v1`) | Reescrever o editor agora atrasaria tudo; o resto já migrou |
| D0 | **Organização por módulo**: cada módulo de domínio (`modulos/<m>/`) reúne seu `backend/`, `worker/` e `app/`; a `plataforma/` dá o núcleo comum (ponte, auth, sync, fila, app principal) e monta os módulos. Tudo num único repositório | Codificar backend e frontend de um domínio no mesmo lugar |
| D2 | **Python 3.12**; **workspace `uv`** na raiz com a plataforma e o backend/worker de cada módulo; ruff, mypy e pytest com a configuração do `llm_gateway`. A esteira fica **fora** do workspace, com `.venv` e `.venv-img` próprios (CUDA, torch) | Um ambiente para os pacotes leves, sem arrastar dependências de GPU para a VPS |
| D3 | **VPS + PostgreSQL** para dados estruturados (tarefas, metas, finanças, fila, logs). **Notas e roteiros ficam como Markdown no vault**, e o Postgres só os indexa | O vault já é o fluxo de escrita do usuário e alimenta a esteira |
| D4 | **Ponte = `llm_gateway`**: o worker abre um WebSocket para a VPS, e a VPS nunca inicia conexão com a casa. Substitui a ideia do WireGuard | Já implementado e testado; nenhuma porta aberta em casa |
| D5 | O **protocolo WebSocket ganha mensagens de job** (`job_offer`, `job_progress`, `job_result`) além de `chat_request`, e a fila fica no Postgres da VPS | O mesmo canal leva chat e jobs do pipeline |
| D6 | O worker usa **só llama.cpp** (`LlamaCppProvider`): sobe/troca o `llama-server` com os `.gguf` de `WORKER_MODELOS_DIR`. O app troca o modelo em `/api/llm` (tela Modelo de IA), proibido enquanto outro módulo usa o LLM (409) | Sem LM Studio; trocar de modelo sem rebuild nem `.env` |
| D7 | No PC com GPU, a esteira **chama o llama.cpp direto** (`esteira/ia/llama.py`, o mesmo roteador do worker; uso dela bloqueia a troca de modelo no app) e escala para o Claude com os tetos de `[claude]`. O rastro (`nucleo/rastro.py`) e os eventos alimentam o Dashboard | Evita ida e volta à VPS; preserva o que já funciona |
| D8 | **Edição de mídia via Craft Apps headless** (`<app>-cli`, MCP), como a esteira já faz | — |
| D9 | **Dados pesados fora do git**, em `$AGENT_DATA/<módulo>/` (padrão `~/agent-data`). Empreendimento: `projetos/` (16 GB), `acervo/` (2,8 GB), `cache/`. A esteira lê o caminho em `esteira/projeto.py` (`DADOS`, `PROJETOS`, `CACHE`) | Repositório leve; os dados podem ir para um HD externo |
| D10 | O **`.venv-img`** (PyTorch, 7,6 GB) é **recriado** a partir de `requirements-img.txt`, não copiado | Ambiente reproduzível; venvs não sobrevivem bem a mudanças de pasta |
| D11 | O `llm_gateway` entra por **`git subtree`** (preserva os commits); a esteira, que não tem commits, entra por cópia num commit único | Histórico preservado onde ele existe |
| D12 | Segredos: `.env` nunca vai para o git; cada pacote tem um `.env.example` | — |
| D13 | Usuário único por enquanto, mas **toda tabela leva `user_id`** | Abrir para mais usuários depois sem migração dolorosa |

## 4. Topologia

```
 Flutter (celular, tablet, desktop)      Clientes OpenAI-compatible (Claude Code, Cursor…)
        │ HTTPS (JWT)                              │ HTTPS (sk_...)
        ▼                                          ▼
 ┌──────────────────────────────────────────────────────────────┐
 │ VPS — Nginx (TLS) → backend/ (FastAPI, ex-llm_gateway)       │
 │   /v1/* (OpenAI-compatible)   /api/* (domínios)   /sync      │
 │   PostgreSQL: tarefas, metas, finanças, fila de jobs, logs   │
 │   Scheduler + Cobrador → push (FCM)                          │
 └───────────────────────────────▲──────────────────────────────┘
                                 │ WebSocket iniciado pelo worker
 ┌───────────────────────────────┴──────────────────────────────┐
 │ PC em casa — RTX 5060 Ti 16 GB                               │
 │   worker/   providers: llama.cpp · executor de jobs        │
 │   content/  esteira (./dark, painel :8765) ─┬─ llama.cpp     │
 │                                             ├─ faster-whisper│
 │                                             ├─ Craft Apps CLI│
 │                                             └─ RealVisXL     │
 │   ~/Documents/github/obsidian (vault)   ~/agent-data (mídia) │
 └──────────────────────────────────────────────────────────────┘
```

GPU: a esteira já serializa trabalhos pesados (`core/locks.py`, uma vaga por vez) e libera
a VRAM antes do Whisper e do SDXL (`liberar_gpu()`). O worker passa a respeitar a mesma trava:
respostas rápidas (chat) só esperam se a vaga estiver ocupada por um job pesado.

## 5. Módulos de domínio

| Módulo | Pasta | Dados | IA / GPU |
|---|---|---|---|
| Arquivos (biblioteca de estudo) | `modulos/arquivos` + `backend/arquivos` | PDF/DOCX/PPTX, traços, destaques com texto | — (LibreOffice converte) |
| Empreendimento (YouTube ×5) | `modulos/empreendimento` (+ `youtube/` em `/api/youtube`) | episódios, acervo, perfis; canais/temas/histórias/roteiros/planos/métodos como notas do cofre | pipeline completo (`esteira/`) |
| Estudos (conhecimento + idiomas) | `modulos/estudos` | índice do vault, backlinks, embeddings, trilhas A1–C2 | resumos, RAG, exercícios, cronogramas |
| Saúde (espiritual, físico, mental) | `modulos/saude` | leituras, treinos, cargas, hábitos, diário | reflexões, ajustes de treino |
| Rotinas (Kanban + timer) | `modulos/rotinas` | quadros, tarefas, sessões de tempo | respostas rápidas |
| Design (quadro branco) | `modulos/design` (`/api/design`) | quadros: traços vetoriais com pressão, formas, textos (JSON) | — |
| Eletrônica (CAD de circuitos) | `modulos/eletronica` (`/api/eletronica`) | projetos: esquemático (componentes, fios, rótulos, folhas), biblioteca de símbolos | simulação ngspice no worker (fase 3) |
| Código (codificação a distância) | `modulos/codigo` (`/api/codigo`) | abas: etapas do Claude Code (JSONL), imagens de referência | Claude Code no worker do PC, no repositório |
| Finanças | `modulos/financas` | transações (OFX/CSV), empresas, DRE (CVM) | categorização, indicadores |
| Painel (Dashboard + Cobrador) | `modulos/painel` | requisições do gateway, rastro da esteira, metas, desvios | detecta desvios, redige cobranças |

## 6. Estrutura do repositório

```
agent/
├── pyproject.toml · uv.lock      # workspace uv + ruff/mypy/pytest
├── pubspec.yaml · pubspec.lock   # pub workspace do Flutter
├── plataforma/                   # núcleo comum, sem regra de domínio
│   ├── backend/                  # FastAPI na VPS (ex-llm_gateway/gateway; pacote `backend`)
│   ├── worker/                   # cliente WS no PC com GPU (ex-llm_gateway/worker)
│   ├── shared/                   # protocolo WS e schemas (ex-llm_gateway/shared)
│   ├── app/                      # app Flutter principal (web, Linux, Android): navegação entre módulos
│   ├── app_core/                 # pacote Flutter comum: Modulo, ApiCliente, Sondagem, tema
│   └── app_notas/                # notas reutilizáveis (editor, relações, análise); backend em backend/notas
├── modulos/
│   ├── empreendimento/
│   │   ├── esteira/              # ex-esteira-dark: ./dark, painel + API /api/v1, perfis, testes (venv próprio)
│   │   └── app/                  # telas Flutter: produção, roteiros, fila, máquina, episódio
│   ├── estudos/  saude/  rotinas/  design/  financas/  painel/
│   │   └── (cada um)  backend/  worker/  app/   ← criados quando houver código
├── infra/
│   ├── docker/                   # compose, Dockerfile do backend, nginx
│   └── scripts/                  # run_gateway / run_worker / llm_gateway (.sh e .ps1)
└── docs/
    ├── ARCHITECTURE.md
    └── gateway/                  # docs herdadas do llm_gateway
```

Contratos entre plataforma e módulos:
- **Backend:** cada `modulos/<m>/backend` é um pacote do workspace uv (`agent-<m>`) que expõe um
  `APIRouter`; a plataforma o monta em `/api/<m>`. Uma só migração Alembic, com uma pasta de versões
  por módulo.
- **Worker:** cada `modulos/<m>/worker` registra executores por tipo de job (`<m>.<ação>`); o worker
  da plataforma recebe o job pelo WebSocket e despacha. Para a esteira, o executor chama o `./dark`.
- **App:** cada `modulos/<m>/app` é um pacote Flutter (`agent_<m>`) que exporta suas rotas; o app da
  plataforma junta todos num pub workspace.

## 7. Roteiro

| Fase | Entrega | Critério de pronto |
|---|---|---|
| **0a. Migração** ✅ | merge do `llm_gateway` com histórico; esteira em `modulos/empreendimento/esteira`; `AGENT_DATA`; workspace uv | 20 testes da plataforma e 32 da esteira passando; `./dark status` lista os episódios; FilmCraft abre os projetos migrados |
| **App Empreendimento** ✅ | app Flutter (shell + `app_core` + telas do Empreendimento) sobre a API JSON da esteira | produção, roteiros, fila e máquina com dados reais; web rodando |
| **0b. Ponte** | OllamaProvider; Postgres + Alembic (etapa 6 do gateway); mensagens de job | um chat do celular é respondido pela GPU de casa; `./dark all` disparado pela fila |
| 1. Rotina | Kanban, timer, Cobrador, Dashboard básico no Flutter | uso diário real |
| 2. Conhecimento | índice do vault, backlinks, grafo, RAG, idiomas | — |
| 3. Conteúdo na plataforma | fila, status e aprovação humana no Flutter; upload pela YouTube Data API | 5 canais publicando com revisão humana |
| 4. Demais | finanças, saúde, quadro branco com S-Pen; editor visual em Flutter | — |

## 8. Restrições externas

- YouTube Data API: 10.000 unidades/dia por padrão, e cada upload custa cerca de 1.600, o que
  dá uns 6 uploads/dia; pedir aumento de cota cedo.
- Política de monetização do YouTube contra conteúdo repetitivo: revisão humana obrigatória.
- Openverse sem chave: 200 buscas/dia.
