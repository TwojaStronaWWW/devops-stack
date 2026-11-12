<#
.SYNOPSIS
    Automatyczny 1-klikowy launcher monitoringu TwojaStronaWWW DevOps Stack + Asystenta AMMS.
.DESCRIPTION
    Uruchamia w tle cichy tunel SSH port-forwarding (jeśli jeszcze nie działa)
    i otwiera w domyślnej przeglądarce w zadanej kolejności:
    1. Wszystkie 3 dashboardy Grafany:
       - Centrum Monitoringu & Działanie Stron WWW (uptime-kuma-overview)
       - AI Router & Kaskada Modeli (ai-router-overview)
       - Analityka Ruchu WWW & SEO (web-analytics-overview)
    2. Dozzle (logi kontenerów w czasie rzeczywistym)
    3. Uptime Kuma (panel monitorów HTTP/HTTPS)
    4. Asystent Ekspercki AMMS & Baza Oracle (Microsoft Teams UI)
    Po otwarciu wszystkich kart automatycznie przełącza aktywną zakładkę na pierwszą kartę Grafany (Działanie stron internetowych).
#>

[CmdletBinding()]
param(
    [string]$HostIp = "89.168.62.31",
    [string]$User = "ubuntu",
    [string]$KeyPath = "$HOME\.ssh\id_ed25519"
)

function Test-PortOpen([string]$Address, [int]$Port) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $connect = $tcp.BeginConnect($Address, $Port, $null, $null)
        $success = $connect.AsyncWaitHandle.WaitOne(400, $false)
        if ($success) {
            $tcp.EndConnect($connect)
            $tcp.Close()
            return $true
        }
        $tcp.Close()
        return $false
    } catch {
        return $false
    }
}

Write-Host ">> [DevOps Launcher] Weryfikacja stanu bezpiecznego tunelu SSH..." -ForegroundColor Cyan

# Obsługa klucza przenośnego (gdy paczka jest uruchomiona na drugim komputerze)
$BundledKey = Join-Path $PSScriptRoot "klucz\id_ed25519"
if ((Test-Path $BundledKey) -and -not (Test-Path $KeyPath)) {
    $KeyPath = $BundledKey
}
if (Test-Path $KeyPath) {
    try {
        & icacls "$KeyPath" /inheritance:r | Out-Null
        & icacls "$KeyPath" /grant:r "$($env:USERNAME):(R)" | Out-Null
    } catch {
        # ignoruj jeśli uprawnienia są już ustawione
    }
}

# Sprawdzenie czy porty Grafany (3000), Uptime Kuma (3001), Asystenta AMMS (8085), Ntfy (8086), PrivateBin (8087) oraz FreeScout (8088) są już otwarte lokalnie
if (-not (Test-PortOpen "127.0.0.1" 3000) -or -not (Test-PortOpen "127.0.0.1" 3001) -or -not (Test-PortOpen "127.0.0.1" 8085) -or -not (Test-PortOpen "127.0.0.1" 8086) -or -not (Test-PortOpen "127.0.0.1" 8087) -or -not (Test-PortOpen "127.0.0.1" 8088)) {
    Write-Host ">> Uruchamianie cichego tunelu SSH w tle do $HostIp (3000, 3001, 8888, 9090, 8085, 8086, 8087, 8088)..." -ForegroundColor Yellow
    $sshArgs = "-N -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new -L 3000:127.0.0.1:3000 -L 3001:127.0.0.1:3001 -L 8888:127.0.0.1:8888 -L 9090:127.0.0.1:9090 -L 8085:127.0.0.1:8085 -L 8086:127.0.0.1:8086 -L 8087:127.0.0.1:8087 -L 8088:127.0.0.1:8088 -i `"$KeyPath`" $User@$HostIp"
    Start-Process -FilePath "ssh" -ArgumentList $sshArgs -WindowStyle Hidden
    
    # Odczekaj na zainicjowanie połączenia (max 4 sekundy)
    $attempts = 0
    while ((-not (Test-PortOpen "127.0.0.1" 3000) -or -not (Test-PortOpen "127.0.0.1" 8085) -or -not (Test-PortOpen "127.0.0.1" 8088)) -and $attempts -lt 20) {
        Start-Sleep -Milliseconds 200
        $attempts++
    }
} else {
    Write-Host ">> Tunel SSH (w tym porty 8085 AMMS, 8086 Ntfy Push, 8087 PrivateBin Sejf, 8088 FreeScout Poczta) jest już aktywny w tle." -ForegroundColor Green
}

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host " AKTYWNE PORTY TUNELU SSH ZERO TRUST (127.0.0.1 -> VPS):" -ForegroundColor Cyan
Write-Host "----------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  [3000] Grafana Dashboards      : http://localhost:3000" -ForegroundColor White
Write-Host "  [3001] Uptime Kuma             : http://localhost:3001/dashboard" -ForegroundColor White
Write-Host "  [8888] Dozzle (Logi Live)      : http://localhost:8888" -ForegroundColor White
Write-Host "  [9090] Prometheus              : http://localhost:9090" -ForegroundColor White
Write-Host "  [8085] AI Router & AMMS Teams  : http://localhost:8085/amms" -ForegroundColor White
Write-Host "  [8086] Self-Hosted Ntfy Push   : http://127.0.0.1:8086" -ForegroundColor Green
Write-Host "  [8087] PrivateBin Sejf Haseł   : http://127.0.0.1:8087" -ForegroundColor Green
Write-Host "  [8088] FreeScout Centrum Poczty : http://localhost:8088" -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

$TabsInOrder = @(
    # 1. WSZYSTKIE DASHBOARDY GRAFANY (pierwszy: Działanie stron internetowych & VPS)
    "http://localhost:3000/d/uptime-kuma-overview?refresh=5s",
    "http://localhost:3000/d/ai-router-overview?refresh=5s",
    "http://localhost:3000/d/web-analytics-overview?refresh=10s",
    # 2. DOZZLE (Logi kontenerów na żywo)
    "http://localhost:8888",
    # 3. UPTIME KUMA (Panel monitoringu)
    "http://localhost:3001/dashboard",
    # 4. ASYSTENT EKSPERCKI AMMS & BAZA ORACLE (Microsoft Teams UI)
    "http://localhost:8085/amms",
    # 5. FREESCOUT CENTRUM POCZTY & HELPDESK
    "http://localhost:8088"
)

Write-Host ">> Otwieranie kart w kolejności: [3x Grafana] -> [Dozzle] -> [Uptime Kuma] -> [Asystent AMMS]..." -ForegroundColor Green
foreach ($url in $TabsInOrder) {
    Start-Process $url
    Start-Sleep -Milliseconds 350
}

# Automatyczne przełączenie aktywnej zakładki w przeglądarce z powrotem na 1. kartę:
# Grafana dotycząca działania stron internetowych (uptime-kuma-overview)
try {
    Start-Sleep -Milliseconds 750
    $wshell = New-Object -ComObject WScript.Shell
    $stepsBack = $TabsInOrder.Count - 1
    for ($i = 0; $i -lt $stepsBack; $i++) {
        $wshell.SendKeys("^{PGUP}")
        Start-Sleep -Milliseconds 90
    }
} catch {
    # Ignoruj w środowisku bez sesji graficznej
}

Write-Host ">> [OK] Wszystkie panele otwarte. Aktywna zakładka: Grafana (Działanie stron internetowych)." -ForegroundColor Cyan

