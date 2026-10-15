<#
.SYNOPSIS
    Zdalny audyt i diagnostyka żywego serwera VPS (TwojaStronaWWW DevOps Stack).
.DESCRIPTION
    Przesyła lokalny skrypt scripts/audit-server.sh przez bezpieczny kanał SSH
    i wykonuje 5-warstwowy audyt bezpośrednio na serwerze produkcyjnym,
    wyświetlając czytelny raport w konsoli oraz zapisując go do logs/latest-audit.log.
#>

[CmdletBinding()]
param(
    [string]$HostIp = "89.168.62.31",
    [string]$User = "ubuntu",
    [string]$KeyPath = "$HOME\.ssh\id_ed25519",
    [switch]$Strict
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$AuditScriptPath = Join-Path $ScriptDir "audit-server.sh"
$LogDir = Join-Path $RootDir "logs"

if (-not (Test-Path $AuditScriptPath)) {
    Write-Error "Brak pliku skryptu audytowego: $AuditScriptPath"
    exit 1
}

if (-not (Test-Path $KeyPath)) {
    Write-Error "Brak klucza prywatnego SSH w lokalizacji: $KeyPath"
    exit 1
}

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

Write-Host ">> [DevOps Live Audit] Łączenie z serwerem $User@$HostIp i uruchamianie diagnostyki..." -ForegroundColor Cyan

# Wczytanie skryptu i wymuszenie zakończeń linii LF (Unix) przed przesłaniem do basha
$BashContent = (Get-Content -Raw -Encoding UTF8 $AuditScriptPath) -replace "`r`n", "`n"
$RemoteArgs = if ($Strict) { "bash -s -- --strict" } else { "bash -s" }

$AuditOutput = $BashContent | & ssh -o BatchMode=yes -o ConnectTimeout=12 -i "$KeyPath" "$User@$HostIp" $RemoteArgs
$ExitCode = $LASTEXITCODE

# Wyświetlenie w konsoli
$AuditOutput | ForEach-Object { Write-Host $_ }

# Zapisanie czystego raportu (bez kodów ANSI) do logs/latest-audit.log
$CleanLogPath = Join-Path $LogDir "latest-audit.log"
($AuditOutput -replace '\x1b\[[0-9;]*m', '') | Set-Content -Path $CleanLogPath -Encoding UTF8

Write-Host ">> [ZAPISANO] Pełny raport tekstowy zapisano w: $CleanLogPath" -ForegroundColor DarkGray
exit $ExitCode
