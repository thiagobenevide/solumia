#!/usr/bin/env bash
# Starts the Gateway locally (outside Docker) for development.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

if [ ! -d ".venv" ]; then
    echo "Creating virtualenv in .venv ..."
    python3 -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate

pip install --quiet --upgrade pip
pip install --quiet -e "./plataforma/shared"
pip install --quiet -e "./plataforma/backend[dev]"

if [ ! -f "plataforma/backend/.env" ]; then
    echo "plataforma/backend/.env not found, copying plataforma/backend/.env.example"
    cp plataforma/backend/.env.example plataforma/backend/.env
fi

# Settings.env_file is relative to the cwd, so we run from plataforma/backend/.
cd "$repo_root/plataforma/backend"
exec python -m backend.main
