# LLM Gateway

## Goal

Many people have a personal machine (desktop with a GPU, laptop) running
LLMs locally through **LM Studio**, **Ollama**, `vLLM` or
`llama.cpp`. The problem: that machine sits on your home network, with no fixed
public IP, behind NAT/firewall — so tools running outside it
(Claude Code, Cursor, Continue.dev, Open WebUI, an OpenAI SDK on another
computer) cannot talk to it directly.

The **LLM Gateway** solves this with a public VPS in the middle:

- The VPS exposes an API **100% compatible with the OpenAI API**
  (`/v1/chat/completions`, `/v1/models`, etc.), so any client that already
  talks to OpenAI works here by just changing the base URL and the API
  key — no plugin or specific SDK.
- The personal machine runs a **Worker** that connects *inside-out*
  to the VPS (WebSocket), authenticates, and waits for requests to arrive over
  that connection.
- **The VPS never starts a connection to the personal machine.** This is the central
  principle of the design: the personal machine does not need to open any port on the
  router or have a public IP — it only needs to be able to *reach out* to the
  internet, which any home network already allows.

```
OpenAI-compatible client (Claude Code, Cursor, Continue.dev, ...)
        │  HTTPS
        ▼
      Nginx (VPS)  ← TLS certificate (Let's Encrypt/certbot), optionally behind Cloudflare
        │
        ▼
  LLM Gateway (VPS)  ← this repository
        │  WebSocket (connection opened by the Worker, not by the VPS)
        ▼
   Worker (personal machine)
        │
        ▼
     LM Studio / Ollama / vLLM / llama.cpp
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the architecture details
(Clean Architecture, Provider Pattern, Worker↔Gateway protocol)
and the full stage roadmap.

> **Current status:** Stage 3 (+ a slice of 4/5) — real Worker connected over
> WebSocket. The Gateway exposes `/health`, `GET /v1/models` (mock, replaced
> by the real models as soon as a Worker connects) and `POST
> /v1/chat/completions` routed end to end to the LM Studio on your
> personal machine. Worker authentication uses the static list
> `GATEWAY_WORKER_API_KEYS`; balancing across multiple workers,
> real incremental streaming, persistence (Postgres/Redis) and
> client/JWT authentication do not exist yet — they are left for the next
> roadmap stages.

## Where each piece runs

| Piece | Machine | What it is today |
|------|---------|--------------|
| `gateway/` (this code) | VPS | Works — FastAPI API with `/health`, `/v1/models` and `/v1/chat/completions` routing to connected workers |
| Nginx + certbot | VPS | Config ready in this repo — reverse proxy/TLS in front of the Gateway |
| `worker/` (this code) | Personal machine (where LM Studio/Ollama runs) | Works — connects to the Gateway over WebSocket, authenticates, reconnects with backoff, and forwards chat completions to the local LM Studio |
| LM Studio / Ollama | Personal machine | You already run it on your own, today, independently of this project |

## Requirements

- Python 3.12+
- Docker + Docker Compose (optional, to run in a container or to deploy
  to the VPS)

## Running locally (without Docker)

To develop the Gateway on your own machine (this is not the production
deploy — it only starts the server locally to test/edit code):

**Linux/macOS:**

```bash
./scripts/run_gateway.sh
```

**Windows (PowerShell):**

```powershell
.\scripts\run_gateway.ps1
```

The scripts create a virtualenv in `.venv`, install the `shared` and
`gateway` packages in editable mode, copy `gateway/.env.example` to
`gateway/.env` (if it does not exist yet) and start the server at
`http://localhost:48080`.

Check that it is up:

```bash
curl http://localhost:48080/health
curl http://localhost:48080/v1/models
```

Expected `/health` response:

```json
{"status": "ok", "app_name": "LLM Gateway", "version": "0.1.0", "environment": "development"}
```

The interactive documentation (Swagger) is at `http://localhost:48080/docs`.

## Running with Docker (local)

```bash
cp gateway/.env.example gateway/.env
docker compose -f docker/docker-compose.yml up --build gateway
```

Or, with the convenience script (does the same thing, in the background):

```bash
./scripts/llm_gateway.sh -home -up      # start
./scripts/llm_gateway.sh -home -down    # stop
```

```powershell
.\scripts\llm_gateway.ps1 -home -up     # start
.\scripts\llm_gateway.ps1 -home -down   # stop
```

The Gateway comes up at `http://localhost:48080`, with an automatic healthcheck
configured in the container. Note that only the `gateway` service starts here —
the `nginx`/`certbot` services in the same compose file are for the production
deploy (next section) and make no sense running locally.

## Production deploy (VPS)

`docker/docker-compose.yml` already ships three services:

- **`gateway`** — the API. Publishes port 48080 only on `127.0.0.1` (it is not
  reachable directly from the internet) — external traffic always goes to
  nginx, never to the gateway directly.
- **`nginx`** — reverse proxy that terminates TLS (HTTPS) and forwards to the
  gateway.
- **`certbot`** — issues and automatically renews the Let's Encrypt
  certificate used by nginx.

There are **two VPS scenarios**, depending on whether it is dedicated to this
project or already hosts other things. Pick yours.

### Scenario A — VPS dedicated to this project

Nobody else uses ports 80/443 on this VPS. In this case, this repo's nginx
can take both ports.

**1. Copy the gateway and the nginx config example to the VPS**, and generate the
real `nginx.conf` from the example (same logic as `.env`/`.env.example`
— the example is generic and goes to git, the real one has your domain and stays only on the
VPS):

```bash
cp docker/nginx/nginx.conf.example docker/nginx/nginx.conf
# edit docker/nginx/nginx.conf and replace "seu-dominio.exemplo.com" with
# your VPS's real domain
```

**2. Configure DNS** for the domain, pointing the A record to the VPS IP.
If you use Cloudflare, read the **Cloudflare** section below before
going on — the order of the steps matters for the first certificate
issuance.

**3. Start the gateway and nginx (the nginx HTTPS block starts commented out,
because the certificate does not exist yet — only the HTTP/80 block comes up now):**

```bash
docker compose -f docker/docker-compose.yml up -d gateway nginx
```

**4. Issue the certificate** (nginx is already up on port 80 answering
the Let's Encrypt HTTP-01 challenge through webroot):

```bash
docker compose -f docker/docker-compose.yml run --rm certbot \
  certonly --webroot -w /var/www/certbot \
  -d seu-dominio.exemplo.com --email YOUR_EMAIL --agree-tos
```

**5. Uncomment the HTTPS (443) server block** in `docker/nginx/nginx.conf` and
restart nginx so it serves HTTPS:

```bash
docker compose -f docker/docker-compose.yml restart nginx
```

**6. Leave automatic renewal running** (a loop that runs `certbot renew`
every 12h — Let's Encrypt certificates expire in 90 days):

```bash
docker compose -f docker/docker-compose.yml up -d certbot
```

Done: `https://seu-dominio.exemplo.com/health` should respond.

From here on, day-to-day work (restarting the VPS, starting after a `git pull`,
etc.) can use the convenience script instead of repeating the commands above
— see [Convenience scripts](#convenience-scripts) below.

### Scenario B — shared VPS (already has other domains/services)

If the VPS already runs another nginx (installed directly on the host, outside Docker) —
or another reverse proxy — on ports 80/443, **do not start this repo's `nginx`
service**: it would try to take the same ports and would not start (`bind:
address already in use`). Instead, you add `seu-dominio.exemplo.com`
as one more site in the existing nginx.

**1. Start only the gateway** (it keeps publishing `127.0.0.1:48080`, which is all
the host nginx needs to see):

```bash
docker compose -f docker/docker-compose.yml up -d gateway
```

**2. Add a new site to the host nginx**, using
[docker/nginx/host-nginx-site.conf.example](docker/nginx/host-nginx-site.conf.example)
as a template (the only difference from the default `nginx.conf.example` is the
`proxy_pass`, which points to `127.0.0.1:48080` instead of the internal
`gateway` hostname of this project's Docker network):

```bash
sudo cp docker/nginx/host-nginx-site.conf.example \
  /etc/nginx/sites-available/seu-dominio.exemplo.com.conf
sudo ln -s /etc/nginx/sites-available/seu-dominio.exemplo.com.conf \
  /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

**3. Issue the certificate with the certbot already installed on this VPS** (the same
installation that already handles the other domains — this repo's `certbot`
service is not needed in this scenario):

```bash
sudo certbot --nginx -d seu-dominio.exemplo.com
```

certbot's `--nginx` plugin edits the site file on its own, adding
the certificate paths and the HTTP→HTTPS redirect. It also handles
automatic renewal through a timer/cron that the `certbot` package installs on the
system — no need to create another renewal loop.

### Cloudflare (proxy + HTTPS)

If the domain is on Cloudflare, it sits between the client and your VPS
as an extra reverse proxy: `Client → Cloudflare → nginx (VPS) →
Gateway`. This changes two things:

**1. Cloudflare SSL/TLS mode — use "Full (strict)".**
In the Cloudflare dashboard, under *SSL/TLS → Overview*, there are 4 modes:

- ❌ **Flexible** — Cloudflare speaks HTTPS with the visitor, but plain HTTP with
  your VPS. Avoid it: besides leaving the Cloudflare→VPS traffic
  unencrypted, it usually causes an **infinite redirect loop**, because
  this repo's nginx redirects every HTTP (80) request to HTTPS (443)
  — and Cloudflare, in Flexible mode, keeps speaking HTTP to the origin.
- ⚠️ **Full** — encrypts Cloudflare→VPS, but accepts a self-signed
  certificate at the origin (does not validate it). It works, but does not check that it
  really is your VPS on the other side.
- ✅ **Full (strict)** — encrypts Cloudflare→VPS **and** validates the
  origin certificate against a public CA. **Recommended**, and it already
  works with the Let's Encrypt certificate that certbot issues in both
  scenarios above — no need to generate a special Cloudflare "Origin Certificate".
- **Strict (SSL-Only Origin Pull)** — an even stricter variant; not
  needed here.

**2. First certificate issuance: set DNS to "DNS only" first.**
The Let's Encrypt HTTP-01 challenge (`/.well-known/acme-challenge/...`)
has to reach your VPS directly the first time. If the DNS record is already
"Proxied" (orange cloud) with "Always Use HTTPS" on, the
validation can be redirected and fail. Safe steps:

1. Create the domain's A record on Cloudflare as **"DNS only"** (grey
   cloud).
2. Run the certificate issuance (step 4 of Scenario A, or the `certbot
   --nginx` of Scenario B).
3. Once the certificate is issued, switch the record to
   **"Proxied"** (orange cloud) and the SSL/TLS mode to **Full (strict)**.

Later automatic renewals work normally with the domain already
proxied, because only the `/.well-known/acme-challenge/` route stays outside the
HTTPS redirect in this repo's config.

**3. (Optional/advanced) Visitor's real IP.** With Cloudflare as a
proxy, nginx sees Cloudflare's IP as if it were the client's, not the
real IP of whoever made the request — relevant once the Gateway has per-IP rate
limiting (roadmap). To recover the real IP, nginx has to trust
Cloudflare's IP ranges (official, stable list at
https://www.cloudflare.com/ips/) and read the `CF-Connecting-IP` header through the
`set_real_ip_from` / `real_ip_header` directives — this is not yet in this repo's
`nginx.conf.example` because the IP list changes over time;
add it when the rate-limit stage arrives.

## Convenience scripts

The `scripts/llm_gateway.sh` (Linux/macOS/VPS) and
`scripts/llm_gateway.ps1` (Windows) scripts wrap the `docker compose` commands
used above, so you do not have to memorize them:

```bash
./scripts/llm_gateway.sh -vps -up        # VPS: starts gateway + nginx + certbot
./scripts/llm_gateway.sh -vps -down      # VPS: stops the three services
./scripts/llm_gateway.sh -home -up       # local machine: starts only the gateway
./scripts/llm_gateway.sh -home -down     # local machine: stops the gateway
```

```powershell
.\scripts\llm_gateway.ps1 -vps -up       # VPS: starts gateway + nginx + certbot
.\scripts\llm_gateway.ps1 -vps -down     # VPS: stops the three services
.\scripts\llm_gateway.ps1 -home -up      # local machine: starts only the gateway
.\scripts\llm_gateway.ps1 -home -down    # local machine: stops the gateway
```

Both copy `gateway/.env.example` to `gateway/.env` automatically if it
does not exist yet. The `-vps` mode also requires `docker/nginx/nginx.conf`
to exist already (generated from the `.example` — see **Production deploy**
above); without it, the script stops with a warning instead of starting a broken
nginx. These scripts assume the initial certificate bootstrap
(steps 1–4 of Scenario A, or the `certbot --nginx` of Scenario B) is already done
— they only automate the day-to-day start/stop.

## Personal machine (Worker + LM Studio / Ollama)

This is the machine where the models actually run. The Worker connects *outward*
to the VPS over WebSocket, authenticates with a `WORKER_API_KEY`, and keeps
forwarding chat completions to the local OpenAI-compatible server
(LM Studio by default). No port has to be opened on the router or
exposed to the internet — the VPS never starts a connection to this machine.

**1. Start the provider's local server:**

- **LM Studio**: *Developer* tab → *Start Server*, usually at
  `http://localhost:1234`.
- **Ollama**: `ollama serve` (or it already runs as a service), usually at
  `http://localhost:11434/v1` in OpenAI compatibility mode.

**2. Configure the Worker:**

```bash
cp worker/.env.example worker/.env
```

Edit `worker/.env`:
- `WORKER_GATEWAY_URL` — WebSocket address of your Gateway (e.g.
  `wss://llm.seu-dominio.com/ws/worker`).
- `WORKER_API_KEY` — must be one of the values in `GATEWAY_WORKER_API_KEYS`
  in the Gateway `.env` (on the VPS).
- `WORKER_PROVIDER_BASE_URL` — `http://localhost:1234/v1` (LM Studio) by
  default; change it if you use Ollama or another port.

**3. Start the Worker:**

```bash
./scripts/run_worker.sh
```

```powershell
.\scripts\run_worker.ps1
```

The script creates the virtualenv, installs `shared` and `worker` in editable mode, and
connects to the Gateway — reconnecting automatically (with exponential backoff)
if the connection drops. With the Worker connected, `GET /v1/models` on the Gateway
lists the real LM Studio models, and `POST /v1/chat/completions` already
routes end to end.

## Running the tests

```bash
python -m venv .venv
# Linux/macOS: source .venv/bin/activate
# Windows:     .venv\Scripts\Activate.ps1
pip install -e "./shared" -e "./gateway[dev]" -e "./worker[dev]"
pytest
```

Lint and type-check:

```bash
ruff check .
mypy gateway/src worker/src shared/src
```

## Configuration

Every Gateway environment variable uses the `GATEWAY_` prefix and is
documented in [gateway/.env.example](gateway/.env.example). That file is
generic on purpose — no domain or keys from any specific
install — so anyone can use this Gateway in their own
project. The real `gateway/.env` file (with your secrets) is never
committed. See [SECURITY.md](SECURITY.md) for how to generate your own
keys safely.

The same convention applies to nginx: `docker/nginx/nginx.conf.example` and
`docker/nginx/host-nginx-site.conf.example` are generic and go to git;
the real files (`docker/nginx/nginx.conf`, the sites in the VPS's
`/etc/nginx/sites-available`) have the real domain and are never
committed.

> The secret fields (`GATEWAY_CLIENT_API_KEYS`, `GATEWAY_WORKER_API_KEYS`,
> `GATEWAY_JWT_SECRET_KEY`) already exist in the configuration, but are not
> validated by any endpoint yet — the authentication logic arrives in roadmap
> Stage 3.

## Monorepo layout

```
llm-gateway/
├── gateway/     # OpenAI-compatible API (runs on the VPS)
├── docker/      # Dockerfiles, docker-compose and nginx configs
├── tests/       # Automated tests
├── scripts/     # Development and operations scripts
└── docs/        # Architecture documentation
```

The `worker/`, `providers/`, `shared/`, `dashboard/`,
`sdk-python/` and `sdk-js/` directories will be added in the next stages, following the
roadmap in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License

[MIT](LICENSE)
