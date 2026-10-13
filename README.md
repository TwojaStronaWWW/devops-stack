# DevOps Stack & Zero-Bloat Monitoring

> **Infrastruktura DevOps**: Od środowiska lokalnego (WSL2: Ubuntu / Kali / Oracle Linux) do Oracle Cloud (ARM64 Ampere / AMD64) zgodna z normą **ISO 27001**, wytycznymi **CIS Benchmark**, zasadą **PoLP** (Principle of Least Privilege) i architekturą **Zero Trust**.

---

## 1. Architektura Systemu

```text
[ Internet / Zewnętrzni Użytkownicy ]
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
 │  │  (Blackbox mon) │ │  (TSDB 15d)   │ │  (Dashboardy & Alerting)   │  │
 │  │  127.0.0.1:3001 │ │ 127.0.0.1:9090│ │  127.0.0.1:3000           │  │
 │  └────────┬────────┘ └───────▲───────┘ └─────────────┬──────────────┘  │
 │           │                  │                       │                 │
 │           └────── metrics ───┤                       │                 │
 │                              │                       │                 │
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
 │  │  Zunifikowany Runner Organizacji zeslownikiem (zeslownikiem-pc-unified)│  │
 │  │  Obsługuje automatycznie: gal-anonym, gal-anonim-web & nowe projekty   │  │
 │  └────────────────────────────────────────────────────────────────────────┘  │
 │                                                                        │
 │  Trwałe wolumeny danych & Kopia Offsite:                               │
 │  ├── uptime_kuma_data                                                  │
 │  ├── prometheus_data                                                   │
 │  ├── grafana_data                                                      │
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
│   ├── docker-compose.yml         # Stos: Prometheus, Grafana, Kuma, Node Exporter, cAdvisor, Dozzle, GitHub Exporter
│   ├── extensions.yml             # Tunel Cloudflare Zero Trust (cloudflared)
│   └── runners.yml                # Zunifikowany runner GitHub Actions (ARM64, organizacja zeslownikiem)
├── config/
│   ├── prometheus/
│   │   └── prometheus.yml         # Scrape: Kuma, Node Exporter, cAdvisor, GitHub Exporter (password_file)
│   └── grafana/
│       └── provisioning/
│           ├── datasources/       # Automatyczne podpinanie Prometheus API
│           └── dashboards/        # Automatyczny pulpit: Centrum Monitoringu Stron WWW & Usług
├── docs/
│   └── CLOUDFLARE_STAGING_GUIDE.md# Poradnik testowania stagingu bez publicznych subdomen
├── scripts/
│   ├── 01-harden-os.sh            # Skrypt pełnego hardeningu systemu Ubuntu (ISO 27001) + auto-SWAP
│   ├── 02-install-docker.sh       # Instalacja Docker CE i Compose v2 z optymalizacją pod VPS
│   ├── backup-offsite.sh          # Automatyczny backup do chmury (S3/R2/Oracle) z alertami Ntfy
│   ├── backup-volumes.sh          # Bezpieczny lokalny backup wolumenów :ro z retencją 7 dni
│   ├── open-dashboard.ps1/.cmd    # Błyskawiczny launcher 1-klik (cichy tunel SSH + otwarcie przeglądarki)
│   ├── preview-tunnel.ps1/.sh     # Quick Tunnel – natychmiastowy szyfrowany link HTTPS dla stagingu
│   ├── setup-kuma.js              # Rejestracja monitorowanych witryn w Uptime Kuma
│   ├── setup-ntfy.js              # Konfiguracja kanału powiadomień Ntfy
│   └── runners/                   # Skrypty sterowania runnerami CI/CD
├── tests/
│   └── unit/
│       └── repo-hygiene.test.js   # Natywne testy higieny repozytorium (node:test)
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

## 5. Obsługa Runnerów GitHub Actions (Zunifikowany Runner Organizacji)

Zamiast utrzymywać osobne instancje runnerów dla każdego repozytorium, wdrożono **Jeden Zunifikowany Runner na Poziomie Organizacji `zeslownikiem`** (`zeslownikiem-pc-unified`). 

Runner ten automatycznie obsługuje kolejki zadań dla:
- `gal-anonym` (Desktop)
- `gal-anonim-web` (Web)
- Każdego nowego projektu dodanego do organizacji `zeslownikiem`.

### A. Na stacji roboczej (Windows):
Instalacja znajduje się w `E:\actions-runner-zeslownikiem` (etykiety: `self-hosted`, `Windows`, `X64`).
Uruchomienie procesu w tle:
```cmd
scripts\runners\start-runners.cmd
```
Lub z poziomu PowerShell:
```powershell
pwsh scripts/runners/Start-Runners.ps1
```

### B. Na serwerze produkcyjnym (Linux / VPS):
Jeśli zadania CI/CD mają wykonywać się na maszynie w chmurze w kontenerze Docker:
```bash
cd compose
docker compose -f runners.yml up -d runner-unified
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
   
   Utwórz zabezpieczony plik poświadczeń dla scrapera Prometheusa:
   ```bash
   echo -n "TwojeHasloKuma" > config/prometheus/kuma_password
   chmod 600 config/prometheus/kuma_password
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

