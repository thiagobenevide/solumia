#!/usr/bin/env bash
# Sobe o Gateway localmente (fora do Docker) para desenvolvimento.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

if [ ! -d ".venv" ]; then
    echo "Criando virtualenv em .venv ..."
    python3 -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate

pip install --quiet --upgrade pip
pip install --quiet -e "./plataforma/shared"
pip install --quiet -e "./plataforma/backend[dev]"

if [ ! -f "plataforma/backend/.env" ]; then
    echo "plataforma/backend/.env não encontrado, copiando de plataforma/backend/.env.example"
    cp plataforma/backend/.env.example plataforma/backend/.env
fi

# Settings.env_file é relativo ao cwd, por isso rodamos a partir de plataforma/backend/.
cd "$repo_root/plataforma/backend"
exec python -m backend.main
