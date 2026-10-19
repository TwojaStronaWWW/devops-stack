<#
.SYNOPSIS
    Generator przenośnej paczki ZIP (Portable) dla Asystenta AMMS i Monitoringu na drugi komputer.
.DESCRIPTION
    Buduje samowystarczalną paczkę C:\Users\<user>\Downloads\AMMS-Asystent-Drugi-Komputer.zip,
    którą można przenieść na dowolny drugi komputer z systemem Windows 10/11 i uruchomić
    jednym kliknięciem bez instalowania PHP, Dockera ani kopiowania 170 MB bazy SQLite
    (cała baza i kaskada 11 modeli działa po szyfrowanym tunelu SSH do VPS 89.168.62.31).
#>

[CmdletBinding()]
param(
    [string]$OutputZip = "$HOME\Downloads\AMMS-Asystent-Drugi-Komputer.zip",
    [string]$SshKeyPath = "$HOME\.ssh\id_ed25519"
)

$ErrorActionPreference = "Stop"
$TempDir = Join-Path $env:TEMP ("amms-portable-build-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$KeySubDir = Join-Path $TempDir "klucz"

New-Item -ItemType Directory -Path $KeySubDir -Force | Out-Null

# 1. Kopiowanie skryptów PowerShell
Copy-Item -Path (Join-Path $PSScriptRoot "open-amms-assistant.ps1") -Destination (Join-Path $TempDir "open-amms-assistant.ps1") -Force
Copy-Item -Path (Join-Path $PSScriptRoot "open-dashboard.ps1") -Destination (Join-Path $TempDir "open-dashboard.ps1") -Force

# 2. Tworzenie 1-klikowych plików .cmd (osobny dla AMMS oraz wspólny z Monitoringiem)
$CmdStandalone = "@echo off`r`nchcp 65001 >nul`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0open-amms-assistant.ps1`"`r`n"
Set-Content -Path (Join-Path $TempDir "1-Uruchom-Tylko-Asystenta-AMMS.cmd") -Value $CmdStandalone -Encoding ASCII

$CmdCombined = "@echo off`r`nchcp 65001 >nul`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0open-dashboard.ps1`"`r`n"
Set-Content -Path (Join-Path $TempDir "2-Uruchom-Monitoring-i-AMMS-Wspolnie.cmd") -Value $CmdCombined -Encoding ASCII

# 3. Dołączenie klucza SSH (wyłącznie do zewnętrznego archiwum w Downloads)
if (Test-Path $SshKeyPath) {
    Copy-Item -Path $SshKeyPath -Destination (Join-Path $KeySubDir "id_ed25519") -Force
}

# 4. Instrukcja obsługi na drugim komputerze
$ReadmeText = @"
================================================================================
 ASYSTENT EKSPERCKI ASSECO AMMS & BAZA ORACLE (PORTABLE - DRUGI KOMPUTER)
================================================================================

JAK URUCHOMIĆ NA DRUGIM KOMPUTERZE (WINDOWS 10 / 11):
1. Rozpakuj całe archiwum ZIP do dowolnego folderu (np. na Pulpit).
2. Masz do wyboru dwa 1-klikowe programy startowe:

   A) [1-Uruchom-Tylko-Asystenta-AMMS.cmd] (METODA OSOBNA)
      - Zestawia w tle szyfrowany tunel SSH (Ed25519) do serwera VPS (89.168.62.31)
      - Automatycznie naprawia uprawnienia Windows (icacls) do klucza SSH po rozpakowaniu ZIP
      - Otwiera w przeglądarce prywatny czat Microsoft Teams:
        http://localhost:8085/amms

   B) [2-Uruchom-Monitoring-i-AMMS-Wspolnie.cmd] (METODA WSPÓLNA Z MONITORINGIEM)
      - Otwiera karty w dokładnej kolejności:
        1. Wszystkie 3 dashboardy Grafany (Działanie Stron WWW -> AI Router -> Analityka WWW)
        2. Dozzle (Logi kontenerów na żywo)
        3. Uptime Kuma (Monitoring stron)
        4. Asystent Ekspercki AMMS & Baza Oracle (Microsoft Teams UI)
      - Automatycznie ustawia aktywną (otwartą) zakładkę na pierwszą Grafanę
        dotyczącą działania stron internetowych (uptime-kuma-overview).

BEZPIECZEŃSTWO (ZERO TRUST):
- Czat AMMS i baza wiedzy Oracle są całkowicie zablokowane z publicznego internetu (HTTP 403).
- Połączenie odbywa się wyłącznie przez szyfrowany tunel SSH na adres 127.0.0.1:8085.
- Na drugim komputerze nie trzeba instalować PHP, Dockera ani kopiować 170 MB bazy SQLite.
================================================================================
"@
Set-Content -Path (Join-Path $TempDir "INSTRUKCJA.txt") -Value $ReadmeText -Encoding UTF8

# 5. Pakowanie do ZIP
if (Test-Path $OutputZip) {
    Remove-Item -Path $OutputZip -Force
}
Compress-Archive -Path "$TempDir\*" -DestinationPath $OutputZip -Force
Remove-Item -Path $TempDir -Recurse -Force

Write-Host ">> [OK] Gotowa paczka na drugi komputer została utworzona:" -ForegroundColor Green
Write-Host "   $OutputZip" -ForegroundColor Cyan
