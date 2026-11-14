#!/usr/bin/env pwsh
# Sobe o Gateway localmente (fora do Docker) para desenvolvimento no Windows.
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $repoRoot

if (-not (Test-Path ".venv")) {
    Write-Host "Criando virtualenv em .venv ..."
    python -m venv .venv
}

& .\.venv\Scripts\Activate.ps1

pip install --quiet --upgrade pip
pip install --quiet -e ".\plataforma\shared"
pip install --quiet -e ".\plataforma\backend[dev]"

if (-not (Test-Path "gateway\.env")) {
    Write-Host "gateway\.env não encontrado, copiando de gateway\.env.example"
    Copy-Item "gateway\.env.example" "gateway\.env"
}

# Settings.env_file é relativo ao cwd, por isso rodamos a partir de gateway\.
Set-Location "$repoRoot\plataforma\backend"
python -m backend.main
