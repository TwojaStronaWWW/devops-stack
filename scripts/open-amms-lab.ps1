<#
.SYNOPSIS
    1-klikowy launcher Wielostrefowego Laboratorium Szpitalnego Asseco AMMS (Zero Trust SSH Tunnel).
.DESCRIPTION
    Zestawia w tle szyfrowany tunel SSH (Ed25519) do wirtualnej serwerowni szpitalnej na VPS (89.168.62.31):
    - 127.0.0.1:3010  -> pc01.szpital.lab (10.20.40.50:3000) — Pulpit Graficzny Stacji Roboczej (XFCE Webtop)
    - 127.0.0.1:18080 -> amms.szpital.lab (10.20.20.10:8080) — Serwer Aplikacyjny AMMS (WildFly 26.0.1.Final)
    - 127.0.0.1:19990 -> amms.szpital.lab (10.20.20.10:9990) — Konsola Administracyjna WildFly
    - 127.0.0.1:18081 -> int.szpital.lab  (10.20.30.10:8080) — Platforma Integracyjna Asseco (Apache Tomcat)
    - 127.0.0.1:11521 -> db.szpital.lab   (10.20.10.10:1521) — Baza Danych Oracle 19c/23ai (SID/Service: MOJA)
#>

[CmdletBinding()]
param(
    [string]$HostIp = "89.168.62.31",
    [string]$User = "ubuntu",
    [string]$KeyPath = "$HOME\.ssh\id_ed25519"
)

$ErrorActionPreference = "Stop"

function Test-PortOpen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port
    )
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

try {
    $BundledKey = Join-Path $PSScriptRoot "klucz\id_ed25519"
    $DesktopFallbackKey = "$HOME\Desktop\AMMS-Asystent-Drugi-Komputer\klucz\id_ed25519"

    if (-not (Test-Path -Path $KeyPath)) {
        if (Test-Path -Path $BundledKey) {
            $KeyPath = $BundledKey
        } elseif (Test-Path -Path $DesktopFallbackKey) {
            Copy-Item -Path $DesktopFallbackKey -Destination $KeyPath -Force -ErrorAction Stop
        }
    }

    if (Test-Path -Path $KeyPath) {
        try {
            & icacls "$KeyPath" /inheritance:r | Out-Null
            & icacls "$KeyPath" /grant:r "$($env:USERNAME):(R)" | Out-Null
        } catch {
            # Ignoruj błędy icacls jeśli uprawnienia są już poprawne
        }
    } else {
        throw "Brak klucza prywatnego SSH Ed25519 w lokalizacji: $KeyPath"
    }

    if (-not (Test-PortOpen -Address "127.0.0.1" -Port 3010)) {
        Write-Host ">> [AMMS Hospital Lab] Zestawianie tunelu SSH do serwerowni szpitalnej ($User@$HostIp)..." -ForegroundColor Cyan
        $sshArgs = "-N -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new -L 3010:127.0.0.1:3010 -L 18080:127.0.0.1:18080 -L 19990:127.0.0.1:19990 -L 18081:127.0.0.1:18081 -L 11521:127.0.0.1:11521 -i `"$KeyPath`" $User@$HostIp"
        Start-Process -FilePath "ssh" -ArgumentList $sshArgs -WindowStyle Hidden -ErrorAction Stop

        $attempts = 0
        while (-not (Test-PortOpen -Address "127.0.0.1" -Port 3010) -and $attempts -lt 25) {
            Start-Sleep -Milliseconds 250
            $attempts++
        }
    }

    Write-Host ">> [OK] Tunel aktywny:" -ForegroundColor Green
    Write-Host "   - Stacja Robocza (pc01.szpital.lab / 10.20.40.50): http://localhost:3010" -ForegroundColor Yellow
    Write-Host "   - Serwer AMMS HIS (amms.szpital.lab / 10.20.20.10): http://localhost:18080/amms" -ForegroundColor Gray
    Write-Host "   - Platforma Integracyjna (int.szpital.lab / 10.20.30.10): http://localhost:18081" -ForegroundColor Gray
    Write-Host "   - Baza Oracle (db.szpital.lab / 10.20.10.10): 127.0.0.1:11521/moja" -ForegroundColor Gray

    Start-Process -FilePath "http://localhost:3010"
} catch {
    Write-Error "Błąd uruchamiania tunelu AMMS Lab: $($_.Exception.Message)"
    exit 1
}
