#!/usr/bin/env pwsh
# Sobe/derruba os containers do Gateway via Docker Compose.
#
# Uso:
#   .\scripts\llm_gateway.ps1 -home -up     # Máquina local: só o gateway (sem TLS)
#   .\scripts\llm_gateway.ps1 -home -down   # Máquina local: derruba o gateway
#   .\scripts\llm_gateway.ps1 -vps -up      # VPS: gateway + nginx + certbot
#   .\scripts\llm_gateway.ps1 -vps -down    # VPS: derruba os três serviços
param(
    [switch]$vps,
    [Alias('home')][switch]$IsHome,
    [switch]$up,
    [switch]$down
)
$ErrorActionPreference = "Stop"

function Usage {
    Write-Error "Uso: llm_gateway.ps1 (-vps|-home) (-up|-down)"
    exit 1
}

if ($vps -eq $IsHome) { Usage }
if ($up -eq $down) { Usage }

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $repoRoot

$composeFile = "infra/docker/docker-compose.yml"

if (-not (Test-Path "gateway\.env")) {
    Write-Host "gateway\.env não encontrado, copiando de gateway\.env.example"
    Copy-Item "gateway\.env.example" "gateway\.env"
}

if ($vps) {
    if ($up -and -not (Test-Path "docker\nginx\nginx.conf")) {
        Write-Error "docker\nginx\nginx.conf não encontrado — copie de docker\nginx\nginx.conf.example, configure seu domínio e emita o certificado (veja README, seção Deploy em produção)."
        exit 1
    }
    if ($up) {
        docker compose -f $composeFile up -d --build gateway nginx certbot
    } else {
        docker compose -f $composeFile down
    }
} else {
    if ($up) {
        docker compose -f $composeFile up -d --build gateway
    } else {
        docker compose -f $composeFile rm --force --stop gateway
    }
}
