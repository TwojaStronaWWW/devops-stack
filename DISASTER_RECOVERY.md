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

### Krok 3: Odtworzenie zmiennych środowiskowych i poświadczeń (Czas: ~1 min)
Wszystkie poświadczenia (hasła Grafana, Uptime Kuma, tokeny Cloudflare oraz tokeny runnerów) są bezpiecznie zarchiwizowane w Twojej bazie **KeePass** (`Databasekpoczatek.kdbx` w grupie `VPS - TwojaStronaWWW`) oraz w **GitHub Actions Secrets**.

```bash
cp .env.example .env
nano .env
# Wprowadź poświadczenia z KeePassa / GitHub Secrets

# Utworzenie zabezpieczonego pliku poświadczeń dla scrapera Prometheusa (UID 65534 - ISO 27001):
echo -n "TwojeHasloKumaZKeePassa" > config/prometheus/kuma_password
sudo chown 65534:ubuntu config/prometheus/kuma_password
sudo chmod 640 config/prometheus/kuma_password
chmod 600 .env
```

### Krok 4: Utworzenie wolumenów i sieci Dockera (Czas: ~1 min)
```bash
docker network create devops_internal_network || true
docker volume create uptime_kuma_data
docker volume create grafana_data
docker volume create prometheus_data
mkdir -p /opt/devops-stack/config/node-exporter
mkdir -p /opt/devops-stack/backups/websites
```

### Krok 5: Odtworzenie danych z archiwów (Restore) (Czas: ~3 min)
Prześlij pliki kopii zapasowej (z lokalnego dysku lub pobrane z Cloudflare R2 / S3) do `/tmp` na serwerze i przywróć ich zawartość:

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

# 4. Przywrócenie kopii stron WWW z hostingu LH.pl (w przypadku awarii hostingu LH):
mkdir -p /opt/devops-stack/backups/websites/restored
tar -xzf /tmp/lh_websites_backup_*.tar.gz -C /opt/devops-stack/backups/websites/restored/
```

### Krok 6: Poprawność uprawnień (Fix Permissions) (Czas: ~1 min)
Prometheus i Grafana uruchamiają się jako użytkownicy nie-root (UID `65534` oraz `472`). Weryfikacja uprawnień:

```bash
# Uprawnienia Grafana (UID 472)
docker run --rm -v grafana_data:/target alpine chown -R 472:472 /target

# Uprawnienia Prometheus (UID 65534)
docker run --rm -v prometheus_data:/target alpine chown -R 65534:65534 /target
```

### Krok 7: Uruchomienie usług i runnerów CI/CD (Czas: ~2 min)
```bash
cd /opt/devops-stack/compose
# 1. Uruchomienie monitoringu i tunelu Cloudflare
docker compose up -d

# 2. Uruchomienie runnerów dla obu organizacji (zeslownikiem oraz TwojaStronaWWW)
docker compose -f runners.yml up -d runner-unified runner-twojastronawww

# 3. Aktywacja nocnego harmonogramu backupów systemd
sudo systemctl daemon-reload
sudo systemctl enable --now devops-backup.timer
```

---

## 3. Test Poprawności (Post-Recovery Checklist)

- [ ] Kontenery mają status `Up (healthy)`.
- [ ] Runnery `runner-zeslownikiem-unified` i `runner-twojastronawww-unified` mają status `Listening for Jobs`.
- [ ] Uptime Kuma odzyskuje historię monitorowanych endpointów pod `https://monitoring.twojastronawww.pl` (z auto-logowaniem).
- [ ] Grafana uruchamia się z zachowanymi dashboardami pod `http://127.0.0.1:3000`.
- [ ] Sekcja Disaster Recovery w Grafanie poprawnie odczytuje status backupów z node-exporter.
- [ ] Prometheus zbiera metryki i wszystkie targety mają status `UP` w `http://127.0.0.1:9090/targets`.
- [ ] Systemd timer `devops-backup.timer` jest aktywny (`systemctl list-timers devops-backup.timer`).

