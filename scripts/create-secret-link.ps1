<#
.SYNOPSIS
    Pomocnik administratora do bezpiecznego przekazywania haseł klientom przez PrivateBin (Zero-Knowledge Vault).
.DESCRIPTION
    Sprawdza dostępność lokalnego tunelu SSH na porcie 8087 (http://127.0.0.1:8087)
    lub publicznego adresu Cloudflare Zero Trust (https://sejf.twojastronawww.pl).
    Otwiera jednorazowy Sejf Haseł ("Burn After Reading") w przeglądarce oraz wyświetla
    ściągę bezpieczeństwa ISO 27001 (przekazywanie linku i hasła dwoma niezależnymi kanałami).
#>

[CmdletBinding()]
param(
    [string]$HostIp = "89.168.62.31",
    [string]$User = "ubuntu",
    [string]$KeyPath = "$HOME\.ssh\id_ed25519",
    [int]$LocalPort = 8087,
    [string]$PublicUrl = "https://sejf.twojastronawww.pl",
    [switch]$Open,
    [switch]$NoOpen,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ShouldOpen = $true
if ($NoOpen) {
    $ShouldOpen = $false
}
if ($Open -or ($RemainingArgs -contains "--open")) {
    $ShouldOpen = $true
}
if ($RemainingArgs -contains "--no-open" -or $RemainingArgs -contains "--check") {
    $ShouldOpen = $false
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

$LocalUrl = "http://127.0.0.1:$LocalPort"
$TargetUrl = $PublicUrl

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ">> [PrivateBin Zero-Knowledge Vault] Jednorazowy Sejf Haseł (AES-256-GCM)" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

if (Test-PortOpen "127.0.0.1" $LocalPort) {
    Write-Host ">> [OK] Wykryto aktywny lokalny tunel SSH na porcie $LocalPort ($LocalUrl)." -ForegroundColor Green
    $TargetUrl = $LocalUrl
} else {
    Write-Host ">> [INFO] Lokalny tunel na porcie $LocalPort ($LocalUrl) nie jest aktywny." -ForegroundColor Yellow
    Write-Host ">>        Użycie publicznego adresu Cloudflare Zero Trust: $PublicUrl" -ForegroundColor Cyan
    $TargetUrl = $PublicUrl
}

Write-Host ""
Write-Host "----------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host " INSTRUKCJA BEZPIECZNEGO PRZEKAZYWANIA (ISO 27001 Out-of-Band):" -ForegroundColor Yellow
Write-Host "  1. Wklej hasło w Sejfie (opcja 'Zniszcz po przeczytaniu' jest domyślnie włączona)." -ForegroundColor White
Write-Host "  2. Ustaw dodatkowe zabezpieczenie w polu 'Hasło' (wymagane dla kont produkcyjnych)." -ForegroundColor White
Write-Host "  3. Kliknij 'Utwórz' - klucz AES-256-GCM znajduje się po znaku '#' i NIGDY nie trafia na serwer." -ForegroundColor White
Write-Host "  4. Wyślij LINK klientowi 1. kanałem (np. e-mail / osTicket), a HASŁO 2. kanałem (np. SMS / Signal)." -ForegroundColor Green
Write-Host "  5. Uwaga: Klientowi zawsze wysyłaj link z domeną publiczną ($PublicUrl), a nie 127.0.0.1!" -ForegroundColor Magenta
Write-Host "----------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ">> Adres lokalny (tunel SSH): $LocalUrl" -ForegroundColor Gray
Write-Host ">> Adres publiczny (Klient):  $PublicUrl" -ForegroundColor Green
Write-Host ""

if ($ShouldOpen) {
    Write-Host ">> Otwieranie Sejfu Haseł w przeglądarce: $TargetUrl" -ForegroundColor Green
    try {
        Start-Process $TargetUrl
    } catch {
        Write-Warning "Nie udało się automatycznie otworzyć przeglądarki. Otwórz ręcznie: $TargetUrl"
    }
}
