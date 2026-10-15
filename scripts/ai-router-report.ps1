<#
.SYNOPSIS
    Pełny raport kontrolny AI Routera (kaskada modeli, limity, zawieszenia, logi, zasoby).
.DESCRIPTION
    Przesyła scripts/ai-router-report.sh na VPS przez SSH (bash -s) i wypisuje raport.
    Tylko odczyt - nic nie jest instalowane ani zmieniane na serwerze.
.EXAMPLE
    .\scripts\ai-router-report.ps1
    .\scripts\ai-router-report.ps1 -Since 6h
#>

[CmdletBinding()]
param(
    [string]$HostIp = "89.168.62.31",
    [string]$User = "ubuntu",
    [string]$KeyPath = "$HOME\.ssh\id_ed25519",
    [ValidatePattern('^[0-9]+[smhd]$')]
    [string]$Since = "24h"
)

$scriptPath = Join-Path $PSScriptRoot "ai-router-report.sh"
if (-not (Test-Path $scriptPath)) {
    Write-Error "Brak pliku $scriptPath"
    exit 1
}

# Normalizacja końców linii (CRLF -> LF), aby bash na serwerze nie zgłaszał błędów '\r'
$body = (Get-Content $scriptPath -Raw) -replace "`r`n", "`n"
$body | ssh -o BatchMode=yes -i $KeyPath "$User@$HostIp" "bash -s -- $Since"
exit $LASTEXITCODE
