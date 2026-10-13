# DevOps Stack & Zero-Bloat Monitoring

> **Infrastruktura DevOps**: Od środowiska lokalnego (WSL2) do Oracle Cloud (ARM64 / AMD64) zgodna z zasadami ISO 27001, PoLP (Principle of Least Privilege) i modelem Zero Trust.

---

## 1. Architektura Systemu

```text
[ Internet ]
     │
     ▼ (Tunel szyfrowany TLS / Zero Trust - brak publicznych portów)
[ Cloudflare Tunnel / Tailscale ]
     │
     ▼ (Sieć Docker: devops_internal_network)
 ┌────────────────────────────────────────────────────────┐
 │                      HOST VPS                          │
 │                                                        │
 │  ┌─────────────────┐ ┌───────────────┐ ┌────────────┐  │
 │  │  Uptime Kuma    │ │  Prometheus   │ │  Grafana   │  │
 │  │  (Blackbox mon) │ │  (TSDB 15d)   │ │ (Dashb.)   │  │
 │  │  127.0.0.1:3001 │ │ 127.0.0.1:9090│ │127.0.0.1:  │  │
 │  │                 │ │               │ │   3000     │  │
 │  └────────┬────────┘ └───────▲───────┘ └─────┬──────┘  │
 │           │                  │               │         │
 │           └────── metrics ───┘               │         │
 │                              └─ data source ─┘         │
 │                                                        │
 │  Trwałe wolumeny danych:                               │
 │  ├── uptime_kuma_data                                  │
 │  ├── prometheus_data                                   │
 │  └── grafana_data                                      │
 └────────────────────────────────────────────────────────┘
```

---

## 2. Standardy Bezpieczeństwa (ISO 27001 & CIS)

1. **Izolacja Portów (Zero Trust)**:
   - Żadna usługa monitoringu nie jest wystawiana na `0.0.0.0`.
   - Porty kontenerów nasłuchują wyłącznie na `127.0.0.1`.
   - Dostęp z zewnątrz odbywa się wyłącznie za pośrednictwem szyfrowanych tuneli (Cloudflare Tunnel) lub bramki Reverse Proxy.
2. **Uprawnienia kontenerów (PoLP)**:
   - `prometheus`: uruchamiany jako nieuprzywilejowany użytkownik `nobody` (UID `65534`).
   - `grafana`: uruchamiana jako użytkownik `grafana` (UID `472`).
   - Włączona flaga `security_opt: [no-new-privileges:true]`.
3. **Konfiguracje montowane w trybie tylko do odczytu (`:ro`)**:
   - `prometheus.yml` oraz katalog provisioning Grafany są montowane jako `:ro`.
4. **Ochrona zasobów (Anti-OOM)**:
   - Wszystkie usługi posiadają zdefiniowane limity CPU i RAM w sekcji `deploy.resources.limits`.
   - Logi kontenerów w Dockerze są rotowane (`max-size: 10m`, `max-file: 3`), zapobiegając wyczerpaniu miejsca na dysku.

---

## 3. Struktura Katalogów

```text
.
├── .github/
│   └── workflows/
│       ├── lint-compose.yml       # Sprawdzanie składni plików YAML
│       └── deploy.yml             # Automatyczna aktualizacja stosu na serwerze
├── compose/
│   ├── docker-compose.yml         # Główny plik: Prometheus, Grafana, Uptime Kuma
│   └── extensions.yml             # Rozszerzenia: Cloudflare Tunnel, GitHub Runner
├── config/
│   ├── prometheus/
│   │   └── prometheus.yml         # Konfiguracja celów odpytywania
│   └── grafana/
│       └── provisioning/          # Automatyczne Data Sources i Dashboardy
├── scripts/
│   ├── 01-harden-os.sh            # Hardening systemu (SSH, UFW, Fail2Ban)
│   ├── 02-install-docker.sh       # Instalacja Docker Engine (ARM64/AMD64)
│   └── backup-volumes.sh          # Bezpieczny backup wolumenów w trybie :ro
├── .env.example                   # Szablon zmiennych środowiskowych
├── .gitignore                     # Blokada wycieku sekretów i danych
├── README.md                      # Dokumentacja architektury
└── DISASTER_RECOVERY.md           # Procedura Disaster Recovery (<15 min)
```

---

## 4. Szybki Start (WSL2 / Local Staging)

### Krok 1: Kopiowanie i uzupełnienie zmiennych środowiskowych
```bash
cp .env.example .env
# Edytuj plik .env i ustaw bezpieczne hasło administratora Grafany
```

### Krok 2: Uruchomienie stosu
```bash
cd compose
docker compose up -d
```

### Krok 3: Weryfikacja stanu kontenerów
```bash
docker compose ps
docker compose logs -f
```

Usługi będą dostępne lokalnie pod adresami:
- **Grafana**: [http://127.0.0.1:3000](http://127.0.0.1:3000)
- **Uptime Kuma**: [http://127.0.0.1:3001](http://127.0.0.1:3001)
- **Prometheus**: [http://127.0.0.1:9090](http://127.0.0.1:9090)

---

## 5. Wdrożenie na serwerze produkcyjnym (Oracle Cloud VPS)

1. Po zalogowaniu na świeżą instancję Ubuntu:
   ```bash
   git clone <URL_REPOZYTORIUM> /opt/devops-stack
   cd /opt/devops-stack
   ```
2. Uruchomienie skryptów przygotowawczych:
   ```bash
   sudo bash scripts/01-harden-os.sh
   sudo bash scripts/02-install-docker.sh
   ```
3. Skonfigurowanie pliku `.env`:
   ```bash
   cp .env.example .env
   nano .env
   ```
4. Start stosu:
   ```bash
   cd compose
   docker compose up -d
   # (opcjonalnie z tunelem Cloudflare)
   docker compose -f docker-compose.yml -f extensions.yml up -d
   ```
