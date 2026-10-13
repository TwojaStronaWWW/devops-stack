<#
.SYNOPSIS
    Generuje tymczasowy, szyfrowany podglad strony (Quick Tunnel via trycloudflare.com).
.DESCRIPTION
    Eliminuje potrzebe tworzenia subdomen testowych ('test.nazwastrony.pl') i otwierania portow w zaporze.
    Uruchamia kontener cloudflared w Dockerze i generuje unikalny link HTTPS.
.EXAMPLE
    pwsh -File scripts/preview-tunnel.ps1 -Target "http://localhost:3000"
#>

[CmdletBinding()]
param(
    [string]$Target = "http://localhost:3000"
)

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ">> [Cloudflare Quick Tunnel] Generowanie podgladu staging..." -ForegroundColor Cyan
Write-Host ">> Cel: $Target" -ForegroundColor White
Write-Host ">> Zero konfiguracji DNS, zero otwartych portow na routerze/firewallu." -ForegroundColor Green
Write-Host ">> Po zakonczeniu testow nacisnij Ctrl+C, aby natychmiast zamknac tunel." -ForegroundColor Yellow
Write-Host "======================================================================" -ForegroundColor Cyan

# Sprawdzenie czy Docker dziala w WSL lub Windows
if (Get-Command docker -ErrorAction SilentlyContinue) {
    docker run --rm -it --name ephemeral-preview-tunnel cloudflare/cloudflared:latest tunnel --no-autoupdate --url $Target
} else {
    wsl -d Ubuntu-24.04 -u root docker run --rm -it --name ephemeral-preview-tunnel cloudflare/cloudflared:latest tunnel --no-autoupdate --url $Target
}
