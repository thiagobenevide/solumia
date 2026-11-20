# Builds the Solumia app and the configurator for Windows on this machine (same steps as the
# "windows" job in .github/workflows/release.yml), without GitHub Actions.
#
# Requirements (install once): Flutter 3.47.8 on PATH, Visual Studio Build Tools with
# "Desktop development with C++" plus "C++ ATL" (secure storage and notification plugins), Python 3.12 (py launcher) and, optionally, Inno Setup 6.
#
# Usage, from the repository root:
#   powershell -ExecutionPolicy Bypass -File infra\windows\build_local.ps1 [-Version 0.2.4] [-ApiUrl https://...]
#
# Output in dist\:
#   solumia-<v>-windows-x64.zip               app (unzip and open agent.exe)
#   solumia-configurador-<v>-windows-x64.zip  configurator (unzip and open solumia_configurador.exe)
#   *-setup.exe                               installers, only when Inno Setup is installed
# These files are not GPG-signed: the configurator's Apps screen does not accept them.

param(
    [string]$Version = "0.2.4",
    [string]$ApiUrl = "https://solumialocal.thiagobenevide.com"
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path "$PSScriptRoot\..\..").Path
$Dist = Join-Path $Root "dist"
$Work = Join-Path $env:TEMP "solumia-build"

function Require-Command($name, $hint) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "'$name' not found. $hint"
    }
}

function Invoke-Checked($exe, [string[]]$arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$exe $($arguments -join ' ') failed (exit $LASTEXITCODE)"
    }
}

function Get-BuildNumber($version) {
    # X.Y.Z -> X*10000 + Y*100 + Z, the same rule as the release workflow.
    $parts = $version.Split(".")
    return [int]$parts[0] * 10000 + [int]$parts[1] * 100 + [int]$parts[2]
}

function Find-Iscc {
    $command = Get-Command iscc -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    $default = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
    if (Test-Path $default) {
        return $default
    }
    return $null
}

function Build-App($build) {
    Write-Host "== Solumia app"
    Push-Location (Join-Path $Root "plataforma\app")
    try {
        Invoke-Checked "flutter" @("build", "windows", "--release", "--build-name", $Version,
            "--build-number", "$build", "--dart-define=API_URL=$ApiUrl", "--dart-define=BUILD=$build")
    } finally {
        Pop-Location
    }
}

function Build-ConfiguratorInterface($build) {
    Write-Host "== Configurator interface"
    Push-Location (Join-Path $Root "configurador\app")
    try {
        Invoke-Checked "flutter" @("pub", "get")
        Invoke-Checked "flutter" @("build", "windows", "--release", "--build-name", $Version,
            "--build-number", "$build")
    } finally {
        Pop-Location
    }
}

function Build-ConfiguratorCore($release) {
    # One folder next to the interface: core.dart looks for nucleo\solumia-configurador.exe.
    Write-Host "== Configurator core (PyInstaller)"
    $venv = Join-Path $Work "venv"
    if (-not (Test-Path $venv)) {
        Invoke-Checked "py" @("-3.12", "-m", "venv", $venv)
    }
    $python = Join-Path $venv "Scripts\python.exe"
    Invoke-Checked $python @("-m", "pip", "install", "-q", "--upgrade", "pip")
    Invoke-Checked $python @("-m", "pip", "install", "-q", (Join-Path $Root "configurador\core"), "pyinstaller")
    Invoke-Checked $python @("-m", "PyInstaller", "--noconfirm", "--clean", "--onedir", "--console",
        "--name", "solumia-configurador", "--distpath", (Join-Path $Work "core"),
        "--workpath", (Join-Path $Work "pyi"), "--specpath", $Work,
        "--collect-submodules", "uvicorn", "--collect-submodules", "keyring", "--copy-metadata", "keyring",
        "--collect-submodules", "solumia_configurador", (Join-Path $Root "infra\windows\configurator_core.py"))
    $nucleo = Join-Path $release "nucleo"
    if (Test-Path $nucleo) {
        Remove-Item -Recurse -Force $nucleo
    }
    Copy-Item -Recurse (Join-Path $Work "core\solumia-configurador") $nucleo
    Invoke-Checked (Join-Path $nucleo "solumia-configurador.exe") @("--help") | Out-Null
}

function New-Zip($source, $name) {
    $zip = Join-Path $Dist "$name.zip"
    if (Test-Path $zip) {
        Remove-Item -Force $zip
    }
    Compress-Archive -Path "$source\*" -DestinationPath $zip
    Write-Host "   $zip"
}

function New-Installer($iscc, $id, $appName, $exe, $source, $base) {
    $setup = Join-Path $Root "infra\windows\setup.iss"
    Invoke-Checked $iscc @("/Q", "/DAppId=$id", "/DAppName=$appName", "/DAppExe=$exe",
        "/DAppVersion=$Version", "/DSourceDir=$source", "/DOutputDir=$Dist", "/DOutputBase=$base", $setup)
    Write-Host "   $(Join-Path $Dist "$base.exe")"
}

Require-Command "flutter" "Install Flutter 3.47.8 and add flutter\bin to PATH."
Require-Command "py" "Install Python 3.12 from python.org (with the py launcher)."

$build = Get-BuildNumber $Version
New-Item -ItemType Directory -Force $Dist, $Work | Out-Null

Push-Location $Root
try {
    Invoke-Checked "flutter" @("pub", "get")
} finally {
    Pop-Location
}

$appRelease = Join-Path $Root "plataforma\app\build\windows\x64\runner\Release"
$configRelease = Join-Path $Root "configurador\app\build\windows\x64\runner\Release"

Build-App $build
Build-ConfiguratorInterface $build
Build-ConfiguratorCore $configRelease

Write-Host "== Packages"
New-Zip $appRelease "solumia-$Version-windows-x64"
New-Zip $configRelease "solumia-configurador-$Version-windows-x64"

$iscc = Find-Iscc
if ($iscc) {
    New-Installer $iscc "solumia" "Solumia" "agent.exe" $appRelease "solumia-$Version-windows-x64-setup"
    New-Installer $iscc "solumia-configurador" "Solumia Configurador" "solumia_configurador.exe" `
        $configRelease "solumia-configurador-$Version-windows-x64-setup"
} else {
    Write-Host "   Inno Setup not found: installers skipped (the zips are enough)."
}

Write-Host "Done: $Dist"
