"""Files generated from manifest + vault. Never edited by hand.

The repository's nginx templates and Dockerfiles are reused; only the domain, published ports and
names (rate-limit zone, log format) are replaced, to coexist with the current installation.
"""

from __future__ import annotations

import io
import os
import re
import shutil
import tarfile
from pathlib import Path

from . import names, secret_store
from .manifest import Manifest
from .vault import Vault

# Repository files sent to the VPS to build the images.
_GATEWAY_SOURCES = [
    "plataforma/shared",
    "plataforma/backend",
    "modulos/saude/backend", "modulos/estudos/backend", "modulos/rotinas/backend",
    "modulos/design/backend", "modulos/eletronica/backend", "modulos/codigo/backend",
    "modulos/financas/backend", "modulos/painel/backend", "modulos/concursos/backend",
    "modulos/empreendimento/youtube",
    "infra/docker/backend",
    "infra/docker/tunel/Dockerfile", "infra/docker/tunel/entrypoint.sh", "infra/docker/tunel/sshd_config",
]
_EXCLUDE = re.compile(
    r"(^|/)(\.env(\..*)?|.*\.bak|__pycache__|\.venv[^/]*|tests?|\.pytest_cache|\.ruff_cache|.*\.pyc|"
    r"authorized_keys|chave_pc(\.pub)?|local\.properties|node_modules|build)(/|$)"
)
_PERMITIR = re.compile(r"(^|/)\.env\.example$")


def repository_root() -> Path:
    """Monorepo root. Installed from the .deb the core lives in /opt, so the launcher passes the
    repository in SOLUMIA_REPO; in development it is found from this file's path."""
    configured = os.environ.get("SOLUMIA_REPO", "")
    if configured:
        return Path(configured)
    return Path(__file__).resolve().parents[4]


def _replace_names(text: str) -> str:
    return (text.replace("agent_login", names.ZONA_LOGIN_NGINX)
                 .replace("agent_sem_token", f"{names.PREFIX}_sem_token")
                 .replace("agent-seguranca.conf", names.NGINX_SECURITY_CONF))


# --- source package -------------------------------------------------------------------------------
def source_package(root: Path | None = None) -> bytes:
    """tar.gz with only what the images need; secrets and caches stay out (checked)."""
    root = root or repository_root()
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", compresslevel=6) as tar:
        for rel in _GATEWAY_SOURCES:
            origin = root / rel
            if not origin.exists():
                raise FileNotFoundError(f"faltando no repositório: {rel}")
            files = [origin] if origin.is_file() else sorted(p for p in origin.rglob("*") if p.is_file())
            for p in files:
                relative = p.relative_to(root).as_posix()
                if _EXCLUDE.search(relative) and not _PERMITIR.search(relative):
                    continue
                info = tar.gettarinfo(str(p), arcname=relative)
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.mode = 0o755 if info.mode & 0o111 else 0o644
                with p.open("rb") as f:
                    tar.addfile(info, f)
    return buf.getvalue()


# --- docker compose --------------------------------------------------------------------------------
def compose(nginx_no_docker: bool) -> str:
    """Solumia docker-compose. Project `solumia`: its own container, network and volume names."""
    nginx = """
  nginx:
    image: nginx:1.27-alpine
    depends_on: [gateway, tunel, collabora]
    command: ["/bin/sh", "-c", "while :; do sleep 6h; nginx -s reload; done & exec nginx -g 'daemon off;'"]
    ports: ["80:80", "443:443"]
    volumes:
      - ./nginx/site.conf:/etc/nginx/conf.d/default.conf:ro
      - ./nginx/seguranca-http.conf:/etc/nginx/conf.d/00-seguranca.conf:ro
      - certbot-www:/var/www/certbot:ro
      - certbot-etc:/etc/letsencrypt:ro
    restart: unless-stopped

  certbot:
    image: ${CERTBOT_IMAGEM:-certbot/certbot:latest}
    volumes:
      - certbot-www:/var/www/certbot
      - certbot-etc:/etc/letsencrypt
    entrypoint: >
      sh -c "trap exit TERM; while :; do certbot renew --webroot -w /var/www/certbot --quiet; sleep 12h; done"
    restart: unless-stopped
""" if nginx_no_docker else ""
    return f"""# Gerado pelo configurador do Solumia. Não edite: altere no configurador e aplique.
name: {names.COMPOSE_PROJECT}

services:
  gateway:
    build:
      context: ./fonte
      dockerfile: infra/docker/backend/Dockerfile
    image: {names.GATEWAY_IMAGE}:local
    env_file: [./gateway.env]
    environment:
      GATEWAY_HOST: 0.0.0.0
      GATEWAY_PORT: {names.GATEWAY_CONTAINER_PORT}
    ports: ["127.0.0.1:{names.GATEWAY_HOST_PORT}:{names.GATEWAY_CONTAINER_PORT}"]
    volumes: ["{names.DATA_VOLUME}:/home/gateway/agent-data"]
    read_only: false
    security_opt: ["no-new-privileges:true"]
    cap_drop: [ALL]
    restart: unless-stopped

  tunel:
    build: ./fonte/infra/docker/tunel
    image: {names.TUNNEL_IMAGE}:local
    ports:
      - "{names.SSH_TUNNEL_PORT}:2222"
      - "127.0.0.1:{names.PIPELINE_TUNNEL_HOST_PORT}:8765"
    volumes:
      - ./tunel/authorized_keys:/config/authorized_keys:ro
      - tunel-chaves:/etc/ssh/chaves
    security_opt: ["no-new-privileges:true"]
    restart: unless-stopped

  collabora:
    image: ${{COLLABORA_IMAGEM:-collabora/code:latest}}
    cap_add: [MKNOD]
    environment:
      aliasgroup1: http://gateway:{names.GATEWAY_CONTAINER_PORT}
      extra_params: --o:ssl.enable=false --o:ssl.termination=true
      server_name: ${{COLLABORA_DOMINIO:-}}
      dictionaries: pt_BR en_US
      username: admin
      password: ${{COLLABORA_ADMIN_SENHA:-}}
    ports: ["127.0.0.1:{names.COLLABORA_HOST_PORT}:9980"]
    restart: unless-stopped
{nginx}
volumes:
  {names.DATA_VOLUME}:
  tunel-chaves:
  certbot-www:
  certbot-etc:
"""


def env_compose(m: Manifest, vault: Vault, imagens: dict[str, str]) -> str:
    """Compose `.env` (interpolation variables): pinned images and the Collabora password."""
    lines = [f"{k}={v}" for k, v in sorted(imagens.items())]
    # Domain already validated by the manifest; urlsafe password (no $ or quotes) so nothing is interpolated.
    lines.append(f"COLLABORA_DOMINIO={m.topologia.dominio}")
    password = vault.get_or_generate(secret_store.COLLABORA_PASSWORD, lambda: secret_store.token())
    lines.append(f"COLLABORA_ADMIN_SENHA={password}")
    return "\n".join(lines) + "\n"


def env_gateway(m: Manifest, vault: Vault) -> str:
    domain = m.topologia.dominio
    v = {
        "GATEWAY_APP_NAME": names.DISPLAY_NAME,
        "GATEWAY_ENVIRONMENT": "production",
        "GATEWAY_DEBUG": "false",
        "GATEWAY_LOG_FORMAT": "json",
        "GATEWAY_LOG_LEVEL": "info",
        "GATEWAY_CORS_ORIGINS": f"https://{domain}",
        "GATEWAY_CLIENT_API_KEYS": vault.get_or_generate(
            secret_store.CLIENT_KEY, lambda: secret_store.token("sk_live_")
        ),
        "GATEWAY_WORKER_API_KEYS": vault.get_or_generate(
            secret_store.WORKER_KEY, lambda: secret_store.token("worker_")
        ),
        "GATEWAY_ADMIN_USUARIO": m.conta.usuario,
        "GATEWAY_ADMIN_SENHA_HASH": vault.require(secret_store.PASSWORD_HASH),
        "GATEWAY_ADMIN_TOTP_SEGREDO": vault.require(secret_store.TOTP),
        "GATEWAY_JWT_SECRET_KEY": vault.get_or_generate(secret_store.JWT, lambda: secret_store.token(tamanho=48)),
        "GATEWAY_COLLABORA_URL": f"https://{domain}",
        "GATEWAY_COLLABORA_INTERNO_URL": "http://collabora:9980",
        "GATEWAY_WOPI_BASE_URL": f"http://gateway:{names.GATEWAY_CONTAINER_PORT}",
        "GATEWAY_WOPI_SECRET": vault.get_or_generate(secret_store.WOPI, lambda: secret_store.token(tamanho=48)),
    }
    lines = ["# Gerado pelo configurador do Solumia. Contém segredos: modo 0600, não copiar."]
    for key, value in v.items():
        if "\n" in value or "'" in value:
            raise ValueError(f"valor inválido para {key}")
        lines.append(f"{key}='{value}'")
    return "\n".join(lines) + "\n"


def nginx_desafio(dominio: str) -> str:
    """Before the certificate: only port 80 with the Let's Encrypt challenge."""
    return (f"server {{\n    listen 80;\n    server_name {dominio};\n"
            "    location /.well-known/acme-challenge/ { root /var/www/certbot; }\n"
            "    location / { return 503; }\n}\n")


def nginx_site_docker(dominio: str, root: Path | None = None) -> str:
    root = root or repository_root()
    text = (root / "infra/docker/nginx/nginx.conf.example").read_text()
    return _replace_names(text.replace("seu-dominio.exemplo.com", dominio))


def nginx_site_host(dominio: str, root: Path | None = None) -> str:
    root = root or repository_root()
    text = (root / "infra/docker/nginx/host-nginx-site.conf.example").read_text()
    text = (text.replace("seu-dominio.exemplo.com", dominio)
                  .replace("127.0.0.1:48080", f"127.0.0.1:{names.GATEWAY_HOST_PORT}")
                  .replace("127.0.0.1:18765", f"127.0.0.1:{names.PIPELINE_TUNNEL_HOST_PORT}")
                  .replace("127.0.0.1:9980", f"127.0.0.1:{names.COLLABORA_HOST_PORT}"))
    return _replace_names(text)


# Directives of the security conf that nginx accepts only once per http context.
NGINX_SINGLE_DIRECTIVES = ("real_ip_header", "real_ip_recursive", "limit_req_status")


def nginx_security(root: Path | None = None, skip: tuple[str, ...] | list[str] = ()) -> str:
    """`skip`: directives the host nginx already sets; a second one would fail `nginx -t`."""
    root = root or repository_root()
    text = _replace_names((root / "infra/docker/nginx/seguranca-http.conf").read_text())
    kept = []
    for line in text.splitlines(keepends=True):
        words = line.split()
        if not words or words[0] not in skip:
            kept.append(line)
    return "".join(kept)


def authorized_keys_tunnel(public: str) -> str:
    # restrict: the key only opens the pipeline's reverse forwarding, nothing else.
    if not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/=]+( [\w.@-]+)?", public.strip()):
        raise ValueError("chave pública do túnel inválida")
    return f'restrict,port-forwarding,permitlisten="0.0.0.0:8765" {public.strip()}\n'


# --- host services (Linux, systemd --user) ---------------------------------------------------------
def worker_unit(dir_worker: Path, python: Path) -> str:
    return f"""# Gerado pelo configurador do Solumia.
[Unit]
Description={names.DISPLAY_NAME}: worker (conecta ao gateway)
After=network-online.target

[Service]
WorkingDirectory={dir_worker}
EnvironmentFile=%h/.config/{names.PREFIX}/worker.env
ExecStart={python} -m worker.main
Restart=always
RestartSec=5
NoNewPrivileges=yes

[Install]
WantedBy=default.target
"""


def tunnel_unit(host: str, port_ssh: int, key: Path, known_hosts: Path) -> str:
    return f"""# Gerado pelo configurador do Solumia.
[Unit]
Description={names.DISPLAY_NAME}: túnel reverso da esteira até a VPS
After=network-online.target

[Service]
ExecStart=/usr/bin/ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \\
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile={known_hosts} -i {key} -p {port_ssh} \\
  -R 0.0.0.0:8765:127.0.0.1:{names.PIPELINE_LOCAL_PORT} tunel@{host}
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
"""


# Where llama.cpp is usually built; systemd --user services do not see the shell's PATH.
LLAMA_SERVER_CANDIDATES = (
    Path.home() / "development/llama.cpp/build/bin/llama-server",
    Path.home() / "llama.cpp/build/bin/llama-server",
    Path.home() / ".local/bin/llama-server",
    Path("/usr/local/bin/llama-server"),
)


def llama_server_path() -> str:
    """Full path of llama-server, or the bare name when it cannot be found."""
    found = shutil.which("llama-server")
    if found:
        return found
    for candidate in LLAMA_SERVER_CANDIDATES:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return "llama-server"


def env_worker(m: Manifest, vault: Vault) -> str:
    return (
        "# Gerado pelo configurador do Solumia. Contém a chave do worker.\n"
        f"WORKER_NAME={names.PREFIX}-worker\n"
        f"WORKER_GATEWAY_URL=wss://{m.topologia.dominio}/ws/worker\n"
        f"WORKER_API_KEY={vault.require(secret_store.WORKER_KEY)}\n"
        f"WORKER_LLAMA_PORTA={names.LLAMA_LOCAL_PORT}\n"
        f"WORKER_LLAMA_SERVER_BIN={llama_server_path()}\n"
    )
