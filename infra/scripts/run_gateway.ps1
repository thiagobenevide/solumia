#!/usr/bin/env pwsh
# Starts the Gateway locally (outside Docker) for development on Windows.
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
pip install --quiet -e ".\plataforma\backend[dev]"

if (-not (Test-Path "gateway\.env")) {
    Write-Host "gateway\.env not found, copying gateway\.env.example"
    Copy-Item "gateway\.env.example" "gateway\.env"
}

# Settings.env_file is relative to the cwd, so we run from gateway\.
Set-Location "$repoRoot\plataforma\backend"
python -m backend.main
