# Przewodnik Wdrożeniowy: Wielostrefowe Laboratorium Szpitalne Asseco AMMS na VPS (Oracle Ampere ARM64)

> **Standard Infrastruktury**: Wirtualna Serwerownia Szpitalna (`*.szpital.lab`) odseparowana w `/opt/amms-lab` z 4 dedykowanymi podsieciami VLAN (`10.20.10.0/24` – `10.20.40.0/24`), zgodna z architekturą **Zero Trust** (dostęp wyłącznie przez szyfrowany tunel SSH Ed25519) i mieszcząca się w 100% w darmowej puli **Oracle Cloud Always Free (0.00 PLN)**.

---

## 1. Architektura i Adresacja Sieci Szpitalnej (`*.szpital.lab`)

```text
[ Stacja Lokalna Windows 11 ] ═══( Szyfrowany Tunel SSH: porty 3010, 18080, 18081, 11521 )═══► [ VPS Oracle Ampere 24 GB RAM ]
                                                                                                         │
  ┌──────────────────────────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────┐
  │                                            WIRTUALNA SERWEROWNIA SZPITALNA (/opt/amms-lab)           │                                           │
  │                                                                                                      │                                           │
  │  [VLAN 10] STREFA BAZY DANYCH (szpital_vlan_db: 10.20.10.0/24)                                       │  [VLAN 20] STREFA HIS (szpital_vlan_his: 10.20.20.0/24)
  │  ┌──────────────────────────────────────────────────────────┐                                        │  ┌────────────────────────────────────────┐
  │  │ 🗄️ szpital-oracle-db (10.20.10.10 | db.szpital.lab)      │◄───────────── port 1521 ───────────────┼──┤ 🏥 szpital-amms-his (10.20.20.10)      │
  │  │ • Silnik: Oracle Database ARM64 (SID/Service: MOJA)      │               (JDBC Thin)              │  │ • Hostname: amms.szpital.lab           │
  │  │ • Schematy: SYSADM, AD, AMMS_INFRA, P1_ZDM, LICENCE      │                                        │  │ • OpenJDK 8 ARM64 + WildFly 26.0.1     │
  │  │ • Tunel SSH z Windowsa: 127.0.0.1:11521 -> 1521          │                                        │  │ • Wdrożenie: amms.ear (6.10.07)        │
  │  └──────────────────────────────────────────────────────────┘                                        │  │ • Tunel SSH: 127.0.0.1:18080 -> 8080   │
  │                                ▲                                                                     │  └───────────────────▲────────────────────┘
  │                                │ (JDBC: P1_ZDM / SYSADM)                                             │                      │                    │
  │                                ▼                                                                     │      (REST / SOAP / HL7 / WebServices)    │
  │  [VLAN 30] STREFA INTEGRACJI & DMZ (szpital_vlan_dmz: 10.20.30.0/24)                                 │                      ▼                    │
  │  ┌──────────────────────────────────────────────────────────┐                                        │  [VLAN 40] STACJE ROBOCZE (szpital_vlan_lan: 10.20.40.0/24)
  │  │ 🔌 szpital-integracja (10.20.30.10 | int.szpital.lab)    │◄───────────────────────────────────────┼──► 🖥️ szpital-pc01-desktop (10.20.40.50)  │
  │  │ • Apache Tomcat (Platforma Integracyjna Asseco)          │                                        │  │ • Hostname: pc01.szpital.lab           │
  │  │ • Aplikacje: documents-utility, pdf-generator            │                                        │  │ • Pulpit Graficzny Linux XFCE (Webtop) │
  │  │ • Tunel SSH z Windowsa: 127.0.0.1:18081 -> 8080          │                                        │  │ • Tunel SSH: http://localhost:3010     │
  │  └──────────────────────────────────────────────────────────┘                                        │  └────────────────────────────────────────┘
  └──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Tabela Adresacji Węzłów Laboratorium

| Węzeł (Kontener) | Nazwa DNS (`extra_hosts`) | Sieć VLAN | Adres IP w Labie | Port na VPS (`127.0.0.1`) | Przeznaczenie |
|---|---|---|---|---|---|
| **`szpital-oracle-db`** | `db.szpital.lab` | `szpital_vlan_db` | `10.20.10.10` | `127.0.0.1:11521` $\rightarrow$ `1521` | Baza danych Oracle (`MOJA`) ze schematami `SYSADM`, `LICENCE`, `AD`, `AMMS_INFRA`, `P1_ZDM`. |
| **`szpital-amms-his`** | `amms.szpital.lab` | `szpital_vlan_his` | `10.20.20.10` | `127.0.0.1:18080` $\rightarrow$ `8080`<br>`127.0.0.1:19990` $\rightarrow$ `9990` | Główny serwer aplikacyjny `WildFly 26.0.1.Final` z pakietem `amms.ear` oraz `amms-charsets-1.0.0.jar`. |
| **`szpital-integracja`** | `int.szpital.lab` | `szpital_vlan_dmz` | `10.20.30.10` | `127.0.0.1:18081` $\rightarrow$ `8080` | Serwer Platformy Integracyjnej (`Apache Tomcat`: `documents-utility`, `pdf-generator`, integracje P1/EDM/HL7). |
| **`szpital-pc01-desktop`** | `pc01.szpital.lab` | `szpital_vlan_lan` | `10.20.40.50` | `127.0.0.1:3010` $\rightarrow$ `3000` | Graficzna stacja robocza w przeglądarce (XFCE Desktop + Chromium + narzędzia bazodanowe i diagnostyczne). |

---

## 2. Instrukcja Wdrożenia Krok po Kroku („Na Piechotę”)

### KROK 1: Przygotowanie klucza SSH na Windows 11 i rekonesans zasobów VPS

1. Na komputerze z Windows 11 upewnij się, że klucz prywatny Ed25519 znajduje się w `$HOME\.ssh\id_ed25519` i posiada restrykcyjne uprawnienia NTFS (`icacls`):
   ```powershell
   Copy-Item -Path "$HOME\Desktop\AMMS-Asystent-Drugi-Komputer\klucz\id_ed25519" -Destination "$HOME\.ssh\id_ed25519" -Force
   icacls "$HOME\.ssh\id_ed25519" /inheritance:r
   icacls "$HOME\.ssh\id_ed25519" /grant:r "$($env:USERNAME):(R)"
   ssh -i "$HOME\.ssh\id_ed25519" ubuntu@89.168.62.31
   ```
2. Po zalogowaniu na VPS zweryfikuj wolny RAM, dysk oraz obecne sieci Dockera:
   ```bash
   uname -m && nproc
   free -h
   df -h /
   docker network ls
   ```

---

### KROK 2: Utworzenie katalogów `/opt/amms-lab` oraz 4 podsieci szpitalnych VLAN

Na serwerze VPS (`ubuntu@vps-oracle-arm-prod`) utwórz odseparowaną strukturę katalogów oraz 4 mostki sieciowe Dockera symulujące szpitalne VLAN-y:

```bash
# 1. Struktura katalogów laboratorium (odseparowana od /opt/devops-stack)
sudo mkdir -p /opt/amms-lab/{oracle-db,amms-wildfly,integracja-tomcat,desktop-pc01,transfer}
sudo chown -R ubuntu:ubuntu /opt/amms-lab

# 2. Utworzenie 4 odseparowanych podsieci szpitalnych (VLAN 10, 20, 30, 40)
docker network create --driver=bridge --subnet=10.20.10.0/24 --gateway=10.20.10.1 szpital_vlan_db
docker network create --driver=bridge --subnet=10.20.20.0/24 --gateway=10.20.20.1 szpital_vlan_his
docker network create --driver=bridge --subnet=10.20.30.0/24 --gateway=10.20.30.1 szpital_vlan_dmz
docker network create --driver=bridge --subnet=10.20.40.0/24 --gateway=10.20.40.1 szpital_vlan_lan
```

---

### KROK 3: Uruchomienie Graficznego Desktopa Stacji Roboczej (`pc01.szpital.lab` – `10.20.40.50`)

1. Na serwerze VPS utwórz początkowy plik `/opt/amms-lab/docker-compose.yml` i uruchom stację roboczą `pc01-desktop`:
   ```bash
   cat << 'EOF' > /opt/amms-lab/docker-compose.yml
   services:
     pc01-desktop:
       image: lscr.io/linuxserver/webtop:ubuntu-xfce
       container_name: szpital-pc01-desktop
       hostname: pc01.szpital.lab
       restart: unless-stopped
       cap_add:
         - SYS_ADMIN
         - NET_ADMIN
       security_opt:
         - seccomp:unconfined
         - apparmor:unconfined
       environment:
         - PUID=1000
         - PGID=1000
         - TZ=Europe/Warsaw
         - SUBFOLDER=/
         - TITLE=PC01-Szpital-Lab (10.20.40.50)
         - LC_ALL=pl_PL.UTF-8
       volumes:
         - /opt/amms-lab/desktop-pc01:/config
       ports:
         - "127.0.0.1:3010:3000"
       shm_size: "1gb"
       extra_hosts:
         - "db.szpital.lab:10.20.10.10"
         - "amms.szpital.lab:10.20.20.10"
         - "int.szpital.lab:10.20.30.10"
         - "pc01.szpital.lab:10.20.40.50"
       networks:
         szpital_vlan_lan:
           ipv4_address: 10.20.40.50
         szpital_vlan_his:
           ipv4_address: 10.20.20.50
         szpital_vlan_dmz:
           ipv4_address: 10.20.30.50
         szpital_vlan_db:
           ipv4_address: 10.20.10.50

   networks:
     szpital_vlan_db:
       external: true
     szpital_vlan_his:
       external: true
     szpital_vlan_dmz:
       external: true
     szpital_vlan_lan:
       external: true
   EOF

   cd /opt/amms-lab && docker compose up -d
   ```

2. Na komputerze z Windows 11 otwórz tunel SSH (lub kliknij `scripts/open-amms-lab.cmd`) i wejdź w przeglądarce na **`http://localhost:3010`**:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\open-amms-lab.ps1"
   ```

---

### KROK 4: Odchudzone spakowanie i wysyłka `WildFly 26` (`amms.ear`) oraz `Platformy Integracyjnej (Tomcat)`

> [!TIP]
> **Optymalizacja transferu WildFly (`6,1 GB` $\rightarrow$ `1,2 GB`):**  
> Lokalny katalog `C:\WildflyAMMS\wildfly-26.0.1.Final` waży `6,1 GB`, ponieważ `standalone\tmp` zajmuje `3,6 GB`, a `standalone\data` kolejne `1,1 GB`. Pomijając te dwa katalogi tymczasowe podczas pakowania `tar`, przesyłamy na VPS jedynie **`~1,2 GB`** czystego serwera aplikacyjnego wraz z `amms.ear` i modułami `com/oracle` oraz `pl/asseco/amms`.

1. **Na komputerze lokalnym (PowerShell)** spakuj czysty serwer `WildFly` oraz `Tomcat` i wyślij je przez `scp` na VPS:
   ```powershell
   # 1. Spakowanie Platformy Integracyjnej Tomcat (~222 MB)
   tar -czf "$env:TEMP\integracja-tomcat.tar.gz" -C "C:\IntegrationPlatform" --exclude="apache-tomcat/logs/*" --exclude="apache-tomcat/temp/*" --exclude="apache-tomcat/work/*" apache-tomcat

   # 2. Spakowanie WildFly 26.0.1.Final + amms.ear bez katalogów tymczasowych tmp/data/log (~1.2 GB)
   tar -czf "$env:TEMP\amms-wildfly.tar.gz" -C "C:\WildflyAMMS" --exclude="wildfly-26.0.1.Final/standalone/tmp/*" --exclude="wildfly-26.0.1.Final/standalone/data/*" --exclude="wildfly-26.0.1.Final/standalone/log/*" wildfly-26.0.1.Final

   # 3. Wysłanie obu paczek po szyfrowanym SSH z auto-wznawianiem (rsync --append-verify)
   until rsync -avP --append-verify -e "ssh -i $HOME\.ssh\id_ed25519 -o ServerAliveInterval=10" "$env:TEMP\integracja-tomcat.tar.gz" "$env:TEMP\amms-wildfly.tar.gz" ubuntu@89.168.62.31:/opt/amms-lab/transfer/; do sleep 2; done
   ```

2. **Na serwerze VPS** rozpakuj archiwa do katalogów docelowych i przestaw adres bazy danych w `standalone.xml` z `127.0.0.1:1521/moja` na szpitalny adres `db.szpital.lab:1521/moja`:
   ```bash
   # Rozpakowanie Tomcata i WildFly
   tar -xzf /opt/amms-lab/transfer/integracja-tomcat.tar.gz -C /opt/amms-lab/integracja-tomcat/
   tar -xzf /opt/amms-lab/transfer/amms-wildfly.tar.gz -C /opt/amms-lab/amms-wildfly/

   # Utworzenie pustych katalogów runtime dla WildFly i Tomcata
   mkdir -p /opt/amms-lab/amms-wildfly/wildfly-26.0.1.Final/standalone/{tmp,data,log}
   mkdir -p /opt/amms-lab/integracja-tomcat/apache-tomcat/{logs,temp,work}
   chmod +x /opt/amms-lab/amms-wildfly/wildfly-26.0.1.Final/bin/*.sh
   chmod +x /opt/amms-lab/integracja-tomcat/apache-tomcat/bin/*.sh

   # Przestawienie JDBC w WildFly z 127.0.0.1 na db.szpital.lab (10.20.10.10)
   sed -i 's|jdbc:oracle:thin:@127.0.0.1:1521/moja|jdbc:oracle:thin:@db.szpital.lab:1521/moja|g' \
     /opt/amms-lab/amms-wildfly/wildfly-26.0.1.Final/standalone/configuration/standalone.xml
   ```

---

### KROK 5: Eksport bazy Oracle (`MOJA`) bez 140 GB logów tymczasowych i import na `db.szpital.lab`

> [!IMPORTANT]
> **Dlaczego nie kopiujemy surowych plików `.DBF` (`270 GB`)?**  
> Lokalna baza `MOJA` waży `270 GB`, ponieważ ponad `140 GB` zajmują tabele logów technicznych i retencji (`DBAP_OPERATIONS` z indeksami = `40,3 GB`, `TEMP_RETENTION` = `30,4 GB`, `AUTORYZACJA_DANYCH` = `21,2 GB`, `TRACE_LOG_COPY` = `10,8 GB`, `PAC_DOKUM_EWUS` = `6,6 GB`, `FORM2_WART_ARCH` = `2,6 GB`).  
> Używając `expdp` z wykluczeniem samych wierszy (`EXCLUDE=TABLE_DATA`) wyłącznie dla tych tabel logów (przy zachowaniu 100% ich definicji DDL, indeksów i triggerów!) oraz `COMPRESSION=ALL`, otrzymujemy lekki zrzut zawierający kompletny słownik **2 565 tabel**, kod **PL/SQL**, parametry **`KFG_PARAMETR`** oraz dane medyczne.

1. **Na komputerze lokalnym (PowerShell)** wykonaj odchudzony eksport `expdp` schematów `SYSADM`, `LICENCE`, `AD`, `AMMS_INFRA`, `P1_ZDM`:
   ```powershell
   # Utworzenie katalogu na zrzut DataPump
   New-Item -ItemType Directory -Path "C:\Temp\amms_export" -Force | Out-Null

   # Rejestracja katalogu w Oracle i uruchomienie expdp
   "CREATE OR REPLACE DIRECTORY AMMS_LAB_EXP AS 'C:\Temp\amms_export';`nEXIT;" | & "C:\db_home\bin\sqlplus.exe" -S "sysadm/sysadm@moja"

   expdp sysadm/sysadm@moja DIRECTORY=AMMS_LAB_EXP DUMPFILE=moja_lab.dmp LOGFILE=moja_lab_exp.log `
     SCHEMAS=SYSADM,LICENCE,AD,AMMS_INFRA,P1_ZDM,DATA_STORAGE `
     EXCLUDE=STATISTICS `
     QUERY=SYSADM.DBAP_OPERATIONS:'"WHERE 1=0"' `
     QUERY=SYSADM.TEMP_RETENTION:'"WHERE 1=0"' `
     QUERY=SYSADM.AUTORYZACJA_DANYCH:'"WHERE 1=0"' `
     QUERY=SYSADM.TRACE_LOG_COPY:'"WHERE 1=0"' `
     QUERY=SYSADM.PAC_DOKUM_EWUS:'"WHERE 1=0"' `
     QUERY=SYSADM.FORM2_WART_ARCH:'"WHERE 1=0"'
   ```

2. **Na serwerze VPS** zaimportuj zrzut do kontenera `szpital-oracle-db` (`10.20.10.10`) z flagą `TRANSFORM=SEGMENT_ATTRIBUTES:N` (eliminującą puste gigabajtowe alokacje przestrzeni `INITIAL EXTENT` z dużej bazy szpitalnej):
   ```bash
   docker exec -it szpital-oracle-db impdp system/OracleLab2026@//localhost:1521/moja \
     DIRECTORY=DATA_PUMP_DIR DUMPFILE=moja_lab.dmp LOGFILE=moja_lab_imp.log \
     TRANSFORM=SEGMENT_ATTRIBUTES:N,OID:N
   ```
