# Procedura Disaster Recovery (< 15 minut)

> **Cel**: Przywrócenie pełnej operacyjności stosu DevOps & Monitoring na nowym hoście VPS lub po awarii sprzętowej/systemowej w czasie poniżej 15 minut.

---

## 1. Wymagania wstępne (Prerequisites)

1. Nowa lub wyczyszczona instancja serwera (Ubuntu 22.04 / 24.04 LTS, AMD64 lub ARM64).
2. Dostęp SSH przez klucz kryptograficzny Ed25519.
3. Dostęp do archiwów kopii zapasowej (`*.tar.gz`) z wolumenów utworzonych przez skrypt `scripts/backup-volumes.sh`.

---

## 2. Procedura Krok po Kroku (Step-by-Step)

### Krok 1: Klonowanie repozytorium (Czas: ~1 min)
```bash
git clone <URL_REPOZYTORIUM> /opt/devops-stack
cd /opt/devops-stack
```

### Krok 2: Przygotowanie środowiska i instalacja Dockera (Czas: ~3 min)
```bash
sudo bash scripts/01-harden-os.sh
sudo bash scripts/02-install-docker.sh
```

### Krok 3: Odtworzenie zmiennych środowiskowych (Czas: ~1 min)
```bash
cp .env.example .env
nano .env
# Wprowadź hasło Grafana i token Cloudflare Tunnel
```

### Krok 4: Utworzenie wolumenów i sieci Dockera (Czas: ~1 min)
```bash
docker network create devops_internal_network || true
docker volume create uptime_kuma_data
docker volume create grafana_data
docker volume create prometheus_data
```

### Krok 5: Odtworzenie danych z archiwów (Restore) (Czas: ~3 min)
Prześlij pliki kopii zapasowej do `/tmp` na serwerze i przywróć ich zawartość:

```bash
# 1. Przywrócenie bazy Uptime Kuma
docker run --rm \
  -v uptime_kuma_data:/target \
  -v /tmp:/backup:ro \
  alpine tar -xzf /backup/uptime_kuma_data_*.tar.gz -C /target

# 2. Przywrócenie konfiguracji i dashboardów Grafana
docker run --rm \
  -v grafana_data:/target \
  -v /tmp:/backup:ro \
  alpine tar -xzf /backup/grafana_data_*.tar.gz -C /target

# 3. Przywrócenie bazy TSDB Prometheus (jeśli wymagana historia)
docker run --rm \
  -v prometheus_data:/target \
  -v /tmp:/backup:ro \
  alpine tar -xzf /backup/prometheus_data_*.tar.gz -C /target
```

### Krok 6: Poprawność uprawnień (Fix Permissions) (Czas: ~1 min)
Prometheus i Grafana uruchamiają się jako użytkownicy nie-root (UID `65534` oraz `472`). Weryfikacja uprawnień:

```bash
# Uprawnienia Grafana (UID 472)
docker run --rm -v grafana_data:/target alpine chown -R 472:472 /target

# Uprawnienia Prometheus (UID 65534)
docker run --rm -v prometheus_data:/target alpine chown -R 65534:65534 /target
```

### Krok 7: Uruchomienie i weryfikacja usług (Czas: ~2 min)
```bash
cd /opt/devops-stack/compose
docker compose up -d

# Weryfikacja poprawności uruchomienia:
docker compose ps
docker compose logs -f --tail=50
```

---

## 3. Test Poprawności (Post-Recovery Checklist)

- [ ] Kontenery mają status `Up (healthy)`.
- [ ] Uptime Kuma odzyskuje historię monitorowanych endpointów pod `http://127.0.0.1:3001`.
- [ ] Grafana uruchamia się z zachowanymi danymi użytkowników i dashboardami pod `http://127.0.0.1:3000`.
- [ ] Prometheus zbiera metryki i target `uptime-kuma` ma status `UP` w `http://127.0.0.1:9090/targets`.
- [ ] Tunel Cloudflare (jeśli uruchomiony) nawiązał połączenie i ruch zewnętrzny jest obsługiwany.
