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
 │  │  cAdvisor       ├─────────┘                       │                 │
 │  │  (Docker stats) │                                 │                 │
 │  └─────────────────┘                                 │                 │
 │                              └────── data source ────┘                 │
 │                                                                        │
 │  ┌───────────────────────────────────┐ ┌────────────────────────────┐  │
 │  │  Runner gal-anonym (Desktop)      │ │ Runner gal-anonim-web (Web)│  │
 │  │  (Konteneryzowany GitHub Runner)  │ │ (Konteneryzowany Runner)   │  │
 │  └───────────────────────────────────┘ └────────────────────────────┘  │
 │                                                                        │
 │  Trwałe wolumeny danych (Data Persistence):                            │
 │  ├── uptime_kuma_data                                                  │
 │  ├── prometheus_data                                                   │
 │  └── grafana_data                                                      │
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
│   └── workflows/
│       ├── lint-compose.yml       # Sprawdzanie poprawności składni Compose w CI
│       └── deploy.yml             # Automatyczny deploy na serwer VPS po merge'u do main
├── compose/
│   ├── docker-compose.yml         # Stos: Prometheus, Grafana, Kuma, Node Exporter, cAdvisor
│   ├── extensions.yml             # Tunel Cloudflare Zero Trust
│   └── runners.yml                # Konteneryzowane runnery GitHub Actions dla VPS
├── config/
│   ├── prometheus/
│   │   └── prometheus.yml         # Scrape: Prometheus, Uptime Kuma, Node Exporter, cAdvisor
│   └── grafana/
│       └── provisioning/
│           ├── datasources/       # Automatyczne podpinanie Prometheus API
│           └── dashboards/        # Automatyczny pulpit: Centrum Monitoringu Stron WWW & Usług
├── docs/
│   └── CLOUDFLARE_STAGING_GUIDE.md# Poradnik testowania stagingu bez publicznych subdomen
├── scripts/
│   ├── 01-harden-os.sh            # Skrypt pełnego hardeningu systemu Ubuntu (ISO 27001)
│   ├── 02-install-docker.sh       # Instalacja Docker Engine z optymalizacją pod WSL2/VPS
│   ├── backup-volumes.sh          # Bezpieczny backup wolumenów :ro z retencją 7 dni
│   ├── preview-tunnel.sh          # Quick Tunnel (Linux/WSL) – natychmiastowy link HTTPS
│   ├── preview-tunnel.ps1         # Quick Tunnel (Windows/PowerShell)
│   └── runners/
│       ├── Resume-NightlyRuns.ps1 # Zoptymalizowane wznawianie przerwanych zadan CI/CD
│       ├── Start-Runners.ps1      # Orkiestrator runnerow dla stacji roboczej Windows
│       └── start-runners.cmd      # Skrót uruchomieniowy dla systemu Windows
├── .env.example                   # Szablon zmiennych środowiskowych i tokenów
├── .gitattributes                 # Wymuszenie zakończeń linii LF (ochrona przed CRLF)
├── .gitignore                     # Blokada wycieku sekretów, haseł i kopii zapasowych
├── README.md                      # Główna dokumentacja architektury i bezpieczeństwa
└── DISASTER_RECOVERY.md           # Procedura odtworzenia środowiska z kopii w < 15 minut
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

## 5. Obsługa Runnerów GitHub Actions

### Na stacji roboczej (Windows):
Uruchomienie lokalnych instancji runnerów (`gal-anonym` oraz `gal-anonim-web`) wraz z automatycznym wznawianiem nocnych zadań:
```cmd
scripts\runners\start-runners.cmd
```
Lub z poziomu PowerShell:
```powershell
pwsh scripts/runners/Start-Runners.ps1
```

### Na serwerze produkcyjnym (Oracle Cloud VPS / Linux):
Runnery działają w izolacji kontenerowej w sieci wewnętrznej:
```bash
cd compose
docker compose -f runners.yml up -d
```

---

## 6. Szybki Start na Świeżym Serwerze VPS (Oracle Cloud Ubuntu)

1. **Klonowanie repozytorium**:
   ```bash
   git clone <URL_REPOZYTORIUM> /opt/devops-stack
   cd /opt/devops-stack
   ```
2. **Wykonanie hardeningu systemu i instalacja Dockera**:
   ```bash
   sudo bash scripts/01-harden-os.sh
   sudo bash scripts/02-install-docker.sh
   ```
3. **Konfiguracja zmiennych środowiskowych**:
   ```bash
   cp .env.example .env
   nano .env
   ```
4. **Uruchomienie stosu**:
   ```bash
   cd compose
   docker compose up -d
   # Opcjonalnie z tunelem Cloudflare i runnerami:
   docker compose -f docker-compose.yml -f extensions.yml -f runners.yml up -d
   ```
