<#
.SYNOPSIS
    Orkiestrator lokalnych self-hosted runnerow GitHub Actions (Desktop + Web).
.DESCRIPTION
    Weryfikuje stan procesow Runner.Listener dla obu katalogow (actions-runner i actions-runner-web).
    Uruchamia brakujace instancje w tle oraz wywoluje skrypt wznawiania nocnych zadan.
.EXAMPLE
    pwsh -File scripts/runners/Start-Runners.ps1
#>

[CmdletBinding()]
param(
    [string]$DesktopRunnerPath = "E:\actions-runner",
    [string]$WebRunnerPath = "E:\actions-runner-web",
    [switch]$SkipNightlyResume
)

$ErrorActionPreference = "Continue"

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " [GitHub Runners] Weryfikacja i uruchamianie instancji..." -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan

function Start-RunnerInstance([string]$name, [string]$path) {
    if (-not (Test-Path $path)) {
        Write-Warning "Katalog runnera '$name' nie istnieje pod sciezka: $path"
        return
    }

    $existing = Get-Process -Name "Runner.Listener" -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -like "$path\*"
    }

    if ($existing) {
        Write-Host "-> Runner '$name' juz dziala (PID: $($existing.Id | Out-String).Trim())." -ForegroundColor Green
    } else {
        Write-Host "-> Uruchamianie runnera '$name' ($path)..." -ForegroundColor Yellow
        $runCmd = Join-Path $path "run.cmd"
        if (Test-Path $runCmd) {
            Start-Process cmd.exe -ArgumentList "/c run.cmd" -WorkingDirectory $path -WindowStyle Minimized
            Write-Host "   Pomyslnie wystartowano proces w tle." -ForegroundColor Green
        } else {
            Write-Error "Brak pliku run.cmd w katalogu $path!"
        }
    }
}

# 1. Start runnera desktopowego
Start-RunnerInstance -name "Desktop (gal-anonym)" -path $DesktopRunnerPath

# 2. Start runnera webowego
Start-RunnerInstance -name "Web (gal-anonim-web)" -path $WebRunnerPath

# 3. Wznowienie zadan przerwanych podczas offline runnerow
if (-not $SkipNightlyResume) {
    $resumeScript = Join-Path $PSScriptRoot "Resume-NightlyRuns.ps1"
    if (Test-Path $resumeScript) {
        Write-Host "`n-> Uruchamianie procedury auto-resume dla zadan..." -ForegroundColor Cyan
        Start-Process pwsh -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File `"$resumeScript`"" -WindowStyle Minimized
    }
}

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " [GitHub Runners] Gotowe. Runnery pracuja w tle." -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
