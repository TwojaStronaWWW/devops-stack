<#
.SYNOPSIS
    1-klikowy launcher Asystenta Wiedzy Asseco AMMS 6.10.07 & Architekta Bazy Oracle (Microsoft Teams UI).
.DESCRIPTION
    Uruchamia lokalny mikro-router AI z bazą SQLite FTS5 BM25 (43 848 fragmentów z 383 plików)
    lub tunel SSH do VPS i otwiera w przeglądarce aplikację czatu w stylu Microsoft Teams (/amms).
    Obsługuje również flagę -SyncToVps do wgrania bazy amms-knowledge.sqlite na serwer produkcyjny VPS.
#>

[CmdletBinding()]
param(
    [string]$HostIp = "89.168.62.31",
    [string]$User = "ubuntu",
    [string]$KeyPath = "$HOME\.ssh\id_ed25519",
    [int]$LocalPort = 8085,
    [switch]$SyncToVps
)

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SqliteFile = Join-Path $RepoRoot "services\ai-router\data\amms-knowledge.sqlite"
$ZipPackage = "$HOME\Downloads\AMMS-RAG-VPS-Package.zip"

if (-not (Test-Path $SqliteFile) -and (Test-Path $ZipPackage)) {
    Write-Host ">> Rozpakowywanie bazy amms-knowledge.sqlite z $ZipPackage..." -ForegroundColor Cyan
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPackage)
    $entry = $zip.Entries | Where-Object { $_.FullName -match "amms-knowledge\.sqlite$" } | Select-Object -First 1
    if ($entry) {
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $SqliteFile, $true)
    }
    $zip.Dispose()
}

if ($SyncToVps) {
    if (-not (Test-Path $SqliteFile)) {
        Write-Error "Brak pliku bazy wiedzy: $SqliteFile"
        exit 1
    }
    Write-Host ">> Przesyłanie bazy wiedzy AMMS SQLite FTS5 na VPS ($User@$HostIp)..." -ForegroundColor Yellow
    scp -i "$KeyPath" "$SqliteFile" "${User}@${HostIp}:/opt/devops-stack/services/ai-router/data/amms-knowledge.sqlite"
    Write-Host ">> [OK] Baza amms-knowledge.sqlite została zsynchronizowana z VPS." -ForegroundColor Green
}

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

if (-not (Test-PortOpen "127.0.0.1" $LocalPort)) {
    if (Test-Path $KeyPath) {
        Write-Host ">> [Zero Trust SSH] Uruchamianie szyfrowanego tunelu SSH do VPS ($User@$HostIp -> 127.0.0.1:$LocalPort)..." -ForegroundColor Cyan
        $sshArgs = "-N -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new -L ${LocalPort}:127.0.0.1:8085 -i `"$KeyPath`" $User@$HostIp"
        Start-Process -FilePath "ssh" -ArgumentList $sshArgs -WindowStyle Hidden

        $sshAttempts = 0
        while (-not (Test-PortOpen "127.0.0.1" $LocalPort) -and $sshAttempts -lt 20) {
            Start-Sleep -Milliseconds 200
            $sshAttempts++
        }
    }

    # Fallback lokalny (jeśli brak połączenia z VPS / praca offline)
    if (-not (Test-PortOpen "127.0.0.1" $LocalPort)) {
        $LocalEnvFile = Join-Path $RepoRoot ".env"
        if (-not (Test-Path $LocalEnvFile) -and (Test-Path $KeyPath)) {
            Write-Host ">> Pobieranie kluczy API darmowej kaskady z bezpiecznego sejfu VPS (.env w RAM)..." -ForegroundColor Cyan
            $remoteEnv = ssh -i "$KeyPath" -o ConnectTimeout=4 "${User}@${HostIp}" "grep -E '^(GEMINI|GROQ|CEREBRAS|CF_|OPENROUTER|ANTHROPIC)_' /opt/devops-stack/.env 2>/dev/null || true"
            foreach ($line in ($remoteEnv -split "`r?`n")) {
                if ($line -match "^([A-Z0-9_]+)=(.*)$") {
                    $k = $Matches[1]
                    $v = $Matches[2].Trim('"', "'", " ")
                    [System.Environment]::SetEnvironmentVariable($k, $v, "Process")
                }
            }
        }

        $RouterSrcDir = Join-Path $RepoRoot "services\ai-router\src"
        $RouterScript = Join-Path $RouterSrcDir "chat-router.php"

        Write-Host ">> Uruchamianie lokalnego silnika AI Router + SQLite FTS5 na http://127.0.0.1:$LocalPort ..." -ForegroundColor Yellow
        Start-Process -FilePath "php" -ArgumentList "-S 127.0.0.1:$LocalPort -t `"$RouterSrcDir`" `"$RouterScript`"" -WindowStyle Hidden

        $attempts = 0
        while (-not (Test-PortOpen "127.0.0.1" $LocalPort) -and $attempts -lt 15) {
            Start-Sleep -Milliseconds 200
            $attempts++
        }
    } else {
        Write-Host ">> [OK] Szyfrowany tunel SSH (Ed25519) do VPS jest aktywny." -ForegroundColor Green
    }
} else {
    Write-Host ">> Tunel / serwer na porcie 127.0.0.1:$LocalPort jest już aktywny." -ForegroundColor Green
}

$TeamsUrl = "http://localhost:$LocalPort/amms"
Write-Host ">> Otwieranie prywatnego czatu Microsoft Teams • Ekspert AMMS & Baza Oracle: $TeamsUrl" -ForegroundColor Green
Start-Process $TeamsUrl
