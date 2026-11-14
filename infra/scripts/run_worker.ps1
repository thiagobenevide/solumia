#!/usr/bin/env pwsh
# Sobe o Worker localmente na sua máquina pessoal (onde o LM Studio/Ollama roda).
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
pip install --quiet -e ".\plataforma\worker[dev]"

if (-not (Test-Path "worker\.env")) {
    Write-Host "worker\.env não encontrado, copiando de worker\.env.example"
    Copy-Item "worker\.env.example" "worker\.env"
}

# WorkerSettings.env_file é relativo ao cwd, por isso rodamos a partir de worker\.
Set-Location "$repoRoot\plataforma\worker"
python -m worker.main
