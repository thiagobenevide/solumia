#!/usr/bin/env pwsh
# Starts/stops the Gateway containers via Docker Compose.
#
# Usage:
#   .\scripts\llm_gateway.ps1 -home -up     # Local machine: gateway only (no TLS)
#   .\scripts\llm_gateway.ps1 -home -down   # Local machine: stops the gateway
#   .\scripts\llm_gateway.ps1 -vps -up      # VPS: gateway + nginx + certbot
#   .\scripts\llm_gateway.ps1 -vps -down    # VPS: stops the three services
param(
    [switch]$vps,
    [Alias('home')][switch]$IsHome,
    [switch]$up,
    [switch]$down
)
$ErrorActionPreference = "Stop"

function Usage {
    Write-Error "Usage: llm_gateway.ps1 (-vps|-home) (-up|-down)"
    exit 1
}

if ($vps -eq $IsHome) { Usage }
if ($up -eq $down) { Usage }

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $repoRoot

$composeFile = "infra/docker/docker-compose.yml"

if (-not (Test-Path "gateway\.env")) {
    Write-Host "gateway\.env not found, copying gateway\.env.example"
    Copy-Item "gateway\.env.example" "gateway\.env"
}

if ($vps) {
    if ($up -and -not (Test-Path "docker\nginx\nginx.conf")) {
        Write-Error "docker\nginx\nginx.conf not found — copy docker\nginx\nginx.conf.example, set your domain and issue the certificate (see README, production deploy section)."
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
