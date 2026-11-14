"""Arquivos gerados a partir de manifesto + cofre. Nunca editados à mão.

Os modelos do nginx e os Dockerfiles do repositório são reaproveitados; só trocamos domínio, portas
publicadas e nomes (zona de limite, formato de log), para conviver com a instalação atual.
"""

from __future__ import annotations

import io
import re
import tarfile
from pathlib import Path

from . import names, secret_store
from .manifest import Manifesto
from .vault import Cofre

# Arquivos do repositório que vão para a VPS para construir as imagens.
_FONTES_GATEWAY = [
    "plataforma/shared",
    "plataforma/backend",
    "modulos/saude/backend", "modulos/estudos/backend", "modulos/rotinas/backend",
    "modulos/design/backend", "modulos/eletronica/backend", "modulos/codigo/backend",
    "modulos/financas/backend", "modulos/painel/backend", "modulos/concursos/backend",
    "modulos/empreendimento/youtube",
    "infra/docker/backend",
    "infra/docker/tunel/Dockerfile", "infra/docker/tunel/entrypoint.sh", "infra/docker/tunel/sshd_config",
]
_EXCLUIR = re.compile(
    r"(^|/)(\.env(\..*)?|.*\.bak|__pycache__|\.venv[^/]*|tests?|\.pytest_cache|\.ruff_cache|.*\.pyc|"
    r"authorized_keys|chave_pc(\.pub)?|local\.properties|node_modules|build)(/|$)"
)
_PERMITIR = re.compile(r"(^|/)\.env\.example$")


def raiz_repositorio() -> Path:
    """configurador/core/src/solumia_configurador/generate.py -> raiz do monorepo."""
    return Path(__file__).resolve().parents[4]


def _substituir_nomes(texto: str) -> str:
    return (texto.replace("agent_login", names.ZONA_LOGIN_NGINX)
                 .replace("agent_sem_token", f"{names.PREFIXO}_sem_token")
                 .replace("agent-seguranca.conf", names.CONF_SEGURANCA_NGINX))


# --- pacote de código-fonte -----------------------------------------------------------------------
def pacote_fonte(raiz: Path | None = None) -> bytes:
    """tar.gz só com o necessário para as imagens; segredos e caches ficam fora (conferido)."""
    raiz = raiz or raiz_repositorio()
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", compresslevel=6) as tar:
        for rel in _FONTES_GATEWAY:
            origem = raiz / rel
            if not origem.exists():
                raise FileNotFoundError(f"faltando no repositório: {rel}")
            arquivos = [origem] if origem.is_file() else sorted(p for p in origem.rglob("*") if p.is_file())
            for p in arquivos:
                relativo = p.relative_to(raiz).as_posix()
                if _EXCLUIR.search(relativo) and not _PERMITIR.search(relativo):
                    continue
                info = tar.gettarinfo(str(p), arcname=relativo)
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.mode = 0o755 if info.mode & 0o111 else 0o644
                with p.open("rb") as f:
                    tar.addfile(info, f)
    return buf.getvalue()


# --- docker compose --------------------------------------------------------------------------------
def compose(nginx_no_docker: bool) -> str:
    """docker-compose do Solumia. Projeto `solumia`: nomes de contêiner, rede e volume próprios."""
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
name: {names.PROJETO_COMPOSE}

services:
  gateway:
    build:
      context: ./fonte
      dockerfile: infra/docker/backend/Dockerfile
    image: {names.IMAGEM_GATEWAY}:local
    env_file: [./gateway.env]
    environment:
      GATEWAY_HOST: 0.0.0.0
      GATEWAY_PORT: {names.PORTA_GATEWAY_CONTEINER}
    ports: ["127.0.0.1:{names.PORTA_GATEWAY_HOST}:{names.PORTA_GATEWAY_CONTEINER}"]
    volumes: ["{names.VOLUME_DADOS}:/home/gateway/agent-data"]
    read_only: false
    security_opt: ["no-new-privileges:true"]
    cap_drop: [ALL]
    restart: unless-stopped

  tunel:
    build: ./fonte/infra/docker/tunel
    image: {names.IMAGEM_TUNEL}:local
    ports:
      - "{names.PORTA_TUNEL_SSH}:2222"
      - "127.0.0.1:{names.PORTA_TUNEL_ESTEIRA_HOST}:8765"
    volumes:
      - ./tunel/authorized_keys:/config/authorized_keys:ro
      - tunel-chaves:/etc/ssh/chaves
    security_opt: ["no-new-privileges:true"]
    restart: unless-stopped

  collabora:
    image: ${{COLLABORA_IMAGEM:-collabora/code:latest}}
    cap_add: [MKNOD]
    environment:
      aliasgroup1: http://gateway:{names.PORTA_GATEWAY_CONTEINER}
      extra_params: --o:ssl.enable=false --o:ssl.termination=true
      server_name: ${{COLLABORA_DOMINIO:-}}
      dictionaries: pt_BR en_US
      username: admin
      password: ${{COLLABORA_ADMIN_SENHA:-}}
    ports: ["127.0.0.1:{names.PORTA_COLLABORA_HOST}:9980"]
    restart: unless-stopped
{nginx}
volumes:
  {names.VOLUME_DADOS}:
  tunel-chaves:
  certbot-www:
  certbot-etc:
"""


def env_compose(m: Manifesto, cofre: Cofre, imagens: dict[str, str]) -> str:
    """`.env` do compose (variáveis de interpolação): imagens fixadas e senha do Collabora."""
    linhas = [f"{k}={v}" for k, v in sorted(imagens.items())]
    # Domínio já validado pelo manifesto; senha urlsafe (sem $ nem aspas) para não haver interpolação.
    linhas.append(f"COLLABORA_DOMINIO={m.topologia.dominio}")
    senha = cofre.obter_ou_gerar(secret_store.COLLABORA_SENHA, lambda: secret_store.token())
    linhas.append(f"COLLABORA_ADMIN_SENHA={senha}")
    return "\n".join(linhas) + "\n"


def env_gateway(m: Manifesto, cofre: Cofre) -> str:
    dominio = m.topologia.dominio
    v = {
        "GATEWAY_APP_NAME": names.NOME_EXIBICAO,
        "GATEWAY_ENVIRONMENT": "production",
        "GATEWAY_DEBUG": "false",
        "GATEWAY_LOG_FORMAT": "json",
        "GATEWAY_LOG_LEVEL": "info",
        "GATEWAY_CORS_ORIGINS": f"https://{dominio}",
        "GATEWAY_CLIENT_API_KEYS": cofre.obter_ou_gerar(
            secret_store.CHAVE_CLIENTE, lambda: secret_store.token("sk_live_")
        ),
        "GATEWAY_WORKER_API_KEYS": cofre.obter_ou_gerar(
            secret_store.CHAVE_WORKER, lambda: secret_store.token("worker_")
        ),
        "GATEWAY_ADMIN_USUARIO": m.conta.usuario,
        "GATEWAY_ADMIN_SENHA_HASH": cofre.exigir(secret_store.SENHA_HASH),
        "GATEWAY_ADMIN_TOTP_SEGREDO": cofre.exigir(secret_store.TOTP),
        "GATEWAY_JWT_SECRET_KEY": cofre.obter_ou_gerar(secret_store.JWT, lambda: secret_store.token(tamanho=48)),
        "GATEWAY_COLLABORA_URL": f"https://{dominio}",
        "GATEWAY_COLLABORA_INTERNO_URL": "http://collabora:9980",
        "GATEWAY_WOPI_BASE_URL": f"http://gateway:{names.PORTA_GATEWAY_CONTEINER}",
        "GATEWAY_WOPI_SECRET": cofre.obter_ou_gerar(secret_store.WOPI, lambda: secret_store.token(tamanho=48)),
    }
    linhas = ["# Gerado pelo configurador do Solumia. Contém segredos: modo 0600, não copiar."]
    for chave, valor in v.items():
        if "\n" in valor or "'" in valor:
            raise ValueError(f"valor inválido para {chave}")
        linhas.append(f"{chave}='{valor}'")
    return "\n".join(linhas) + "\n"


def nginx_desafio(dominio: str) -> str:
    """Antes do certificado: só a porta 80 com o desafio do Let's Encrypt."""
    return (f"server {{\n    listen 80;\n    server_name {dominio};\n"
            "    location /.well-known/acme-challenge/ { root /var/www/certbot; }\n"
            "    location / { return 503; }\n}\n")


def nginx_site_docker(dominio: str, raiz: Path | None = None) -> str:
    raiz = raiz or raiz_repositorio()
    texto = (raiz / "infra/docker/nginx/nginx.conf.example").read_text()
    return _substituir_nomes(texto.replace("seu-dominio.exemplo.com", dominio))


def nginx_site_host(dominio: str, raiz: Path | None = None) -> str:
    raiz = raiz or raiz_repositorio()
    texto = (raiz / "infra/docker/nginx/host-nginx-site.conf.example").read_text()
    texto = (texto.replace("seu-dominio.exemplo.com", dominio)
                  .replace("127.0.0.1:48080", f"127.0.0.1:{names.PORTA_GATEWAY_HOST}")
                  .replace("127.0.0.1:18765", f"127.0.0.1:{names.PORTA_TUNEL_ESTEIRA_HOST}")
                  .replace("127.0.0.1:9980", f"127.0.0.1:{names.PORTA_COLLABORA_HOST}"))
    return _substituir_nomes(texto)


def nginx_seguranca(raiz: Path | None = None) -> str:
    raiz = raiz or raiz_repositorio()
    return _substituir_nomes((raiz / "infra/docker/nginx/seguranca-http.conf").read_text())


def authorized_keys_tunel(publica: str) -> str:
    # restrict: a chave só abre o encaminhamento reverso da esteira, nada mais.
    if not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/=]+( [\w.@-]+)?", publica.strip()):
        raise ValueError("chave pública do túnel inválida")
    return f'restrict,port-forwarding,permitlisten="0.0.0.0:8765" {publica.strip()}\n'


# --- serviços no host (Linux, systemd --user) ------------------------------------------------------
def unidade_worker(dir_worker: Path, python: Path) -> str:
    return f"""# Gerado pelo configurador do Solumia.
[Unit]
Description={names.NOME_EXIBICAO}: worker (conecta ao gateway)
After=network-online.target

[Service]
WorkingDirectory={dir_worker}
EnvironmentFile=%h/.config/{names.PREFIXO}/worker.env
ExecStart={python} -m worker
Restart=always
RestartSec=5
NoNewPrivileges=yes

[Install]
WantedBy=default.target
"""


def unidade_tunel(host: str, porta_ssh: int, chave: Path, known_hosts: Path) -> str:
    return f"""# Gerado pelo configurador do Solumia.
[Unit]
Description={names.NOME_EXIBICAO}: túnel reverso da esteira até a VPS
After=network-online.target

[Service]
ExecStart=/usr/bin/ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \\
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile={known_hosts} -i {chave} -p {porta_ssh} \\
  -R 0.0.0.0:8765:127.0.0.1:{names.PORTA_ESTEIRA_LOCAL} tunel@{host}
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
"""


def env_worker(m: Manifesto, cofre: Cofre) -> str:
    return (
        "# Gerado pelo configurador do Solumia. Contém a chave do worker.\n"
        f"WORKER_NAME={names.PREFIXO}-worker\n"
        f"WORKER_GATEWAY_URL=wss://{m.topologia.dominio}/ws/worker\n"
        f"WORKER_API_KEY={cofre.exigir(secret_store.CHAVE_WORKER)}\n"
        f"WORKER_LLAMA_PORTA={names.PORTA_LLAMA_LOCAL}\n"
    )
