# DevOps Stack & Zero-Bloat Monitoring

> **Infrastruktura DevOps**: Od środowiska lokalnego (WSL2: Ubuntu / Kali / Oracle Linux) do Oracle Cloud (ARM64 Ampere / AMD64) zgodna z normą **ISO 27001**, wytycznymi **CIS Benchmark**, zasadą **PoLP** (Principle of Least Privilege) i architekturą **Zero Trust**.

---

## 1. Architektura Systemu

```text
[ Internet / Zewnętrzni Użytkownicy & Witryny Klienckie (FuegoLingua, KatoSalsaHub, TwojaStronaWWW) ]
              │
              ▼ (Tunel szyfrowany TLS / QUIC - Porty zaporowe 80/443 pozostają ZAMKNIĘTE)
[ Cloudflare Zero Trust (cloudflared: ai.twojastronawww.pl & monitoring.twojastronawww.pl) ]
              │
              ▼
 ┌────────────────────────────────────────────────────────────────────────┐
 │                    HOST VPS (Oracle Ampere ARM64)                      │
 │                                                                        │
 │  [ Strefa 1: Sieć wewnętrzna `devops_internal_network` ]               │
 │  ┌─────────────────┐ ┌───────────────┐ ┌────────────────────────────┐  │
 │  │  Uptime Kuma    │ │  Prometheus   │ │  Grafana (Viewer PoLP)     │  │
 │  │  (10 monitorów) │ │  (TSDB 15d)   │ │  (2 Dashboardy & Alerting) │  │
 │  │  127.0.0.1:3001 │ │ 127.0.0.1:9090│ │  127.0.0.1:3000           │  │
 │  └────────┬────────┘ └───────▲───────┘ └─────────────┬──────────────┘  │
 │           │                  │                       │                 │
 │           └────── metrics ───┤                       │                 │
 │                              │                       │                 │
 │  ┌─────────────────┐         │                       │                 │
 │  │  AI Router RAG  ├─────────┤ (/metrics & /health)  │                 │
 │  │  (Cache <5ms +  │         │                       │                 │
 │  │   7-Model Casc) │         │                       │                 │
 │  │  127.0.0.1:8085 │         │                       │                 │
 │  └─────────────────┘         │                       │                 │
 │  ┌─────────────────┐         │                       │                 │
 │  │  Node Exporter  ├─────────┤ (*.prom: backup/audit)│                 │
 │  └─────────────────┘         │                       │                 │
 │  ┌─────────────────┐         │                       │                 │
 │  │  cAdvisor       ├─────────┤ (Docker stats)        │                 │
 │  └─────────────────┘         │                       │                 │
 │  ┌─────────────────┐         │                       │                 │
 │  │ GitHub Exporter ├─────────┘ (CI/CD Actions)       │                 │
 │  └─────────────────┘         ┌───────────────────────┴──────────────┐  │
 │                              │ Dozzle: Logi Kontenerów w Przeglądarce│  │
 │                              │ 127.0.0.1:8888                       │  │
 │                              └──────────────────────────────────────┘  │
 │                                                                        │
 │  [ Strefa 2: Odseparowana sieć CI/CD `devops_runners_network` ]        │
 │  ┌──────────────────────────────────────────────────────────────────┐  │
 │  │  3 Runnery GitHub Actions ARM64 (brak dostępu L3 do monitoringu) │  │
 │  │  • runner-zeslownikiem-unified  • runner-twojastronawww-unified  │  │
 │  │  • runner-gal-anonim-web                                         │  │
 │  └──────────────────────────────────────────────────────────────────┘  │
 │                                                                        │
 │  Trwałe wolumeny, Autonomiczny Strażnik 24/7 & Kopia Offsite:          │
 │  ├── devops-audit.timer (co 15 min) ──> audit.prom + Alerty Ntfy.sh    │
 │  ├── devops-backup.timer (03:00 UTC) ──> tar -tzf + AES-256 ──> R2/S3  │
 │  └── backup-websites-lh.sh (FTPS TLS + mysqldump) ──> Cloudflare R2    │
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

### G. Izolacja Usług i Konteneryzacja (Docker Hardening & Network Segmentation)
- **Binding wyłącznie do localhosta**: Porty usług nasłuchują na `127.0.0.1`, a nie `0.0.0.0` (brak omijania UFW przez iptables Dockera).
- **Separacja sieciowa Runnerów CI/CD**: Runnery GitHub Actions działają w odizolowanej sieci `devops_runners_network`, nie mając dostępu sieciowego do wewnętrznej sieci `devops_internal_network`.
- **PoLP (Zasada Najmniejszych Przywilejów)**:
  - Prometheus działa jako użytkownik `nobody` (UID `65534`).
  - Grafana działa jako użytkownik `grafana` (UID `472`) z domyślną rolą `Viewer` dla dostępu bez logowania przez tunel SSH (`GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer`).
  - AI Router działa jako użytkownik `nobody` z 4 workerami PHP (`PHP_CLI_SERVER_WORKERS=4`).
- **Flaga bezpieczeństwa**: `security_opt: [no-new-privileges:true]` uniemożliwia eskalację uprawnień z wnętrza kontenera.
- **Pliki konfiguracyjne w trybie tylko do odczytu**: `prometheus.yml`, `rules/`, `provisioning/` oraz bazy wiedzy `data/` montowane z uprawnieniem `:ro`.
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
│       └── deploy.yml             # Automatyczny deploy po SSH + flush DNS nscd + audyt powykonawczy
├── .githooks/
│   ├── pre-commit                 # Git hook blokujący wycieki sekretów (.env, .env.bak*, *.pem, *.key)
│   └── commit-msg                 # Git hook wymuszający format Conventional Commits
├── compose/
│   ├── docker-compose.yml         # Stos (devops_internal_network): Prometheus, Grafana, Kuma, Node Exporter, cAdvisor, Dozzle, AI Router, GitHub Exporter
│   ├── extensions.yml             # Tunel Cloudflare Zero Trust (cloudflared)
│   └── runners.yml                # Runnery GitHub Actions ARM64 w odseparowanej sieci (devops_runners_network)
├── config/
│   ├── prometheus/
│   │   ├── prometheus.yml         # Scrape: Kuma, Node Exporter, cAdvisor, GitHub Exporter, AI Router (/metrics)
│   │   └── rules/
│   │       └── ai-router.yml      # Reguły alertów Prometheusa dla kaskady i limitów AI Routera
│   └── grafana/
│       └── provisioning/
│           ├── datasources/       # Automatyczne podpinanie Prometheus API (uid: prometheus)
│           └── dashboards/        # 2 pulpity: Centrum Monitoringu Stron WWW & Usług + AI Router (Gemini Proxy Monitor)
├── docs/
│   ├── AI_ROUTER_RAPORT.md        # Dokumentacja telemetrii, metryk, cache'u RAG i raportowania AI Routera
│   └── CLOUDFLARE_STAGING_GUIDE.md# Poradnik testowania stagingu bez publicznych subdomen
├── scripts/
│   ├── 01-harden-os.sh            # Skrypt pełnego hardeningu systemu Ubuntu (ISO 27001) + auto-SWAP
│   ├── 02-install-docker.sh       # Instalacja Docker CE i Compose v2 z optymalizacją pod VPS
│   ├── ai-router-report.sh/.ps1   # Narzędzia CLI do generowania raportów skuteczności, cache'u i kaskady AI Routera
│   ├── audit-server.sh            # 5-warstwowy audyt żywego serwera VPS + samonaprawa nscd + alerty Ntfy
│   ├── backup-offsite.sh          # Snapshot wolumenów (weryfikacja tar -tzf + AES-256) do chmury R2/S3 z alertami Ntfy
│   ├── backup-volumes.sh          # Bezpieczny lokalny backup wolumenów :ro z retencją 7 dni
│   ├── backup-websites-lh.sh      # Backup serwisów WWW z hostingu LH.pl (FTPS TLS + mysqldump + tar -tzf + AES-256)
│   ├── open-dashboard.ps1/.cmd    # Błyskawiczny launcher 1-klik (cichy tunel SSH + otwarcie przeglądarki)
│   ├── preview-tunnel.ps1/.sh     # Quick Tunnel – natychmiastowy szyfrowany link HTTPS dla stagingu
│   ├── setup-audit-timer.sh       # Idempotentna instalacja strażnika systemd 24/7 (devops-audit.timer co 15 min)
│   ├── setup-kuma.js              # Idempotentna rejestracja 10 monitorowanych witryn i AI Routera w Uptime Kuma
│   ├── setup-ntfy.js              # Konfiguracja kanału powiadomień Ntfy
│   ├── verify-remote.ps1/.cmd     # Zdalny wyzwalacz audytu VPS z poziomu Windows (npm run audit)
│   └── runners/                   # Skrypty sterowania runnerami CI/CD
├── services/
│   └── ai-router/                 # Scentralizowany mikro-router AI (PHP 8.3 Alpine, Multi-Provider RAG, Cache <5ms, Zero-Bloat)
│       ├── Dockerfile             # Izolowany kontener non-root, minimalny footprint (~12 MB RAM, 4 workery PHP)
│       ├── src/
│       │   ├── chat-router.php    # Obsługa POST, CORS whitelist, IP limiter, Cache RAG (<5ms), Detektor Leadów, 7-modelowa kaskada LLM
│       │   └── ai-stats.php       # Moduł telemetrii Prometheus, Cooldownu modeli, domyślnych limitów RPD i wyzerowanych serii błędów
│       ├── data/                  # Bazy wiedzy RAG montowane :ro (fuegolingua-knowledge.txt, katosalsahub-knowledge.txt, twojastronawww-knowledge.txt)
│       ├── storage/               # Trwały wolumen na pliki rate-limit, cache RAG (/app/storage/cache) oraz ai_stats.json
│       └── public-test/           # Tester frontendu (Vanilla HTML + JS + CSS)
├── tests/
│   └── unit/
│       └── repo-hygiene.test.js   # 24 natywne testy higieny repozytorium, telemetrii AI i bezpieczeństwa (node:test)
├── AGENTS.md / GEMINI.md          # Wytyczne architektoniczne dla modeli AI i rygor Always Free
├── DISASTER_RECOVERY.md           # Procedura odtworzenia środowiska z kopii w < 15 minut
├── README.md                      # Główna dokumentacja architektury i bezpieczeństwa
├── SECURITY.md                    # Polityka bezpieczeństwa ISO 27001 i Responsible Disclosure
├── LICENSE                        # Licencja TwojaStronaWWW
├── .editorconfig                  # Standard kodowania LF, UTF-8 i wcięć
├── .gitattributes                 # Wymuszenie zakończeń linii LF (ochrona przed CRLF)
├── .gitignore                     # Rygor ISO 27001: wykluczenie kluczy, certyfikatów, haseł, .env i .env.bak*
└── package.json                   # Skrypty jakościowe (npm test, npm run check, npm run audit)
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

## 5. Obsługa Runnerów GitHub Actions (Odseparowana Sieć `devops_runners_network`)

Runnery CI/CD działają w kontenerach Docker na architekturze ARM64 wewnątrz wydzielonej sieci mostkowej **`devops_runners_network`**, dzięki czemu zadania budowania kodu nie mają dostępu do wewnętrznej sieci usług monitoringu (`devops_internal_network`):

1. **`runner-zeslownikiem-unified`** (Organizacja: `zeslownikiem`):
   - Obsługuje repozytoria organizacji `zeslownikiem` (`gal-anonym` itd.).
   - Etykiety: `self-hosted,linux,arm64,ARM64,vps,unified`.
2. **`runner-twojastronawww-unified`** (Organizacja: `TwojaStronaWWW`):
   - Automatycznie obsługuje: `devops-stack`, `twojastronawww`, `katosalsahub`, `raricart`, `hd-osticket-helpdesk` oraz szablony witryn `_site-template`.
   - Etykiety: `self-hosted,linux,arm64,ARM64,vps,unified,twojastronawww`.
3. **`runner-gal-anonim-web`** (Repozytorium: `zeslownikiem/gal-anonim-web`):
   - Dedykowany runner dla aplikacji webowej `gal-anonim-web`.
   - Etykiety: `self-hosted,linux,arm64,ARM64,vps,unified`.

### Uruchomienie runnerów na serwerze produkcyjnym (VPS):
```bash
cd /opt/devops-stack/compose
docker compose --env-file /opt/devops-stack/.env -f runners.yml up -d
```

---

## 6. Prowizjonowanie i Szybki Start na Serwerze VPS (Oracle Cloud Ubuntu)

### A. Automatyczne Utworzenie Maszyny ARM w Oracle Cloud (Instance Hunter)
W przypadku popularnych regionów (np. Paryż `eu-paris-1`), darmowe procesory ARM Ampere A1 (`VM.Standard.A1.Flex` - 4 OCPU, 24 GB RAM) bywają tymczasowo wyczerpane (*"Out of host capacity"*).

Do automatycznego „upolowania” maszyny służy skrypt [`scripts/oracle-arm-hunter.sh`](file:///e:/Projekty/VPS/scripts/oracle-arm-hunter.sh):
1. **Konfiguracja OCI CLI w WSL2**:
   ```bash
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
   newgrp docker
   ```

4. **Konfiguracja zmiennych środowiskowych i poświadczeń**:
   ```bash
   cp .env.example .env
   chmod 600 .env
   nano .env
   ```
   *Uzupełnij: `CLOUDFLARE_TUNNEL_TOKEN`, `RUNNER_ORG_TOKEN`, `GITHUB_TOKEN`, `GEMINI_API_KEY`, `GROQ_API_KEY`, `OPENROUTER_API_KEY` oraz hasła do Grafany i Uptime Kuma.*
   
   Utwórz zabezpieczony plik poświadczeń dla scrapera Prometheusa (UID 65534):
   ```bash
   echo -n "TwojeHasloKuma" > config/prometheus/kuma_password
   sudo chown 65534:ubuntu config/prometheus/kuma_password
   sudo chmod 640 config/prometheus/kuma_password
   ```

5. **Uruchomienie pełnego stosu produkcyjnego, pre-warming Cache RAG oraz aktywacja strażnika 24/7**:
   ```bash
   cd /opt/devops-stack/compose
   docker compose --env-file /opt/devops-stack/.env -f docker-compose.yml -f extensions.yml -f runners.yml up -d --build
   bash /opt/devops-stack/scripts/warm-ai-cache.sh
   sudo bash /opt/devops-stack/scripts/setup-audit-timer.sh
   ```

6. **Weryfikacja stanu usług (5-warstwowy audyt)**:
   ```bash
   bash /opt/devops-stack/scripts/audit-server.sh
   ```

---

## 7. Błyskawiczny Dostęp 1-Klik z Pulpitu (Windows Workstation)

Aby wyeliminować konieczność manualnego otwierania terminala i zestawiania tuneli SSH, wdrożono zautomatyzowany mechanizm **1-Klik**:

- **Lokalizacja skryptu**: [`scripts/open-dashboard.ps1`](file:///e:/Projekty/VPS/scripts/open-dashboard.ps1) / [`scripts/open-dashboard.cmd`](file:///e:/Projekty/VPS/scripts/open-dashboard.cmd)
- **Zdalny audyt 1 komendą**: `npm run audit` ([`scripts/verify-remote.ps1`](file:///e:/Projekty/VPS/scripts/verify-remote.ps1))

### Jak działa mechanizm:
1. Sprawdza, czy porty lokalne (3000, 3001, 8888, 9090) są już aktywne.
2. Jeśli tunel nie działa, cicho uruchamia proces SSH w tle z asymetrycznym kluczem `id_ed25519`:
   ```bash
   ssh -N -L 3000:127.0.0.1:3000 -L 3001:127.0.0.1:3001 -L 8888:127.0.0.1:8888 -L 9090:127.0.0.1:9090 ubuntu@89.168.62.31
   ```
3. Po ustabilizowaniu portów automatycznie otwiera domyślną przeglądarkę z gotowymi kartami:
   - **Grafana** (`http://127.0.0.1:3000`): Działa w trybie podglądu **Anonymous Viewer (`GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer`)** zgodnie z zasadą PoLP (ISO 27001), chroniąc dashboardy przed przypadkowym usunięciem. Pełna edycja wymaga zalogowania na konto administratora.
   - **Uptime Kuma** (`http://127.0.0.1:3001`): Panel statusu 10 monitorowanych witryn i usług.
   - **Dozzle** (`http://127.0.0.1:8888`): Podgląd logów wszystkich 12 kontenerów w czasie rzeczywistym.

---

## 8. Model Bezpieczeństwa Publicznego Repozytorium (ISO 27001 & Zero Trust)

> **Często Zadawane Pytanie Bezpieczeństwa:**  
> *„Jeśli to repozytorium jest publiczne na GitHubie, czy ktokolwiek z internetu może sklonować kod i uzyskać dostęp do serwera, kontenerów lub monitorowanych usług?”*

### Odpowiedź: KATEGORYCZNIE NIE.

Infrastruktura została zaprojektowana w oparciu o wojskowy rygor **Defense-in-Depth (Obrona w głąb)** oraz normę **ISO 27001**. Posiadanie kodu źródłowego repozytorium **nie daje atakującemu żadnej ścieżki wejścia** na serwer.

### Wielowarstwowe Mechanizmy Ochrony:

| Warstwa Bezpieczeństwa | Mechanizm Obronny | Skutek dla Atakującego z Internetu |
|---|---|---|
| **1. Sieciowa (WAN)** | Wszystkie porty aplikacji (3000, 3001, 8085, 8888, 9090) są powiązane wyłącznie z `127.0.0.1` (loopback). Brak mapowania na `0.0.0.0`. | Porty aplikacji są **niewidoczne i nieosiągalne** z internetu. Skany Nmap wskazują porty jako zamknięte/odfiltrowane. |
| **2. Firewall (UFW & OCI)** | Porty 80 i 443 oraz wszystkie porty aplikacji są zablokowane na zaporze UFW i listach OCI Security Lists. | Nawet celowe zapytania pod publiczny adres IP `89.168.62.31` są natychmiast odrzucane na poziomie jądra (`DROP`). |
| **3. Tożsamość & SSH** | Port 22 ma wyłączone uwierzytelnianie hasłem (`PasswordAuthentication no`) oraz zablokowane konto roota (`PermitRootLogin no`). | Zgadnięcie lub złamanie hasła jest niemożliwe. Wejście wymaga prywatnego klucza `id_ed25519`, który znajduje się wyłącznie na Twoim fizycznym dysku i **nigdy nie trafił do Git**. |
| **4. Ochrona Brute-Force** | UFW rate-limiting (`limit 22/tcp`) + Fail2ban IPS (`mode = aggressive`, `bantime = 1h`). | Automatyczny ban na poziomie zapory ogniowej po 4 nieudanych próbach połączenia SSH. |
| **5. Higiena Sekretów** | Rygor `.gitignore` wyklucza pliki `.env`, `.env.bak*`, klucze `*.pem`, `*.key`, `id_*`, certyfikaty oraz pliki haseł `kuma_password`. | W publicznym repozytorium znajdują się **wyłącznie zanonimizowane szablony** (`.env.example`). Zero realnych tokenów w historii gita. |
| **6. Git Hooks (Pre-commit)** | Skrypt `.githooks/pre-commit` skanuje każdy commit i blokuje wysłanie plików o wrażliwych rozszerzeniach. | Ochrona przed przypadkowym wysłaniem klucza lub hasła przez administratora. |
| **7. Separacja Sieci i PoLP** | Runnery CI/CD są odizolowane w `devops_runners_network`, a usługi działają z `no-new-privileges:true` (`nobody:65534`, `grafana:472`). | Nawet w hipotetycznym scenariuszu kompromitacji zadania CI/CD atakujący nie ma dostępu do wewnętrznej sieci usług ani roota hosta. |

---

## 9. Architektura Kopii Zapasowych, Weryfikacji Integralności i Audytu 24/7 (ISO 27001)

Serwer VPS pełni funkcję **Centralnego Sejfu i Węzła Disaster Recovery** dla całej infrastruktury TwojaStronaWWW:

### A. Backup Wolumenów Monitoringu i AI (`scripts/backup-offsite.sh`):
- Tworzy spójne snapshoty wszystkich 7 wolumenów (`uptime_kuma_data`, `grafana_data`, `prometheus_data`, `ai_router_storage`, `runner_zeslownikiem_data`, `runner_twojastronawww_data`, `runner_gal_anonim_web_data`) montowanych w trybie tylko do odczytu (`:ro`) wraz z weryfikacją baz SQLite (`PRAGMA quick_check`).
- Automatycznie weryfikuje integralność wygenerowanego archiwum (`tar -tzf`) przed dalszym przetwarzaniem i eksportuje metrykę `devops_backup_verified`.
- Opcjonalnie szyfruje archiwum symetrycznie algorytmem **AES-256-CBC (PBKDF2)** (`BACKUP_ENCRYPTION_KEY`) i przesyła do **Cloudflare R2 / S3** z kroczącą retencją **30 dni** (zarówno lokalnie na VPS, jak i w chmurze R2 przez `rclone delete --min-age 30d`).

### B. Backup Stron WWW z Hostingu LH.pl (`scripts/backup-websites-lh.sh`):
- Łączy się ze zdalnym hostingiem LH.pl przez szyfrowany kanał **FTPS TLS** (`ftp:ssl-allow true`, `ftp:ssl-protect-data true`).
- Pobiera strukturę plików witryn (`public_html`) z normalizacją uprawnień (`--no-perms` + `chown`), oraz opcjonalnie wykonuje zrzut bazy MySQL (`mysqldump --single-transaction`).
- Weryfikuje integralność archiwum (`tar -tzf`, metryka `devops_backup_websites_verified`), opcjonalnie szyfruje **AES-256-CBC** i przesyła do Cloudflare R2 (`${S3_BUCKET}/websites/`) z automatyczną rotacją **30 dni** lokalnie oraz w R2.

### C. Automatyzacja Harmonogramów Systemd (Backup & Strażnik 24/7):
- **`devops-backup.timer`**: Uruchamiany codziennie o **03:00 UTC** (05:00 rano czasu polskiego) — wykonuje pełny backup wolumenów i stron LH.pl.
- **`devops-audit.timer`** ([`scripts/setup-audit-timer.sh`](file:///e:/Projekty/VPS/scripts/setup-audit-timer.sh)): Uruchamiany **co 15 minut** — wykonuje 5-warstwowy audyt bezpieczeństwa i zdrowia (`audit-server.sh`), odświeża telemetrię `audit.prom`, wykonuje samonaprawę DNS `nscd` w Uptime Kuma i wysyła natychmiastowy alert Push na telefon (**Ntfy.sh**) w razie jakiejkolwiek awarii lub aktywnego alarmu Prometheusa.

---

## 10. Strategia Zarządzania Poświadczeniami i Sekretami (KeePass & GitHub Secrets)

W celu zapewnienia bezwzględnej zgodności z normą **ISO 27001** oraz uniknięcia jakichkolwiek wycieków poświadczeń, wdrożono **Dwuwarstwowy Model Zarządzania Sekretami**:

1. **Warstwa Główna: Baza KeePass Password Safe (`Databasekpoczatek.kdbx`):**
   - Wszystkie poświadczenia produkcyjne są scentralizowane w zaszyfrowanej bazie KeePass w dedykowanej grupie **`VPS - TwojaStronaWWW`**.
   - Obejmuje: hasła administracyjne Grafana, Uptime Kuma, dane klucza SSH Ed25519, tokeny Cloudflare Zero Trust, klucze Cloudflare R2, dane FTPS LH.pl, tokeny rejestracyjne runnerów CI/CD oraz **6 kluczy API dla AI Routera (`GEMINI_API_KEY`, `GROQ_API_KEY`, `CEREBRAS_API_KEY`, `CF_AI_API_TOKEN`, `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`)**.
2. **Warstwa Automatyzacji: GitHub Actions Secrets:**
   - Zmienne używane w potokach wdrożeniowych (`VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY`, `FTP_*`) są zdefiniowane wyłącznie w GitHub Secrets.
3. **Warstwa Hosta VPS: Izolowany Plik `.env`:**
   - Na serwerze VPS zmienne środowiskowe znajdują się w pliku `/opt/devops-stack/.env` zabezpieczonym uprawnieniem `chmod 600` (właściciel `ubuntu`), trwale wykluczonym przez `.gitignore` (wraz z `.env.bak*`).

---

## 11. Centralna Bramka AI & Multi-Provider RAG Router (`services/ai-router`)

Serwer VPS udostępnia scentralizowany mikro-router AI ([`services/ai-router/src/chat-router.php`](file:///e:/Projekty/VPS/services/ai-router/src/chat-router.php)) obsługujący asystentów czatowych dla witryn platformy (**Fuego Lingua**, **Kato Salsa Hub**, **TwojaStronaWWW**) pod adresem `https://ai.twojastronawww.pl/chat-router.php`.

### A. Klasyfikacja Rozwiązania, Cache RAG (`< 5 ms`), Pre-warming i Detektor Leadów
- **Obszar 3 (AI z bazą wiedzy firmy RAG) + Enterprise High-Availability:** Dynamiczny dobór bazy wiedzy po parametrze `site_id` (`services/ai-router/data/<site_id>-knowledge.txt` montowane w trybie `:ro`), pamięć konwersacji Multi-Turn (`history` do 8 wiadomości) oraz twarde reguły anty-halucynacyjne (Guardrails).
- **Inteligentny Cache odpowiedzi RAG (`~1.8 ms` / `0` tokenów) + Automatyczny Pre-warming (`scripts/warm-ai-cache.sh`):** Powtarzalne pytania o ofertę i cennik są serwowane z atomowej pamięci podręcznej `/app/storage/cache` w niecałe **2 milisekundy**, bez zużywania dziennych limitów API. Klucz cache uwzględnia `filemtime` pliku wiedzy, a skrypt `scripts/warm-ai-cache.sh` automatycznie rozgrzewa przyciski Quick Prompts podczas każdego wdrożenia CI/CD (`deploy.yml`).
- **Ochrona przed ucinaniem zdań i ukrytymi tokenami myślenia (`thoughtsTokenCount` / `reasoning_tokens`):** Router wymusza `maxOutputTokens: 2048`, przekazuje `'thinkingLevel' => 'MINIMAL'` dla `gemini-3.5-*` (lub `'LOW'` dla `gemini-3.7/3.8`), `'reasoning_effort' => 'low'` / `'disable_reasoning' => true` dla Cerebras WSE, `'reasoning' => ['effort' => 'none']` dla OpenRoutera, wykorzystuje domyślnie wyłączone *Extended Thinking* + *Prompt Caching* (`ephemeral` `-90%`) w Claude Haiku 4.5 oraz odrzuca odpowiedzi z `finishReason === 'MAX_TOKENS'` (`length` / `max_tokens`).
- **Detektor „Gorącego Leada” (Zero-PII):** Przy 4. pytaniu klienta w jednej sesji rozmowy (`count($sanitizedHistory) === 6`) router wysyła ciche powiadomienie Push do aplikacji **Ntfy.sh** na telefon właściciela (`event=hot_lead_detected`), sygnalizując zaangażowanego klienta bez ujawniania danych osobowych ani treści rozmowy.
- **0 MB wag modeli na serwerze VPS:** Wszystkie 11 modeli LLM działa w chmurze zewnętrznych dostawców. Sam kontener `ai-router` (PHP 8.3 Alpine, `PHP_CLI_SERVER_WORKERS=4`) zużywa jedynie **~14 MiB RAM** oraz **0,00 PLN / mies.** kosztów utrzymania.

### B. 6-Dostawczowa Kaskada Odporności na Awarie (11 Modeli LLM) + Smart Fast-Fail
Router posiada skonfigurowanych **6 niezależnych kluczy API**, nakłada wydłużony cooldown na przeciążone modele (`600 s` po timeoucie 4s, `180 s` po HTTP `503`) i wykonuje **natychmiastowy Fast-Fail do Groq LPU (`~0.6 s`) / Cerebras WSE (`~0.15 s`)** po pierwszym timeoucie sieciowym lub gdy $\ge 2$ modele Gemini są zawieszone:

| Pozycja w kaskadzie | Dostawca (Zmienna Klucza) | Model LLM | Domyślny Limit RPD (Free Tier) | Rola w architekturze |
|---|---|---|---|---|
| **0 (Primary)** | Google AI Studio (`GEMINI_API_KEY`) | `gemini-3.5-flash` (`MINIMAL`) | `500` / doba | Najszybszy i najstabilniejszy model główny (`~1.5 s`, 0 ukrytych myśli) |
| **1 (Fallback 1)** | Google AI Studio (`GEMINI_API_KEY`) | `gemini-3.5-flash-lite` (`MINIMAL`) | `1 500` / doba | Ultralekki model o wysokim limicie RPD |
| **2 (Fallback 2)** | Google AI Studio (`GEMINI_API_KEY`) | `gemini-3.7-flash` (`LOW`) | `500` / doba | Druga pula modelu Gemini Flash |
| **3 (Fallback 3)** | Google AI Studio (`GEMINI_API_KEY`) | `gemini-3.8-flash` (`LOW`) | `500` / doba | Najnowsza generacja Gemini Flash |
| **4 (Fallback 4)** | Google AI Studio (`GEMINI_API_KEY`) | `gemma-4-31b-it` | `14 400` / doba | Otwarty model Google o dużej puli dziennej |
| **5 (Fallback 5)** | Groq Cloud (`GROQ_API_KEY`) | `openai/gpt-oss-120b` | `1 000` / doba | Zewnętrzny ultra-szybki fallback na układach LPU (`~0.6 s`, Fast-Fail) |
| **6 (Fallback 6)** | Cerebras WSE (`CEREBRAS_API_KEY`) | `gpt-oss-120b` (`low`) | `2 400` / doba | Wafer-Scale Engine (`~2000 tok/s`, odpowiedź w `~0.15 s`, 1 mln tok/doba) |
| **7 (Fallback 7)** | Cerebras WSE (`CEREBRAS_API_KEY`) | `qwen-3.8-27b` (`no-think`) | `648 000` / doba | Gigantyczna pula 648 tys. zapytań/doba (450 RPM, `0` reasoning tokens) |
| **8 (Fallback 8)** | Cloudflare Workers AI (`CF_AI_API_TOKEN`) | `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | `1 000` / doba | Edge AI na sieci Cloudflare (`10 000 Neurons/doba`, `~7.5` neurona/zapytanie) |
| **9 (Fallback 9)** | OpenRouter (`OPENROUTER_API_KEY`) | `nvidia/nemotron-3-super-120b-a12b:free` | `200` / doba | Niezależny zapasowy klaster chmurowy (`:free`, `reasoning: none`) |
| **10 (Bezpiecznik)** | Anthropic Claude (`ANTHROPIC_API_KEY`) | `claude-haiku-4-5` | `1 000` / doba | Ostatni bezpiecznik Pre-paid $5 (`~0.9 s`, `0` myśli, Prompt Cache `-90%`) |

### C. Pełna Obserwowalność, Alerting i Raportowanie CLI (ISO 27001 Zero-PII)
1. **Endpoint Prometheus (`GET /metrics`):** Eksportuje metryki zapytań, trafień cache (`ai_router_cache_hits_total`, `ai_router_cache_entries`), skuteczności kaskady, prób per model, aktywnych cooldownów, limitów dziennych RPD oraz wyzerowanych serii błędów. Zgodnie z **ISO 27001** moduł [`ai-stats.php`](file:///e:/Projekty/VPS/services/ai-router/src/ai-stats.php) **nigdy nie loguje treści pytań klientów, adresów IP ani kluczy API**.
2. **Dashboard Grafany (`uid: ai-router-overview`):** Pulpit **AI Router - Gemini Proxy Monitor** ([`ai-router-overview.json`](file:///e:/Projekty/VPS/config/grafana/provisioning/dashboards/definitions/ai-router-overview.json)) prezentujący ruch, paski dziennego limitu RPD, błędy i zdrowie wszystkich 11 modeli per strona (`fuegolingua`, `katosalsahub`, `twojastronawww`).
3. **Reguły Alertów Prometheusa + Push Ntfy.sh:** Plik [`config/prometheus/rules/ai-router.yml`](file:///e:/Projekty/VPS/config/prometheus/rules/ai-router.yml) monitoruje warunki krytyczne, a `devops-audit.timer` co 15 minut weryfikuje stan alarmów `firing` w Prometheusie i natychmiast wysyła powiadomienia Push na telefon.
4. **Raporty CLI na żądanie:** Skrypty [`scripts/ai-router-report.sh`](file:///e:/Projekty/VPS/scripts/ai-router-report.sh) oraz [`scripts/ai-router-report.ps1`](file:///e:/Projekty/VPS/scripts/ai-router-report.ps1) (szczegóły w [`docs/AI_ROUTER_RAPORT.md`](file:///e:/Projekty/VPS/docs/AI_ROUTER_RAPORT.md)).

### D. Checklista Podpięcia Czatu AI pod Kolejną Stronę WWW (Standard `_site-template` v2.2)
1. **Baza wiedzy na VPS:** Utwórz plik `services/ai-router/data/<site_id>-knowledge.txt` i dopisz jego ścieżkę w `tests/unit/repo-hygiene.test.js`.
2. **CORS na VPS:** Dopisz domenę (`https://domena.pl,https://www.domena.pl`) do `ALLOWED_ORIGINS` w `/opt/devops-stack/.env` (oraz `.env.example`).
3. **Pre-warming Cache RAG:** Dopisz 4 pytania startowe (Quick Prompts) witryny do tablicy `PROMPTS` w [`scripts/warm-ai-cache.sh`](file:///e:/Projekty/VPS/scripts/warm-ai-cache.sh).
4. **Frontend na stronie docelowej (wg wzorca `_site-template`):**
   - Skopiuj `assets/js/ai-widget.js` (zawierający `AbortController` 9s timeout oraz lokalny fallback `getLocalFallbackAnswer(question, siteId)`),
   - W `<head>` każdego pliku HTML dodaj `<link rel="preconnect" href="https://ai.twojastronawww.pl" crossorigin>`,
   - Przed `</body>` dodaj `<script type="module" src="assets/js/ai-widget.js" data-site-id="<site_id>" data-title="Asystent ..."></script>`,
   - Jeśli strona posiada pływający przycisk telefonu (`.sticky-call-btn`), przesuń go na mobile na `bottom: 96px; right: 28px`, aby nie kolidował z przyciskiem czatu (`.tsw-ai-btn` na `bottom: 24px; right: 24px`).




