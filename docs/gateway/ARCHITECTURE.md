# Arquitetura — LLM Gateway

## Visão geral

O LLM Gateway permite que qualquer cliente compatível com a API da OpenAI
(Claude Code, Cursor, Continue.dev, Cline, Roo Code, Open WebUI, SDKs
oficiais, etc.) utilize modelos rodando em uma máquina pessoal (via LM
Studio, Ollama, vLLM, llama.cpp, ...) sem que essa máquina seja exposta
diretamente à internet.

```
Cliente OpenAI-compatible
        │  HTTPS
        ▼
      Nginx (VPS)
        │
        ▼
  LLM Gateway (VPS)
        │  WebSocket (iniciado pelo Worker)
        ▼
   Worker (máquina pessoal)
        │
        ▼
     LM Studio / Ollama / vLLM / ...
```

Ponto central do desenho: **a VPS nunca inicia conexão com a máquina
pessoal**. É sempre o Worker quem conecta na VPS, autentica e mantém um
WebSocket aberto. O Gateway expõe a API pública e roteia requisições para o
Worker certo através dessa conexão já estabelecida.

## Módulos do monorepo

| Módulo         | Onde roda        | Responsabilidade                                             | Status  |
|----------------|-------------------|----------------------------------------------------------------|---------|
| `gateway/`     | VPS               | API OpenAI-compatible, auth, rate limit, roteamento, dashboard backend | Etapa 1 (fundação) |
| `worker/`      | Máquina pessoal   | Conecta no Gateway, descobre modelos, encaminha requisições    | Próximas etapas |
| `providers/`   | Dentro do Worker  | Abstração sobre LM Studio / Ollama / vLLM / llama.cpp          | Próximas etapas |
| `shared/`      | Ambos             | Contratos (schemas Pydantic) compartilhados entre Gateway e Worker | Próximas etapas |
| `dashboard/`   | VPS (servido pelo Gateway/Nginx) | UI React/Vite/TS de observabilidade                | Próximas etapas |
| `docker/`      | VPS               | Dockerfiles e docker-compose                                   | Etapa 1 (parcial) |
| `tests/`       | CI / dev          | Testes automatizados de todos os módulos                       | Etapa 1 (parcial) |
| `sdk-python/`  | Clientes          | SDK Python de conveniência                                     | Próximas etapas |
| `sdk-js/`      | Clientes          | SDK Node/JS de conveniência                                    | Próximas etapas |

## Princípios de arquitetura

- **Clean Architecture**: cada módulo separa `api` (transporte HTTP/WS),
  `core` (config, cross-cutting concerns), `domain` (entidades e regras de
  negócio) e `infrastructure` (banco, cache, providers externos). Camadas
  internas não dependem de camadas externas.
- **Provider Pattern**: o Worker nunca fala diretamente com "LM Studio" —
  fala com uma interface `Provider`. `LMStudioProvider` é a primeira
  implementação; `OllamaProvider`, `VLLMProvider`, `LlamaCppProvider` e
  `OpenAICompatibleProvider` são adicionados depois sem alterar o restante
  do sistema.
- **Protocolo próprio Worker↔Gateway**: mensagens tipadas sobre WebSocket
  (`{"type": "chat_request", "request_id": "...", "payload": {...}}`),
  desenhado para suportar streaming, heartbeat e múltiplos workers
  simultâneos.
- **Compatibilidade OpenAI estrita**: o formato JSON de request/response dos
  endpoints públicos (`/v1/chat/completions`, `/v1/models`, `/v1/responses`,
  `/v1/embeddings`) deve ser byte-a-byte compatível com a API da OpenAI, para
  que nenhum cliente precise saber que está falando com este Gateway.
- **Assíncrono de ponta a ponta**: FastAPI + `asyncio` + `httpx` no Gateway;
  `websockets`/`asyncio` no Worker.

## Roadmap de etapas

1. **Fundação do projeto e Gateway básico** *(esta etapa)* — estrutura do
   monorepo, app FastAPI com configuração via env, logging estruturado,
   middleware de request-id, health check, Docker do Gateway, testes e
   tooling (ruff/mypy/pytest).
2. **Endpoints OpenAI-compatible (mock)** — `GET /v1/models` e
   `POST /v1/chat/completions` (non-streaming e streaming SSE) servidos por
   um provider fake, para fechar o contrato de API antes de existir Worker.
3. **Protocolo Worker↔Gateway sobre WebSocket** — servidor WS no Gateway,
   cliente WS no Worker, autenticação de worker, heartbeat, reconexão com
   backoff exponencial.
4. **Provider Pattern + LMStudioProvider** — abstração `Provider`,
   implementação real para LM Studio, descoberta automática de modelos.
5. **Roteamento de requisições reais** — Gateway encaminha
   `chat_request`/`chat_response` fim-a-fim através do WebSocket até o
   LM Studio e de volta ao cliente, com streaming.
6. **Persistência (PostgreSQL + Alembic)** — modelos `workers`, `api_keys`,
   `requests`, `logs`, `models`, `users`; Repository Pattern.
7. **Autenticação e autorização** — API keys de cliente (`sk_live_...`),
   chaves de worker (`worker_...`), JWT onde fizer sentido.
8. **Redis** — cache, filas, rate limit, presença de workers online.
9. **Balanceamento entre múltiplos workers** — seleção por modelo, GPU,
   latência, carga.
10. **Dashboard (React/Vite/TS)**.
11. **Nginx + Docker Compose completo + scripts finais** (`ia_llm.sh` para
    subir o Gateway na VPS, `ia_llm.ps1` para subir o Worker local).
12. **Endurecimento para produção**: rate limit, retries, timeouts, CORS,
    logging estruturado completo, `/v1/embeddings`, `/v1/responses`,
    function/tool calling, imagens.

Cada etapa entrega algo executável e testável antes de avançar para a
próxima.

## Estrutura de diretórios (após esta etapa)

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

Diretórios como `worker/`, `providers/`, `shared/`, `dashboard/`,
`sdk-python/` e `sdk-js/` serão criados quando a etapa correspondente do
roadmap os utilizar, para evitar código morto no repositório.
