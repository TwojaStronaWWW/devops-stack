<#
.SYNOPSIS
    Generator Audytow Sprzedazowych i Bezpieczenstwa "Przed i Po" (HTML A4 + JSON + PDF) dla klientow TwojaStronaWWW.
.DESCRIPTION
    Uruchamia scripts/generate-client-audit.js dla podanego adresu URL klienta,
    a nastepnie - jesli na stacji roboczej dostepny jest Microsoft Edge lub Google Chrome -
    automatycznie konwertuje raport HTML A4 do gotowego pliku PDF (--headless --print-to-pdf).
.EXAMPLE
    .\scripts\generate-client-audit.ps1 -Url "https://twojastronawww.pl" -ClientName "TwojaStronaWWW" -Open
    .\scripts\generate-client-audit.ps1 -SelfTest
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$Url = "",

    [Parameter(Mandatory = $false)]
    [string]$ClientName = "",

    [Parameter(Mandatory = $false)]
    [string]$OutDir = "",

    [Parameter(Mandatory = $false)]
    [switch]$Open,

    [Parameter(Mandatory = $false)]
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

$scriptJs = Join-Path $PSScriptRoot "generate-client-audit.js"

if (-not (Test-Path $scriptJs)) {
    Write-Error "Brak pliku generatora: $scriptJs"
    exit 1
}

if ($SelfTest) {
    & node $scriptJs --self-test
    exit $LASTEXITCODE
}

if ([string]::IsNullOrWhiteSpace($Url)) {
    Write-Error "Podaj adres URL badanej strony, np.: .\scripts\generate-client-audit.ps1 -Url 'https://example.com' -Open"
    exit 1
}

$nodeArgs = @($scriptJs, $Url)
if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
    $nodeArgs += @("--out", $OutDir)
}
if (-not [string]::IsNullOrWhiteSpace($ClientName)) {
    $nodeArgs += @("--client-name", $ClientName)
}

$outputLines = & node @nodeArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "Generowanie audytu zakonczylo sie bledem (kod: $LASTEXITCODE)."
    exit $LASTEXITCODE
}

$htmlPath = $null
$jsonPath = $null
foreach ($line in $outputLines) {
    Write-Host $line
    if ($line -match '^HTML_REPORT=(.+)$') {
        $htmlPath = $Matches[1].Trim()
    }
    elseif ($line -match '^JSON_REPORT=(.+)$') {
        $jsonPath = $Matches[1].Trim()
    }
}

if (-not $htmlPath -or -not (Test-Path $htmlPath)) {
    Write-Error "Nie znaleziono wygenerowanego pliku HTML raportu."
    exit 1
}

# Automatyczne generowanie pliku PDF przez Microsoft Edge lub Google Chrome (Headless)
$browserCandidates = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
)

$browserExe = $browserCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
$pdfPath = [System.IO.Path]::ChangeExtension($htmlPath, ".pdf")

if ($browserExe) {
    Write-Host "==> Konwersja raportu A4 do PDF przy uzyciu: $browserExe ..." -ForegroundColor Cyan
    $fileUri = ([System.Uri]::new((Resolve-Path $htmlPath).Path)).AbsoluteUri
    & $browserExe --headless --disable-gpu --no-pdf-header-footer "--print-to-pdf=$pdfPath" $fileUri 2>$null
    if (Test-Path $pdfPath) {
        Write-Host "PDF_REPORT=$pdfPath" -ForegroundColor Green
    }
}
else {
    Write-Warning "Nie wykryto przegladarki Edge/Chrome do automatycznego wydruku PDF. Raport HTML A4 jest gotowy do druku (Ctrl+P)."
}

if ($Open) {
    if (Test-Path $pdfPath) {
        Start-Process $pdfPath
    }
    else {
        Start-Process $htmlPath
    }
}
