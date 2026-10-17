<#
.SYNOPSIS
    Automatyczny 1-klikowy launcher monitoringu TwojaStronaWWW DevOps Stack.
.DESCRIPTION
    Uruchamia w tle cichy tunel SSH port-forwarding (jeśli jeszcze nie działa)
    i natychmiast otwiera w domyślnej przeglądarce 3 karty:
    - Grafana (auto-login Admin)
    - Dozzle (logi kontenerów w czasie rzeczywistym)
    - Uptime Kuma (monitoring dostępności stron WWW)
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

Write-Host ">> [DevOps Launcher] Weryfikacja stanu bezpiecznego tunelu..." -ForegroundColor Cyan

# Sprawdzenie czy porty Grafany (3000) i Uptime Kuma (3001) są już otwarte lokalnie
if (-not (Test-PortOpen "127.0.0.1" 3000) -or -not (Test-PortOpen "127.0.0.1" 3001)) {
    Write-Host ">> Uruchamianie cichego tunelu SSH w tle do $HostIp..." -ForegroundColor Yellow
    $sshArgs = "-N -o ExitOnForwardFailure=yes -L 3000:127.0.0.1:3000 -L 3001:127.0.0.1:3001 -L 8888:127.0.0.1:8888 -L 9090:127.0.0.1:9090 -i `"$KeyPath`" $User@$HostIp"
    Start-Process -FilePath "ssh" -ArgumentList $sshArgs -WindowStyle Hidden
    
    # Odczekaj na zainicjowanie połączenia (max 3 sekundy)
    $attempts = 0
    while (-not (Test-PortOpen "127.0.0.1" 3000) -and $attempts -lt 15) {
        Start-Sleep -Milliseconds 200
        $attempts++
    }
} else {
    Write-Host ">> Tunel SSH jest już aktywny w tle." -ForegroundColor Green
}

Write-Host ">> Otwieranie paneli monitoringu w przeglądarce..." -ForegroundColor Green
Start-Process "http://localhost:3000/d/uptime-kuma-overview?refresh=5s"
Start-Process "http://localhost:8888"
Start-Process "http://localhost:3001/dashboard"

Write-Host ">> [OK] Panele zostały otwarte pomyślnie." -ForegroundColor Cyan
