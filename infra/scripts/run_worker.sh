#!/usr/bin/env bash
# Sobe o Worker localmente na sua máquina pessoal (onde roda o llama.cpp com a GPU).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

if [ ! -d ".venv" ]; then
    echo "Criando virtualenv em .venv ..."
    python3 -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate

# .venv do workspace uv (uv sync --all-packages) não tem pip: os pacotes já vêm instalados.
if command -v pip >/dev/null; then
    pip install --quiet --upgrade pip
    pip install --quiet -e "./plataforma/shared"
    pip install --quiet -e "./plataforma/worker[dev]"
fi

if [ ! -f "plataforma/worker/.env" ]; then
    echo "plataforma/worker/.env não encontrado, copiando de plataforma/worker/.env.example"
    cp plataforma/worker/.env.example plataforma/worker/.env
fi

# WorkerSettings.env_file é relativo ao cwd, por isso rodamos a partir de plataforma/worker/.
cd "$repo_root/plataforma/worker"
exec python -m worker.main
