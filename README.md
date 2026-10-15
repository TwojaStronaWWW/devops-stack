# DevOps Stack & Zero-Bloat Monitoring

> **Infrastruktura DevOps**: Od środowiska lokalnego (WSL2: Ubuntu / Kali / Oracle Linux) do Oracle Cloud (ARM64 Ampere / AMD64) zgodna z normą **ISO 27001**, wytycznymi **CIS Benchmark**, zasadą **PoLP** (Principle of Least Privilege) i architekturą **Zero Trust**.

---

## 1. Architektura Systemu

```text
[ Internet / Zewnętrzni Użytkownicy & Witryny Klienckie (FuegoLingua, KatoSalsaHub, TwojaStronaWWW) ]
              │
              ▼ (Tunel szyfrowany TLS / QUIC - Porty zaporowe pozostają ZAMKNIĘTE)
[ Cloudflare Zero Trust (Tunnels & Access) ]
              │
              ▼ (Wewnętrzna sieć Docker: devops_internal_network)
 ┌────────────────────────────────────────────────────────────────────────┐
 │                              HOST VPS                                  │
 │                                                                        │
 │  ┌─────────────────┐ ┌───────────────┐ ┌────────────────────────────┐  │
 │  │  Uptime Kuma    │ │  Prometheus   │ │  Grafana                   │  │
 │  │  (Blackbox mon) │ │  (TSDB 15d)   │ │  (2 Dashboardy & Alerting) │  │
 │  │  127.0.0.1:3001 │ │ 127.0.0.1:9090│ │  127.0.0.1:3000           │  │
 │  └────────┬────────┘ └───────▲───────┘ └─────────────┬──────────────┘  │
 │           │                  │                       │                 │
 │           └────── metrics ───┤                       │                 │
 │                              │                       │                 │
 │  ┌─────────────────┐         │                       │                 │
 │  │  AI Router RAG  ├─────────┤ (/metrics & /health)  │                 │
 │  │  (7-Model Casc) │         │                       │                 │
 │  │  127.0.0.1:8085 │         │                       │                 │
 │  └─────────────────┘         │                       │                 │
 │  ┌─────────────────┐         │                       │                 │
 │  │  Node Exporter  ├─────────┤                       │                 │
 │  │  (CPU/RAM/Dysk) │         │                       │                 │
 │  └─────────────────┘         │                       │                 │
 │  ┌─────────────────┐         │                       │                 │
 │  │  cAdvisor       ├─────────┤                       │                 │
 │  │  (Docker stats) │         │                       │                 │
 │  └─────────────────┘         │                       │                 │
 │  ┌─────────────────┐         │                       │                 │
 │  │ GitHub Exporter ├─────────┘                       │                 │
 │  │ (CI/CD Actions) │                                 │                 │
 │  └─────────────────┘         ┌───────────────────────┴──────────────┐  │
 │                              │ Dozzle: Logi Kontenerów w Przeglądarce│  │
 │                              │ 127.0.0.1:8888                       │  │
 │                              └──────────────────────────────────────┘  │
 │                                                                        │
 │  ┌────────────────────────────────────────────────────────────────────────┐  │
 │  │  Zunifikowane Runnery Organizacji (zeslownikiem & TwojaStronaWWW)      │  │
 │  │  Obsługują automatycznie: gal-anonym, fuegolingua, _site-template itd. │  │
 │  └────────────────────────────────────────────────────────────────────────┘  │
 │                                                                        │
 │  Trwałe wolumeny danych & Kopia Offsite:                               │
 │  ├── uptime_kuma_data                                                  │
 │  ├── prometheus_data                                                   │
 │  ├── grafana_data                                                      │
 │  ├── ai_router_storage (rate-limit & ai_stats.json)                    │
 │  └── backup-offsite.sh ──> S3 / Cloudflare R2 / Oracle Cloud (Alerty)  │
 └────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Standardy Bezpieczeństwa & Pełna Ochrona Przed Włamaniami (ISO 27001)

Wszystkie mechanizmy obronne są wdrażane automatycznie przez skrypt [`scripts/01-harden-os.sh`](file:///e:/Projekty/VPS/scripts/01-harden-os.sh):

### A. Automatyczne Aktualizacje Bezpieczeństwa (Unattended Upgrades)
- **Codzienna instalacja łatek CVE**: System automatycznie pobiera i instaluje krytyczne poprawki bezpieczeństwa z oficjalnych repozytoriów (`security`), eliminując podatności typu zero-day bez konieczności ręcznego logowania administratora.
- **Higiena pakietów**: Automatyczne usuwanie zbędnych zależności i przestarzałych wersji jądra Linuksa (`Remove-Unused-Kernel-Packages: true`).

### B. Ochrona Dostępu SSH (Brak Haseł & Blokada Roota)
- **Blokada konta root**: `PermitRootLogin no` uniemożliwia bezpośrednie logowanie na konto roota.
- **Wyłączenie uwierzytelniania hasłem**: `PasswordAuthentication no` całkowicie eliminuje podatność na ataki słownikowe i zgadywanie haseł. Dozwolone są wyłącznie silne klucze asymetryczne (np. **Ed25519**).
- **Limit prób logowania**: `MaxAuthTries 3` – rozłączenie sesji po 3 nieudanych próbach.
- **Wyłączenie X11 i niepotrzebnych kanałów**: `X11Forwarding no`.

### C. System Zapobiegania Włamaniom (Fail2Ban Intrusion Prevention System)
- **Aktywne więzienie SSH**: Monitorowanie prób nieautoryzowanego dostępu w czasie rzeczywistym (`mode = aggressive`).
- **Automatyczny Ban**: Po 4 nieudanych próbach logowania w oknie 10 minut adres IP agresora zostaje zablokowany na poziomie zapory sieciowej na okres **1 godziny** (`bantime = 1h`).

### D. Zapora Ogniowa UFW (Stateful Firewall & Rate Limiting)
- **Polityka domyślna**: Całkowita blokada ruchu przychodzącego (`default deny incoming`) oraz zezwolenie na ruch wychodzący (`default allow outgoing`).
- **SSH Rate Limiting**: Reguła `ufw limit 22/tcp` odrzuca połączenia od hostów, które próbują zainicjować 6 lub więcej połączeń w ciągu 30 sekund.
- **Brak otwartych portów webowych**: W modelu Cloudflare Zero Trust porty 80 i 443 pozostają **zamknięte** na zaporze serwera.

### E. Ochrona na Poziomie Jądra i Sieci (Kernel Sysctl Hardening)
- **Ochrona przed SYN Flood DoS**: `net.ipv4.tcp_syncookies = 1` chroni przed przepełnieniem tablicy połączeń TCP fałszywymi pakietami SYN.
- **Anti-Spoofing (RP Filter)**: `net.ipv4.conf.all.rp_filter = 1` weryfikuje trasę powrotną pakietów, odrzucając pakiety z podrobionym adresem źródłowym (IP Spoofing).
- **Blokada ataków MITM (ICMP Redirects)**: Wyłączenie akceptowania i wysyłania przekierowań ICMP (`accept_redirects = 0`).
- **Ochrona przed atakiem Smurf**: `icmp_echo_ignore_broadcasts = 1` ignoruje zapytania ICMP wysyłane na adresy rozgłoszeniowe.

### F. Zabezpieczenie Pamięci Współdzielonej (`/dev/shm`)
- Montowanie pamięci `/dev/shm` z flagami `noexec,nosuid,nodev` w `/etc/fstab` uniemożliwia uruchamianie złośliwych skryptów i binariów w pamięci podręcznej.

### G. Izolacja Usług i Konteneryzacja (Docker Hardening)
- **Binding wyłącznie do localhosta**: Porty usług nasłuchują na `127.0.0.1`, a nie `0.0.0.0` (brak omijania UFW przez iptables Dockera).
- **PoLP (Zasada Najmniejszych Przywilejów)**:
  - Prometheus działa jako użytkownik `nobody` (UID `65534`).
  - Grafana działa jako użytkownik `grafana` (UID `472`).
- **Flaga bezpieczeństwa**: `security_opt: [no-new-privileges:true]` uniemożliwia eskalację uprawnień z wnętrza kontenera.
- **Pliki konfiguracyjne w trybie tylko do odczytu**: `prometheus.yml` i `provisioning/` montowane z uprawnieniem `:ro`.
- **Prewencja zapełnienia dysku**: Rotacja logów kontenerów w `/etc/docker/daemon.json` (`max-size: 10m`, `max-file: 3`).

---

## 3. Struktura Projektu

```text
.
├── .github/
│   ├── ISSUE_TEMPLATE/            # Szablony incydentów i zadań infrastrukturalnych
│   ├── pull_request_template.md   # Quality Gate checklist dla zmian infra
│   ├── dependabot.yml             # Comiesięczny nadzór nad wersjami akcji i obrazów Docker
│   └── workflows/
│       ├── lint-compose.yml       # Quality Gate: walidacja Compose, składni skryptów i higieny
│       └── deploy.yml             # Automatyczny deploy po SSH na serwer produkcyjny
├── .githooks/
│   ├── pre-commit                 # Git hook blokujący wycieki sekretów (.env, *.pem, *.key)
│   └── commit-msg                 # Git hook wymuszający format Conventional Commits
├── compose/
│   ├── docker-compose.yml         # Stos: Prometheus, Grafana, Kuma, Node Exporter, cAdvisor, Dozzle, AI Router, GitHub Exporter
│   ├── extensions.yml             # Tunel Cloudflare Zero Trust (cloudflared)
│   └── runners.yml                # Zunifikowane runnery GitHub Actions (ARM64: zeslownikiem & TwojaStronaWWW)
├── config/
│   ├── prometheus/
│   │   ├── prometheus.yml         # Scrape: Kuma, Node Exporter, cAdvisor, GitHub Exporter, AI Router (/metrics)
│   │   └── rules/
│   │       └── ai-router.yml      # 8 reguł alertów Prometheusa dla kaskady i limitów AI Routera
│   └── grafana/
│       └── provisioning/
│           ├── datasources/       # Automatyczne podpinanie Prometheus API (uid: prometheus)
│           └── dashboards/        # 2 pulpity: Centrum Monitoringu Stron WWW & Usług + AI Router (25 paneli)
├── docs/
│   ├── AI_ROUTER_RAPORT.md        # Dokumentacja telemetrii, metryk i raportowania AI Routera
│   └── CLOUDFLARE_STAGING_GUIDE.md# Poradnik testowania stagingu bez publicznych subdomen
├── scripts/
│   ├── 01-harden-os.sh            # Skrypt pełnego hardeningu systemu Ubuntu (ISO 27001) + auto-SWAP
│   ├── 02-install-docker.sh       # Instalacja Docker CE i Compose v2 z optymalizacją pod VPS
│   ├── ai-router-report.sh/.ps1   # Narzędzia CLI do generowania raportów skuteczności i kosztów AI Routera
│   ├── audit-server.sh            # Skrypt audytu bezpieczeństwa i stanu żywego serwera VPS
│   ├── backup-offsite.sh          # Automatyczny backup do chmury (S3/R2/Oracle) z alertami Ntfy
│   ├── backup-volumes.sh          # Bezpieczny lokalny backup wolumenów :ro z retencją 7 dni
│   ├── backup-websites-lh.sh      # Automatyczny backup serwisów WWW z hostingu LH.pl z telemetrią Prometheus
│   ├── open-dashboard.ps1/.cmd    # Błyskawiczny launcher 1-klik (cichy tunel SSH + otwarcie przeglądarki)
│   ├── preview-tunnel.ps1/.sh     # Quick Tunnel – natychmiastowy szyfrowany link HTTPS dla stagingu
│   ├── setup-kuma.js              # Idempotentna rejestracja monitorowanych witryn i AI Routera w Uptime Kuma
│   ├── setup-ntfy.js              # Konfiguracja kanału powiadomień Ntfy
│   └── runners/                   # Skrypty sterowania runnerami CI/CD
├── services/
│   └── ai-router/                 # Scentralizowany mikro-router AI (PHP 8.3 Alpine, Multi-Provider RAG, Zero-Bloat)
│       ├── Dockerfile             # Izolowany kontener non-root, minimalny footprint (~11-15 MB RAM, 4 workery PHP)
│       ├── src/
│       │   ├── chat-router.php    # Obsługa POST, CORS whitelist, IP limiter, 7-modelowa kaskada LLM, /health, /metrics
│       │   └── ai-stats.php       # Moduł telemetrii Prometheus i inteligentnego Cooldownu modeli (LOCK_EX, zero PII)
│       ├── data/                  # Bazy wiedzy RAG montowane :ro (fuegolingua-knowledge.txt, katosalsahub-knowledge.txt, twojastronawww-knowledge.txt)
│       ├── storage/               # Trwały wolumen na pliki rate-limit per IP oraz ai_stats.json
│       └── public-test/           # Tester frontendu (Vanilla HTML + JS + CSS)
├── tests/
│   └── unit/
│       └── repo-hygiene.test.js   # 22 natywne testy higieny repozytorium i telemetrii AI (node:test)
├── AGENTS.md / GEMINI.md          # Wytyczne architektoniczne dla modeli AI i rygor Always Free
├── DISASTER_RECOVERY.md           # Procedura odtworzenia środowiska z kopii w < 15 minut
├── README.md                      # Główna dokumentacja architektury i bezpieczeństwa
├── SECURITY.md                    # Polityka bezpieczeństwa ISO 27001 i Responsible Disclosure
├── LICENSE                        # Licencja TwojaStronaWWW
├── .editorconfig                  # Standard kodowania LF, UTF-8 i wcięć
├── .gitattributes                 # Wymuszenie zakończeń linii LF (ochrona przed CRLF)
├── .gitignore                     # Rygor ISO 27001: wykluczenie kluczy, certyfikatów, haseł i .env
└── package.json                   # Skrypty jakościowe (npm test, npm run check)
```

---

## 4. Testowanie Stron przed Wdrożeniem (Bez Subdomen `test.*`)

Dzięki wdrożeniu tuneli Cloudflare możesz **całkowicie skasować subdomeny `test.nazwastrony.pl` w swoim panelu DNS**:

1. **Podgląd natychmiastowy (Ad-Hoc Preview)**:
   ```bash
   # W Windows (PowerShell):
   pwsh scripts/preview-tunnel.ps1 -Target "http://localhost:3000"

   # W Linuksie / WSL2:
   ./scripts/preview-tunnel.sh http://localhost:3000
   ```
   Generuje tymczasowy, szyfrowany adres HTTPS (np. `https://random-word.trycloudflare.com`). Zero wpisów w DNS, po `Ctrl+C` tunel znika.

2. **Stały Staging z Kontrolą Dostępu**:
   Szczegółowa konfiguracja routingu wewnętrznego i polityki Cloudflare Zero Trust (autoryzacja kodem PIN na e-mail) znajduje się w przewodniku [`docs/CLOUDFLARE_STAGING_GUIDE.md`](file:///e:/Projekty/VPS/docs/CLOUDFLARE_STAGING_GUIDE.md).

---

## 5. Obsługa Runnerów GitHub Actions (Zunifikowane Runnery Organizacji)

Zamiast utrzymywać osobne instancje runnerów dla każdego repozytorium, wdrożono **Dwa Zunifikowane Runnery Organizacji** działające w kontenerach Docker na architekturze ARM64:

1. **`runner-zeslownikiem-unified`** (Organizacja: `zeslownikiem`):
   - Automatycznie obsługuje: `gal-anonym` (Desktop), `gal-anonim-web` (Web) oraz każde nowe repozytorium w organizacji.
   - Etykiety: `self-hosted,linux,arm64,ARM64,vps,unified`.
2. **`runner-twojastronawww-unified`** (Organizacja: `TwojaStronaWWW`):
   - Automatycznie obsługuje: `devops-stack`, `twojastronawww`, `katosalsahub`, `raricart`, `hd-osticket-helpdesk` oraz wszystkie szablony witryn `_site-template`.
   - Etykiety: `self-hosted,linux,arm64,ARM64,vps,unified,twojastronawww`.

### Uruchomienie runnerów na serwerze produkcyjnym (VPS):
```bash
cd /opt/devops-stack/compose
# Start obu zunifikowanych runnerów w tle:
docker compose -f runners.yml up -d runner-unified runner-twojastronawww
```

---

## 6. Prowizjonowanie i Szybki Start na Serwerze VPS (Oracle Cloud Ubuntu)

### A. Automatyczne Utworzenie Maszyny ARM w Oracle Cloud (Instance Hunter)
W przypadku popularnych regionów (np. Paryż `eu-paris-1`), darmowe procesory ARM Ampere A1 (`VM.Standard.A1.Flex` - 4 OCPU, 24 GB RAM) bywają tymczasowo wyczerpane (*"Out of host capacity"*).

Do automatycznego „upolowania” maszyny służy skrypt [`scripts/oracle-arm-hunter.sh`](file:///e:/Projekty/VPS/scripts/oracle-arm-hunter.sh):
1. **Konfiguracja OCI CLI w WSL2**:
   ```bash
   # Instalacja narzędzia
   bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults
   exec -l $SHELL
   ```
2. **Automatyczne wykrycie identyfikatorów konta**:
   ```bash
   ./scripts/oracle-arm-hunter.sh --discover
   ```
3. **Uruchomienie łowcy w tle (z powiadomieniami Ntfy na telefon)**:
   ```bash
   nohup ./scripts/oracle-arm-hunter.sh > oracle-hunter.log 2>&1 &
   # Podgląd polowania:
   tail -f oracle-hunter.log
   ```

---

### B. Konfiguracja Nowego Serwera po Utworzeniu (Oracle VPS)

1. **Połączenie SSH z serwerem**:
   ```bash
   ssh -i ~/.ssh/id_ed25519 ubuntu@89.168.62.31
   ```

2. **Klonowanie repozytorium do katalogu docelowego**:
   ```bash
   sudo git clone https://github.com/TwojaStronaWWW/devops-stack.git /opt/devops-stack
   sudo chown -R ubuntu:ubuntu /opt/devops-stack
   cd /opt/devops-stack
   ```

3. **Wykonanie hardeningu systemu i instalacja silnika Dockera**:
   ```bash
   sudo bash scripts/01-harden-os.sh
   sudo bash scripts/02-install-docker.sh
   # Przeładuj grupę docker:
   newgrp docker
   ```

4. **Konfiguracja zmiennych środowiskowych i poświadczeń**:
   ```bash
   cp .env.example .env
   nano .env
   ```
   *Uzupełnij: `CLOUDFLARE_TUNNEL_TOKEN`, `RUNNER_ORG_TOKEN`, `GITHUB_TOKEN` oraz hasła do Grafany i Uptime Kuma.*
   
   Utwórz zabezpieczony plik poświadczeń dla scrapera Prometheusa (UID 65534):
   ```bash
   echo -n "TwojeHasloKuma" > config/prometheus/kuma_password
   sudo chown 65534:ubuntu config/prometheus/kuma_password
   sudo chmod 640 config/prometheus/kuma_password
   ```

5. **Uruchomienie pełnego stosu produkcyjnego wraz z runnerem**:
   ```bash
   cd compose
   # 1. Start głównego monitoringu:
   docker compose up -d

   # 2. Start rozszerzeń (Cloudflare Tunnel) oraz Zunifikowanego Runnera GitHub Actions:
   docker compose -f docker-compose.yml -f extensions.yml -f runners.yml up -d
   ```

6. **Weryfikacja stanu usług**:
   ```bash
   docker compose -f docker-compose.yml -f extensions.yml -f runners.yml ps
   docker logs -f runner-zeslownikiem-unified
   ```

---

## 7. Błyskawiczny Dostęp 1-Klik z Pulpitu (Windows Workstation)

Aby wyeliminować konieczność manualnego otwierania terminala, zestawiania tuneli SSH i żmudnego logowania się do każdego z paneli, wdrożono zautomatyzowany mechanizm **1-Klik**:

- **Lokalizacja skryptu**: [`scripts/open-dashboard.ps1`](file:///e:/Projekty/VPS/scripts/open-dashboard.ps1) / [`scripts/open-dashboard.cmd`](file:///e:/Projekty/VPS/scripts/open-dashboard.cmd)
- **Skrót na pulpicie Windows**: `DevOps Monitoring.cmd`

### Jak działa mechanizm:
1. Sprawdza, czy porty lokalne (3000, 3001, 8888, 9090) są już aktywne.
2. Jeśli tunel nie działa, cicho uruchamia proces SSH w tle z asymetrycznym kluczem `id_ed25519`:
   ```bash
   ssh -N -L 3000:127.0.0.1:3000 -L 3001:127.0.0.1:3001 -L 8888:127.0.0.1:8888 -L 9090:127.0.0.1:9090 ubuntu@89.168.62.31
   ```
3. Po ustabilizowaniu portów (do 15 s) automatycznie otwiera domyślną przeglądarkę z gotowymi kartami:
   - **Grafana** (`http://127.0.0.1:3000`): Działa z natywnym autologowaniem Anonymous Admin (`GF_AUTH_ANONYMOUS_ENABLED=true`), od razu prezentując pulpit operacyjny z metrykami hosta, Uptime Kuma i CI/CD GitHub Actions.
   - **Uptime Kuma** (`http://127.0.0.1:3001`): Panel statusu usług zewnętrznych.
   - **Dozzle** (`http://127.0.0.1:8888`): Podgląd logów kontenerów w czasie rzeczywistym.

---

## 8. Model Bezpieczeństwa Publicznego Repozytorium (ISO 27001 & Zero Trust)

> **Często Zadawane Pytanie Bezpieczeństwa:**  
> *„Jeśli to repozytorium jest publiczne na GitHubie, czy ktokolwiek z internetu może sklonować kod i uzyskać dostęp do serwera, kontenerów lub monitorowanych usług?”*

### Odpowiedź: KATEGORYCZNIE NIE.

Infrastruktura została zaprojektowana w oparciu o wojskowy rygor **Defense-in-Depth (Obrona w głąb)** oraz normę **ISO 27001**. Posiadanie kodu źródłowego repozytorium **nie daje atakującemu żadnej ścieżki wejścia** na serwer.

### Wielowarstwowe Mechanizmy Ochrony:

| Warstwa Bezpieczeństwa | Mechanizm Obronny | Skutek dla Atakującego z Internetu |
|---|---|---|
| **1. Sieciowa (WAN)** | Wszystkie porty aplikacji (3000, 3001, 8888, 9090) są powiązane wyłącznie z `127.0.0.1` (loopback). Brak mapowania na `0.0.0.0`. | Porty aplikacji są **niewidoczne i nieosiągalne** z internetu. Skany Nmap wskazują porty jako zamknięte/odfiltrowane. |
| **2. Firewall (UFW & OCI)** | Porty 80 i 443 oraz wszystkie porty aplikacji są zablokowane na zaporze UFW i listach OCI Security Lists. | Nawet celowe zapytania pod publiczny adres IP `89.168.62.31` są natychmiast odrzucane na poziomie jądra (`DROP`). |
| **3. Tożsamość & SSH** | Port 22 ma wyłączone uwierzytelnianie hasłem (`PasswordAuthentication no`) oraz zablokowane konto roota (`PermitRootLogin no`). | Zgadnięcie lub złamanie hasła jest niemożliwe. Wejście wymaga prywatnego klucza `id_ed25519`, który znajduje się wyłącznie na Twoim fizycznym dysku i **nigdy nie trafił do Git**. |
| **4. Ochrona Brute-Force** | UFW rate-limiting (`limit 22/tcp`) + Fail2ban IPS (`mode = aggressive`, `bantime = 1h`). | Automatyczny ban na poziomie zapory ogniowej po 4 nieudanych próbach połączenia SSH. |
| **5. Higiena Sekretów** | Rygor `.gitignore` wyklucza pliki `.env`, klucze `*.pem`, `*.key`, `id_*`, certyfikaty oraz pliki haseł `kuma_password`. | W publicznym repozytorium znajdują się **wyłącznie zanonimizowane szablony** (`.env.example`). Zero realnych tokenów w historii gita. |
| **6. Git Hooks (Pre-commit)** | Skrypt `.githooks/pre-commit` skanuje każdy commit i blokuje wysłanie plików o wrażliwych rozszerzeniach. | Ochrona przed przypadkowym wysłaniem klucza lub hasła przez administratora. |
| **7. Uprawnienia Usług (PoLP)** | Usługi działają w kontenerach z `no-new-privileges:true` na dedykowanych użytkownikach (`nobody:65534`, `grafana:472`). | Nawet w hipotetycznym scenariuszu luki w oprogramowaniu eskalacja uprawnień do roota hosta jest zablokowana. |

---

## 9. Architektura Kopii Zapasowych & Disaster Recovery (ISO 27001)

Serwer VPS pełni funkcję **Centralnego Sejfu i Węzła Disaster Recovery** dla całej infrastruktury TwojaStronaWWW:

### A. Backup Wolumenów Monitoringu (`scripts/backup-offsite.sh`):
- Tworzy spójne snapshoty wolumenów `uptime_kuma_data`, `grafana_data` oraz `prometheus_data` montowanych w trybie tylko do odczytu (`:ro`).
- Pakuje wolumeny do archiwum zbiorczego `vps_full_backup_YYYYMMDD_HHMMSS.tar.gz`.
- Rotacja: automatyczne usuwanie lokalnych kopii starszych niż **14 dni**.
- Offsite Sync: jeśli w `.env` skonfigurowano klucze chmurowe (`S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`), paczka jest natychmiast przesyłana do Cloudflare R2 / S3.

### B. Backup Stron WWW z Hostingu LH.pl (`scripts/backup-websites-lh.sh`):
- Łączy się ze zdalnym hostingiem LH.pl przez bezpieczny protokół FTP/SFTP (dane z GitHub Secrets / `.env`).
- Pobiera strukturę plików witryn (`public_html`) za pomocą izolowanego kontenera `lftp`/`rclone`.
- Tworzy archiwum `lh_websites_backup_YYYYMMDD_HHMMSS.tar.gz` i rotuje kopie z retencją 14 dni.
- Opcjonalnie przesyła kopię do Cloudflare R2 (`${S3_BUCKET}/websites/`).

### C. Automatyzacja Harmonogramu (Systemd Timer):
Zadania backupu są zautomatyzowane przez usługę i timer jądra Linuksa:
- **Timer:** `devops-backup.timer`
- **Częstotliwość:** Codziennie o **03:00 UTC** (05:00 rano czasu polskiego).
- **Weryfikacja:** `systemctl list-timers devops-backup.timer`

### D. Telemetria i Wskaźniki w Grafanie:
Każdy przebieg skryptu backupu generuje metryki w standardzie Prometheus Textfile Collector (`config/node-exporter/*.prom`).
Na głównym pulpicie w Grafanie sekcja **Kopie Zapasowe i Odporność na Awarie** prezentuje w czasie rzeczywistym:
- **Status Ostatniego Backupu Wolumenów i Stron LH** (Zielony "SUKCES" / Czerwony "BŁĄD").
- **Czas od Ostatniego Backupu** (dynamiczny licznik czasu, alarm > 24h).
- **Wielkość Archiwów** (w MB/GB).
- **Status Wysyłki Offsite do Chmury (Cloudflare R2 / S3)**.

---

## 10. Strategia Zarządzania Poświadczeniami i Sekretami (KeePass & GitHub Secrets)

W celu zapewnienia bezwzględnej zgodności z normą **ISO 27001** oraz uniknięcia jakichkolwiek wycieków poświadczeń, wdrożono **Dwuwarstwowy Model Zarządzania Sekretami**:

1. **Warstwa Główna: Baza KeePass Password Safe (`Databasekpoczatek.kdbx`):**
   - Wszystkie poświadczenia produkcyjne są scentralizowane w zaszyfrowanej bazie KeePass w dedykowanej grupie **`VPS - TwojaStronaWWW`**.
   - Obejmuje: hasła administracyjne Grafana, Uptime Kuma, dane klucza SSH Ed25519, tokeny Cloudflare Zero Trust, tokeny rejestracyjne runnerów CI/CD oraz **3 klucze API dla AI Routera (`GEMINI_API_KEY`, `GROQ_API_KEY`, `OPENROUTER_API_KEY`)**.
   - Wszystkie hasła generowane są z zachowaniem rygoru kryptograficznego (min. 32 znaki, wysoka entropia, brak słów słownikowych).

2. **Warstwa Automatyzacji: GitHub Actions Secrets:**
   - Wszystkie zmienne używane w potokach wdrożeniowych (np. `.github/workflows/deploy.yml` oraz potoki serwisów WWW na hostingu LH.pl) są zdefiniowane w GitHub Secrets:
     - `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY`, `VPS_SSH_PORT` (wdrożenie stacku na serwerze).
     - `FTP_SERVER`, `FTP_USERNAME`, `FTP_PASSWORD`, `FTP_PORT` (wdrożenia stron na hostingu LH.pl).
   - Żadne hasło ani klucz prywatny nigdy nie są zapisywane w kodzie repozytorium.

3. **Warstwa Hosta VPS: Izolowany Plik `.env`:**
   - Na serwerze VPS zmienne środowiskowe znajdują się w pliku `/opt/devops-stack/.env` zabezpieczonym uprawnieniem `chmod 600` (dostępnym wyłącznie dla użytkownika `ubuntu`).
   - Plik ten jest trwale wykluczony z systemu kontroli wersji przez `.gitignore`.

---

## 11. Centralna Bramka AI & Multi-Provider RAG Router (`services/ai-router`)

Serwer VPS udostępnia scentralizowany mikro-router AI ([`services/ai-router/src/chat-router.php`](file:///e:/Projekty/VPS/services/ai-router/src/chat-router.php)) obsługujący asystentów czatowych dla witryn platformy (**Fuego Lingua**, **Kato Salsa Hub**, **TwojaStronaWWW** oraz nowych wdrożeń z szablonu **`_site-template`**) pod adresem `https://ai.twojastronawww.pl/chat-router.php`.

### A. Klasyfikacja Rozwiązania i Zerowy Narzut Zasobów
- **Obszar 3 (AI z bazą wiedzy firmy RAG) + Enterprise High-Availability:** Dynamiczny dobór bazy wiedzy po parametrze `site_id` (`services/ai-router/data/<site_id>-knowledge.txt` montowane w trybie `:ro`), pamięć konwersacji Multi-Turn (`history` do 10 wiadomości) oraz twarde reguły anty-halucynacyjne (Guardrails).
- **0 MB wag modeli na serwerze VPS:** Wszystkie 7 modeli LLM działa w chmurze zewnętrznych dostawców (komunikacja przez HTTPS cURL). Sam kontener `ai-router` (PHP 8.3 Alpine, `PHP_CLI_SERVER_WORKERS=4`) zużywa jedynie **~11–15 MiB RAM** oraz **0,00 PLN / mies.** kosztów utrzymania.

### B. 3-Dostawczowa Kaskada Odporności na Awarie (7 Modeli LLM) + Cooldown
Router posiada skonfigurowane **3 niezależne klucze API** i automatycznie przełącza zapytanie do kolejnego modelu w ułamku sekundy w razie błędu `429 Rate Limit`, `503 Overload` lub przekroczenia czasu:

| Pozycja w kaskadzie | Dostawca (Zmienna Klucza) | Model LLM | Rola w architekturze |
|---|---|---|---|
| **1 (Primary)** | Google AI Studio (`GEMINI_API_KEY`) | `gemini-2.5-flash` | Główny szybki model produkcyjny |
| **2 (Fallback 1)** | Google AI Studio (`GEMINI_API_KEY`) | `gemini-2.5-flash-lite` | Ultralekki model o podwyższonym limicie RPD |
| **3 (Fallback 2)** | Google AI Studio (`GEMINI_API_KEY`) | `gemini-3-flash-preview` | Nowa generacja Gemini Flash (osobna pula limitów) |
| **4 (Fallback 3)** | Google AI Studio (`GEMINI_API_KEY`) | `gemini-2.5-pro` | Zaawansowany model rozumowania |
| **5 (Fallback 4)** | Google AI Studio (`GEMINI_API_KEY`) | `gemma-3-27b-it` | Otwarty model Google (wysoka pula darmowych zapytań) |
| **6 (Fallback 5)** | Groq Cloud (`GROQ_API_KEY`) | `openai/gpt-oss-120b` | Zewnętrzny ultra-szybki fallback (~1 s na układach LPU) |
| **7 (Fallback 6)** | OpenRouter (`OPENROUTER_API_KEY`) | `nvidia/nemotron-3-super-120b-a12b:free` | Niezależny zapasowy klaster chmurowy (Free Tier) |

- **Inteligentny Cooldown Modeli ([`ai-stats.php`](file:///e:/Projekty/VPS/services/ai-router/src/ai-stats.php)):** Gdy dowolny model zwróci błąd limitu (`429`), przeciążenia (`503`) lub timeout, otrzymuje tymczasowy cooldown. Kolejne zapytania klientów natychmiast omijają go w `0 ms`, trafiając od razu do sprawnego modelu.

### C. Pełna Obserwowalność, Alerting i Raportowanie CLI (ISO 27001 Zero-PII)
1. **Endpoint Prometheus (`GET /metrics`):** Eksportuje metryki zapytań, skuteczności kaskady, prób per model, aktywnych cooldownów, zużycia tokenów, estymacji kosztów USD oraz histogramu latencji (`p50`/`p95`). Zgodnie z **ISO 27001** moduł [`ai-stats.php`](file:///e:/Projekty/VPS/services/ai-router/src/ai-stats.php) **nigdy nie loguje treści pytań klientów, adresów IP ani kluczy API**.
2. **Dashboard Grafany (`uid: ai-router-overview`):** 25-panelowy pulpit **AI Router - Gemini Proxy Monitor** ([`ai-router-overview.json`](file:///e:/Projekty/VPS/config/grafana/provisioning/dashboards/definitions/ai-router-overview.json)) prezentujący ruch i zdrowie wszystkich 7 modeli per strona (`fuegolingua`, `katosalsahub`, `twojastronawww`).
3. **Reguły Alertów Prometheusa:** Plik [`config/prometheus/rules/ai-router.yml`](file:///e:/Projekty/VPS/config/prometheus/rules/ai-router.yml) monitoruje 8 warunków krytycznych (`AiRouterDown`, `AiRouterHighErrorRate`, `AiRouterNoSuccessfulAnswers`, `AiRouterCascadeFallbackActive`, `AiRouterHighLatencyP95`, `AiRouterRateLimitSpike`, `AiRouterDailyQuotaExhausted`, `AiRouterModelDailyQuotaNearLimit`).
4. **Raporty CLI na żądanie:** Skrypty [`scripts/ai-router-report.sh`](file:///e:/Projekty/VPS/scripts/ai-router-report.sh) oraz [`scripts/ai-router-report.ps1`](file:///e:/Projekty/VPS/scripts/ai-router-report.ps1) (szczegóły w [`docs/AI_ROUTER_RAPORT.md`](file:///e:/Projekty/VPS/docs/AI_ROUTER_RAPORT.md)).



