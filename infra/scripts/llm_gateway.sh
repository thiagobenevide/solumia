#!/usr/bin/env bash
# Sobe/derruba os containers do Gateway via Docker Compose.
#
# Uso:
#   ./scripts/llm_gateway.sh -vps -up      # VPS: gateway + nginx + certbot
#   ./scripts/llm_gateway.sh -vps -down    # VPS: derruba os três serviços
#   ./scripts/llm_gateway.sh -home -up     # Máquina local: só o gateway (sem TLS)
#   ./scripts/llm_gateway.sh -home -down   # Máquina local: derruba o gateway
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

compose_file="infra/docker/docker-compose.yml"
target=""
action=""

usage() {
    echo "Uso: $0 (-vps|-home) (-up|-down)" >&2
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        -vps) target="vps" ;;
        -home) target="home" ;;
        -up) action="up" ;;
        -down) action="down" ;;
        *) usage ;;
    esac
done

[ -n "$target" ] && [ -n "$action" ] || usage

if [ ! -f "plataforma/backend/.env" ]; then
    echo "plataforma/backend/.env não encontrado, copiando de plataforma/backend/.env.example"
    cp plataforma/backend/.env.example plataforma/backend/.env
fi

if [ "$target" = "vps" ]; then
    if [ "$action" = "up" ] && [ ! -f "infra/docker/nginx/nginx.conf" ]; then
        echo "infra/docker/nginx/nginx.conf não encontrado — copie de infra/docker/nginx/nginx.conf.example," >&2
        echo "configure seu domínio e emita o certificado (veja README, seção Deploy em produção)." >&2
        exit 1
    fi
    if [ "$action" = "up" ]; then
        docker compose -f "$compose_file" up -d --build gateway nginx certbot
    else
        docker compose -f "$compose_file" down
    fi
else
    if [ "$action" = "up" ]; then
        docker compose -f "$compose_file" up -d --build gateway
    else
        docker compose -f "$compose_file" rm --force --stop gateway
    fi
fi
