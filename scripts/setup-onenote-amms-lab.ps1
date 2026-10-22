#Requires -Version 5.1
<#
.SYNOPSIS
    Tworzy dedykowany Notes OneNote "Laboratorium AMMS" z 6 zakładkami tematycznymi
    oraz automatycznie wypełnia je sformatowanymi instrukcjami (CF_HTML) i generuje
    interaktywną Księgę Inżynieryjną HTML.
#>
[CmdletBinding()]
Param(
    [string]$NotebookPath = "$env:USERPROFILE\Documents\OneNote Notebooks\Laboratorium AMMS",
    [switch]$AutoPasteToOneNote = $true
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

function ConvertTo-CfHtml {
    Param([Parameter(Mandatory)][string]$HtmlFragment)
    $headerTemplate = "Version:0.9`r`nStartHTML:{0:D10}`r`nEndHTML:{1:D10}`r`nStartFragment:{2:D10}`r`nEndFragment:{3:D10}`r`n"
    $pre = "<html><head><meta charset='utf-8'></head><body><!--StartFragment-->"
    $post = "<!--EndFragment--></body></html>"
    $dummyHeader = $headerTemplate -f 0, 0, 0, 0
    $startHtml = [System.Text.Encoding]::UTF8.GetByteCount($dummyHeader)
    $startFrag = $startHtml + [System.Text.Encoding]::UTF8.GetByteCount($pre)
    $fragBytes = [System.Text.Encoding]::UTF8.GetByteCount($HtmlFragment)
    $endFrag = $startFrag + $fragBytes
    $endHtml = $endFrag + [System.Text.Encoding]::UTF8.GetByteCount($post)
    $header = $headerTemplate -f $startHtml, $endHtml, $startFrag, $endFrag
    return ($header + $pre + $HtmlFragment + $post)
}

function Set-ClipboardHtml {
    Param(
        [Parameter(Mandatory)][string]$HtmlFragment,
        [Parameter(Mandatory)][string]$PlainTextTitle
    )
    $cfHtml = ConvertTo-CfHtml -HtmlFragment $HtmlFragment
    $dataObj = New-Object System.Windows.Forms.DataObject
    $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($cfHtml)
    $ms = New-Object System.IO.MemoryStream(,$utf8Bytes)
    $dataObj.SetData("Html Format", $ms)
    $dataObj.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $PlainTextTitle)
    [System.Windows.Forms.Clipboard]::SetDataObject($dataObj, $true)
}

try {
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Office\16.0\OneNote\General" -Name "ConsecutiveBootCrashes" -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Office\16.0\OneNote\General" -Name "ConsecutiveEarlyCrashes" -Value 0 -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $NotebookPath -Force | Out-Null

    # Rejestracja Notesu w OpenNotebooks obok MaxBit
    $regPath = "HKCU:\Software\Microsoft\Office\16.0\OneNote\OpenNotebooks"
    if (Test-Path $regPath) {
        $props = Get-ItemProperty -Path $regPath
        $alreadyOpen = $false
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Value -like "*Laboratorium AMMS*") { $alreadyOpen = $true }
        }
        if (-not $alreadyOpen) {
            Set-ItemProperty -Path $regPath -Name "2" -Value "$NotebookPath\"
        }
    }

    $blankOne = "C:\Program Files\Microsoft Office\root\Templates\1033\ONENOTE\16\Stationery\BLANK.ONE"
    $onePkg = "C:\Program Files\Microsoft Office\root\Office16\1033\ONGuide.onepkg"
    $tocPath = Join-Path $NotebookPath "Open Notebook.onetoc2"
    if ((Test-Path $onePkg) -and (-not (Test-Path $tocPath))) {
        & expand.exe "$onePkg" -F:"Open Notebook.onetoc2" "$NotebookPath" | Out-Null
    }

    $pages = @(
        @{
            File  = "01 - Architektura i Sieci VLAN.one"
            Title = "1. Architektura Wirtualnej Serwerowni Szpitalnej (4 VLAN-y)"
            Html  = @"
<div style="font-family:Calibri,Segoe UI,sans-serif;font-size:11pt;color:#1e293b;">
<h2 style="color:#1e40af;border-bottom:2px solid #1e40af;padding-bottom:4px;">🏥 Wirtualna Serwerownia Szpitalna Asseco AMMS (/opt/amms-lab)</h2>
<p>Środowisko laboratoryjne na serwerze <b>Oracle Cloud Always Free ARM64 (89.168.62.31, 4 OCPU Ampere, 24 GB RAM)</b> odwzorowujące prawdziwą architekturę sieciową szpitala z podziałem na 4 odizolowane podsieci VLAN.</p>

<h3 style="color:#0f172a;">🗺️ Mapa 4 Podsieci Szpitalnych (Docker VLAN Bridge)</h3>
<table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse;width:100%;border-color:#cbd5e1;">
  <tr style="background-color:#1e3a8a;color:#ffffff;font-weight:bold;">
    <td>Strefa VLAN</td>
    <td>Podsieć IP</td>
    <td>Kontener Docker</td>
    <td>Nazwa DNS (Hostname)</td>
    <td>Adres IP w sieci</td>
    <td>Rola w Szpitalu</td>
  </tr>
  <tr style="background-color:#f8fafc;">
    <td><b>VLAN 10 (DB)</b></td>
    <td><code>10.20.10.0/24</code></td>
    <td><code>szpital-oracle-db</code></td>
    <td><code>db.szpital.lab</code></td>
    <td><b><code>10.20.10.10:1521</code></b></td>
    <td>Serwer bazy danych Oracle 23ai Free ARM64 (SID/Service: <code>moja</code>, user: <code>SYSADM</code>)</td>
  </tr>
  <tr>
    <td><b>VLAN 20 (HIS)</b></td>
    <td><code>10.20.20.0/24</code></td>
    <td><code>szpital-amms-his</code></td>
    <td><code>amms.szpital.lab</code></td>
    <td><b><code>10.20.20.10:8080</code></b></td>
    <td>Serwer aplikacyjny HIS Asseco AMMS (WildFly 26.0.1.Final + <code>amms.ear</code> + Java 8)</td>
  </tr>
  <tr style="background-color:#f8fafc;">
    <td><b>VLAN 30 (DMZ)</b></td>
    <td><code>10.20.30.0/24</code></td>
    <td><code>szpital-integracja</code></td>
    <td><code>int.szpital.lab</code></td>
    <td><b><code>10.20.30.10:8181</code></b></td>
    <td>Platforma Integracyjna Asseco (Apache Tomcat: <code>documents-utility</code>, <code>pdf-generator</code>)</td>
  </tr>
  <tr>
    <td><b>VLAN 40 (LAN)</b></td>
    <td><code>10.20.40.0/24</code></td>
    <td><code>szpital-pc01-desktop</code></td>
    <td><code>pc01.szpital.lab</code></td>
    <td><b><code>10.20.40.50:3000</code></b></td>
    <td>Graficzna Stacja Robocza Lekarza / Admina (Linux XFCE + Firefox w sieci szpitala)</td>
  </tr>
</table>

<h3 style="color:#0f172a;margin-top:14px;">🔒 Bezpieczeństwo Zero Trust i Porty Tunelu SSH (Localhost)</h3>
<ul>
  <li>Żaden port szpitalny nie jest wystawiony do internetu (WAN). Wszystkie porty słuchają wyłącznie na <code>127.0.0.1</code> na VPS.</li>
  <li><b><code>http://localhost:3010</code></b> &rarr; Wirtualny Pulpit Lekarza <code>PC01</code> (przeglądarka wewnątrz sieci szpitalnej).</li>
  <li><b><code>http://localhost:18080/amms</code></b> &rarr; Bezpośredni dostęp do AMMS (WildFly 26).</li>
  <li><b><code>http://localhost:18081</code></b> &rarr; Bezpośredni dostęp do Platformy Integracyjnej Tomcat (port 8181 w kontenerze).</li>
  <li><b><code>localhost:11521/moja</code></b> &rarr; Bezpośredni tunel JDBC/SQL Developer do bazy Oracle na VPS.</li>
</ul>
</div>
"@
        },
        @{
            File  = "02 - Dostep SSH, MobaXterm i PC01.one"
            Title = "2. Dostęp 1-Klik, MobaXterm i Wirtualny Pulpit Lekarza (PC01)"
            Html  = @"
<div style="font-family:Calibri,Segoe UI,sans-serif;font-size:11pt;color:#1e293b;">
<h2 style="color:#1e40af;border-bottom:2px solid #1e40af;padding-bottom:4px;">🖥️ Jak wchodzić do Laboratorium i obsługiwać Serwerownię</h2>

<h3 style="color:#0f172a;">1️⃣ Uruchamianie jednym kliknięciem z Windowsa</h3>
<ul>
  <li>Skrót w projekcie: <code>scripts\open-amms-lab.cmd</code></li>
  <li>Skrót w paczce na Pulpicie: <code>Desktop\AMMS-Asystent-Drugi-Komputer\3-Uruchom-Laboratorium-Szpitalne-AMMS.cmd</code></li>
  <li>Co robi skrypt: zestawia szyfrowany tunel SSH w tle (porty <code>3010</code>, <code>18080</code>, <code>18081</code>, <code>19990</code>, <code>11521</code>) i otwiera w przeglądarce Wirtualny Pulpit <code>PC01</code> (<code>http://localhost:3010</code>).</li>
</ul>

<h3 style="color:#0f172a;">2️⃣ Zakładki w MobaXterm (User Sessions)</h3>
<ul>
  <li><b><code>1-VPS-Szpital-Lab (Serwerownia AMMS)</code></b> &rarr; Loguje po SSH na <code>ubuntu@89.168.62.31</code> z kluczem <code>~/.ssh/id_ed25519</code>, przechodzi do <code>/opt/amms-lab</code> i automatycznie wyświetla kolorową tablicę 4 serwerów (<code>/opt/amms-lab/status-lab.sh</code>).</li>
  <li><b><code>2-Lokalny-PC-Transfer (Moj Komputer)</code></b> &rarr; Lokalny terminal z podpiętym kluczem SSH do wysyłania paczek przez <code>rsync</code>.</li>
</ul>

<h3 style="color:#0f172a;">3️⃣ Praca na Wirtualnym Pulpicie Lekarza (PC01 - 10.20.40.50)</h3>
<ul>
  <li>Otwórz w przeglądarce na swoim komputerze: <b><code>http://localhost:3010</code></b></li>
  <li>Wewnątrz wirtualnego pulpitu kliknij ikonę <b>Firefox</b> lub <b>Terminal</b>.</li>
  <li>W Firefoksie wewnątrz <code>PC01</code> używasz prawdziwych wewnętrznych adresów szpitalnych:
    <ul>
      <li>AMMS HIS: <b><code>http://amms.szpital.lab:8080/amms</code></b></li>
      <li>Platforma Integracyjna (Wydruki): <b><code>http://int.szpital.lab:8181/documents-utility</code></b></li>
      <li>Generator PDF: <b><code>http://int.szpital.lab:8181/pdf-generator</code></b></li>
    </ul>
  </li>
</ul>
</div>
"@
        },
        @{
            File  = "03 - Baza Oracle 23ai ARM64.one"
            Title = "3. Baza Danych Oracle 23ai ARM64 i Odchudzanie Bazy MOJA"
            Html  = @"
<div style="font-family:Calibri,Segoe UI,sans-serif;font-size:11pt;color:#1e293b;">
<h2 style="color:#1e40af;border-bottom:2px solid #1e40af;padding-bottom:4px;">🗄️ Serwer Bazy Danych Oracle (db.szpital.lab / 10.20.10.10)</h2>

<h3 style="color:#0f172a;">1️⃣ Parametry Kontenera <code>szpital-oracle-db</code></h3>
<table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse;width:100%;border-color:#cbd5e1;">
  <tr style="background-color:#1e3a8a;color:#ffffff;font-weight:bold;">
    <td>Parametr</td>
    <td>Wartość</td>
    <td>Opis</td>
  </tr>
  <tr><td>Obraz Docker</td><td><code>gvenzl/oracle-free:23-slim</code></td><td>Natywny obraz ARM64 (Ampere Altra) bez narzutu emulacji x86</td></tr>
  <tr style="background-color:#f8fafc;"><td>Adres w sieci Lab</td><td><code>db.szpital.lab:1521</code> (<code>10.20.10.10</code>)</td><td>Strefa VLAN 10 (Bazy Danych)</td></tr>
  <tr><td>Nazwa serwisowa (PDB)</td><td><b><code>moja</code></b></td><td>Zgodna z Twoją lokalną bazą Oracle 19c</td></tr>
  <tr style="background-color:#f8fafc;"><td>Użytkownik / Hasło</td><td><b><code>SYSADM</code> / <code>sysadm</code></b></td><td>Główny schemat właściciela tabel AMMS</td></tr>
  <tr><td>Katalog Data Pump</td><td><code>/opt/amms-lab/transfer</code> &rarr; <code>/opt/oracle/dpdump</code></td><td>Współdzielony katalog do importu <code>impdp</code></td></tr>
</table>

<h3 style="color:#0f172a;margin-top:14px;">2️⃣ Dlaczego lokalna baza MOJA waży 270 GB i jak odchudzamy ją do ~3 GB?</h3>
<p>Audyt przestrzeni tablespace na Twoim komputerze wykazał, że ponad <b>140 GB</b> zajmują wyłącznie tabele logów i retencji:</p>
<ul>
  <li><code>SYSADM.DBAP_OPERATIONS</code> (40 GB), <code>SYSADM.TEMP_RETENTION</code> (30.4 GB), <code>SYSADM.AUTORYZACJA_DANYCH</code> (21.2 GB), <code>SYSADM.TRACE_LOG_COPY</code> (10.8 GB), <code>SYSADM.PAC_DOKUM_EWUS</code> (6.6 GB).</li>
  <li>Podczas eksportu <code>expdp</code> używamy flagi <code>QUERY=SYSADM.DBAP_OPERATIONS:"WHERE 1=0"</code> (przenosimy strukturę tych tabel z 0 wierszy logów) oraz przy imporcie <code>impdp</code> flagi <b><code>TRANSFORM=SEGMENT_ATTRIBUTES:N</code></b> (usuwającej puste początkowe alokacje <code>INITIAL EXTENT</code>).</li>
  <li>Dzięki temu pełna baza szpitalna AMMS ze wszystkimi słownikami, konfiguracją i strukturami mieści się w kilku gigabajtach na dysku VPS!</li>
</ul>
</div>
"@
        },
        @{
            File  = "04 - Serwer AMMS WildFly i Tomcat.one"
            Title = "4. Konfiguracja Serwera AMMS (WildFly 26) i Wydruków (Tomcat)"
            Html  = @"
<div style="font-family:Calibri,Segoe UI,sans-serif;font-size:11pt;color:#1e293b;">
<h2 style="color:#1e40af;border-bottom:2px solid #1e40af;padding-bottom:4px;">⚙️ Serwer Aplikacyjny AMMS (WildFly 26) + Wydruki (Tomcat DMZ)</h2>

<h3 style="color:#0f172a;">1️⃣ Kluczowe pliki konfiguracyjne na VPS</h3>
<ul>
  <li><b>Datasource JDBC w WildFly:</b> <code>/opt/amms-lab/amms-wildfly/wildfly-26.0.1.Final/standalone/configuration/standalone.xml</code>
    <br/>URL połączenia zmieniony z <code>localhost:1521/moja</code> na: <b><code>jdbc:oracle:thin:@db.szpital.lab:1521/moja</code></b></li>
  <li><b>Konfiguracja AMMS (<code>appConfig.properties</code>):</b> <code>/opt/amms-lab/amms-wildfly/wildfly-26.0.1.Final/configs/appConfig.properties</code>
    <ul>
      <li><code>pdf.service=http://int.szpital.lab:8181/pdf-generator/rest/pdfprint</code></li>
      <li><code>documents-utility.service.host.url=http://int.szpital.lab:8181/documents-utility</code></li>
      <li><code>password-manager.key.path=/opt/wildfly/wildfly-26.0.1.Final/configs/pass.key</code></li>
      <li><code>pi.rest.jwt.secret=ua1ilJM1fAWRV77CSkoI2XvsqUEJoztuo7LZfp9Uy45bwr3kxoN6JEUuL6Dmdgtr</code></li>
    </ul>
  </li>
  <li><b>Konfiguracja Wydruków Jasper (Tomcat):</b> <code>/opt/amms-lab/integracja-tomcat/apache-tomcat/webapps/documents-utility/appConfig.properties</code>
    <ul>
      <li><code>jdbc.documents-utility.medical.url=jdbc:oracle:thin:@db.szpital.lab:1521/moja</code></li>
    </ul>
  </li>
</ul>

<h3 style="color:#0f172a;margin-top:14px;">2️⃣ Standardy uruchomieniowe ze Szkolenia Linux Asseco</h3>
<ul>
  <li>Obraz Javy: <b>OpenJDK 8 (Temurin 8)</b> z podpiętym polskim kodowaniem znaków Asseco:
    <br/><code>-Xbootclasspath/a:/opt/wildfly/wildfly-26.0.1.Final/modules/system/layers/base/pl/asseco/amms/main/amms-charsets-1.0.0.jar</code></li>
  <li>Flagi wymagane dla AMMS i Oracle JDBC na Linuksie:
    <br/><code>-DappServerIntegration=true -Doracle.jdbc.disableOob=true -Doracle.net.disableOob=true -Djava.awt.headless=true</code></li>
</ul>
</div>
"@
        },
        @{
            File  = "05 - Srodowiska Testowe P1 i Docker.one"
            Title = "5. Środowiska Testowe Asseco / CeZ (P1) i Kontenery Docker"
            Html  = @"
<div style="font-family:Calibri,Segoe UI,sans-serif;font-size:11pt;color:#1e293b;">
<h2 style="color:#1e40af;border-bottom:2px solid #1e40af;padding-bottom:4px;">🔐 Środowiska Testowe Asseco, Certyfikaty P1 i GitLab Docker</h2>

<h3 style="color:#0f172a;">1️⃣ Adresy Testowe (Integracyjne) do testowania wysyłki P1 / EDM / CeR / KSK</h3>
<table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse;width:100%;border-color:#cbd5e1;">
  <tr style="background-color:#1e3a8a;color:#ffffff;font-weight:bold;">
    <td>Usługa / Parametr</td>
    <td>Adres Testowy / Wartość ze Szkolenia</td>
    <td>Uwagi</td>
  </tr>
  <tr><td><b>Testowy AMMS REST (Asseco Prezentacja2)</b></td><td><code>https://amms.asseco.pl/prezentacja2/pi-rest/</code></td><td>Można wpisać jako <code>AMMS_REST_URL</code> w kontenerach PI</td></tr>
  <tr style="background-color:#f8fafc;"><td><b>Nasz Lab AMMS REST (Wewnętrzny)</b></td><td><code>http://amms.szpital.lab:8080/amms/pi-rest/</code></td><td>Adres naszego kontenera WildFly w VLAN 20</td></tr>
  <tr><td><b>CeZ / P1 Token URL (TEST)</b></td><td><code>https://isus.ezdrowie.gov.pl/token</code></td><td>Produkcja to: <code>https://sus.ezdrowie.gov.pl/token</code></td></tr>
  <tr style="background-color:#f8fafc;"><td><b>CeZ / P1 Usługi (TEST)</b></td><td><code>https://isus.ezdrowie.gov.pl</code></td><td>Środowisko integracyjne Centrum e-Zdrowia</td></tr>
  <tr><td><b>Kod resortowy podmiotu testowego</b></td><td><code>AMMS_ORGANIZATION_IDENTIFIER=000000025677</code></td><td>I część kodu resortowego ze szkoleń Asseco</td></tr>
  <tr style="background-color:#f8fafc;"><td><b>Certyfikaty testowe P1 (PKCS12)</b></td><td><code>certs/Podmiot_leczniczy_16-wss.p12</code> + <code>certs/ezdrowie.cer</code></td><td>Aliasy: <code>podmiot_leczniczy_16-uwierzytelnienie systemu</code> / <code>danych</code></td></tr>
</table>

<h3 style="color:#0f172a;margin-top:14px;">2️⃣ Repozytoria Docker Platformy Integracyjnej 2.0 (GitLab Asseco)</h3>
<ul>
  <li><b>Adres GitLab Asseco:</b> <code>https://amms.asseco.pl/gitlab/asseco-poz</code></li>
  <li><b>Kluczowe kontenery (gotowe do wstawienia w naszą strefę DMZ <code>10.20.30.0/24</code>):</b>
    <ul>
      <li><code>pi-p1-ksk-provider</code> (Krajowa Sieć Kardiologiczna e-KOK)</li>
      <li><code>pi-p1-kso-provider</code> (Krajowa Sieć Onkologiczna e-DILO)</li>
      <li><code>pi-p1-erejestracja-provider</code> (Centralna e-Rejestracja CeR)</li>
      <li><code>Integration-Platform/si-hl7/pi-hl7-provider</code> (Komunikacja HL7)</li>
      <li><code>si-nfz-master</code> / <code>si-nfz-container</code> (Komunikacja NFZ)</li>
    </ul>
  </li>
  <li><b>Serwer FTP Asseco z dokumentacją i instalkami:</b> <code>ftps://dwftp.gliwice.asseco.pl</code> (<code>/public/AMMS/Install/</code>)</li>
</ul>
</div>
"@
        },
        @{
            File  = "06 - Sciaga Komend i Diagnostyka.one"
            Title = "6. Ściąga Komend (MobaXterm) i Zarządzanie Serwerownią"
            Html  = @"
<div style="font-family:Calibri,Segoe UI,sans-serif;font-size:11pt;color:#1e293b;">
<h2 style="color:#1e40af;border-bottom:2px solid #1e40af;padding-bottom:4px;">🛠️ Ściąga Komend Administratora Szpitala (Wklej w MobaXterm)</h2>

<table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse;width:100%;border-color:#cbd5e1;">
  <tr style="background-color:#1e3a8a;color:#ffffff;font-weight:bold;">
    <td>Czynność</td>
    <td>Komenda na VPS (zakładka <code>ubuntu@devops-vps</code>)</td>
  </tr>
  <tr>
    <td><b>Tablica statusu całej serwerowni (4 VLAN-y)</b></td>
    <td><code>/opt/amms-lab/status-lab.sh</code></td>
  </tr>
  <tr style="background-color:#f8fafc;">
    <td><b>Uruchomienie wszystkich 4 serwerów szpitalnych</b></td>
    <td><code>cd /opt/amms-lab &amp;&amp; docker compose up -d</code></td>
  </tr>
  <tr>
    <td><b>Zatrzymanie laboratorium (zwolnienie RAM-u na VPS)</b></td>
    <td><code>cd /opt/amms-lab &amp;&amp; docker compose stop</code></td>
  </tr>
  <tr style="background-color:#f8fafc;">
    <td><b>Restart samego serwera AMMS (WildFly 26)</b></td>
    <td><code>docker restart szpital-amms-his</code></td>
  </tr>
  <tr>
    <td><b>Podgląd logów startu AMMS na żywo</b></td>
    <td><code>docker logs -f --tail 100 szpital-amms-his</code></td>
  </tr>
  <tr style="background-color:#f8fafc;">
    <td><b>Podgląd logów bazy Oracle DB na żywo</b></td>
    <td><code>docker logs -f --tail 100 szpital-oracle-db</code></td>
  </tr>
  <tr>
    <td><b>Podgląd logów Platformy Integracyjnej (Tomcat)</b></td>
    <td><code>docker logs -f --tail 100 szpital-integracja</code></td>
  </tr>
  <tr style="background-color:#f8fafc;">
    <td><b>Wejście do konsoli SQL*Plus w bazie Oracle</b></td>
    <td><code>docker exec -it szpital-oracle-db sqlplus sysadm/sysadm@moja</code></td>
  </tr>
  <tr>
    <td><b>Wejście do terminala serwera AMMS</b></td>
    <td><code>docker exec -it szpital-amms-his bash</code></td>
  </tr>
  <tr style="background-color:#f8fafc;">
    <td><b>Sprawdzenie wolnego miejsca na dysku VPS i RAM-u</b></td>
    <td><code>df -h / &amp;&amp; free -h</code></td>
  </tr>
</table>
</div>
"@
        }
    )

    # Zapisz również zbiorczy plik HTML w katalogu Notesu
    $fullBookHtml = @"
<!DOCTYPE html>
<html lang="pl">
<head>
<meta charset="utf-8">
<title>Notes: Laboratorium AMMS (Kompendium)</title>
<style>
  body { font-family: 'Segoe UI', Calibri, sans-serif; background: #f1f5f9; color: #1e293b; max-width: 1050px; margin: 24px auto; padding: 0 16px; }
  .card { background: #fff; border-radius: 10px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); padding: 24px; margin-bottom: 24px; border-top: 5px solid #1e40af; }
  code { background: #e2e8f0; padding: 2px 6px; border-radius: 4px; font-family: Consolas, monospace; font-size: 10pt; }
</style>
</head>
<body>
<h1 style="color:#0f172a;">📘 Notes Inżynieryjny: Laboratorium Szpitalne Asseco AMMS</h1>
"@
    foreach ($p in $pages) {
        $fullBookHtml += "<div class='card'>$($p.Html)</div>`r`n"
        $secPath = Join-Path $NotebookPath $p.File
        if (-not (Test-Path $secPath)) {
            Copy-Item -Path $blankOne -Destination $secPath -Force
        }
    }
    $fullBookHtml += "</body></html>"
    Set-Content -Path (Join-Path $NotebookPath "Kompendium-Laboratorium-AMMS.html") -Value $fullBookHtml -Encoding UTF8

    if ($AutoPasteToOneNote) {
        $oneNoteExe = "C:\Program Files\Microsoft Office\root\Office16\ONENOTE.EXE"
        $wshell = New-Object -ComObject WScript.Shell

        if (Test-Path $tocPath) {
            Start-Process -FilePath $oneNoteExe -ArgumentList "`"$tocPath`""
            Start-Sleep -Milliseconds 2000
        }

        foreach ($p in $pages) {
            $secPath = Join-Path $NotebookPath $p.File
            Start-Process -FilePath $oneNoteExe -ArgumentList "`"$secPath`""
            Start-Sleep -Milliseconds 1300
            [void]$wshell.AppActivate("OneNote")
            Start-Sleep -Milliseconds 250
            # Zaznacz wszystkie szablonowe strony w sekcji (Ctrl+Shift+T -> 3x Ctrl+Shift+A) i usun je (DEL)
            $wshell.SendKeys("^+t")
            Start-Sleep -Milliseconds 100
            $wshell.SendKeys("^+a")
            Start-Sleep -Milliseconds 100
            $wshell.SendKeys("^+a")
            Start-Sleep -Milliseconds 100
            $wshell.SendKeys("^+a")
            Start-Sleep -Milliseconds 100
            $wshell.SendKeys("{DEL}")
            Start-Sleep -Milliseconds 200
            # Wklej tytul strony i przejdz do tresci (ENTER)
            [System.Windows.Forms.Clipboard]::SetText($p.Title)
            $wshell.SendKeys("^+t")
            Start-Sleep -Milliseconds 100
            $wshell.SendKeys("^v")
            Start-Sleep -Milliseconds 120
            $wshell.SendKeys("{ENTER}")
            Start-Sleep -Milliseconds 150
            # Wklej sformatowane tabele HTML
            Set-ClipboardHtml -HtmlFragment $p.Html -PlainTextTitle $p.Title
            $wshell.SendKeys("^v")
            Start-Sleep -Milliseconds 600
        }
        # Na koniec przełącz na zakładkę nr 1
        $firstSec = Join-Path $NotebookPath $pages[0].File
        Start-Process -FilePath $oneNoteExe -ArgumentList "`"$firstSec`""
    }
    Write-Output "OneNote Notebook 'Laboratorium AMMS' utworzony i wypelniony pomyslnie!"
} catch {
    Write-Error "Blad podczas konfiguracji OneNote: $_"
    exit 1
}
