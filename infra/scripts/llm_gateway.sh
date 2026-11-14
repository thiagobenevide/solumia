#!/usr/bin/env bash
# Starts/stops the Gateway containers via Docker Compose.
#
# Usage:
#   ./scripts/llm_gateway.sh -vps -up      # VPS: gateway + nginx + certbot
#   ./scripts/llm_gateway.sh -vps -down    # VPS: stops the three services
#   ./scripts/llm_gateway.sh -home -up     # Local machine: gateway only (no TLS)
#   ./scripts/llm_gateway.sh -home -down   # Local machine: stops the gateway
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

compose_file="infra/docker/docker-compose.yml"
target=""
action=""

usage() {
    echo "Usage: $0 (-vps|-home) (-up|-down)" >&2
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
    echo "plataforma/backend/.env not found, copying plataforma/backend/.env.example"
    cp plataforma/backend/.env.example plataforma/backend/.env
fi

if [ "$target" = "vps" ]; then
    if [ "$action" = "up" ] && [ ! -f "infra/docker/nginx/nginx.conf" ]; then
        echo "infra/docker/nginx/nginx.conf not found — copy infra/docker/nginx/nginx.conf.example," >&2
        echo "set your domain and issue the certificate (see README, production deploy section)." >&2
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
