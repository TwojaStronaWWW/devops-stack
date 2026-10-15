#!/usr/bin/env bash
# ==============================================================================
# audit-server.sh
# Kompleksowy, nieinwazyjny (Read-Only) audyt żywego serwera VPS (ISO 27001)
# Weryfikuje 5 warstw: Git Drift, Sekrety (.env), Hardening OS, Kontenery Docker,
# Endpointy HTTP oraz Backupy + eksportuje telemetrię do Prometheusa (audit.prom).
# ==============================================================================
set -uo pipefail

STACK_ROOT="${STACK_ROOT:-/opt/devops-stack}"
STRICT_MODE=false
if [[ "${1:-}" == "--strict" ]]; then
    STRICT_MODE=true
fi

# Kolory ANSI (wyłączane automatycznie przy braku terminala lub fladze NO_COLOR)
if [[ -z "${NO_COLOR:-}" ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_RED="\033[31m"
    C_CYAN="\033[36m"
else
    C_RESET=""
    C_BOLD=""
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
    C_CYAN=""
fi

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

GIT_SYNCED=1
ENV_VALID=1
OS_HARDENED=1
CONTAINERS_HEALTHY=1

REMEDIATION_HINTS=()

pass() {
    OK_COUNT=$((OK_COUNT + 1))
    printf "  ${C_GREEN}[OK]${C_RESET}   %s\n" "$1"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    printf "  ${C_YELLOW}[WARN]${C_RESET} %s\n" "$1"
    if [[ -n "${2:-}" ]]; then
        REMEDIATION_HINTS+=("WARN: $1 -> Naprawa: $2")
    fi
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf "  ${C_RED}[FAIL]${C_RESET} %s\n" "$1"
    if [[ -n "${2:-}" ]]; then
        REMEDIATION_HINTS+=("FAIL: $1 -> Naprawa: $2")
    fi
}

section() {
    printf "\n${C_BOLD}${C_CYAN}======================================================================${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}>> %s${C_RESET}\n" "$1"
    printf "${C_BOLD}${C_CYAN}======================================================================${C_RESET}\n"
}

NOW_HUMAN="$(date +'%Y-%m-%d %H:%M:%S %Z')"
HOST_NAME="$(hostname 2>/dev/null || echo 'vps')"
ARCH_NAME="$(uname -m 2>/dev/null || echo 'unknown')"

printf "${C_BOLD}======================================================================${C_RESET}\n"
printf "${C_BOLD}   AUDYT ŻYWEGO SERWERA VPS: %s (%s) | %s${C_RESET}\n" "${HOST_NAME}" "${ARCH_NAME}" "${NOW_HUMAN}"
printf "${C_BOLD}======================================================================${C_RESET}\n"

# ==============================================================================
# WARSTWA 1: SPÓJNOŚĆ REPOZYTORIUM GIT I PLIKÓW (CODE DRIFT)
# ==============================================================================
section "[1/5] WARSTWA 1: Spójność Repozytorium Git (${STACK_ROOT})"

if [[ ! -d "${STACK_ROOT}" ]]; then
    GIT_SYNCED=0
    fail "Katalog docelowy ${STACK_ROOT} nie istnieje na serwerze!" \
         "sudo git clone https://github.com/TwojaStronaWWW/devops-stack.git ${STACK_ROOT}"
else
    pass "Katalog roboczy ${STACK_ROOT} istnieje."
    if [[ -d "${STACK_ROOT}/.git" ]]; then
        cd "${STACK_ROOT}" || true
        CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
        LOCAL_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

        # Cichy fetch z timeoutem 8s
        timeout 8 git fetch origin main --quiet 2>/dev/null || true
        REMOTE_SHA="$(git rev-parse --short origin/main 2>/dev/null || echo 'unknown')"

        if [[ "${CURRENT_BRANCH}" == "main" ]]; then
            pass "Aktywna gałąź Git: main (commit: ${LOCAL_SHA})"
        else
            GIT_SYNCED=0
            warn "Serwer jest na gałęzi '${CURRENT_BRANCH}' zamiast 'main' (commit: ${LOCAL_SHA})" \
                 "cd ${STACK_ROOT} && git checkout main"
        fi

        if [[ "${LOCAL_SHA}" == "${REMOTE_SHA}" && "${LOCAL_SHA}" != "unknown" ]]; then
            pass "Kod na serwerze jest w 100% zsynchronizowany z GitHub origin/main (${LOCAL_SHA})."
        else
            GIT_SYNCED=0
            fail "Rozjazd wersji kodu! Serwer: ${LOCAL_SHA} vs GitHub origin/main: ${REMOTE_SHA}" \
                 "cd ${STACK_ROOT} && git fetch origin main && git reset --hard origin/main"
        fi

        DIRTY_FILES="$(git status --porcelain 2>/dev/null || true)"
        if [[ -z "${DIRTY_FILES}" ]]; then
            pass "Czyste drzewo robocze Git (brak ręcznie edytowanych lub nieśledzonych plików)."
        else
            GIT_SYNCED=0
            DIRTY_COUNT="$(echo "${DIRTY_FILES}" | wc -l | tr -d ' ')"
            warn "Wykryto ${DIRTY_COUNT} zmodyfikowanych/nieśledzonych plików na serwerze: $(echo "${DIRTY_FILES}" | tr '\n' ' ')" \
                 "cd ${STACK_ROOT} && git status (lub git reset --hard origin/main && git clean -fd)"
        fi
    else
        GIT_SYNCED=0
        fail "Katalog ${STACK_ROOT} nie jest repozytorium Git (.git nie istnieje)!"
    fi
fi

# ==============================================================================
# WARSTWA 2: SEKRETY, UPRAWNIENIA I KOMPLETNOŚĆ PLIKU .ENV (ISO 27001)
# ==============================================================================
section "[2/5] WARSTWA 2: Higiena Sekretów i Kompletność .env (ISO 27001)"

ENV_FILE="${STACK_ROOT}/.env"
ENV_EXAMPLE="${STACK_ROOT}/.env.example"

if [[ ! -f "${ENV_FILE}" ]]; then
    ENV_VALID=0
    fail "Brak pliku środowiskowego ${ENV_FILE}!" \
         "cp ${STACK_ROOT}/.env.example ${ENV_FILE} && chmod 600 ${ENV_FILE}"
else
    pass "Plik ${ENV_FILE} istnieje."

    ENV_PERMS="$(stat -c '%a' "${ENV_FILE}" 2>/dev/null || echo 'unknown')"
    ENV_OWNER="$(stat -c '%U' "${ENV_FILE}" 2>/dev/null || echo 'unknown')"

    if [[ "${ENV_PERMS}" == "600" ]]; then
        pass "Uprawnienia pliku .env są rygorystyczne: chmod 600 (właściciel: ${ENV_OWNER})."
    else
        ENV_VALID=0
        fail "Zbyt szerokie uprawnienia pliku .env: ${ENV_PERMS} (wymagane: 600)!" \
             "chmod 600 ${ENV_FILE}"
    fi

    # Weryfikacja kluczowych zmiennych produkcyjnych (bez wypisywania tajnych wartości!)
    REQUIRED_KEYS=(
        "GRAFANA_ADMIN_USER"
        "GRAFANA_ADMIN_PASSWORD"
        "CLOUDFLARE_TUNNEL_TOKEN"
        "GITHUB_TOKEN"
        "RUNNER_ORG_TOKEN"
        "RUNNER_TWOJASTRONAWWW_ORG_TOKEN"
        "GEMINI_API_KEY"
        "TZ"
    )

    OPTIONAL_KEYS=(
        "S3_ENDPOINT"
        "S3_BUCKET"
        "S3_ACCESS_KEY"
        "S3_SECRET_KEY"
        "LH_FTP_USERNAME"
        "LH_FTP_PASSWORD"
    )

    MISSING_REQUIRED=()
    PLACEHOLDER_KEYS=()

    for KEY in "${REQUIRED_KEYS[@]}"; do
        if ! grep -qE "^${KEY}=" "${ENV_FILE}" 2>/dev/null; then
            MISSING_REQUIRED+=("${KEY}")
        else
            VAL="$(grep -E "^${KEY}=" "${ENV_FILE}" | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')"
            if [[ -z "${VAL}" ]]; then
                MISSING_REQUIRED+=("${KEY} (pusty)")
            elif [[ "${VAL}" == *"ChangeMe_"* || "${VAL}" == *"example"* ]]; then
                PLACEHOLDER_KEYS+=("${KEY}")
            fi
        fi
    done

    if [[ ${#MISSING_REQUIRED[@]} -eq 0 ]]; then
        pass "Wszystkie krytyczne klucze produkcyjne (${#REQUIRED_KEYS[@]}) są zdefiniowane w .env."
    else
        ENV_VALID=0
        fail "Brakujące lub puste klucze wymagane w .env: ${MISSING_REQUIRED[*]}" \
             "Uzupełnij brakujące klucze w ${ENV_FILE} na podstawie KeePass (Databasekpoczatek.kdbx)"
    fi

    if [[ ${#PLACEHOLDER_KEYS[@]} -eq 0 ]]; then
        pass "Brak domyślnych haseł szablonowych (ChangeMe/example) w krytycznych kluczach .env."
    else
        ENV_VALID=0
        fail "Wykryto niewymienione wartości przykładowe (placeholder) w .env dla: ${PLACEHOLDER_KEYS[*]}" \
             "Zastąp wartości przykładowe w ${ENV_FILE} docelowymi sekretami z KeePass"
    fi

    # Porównanie wszystkich kluczy z .env.example
    if [[ -f "${ENV_EXAMPLE}" ]]; then
        EXAMPLE_KEYS="$(grep -E '^[A-Z0-9_]+=' "${ENV_EXAMPLE}" | cut -d'=' -f1)"
        UNLISTED_KEYS=()
        for EKEY in ${EXAMPLE_KEYS}; do
            if ! grep -qE "^${EKEY}=" "${ENV_FILE}" 2>/dev/null; then
                UNLISTED_KEYS+=("${EKEY}")
            fi
        done
        if [[ ${#UNLISTED_KEYS[@]} -eq 0 ]]; then
            pass "Pełna zgodność struktury .env z szablonem .env.example."
        else
            warn "Klucze z .env.example nieobecne w serwerowym .env: ${UNLISTED_KEYS[*]}" \
                 "Porównaj ${ENV_EXAMPLE} z ${ENV_FILE}"
        fi
    fi

    # Sprawdzenie kluczy opcjonalnych (Chmura S3 / Backup LH.pl)
    MISSING_OPT=()
    for OKEY in "${OPTIONAL_KEYS[@]}"; do
        OVAL="$(grep -E "^${OKEY}=" "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || true)"
        if [[ -z "${OVAL}" || "${OVAL}" == *"<account_id>"* ]]; then
            MISSING_OPT+=("${OKEY}")
        fi
    done
    if [[ ${#MISSING_OPT[@]} -eq 0 ]]; then
        pass "Klucze integracji chmurowej S3/R2 oraz LH.pl są skonfigurowane."
    else
        warn "Nieuzupełnione opcjonalne klucze backupu zewnętrznego (S3/LH.pl): ${MISSING_OPT[*]}"
    fi
fi

KUMA_PASS_FILE="${STACK_ROOT}/config/prometheus/kuma_password"
if [[ -f "${KUMA_PASS_FILE}" && -s "${KUMA_PASS_FILE}" ]]; then
    KUMA_PERMS="$(stat -c '%a' "${KUMA_PASS_FILE}" 2>/dev/null || echo 'unknown')"
    pass "Plik poświadczeń Prometheusa (kuma_password) istnieje (uprawnienia: ${KUMA_PERMS})."
else
    warn "Brak lub pusty plik ${KUMA_PASS_FILE} (Prometheus może nie pobierać metryk z Uptime Kuma)." \
         "Zapisz hasło do ${KUMA_PASS_FILE} i nadaj chown 65534:ubuntu oraz chmod 640"
fi

# ==============================================================================
# WARSTWA 3: BEZPIECZEŃSTWO SYSTEMU I SIECI (ISO 27001 / ZERO TRUST)
# ==============================================================================
section "[3/5] WARSTWA 3: Bezpieczeństwo Systemu Operacyjnego i Sieci"

# 1. Porty nasłuchujące na interfejsach publicznych (0.0.0.0 / [::])
EXPOSED_WEB_PORTS="$(ss -tuln 2>/dev/null | awk 'NR>1 {print $1, $5}' | grep -E '(0\.0\.0\.0:|\[::\]:)(80|443|3000|3001|8080|8085|8888|9090)$' || true)"
if [[ -z "${EXPOSED_WEB_PORTS}" ]]; then
    pass "Zero Trust WAN: Żaden port webowy/aplikacyjny nie nasłuchuje na 0.0.0.0 (wyłącznie 127.0.0.1)."
else
    OS_HARDENED=0
    fail "Wykryto porty aplikacji wystawione publicznie na 0.0.0.0: ${EXPOSED_WEB_PORTS}" \
         "Sprawdź sekcję ports w compose/*.yml i wymuś prefix 127.0.0.1:"
fi

# 2. Zapora UFW
if command -v ufw >/dev/null 2>&1; then
    UFW_OUT="$(sudo -n ufw status 2>/dev/null || ufw status 2>/dev/null || echo 'brak_uprawnien')"
    if echo "${UFW_OUT}" | grep -q "Status: active"; then
        pass "Zapora sieciowa UFW jest AKTYWNA."
        if echo "${UFW_OUT}" | grep -qE "22/tcp.*LIMIT"; then
            pass "Reguła ochrony SSH (22/tcp LIMIT IN) jest aktywna w UFW."
        else
            warn "Brak reguły LIMIT dla 22/tcp w UFW." "sudo ufw limit 22/tcp"
        fi
    elif [[ "${UFW_OUT}" == "brak_uprawnien" ]]; then
        warn "Nie można odczytać statusu UFW bez sudo."
    else
        OS_HARDENED=0
        fail "Zapora UFW jest NIEAKTYWNA!" "sudo bash ${STACK_ROOT}/scripts/01-harden-os.sh"
    fi
else
    OS_HARDENED=0
    fail "Pakiet UFW nie jest zainstalowany!" "sudo bash ${STACK_ROOT}/scripts/01-harden-os.sh"
fi

# 3. Fail2ban IPS
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    pass "Demon ochrony przed włamaniami Fail2Ban (IPS) działa (active)."
else
    OS_HARDENED=0
    fail "Usługa Fail2Ban NIE DZIAŁA!" "sudo systemctl enable --now fail2ban"
fi

# 4. SSH Hardening
if [[ -f /etc/ssh/sshd_config.d/99-security-hardening.conf ]]; then
    pass "Konfiguracja SSH Hardening (99-security-hardening.conf) jest wdrożona."
else
    warn "Brak pliku /etc/ssh/sshd_config.d/99-security-hardening.conf (sprawdź czy uruchomiono 01-harden-os.sh)." \
         "sudo bash ${STACK_ROOT}/scripts/01-harden-os.sh"
fi

# 5. Kernel sysctl & /dev/shm
SYNC_COOKIES="$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo '0')"
RP_FILTER="$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo '0')"
if [[ "${SYNC_COOKIES}" == "1" && "${RP_FILTER}" == "1" ]]; then
    pass "Parametry bezpieczeństwa jądra (tcp_syncookies=1, rp_filter=1) są aktywne."
else
    warn "Parametry sysctl nie są w pełni utwardzone (syncookies=${SYNC_COOKIES}, rp_filter=${RP_FILTER})." \
         "sudo sysctl --system"
fi

if mount | grep " /dev/shm " | grep -q "noexec"; then
    pass "Pamięć współdzielona /dev/shm posiada ochronę noexec."
else
    warn "Pamięć /dev/shm nie ma aktywnej flagi noexec." \
         "sudo mount -o remount,noexec,nosuid,nodev /dev/shm"
fi

# ==============================================================================
# WARSTWA 4: KONTENERY DOCKER, HEALTHCHECKI I SMOKE TESTY ENDPOINTÓW
# ==============================================================================
section "[4/5] WARSTWA 4: Kontenery Docker, Healthchecki i Endpointy HTTP"

if ! command -v docker >/dev/null 2>&1; then
    CONTAINERS_HEALTHY=0
    fail "Silnik Docker nie jest zainstalowany!" "sudo bash ${STACK_ROOT}/scripts/02-install-docker.sh"
else
    if docker network inspect devops_internal_network >/dev/null 2>&1; then
        pass "Izolowana sieć Docker 'devops_internal_network' istnieje."
    else
        CONTAINERS_HEALTHY=0
        fail "Brak sieci Docker 'devops_internal_network'!" \
             "cd ${STACK_ROOT}/compose && docker compose up -d"
    fi

    EXPECTED_CONTAINERS=(
        "uptime-kuma"
        "prometheus"
        "grafana"
        "node-exporter"
        "cadvisor"
        "dozzle"
        "github-exporter"
        "ai-router"
        "cloudflared"
        "runner-zeslownikiem-unified"
        "runner-twojastronawww-unified"
        "runner-gal-anonim-web"
    )

    for CNAME in "${EXPECTED_CONTAINERS[@]}"; do
        if ! docker inspect "${CNAME}" >/dev/null 2>&1; then
            CONTAINERS_HEALTHY=0
            fail "Kontener '${CNAME}' NIE ISTNIEJE (nie został uruchomiony)!" \
                 "cd ${STACK_ROOT}/compose && docker compose -f docker-compose.yml -f extensions.yml -f runners.yml up -d"
        else
            C_STATE="$(docker inspect -f '{{.State.Status}}' "${CNAME}" 2>/dev/null || echo 'unknown')"
            C_HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${CNAME}" 2>/dev/null || echo 'none')"
            C_RESTARTS="$(docker inspect -f '{{.RestartCount}}' "${CNAME}" 2>/dev/null || echo '0')"

            if [[ "${C_STATE}" == "running" ]]; then
                if [[ "${C_HEALTH}" == "healthy" || "${C_HEALTH}" == "none" ]]; then
                    if [[ "${C_RESTARTS}" -gt 3 ]]; then
                        warn "Kontener '${CNAME}' działa (${C_STATE}/${C_HEALTH}), ale miał ${C_RESTARTS} restartów." \
                             "docker logs --tail 50 ${CNAME}"
                    else
                        pass "Kontener '${CNAME}': ${C_STATE} (health: ${C_HEALTH}, restarty: ${C_RESTARTS})"
                    fi
                else
                    CONTAINERS_HEALTHY=0
                    fail "Kontener '${CNAME}' ma błędny status zdrowia: ${C_HEALTH} (restarty: ${C_RESTARTS})!" \
                         "docker logs --tail 50 ${CNAME}"
                fi
            else
                CONTAINERS_HEALTHY=0
                fail "Kontener '${CNAME}' NIE DZIAŁA (status: ${C_STATE}, restarty: ${C_RESTARTS})!" \
                     "docker logs --tail 50 ${CNAME}"
            fi
        fi
    done

    # Wykrywanie zatrzymanych / osieroconych kontenerów
    STOPPED_CONTAINERS="$(docker ps -a --filter "status=exited" --filter "status=dead" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ' || true)"
    if [[ -z "${STOPPED_CONTAINERS// /}" ]]; then
        pass "Brak martwych / zatrzymanych kontenerów na hoście."
    else
        warn "Wykryto zatrzymane kontenery (do wyczyszczenia): ${STOPPED_CONTAINERS}" \
             "docker container prune -f"
    fi

    # Smoke testy HTTP na 127.0.0.1
    check_http() {
        local name="$1"
        local url="$2"
        local code
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}" 2>/dev/null || echo '000')"
        if [[ "${code}" =~ ^(200|204|301|302)$ ]]; then
            pass "Smoke Test HTTP [${name}]: ${url} -> HTTP ${code}"
        else
            CONTAINERS_HEALTHY=0
            fail "Smoke Test HTTP [${name}] NIEUDANY: ${url} -> HTTP ${code}" \
                 "Sprawdź logi usługi: ${name}"
        fi
    }

    check_http "Grafana API" "http://127.0.0.1:3000/api/health"
    check_http "Prometheus"  "http://127.0.0.1:9090/-/healthy"
    check_http "Uptime Kuma" "http://127.0.0.1:3001"
    check_http "Dozzle Logs" "http://127.0.0.1:8888"
    check_http "AI Router"   "http://127.0.0.1:8085/health"

    # Sprawdzenie czy w Prometheusie wszystkie targety mają stan UP
    PROM_TARGETS="$(curl -s --max-time 5 "http://127.0.0.1:9090/api/v1/targets" 2>/dev/null || true)"
    if [[ -n "${PROM_TARGETS}" ]]; then
        DOWN_TARGETS="$(echo "${PROM_TARGETS}" | grep -o '"health":"down"' | wc -l | tr -d ' ')"
        UP_TARGETS="$(echo "${PROM_TARGETS}" | grep -o '"health":"up"' | wc -l | tr -d ' ')"
        if [[ "${DOWN_TARGETS}" -eq 0 && "${UP_TARGETS}" -gt 0 ]]; then
            pass "Prometheus Scrape Targets: wszystkie aktywne cele (${UP_TARGETS}) mają status UP."
        elif [[ "${DOWN_TARGETS}" -gt 0 ]]; then
            warn "Prometheus zgłasza ${DOWN_TARGETS} niedostępnych celów (health=down, up=${UP_TARGETS})." \
                 "Sprawdź http://localhost:9090/targets przez tunel SSH"
        fi
    fi

    # Sprawdzenie aktywnych alertów Prometheusa (rules/ai-router.yml) + wysyłka Push do Ntfy.sh
    PROM_ALERTS="$(curl -s --max-time 5 "http://127.0.0.1:9090/api/v1/alerts" 2>/dev/null || true)"
    if [[ -n "${PROM_ALERTS}" ]]; then
        FIRING_COUNT="$(echo "${PROM_ALERTS}" | grep -o '"state":"firing"' | wc -l | tr -d ' ')"
        if [[ "${FIRING_COUNT}" -eq 0 ]]; then
            pass "Reguły Alertów Prometheusa (AI Router): 0 aktywnych alarmów (firing=0)."
        else
            FIRING_NAMES="$(echo "${PROM_ALERTS}" | grep -oE '"alertname":"[^"]+"' | cut -d'"' -f4 | sort -u | tr '\n' ' ')"
            warn "Aktywne alarmy Prometheusa (firing=${FIRING_COUNT}): ${FIRING_NAMES}" \
                 "Sprawdź raport: bash ${STACK_ROOT}/scripts/ai-router-report.sh"
            NTFY_TOPIC_VAL="$(grep -E '^NTFY_TOPIC=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || echo 'kpoczatek-vps-alerty')"
            if [[ -n "${NTFY_TOPIC_VAL}" ]]; then
                curl -s --max-time 5 \
                    -H "Title: 🚨 Prometheus Alert (VPS AI Router)" \
                    -H "Priority: high" \
                    -H "Tags: rotating_light,robot" \
                    -d "Wykryto aktywne alarmy (${FIRING_COUNT}): ${FIRING_NAMES}" \
                    "https://ntfy.sh/${NTFY_TOPIC_VAL}" >/dev/null 2>&1 || true
            fi
        fi
    fi
fi

# ==============================================================================
# WARSTWA 5: ZASOBY SPRZĘTOWE (ALWAYS FREE), WOLUMENY I BACKUPY
# ==============================================================================
section "[5/5] WARSTWA 5: Zasoby Sprzętowe, Wolumeny i Ciągłość Backupów"

# 1. Zajętość dysku głównego
DISK_USE_PCT="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
DISK_AVAIL_HUMAN="$(df -h / | awk 'NR==2 {print $4}')"
if [[ "${DISK_USE_PCT}" -lt 75 ]]; then
    pass "Zajętość dysku systemowego (/): ${DISK_USE_PCT}% (wolne: ${DISK_AVAIL_HUMAN})."
elif [[ "${DISK_USE_PCT}" -lt 85 ]]; then
    warn "Zajętość dysku (/) wynosi już ${DISK_USE_PCT}% (wolne: ${DISK_AVAIL_HUMAN})." \
         "docker image prune -af"
else
    fail "Krytyczne zapełnienie dysku (/): ${DISK_USE_PCT}% (wolne: ${DISK_AVAIL_HUMAN})!" \
         "docker system prune -af (UWAGA: bez flagi --volumes!)"
fi

# 2. Pamięć RAM i SWAP
MEM_INFO="$(free -h | awk '/^Mem:/ {print "Użyte: "$3" / "$2" (Dostępne: "$7")"}')"
pass "Pamięć RAM hosta: ${MEM_INFO}"

# 3. Wolumeny danych
REQUIRED_VOLUMES=("uptime_kuma_data" "prometheus_data" "grafana_data" "ai_router_storage")
for VOL in "${REQUIRED_VOLUMES[@]}"; do
    if docker volume inspect "${VOL}" >/dev/null 2>&1; then
        pass "Trwały wolumen Docker '${VOL}' istnieje."
    else
        warn "Wolumen Docker '${VOL}' jeszcze nie istnieje."
    fi
done

# 4. Systemd timer dla backupów
if systemctl is-active --quiet devops-backup.timer 2>/dev/null; then
    pass "Harmonogram automatycznego backupu (devops-backup.timer) jest AKTYWNY."
else
    warn "Harmonogram systemd 'devops-backup.timer' NIE JEST AKTYWNY (backup nie uruchamia się automatycznie w nocy)." \
         "Skonfiguruj i włącz devops-backup.timer w /etc/systemd/system/"
fi

# 5. Telemetria backupów (*.prom)
PROM_DIR="${STACK_ROOT}/config/node-exporter"
BACKUP_PROM="${PROM_DIR}/backup.prom"
if [[ -f "${BACKUP_PROM}" ]]; then
    LAST_TS="$(awk '/^devops_backup_last_timestamp_seconds/ {print $2}' "${BACKUP_PROM}" 2>/dev/null || echo '0')"
    NOW_TS="$(date +%s)"
    if [[ "${LAST_TS}" -gt 0 ]]; then
        AGE_HOURS=$(( (NOW_TS - LAST_TS) / 3600 ))
        if [[ "${AGE_HOURS}" -le 26 ]]; then
            pass "Ostatni backup wolumenów wykonano ${AGE_HOURS}h temu (świeży < 26h)."
        else
            warn "Ostatni backup wolumenów jest przestarzały (wykonany ${AGE_HOURS}h temu)." \
                 "sudo bash ${STACK_ROOT}/scripts/backup-offsite.sh"
        fi
    fi
else
    warn "Brak pliku telemetrii ${BACKUP_PROM} (skrypt backup-offsite.sh nie był jeszcze uruchamiany)." \
         "sudo bash ${STACK_ROOT}/scripts/backup-offsite.sh"
fi

# ==============================================================================
# EKSPORT METRYK AUDYTU DO PROMETHEUSA / GRAFANY (config/node-exporter/audit.prom)
# ==============================================================================
if [[ -d "${PROM_DIR}" && -w "${PROM_DIR}" ]]; then
    AUDIT_PROM="${PROM_DIR}/audit.prom"
    AUDIT_TS="$(date +%s)"
    AUDIT_OVERALL=1
    if [[ "${FAIL_COUNT}" -gt 0 ]]; then
        AUDIT_OVERALL=0
    fi
    cat <<EOF > "${AUDIT_PROM}.tmp"
# HELP devops_audit_last_timestamp_seconds Czas uniksowy ostatniego audytu serwera
# TYPE devops_audit_last_timestamp_seconds gauge
devops_audit_last_timestamp_seconds ${AUDIT_TS}

# HELP devops_audit_status Ogolny status audytu serwera (1 = brak bledow, 0 = wykryto bledy)
# TYPE devops_audit_status gauge
devops_audit_status ${AUDIT_OVERALL}

# HELP devops_audit_ok_total Liczba testow zakonczonych sukcesem
# TYPE devops_audit_ok_total gauge
devops_audit_ok_total ${OK_COUNT}

# HELP devops_audit_warnings_total Liczba ostrzezen audytu
# TYPE devops_audit_warnings_total gauge
devops_audit_warnings_total ${WARN_COUNT}

# HELP devops_audit_errors_total Liczba bledow krytycznych audytu
# TYPE devops_audit_errors_total gauge
devops_audit_errors_total ${FAIL_COUNT}

# HELP devops_audit_git_synced Status synchronizacji repozytorium Git z origin/main (1 = zgodny, 0 = rozjazd)
# TYPE devops_audit_git_synced gauge
devops_audit_git_synced ${GIT_SYNCED}

# HELP devops_audit_env_valid Status kompletnosci i uprawnien pliku .env (1 = poprawny, 0 = blad)
# TYPE devops_audit_env_valid gauge
devops_audit_env_valid ${ENV_VALID}

# HELP devops_audit_os_hardened Status utwardzenia systemu i zapory UFW/Fail2ban (1 = bezpieczny, 0 = blad)
# TYPE devops_audit_os_hardened gauge
devops_audit_os_hardened ${OS_HARDENED}

# HELP devops_audit_containers_healthy Status kondycji wszystkich kontenerow i endpointow (1 = zdrowe, 0 = blad)
# TYPE devops_audit_containers_healthy gauge
devops_audit_containers_healthy ${CONTAINERS_HEALTHY}
EOF
    mv "${AUDIT_PROM}.tmp" "${AUDIT_PROM}"
    chmod 644 "${AUDIT_PROM}" 2>/dev/null || true
fi

# ==============================================================================
# PODSUMOWANIE I REKOMENDACJE NAPRAWCZE
# ==============================================================================
printf "\n${C_BOLD}======================================================================${C_RESET}\n"
printf "${C_BOLD}PODSUMOWANIE AUDYTU:${C_RESET} ${C_GREEN}%d OK${C_RESET} | ${C_YELLOW}%d OSTRZEŻEŃ${C_RESET} | ${C_RED}%d BŁĘDÓW${C_RESET}\n" "${OK_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"
printf "${C_BOLD}======================================================================${C_RESET}\n"

if [[ ${#REMEDIATION_HINTS[@]} -gt 0 ]]; then
    printf "\n${C_BOLD}ZALECANE DZIAŁANIA NAPRAWCZE (REFAKTORING / REKONCYLIACJA):${C_RESET}\n"
    IDX=1
    for HINT in "${REMEDIATION_HINTS[@]}"; do
        printf "  %d. %s\n" "${IDX}" "${HINT}"
        IDX=$((IDX + 1))
    done
    printf "\n"
fi

if [[ "${STRICT_MODE}" == "true" && "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi
exit 0
