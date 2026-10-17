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
Wszystkie poświadczenia (hasła Grafana, Uptime Kuma, tokeny Cloudflare, tokeny runnerów oraz 6 kluczy API dla AI Routera: `GEMINI_API_KEY`, `GROQ_API_KEY`, `CEREBRAS_API_KEY`, `CF_AI_API_TOKEN`, `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`) są bezpiecznie zarchiwizowane w Twojej bazie **KeePass** (`Databasekpoczatek.kdbx` w grupie `VPS - TwojaStronaWWW`) oraz w **GitHub Actions Secrets**.

```bash
cp .env.example .env
nano .env
# Wprowadź poświadczenia z KeePassa / GitHub Secrets (w tym GEMINI_API_KEY, GROQ_API_KEY, CEREBRAS_API_KEY, CF_AI_API_TOKEN, CF_ACCOUNT_ID, OPENROUTER_API_KEY, ANTHROPIC_API_KEY)

# Utworzenie zabezpieczonego pliku poświadczeń dla scrapera Prometheusa (UID 65534 - ISO 27001):
echo -n "TwojeHasloKumaZKeePassa" > config/prometheus/kuma_password
sudo chown 65534:ubuntu config/prometheus/kuma_password
sudo chmod 640 config/prometheus/kuma_password
chmod 600 .env
```

### Krok 4: Utworzenie wolumenów i obu stref sieciowych Dockera (Czas: ~1 min)
```bash
docker network create devops_internal_network || true
docker network create devops_runners_network || true
docker volume create uptime_kuma_data
docker volume create grafana_data
docker volume create prometheus_data
docker volume create ai_router_storage
docker volume create runner_zeslownikiem_data
docker volume create runner_twojastronawww_data
docker volume create runner_gal_anonim_web_data
mkdir -p /opt/devops-stack/config/node-exporter
mkdir -p /opt/devops-stack/backups/websites
```

### Krok 5: Odtworzenie danych z archiwów (Restore) (Czas: ~2 min)
Możesz przeprowadzić automatyczne pobranie z chmury Cloudflare R2, odszyfrowanie AES-256-CBC, weryfikację spójności SQLite oraz przywrócenie wszystkich wolumenów i uprawnień jednym poleceniem:

```bash
# Opcja A (Zalecana — pełny automat pobierający najświeższy backup z Cloudflare R2):
bash /opt/devops-stack/scripts/restore-backup.sh --from-r2 --yes

# Opcja B (Nieinwazyjny test odtworzeniowy / Restore Drill bez nadpisywania wolumenów):
bash /opt/devops-stack/scripts/restore-backup.sh --verify-only

# Opcja C (Ręczne przywrócenie pojedynczego wolumenu z lokalnego pliku w /tmp):
docker run --rm \
  -v uptime_kuma_data:/target \
  -v /tmp:/backup:ro \
  alpine tar -xzf /backup/uptime_kuma_data_*.tar.gz -C /target

# Przywrócenie kopii stron WWW z hostingu LH.pl (w przypadku awarii hostingu LH):
mkdir -p /opt/devops-stack/backups/websites/restored
tar -xzf /tmp/lh_websites_backup_*.tar.gz -C /opt/devops-stack/backups/websites/restored/
```

### Krok 6: Poprawność uprawnień (Fix Permissions) (Czas: ~1 min)
Skrypt `restore-backup.sh` ustawia uprawnienia automatycznie. Przy odtwarzaniu ręcznym (Opcja C) zweryfikuj właścicieli non-root (UID `65534` oraz `472`):

```bash
# Uprawnienia Grafana (UID 472)
docker run --rm -v grafana_data:/target alpine chown -R 472:472 /target

# Uprawnienia Prometheus (UID 65534)
docker run --rm -v prometheus_data:/target alpine chown -R 65534:65534 /target
```

### Krok 7: Uruchomienie usług, runnerów CI/CD i harmonogramów systemd (Czas: ~2 min)
```bash
cd /opt/devops-stack/compose
# 1. Uruchomienie pełnego stacku (monitoring, AI Router, tunel Cloudflare oraz 3 runnery CI/CD)
docker compose --env-file /opt/devops-stack/.env -f docker-compose.yml -f extensions.yml -f runners.yml up -d --build

# 2. Odświeżenie pamięci podręcznej DNS (nscd) w Uptime Kuma oraz pre-warming Cache RAG (Quick Prompts)
docker exec uptime-kuma nscd -i hosts 2>/dev/null || true
bash /opt/devops-stack/scripts/warm-ai-cache.sh

# 3. Idempotentna instalacja i aktywacja harmonogramu nocnych backupów (03:00 UTC) oraz strażnika 24/7 (co 15 min)
sudo bash /opt/devops-stack/scripts/setup-audit-timer.sh
sudo bash /opt/devops-stack/scripts/setup-backup-timer.sh
```

---

## 3. Test Poprawności (Post-Recovery Checklist)

- [ ] Wszystkie 12 kontenerów ma status `Up (healthy)` / `running`.
- [ ] Runnery `runner-zeslownikiem-unified`, `runner-twojastronawww-unified` oraz `runner-gal-anonim-web` działają w odseparowanej sieci `devops_runners_network`.
- [ ] AI Router odpowiada na `curl -s http://127.0.0.1:8085/health`, ma rozgrzane wpisy Quick Prompts w `/app/storage/cache` (`warm-ai-cache.sh`) oraz eksportuje metryki pod `http://127.0.0.1:8085/metrics`.
- [ ] Uptime Kuma prezentuje wszystkie 10 monitorowanych witryn i usług (w tym `AI Router Healthcheck` = UP).
- [ ] Grafana uruchamia się w trybie PoLP `Viewer` z oboma dashboardami (`Centrum Monitoringu Stron WWW & Usług` oraz `AI Router - Gemini Proxy Monitor`) pod `http://127.0.0.1:3000`.
- [ ] Pełny audyt 5 warstw (`bash /opt/devops-stack/scripts/audit-server.sh` lub `npm run audit`) zwraca **`0 OSTRZEŻEŃ | 0 BŁĘDÓW`**.
- [ ] Timery systemd `devops-backup.timer` (03:00 UTC) oraz `devops-audit.timer` (co 15 min) są aktywne.


