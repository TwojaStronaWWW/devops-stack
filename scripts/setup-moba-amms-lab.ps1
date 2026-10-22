<#
.SYNOPSIS
    Automatyczna konfiguracja sesji i zestawienia Laboratorium Szpitalnego AMMS w MobaXterm.
.DESCRIPTION
    1. Kopiuje klucz prywatny Ed25519 oraz konfigurację ~/.ssh/config do środowiska MobaXterm.
    2. Dodaje do MobaXterm.ini dedykowany katalog sesji 'VPS - Szpital AMMS Lab' z 6 sesjami:
       - [0] ZESTAWIENIE SERWEROWNI (Dashboard na żywo wszystkich VLAN-ów i serwerów)
       - [1] VPS-HOST (89.168.62.31 - Główny serwer + SFTP w katalogu /opt/amms-lab)
       - [2] SRV-ORACLE-DB (10.20.10.10 | db.szpital.lab - Baza Oracle MOJA)
       - [3] SRV-AMMS-HIS (10.20.20.10 | amms.szpital.lab - WildFly 26 + amms.ear)
       - [4] SRV-INTEGRACJA (10.20.30.10 | int.szpital.lab - Apache Tomcat DMZ)
       - [5] PC01-DESKTOP (10.20.40.50 | pc01.szpital.lab - Stacja Robocza Lekarza)
    3. Tworzy plik eksportu sesji Szpital-AMMS-Lab.mxtsessions na Pulpicie.
#>

[CmdletBinding()]
param(
    [string]$HostIp = "89.168.62.31",
    [string]$User = "ubuntu",
    [string]$KeyPath = "C:\Users\kpocz\.ssh\id_ed25519"
)

$ErrorActionPreference = "Stop"

try {
    $MobaAppData = Join-Path $env:APPDATA "MobaXterm"
    $MobaIniPath = Join-Path $MobaAppData "MobaXterm.ini"
    $MobaHomeSsh = Join-Path $MobaAppData "slash\home\mobaxterm\.ssh"

    if (-not (Test-Path -Path $MobaHomeSsh)) {
        New-Item -ItemType Directory -Path $MobaHomeSsh -Force | Out-Null
    }

    if (Test-Path -Path $KeyPath) {
        Copy-Item -Path $KeyPath -Destination (Join-Path $MobaHomeSsh "id_ed25519") -Force
        $sshConfig = @"
Host $HostIp vps-szpital
    HostName $HostIp
    User $User
    Port 22
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
"@
        Set-Content -Path (Join-Path $MobaHomeSsh "config") -Value $sshConfig -Encoding ASCII
    }

    function New-MobaSshLine {
        param(
            [string]$Name,
            [string]$RemoteCmd,
            [int]$Icon = 109
        )
        return "$Name=#$Icon#0%$HostIp%22%$User%%-1%-1%$RemoteCmd%%%%0%-1%0%$KeyPath%%-1%-1%0%0%%1080%%0%0%1%%0%%%%0%-1%-1%0%%%0#MobaFont%10%0%0%-1%15%236,236,236%30,30,30%180,180,192%0%-1%0%UTF-8%xterm%-1%0%_Std_Colors_0_%80%24%0%1%-1%<none>%%0%0%-1%0%#0# #-1"
    }

    $BookmarkBlock = @(
        "[Bookmarks_1]",
        "SubRep=VPS - Szpital AMMS Lab",
        "ImgNum=41",
        (New-MobaSshLine -Name "0. ZESTAWIENIE SERWEROWNI (Status + SFTP)" -RemoteCmd "" -Icon 93),
        (New-MobaSshLine -Name "1. VPS-HOST Glowny (Pełne Drzewo Plików SFTP)" -RemoteCmd "" -Icon 109),
        (New-MobaSshLine -Name "2. SRV-ORACLE-DB (10.20.10.10 - db.szpital.lab)" -RemoteCmd "docker exec -it szpital-oracle-db bash 2>/dev/null || (echo 'Kontener szpital-oracle-db jeszcze nie uruchomiony'; cd /opt/amms-lab; exec bash)" -Icon 140),
        (New-MobaSshLine -Name "3. SRV-AMMS-HIS (10.20.20.10 - amms.szpital.lab)" -RemoteCmd "docker exec -it szpital-amms-his bash 2>/dev/null || (echo 'Kontener szpital-amms-his jeszcze nie uruchomiony'; cd /opt/amms-lab; exec bash)" -Icon 109),
        (New-MobaSshLine -Name "4. SRV-INTEGRACJA (10.20.30.10 - int.szpital.lab)" -RemoteCmd "docker exec -it szpital-integracja bash 2>/dev/null || (echo 'Kontener szpital-integracja jeszcze nie uruchomiony'; cd /opt/amms-lab; exec bash)" -Icon 109),
        (New-MobaSshLine -Name "5. PC01-DESKTOP (10.20.40.50 - pc01.szpital.lab)" -RemoteCmd "docker exec -it szpital-pc01-desktop bash" -Icon 105),
        ""
    ) -join "`r`n"

    # Zapis pliku .mxtsessions na Pulpicie (do ręcznego importu w razie potrzeby)
    $MxtSessionsFile = "$HOME\Desktop\AMMS-Asystent-Drugi-Komputer\Szpital-AMMS-Lab.mxtsessions"
    $MxtContent = ($BookmarkBlock -replace "^\[Bookmarks_1\]", "[Bookmarks]")
    Set-Content -Path $MxtSessionsFile -Value $MxtContent -Encoding ASCII

    # Aktualizacja MobaXterm.ini (jeśli istnieje)
    if (Test-Path -Path $MobaIniPath) {
        $iniContent = Get-Content -Path $MobaIniPath -Raw
        if ($iniContent -match "\[Bookmarks_1\]") {
            $iniContent = $iniContent -replace "(?ms)\[Bookmarks_1\].*?(?=\r?\n\[|\z)", ($BookmarkBlock + "`r`n")
        } else {
            $iniContent = $iniContent.TrimEnd() + "`r`n`r`n" + $BookmarkBlock + "`r`n"
        }
        Set-Content -Path $MobaIniPath -Value $iniContent -Encoding ASCII
        Write-Host ">> [OK] Dodano folder 'VPS - Szpital AMMS Lab' do MobaXterm.ini" -ForegroundColor Green
    }

    Write-Host ">> [OK] Zapisano plik sesji: $MxtSessionsFile" -ForegroundColor Green
} catch {
    Write-Error "Błąd konfiguracji MobaXterm: $($_.Exception.Message)"
    exit 1
}
