#!/usr/bin/env bash
# Starts the Worker locally on your personal machine (where llama.cpp runs on the GPU).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

if [ ! -d ".venv" ]; then
    echo "Creating virtualenv in .venv ..."
    python3 -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate

# The uv workspace .venv (uv sync --all-packages) has no pip: the packages are already installed.
if command -v pip >/dev/null; then
    pip install --quiet --upgrade pip
    pip install --quiet -e "./plataforma/shared"
    pip install --quiet -e "./plataforma/worker[dev]"
fi

if [ ! -f "plataforma/worker/.env" ]; then
    echo "plataforma/worker/.env not found, copying plataforma/worker/.env.example"
    cp plataforma/worker/.env.example plataforma/worker/.env
fi

# WorkerSettings.env_file is relative to the cwd, so we run from plataforma/worker/.
cd "$repo_root/plataforma/worker"
exec python -m worker.main
