# LLM Gateway

## Objetivo

Muita gente tem uma máquina pessoal (desktop com GPU, notebook) rodando
modelos de LLM localmente via **LM Studio**, **Ollama**, `vLLM` ou
`llama.cpp`. O problema: essa máquina fica na sua rede doméstica, sem IP
público fixo, atrás de NAT/firewall — então ferramentas que rodam fora dela
(Claude Code, Cursor, Continue.dev, Open WebUI, um SDK OpenAI em outro
computador) não conseguem falar com ela diretamente.

O **LLM Gateway** resolve isso com uma VPS pública no meio do caminho:

- A VPS expõe uma API **100% compatível com a API da OpenAI**
  (`/v1/chat/completions`, `/v1/models`, etc.), então qualquer cliente que já
  sabe falar com a OpenAI funciona aqui só trocando a URL base e a chave de
  API — sem plugin nem SDK específico.
- A máquina pessoal roda um **Worker** que se conecta *de dentro para fora*
  na VPS (WebSocket), autentica, e fica esperando requisições chegarem por
  essa conexão.
- **A VPS nunca inicia conexão com a máquina pessoal.** Isso é o princípio
  central do desenho: a máquina pessoal não precisa abrir nenhuma porta no
  roteador nem ter IP público — ela só precisa conseguir *sair* para a
  internet, o que qualquer rede doméstica já permite.

```
Cliente OpenAI-compatible (Claude Code, Cursor, Continue.dev, ...)
        │  HTTPS
        ▼
      Nginx (VPS)  ← certificado TLS (Let's Encrypt/certbot), opcionalmente atrás do Cloudflare
        │
        ▼
  LLM Gateway (VPS)  ← este repositório
        │  WebSocket (conexão iniciada pelo Worker, não pela VPS)
        ▼
   Worker (máquina pessoal)
        │
        ▼
     LM Studio / Ollama / vLLM / llama.cpp
```

Veja [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) para o detalhamento da
arquitetura (Clean Architecture, Provider Pattern, protocolo Worker↔Gateway)
e o roadmap completo de etapas.

> **Status atual:** Etapa 3 (+ fatia de 4/5) — Worker real conectado via
> WebSocket. O Gateway expõe `/health`, `GET /v1/models` (mock, substituído
> pelos modelos reais assim que um Worker conecta) e `POST
> /v1/chat/completions` roteado de ponta a ponta até o LM Studio da sua
> máquina pessoal. Autenticação de worker usa a lista estática
> `GATEWAY_WORKER_API_KEYS`; balanceamento entre múltiplos workers,
> streaming incremental de verdade, persistência (Postgres/Redis) e
> autenticação de cliente/JWT ainda não existem — ficam para as próximas
> etapas do roadmap.

## Onde cada peça roda

| Peça | Máquina | O que é hoje |
|------|---------|--------------|
| `gateway/` (este código) | VPS | Funciona — API FastAPI com `/health`, `/v1/models` e `/v1/chat/completions` roteando para workers conectados |
| Nginx + certbot | VPS | Config pronta neste repo — reverse proxy/TLS na frente do Gateway |
| `worker/` (este código) | Máquina pessoal (onde roda o LM Studio/Ollama) | Funciona — conecta no Gateway via WebSocket, autentica, reconecta com backoff, e encaminha chat completions para o LM Studio local |
| LM Studio / Ollama | Máquina pessoal | Você já roda por conta própria, hoje, independente deste projeto |

## Requisitos

- Python 3.12+
- Docker + Docker Compose (opcional, para rodar via container ou fazer o
  deploy na VPS)

## Rodando localmente (sem Docker)

Para desenvolver o Gateway na sua própria máquina (não é o deploy de
produção — é só subir o servidor localmente para testar/editar código):

**Linux/macOS:**

```bash
./scripts/run_gateway.sh
```

**Windows (PowerShell):**

```powershell
.\scripts\run_gateway.ps1
```

Os scripts criam um virtualenv em `.venv`, instalam os pacotes `shared` e
`gateway` em modo editável, copiam `gateway/.env.example` para
`gateway/.env` (se ainda não existir) e sobem o servidor em
`http://localhost:48080`.

Confira que está no ar:

```bash
curl http://localhost:48080/health
curl http://localhost:48080/v1/models
```

Resposta esperada do `/health`:

```json
{"status": "ok", "app_name": "LLM Gateway", "version": "0.1.0", "environment": "development"}
```

A documentação interativa (Swagger) fica em `http://localhost:48080/docs`.

## Rodando via Docker (local)

```bash
cp gateway/.env.example gateway/.env
docker compose -f docker/docker-compose.yml up --build gateway
```

Ou, usando o script de conveniência (faz a mesma coisa, em segundo plano):

```bash
./scripts/llm_gateway.sh -home -up      # sobe
./scripts/llm_gateway.sh -home -down    # derruba
```

```powershell
.\scripts\llm_gateway.ps1 -home -up     # sobe
.\scripts\llm_gateway.ps1 -home -down   # derruba
```

O Gateway sobe em `http://localhost:48080`, com healthcheck automático
configurado no container. Repare que aqui subimos só o serviço `gateway` —
os serviços `nginx`/`certbot` do mesmo compose file são para o deploy em
produção (próxima seção) e não fazem sentido rodando localmente.

## Deploy em produção (VPS)

O `docker/docker-compose.yml` já traz três serviços:

- **`gateway`** — a API. Publica a porta 48080 só em `127.0.0.1` (não é
  acessível direto da internet) — quem recebe tráfego externo é sempre o
  nginx, nunca o gateway diretamente.
- **`nginx`** — reverse proxy que termina TLS (HTTPS) e encaminha para o
  gateway.
- **`certbot`** — emite e renova automaticamente o certificado Let's
  Encrypt usado pelo nginx.

Existem **dois cenários** de VPS, dependendo se ela é dedicada a este
projeto ou já hospeda outras coisas. Escolha o seu.

### Cenário A — VPS dedicada só a este projeto

Ninguém mais está usando as portas 80/443 dessa VPS. Nesse caso, o nginx
deste repo pode assumir as duas portas.

**1. Copie o gateway e o exemplo de config do nginx para a VPS**, e gere o
`nginx.conf` real a partir do exemplo (mesma lógica do `.env`/`.env.example`
— o exemplo é genérico e vai para o git, o real tem seu domínio e fica só na
VPS):

```bash
cp docker/nginx/nginx.conf.example docker/nginx/nginx.conf
# edite docker/nginx/nginx.conf e troque "seu-dominio.exemplo.com" pelo
# domínio real da sua VPS
```

**2. Configure o DNS** do domínio apontando o registro A para o IP da VPS.
Se for usar Cloudflare, veja a seção **Cloudflare** logo abaixo antes de
continuar — a ordem dos passos importa para a primeira emissão do
certificado.

**3. Suba o gateway e o nginx (o bloco HTTPS do nginx começa comentado,
porque o certificado ainda não existe — só o bloco HTTP/80 sobe agora):**

```bash
docker compose -f docker/docker-compose.yml up -d gateway nginx
```

**4. Emita o certificado** (o nginx já está de pé na porta 80 respondendo
o desafio HTTP-01 do Let's Encrypt via webroot):

```bash
docker compose -f docker/docker-compose.yml run --rm certbot \
  certonly --webroot -w /var/www/certbot \
  -d seu-dominio.exemplo.com --email SEU_EMAIL --agree-tos
```

**5. Descomente o server block HTTPS (443)** em `docker/nginx/nginx.conf` e
reinicie o nginx para ele passar a servir HTTPS:

```bash
docker compose -f docker/docker-compose.yml restart nginx
```

**6. Deixe a renovação automática rodando** (loop que roda `certbot renew`
a cada 12h — os certificados do Let's Encrypt expiram em 90 dias):

```bash
docker compose -f docker/docker-compose.yml up -d certbot
```

Pronto: `https://seu-dominio.exemplo.com/health` deve responder.

A partir daqui, o dia a dia (reiniciar a VPS, subir depois de um `git pull`,
etc.) pode usar o script de conveniência em vez de repetir os comandos acima
— veja [Scripts de conveniência](#scripts-de-conveniência) mais abaixo.

### Cenário B — VPS compartilhada (já tem outros domínios/serviços)

Se a VPS já roda outro nginx (instalado direto no host, fora de Docker) —
ou outro reverse proxy — nas portas 80/443, **não suba o serviço `nginx`
deste repo**: ele tentaria ocupar as mesmas portas e não subiria (`bind:
address already in use`). Em vez disso, você adiciona `seu-dominio.exemplo.com`
como mais um site no nginx que já existe.

**1. Suba só o gateway** (continua publicando `127.0.0.1:48080`, é só isso
que o nginx do host vai precisar enxergar):

```bash
docker compose -f docker/docker-compose.yml up -d gateway
```

**2. Adicione um novo site no nginx do host**, usando
[docker/nginx/host-nginx-site.conf.example](docker/nginx/host-nginx-site.conf.example)
como modelo (a diferença para o `nginx.conf.example` padrão é só o
`proxy_pass`, que aponta para `127.0.0.1:48080` em vez do hostname interno
`gateway` da rede Docker deste projeto):

```bash
sudo cp docker/nginx/host-nginx-site.conf.example \
  /etc/nginx/sites-available/seu-dominio.exemplo.com.conf
sudo ln -s /etc/nginx/sites-available/seu-dominio.exemplo.com.conf \
  /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

**3. Emita o certificado com o certbot já instalado nessa VPS** (a mesma
instalação que já cuida dos outros domínios — não precisa do serviço
`certbot` deste repo nesse cenário):

```bash
sudo certbot --nginx -d seu-dominio.exemplo.com
```

O plugin `--nginx` do certbot edita o arquivo de site sozinho, adicionando
os caminhos do certificado e o redirect HTTP→HTTPS. Ele também já cuida da
renovação automática via um timer/cron que o pacote `certbot` instala no
sistema — não precisa criar outro loop de renovação.

### Cloudflare (proxy + HTTPS)

Se o domínio estiver no Cloudflare, ele fica entre o cliente e a sua VPS
como um proxy reverso adicional: `Cliente → Cloudflare → nginx (VPS) →
Gateway`. Isso muda duas coisas:

**1. Modo de SSL/TLS do Cloudflare — use "Full (strict)".**
No painel Cloudflare, em *SSL/TLS → Overview*, tem 4 modos:

- ❌ **Flexible** — Cloudflare fala HTTPS com o visitante, mas HTTP puro com
  a sua VPS. Evite: além de deixar o tráfego Cloudflare→VPS sem
  criptografia, costuma causar **loop de redirecionamento infinito**, porque
  o nginx deste repo redireciona toda requisição HTTP (80) para HTTPS (443)
  — e o Cloudflare, em modo Flexible, insiste em falar HTTP com a origem.
- ⚠️ **Full** — criptografa Cloudflare→VPS, mas aceita certificado
  autoassinado na origem (não valida). Funciona, mas não valida se é
  realmente a sua VPS do outro lado.
- ✅ **Full (strict)** — criptografa Cloudflare→VPS **e** valida o
  certificado da origem contra uma CA pública. **Recomendado**, e já
  funciona com o certificado Let's Encrypt que o certbot emite nos dois
  cenários acima — não precisa gerar um "Origin Certificate" especial do
  Cloudflare.
- **Strict (SSL-Only Origin Pull)** — variante ainda mais restrita; não é
  necessária aqui.

**2. Emissão do primeiro certificado: deixe o DNS em "DNS only" antes.**
O desafio HTTP-01 do Let's Encrypt (`/.well-known/acme-challenge/...`)
precisa alcançar a sua VPS diretamente na primeira vez. Se o registro DNS já
estiver "Proxied" (nuvem laranja) com "Always Use HTTPS" ligado, a
validação pode ser redirecionada e falhar. Passo seguro:

1. Crie o registro A do domínio no Cloudflare como **"DNS only"** (nuvem
   cinza).
2. Rode a emissão do certificado (passo 4 do Cenário A, ou o `certbot
   --nginx` do Cenário B).
3. Depois do certificado emitido com sucesso, mude o registro para
   **"Proxied"** (nuvem laranja) e o modo SSL/TLS para **Full (strict)**.

Renovações automáticas seguintes funcionam normalmente com o domínio já
proxied, porque só a rota `/.well-known/acme-challenge/` fica fora do
redirect para HTTPS na config deste repo.

**3. (Opcional/avançado) IP real do visitante.** Com o Cloudflare como
proxy, o nginx enxerga o IP do Cloudflare como se fosse o do cliente, não o
IP real de quem fez a requisição — relevante quando o Gateway tiver rate
limit por IP (roadmap). Para recuperar o IP real, o nginx precisa confiar
nos ranges de IP do Cloudflare (lista oficial e estável em
https://www.cloudflare.com/ips/) e ler o header `CF-Connecting-IP` via as
diretivas `set_real_ip_from` / `real_ip_header` — isso ainda não está no
`nginx.conf.example` deste repo porque a lista de IPs muda com o tempo;
adicione quando a Etapa de rate limit chegar.

## Scripts de conveniência

Os scripts `scripts/llm_gateway.sh` (Linux/macOS/VPS) e
`scripts/llm_gateway.ps1` (Windows) encapsulam os comandos `docker compose`
usados acima, para não precisar decorá-los:

```bash
./scripts/llm_gateway.sh -vps -up        # VPS: sobe gateway + nginx + certbot
./scripts/llm_gateway.sh -vps -down      # VPS: derruba os três serviços
./scripts/llm_gateway.sh -home -up       # máquina local: sobe só o gateway
./scripts/llm_gateway.sh -home -down     # máquina local: derruba o gateway
```

```powershell
.\scripts\llm_gateway.ps1 -vps -up       # VPS: sobe gateway + nginx + certbot
.\scripts\llm_gateway.ps1 -vps -down     # VPS: derruba os três serviços
.\scripts\llm_gateway.ps1 -home -up      # máquina local: sobe só o gateway
.\scripts\llm_gateway.ps1 -home -down    # máquina local: derruba o gateway
```

Os dois copiam `gateway/.env.example` para `gateway/.env` automaticamente se
ainda não existir. O modo `-vps` também exige que `docker/nginx/nginx.conf`
já exista (gerado a partir do `.example` — veja **Deploy em produção**
acima); sem ele, o script para com um aviso em vez de subir o nginx
quebrado. Esses scripts assumem que o bootstrap inicial do certificado
(passos 1–4 do Cenário A, ou o `certbot --nginx` do Cenário B) já foi feito
— eles só automatizam o subir/derrubar do dia a dia.

## Máquina pessoal (Worker + LM Studio / Ollama)

Essa é a máquina onde os modelos realmente rodam. O Worker conecta *para
fora* na VPS via WebSocket, autentica com uma `WORKER_API_KEY`, e fica
encaminhando chat completions para o servidor OpenAI-compatible local
(LM Studio por padrão). Nenhuma porta precisa ser aberta no roteador nem
exposta à internet — a VPS nunca inicia conexão com essa máquina.

**1. Suba o servidor local do provider:**

- **LM Studio**: aba *Developer* → *Start Server*, normalmente em
  `http://localhost:1234`.
- **Ollama**: `ollama serve` (ou já roda como serviço), normalmente em
  `http://localhost:11434/v1` no modo de compatibilidade OpenAI.

**2. Configure o Worker:**

```bash
cp worker/.env.example worker/.env
```

Edite `worker/.env`:
- `WORKER_GATEWAY_URL` — endereço WebSocket do seu Gateway (ex.:
  `wss://llm.seu-dominio.com/ws/worker`).
- `WORKER_API_KEY` — precisa ser um dos valores em `GATEWAY_WORKER_API_KEYS`
  no `.env` do Gateway (na VPS).
- `WORKER_PROVIDER_BASE_URL` — `http://localhost:1234/v1` (LM Studio) por
  padrão; troque se estiver usando Ollama ou outra porta.

**3. Suba o Worker:**

```bash
./scripts/run_worker.sh
```

```powershell
.\scripts\run_worker.ps1
```

O script cria o virtualenv, instala `shared` e `worker` em modo editável, e
conecta ao Gateway — reconectando automaticamente (com backoff exponencial)
se a conexão cair. Com o Worker conectado, `GET /v1/models` no Gateway passa
a listar os modelos reais do LM Studio, e `POST /v1/chat/completions` já
roteia de ponta a ponta.

## Rodando os testes

```bash
python -m venv .venv
# Linux/macOS: source .venv/bin/activate
# Windows:     .venv\Scripts\Activate.ps1
pip install -e "./shared" -e "./gateway[dev]" -e "./worker[dev]"
pytest
```

Lint e type-check:

```bash
ruff check .
mypy gateway/src worker/src shared/src
```

## Configuração

Todas as variáveis de ambiente do Gateway usam o prefixo `GATEWAY_` e estão
documentadas em [gateway/.env.example](gateway/.env.example). Esse arquivo é
genérico de propósito — sem domínio ou chaves de nenhuma instalação
específica — para que qualquer pessoa possa usar este Gateway em seu próprio
projeto. O arquivo real `gateway/.env` (com seus segredos) nunca é
commitado. Veja [SECURITY.md](SECURITY.md) para como gerar suas próprias
chaves com segurança.

A mesma convenção vale para o nginx: `docker/nginx/nginx.conf.example` e
`docker/nginx/host-nginx-site.conf.example` são genéricos e vão para o git;
os arquivos reais (`docker/nginx/nginx.conf`, os sites em
`/etc/nginx/sites-available` da VPS) têm o domínio de verdade e nunca são
commitados.

> Os campos de segredo (`GATEWAY_CLIENT_API_KEYS`, `GATEWAY_WORKER_API_KEYS`,
> `GATEWAY_JWT_SECRET_KEY`) já existem na configuração, mas ainda não são
> validados por nenhum endpoint — a lógica de autenticação chega na Etapa 3
> do roadmap.

## Estrutura do monorepo

```
llm-gateway/
├── gateway/     # API OpenAI-compatible (roda na VPS)
├── docker/      # Dockerfiles, docker-compose e configs de nginx
├── tests/       # Testes automatizados
├── scripts/     # Scripts de desenvolvimento e operação
└── docs/        # Documentação de arquitetura
```

Os diretórios `worker/`, `providers/`, `shared/`, `dashboard/`,
`sdk-python/` e `sdk-js/` serão adicionados nas próximas etapas, conforme o
roadmap em [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Licença

[MIT](LICENSE)
