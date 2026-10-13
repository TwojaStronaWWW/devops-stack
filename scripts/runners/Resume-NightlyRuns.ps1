<#
.SYNOPSIS
    Zoptymalizowane automatyczne wznawianie zadan GitHub Actions (CI/CD) przerwanych w nocy.
.DESCRIPTION
    Weryfikuje aktywne galezie (main, master oraz otwarte PR-y) w repozytoriach organizacji.
    Optymalizacja:
      - Pobiera liste ostatnich przebiegow pojedynczym zapytaniem gh run list (zamiast N zapytan per galaz).
      - Weryfikuje autoryzacje gh CLI oraz lacznosc z api.github.com.
      - Obsluguje przelacznik -DryRun oraz rotacje pliku logow.
.EXAMPLE
    pwsh -File scripts/runners/Resume-NightlyRuns.ps1
    pwsh -File scripts/runners/Resume-NightlyRuns.ps1 -DryRun
#>

param(
    [string[]]$Repos = @("zeslownikiem/gal-anonym", "zeslownikiem/gal-anonim-web"),
    [int]$StartupDelaySeconds = 0,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$logDir = if ($IsWindows -or $env:OS -like "*Windows*") { $env:TEMP } else { "/tmp" }
$logFile = Join-Path $logDir "devops-ci-resume.log"

function Write-Log([string]$msg, [string]$color = "White") {
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $formatted = "[$timestamp] $msg"
    Write-Host $formatted -ForegroundColor $color
    try {
        Add-Content -Path $logFile -Value $formatted -Encoding utf8 -ErrorAction SilentlyContinue
    } catch { }
}

Write-Log "=================================================================" "Cyan"
Write-Log ">> [CI Auto-Resume] Uruchomienie zoptymalizowanego wznawiania zadan..." "Cyan"
Write-Log "=================================================================" "Cyan"

try {
    # 1. Weryfikacja obecnosci GitHub CLI
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Log "BLAD: Narzedzie 'gh' (GitHub CLI) nie jest zainstalowane lub brak w PATH." "Red"
        return
    }

    # 2. Opcjonalne opoznienie startowe (np. przy autostarcie systemu)
    if ($StartupDelaySeconds -gt 0) {
        Write-Log "Oczekiwanie $StartupDelaySeconds s na stabilizacje sieci..." "Gray"
        Start-Sleep -Seconds $StartupDelaySeconds
    }

    # 3. Sprawdzenie lacznosci z api.github.com
    $connected = $false
    for ($i = 1; $i -le 5; $i++) {
        try {
            $dns = [System.Net.Dns]::GetHostAddresses("api.github.com")
            if ($dns -and $dns.Length -gt 0) { $connected = $true; break }
        } catch { }
        Write-Log "Proba $i/5: Oczekiwanie na DNS api.github.com..." "DarkGray"
        Start-Sleep -Seconds 2
    }

    if (-not $connected) {
        Write-Log "Brak polaczenia z internetem. Przerywanie." "Yellow"
        return
    }

    $totalReruns = 0

    foreach ($repo in $Repos) {
        Write-Log ">> Sprawdzanie repozytorium: $repo" "Cyan"

        # 4. Pobranie aktywnych galezi z otwartych PR-ow
        $openPrsJson = gh pr list --repo $repo --state open --json headRefName 2>$null
        $targetBranches = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $targetBranches.Add("main") | Out-Null
        $targetBranches.Add("master") | Out-Null

        if ($openPrsJson) {
            $prs = $openPrsJson | ConvertFrom-Json
            foreach ($pr in $prs) {
                if ($pr.headRefName) {
                    $targetBranches.Add($pr.headRefName) | Out-Null
                }
            }
        }

        # 5. Zoptymalizowane JEDNORAZOWE pobranie ostatnich przebiegow dla repozytorium
        $runsJson = gh run list --repo $repo --limit 50 --json databaseId,headBranch,status,conclusion,name,createdAt 2>$null
        if (-not $runsJson) {
            Write-Log "  Brak historii przebiegow w repozytorium $repo." "Gray"
            continue
        }

        $allRuns = $runsJson | ConvertFrom-Json

        # 6. Analiza najnowszego przebiegu per aktywna galaz
        foreach ($branch in $targetBranches) {
            $latestRun = $allRuns |
                Where-Object { $_.headBranch -eq $branch -and $_.name -in @("CI/CD Pipeline", "CI", "build", "test") } |
                Select-Object -First 1

            if (-not $latestRun) { continue }

            $id = $latestRun.databaseId
            $status = $latestRun.status
            $conclusion = $latestRun.conclusion
            $pName = $latestRun.name

            Write-Log "  - [$branch] Ostatni run #$id ('$pName'): status='$status', wynik='$conclusion'" "White"

            # Wznawianie jesli run padl/zostal anulowany
            if ($status -eq "completed" -and $conclusion -in @("failure", "cancelled", "timed_out", "startup_failure")) {
                Write-Log "    >> Wykryto nieudany przebieg dla '$branch' (#$id)!" "Yellow"
                if ($DryRun) {
                    Write-Log "    [DryRun] Wywolano by: gh run rerun $id --failed --repo $repo" "Magenta"
                    $totalReruns++
                } else {
                    Write-Log "    >> Wznawianie nieudanych krokow dla zadania #$id..." "Green"
                    try {
                        gh run rerun $id --failed --repo $repo 2>&1 | Out-String | ForEach-Object { if ($_) { Write-Log "       $_" "Gray" } }
                        $totalReruns++
                    } catch {
                        Write-Log "       BLAD: $_" "Red"
                    }
                }
            }
        }
    }

    Write-Log "=================================================================" "Cyan"
    if ($DryRun) {
        Write-Log ">> [DryRun] Liczba zadan do wznowienia: $totalReruns" "Magenta"
    } elseif ($totalReruns -gt 0) {
        Write-Log ">> [Sukces] Wznowiono $totalReruns nieudanych zadan CI/CD." "Green"
    } else {
        Write-Log ">> [OK] Wszystkie aktywne galezie maja zielone pipeline'y." "Green"
    }
    Write-Log "=================================================================" "Cyan"
} catch {
    Write-Log "BLAD KRYTYCZNY: $_" "Red"
}
