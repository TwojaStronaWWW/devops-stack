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
FORCE_MORNING_REPORT=false
for arg in "$@"; do
    case "${arg}" in
        --strict) STRICT_MODE=true ;;
        --morning-report) FORCE_MORNING_REPORT=true ;;
    esac
done

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
        "BACKUP_ENCRYPTION_KEY"
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

    # Weryfikacja czy NTFY_TOPIC nie jest słownikowym, publicznie znanym tematem
    NTFY_CUR_VAL="$(grep -E '^NTFY_TOPIC=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || true)"
    if [[ -n "${NTFY_CUR_VAL}" && "${NTFY_CUR_VAL}" != "twojastronawww-alerty-prod" && "${#NTFY_CUR_VAL}" -ge 24 ]]; then
        pass "Kanał Ntfy (NTFY_TOPIC) posiada kryptograficzny, niepubliczny identyfikator."
    else
        warn "Zmienna NTFY_TOPIC w .env jest zbyt krótka lub używa publicznego szablonu (ryzyko podsłuchu powiadomień)." \
             "Ustaw losowy NTFY_TOPIC (min. 24 znaki) w ${ENV_FILE} oraz w aplikacji Ntfy"
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

    # Sprawdzenie kluczy opcjonalnych (Chmura S3 / Szyfrowanie AES-256 / Backup LH.pl)
    MISSING_OPT=()
    for OKEY in "${OPTIONAL_KEYS[@]}"; do
        OVAL="$(grep -E "^${OKEY}=" "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || true)"
        if [[ -z "${OVAL}" || "${OVAL}" == *"<account_id>"* || "${OVAL}" == *"ChangeMe_"* ]]; then
            MISSING_OPT+=("${OKEY}")
        fi
    done
    if [[ ${#MISSING_OPT[@]} -eq 0 ]]; then
        pass "Klucze integracji chmurowej S3/R2, szyfrowania AES-256 oraz LH.pl są skonfigurowane."
    else
        warn "Nieuzupełnione klucze backupu/szyfrowania (S3/AES-256/LH.pl): ${MISSING_OPT[*]}"
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

# 1. Porty nasłuchujące na interfejsach publicznych (0.0.0.0 / [::]) - w tym rpcbind (111)
EXPOSED_WEB_PORTS="$(ss -tuln 2>/dev/null | awk 'NR>1 {print $1, $5}' | grep -E '(0\.0\.0\.0:|\[::\]:)(80|111|443|3000|3001|8080|8085|8888|9090)$' || true)"
if [[ -z "${EXPOSED_WEB_PORTS}" ]]; then
    pass "Zero Trust WAN: Żaden port webowy/aplikacyjny ani rpcbind (111) nie nasłuchuje na 0.0.0.0 (wyłącznie 127.0.0.1)."
else
    OS_HARDENED=0
    fail "Wykryto zbędne porty wystawione publicznie na 0.0.0.0: ${EXPOSED_WEB_PORTS}" \
         "Wyłącz rpcbind (sudo systemctl disable --now rpcbind.service rpcbind.socket) i sprawdź compose/*.yml"
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

if [[ -f /var/run/reboot-required ]]; then
    warn "System oczekuje na restart po aktualizacji jądra/pakietów (/var/run/reboot-required)." \
         "Zaplanuj okno serwisowe i wykonaj: sudo reboot"
else
    pass "Jądro systemu jest aktualne (brak oczekującego restartu /var/run/reboot-required)."
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
        pass "Izolowana sieć wewnętrzna 'devops_internal_network' istnieje."
    else
        CONTAINERS_HEALTHY=0
        fail "Brak sieci Docker 'devops_internal_network'!" \
             "cd ${STACK_ROOT}/compose && docker compose up -d"
    fi

    if docker network inspect devops_runners_network >/dev/null 2>&1; then
        pass "Odseparowana sieć runnerów CI/CD 'devops_runners_network' istnieje (Zero-Trust)."
    else
        warn "Brak odseparowanej sieci 'devops_runners_network' dla runnerów CI/CD." \
             "cd ${STACK_ROOT}/compose && docker compose -f runners.yml up -d"
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

            # Jeśli kontener został świeżo utworzony podczas deployu i jest w fazie 'starting', poczekaj na pierwszy wynik healthchecka
            if [[ "${C_STATE}" == "running" && "${C_HEALTH}" == "starting" ]]; then
                for _wait_hc in {1..18}; do
                    sleep 2
                    C_HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${CNAME}" 2>/dev/null || echo 'none')"
                    [[ "${C_HEALTH}" != "starting" ]] && break
                done
            fi

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

    # Weryfikacja wymogu hasła w Uptime Kuma (ochrona przed disableAuth=true / auto-loginem z WAN)
    KUMA_UNAUTH_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 "http://127.0.0.1:3001/metrics" 2>/dev/null || echo "000")"
    if [[ "${KUMA_UNAUTH_CODE}" == "401" ]]; then
        pass "Ochrona Uptime Kuma Auth: autoryzacja hasłem AKTYWNA (brak dostępu bez hasła -> HTTP 401)."
    else
        KUMA_DB="/var/lib/docker/volumes/uptime_kuma_data/_data/kuma.db"
        if sudo test -f "${KUMA_DB}" && command -v python3 >/dev/null 2>&1; then
            sudo python3 -c "import sqlite3; c=sqlite3.connect('${KUMA_DB}'); c.execute(\"UPDATE setting SET value='false' WHERE key='disableAuth'\"); c.commit()" 2>/dev/null || true
            docker restart uptime-kuma >/dev/null 2>&1 || true
            warn "Wykryto wyłączone hasło w Uptime Kuma (disableAuth=true) — automatycznie przywrócono wymóg hasła i zrestartowano kontener!"
        else
            fail "Uptime Kuma NIE WYMAGA HASŁA (HTTP ${KUMA_UNAUTH_CODE} na /metrics bez autoryzacji)!" \
                 "Włącz uwierzytelnianie w ustawieniach Uptime Kuma (Security -> Enable Auth)"
        fi
    fi

    # Weryfikacja gotowości tunelu krawędziowego Cloudflare Zero Trust wewnątrz sieci Dockera
    if docker exec prometheus wget -q -T 4 --spider "http://cloudflared:2000/ready" >/dev/null 2>&1; then
        pass "Smoke Test Tunelu [cloudflared]: http://cloudflared:2000/ready -> Połączenie QUIC aktywne (READY)"
    else
        warn "Endpoint gotowości tunelu cloudflared (http://cloudflared:2000/ready) nie odpowiedział (sprawdź logi cloudflared)." \
             "docker logs --tail 30 cloudflared"
    fi

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

    # Sprawdzenie statusu monitorowanych stron i usług w Uptime Kuma (metryka monitor_status)
    KUMA_MONITORS="$(curl -s --max-time 5 "http://127.0.0.1:9090/api/v1/query?query=monitor_status" 2>/dev/null || true)"
    if [[ -n "${KUMA_MONITORS}" ]]; then
        KUMA_UP_COUNT="$(echo "${KUMA_MONITORS}" | grep -oE ',"1"\]\}' | wc -l | tr -d ' ')"
        KUMA_DOWN_COUNT="$(echo "${KUMA_MONITORS}" | grep -oE ',"0"\]\}' | wc -l | tr -d ' ')"
        if [[ "${KUMA_DOWN_COUNT}" -eq 0 && "${KUMA_UP_COUNT}" -gt 0 ]]; then
            pass "Uptime Kuma Monitors: wszystkie monitorowane witryny i usługi (${KUMA_UP_COUNT}) mają status UP."
        elif [[ "${KUMA_DOWN_COUNT}" -gt 0 ]]; then
            # Samonaprawa cache DNS (nscd) w Uptime Kuma, jeśli ai-router zmienił wewnętrzne IP po przebudowie
            docker exec uptime-kuma nscd -i hosts >/dev/null 2>&1 || true
            warn "Uptime Kuma zgłasza ${KUMA_DOWN_COUNT} niedostępnych monitorów (UP=${KUMA_UP_COUNT}, odświeżono cache DNS nscd)." \
                 "Sprawdź panel Uptime Kuma (http://127.0.0.1:3001)"
        fi
    fi

    # Sprawdzenie aktywnych alertów Prometheusa (rules/ai-router.yml, poziom warning/critical w stanie firing) + wysyłka Push do Ntfy.sh
    PROM_ALERTS="$(curl -s --max-time 5 "http://127.0.0.1:9090/api/v1/alerts" 2>/dev/null || true)"
    if [[ -n "${PROM_ALERTS}" ]]; then
        FIRING_BLOCKS="$(echo "${PROM_ALERTS}" | sed 's/},{"labels":/}\n{"labels":/g' | grep '"state":"firing"' | grep -E '"severity":"(warning|critical)"' || true)"
        if [[ -z "${FIRING_BLOCKS}" ]]; then
            pass "Reguły Alertów Prometheusa (AI Router & Infrastruktura): 0 aktywnych alarmów (warning/critical firing=0)."
            rm -f /tmp/devops_ntfy_alert_dedup.state 2>/dev/null || true
        else
            FIRING_COUNT="$(echo "${FIRING_BLOCKS}" | wc -l | tr -d ' ')"
            FIRING_NAMES="$(echo "${FIRING_BLOCKS}" | grep -oE '"alertname":"[^"]+"' | cut -d'"' -f4 | sort -u | tr '\n' ' ')"
            FIRING_SUMMARIES="$(echo "${FIRING_BLOCKS}" | grep -oE '"summary":"[^"]+"' | cut -d'"' -f4 | sort -u | sed 's/^/• /' || echo '')"
            warn "Aktywne alarmy Prometheusa (firing=${FIRING_COUNT}): ${FIRING_NAMES}" \
                 "Sprawdź raport: bash ${STACK_ROOT}/scripts/ai-router-report.sh"
            NTFY_TOPIC_VAL="$(grep -E '^NTFY_TOPIC=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || echo '')"
            if [[ -n "${NTFY_TOPIC_VAL}" ]]; then
                DEDUP_FILE="/tmp/devops_ntfy_alert_dedup.state"
                NOW_EPOCH="$(date +%s)"
                SEND_NTFY=1
                if [[ -f "${DEDUP_FILE}" ]]; then
                    LAST_SIG="$(head -n1 "${DEDUP_FILE}" 2>/dev/null || echo '')"
                    LAST_SENT="$(tail -n1 "${DEDUP_FILE}" 2>/dev/null || echo '0')"
                    if [[ "${LAST_SIG}" == "${FIRING_NAMES}" && $((NOW_EPOCH - LAST_SENT)) -lt 7200 ]]; then
                        SEND_NTFY=0
                    fi
                fi
                if [[ "${SEND_NTFY}" -eq 1 ]]; then
                    printf "%s\n%s\n" "${FIRING_NAMES}" "${NOW_EPOCH}" > "${DEDUP_FILE}" 2>/dev/null || true
                    ALERT_MSG="Wykryto aktywne alarmy (${FIRING_COUNT}): ${FIRING_NAMES}"
                    if [[ -n "${FIRING_SUMMARIES}" ]]; then
                        ALERT_MSG="${ALERT_MSG}"$'\n\n'"Szczegóły:"$'\n'"${FIRING_SUMMARIES}"
                    fi
                    curl -s --max-time 5 \
                        -H "Title: 🚨 Prometheus Alert (VPS Stack)" \
                        -H "Priority: high" \
                        -H "Tags: rotating_light,robot" \
                        -d "${ALERT_MSG}" \
                        "https://ntfy.sh/${NTFY_TOPIC_VAL}" >/dev/null 2>&1 || true
                fi
            fi
        fi
    fi

    # 5c. Kontrola autoryzacji GitHub PAT (github-exporter -> github_repo_created_timestamp > 0 & github_request_failures_total == 0)
    GH_REPOS_COUNT="$(curl -sG --max-time 4 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=count(github_repo_created_timestamp)' 2>/dev/null | grep -oE '"[0-9]+"\]' | tr -d '"[]' | head -n1 || echo '0')"
    GH_FAILURES="$(curl -sG --max-time 4 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=sum(github_request_failures_total)' 2>/dev/null | grep -oE '"[0-9]+"\]' | tr -d '"[]' | head -n1 || echo '0')"
    if [[ "${GH_REPOS_COUNT:-0}" -gt 0 ]] && [[ "${GH_FAILURES:-0}" -eq 0 ]]; then
        pass "Tokeny GitHub PAT (github-exporter) są aktywne i autoryzowane (monitorowane repozytoria: ${GH_REPOS_COUNT}, błędy API: 0)."
    else
        warn "Exporter GitHub zgłasza problem z API GitHub (repozytoria: ${GH_REPOS_COUNT:-0}, błędy: ${GH_FAILURES:-0} — sprawdź ważność GITHUB_PAT_* w .env)."
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

# 2. Pamięć RAM, SWAP i Bufor Ochronny OCI Keepalive (>20% alokacji RAM przeciwko Idle Instance Reclamation)
OCI_BUFFER_FILE="/dev/shm/.oci-keepalive-buffer"
OCI_BUFFER_TARGET_MB=4864
OCI_BUFFER_BYTES=0
MEM_TOTAL_MB="$(free -m | awk '/^Mem:/ {print $2}')"
if [[ "${MEM_TOTAL_MB:-0}" -gt 16000 && -d /dev/shm && -w /dev/shm ]]; then
    CURRENT_BUF_MB=0
    if [[ -f "${OCI_BUFFER_FILE}" ]]; then
        CURRENT_BUF_MB=$(( $(wc -c < "${OCI_BUFFER_FILE}" 2>/dev/null | tr -d ' ' || echo 0) / 1048576 ))
    fi
    if [[ "${CURRENT_BUF_MB}" -lt "${OCI_BUFFER_TARGET_MB}" ]]; then
        dd if=/dev/zero of="${OCI_BUFFER_FILE}" bs=1M count="${OCI_BUFFER_TARGET_MB}" status=none 2>/dev/null || true
        chmod 600 "${OCI_BUFFER_FILE}" 2>/dev/null || true
    fi
    OCI_BUFFER_BYTES="$(wc -c < "${OCI_BUFFER_FILE}" 2>/dev/null | tr -d ' ' || echo 0)"
fi
MEM_INFO="$(free -h | awk '/^Mem:/ {print "Użyte przez usługi: "$3" / "$2" (Dostępne: "$7")"}')"
pass "Pamięć RAM hosta: ${MEM_INFO} + Bufor Ochronny OCI: $(( OCI_BUFFER_BYTES / 1048576 )) MiB (>20% RAM)."

# 2a. Higiena obrazów Dockera (wykrywanie i samonaprawa osieroconych warstw <none>)
DANGLING_IMAGES="$(docker images -f "dangling=true" -q 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${DANGLING_IMAGES:-0}" -gt 0 ]]; then
    docker image prune -f >/dev/null 2>&1 || true
    pass "Autonomiczny Garbage Collector: oczyszczono ${DANGLING_IMAGES} osieroconych warstw obrazów Dockera (<none>)."
else
    pass "Higiena obrazów Dockera: brak osieroconych warstw (<none> / dangling=0)."
fi

# 2b. Kontrola rozrostu plików logów kontenerów Dockera (wykrywanie spamu logów > 15 MB)
LARGE_LOGS_COUNT="$(sudo find /var/lib/docker/containers -name "*-json.log" -size +15M 2>/dev/null | wc -l | tr -d ' ' || echo '0')"
if [[ "${LARGE_LOGS_COUNT:-0}" -eq 0 ]]; then
    pass "Higiena logów kontenerów: żaden plik *-json.log nie przekracza 15 MB."
else
    warn "Wykryto ${LARGE_LOGS_COUNT} plików logów kontenerów powyżej 15 MB (możliwy spam błędów w logach)." \
         "sudo du -sh /var/lib/docker/containers/*/*-json.log | sort -hr | head -n 5"
fi

# 3. Wolumeny danych
REQUIRED_VOLUMES=("uptime_kuma_data" "prometheus_data" "grafana_data" "ai_router_storage")
for VOL in "${REQUIRED_VOLUMES[@]}"; do
    if docker volume inspect "${VOL}" >/dev/null 2>&1; then
        pass "Trwały wolumen Docker '${VOL}' istnieje."
    else
        warn "Wolumen Docker '${VOL}' jeszcze nie istnieje."
    fi
done

# 4. Systemd timery dla backupów i audytu 24/7
if systemctl is-active --quiet devops-backup.timer 2>/dev/null; then
    pass "Harmonogram automatycznego backupu (devops-backup.timer) jest AKTYWNY."
else
    warn "Harmonogram systemd 'devops-backup.timer' NIE JEST AKTYWNY (backup nie uruchamia się automatycznie w nocy)." \
         "sudo bash ${STACK_ROOT}/scripts/setup-backup-timer.sh"
fi

if systemctl is-active --quiet devops-audit.timer 2>/dev/null; then
    pass "Autonomiczny Strażnik 24/7 (devops-audit.timer co 15 min) jest AKTYWNY."
else
    warn "Harmonogram systemd 'devops-audit.timer' NIE JEST AKTYWNY." \
         "sudo bash ${STACK_ROOT}/scripts/setup-audit-timer.sh"
fi

# 5. Telemetria backupów (*.prom: wolumeny VPS oraz strony WWW z LH.pl)
PROM_DIR="${STACK_ROOT}/config/node-exporter"
BACKUP_PROM="${PROM_DIR}/backup.prom"
if [[ -f "${BACKUP_PROM}" ]]; then
    LAST_TS="$(awk '/^devops_backup_last_timestamp_seconds/ {print $2}' "${BACKUP_PROM}" 2>/dev/null || echo '0')"
    B_STATUS="$(awk '/^devops_backup_status/ {print $2}' "${BACKUP_PROM}" 2>/dev/null || echo '0')"
    NOW_TS="$(date +%s)"
    if [[ "${LAST_TS}" -gt 0 ]]; then
        AGE_HOURS=$(( (NOW_TS - LAST_TS) / 3600 ))
        if [[ "${B_STATUS}" == "1" && "${AGE_HOURS}" -le 26 ]]; then
            pass "Ostatni backup wolumenów VPS wykonano ${AGE_HOURS}h temu (status=OK, świeży < 26h)."
        else
            warn "Backup wolumenów VPS wymaga uwagi (status=${B_STATUS}, wiek=${AGE_HOURS}h)." \
                 "bash ${STACK_ROOT}/scripts/backup-offsite.sh"
        fi
    fi
else
    warn "Brak pliku telemetrii ${BACKUP_PROM} (skrypt backup-offsite.sh nie był jeszcze uruchamiany)." \
         "bash ${STACK_ROOT}/scripts/backup-offsite.sh"
fi

WEBSITES_PROM="${PROM_DIR}/backup_websites.prom"
if [[ -f "${WEBSITES_PROM}" ]]; then
    W_LAST_TS="$(awk '/^devops_backup_websites_last_timestamp_seconds/ {print $2}' "${WEBSITES_PROM}" 2>/dev/null || echo '0')"
    W_STATUS="$(awk '/^devops_backup_websites_status/ {print $2}' "${WEBSITES_PROM}" 2>/dev/null || echo '0')"
    NOW_TS="$(date +%s)"
    if [[ "${W_LAST_TS}" -gt 0 ]]; then
        W_AGE_HOURS=$(( (NOW_TS - W_LAST_TS) / 3600 ))
        if [[ "${W_STATUS}" == "1" && "${W_AGE_HOURS}" -le 26 ]]; then
            pass "Ostatni backup stron WWW (LH.pl) wykonano ${W_AGE_HOURS}h temu (status=OK, świeży < 26h)."
        else
            warn "Backup stron WWW (LH.pl) wymaga uwagi lub nie wykonał się w nocy (status=${W_STATUS}, wiek=${W_AGE_HOURS}h)." \
                 "bash ${STACK_ROOT}/scripts/backup-websites-lh.sh"
        fi
    fi
else
    warn "Brak pliku telemetrii ${WEBSITES_PROM} (skrypt backup-websites-lh.sh nie był jeszcze uruchamiany)." \
         "bash ${STACK_ROOT}/scripts/backup-websites-lh.sh"
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

# HELP devops_oci_keepalive_buffer_bytes Rozmiar bufora ochronnego RAM w /dev/shm chroniacego przed Oracle Idle Instance Reclamation
# TYPE devops_oci_keepalive_buffer_bytes gauge
devops_oci_keepalive_buffer_bytes ${OCI_BUFFER_BYTES:-0}
EOF
    mv "${AUDIT_PROM}.tmp" "${AUDIT_PROM}"
    chmod 644 "${AUDIT_PROM}" 2>/dev/null || true
fi

# Powiadomienia Push na Ntfy.sh:
# 1. Natychmiastowy alert przy błędach krytycznych (FAIL_COUNT > 0)
# 2. Alert ostrzeżeń (WARN_COUNT > 0, max raz na 6h, aby unikać spamu)
# 3. Codzienny Poranny Raport Bezpieczeństwa o 08:00 rano (Europe/Warsaw) lub z flagą --morning-report
if [[ -f "${ENV_FILE}" ]]; then
    NTFY_AUDIT_TOPIC="$(grep -E '^NTFY_TOPIC=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || echo '')"
    if [[ -n "${NTFY_AUDIT_TOPIC}" ]]; then
        HINTS_SUMMARY=""
        if [[ ${#REMEDIATION_HINTS[@]} -gt 0 ]]; then
            HINTS_SUMMARY="$(printf '\n• %s' "${REMEDIATION_HINTS[@]}")"
        fi

        if [[ "${FAIL_COUNT}" -gt 0 ]]; then
            curl -s --max-time 5 \
                -H "Title: Audyt VPS: Wykryto ${FAIL_COUNT} bledow!" \
                -H "Priority: high" \
                -H "Tags: rotating_light,shield" \
                -d "Audyt (${HOST_NAME}): ${OK_COUNT} OK | ${WARN_COUNT} WARN | ${FAIL_COUNT} FAIL.${HINTS_SUMMARY}" \
                "https://ntfy.sh/${NTFY_AUDIT_TOPIC}" >/dev/null 2>&1 || true
        elif [[ "${WARN_COUNT}" -gt 0 ]]; then
            WARN_STAMP_FILE="/var/tmp/devops-warn-alert.ts"
            LAST_WARN_TS="$(cat "${WARN_STAMP_FILE}" 2>/dev/null || echo 0)"
            NOW_TS="$(date +%s)"
            if [[ $((NOW_TS - LAST_WARN_TS)) -ge 21600 ]]; then
                echo "${NOW_TS}" > "${WARN_STAMP_FILE}" 2>/dev/null || true
                curl -s --max-time 5 \
                    -H "Title: Audyt VPS: ${WARN_COUNT} ostrzezen" \
                    -H "Priority: default" \
                    -H "Tags: warning,shield" \
                    -d "Audyt (${HOST_NAME}): ${OK_COUNT} OK | ${WARN_COUNT} WARN | 0 FAIL.${HINTS_SUMMARY}" \
                    "https://ntfy.sh/${NTFY_AUDIT_TOPIC}" >/dev/null 2>&1 || true
            fi
        fi

        # Codzienny Poranny Raport o 08:00 rano (Europe/Warsaw) lub wymuszony przez --morning-report
        PL_HOUR="$(TZ=Europe/Warsaw date +%H 2>/dev/null || date +%H)"
        PL_DATE="$(TZ=Europe/Warsaw date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"
        MORNING_STAMP_FILE="/var/tmp/devops-morning-digest.date"
        LAST_MORNING_DATE="$(cat "${MORNING_STAMP_FILE}" 2>/dev/null || echo '')"

        if [[ "${FORCE_MORNING_REPORT}" == "true" ]] || [[ "${PL_HOUR}" == "08" && "${LAST_MORNING_DATE}" != "${PL_DATE}" ]]; then
            echo "${PL_DATE}" > "${MORNING_STAMP_FILE}" 2>/dev/null || true
            F2B_BANNED="$(sudo fail2ban-client status sshd 2>/dev/null | awk -F: '/Total banned/ {gsub(/[ \t]/,"",$2); print $2}' || echo '0')"

            # Zbieranie Głębokiego Rentgena (Deep X-Ray) dla modelu Claude Sonnet 4.6
            ANTHROPIC_KEY="$(grep -E '^ANTHROPIC_API_KEY=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || echo '')"
            AI_AUDIT_INSIGHT=""
            if [[ -n "${ANTHROPIC_KEY}" ]] && command -v python3 >/dev/null 2>&1; then
                XRAY_FILE="/var/tmp/devops-xray.txt"
                {
                    echo "=== WYNIK SKRYPTU AUDYTU ==="
                    echo "Data: ${PL_DATE} | Wynik: ${OK_COUNT} OK, ${WARN_COUNT} WARN, ${FAIL_COUNT} FAIL"
                    echo "Dysk: ${DISK_USE_PCT}% (wolne ${DISK_AVAIL_HUMAN}) | RAM: ${MEM_INFO} | Bufor OCI: $(( OCI_BUFFER_BYTES / 1048576 )) MiB"
                    echo "Backupy: VPS ${AGE_HOURS:-?}h temu | WWW LH.pl ${W_AGE_HOURS:-?}h temu | Fail2ban zbanowane IP: ${F2B_BANNED:-0}"
                    if [[ -n "${HINTS_SUMMARY}" ]]; then
                        echo "Wykryte wskazowki: ${HINTS_SUMMARY}"
                    fi
                    echo "=== ROZMIARY LOGOW KONTENEROW (TOP 5) ==="
                    sudo sh -c 'du -sh /var/lib/docker/containers/*/*-json.log 2>/dev/null | sort -hr | head -n 5' || true
                    echo "=== USTAWIENIA BEZPIECZENSTWA UPTIME KUMA (kuma.db) ==="
                    sudo python3 -c "import sqlite3; c=sqlite3.connect('/var/lib/docker/volumes/uptime_kuma_data/_data/kuma.db'); print(c.execute(\"SELECT key, value FROM setting WHERE key IN ('disableAuth','tlsExpiryNotifyDays','keepDataPeriodDays')\").fetchall())" 2>/dev/null || true
                    echo "=== REGULY INGRESS CLOUDFLARED ==="
                    docker logs cloudflared 2>&1 | grep -i "Updated to new configuration" | tail -n 1 || true
                    echo "=== OSTATNIE LOGI KONTENEROW (OSTRZEZENIA I BLEDY) ==="
                    for cname in $(docker ps --format '{{.Names}}' 2>/dev/null); do
                        echo "--- [${cname}] ---"
                        docker logs --tail 6 "${cname}" 2>&1 | tr -d '\000' | cut -c 1-240 || true
                    done
                    echo "=== BLEDY SYSTEMOWE (journalctl 24h) ==="
                    sudo journalctl -p err..emerg --since "24 hours ago" --no-pager 2>/dev/null | tail -n 10 || true
                } > "${XRAY_FILE}" 2>/dev/null

                AI_AUDIT_INSIGHT="$(sudo ENV_FILE="${ENV_FILE}" XRAY_FILE="${XRAY_FILE}" python3 - << 'PYEOF' 2>/dev/null || true
import json, os, urllib.request

env_path = os.environ.get("ENV_FILE", "/opt/devops-stack/.env")
key = ""
if os.path.exists(env_path):
    with open(env_path, "r", encoding="utf-8", errors="ignore") as ef:
        for line in ef:
            if line.startswith("ANTHROPIC_API_KEY="):
                key = line.split("=", 1)[1].strip().strip("\"'")

xray_path = os.environ.get("XRAY_FILE", "")
budget_path = "/var/lib/docker/volumes/ai_router_storage/_data/anthropic_budget.json"

with open(xray_path, "r", encoding="utf-8", errors="replace") as f:
    xray_text = f.read()[:12000]

sys_prompt = (
    "Jesteś Głównym Audytorem Bezpieczeństwa DevOps (ISO 27001) serwera TwojaStronaWWW (Oracle Cloud ARM64). "
    "Przeanalizuj poranny Rentgen serwera (logi kontenerów, rozmiary logów, ustawienia bazy Uptime Kuma, reguły tunelu Cloudflare, błędy journalctl). "
    "Napisz po polsku bardzo zwięzłą, kompletną diagnozę (maksymalnie 3 krótkie wypunktowania, łącznie do 450 znaków, nigdy nie ucinaj zdań): "
    "1) Czy w logach kontenerów lub systemie widać jakiekolwiek ciche błędy/anomalie, "
    "2) Stan ochrony Zero Trust i backupów, "
    "3) Ewentualna rekomendacja (lub potwierdzenie 100% czystości)."
)

payload = {
    "model": "claude-sonnet-4-6",
    "max_tokens": 400,
    "system": [{"type": "text", "text": sys_prompt, "cache_control": {"type": "ephemeral"}}],
    "messages": [{"role": "user", "content": xray_text}]
}

req = urllib.request.Request(
    "https://api.anthropic.com/v1/messages",
    data=json.dumps(payload).encode("utf-8"),
    headers={
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json"
    },
    method="POST"
)

with urllib.request.urlopen(req, timeout=25) as resp:
    data = json.loads(resp.read().decode("utf-8"))

answer = ""
for block in data.get("content", []):
    if block.get("type") == "text":
        answer += block.get("text", "").strip()

usage = data.get("usage", {})
in_tok = int(usage.get("input_tokens", 0))
out_tok = int(usage.get("output_tokens", 0))
cache_w = int(usage.get("cache_creation_input_tokens", 0))
cache_r = int(usage.get("cache_read_input_tokens", 0))
total_tok_today = in_tok + out_tok + cache_w + cache_r

# Cennik Claude Sonnet 4.6: $3/1M input, $15/1M output, $3.75/1M cache_write, $0.30/1M cache_read
cost_usd = (in_tok * 3.0 + out_tok * 15.0 + cache_w * 3.75 + cache_r * 0.30) / 1_000_000.0

budget = {"initial_usd": 5.00, "spent_usd": 0.0, "total_tokens": 0, "runs": 0}
if os.path.exists(budget_path):
    try:
        with open(budget_path, "r", encoding="utf-8") as bf:
            budget.update(json.load(bf))
    except Exception:
        pass

budget["spent_usd"] = round(float(budget.get("spent_usd", 0.0)) + cost_usd, 6)
budget["total_tokens"] = int(budget.get("total_tokens", 0)) + total_tok_today
budget["runs"] = int(budget.get("runs", 0)) + 1
rem_usd = max(0.0, round(float(budget["initial_usd"]) - budget["spent_usd"], 4))
avg_cost = budget["spent_usd"] / max(1, budget["runs"])
est_days = int(rem_usd / avg_cost) if avg_cost > 0 else 999

try:
    os.makedirs(os.path.dirname(budget_path), exist_ok=True)
    with open(budget_path, "w", encoding="utf-8") as bf:
        json.dump(budget, bf, indent=2)
except Exception:
    pass

print(f"🤖 Diagnoza Claude Sonnet 4.6:\n{answer}\n\n💰 Budżet API Anthropic ($5.00):\n• Ten audyt: {total_tok_today} tok. (${cost_usd:.4f})\n• Wydano łącznie: ${budget['spent_usd']:.4f} ({budget['total_tokens']} tok.)\n• Pozostało: ${rem_usd:.4f} (wystarczy na ~{est_days} porannych audytów)")
PYEOF
)"
                rm -f "${XRAY_FILE}" 2>/dev/null || true
            fi

            MORNING_BODY="✅ Wynik: ${OK_COUNT} OK | ${WARN_COUNT} WARN | ${FAIL_COUNT} FAIL
💾 Backupy (03:00): VPS ${AGE_HOURS:-?}h temu | WWW LH.pl ${W_AGE_HOURS:-?}h temu
🧠 Zasoby: Dysk ${DISK_USE_PCT}% (wolne ${DISK_AVAIL_HUMAN}) | ${MEM_INFO}
🛡️ Ochrona: Uptime Kuma Auth OK (401) | Bufor OCI $(( OCI_BUFFER_BYTES / 1048576 )) MiB | Fail2ban: ${F2B_BANNED:-0} zbanowanych IP${HINTS_SUMMARY}"
            if [[ -n "${AI_AUDIT_INSIGHT}" ]]; then
                MORNING_BODY="${MORNING_BODY}

${AI_AUDIT_INSIGHT}"
                printf "\n${C_CYAN}%s${C_RESET}\n" "${AI_AUDIT_INSIGHT}"
            fi

            curl -s --max-time 5 \
                -H "Title: Poranny Audyt AI VPS (${PL_DATE}): ${OK_COUNT} OK / ${FAIL_COUNT} FAIL" \
                -H "Priority: low" \
                -H "Tags: sunny,robot" \
                -d "${MORNING_BODY}" \
                "https://ntfy.sh/${NTFY_AUDIT_TOPIC}" >/dev/null 2>&1 || true
        fi
    fi
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
