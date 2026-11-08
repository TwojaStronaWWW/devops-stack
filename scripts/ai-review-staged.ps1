<#
.SYNOPSIS
    Headless AI Security Review CLI (VPS AI Router) dla lokalnych zmian Git (git diff --cached).
.DESCRIPTION
    Przesyła lokalny diff do centralnej bramki AI TwojaStronaWWW w celu szybkiego audytu
    ISO 27001 / OWASP ASVS / PHP2Shell / Supply Chain przed commitem lub pushem.
#>
[CmdletBinding()]
param(
    [string]$ApiUrl = "https://ai.twojastronawww.pl/chat-router.php"
)

$ErrorActionPreference = "Stop"

$diffLines = git diff --cached 2>$null
if (-not $diffLines) {
    $diffLines = git diff HEAD 2>$null
}

if (-not $diffLines) {
    Write-Host "✅ Brak lokalnych zmian w git diff do audytu." -ForegroundColor Green
    exit 0
}

$shortDiff = ($diffLines | Select-Object -First 160) -join "`n"
if ($shortDiff.Length -gt 11000) {
    $shortDiff = $shortDiff.Substring(0, 11000)
}

$payload = @{
    site_id         = "twojastronawww"
    question        = "Przeprowadź zwięzły audyt bezpieczeństwa ISO 27001 i OWASP ASVS (LOCK_EX, Sec-Fetch-Site, PHP2Shell/phar://, XSS, Supply Chain .npmrc) dla poniższego git diff w kontekście dynamicznym. Jeśli kod jest bezpieczny, potwierdź krótko po polsku."
    dynamic_context = $shortDiff
} | ConvertTo-Json -Depth 4 -Compress

Write-Host "🛡️  Wysyłanie lokalnego diffu do audytu bezpieczeństwa ($ApiUrl)..." -ForegroundColor Cyan
try {
    $headers = @{
        "Origin"       = "https://twojastronawww.pl"
        "Content-Type" = "application/json; charset=utf-8"
    }
    $res = Invoke-RestMethod -Uri $ApiUrl -Method Post -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 25
    if ($res.answer) {
        Write-Host "======================================================================" -ForegroundColor DarkCyan
        Write-Host "🤖 Wynik Audytu ($($res.model)):" -ForegroundColor Green
        Write-Host "======================================================================" -ForegroundColor DarkCyan
        Write-Host $res.answer
        Write-Host "======================================================================" -ForegroundColor DarkCyan
    } else {
        Write-Warning "Brak pola answer w odpowiedzi AI Routera."
    }
} catch {
    Write-Warning "Nie udało się połączyć z bramką AI: $($_.Exception.Message)"
}
