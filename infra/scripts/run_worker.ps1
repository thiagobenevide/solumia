#!/usr/bin/env pwsh
# Starts the Worker locally on your personal machine (where LM Studio/Ollama runs).
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $repoRoot

if (-not (Test-Path ".venv")) {
    Write-Host "Creating virtualenv in .venv ..."
    python -m venv .venv
}

& .\.venv\Scripts\Activate.ps1

pip install --quiet --upgrade pip
pip install --quiet -e ".\plataforma\shared"
pip install --quiet -e ".\plataforma\worker[dev]"

if (-not (Test-Path "worker\.env")) {
    Write-Host "worker\.env not found, copying worker\.env.example"
    Copy-Item "worker\.env.example" "worker\.env"
}

# WorkerSettings.env_file is relative to the cwd, so we run from worker\.
Set-Location "$repoRoot\plataforma\worker"
python -m worker.main
