<#
.SYNOPSIS
    Uruchamia lokalny stos monitoringu w WSL2 z zabezpieczeniem przed uśpieniem maszyny.
.DESCRIPTION
    1. Uruchamia w tle proces podtrzymujący WSL2 (zapobiega automatycznemu zamykaniu maszyny przez Windows).
    2. Uruchamia stos Docker Compose w Ubuntu-24.04.
    3. Weryfikuje stan kontenerów i otwiera dashboardy w domyślnej przeglądarce.
#>

[CmdletBinding()]
param(
    [switch]$NoBrowser
)

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ">> [DevOps Stack] Uruchamianie środowiska lokalnego w WSL2..." -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# 1. Zabezpieczenie przed uśpieniem WSL2 (Keepalive)
$keepaliveRunning = Get-Process -Name "wsl" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*sleep infinity*"
}

if (-not $keepaliveRunning) {
    Write-Host "-> Uruchamianie procesu podtrzymującego WSL2 (Keepalive)..." -ForegroundColor Yellow
    Start-Process wsl.exe -ArgumentList "-d", "Ubuntu-24.04", "-u", "root", "--", "sleep", "infinity" -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

# 2. Uruchomienie Docker Compose
Write-Host "-> Startowanie kontenerów Docker Compose (Grafana, Prometheus, Uptime Kuma)..." -ForegroundColor Cyan
wsl.exe -d Ubuntu-24.04 -u root bash -c "cd /mnt/e/Projekty/VPS/compose && docker compose up -d"

# 3. Oczekiwanie na inicjalizację
Write-Host "-> Weryfikacja dostępności usług..." -ForegroundColor Gray
Start-Sleep -Seconds 3

# 4. Sprawdzenie stanu
wsl.exe -d Ubuntu-24.04 -u root bash -c "cd /mnt/e/Projekty/VPS/compose && docker compose ps"

Write-Host "`n======================================================================" -ForegroundColor Green
Write-Host ">> [SUKCES] Stos monitoringu jest aktywny i dostępny:" -ForegroundColor Green
Write-Host "   Grafana:     http://127.0.0.1:3000  (admin / GF_Admin_9aF8#xK2$vP8!mQ4^zL7*tW1@b)" -ForegroundColor White
Write-Host "   Uptime Kuma: http://127.0.0.1:3001" -ForegroundColor White
Write-Host "   Prometheus:  http://127.0.0.1:9090" -ForegroundColor White
Write-Host "======================================================================" -ForegroundColor Green

if (-not $NoBrowser) {
    Start-Process "http://127.0.0.1:3000"
    Start-Process "http://127.0.0.1:3001"
}
