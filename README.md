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
 │  │  (10 monitorów) │ │  (TSDB 15d)   │ │  (3 Dashboardy & Alerting) │  │
 │  │  127.0.0.1:3001 │ │ 127.0.0.1:9090│ │  127.0.0.1:3000           │  │
 │  └────────┬────────┘ └───────▲───────┘ └─────────────┬──────────────┘  │
 │           │                  │                       │                 │
 │           └────── metrics ───┤                       │                 │
 │                              │                       │                 │
 │  ┌─────────────────┐         │                       │                 │
 │  │  AI Router RAG  ├─────────┤ (/metrics, /health,   │                 │
 │  │  (Cache <5ms +  │         │  /analytics, WAF L7)  │                 │
 │  │  11-Model Casc) │         │                       │                 │
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
 │  ┌─────────────────┐         │ Dozzle: Logi Kontenerów w Przeglądarce│  │
 │  │ OCI Keepalive   │         │ 127.0.0.1:8888                       │  │
 │  │ (+20% / 4.8 GB) │         └──────────────────────────────────────┘  │
 │  └─────────────────┘                                                   │
 │                                                                        │
 │  [ Strefa 2: Odseparowana sieć CI/CD `devops_runners_network` ]        │
 │  ┌──────────────────────────────────────────────────────────────────┐  │
 │  │  3 Runnery GitHub Actions ARM64 (brak dostępu L3 do monitoringu) │  │
 │  │  • runner-zeslownikiem-unified  • runner-twojastronawww-unified  │  │
 │  │  • runner-gal-anonim-web                                         │  │
 │  └──────────────────────────────────────────────────────────────────┘  │
 │                                                                        │
 │  Trwałe wolumeny, Autonomiczny Strażnik 24/7 & Kopia Offsite:          │
 │  ├── devops-audit.timer (co 15 min) ──> IoC/WAF + Dual-AI 120B (08:00)  │
 │  ├── devops-backup.timer (03:00 UTC) ──> AES-256 + Restore Drill ──> R2│
 │  └── backup-websites-lh.sh (FTPS TLS + mysqldump) ──> Cloudflare R2    │
 └────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Standardy Bezpieczeństwa & Pełna Ochrona Przed Włamaniami (ISO 27001)

Wszystkie mechanizmy obronne są wdrażane automatycznie przez skrypt [`scripts/01-harden-os.sh`](file:///e:/Projekty/VPS/scripts/01-harden-os.sh):

### A. Automatyczne Aktualizacje Bezpieczeństwa (Unattended Upgrades & Auto-Patching APT)
- **Codzienna instalacja łatek CVE (OS + Docker CE)**: System automatycznie pobiera i instaluje krytyczne poprawki bezpieczeństwa z oficjalnych repozytoriów (`Ubuntu:noble-security`, `Ubuntu:noble-updates` oraz `Docker CE:noble`), a autonomiczny strażnik `audit-server.sh` co 15 minut monitoruje kolejkę APT (`devops_apt_upgradable_packages`) i automatycznie instaluje oczekujące łatki w tle (`Auto-Patching`), eliminując podatności typu zero-day bez konieczności ręcznego logowania administratora.
- **Higiena pakietów i logów**: Automatyczne usuwanie zbędnych zależności (`Remove-Unused-Kernel-Packages: true`) oraz twardy limit `SystemMaxUse=200M` na logi systemowe `systemd-journald`.

### B. Ochrona Dostępu SSH (Brak Haseł, AllowUsers & Blokada Roota) + Kryminalistyczna Kontrola IoC
- **Blokada konta root i biała lista użytkowników**: `PermitRootLogin no`, `AllowUsers ubuntu` oraz blokada powłoki odziedziczonego konta `opc` (`/usr/sbin/nologin`) uniemożliwiają logowanie na jakiekolwiek inne konto.
- **Wyłączenie uwierzytelniania hasłem**: `PasswordAuthentication no` całkowicie eliminuje podatność na ataki słownikowe i zgadywanie haseł. Dozwolone są wyłącznie silne klucze asymetryczne (**Ed25519**).
- **Limit prób i pełny dziennik audytowy**: `MaxAuthTries 3`, `AllowAgentForwarding no` oraz `LogLevel VERBOSE` (logowanie odcisków kluczy SSH zgodnie z CIS Benchmark).
- **Wyłączenie zbędnych demonów sieciowych**: `X11Forwarding no` oraz całkowite zamaskowanie `rpcbind.service` / `rpcbind.socket` (port 111).
- **Kryminalistyczna kontrola śladów włamania (IoC — `devops_security_ioc_clean`)**: Co 15 minut skrypt `audit-server.sh` weryfikuje dziennik `journalctl -u ssh` pod kątem zerowej liczby logowań hasłem/rootem, sprawdza brak obcych kont `UID 0` w `/etc/passwd`, brak procesów uruchomionych z `/tmp` i `/dev/shm`, integralność `/etc/cron*` oraz kontroluje liczbę kluczy w `~/.ssh/authorized_keys`.

### C. System Zapobiegania Włamaniom (Fail2Ban IPS) + WAF Warstwy 7 i IP Penalty Box
- **Progresywny Ban SSH (Fail2Ban IPS)**: Po **3 nieudanych próbach** logowania w oknie 10 minut adres IP agresora zostaje zablokowany na zaporze UFW na **1 godzinę** (`bantime = 1h`), a dla recydywistów czas blokady rośnie wykładniczo (`bantime.increment = true`, `bantime.factor = 2`) aż do **7 dni (`7d`)**. Statystyki banów (`devops_fail2ban_banned_total`, `devops_fail2ban_currently_banned`) są wizualizowane na żywo w Grafanie.
- **Strażnik WAF Warstwy 7 + 15-Minutowy IP Penalty Box (`chat-router.php`)**: Każde zapytanie do bramki AI jest skanowane przed wywołaniem modelu LLM pod kątem ataków **Prompt Injection**, **Jailbreak**, **XSS** (`<script>`), **SQL Injection** (`UNION SELECT`, `DROP TABLE`) oraz **Path Traversal / LFI** (`../etc/passwd`). Wykryty atak jest natychmiast odrzucany kodem `HTTP 403` (0 zużytych tokenów), a IP agresora trafia na **15 minut do Penalty Box** (`banClientIp`).

### D. Zapora Ogniowa UFW (Stateful Firewall & Rate Limiting)
- **Polityka domyślna**: Całkowita blokada ruchu przychodzącego (`default deny incoming`) oraz zezwolenie na ruch wychodzący (`default allow outgoing`).
- **SSH Rate Limiting**: Reguła `ufw limit 22/tcp` odrzuca połączenia od hostów, które próbują zainicjować 6 lub więcej połączeń w ciągu 30 sekund.
- **Brak otwartych portów webowych**: W modelu Cloudflare Zero Trust porty 80 i 443 pozostają **zamknięte** na zaporze serwera.

### E. Ochrona na Poziomie Jądra i Sieci (Kernel Sysctl Hardening)
- **Ochrona przed SYN Flood DoS**: `net.ipv4.tcp_syncookies = 1` chroni przed przepełnieniem tablicy połączeń TCP fałszywymi pakietami SYN.
- **Anti-Spoofing (RP Filter)**: `net.ipv4.conf.all.rp_filter = 1` weryfikuje trasę powrotną pakietów, odrzucając pakiety z podrobionym adresem źródłowym (IP Spoofing).
- **Blokada ataków MITM (ICMP Redirects)**: Wyłączenie akceptowania i wysyłania przekierowań ICMP (`accept_redirects = 0`).
- **Ochrona przed atakiem Smurf**: `icmp_echo_ignore_broadcasts = 1` ignoruje zapytania ICMP wysyłane na adresy rozgłoszeniowe.
- **Utwardzenie wskaźników jądra i eBPF JIT**: `kernel.kptr_restrict = 2`, `kernel.dmesg_restrict = 1`, `kernel.unprivileged_bpf_disabled = 2` oraz `net.core.bpf_jit_harden = 2`.

### F. Zabezpieczenie Pamięci Współdzielonej (`/dev/shm`)
- Montowanie pamięci `/dev/shm` z flagami `noexec,nosuid,nodev` w `/etc/fstab` uniemożliwia uruchamianie złośliwych skryptów i binariów w pamięci podręcznej.

### G. Izolacja Usług i Konteneryzacja (Docker Hardening, `DOCKER-USER` & Network Segmentation)
- **Binding wyłącznie do localhosta + `DOCKER-USER` WAN Guard**: Porty usług nasłuchują wyłącznie na `127.0.0.1`, a łańcuch `DOCKER-USER` w `iptables` wymusza blokadę nowych połączeń przychodzących z interfejsu WAN (`enp0s6 -> DROP`), uniemożliwiając ominięcie zapory UFW przez demona Docker.
- **Separacja sieciowa Runnerów CI/CD**: Runnery GitHub Actions działają w odizolowanej sieci `devops_runners_network`, nie mając dostępu sieciowego do wewnętrznej sieci `devops_internal_network`.
- **PoLP (Zasada Najmniejszych Przywilejów) & Piaskownica PHP (`99-security-hardening.ini`)**:
  - Prometheus działa jako użytkownik `nobody` (UID `65534`).
  - Grafana działa jako użytkownik `grafana` (UID `472`) z domyślną rolą `Viewer` dla dostępu bez logowania przez tunel SSH (`GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer`).
  - Uptime Kuma ma wymuszone logowanie (`DISABLE_AUTH=false`) i jest dostępna przez tunel SSH (`127.0.0.1:3001`).
  - AI Router działa jako użytkownik `nobody` z 4 workerami PHP (`PHP_CLI_SERVER_WORKERS=4`), wyłączonymi funkcjami powłoki (`disable_functions = exec,passthru,shell_exec,system,proc_open,popen,...`), wyłączonym `file_uploads` oraz `open_basedir = /app:/tmp`.
- **Flaga bezpieczeństwa**: `security_opt: [no-new-privileges:true]` uniemożliwia eskalację uprawnień z wnętrza któregokolwiek z 13 kontenerów.
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
│       ├── deploy.yml             # Automatyczny deploy po SSH + flush DNS nscd + audyt powykonawczy
│       └── external-watchdog.yml  # Zewnętrzny Dead Man's Switch (WAN Watchdog z chmury GitHub -> Ntfy.sh)
├── .githooks/
│   ├── pre-commit                 # Git hook blokujący wycieki sekretów (.env, .env.bak*, *.pem, *.key)
│   └── commit-msg                 # Git hook wymuszający format Conventional Commits
├── compose/
│   ├── docker-compose.yml         # Stos (devops_internal_network): Prometheus, Grafana, Kuma, Node Exporter, cAdvisor, Dozzle, AI Router, GitHub Exporter, OCI Keepalive Buffer
│   ├── extensions.yml             # Tunel Cloudflare Zero Trust (cloudflared)
│   └── runners.yml                # Runnery GitHub Actions ARM64 w odseparowanej sieci (devops_runners_network)
├── config/
│   ├── prometheus/
│   │   ├── prometheus.yml         # Scrape: Kuma, Node Exporter, cAdvisor, GitHub Exporter, AI Router (/metrics co 5s)
│   │   └── rules/
│   │       └── ai-router.yml      # 21 reguł alertów Prometheusa (kaskada AI, WAF, Fail2Ban IPS, IoC, CPU, Inodes, NTP, certyfikaty, dysk, RAM, backupy)
│   └── grafana/
│       └── provisioning/
│           ├── datasources/       # Automatyczne podpinanie Prometheus API (uid: prometheus)
│           └── dashboards/        # 3 pulpity: Centrum Monitoringu + AI Router + Analityka Ruchu WWW & SEO (Cookieless)
├── docs/
│   ├── AI_ROUTER_RAPORT.md        # Dokumentacja telemetrii, metryk, cache'u RAG, WAF, Analityki WWW i raportowania AI Routera
│   └── CLOUDFLARE_STAGING_GUIDE.md# Poradnik testowania stagingu bez publicznych subdomen
├── scripts/
│   ├── 01-harden-os.sh            # Skrypt pełnego hardeningu systemu Ubuntu (ISO 27001, Fail2ban 1h->7d, TCP BBR, inotify, NTP, SWAP 2GB, DOCKER-USER systemd hook, journald 200M)
│   ├── 02-install-docker.sh       # Instalacja Docker CE i Compose v2 z optymalizacją pod VPS
│   ├── ai-router-report.sh/.ps1   # Narzędzia CLI do generowania raportów skuteczności, cache'u i kaskady AI Routera
│   ├── audit-server.sh            # 5-warstwowy audyt (78 testów, IoC/SUID/IPS/WAF, NTP, BBR, SWAP, Zero-Trust, Web Analytics v3, 24h Log Hunter) + poranny raport 08:00 (Dual-AI HIGH Reasoning $0.00 + eskalacja Claude 4.6)
│   ├── backup-offsite.sh          # Snapshot wolumenów (weryfikacja tar -tzf + SQLite + AES-256 + nocny Restore Drill) do chmury R2
│   ├── backup-volumes.sh          # Bezpieczny lokalny backup wolumenów :ro z retencją 7 dni
│   ├── backup-websites-lh.sh      # Backup serwisów WWW z hostingu LH.pl (FTPS TLS + mysqldump + tar -tzf + AES-256)
│   ├── restore-backup.sh          # Automatyczne odtwarzanie (Disaster Recovery) i test Restore Drill (--verify-only)
│   ├── open-dashboard.ps1/.cmd    # Błyskawiczny launcher 1-klik (cichy tunel SSH + otwarcie 3x Grafana, Dozzle i Uptime Kuma)
│   ├── preview-tunnel.ps1/.sh     # Quick Tunnel – natychmiastowy szyfrowany link HTTPS dla stagingu
│   ├── setup-audit-timer.sh       # Idempotentna instalacja strażnika systemd 24/7 (devops-audit.timer co 15 min)
│   ├── setup-backup-timer.sh      # Idempotentna instalacja harmonogramu backupów systemd (devops-backup.timer 03:00 UTC)
│   ├── setup-kuma.js              # Idempotentna rejestracja 10 monitorowanych witryn i AI Routera w Uptime Kuma
│   ├── setup-ntfy.js              # Konfiguracja kanału powiadomień Ntfy
│   ├── sync-gsc-keywords.sh       # Bezciasteczkowa synchronizacja słów kluczowych Google Search Console API + Sitemap Refresh + IndexNow
│   ├── verify-remote.ps1/.cmd     # Zdalny wyzwalacz audytu VPS z poziomu Windows (npm run audit)
│   ├── warm-ai-cache.sh           # Idempotentny pre-warming pamięci podręcznej RAG (Quick Prompts) po wdrożeniu
│   └── runners/                   # Skrypty sterowania runnerami CI/CD
├── services/
│   └── ai-router/                 # Scentralizowany mikro-router AI & Analityki WWW (PHP 8.3 Alpine + PDO SQLite FTS5, Multi-Provider RAG, Cache <5ms, WAF L7)
│       ├── Dockerfile             # Izolowany kontener non-root, minimalny footprint (~12 MB RAM, 4 workery PHP)
│       ├── src/
│       │   ├── chat-router.php    # Obsługa POST, CORS whitelist, WAF L7 + 15m Penalty Box, Cache RAG (<5ms), Leady Ntfy 1-Klik, 11-modelowa kaskada LLM, /analytics
│       │   ├── ai-stats.php       # Moduł telemetrii Prometheus (AI + Cookieless Web Analytics v3), Cooldownu modeli i limitów RPD
│       │   └── widget.js          # Uniwersalny widget czatu AI + Cookieless Web Analytics serwowany przez GET /widget.js
│       ├── data/                  # Bazy wiedzy RAG montowane :ro (fuegolingua, katosalsahub, twojastronawww, sql/sqlite)
│       ├── storage/               # Trwały wolumen na pliki rate-limit, cache RAG (/app/storage/cache) oraz ai_stats.json
│       └── public-test/           # Tester frontendu (Vanilla HTML + JS + CSS)
├── tests/
│   └── unit/
│       ├── repo-hygiene.test.js   # 26 testów higieny repozytorium, walidacji 3 dashboardów JSON, telemetrii AI/WWW i kontraktu _site-template
│       └── security-regression.test.js # 16 testów regresji bezpieczeństwa OWASP / ISO 27001 / Zero Trust / WAF / Analytics (łącznie 42 testy)
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

5. **Uruchomienie pełnego stosu produkcyjnego, pre-warming Cache RAG oraz aktywacja strażnika 24/7 i nocnych backupów**:
   ```bash
   cd /opt/devops-stack/compose
   docker compose --env-file /opt/devops-stack/.env -f docker-compose.yml -f extensions.yml -f runners.yml up -d --build
   bash /opt/devops-stack/scripts/warm-ai-cache.sh
   sudo bash /opt/devops-stack/scripts/setup-audit-timer.sh
   sudo bash /opt/devops-stack/scripts/setup-backup-timer.sh
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
| **4. Ochrona Brute-Force & WAF** | UFW rate-limiting (`limit 22/tcp`) + Fail2ban IPS (progresywny ban `1h -> 7d`) + WAF Warstwy 7 z 15-min IP Penalty Box. | Automatyczny ban na zaporze po 3 błędach SSH oraz natychmiastowa blokada `HTTP 403` prób Prompt Injection / XSS / SQLi / LFI. |
| **5. Higiena Sekretów** | Rygor `.gitignore` wyklucza pliki `.env`, `.env.bak*`, klucze `*.pem`, `*.key`, `id_*`, certyfikaty oraz pliki haseł `kuma_password`. | W publicznym repozytorium znajdują się **wyłącznie zanonimizowane szablony** (`.env.example`). Zero realnych tokenów w historii gita. |
| **6. Git Hooks (Pre-commit)** | Skrypt `.githooks/pre-commit` skanuje każdy commit i blokuje wysłanie plików o wrażliwych rozszerzeniach. | Ochrona przed przypadkowym wysłaniem klucza lub hasła przez administratora. |
| **7. Separacja Sieci i PoLP** | Runnery CI/CD są odizolowane w `devops_runners_network`, a usługi działają z `no-new-privileges:true` (`nobody:65534`, `grafana:472`). | Nawet w hipotetycznym scenariuszu kompromitacji zadania CI/CD atakujący nie ma dostępu do wewnętrznej sieci usług ani roota hosta. |

---

## 9. Architektura Kopii Zapasowych, Weryfikacji Integralności i Audytu 24/7 (ISO 27001)

Serwer VPS pełni funkcję **Centralnego Sejfu i Węzła Disaster Recovery** dla całej infrastruktury TwojaStronaWWW:

### A. Backup Wolumenów Monitoringu i AI (`scripts/backup-offsite.sh`) + Nocny Restore Drill:
- Tworzy spójne snapshoty wszystkich 7 wolumenów (`uptime_kuma_data`, `grafana_data`, `prometheus_data`, `ai_router_storage`, `runner_zeslownikiem_data`, `runner_twojastronawww_data`, `runner_gal_anonim_web_data`) montowanych w trybie tylko do odczytu (`:ro`) wraz z weryfikacją baz SQLite (`PRAGMA quick_check`).
- Automatycznie weryfikuje integralność wygenerowanego archiwum (`tar -tzf`) przed dalszym przetwarzaniem i eksportuje metrykę `devops_backup_verified`.
- Szyfruje archiwum symetrycznie algorytmem **AES-256-CBC (PBKDF2)** (`BACKUP_ENCRYPTION_KEY`) i przesyła do **Cloudflare R2 / S3** z kroczącą retencją **30 dni lokalnie na VPS** oraz **14 dni w chmurze R2** (`rclone delete --min-age 14d`, mieszcząc się w 100% w darmowym limicie 10 GB R2).
- **Automatyczny Nocny Restore Drill (`restore-backup.sh --verify-only`)**: Po wysłaniu kopii do R2 skrypt automatycznie pobiera paczkę z chmury, odszyfrowuje ją w izolowanym katalogu tymczasowym i testuje odtwarzalność archiwów oraz spójność baz SQLite, wystawiając metrykę `devops_backup_restore_drill_verified`.

### B. Backup Stron WWW z Hostingu LH.pl (`scripts/backup-websites-lh.sh`):
- Łączy się ze zdalnym hostingiem LH.pl przez szyfrowany kanał **FTPS TLS** (`ftp:ssl-allow true`, `ftp:ssl-protect-data true`).
- Pobiera strukturę plików witryn (`public_html`) z normalizacją uprawnień (`--no-perms` + `chown`), oraz wykonuje zrzut baz MySQL (`mysqldump --single-transaction`).
- Weryfikuje integralność archiwum (`tar -tzf`, metryki `devops_backup_websites_verified` oraz `devops_backup_websites_db_verified`), szyfruje **AES-256-CBC** i przesyła do Cloudflare R2 (`${S3_BUCKET}/websites/`) z automatyczną rotacją **30 dni lokalnie** oraz **14 dni w R2**.

### C. Automatyzacja Harmonogramów Systemd (Backup, Strażnik 24/7 & Poranny Audytor AI):
- **`devops-backup.timer`** ([`scripts/setup-backup-timer.sh`](file:///e:/Projekty/VPS/scripts/setup-backup-timer.sh)): Uruchamiany codziennie o **03:00 UTC** (05:00 rano czasu polskiego) — wykonuje pełny backup wolumenów, stron LH.pl oraz automatyczny *Restore Drill*.
- **`devops-audit.timer`** ([`scripts/setup-audit-timer.sh`](file:///e:/Projekty/VPS/scripts/setup-audit-timer.sh)): Uruchamiany **co 15 minut** (0 zapytań AI w rutynowych przebiegach) — wykonuje 5-warstwowy audyt bezpieczeństwa i zdrowia (`audit-server.sh`, 78 testów), kontroluje ślady włamań IoC (`devops_security_ioc_clean`), blokady WAF L7 (`devops_waf_blocked_total`), ochronę Zero-Trust i bazę SQLite FTS5, telemetrię Cookieless Web Analytics v3 & GSC Sync, skaner wyjątków 24h (`devops_log_critical_24h_total`) i statystyki Fail2Ban (`devops_fail2ban_banned_total`), odświeża telemetrię `audit.prom`, wykonuje samonaprawę DNS `nscd` w Uptime Kuma i wysyła natychmiastowy alert Push na telefon (**Ntfy.sh**) w razie jakiejkolwiek awarii lub aktywnego alarmu Prometheusa. Ponadto raz dziennie o **08:00 czasu polskiego** wysyła poranny raport stanu infrastruktury wzbogacony o **24-godzinny Rentgen (`--since 24h`)** weryfikowany krzyżowo przez **dwa darmowe modele w trybie głębokiego myślenia (`Groq/Cerebras GPT-OSS-120B reasoning: HIGH` + `Gemini 3.5 Flash thinking: HIGH`, koszt `$0.00`)**, z automatyczną eskalacją do **`Claude Sonnet 4.6`** wyłącznie w razie wykrycia anomalii/błędów.

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

## 11. Centralna Bramka AI, WAF L7 & Bezciasteczkowa Analityka WWW (`services/ai-router`)

Serwer VPS udostępnia scentralizowany mikro-router AI oraz kolektor bezciasteczkowej analityki WWW ([`services/ai-router/src/chat-router.php`](file:///e:/Projekty/VPS/services/ai-router/src/chat-router.php)) obsługujący witryny platformy (**Fuego Lingua**, **Kato Salsa Hub**, **TwojaStronaWWW**) pod adresem `https://ai.twojastronawww.pl`.

### A. Klasyfikacja Rozwiązania, Cache RAG (`< 5 ms`), WAF L7, Analityka WWW i Detektor Leadów
- **Obszar 3 (AI z bazą wiedzy firmy RAG) + Enterprise High-Availability:** Dynamiczny dobór bazy wiedzy po parametrze `site_id` (`services/ai-router/data/<site_id>-knowledge.txt` montowane w trybie `:ro`), pamięć konwersacji Multi-Turn (`history` do 8 wiadomości) oraz twarde reguły anty-halucynacyjne (Guardrails).
- **WAF Warstwy 7 + 15-Minutowy IP Penalty Box (`security_blocked`):** Blokuje próby Prompt Injection, Jailbreak, XSS, SQLi oraz Path Traversal kodem `HTTP 403` przed wywołaniem modelu AI i nakłada 15-minutową blokadę na IP agresora.
- **Bezciasteczkowa Analityka Ruchu WWW & SEO (`POST /analytics` & `/collect` — 100% Cookieless RODO / Zero-PII):** Rejestruje unikalnych odwiedzających dziś (anonimowy dzienny skrót SHA-256 bez zapisu IP i bez ciasteczek), odsłony podstron, źródła wejść (`Google`, `Bezpośrednie`, `Facebook`, `Instagram`), urządzenia (`Smartfon` vs `Komputer`), kraje (`CF-IPCountry` z flagami) oraz wyszukiwane hasła w Salsopedii, prezentując je na 3. dashboardzie Grafany (`web-analytics-overview.json`).
- **Inteligentny Cache odpowiedzi RAG (`~1.8 ms` / `0` tokenów) + Automatyczny Pre-warming (`scripts/warm-ai-cache.sh`):** Powtarzalne pytania o ofertę i cennik są serwowane z atomowej pamięci podręcznej `/app/storage/cache` w niecałe **2 milisekundy**, bez zużywania dziennych limitów API. Klucz cache normalizuje interpunkcji i wielkość liter oraz uwzględnia `filemtime` pliku wiedzy, a skrypt `scripts/warm-ai-cache.sh` automatycznie rozgrzewa przyciski Quick Prompts podczas każdego wdrożenia CI/CD (`deploy.yml`).
- **Ochrona przed ucinaniem zdań i ukrytymi tokenami myślenia (`thoughtsTokenCount` / `reasoning_tokens`):** Router wymusza `maxOutputTokens: 2048`, przekazuje `'thinkingLevel' => 'MINIMAL'` dla `gemini-3.5-*` (lub `'LOW'` dla `gemini-3.7/3.8`), `'reasoning_effort' => 'low'` / `'disable_reasoning' => true` dla Cerebras WSE, `'reasoning' => ['effort' => 'none']` dla OpenRoutera, wykorzystuje domyślnie wyłączone *Extended Thinking* + *Prompt Caching* (`ephemeral` `-90%`) w Claude Haiku 4.5 oraz odrzuca odpowiedzi z `finishReason === 'MAX_TOKENS'` (`length` / `max_tokens`).
- **Detektor „Gorącego Leada” i Natychmiastowa Ekstrakcja Telefonu / E-maila (Zero-PII na dysku):** Gdy klient poda w rozmowie numer telefonu lub adres e-mail (`event=contact_lead_captured`), router automatycznie wyciąga i formatuje numer (`📞 TELEFON: +48 ...`) oraz adres (`✉️ E-MAIL: ...`), umieszcza je bezpośrednio w tytule powiadomienia i w pierwszych linijkach wiadomości Ntfy.sh (wraz z wcześniejszymi pytaniami z sesji) oraz dodaje natywne przyciski akcji 1-Klik (`Zadzwoń tel:...` / `Napisz e-mail mailto:...`). Przy 4. pytaniu klienta w jednej sesji (`count($sanitizedHistory) === 6`) wysyła ponadto sygnał `event=hot_lead_detected`.
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
1. **Endpoint Prometheus (`GET /metrics` co 5 s):** Eksportuje metryki zapytań, zablokowanych ataków WAF (`security_blocked`), trafień cache (`ai_router_cache_hits_total`, `ai_router_cache_entries`), bezciasteczkowej analityki WWW (`web_analytics_*`), skuteczności kaskady, prób per model, aktywnych cooldownów, limitów dziennych RPD oraz wyzerowanych serii błędów. Zgodnie z **ISO 27001** moduł [`ai-stats.php`](file:///e:/Projekty/VPS/services/ai-router/src/ai-stats.php) **nigdy nie loguje treści pytań klientów, adresów IP ani kluczy API**.
2. **3 Dashboardy Grafany:**
   - **Centrum Monitoringu Stron WWW & Usług** (`uptime-kuma-overview.json`): Status 10 witryn, podwójne zegary RAM (Realny vs Sztuczny +20% OCI Buffer), liczniki zablokowanych ataków WAF/Fail2Ban IPS oraz status integralności systemu IoC.
   - **AI Router - Gemini Proxy Monitor** (`ai-router-overview.json`): Ruch czatu, trafienia Cache RAG `<5ms`, paski dziennego limitu RPD, błędy i zdrowie wszystkich 11 modeli oraz pozyskane leady.
   - **Analityka Ruchu WWW & SEO (Cookieless)** (`web-analytics-overview.json`): Unikalni odwiedzający dziś, odsłony podstron, źródła wejść (Google, Bezpośrednie, FB, IG), urządzenia (Smartfon vs Komputer), kraje GeoIP z flagami oraz wyszukiwane hasła w Salsopedii.
3. **18 Reguł Alertów Prometheusa + Push Ntfy.sh:** Plik [`config/prometheus/rules/ai-router.yml`](file:///e:/Projekty/VPS/config/prometheus/rules/ai-router.yml) monitoruje warunki krytyczne, a `devops-audit.timer` co 15 minut weryfikuje stan alarmów `firing` w Prometheusie i natychmiast wysyła powiadomienia Push na telefon.
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





