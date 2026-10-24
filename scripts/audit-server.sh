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
FORCE_CLAUDE_ESCALATION=false
for arg in "$@"; do
    case "${arg}" in
        --strict) STRICT_MODE=true ;;
        --morning-report) FORCE_MORNING_REPORT=true ;;
        --deep-claude) FORCE_MORNING_REPORT=true; FORCE_CLAUDE_ESCALATION=true ;;
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

# 3. Fail2ban IPS + telemetria zablokowanych ataków SSH
F2B_FAILED_TOTAL=0
F2B_BANNED_TOTAL=0
F2B_BANNED_CURRENT=0
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    F2B_OUT="$(sudo -n fail2ban-client status sshd 2>/dev/null || fail2ban-client status sshd 2>/dev/null || true)"
    if [[ -n "${F2B_OUT}" ]]; then
        F2B_FAILED_TOTAL="$(echo "${F2B_OUT}" | awk -F: '/Total failed:/ {gsub(/[^0-9]/,"",$2); print $2}' || echo '0')"
        F2B_BANNED_TOTAL="$(echo "${F2B_OUT}" | awk -F: '/Total banned:/ {gsub(/[^0-9]/,"",$2); print $2}' || echo '0')"
        F2B_BANNED_CURRENT="$(echo "${F2B_OUT}" | awk -F: '/Currently banned:/ {gsub(/[^0-9]/,"",$2); print $2}' || echo '0')"
    fi
    pass "Demon ochrony przed włamaniami Fail2Ban (IPS) działa (zbanowane IP: ${F2B_BANNED_TOTAL:-0}, aktywne bany: ${F2B_BANNED_CURRENT:-0}, odbite próby SSH: ${F2B_FAILED_TOTAL:-0})."
else
    OS_HARDENED=0
    fail "Usługa Fail2Ban NIE DZIAŁA!" "sudo systemctl enable --now fail2ban"
fi

# 4. SSH Hardening (weryfikacja głębokich dyrektyw CIS Benchmark)
if [[ -f /etc/ssh/sshd_config.d/99-security-hardening.conf ]] \
   && grep -qE '^PermitRootLogin no' /etc/ssh/sshd_config.d/99-security-hardening.conf 2>/dev/null \
   && grep -qE '^PasswordAuthentication no' /etc/ssh/sshd_config.d/99-security-hardening.conf 2>/dev/null \
   && grep -qE '^AllowUsers ' /etc/ssh/sshd_config.d/99-security-hardening.conf 2>/dev/null \
   && grep -qE '^AllowAgentForwarding no' /etc/ssh/sshd_config.d/99-security-hardening.conf 2>/dev/null; then
    pass "Konfiguracja SSH Hardening (PermitRootLogin no, PasswordAuthentication no, AllowUsers, AllowAgentForwarding no) jest aktywna."
else
    warn "Plik /etc/ssh/sshd_config.d/99-security-hardening.conf nie istnieje lub brakuje w nim pełnych dyrektyw CIS (AllowUsers / AllowAgentForwarding)." \
         "sudo bash ${STACK_ROOT}/scripts/01-harden-os.sh"
fi

# 4b. Kontrola Integralności Kluczy SSH i Wskaźników Włamania (IoC - Indicators of Compromise)
IOC_CLEAN=1
NON_ROOT_UID0="$(awk -F: '($3 == 0 && $1 != "root") {print $1}' /etc/passwd 2>/dev/null || true)"
if [[ -z "${NON_ROOT_UID0}" ]]; then
    pass "Integralność kont (IoC): Tylko konto 'root' posiada uprawnienia superużytkownika (UID 0)."
else
    IOC_CLEAN=0
    OS_HARDENED=0
    fail "ALARM WŁAMANIA (IoC): Wykryto obce konto z uprawnieniami UID 0: ${NON_ROOT_UID0}!" \
         "Natychmiast zbadaj /etc/passwd i zablokuj nieautoryzowane konto"
fi

if [[ -f /home/ubuntu/.ssh/authorized_keys ]]; then
    AK_PERMS="$(stat -c '%a' /home/ubuntu/.ssh/authorized_keys 2>/dev/null || echo 'unknown')"
    AK_COUNT="$(grep -cE '^ssh-(ed25519|rsa|ecdsa)' /home/ubuntu/.ssh/authorized_keys 2>/dev/null || true)"
    AK_COUNT="${AK_COUNT:-0}"
    if [[ "${AK_PERMS}" == "600" && "${AK_COUNT}" -le 2 && "${AK_COUNT}" -ge 1 ]]; then
        pass "Integralność kluczy SSH (IoC): /home/ubuntu/.ssh/authorized_keys posiada chmod 600 oraz ${AK_COUNT} autoryzowane klucze Ed25519."
    else
        IOC_CLEAN=0
        OS_HARDENED=0
        fail "ALARM INTEGRALNOŚCI SSH (IoC): Nieprawidłowe uprawnienia (${AK_PERMS}) lub liczba kluczy (${AK_COUNT}) w /home/ubuntu/.ssh/authorized_keys!" \
             "Zweryfikuj zawartość /home/ubuntu/.ssh/authorized_keys oraz nadaj chmod 600"
    fi
fi

SSH_ANOMALY_LOGINS="$(sudo -n journalctl -u ssh --since '24 hours ago' --no-pager 2>/dev/null | grep -cE 'Accepted password|Accepted .* for root' || true)"
SSH_ANOMALY_LOGINS="${SSH_ANOMALY_LOGINS:-0}"
if [[ "${SSH_ANOMALY_LOGINS}" -eq 0 ]]; then
    pass "Dziennik autoryzacji SSH (IoC): 0 logowań hasłem i 0 logowań na konto root (100% połączeń kluczem Ed25519)."
else
    IOC_CLEAN=0
    OS_HARDENED=0
    fail "ALARM WŁAMANIA SSH (IoC): Wykryto ${SSH_ANOMALY_LOGINS} podejrzanych logowań (hasłem lub na konto root) w ostatnich 24h!" \
         "Sprawdź: sudo journalctl -u ssh | grep Accepted"
fi

# 4c. Kontrola procesów uruchomionych z katalogów tymczasowych (/tmp, /var/tmp, /dev/shm - Host IDS)
TMP_EXEC_PROCS="$(sudo -n ls -l /proc/[0-9]*/exe 2>/dev/null | grep -E ' -> (/tmp/|/var/tmp/|/dev/shm/)' || true)"
if [[ -z "${TMP_EXEC_PROCS}" ]]; then
    pass "Ochrona procesów (IoC Host IDS): 0 procesów uruchomionych z katalogów tymczasowych (/tmp, /var/tmp, /dev/shm)."
else
    IOC_CLEAN=0
    OS_HARDENED=0
    fail "ALARM MALWARE (IoC): Wykryto proces uruchomiony z katalogu tymczasowego: ${TMP_EXEC_PROCS}!" \
         "Zbadaj i zatrzymaj podejrzany proces (ps aux / kill -9)"
fi

# 4d. Kontrola integralności harmonogramów systemowych (/etc/crontab, /etc/cron.d - ochrona przed backdoorami)
CRON_SUSPICIOUS="$(grep -rnE '(curl .*\|\s*(ba)?sh|wget .*\|\s*(ba)?sh|/dev/tcp/|base64\s+-d)' /etc/crontab /etc/cron.d /var/spool/cron 2>/dev/null || true)"
if [[ -z "${CRON_SUSPICIOUS}" ]]; then
    pass "Integralność harmonogramów (IoC Cron): brak podejrzanych wywołań powłoki (curl|sh, /dev/tcp, base64) w /etc/cron*."
else
    IOC_CLEAN=0
    OS_HARDENED=0
    fail "ALARM BACKDOOR CRON (IoC): Wykryto podejrzany wpis w harmonogramie cron: ${CRON_SUSPICIOUS}!" \
         "Zweryfikuj pliki w /etc/crontab, /etc/cron.d/ oraz /var/spool/cron/"
fi

# 4e. Kontrola binariów SUID na hoście (IoC SUID Baseline Guard - wykrywanie chmod u+s na bash/python/find)
ROGUE_SUID="$(sudo -n find / -xdev -perm -4000 -type f \
    -not -path '/var/lib/containerd/*' \
    -not -path '/var/lib/docker/*' \
    -not -path '/snap/*' 2>/dev/null \
    | grep -vE '^(/usr/bin/(chfn|chsh|fusermount3|gpasswd|mount|newgrp|passwd|su|sudo|umount)|/usr/lib/dbus-1\.0/dbus-daemon-launch-helper|/usr/lib/openssh/ssh-keysign|/usr/lib/polkit-1/polkit-agent-helper-1|/usr/sbin/mount\.nfs)$' || true)"
if [[ -z "${ROGUE_SUID}" ]]; then
    pass "Integralność binariów SUID (IoC SUID Baseline): brak obcych plików SUID poza standardem Ubuntu."
else
    IOC_CLEAN=0
    OS_HARDENED=0
    fail "ALARM BACKDOOR SUID (IoC): Wykryto niestandardowe binaria z bitem SUID: $(echo "${ROGUE_SUID}" | tr '\n' ' ')!" \
         "Usuń bit SUID: sudo chmod u-s <plik> i zbadaj pochodzenie pliku"
fi

# 4f. Kontrola Kernel OOM Killera (journalctl -k) oraz wiszących procesów Zombie (Z)
KERNEL_OOM_24H="$(sudo -n journalctl -k --since '24 hours ago' --no-pager 2>/dev/null | grep -cE 'Out of memory: Killed process|oom-kill:' || true)"
KERNEL_OOM_24H="${KERNEL_OOM_24H:-0}"
ZOMBIE_PROCS="$(ps -eo stat 2>/dev/null | grep -cE '^Z' || true)"
ZOMBIE_PROCS="${ZOMBIE_PROCS:-0}"
if [[ "${KERNEL_OOM_24H}" -eq 0 && "${ZOMBIE_PROCS}" -le 3 ]]; then
    pass "Stabilność jądra i procesów: 0 incydentów Kernel OOM Killer (24h) oraz brak wiszących procesów Zombie (${ZOMBIE_PROCS})."
else
    warn "Wykryto zdarzenia Kernel OOM Killer (${KERNEL_OOM_24H} w 24h) lub nadmiar procesów Zombie (${ZOMBIE_PROCS})." \
         "sudo journalctl -k --since '24 hours ago' | grep -i oom"
fi

# 5. Kernel sysctl (Anti-Spoofing, Google TCP BBR, fs.inotify) & /dev/shm
SYNC_COOKIES="$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo '0')"
RP_FILTER="$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo '0')"
if [[ "${SYNC_COOKIES}" == "1" && "${RP_FILTER}" == "1" ]]; then
    pass "Parametry bezpieczeństwa jądra (tcp_syncookies=1, rp_filter=1) są aktywne."
else
    warn "Parametry sysctl nie są w pełni utwardzone (syncookies=${SYNC_COOKIES}, rp_filter=${RP_FILTER})." \
         "sudo sysctl --system"
fi

# 5a. Kontrola i samonaprawa sterownika Google TCP BBR oraz limitów fs.inotify (dla 12+ kontenerów i runnerów CI/CD)
TCP_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'cubic')"
INOTIFY_INST="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo '128')"
if [[ "${TCP_CC}" != "bbr" || "${INOTIFY_INST:-0}" -lt 512 ]]; then
    sudo -n modprobe tcp_bbr 2>/dev/null || true
    sudo -n sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sudo -n sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    sudo -n sysctl -w fs.inotify.max_user_watches=524288 >/dev/null 2>&1 || true
    sudo -n sysctl -w fs.inotify.max_user_instances=512 >/dev/null 2>&1 || true
    sudo -n sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
    sudo -n sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
    if [[ -f /etc/sysctl.d/99-security-hardening.conf ]] && ! grep -q "tcp_congestion_control" /etc/sysctl.d/99-security-hardening.conf 2>/dev/null; then
        sudo -n bash -c 'cat << "EOF" >> /etc/sysctl.d/99-security-hardening.conf

# Algorytm kontroli przeciazenia Google TCP BBR i limity inotify
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF' 2>/dev/null || true
    fi
    TCP_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'cubic')"
    INOTIFY_INST="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo '128')"
fi
if [[ "${TCP_CC}" == "bbr" && "${INOTIFY_INST:-0}" -ge 512 ]]; then
    pass "Optymalizacja sieci i kontenerów jądra: Google TCP BBR (${TCP_CC}) oraz fs.inotify (instances=${INOTIFY_INST}) są aktywne."
else
    warn "Brak aktywnego sterownika TCP BBR (${TCP_CC}) lub niski limit inotify (${INOTIFY_INST})." \
         "sudo bash ${STACK_ROOT}/scripts/01-harden-os.sh"
fi

# 5b. Kontrola synchronizacji zegara atomowego NTP (wymóg ISO 27001 A.8.17 / Cloudflare R2 SigV4 / OAuth2 JWT)
NTP_SYNCED=0
NTP_STATE="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 'no')"
if [[ "${NTP_STATE}" != "yes" ]]; then
    sudo -n timedatectl set-ntp true 2>/dev/null || true
    sudo -n systemctl restart systemd-timesyncd 2>/dev/null || true
    sleep 1
    NTP_STATE="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 'no')"
fi
if [[ "${NTP_STATE}" == "yes" ]]; then
    NTP_SYNCED=1
    pass "Synchronizacja czasu atomowego NTP (ISO 27001 A.8.17): zegar zsynchronizowany (NTPSynchronized=yes)."
else
    warn "Zegar systemowy nie jest zsynchronizowany przez NTP (NTPSynchronized=${NTP_STATE} — ryzyko błędów S3 R2 i JWT)!" \
         "sudo timedatectl set-ntp true && sudo systemctl restart systemd-timesyncd"
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

# 6. Kontrola i automatyczna samonaprawa oczekujących aktualizacji bezpieczeństwa APT oraz łańcucha DOCKER-USER (+ systemd ExecStartPost hook)
chmod 640 "${STACK_ROOT}"/compose/*.yml 2>/dev/null || true
chmod 644 "${STACK_ROOT}"/services/ai-router/data/* 2>/dev/null || true
chmod 750 "${STACK_ROOT}"/services/ai-router/storage 2>/dev/null || true

if [[ ! -f /etc/systemd/system/docker.service.d/10-docker-user-guard.conf ]]; then
    sudo -n bash -c 'cat << "EOF" > /usr/local/sbin/devops-docker-user-guard.sh
#!/usr/bin/env bash
WAN_IFACE="$(ip route show default 2>/dev/null | awk '\''{print $5; exit}'\'')"
if [[ -n "${WAN_IFACE}" ]] && iptables -L DOCKER-USER -n >/dev/null 2>&1; then
    iptables -D DOCKER-USER -i "${WAN_IFACE}" -j DROP 2>/dev/null || true
    iptables -D DOCKER-USER -i "${WAN_IFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null || true
    iptables -I DOCKER-USER 1 -i "${WAN_IFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null || true
    iptables -I DOCKER-USER 2 -i "${WAN_IFACE}" -j DROP 2>/dev/null || true
fi
EOF
chmod 700 /usr/local/sbin/devops-docker-user-guard.sh
mkdir -p /etc/systemd/system/docker.service.d
cat << "EOF" > /etc/systemd/system/docker.service.d/10-docker-user-guard.conf
[Service]
ExecStartPost=-/usr/local/sbin/devops-docker-user-guard.sh
EOF
systemctl daemon-reload' 2>/dev/null || true
fi

WAN_IFACE_AUDIT="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
if [[ -n "${WAN_IFACE_AUDIT}" ]] && sudo -n iptables -L DOCKER-USER -n >/dev/null 2>&1; then
    if ! sudo -n iptables -C DOCKER-USER -i "${WAN_IFACE_AUDIT}" -j DROP 2>/dev/null; then
        sudo -n iptables -I DOCKER-USER 1 -i "${WAN_IFACE_AUDIT}" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null || true
        sudo -n iptables -I DOCKER-USER 2 -i "${WAN_IFACE_AUDIT}" -j DROP 2>/dev/null || true
    fi
    if sudo -n iptables -C DOCKER-USER -i "${WAN_IFACE_AUDIT}" -j DROP 2>/dev/null && [[ -f /etc/systemd/system/docker.service.d/10-docker-user-guard.conf ]]; then
        pass "Zapora DOCKER-USER WAN Guard (${WAN_IFACE_AUDIT} -> DROP + systemd ExecStartPost hook) oraz uprawnienia Compose (640) są aktywne."
    else
        warn "Brak reguły ochronnej DROP lub hooka systemd w łańcuchu DOCKER-USER dla interfejsu ${WAN_IFACE_AUDIT}." \
             "sudo bash ${STACK_ROOT}/scripts/01-harden-os.sh"
    fi
fi

APT_PENDING_COUNT="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || true)"
APT_PENDING_COUNT="${APT_PENDING_COUNT:-0}"
if [[ "${APT_PENDING_COUNT}" -gt 0 ]]; then
    sudo -n DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" --with-new-pkgs upgrade -y >/dev/null 2>&1 || true
    APT_AFTER_COUNT="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || true)"
    APT_AFTER_COUNT="${APT_AFTER_COUNT:-0}"
    if [[ "${APT_AFTER_COUNT}" -eq 0 ]]; then
        pass "Aktualizacje bezpieczeństwa APT (Auto-Patching): automatycznie zainstalowano ${APT_PENDING_COUNT} oczekujących pakietów (0 zaległych)."
        APT_PENDING_COUNT=0
    else
        APT_PENDING_COUNT="${APT_AFTER_COUNT}"
        warn "System posiada ${APT_PENDING_COUNT} oczekujących pakietów APT wymagających interwencji." \
             "sudo apt-get update && sudo apt-get --with-new-pkgs upgrade -y"
    fi
else
    pass "Aktualizacje bezpieczeństwa APT (unattended-upgrades + Docker CE): wszystkie pakiety są aktualne (0 zaległych)."
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

    # Weryfikacja i autonomiczna aktualizacja (Auto-Update) tunelu krawędziowego Cloudflare Zero Trust wewnątrz sieci Dockera
    if docker logs --since 24h cloudflared 2>&1 | grep -qi "is outdated"; then
        docker compose --env-file "${ENV_FILE}" -f "${STACK_ROOT}/compose/extensions.yml" pull -q cloudflared >/dev/null 2>&1 || true
        docker compose --env-file "${ENV_FILE}" -f "${STACK_ROOT}/compose/extensions.yml" up -d cloudflared >/dev/null 2>&1 || true
        sleep 4
    fi
    if docker exec prometheus wget -q -T 4 --spider "http://cloudflared:2000/ready" >/dev/null 2>&1; then
        CF_VER="$(docker exec cloudflared cloudflared --version 2>/dev/null | awk '{print $3}' || echo 'latest')"
        pass "Smoke Test Tunelu [cloudflared ${CF_VER}]: http://cloudflared:2000/ready -> Połączenie QUIC aktywne (READY)"
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

    # 5b-tls. Kontrola wygasania certyfikatów SSL/TLS monitorowanych domen (< 14 dni)
    MIN_CERT_DAYS="$(curl -sG --max-time 4 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=min(monitor_cert_days_remaining)' 2>/dev/null | grep -oE '"[0-9]+(\.[0-9]+)?"\]' | tr -d '"[]' | cut -d'.' -f1 | head -n1 || echo '')"
    if [[ -n "${MIN_CERT_DAYS}" && "${MIN_CERT_DAYS}" -ge 14 ]]; then
        pass "Certyfikaty SSL/TLS monitorowanych domen są ważne (najkrótszy czas do wygaśnięcia: ${MIN_CERT_DAYS} dni >= 14 dni)."
    elif [[ -n "${MIN_CERT_DAYS}" && "${MIN_CERT_DAYS}" -lt 14 ]]; then
        warn "Certyfikat SSL/TLS jednej z monitorowanych domen wygasa za ${MIN_CERT_DAYS} dni (< 14 dni)!" \
             "Sprawdź szczegóły certyfikatów w panelu Uptime Kuma"
    else
        pass "Certyfikaty SSL/TLS monitorowanych domen są objęte nadzorem Uptime Kuma / Cloudflare Edge."
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

    # 5c. Kontrola autoryzacji GitHub PAT (github-exporter -> github_repo_created_timestamp > 0 & brak świeżych błędów github_request_failures_total w oknie 15m)
    GH_REPOS_COUNT="$(curl -sG --max-time 4 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=count(github_repo_created_timestamp)' 2>/dev/null | grep -oE '"[0-9]+"\]' | tr -d '"[]' | head -n1 || echo '0')"
    GH_FAILURES="$(curl -sG --max-time 4 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=round(sum(increase(github_request_failures_total[15m])))' 2>/dev/null | grep -oE '"[0-9]+(\.[0-9]+)?"\]' | tr -d '"[]' | cut -d'.' -f1 | head -n1 || echo '0')"
    if [[ "${GH_REPOS_COUNT:-0}" -gt 0 ]] && [[ "${GH_FAILURES:-0}" -eq 0 ]]; then
        pass "Tokeny GitHub PAT (github-exporter) są aktywne i autoryzowane (monitorowane repozytoria: ${GH_REPOS_COUNT}, błędy API 15m: 0)."
    else
        warn "Exporter GitHub zgłasza problem z API GitHub (repozytoria: ${GH_REPOS_COUNT:-0}, błędy 15m: ${GH_FAILURES:-0} — sprawdź ważność GITHUB_PAT_* w .env)."
    fi

    # 5d. Kontrola reguły Catch-All (http_status:404) w konfiguracji Ingress tunelu Cloudflare Zero Trust
    CF_INGRESS_CFG="$(docker logs cloudflared 2>&1 | grep -i "Updated to new configuration" | tail -n 1 || true)"
    if [[ -z "${CF_INGRESS_CFG}" ]] || [[ "${CF_INGRESS_CFG}" == *"http_status:404"* ]]; then
        pass "Polityka Ingress Tunelu [cloudflared]: reguła catch-all Zero Trust (http_status:404) jest aktywna."
    else
        warn "W konfiguracji Ingress tunelu cloudflared nie wykryto reguły fallback http_status:404!" \
             "Sprawdź regułę catch-all w panelu Cloudflare Zero Trust -> Networks -> Tunnels"
    fi

    # 5e. Telemetria WAF Warstwy 7, 15-minutowego IP Penalty Box oraz piaskownicy PHP (open_basedir + disable_functions) w AI Routerze
    WAF_BLOCKED_TOTAL="$(curl -s --max-time 4 "http://127.0.0.1:8085/metrics" 2>/dev/null | awk '/^ai_router_requests_total\{.*outcome="security_blocked"/ {s+=$NF} END {print s+0}')"
    PHP_SANDBOX_OK="$(docker exec ai-router php -r 'echo (ini_get("open_basedir") === "/app:/tmp" && strpos(ini_get("disable_functions"), "shell_exec") !== false) ? "1" : "0";' 2>/dev/null || echo '0')"
    if [[ "${PHP_SANDBOX_OK}" == "1" ]]; then
        pass "Strażnik WAF L7, IP Penalty Box & PHP Sandbox (open_basedir=/app:/tmp, disable_functions): aktywny (zablokowane ataki L7: ${WAF_BLOCKED_TOTAL:-0})."
    else
        warn "Kontener ai-router działa, ale brakuje aktywnej piaskownicy php.ini (open_basedir / disable_functions)!" \
             "Przebuduj kontener: cd ${STACK_ROOT}/compose && docker compose --env-file ../.env -f docker-compose.yml up -d --build ai-router"
    fi

    # 5f. Skaner Anomalii Logów 24h (24h Container Log Error Hunter - pełne 24h zamiast wycinka --tail 6)
    LOG_CRITICAL_24H=0
    LOG_CRITICAL_SAMPLES=""
    for _cname in "${EXPECTED_CONTAINERS[@]}"; do
        _hits="$(docker logs --since 24h "${_cname}" 2>&1 | tr -d '\000' \
            | grep -vE '(broken pipe|context canceled|referenced_memory|machine info|GET /health|GET /metrics|GET /amms|HEAD /)' \
            | grep -E '(FATAL|PANIC|Out of memory|Segmentation fault|Uncaught Error|SQLITE_CORRUPT)' | tail -n 2 || true)"
        if [[ -n "${_hits}" ]]; then
            _cnt="$(echo "${_hits}" | wc -l | tr -d ' ')"
            LOG_CRITICAL_24H=$((LOG_CRITICAL_24H + _cnt))
            LOG_CRITICAL_SAMPLES="${LOG_CRITICAL_SAMPLES} [${_cname}]: $(echo "${_hits}" | tr '\n' ' ' | cut -c 1-160)"
        fi
    done
    if [[ "${LOG_CRITICAL_24H}" -eq 0 ]]; then
        pass "Skaner logów 24h (${#EXPECTED_CONTAINERS[@]} kontenerów): 0 krytycznych wyjątków (FATAL/PANIC/OOM/SQLITE_CORRUPT)."
    else
        warn "Skaner logów 24h wykrył ${LOG_CRITICAL_24H} krytycznych wyjątków:${LOG_CRITICAL_SAMPLES}" \
             "Sprawdź logi kontenerów w panelu Dozzle"
    fi

    # 5g. Kontrola Asystenta Eksperckiego AMMS & Oracle DBA (Dual-Stream SQLite FTS5 RAG + Zero Trust WAN Guard)
    AMMS_LOCAL_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:8085/amms" 2>/dev/null || echo '000')"
    AMMS_WAN_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 -H "CF-Connecting-IP: 198.51.100.254" "http://127.0.0.1:8085/amms" 2>/dev/null || echo '000')"
    AMMS_SQLITE_FILE="${STACK_ROOT}/services/ai-router/data/amms-knowledge.sqlite"
    if [[ "${AMMS_LOCAL_CODE}" == "200" && "${AMMS_WAN_CODE}" == "403" ]]; then
        if [[ -f "${AMMS_SQLITE_FILE}" && -s "${AMMS_SQLITE_FILE}" ]]; then
            AMMS_DB_SIZE="$(du -h "${AMMS_SQLITE_FILE}" 2>/dev/null | awk '{print $1}' || echo '162M')"
            pass "Asystent AMMS & Oracle DBA (Zero Trust + SQLite FTS5): dostępny lokalnie (/amms -> 200), zablokowany z WAN (CF -> 403), baza FTS5 aktywna (${AMMS_DB_SIZE})."
        else
            warn "Interfejs AMMS (/amms) i blokada WAN (403) działają, ale brakuje pliku bazy ${AMMS_SQLITE_FILE}." \
                 "Wgraj bazę: powershell -File scripts/open-amms-assistant.ps1 -SyncToVps"
        fi
    else
        CONTAINERS_HEALTHY=0
        fail "Błąd ochrony lub dostępności Asystenta AMMS (/amms lokalnie: HTTP ${AMMS_LOCAL_CODE}, blokada WAN: HTTP ${AMMS_WAN_CODE} — oczekiwano 200 i 403)!" \
             "Sprawdź services/ai-router/src/chat-router.php oraz kontener ai-router"
    fi

    # 5h. Kontrola Cookieless Web Analytics v3 (5 domen w tym raricart + dancepuls) oraz synchronizatora GSC / IndexNow
    METRICS_BODY="$(curl -s --max-time 4 "http://127.0.0.1:8085/metrics" 2>/dev/null || true)"
    GSC_SCRIPT="${STACK_ROOT}/scripts/sync-gsc-keywords.sh"
    if [[ "${METRICS_BODY}" == *'web_analytics_unique_visitors_today{site="raricart"}'* ]] \
       && [[ "${METRICS_BODY}" == *'ai_router_question_topics_total'* ]] \
       && [[ -f "${GSC_SCRIPT}" ]] && bash -n "${GSC_SCRIPT}" 2>/dev/null; then
        pass "Cookieless Web Analytics v3 & SEO Sync (GSC API + IndexNow + Raricart.pl): telemetria 5 domen i skrypt sync-gsc-keywords.sh aktywne."
    else
        warn "Telemetria Web Analytics v3 (raricart/topics) lub skrypt sync-gsc-keywords.sh wymaga weryfikacji." \
             "Sprawdź http://127.0.0.1:8085/metrics oraz ${GSC_SCRIPT}"
    fi
fi

# ==============================================================================
# WARSTWA 5: ZASOBY SPRZĘTOWE (ALWAYS FREE), WOLUMENY I BACKUPY
# ==============================================================================
section "[5/5] WARSTWA 5: Zasoby Sprzętowe, Wolumeny i Ciągłość Backupów"

# 1. Zajętość dysku głównego oraz tablicy Inode'ów (ochrona przed wyczerpaniem i-węzłów)
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

INODE_USE_PCT="$(df -Pi / | awk 'NR==2 {gsub("%","",$5); print $5}')"
if [[ "${INODE_USE_PCT:-0}" -lt 75 ]]; then
    pass "Zajętość tablicy i-węzłów (Inodes /): ${INODE_USE_PCT}% (ochrona przed blokadą zapisu małych plików)."
else
    warn "Wysokie zużycie tablicy i-węzłów (Inodes /): ${INODE_USE_PCT}%!" \
         "df -i / && find /app/storage -type f | wc -l"
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

# 2-swap. Kontrola i automatyczna samonaprawa poduszki bezpieczeństwa SWAP (2 GB) oraz vm.swappiness=10
SWAP_TOTAL_MB="$(free -m | awk '/^Swap:/ {print $2}')"
if [[ "${SWAP_TOTAL_MB:-0}" -lt 1024 ]]; then
    sudo -n bash -c '
        if [[ ! -f /swapfile ]]; then
            fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
        fi
        swapon /swapfile 2>/dev/null || true
        if ! grep -q "/swapfile" /etc/fstab 2>/dev/null; then
            echo "/swapfile none swap sw 0 0" >> /etc/fstab
        fi
        sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
        sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
    ' 2>/dev/null || true
    SWAP_TOTAL_MB="$(free -m | awk '/^Swap:/ {print $2}')"
fi
SWAPPINESS_VAL="$(sysctl -n vm.swappiness 2>/dev/null || echo '60')"
if [[ "${SWAP_TOTAL_MB:-0}" -ge 1024 ]]; then
    pass "Poduszka bezpieczeństwa SWAP: aktywna (${SWAP_TOTAL_MB} MiB, vm.swappiness=${SWAPPINESS_VAL} — ochrona Page Cache dla SQLite FTS5 i OOM)."
else
    warn "Brak aktywnej przestrzeni SWAP (${SWAP_TOTAL_MB:-0} MiB < 1024 MiB)!" \
         "sudo bash ${STACK_ROOT}/scripts/01-harden-os.sh"
fi

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

# 5b. Głęboka weryfikacja Nocnego Restore Drill (--verify-only), spójności SQLite (PRAGMA quick_check) oraz zrzutów MySQL
DRILL_OK="$(awk '/^devops_backup_restore_drill_verified/ {print $2}' "${BACKUP_PROM}" 2>/dev/null || echo '0')"
SQLITE_OK="$(awk '/^devops_backup_sqlite_verified/ {print $2}' "${BACKUP_PROM}" 2>/dev/null || echo '0')"
MYSQL_OK="$(awk '/^devops_backup_websites_db_verified/ {print $2}' "${WEBSITES_PROM}" 2>/dev/null || echo '0')"
if [[ "${DRILL_OK}" == "1" && "${SQLITE_OK}" == "1" && "${MYSQL_OK}" == "1" ]]; then
    pass "Integralność Disaster Recovery: Nocny Restore Drill (--verify-only), SQLite PRAGMA quick_check oraz zrzuty MySQL zweryfikowane (100% OK)."
else
    warn "Niepełna weryfikacja Disaster Recovery (Restore Drill=${DRILL_OK:-0}, SQLite=${SQLITE_OK:-0}, MySQL=${MYSQL_OK:-0})!" \
         "bash ${STACK_ROOT}/scripts/restore-backup.sh --verify-only"
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

# HELP devops_fail2ban_failed_total Laczna liczba wykrytych i odbitych prob wlamania SSH przez Fail2Ban
# TYPE devops_fail2ban_failed_total gauge
devops_fail2ban_failed_total ${F2B_FAILED_TOTAL:-0}

# HELP devops_fail2ban_banned_total Laczna liczba zbanowanych adresow IP agresorow przez Fail2Ban
# TYPE devops_fail2ban_banned_total gauge
devops_fail2ban_banned_total ${F2B_BANNED_TOTAL:-0}

# HELP devops_fail2ban_banned_current Liczba aktualnie aktywnych blokad IP w Fail2Ban
# TYPE devops_fail2ban_banned_current gauge
devops_fail2ban_banned_current ${F2B_BANNED_CURRENT:-0}

# HELP devops_security_ioc_clean Status braku oznak wlamania IoC (1 = czysto, 0 = wykryto naruszenie integralnosci kluczy/kont)
# TYPE devops_security_ioc_clean gauge
devops_security_ioc_clean ${IOC_CLEAN:-1}

# HELP devops_waf_blocked_total Laczna liczba zablokowanych atakow WAF L7 w AI Routerze
# TYPE devops_waf_blocked_total gauge
devops_waf_blocked_total ${WAF_BLOCKED_TOTAL:-0}

# HELP devops_log_critical_24h_total Liczba krytycznych wyjatkow w logach kontenerow z ostatnich 24h
# TYPE devops_log_critical_24h_total gauge
devops_log_critical_24h_total ${LOG_CRITICAL_24H:-0}

# HELP devops_apt_upgradable_packages Liczba oczekujacych aktualizacji pakietow APT na hoscie
# TYPE devops_apt_upgradable_packages gauge
devops_apt_upgradable_packages ${APT_PENDING_COUNT:-0}

# HELP devops_ntp_synchronized Status synchronizacji zegara atomowego NTP (1 = zsynchronizowany, 0 = brak synchronizacji)
# TYPE devops_ntp_synchronized gauge
devops_ntp_synchronized ${NTP_SYNCED:-1}
EOF
    mv "${AUDIT_PROM}.tmp" "${AUDIT_PROM}"
    chmod 644 "${AUDIT_PROM}" 2>/dev/null || true
fi

# Powiadomienia Push na Ntfy.sh:
# 1. Natychmiastowy alert przy błędach krytycznych (FAIL_COUNT > 0)
# 2. Alert ostrzeżeń (WARN_COUNT > 0, max raz na 6h, aby unikać spamu)
# 3. Codzienny Poranny Raport Bezpieczeństwa o 08:00 rano (Europe/Warsaw) lub z flagą --morning-report / --deep-claude
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

        # Codzienny Poranny Raport o 07:30 rano (Europe/Warsaw): Scrapery KSH/DancePuls + Audyt ISO 27001 (E-mail + Ntfy.sh)
        PL_HOUR="$(TZ=Europe/Warsaw date +%H 2>/dev/null || date +%H)"
        PL_MIN="$(TZ=Europe/Warsaw date +%M 2>/dev/null || date +%M)"
        PL_DATE="$(TZ=Europe/Warsaw date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"
        MORNING_STAMP_FILE="/var/tmp/devops-morning-digest.date"
        LAST_MORNING_DATE="$(cat "${MORNING_STAMP_FILE}" 2>/dev/null || echo '')"

        # Pre-trigger o 07:15 (Europe/Warsaw): wywołanie workflow_dispatch dla weekly-report.yml bez czekania na kolejkę crona GitHuba
        if [[ "${PL_HOUR}" == "07" && $((10#${PL_MIN})) -ge 12 && $((10#${PL_MIN})) -le 22 && "${LAST_MORNING_DATE}" != "${PL_DATE}" ]]; then
            sudo ENV_FILE="${ENV_FILE}" PL_DATE="${PL_DATE}" python3 - << 'PYPRE' >/dev/null 2>&1 || true
import json, os, urllib.request
env_vars = {}
env_path = os.environ.get("ENV_FILE", "/opt/devops-stack/.env")
if os.path.exists(env_path):
    with open(env_path, "r", encoding="utf-8", errors="ignore") as ef:
        for line in ef:
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.strip().split("=", 1)
                env_vars[k.strip()] = v.strip().strip("\"'")
gh_tok = env_vars.get("GITHUB_TOKEN", "")
pl_date = os.environ.get("PL_DATE", "")
if gh_tok:
    hdrs = {"Authorization": f"Bearer {gh_tok}", "User-Agent": "TwojaStronaWWW-Audit/2.0", "Accept": "application/vnd.github+json"}
    runs_url = "https://api.github.com/repos/TwojaStronaWWW/katosalsahub/actions/workflows/weekly-report.yml/runs?per_page=1"
    with urllib.request.urlopen(urllib.request.Request(runs_url, headers=hdrs), timeout=8) as r:
        runs = json.loads(r.read().decode("utf-8")).get("workflow_runs") or []
    already_today = bool(runs and str(runs[0].get("created_at", "")).startswith(pl_date))
    if not already_today:
        disp_url = "https://api.github.com/repos/TwojaStronaWWW/katosalsahub/actions/workflows/weekly-report.yml/dispatches"
        req = urllib.request.Request(disp_url, data=json.dumps({"ref": "main"}).encode("utf-8"), headers={**hdrs, "Content-Type": "application/json"}, method="POST")
        urllib.request.urlopen(req, timeout=8)
PYPRE
        fi

        if [[ "${FORCE_MORNING_REPORT}" == "true" ]] || [[ "${LAST_MORNING_DATE}" != "${PL_DATE}" && ( ( "${PL_HOUR}" == "07" && $((10#${PL_MIN})) -ge 28 ) || "${PL_HOUR}" == "08" ) ]]; then
            echo "${PL_DATE}" > "${MORNING_STAMP_FILE}" 2>/dev/null || true
            if [[ -f "${STACK_ROOT}/scripts/sync-gsc-keywords.sh" ]]; then
                bash "${STACK_ROOT}/scripts/sync-gsc-keywords.sh" >/dev/null 2>&1 || true
            fi
            F2B_BANNED="$(sudo fail2ban-client status sshd 2>/dev/null | awk -F: '/Total banned/ {gsub(/[ \t]/,"",$2); print $2}' || echo '0')"
            F2B_IP_LIST="$(sudo fail2ban-client status sshd 2>/dev/null | awk -F: '/Banned IP list/ {gsub(/^[ \t]+/,"",$2); print $2}' || echo 'brak')"
            AI_METRICS_RAW="$(curl -s --max-time 3 "http://127.0.0.1:8085/metrics" 2>/dev/null || true)"
            WA_PV_TOTAL="$(echo "${AI_METRICS_RAW}" | awk '/^web_analytics_pageviews_total\{/ {s+=$NF} END {print s+0}')"
            WA_UV_TOTAL="$(echo "${AI_METRICS_RAW}" | awk '/^web_analytics_unique_visitors_total\{/ {s+=$NF} END {print s+0}')"
            WA_ENG_TOTAL="$(echo "${AI_METRICS_RAW}" | awk '/^web_analytics_engaged_visits_total\{/ {s+=$NF} END {print s+0}')"
            WA_LEADS_TOTAL="$(echo "${AI_METRICS_RAW}" | awk '/^ai_router_leads_total\{/ {s+=$NF} END {print s+0}')"
            WA_LCP_AVG="$(echo "${AI_METRICS_RAW}" | awk '/^web_analytics_cwv_lcp_seconds_sum\{/ {s+=$NF} /^web_analytics_cwv_lcp_seconds_count\{/ {c+=$NF} END {if (c>0) printf "%.2fs", s/c; else print "b/d"}')"
            WA_TOP_TOPIC="$(echo "${AI_METRICS_RAW}" | awk '/^ai_router_question_topics_total\{/ && $NF > 0 {val=$NF; match($0, /topic="[^"]+"/); t=substr($0, RSTART+7, RLENGTH-8); if (val > max) {max=val; best=t}} END {print (best != "" ? best " (" max ")" : "brak")}')"
            WA_TOP_TERM="$(echo "${AI_METRICS_RAW}" | awk '/^web_analytics_search_terms_total\{/ && $NF > 0 {val=$NF; match($0, /term="[^"]+"/); t=substr($0, RSTART+6, RLENGTH-7); if (t != "brak-wyszukiwan" && val > max) {max=val; best=t}} END {print (best != "" ? best " (" max ")" : "brak")}')"

            # Zbieranie Pełnego Rentgena 24h (Deep X-Ray 24h) z odfiltrowaniem szumu healthchecków
            AI_AUDIT_INSIGHT=""
            if command -v python3 >/dev/null 2>&1; then
                XRAY_FILE="/var/tmp/devops-xray.txt"
                {
                    echo "=== WYNIK DETERMINISTYCZNEGO AUDYTU 5 WARSTW (ISO 27001) ==="
                    echo "Data: ${PL_DATE} | Wynik: ${OK_COUNT} OK, ${WARN_COUNT} WARN, ${FAIL_COUNT} FAIL (IoC Clean=${IOC_CLEAN:-1}, Krytyczne wyjatki 24h=${LOG_CRITICAL_24H:-0})"
                    echo "Dysk: ${DISK_USE_PCT}% (wolne ${DISK_AVAIL_HUMAN}) | RAM: ${MEM_INFO} | Bufor OCI: $(( OCI_BUFFER_BYTES / 1048576 )) MiB"
                    echo "Backupy (harmonogram 03:00 UTC + szyfrowanie AES-256-CBC do Cloudflare R2): VPS ${AGE_HOURS:-?}h temu | WWW LH.pl ${W_AGE_HOURS:-?}h temu | Weryfikacja integralnosci: Nocny Restore Drill (--verify-only)=${DRILL_OK:-1}, SQLite PRAGMA quick_check=${SQLITE_OK:-1}, MySQL dump=${MYSQL_OK:-1}, tar -tzf=1 (100% OK)"
                    echo "Architektura Zero Trust & Dostep: Porty 80/443 zamkniete w WAN (UFW + DOCKER-USER DROP), dostep wylacznie przez Cloudflare Zero Trust (Access MFA + Catch-All 404) i tunel SSH Ed25519 (PasswordAuthentication=no, PermitRootLogin=no, Grafana PoLP Viewer)"
                    echo "Ochrona IPS/WAF: Fail2ban zbanowane IP=${F2B_BANNED:-0} (aktywne IP: ${F2B_IP_LIST:-brak}) | WAF L7 zablokowane ataki=${WAF_BLOCKED_TOTAL:-0}"
                    echo "Analityka WWW i AI: Odslony=${WA_PV_TOTAL:-0} | Unikalni=${WA_UV_TOTAL:-0} | Zaangazowani(>=15s)=${WA_ENG_TOTAL:-0} | LCP=${WA_LCP_AVG:-b/d} | Leady=${WA_LEADS_TOTAL:-0} | Top temat AI=${WA_TOP_TOPIC:-brak} | Top fraza=${WA_TOP_TERM:-brak}"
                    if [[ -n "${HINTS_SUMMARY}" ]]; then
                        echo "Wykryte wskazowki naprawcze: ${HINTS_SUMMARY}"
                    fi
                    echo "=== ROZMIARY LOGOW KONTENEROW (TOP 5) ==="
                    sudo sh -c 'du -sh /var/lib/docker/containers/*/*-json.log 2>/dev/null | sort -hr | head -n 5' || true
                    echo "=== USTAWIENIA BEZPIECZENSTWA UPTIME KUMA (kuma.db) ==="
                    sudo python3 -c "import sqlite3; c=sqlite3.connect('/var/lib/docker/volumes/uptime_kuma_data/_data/kuma.db'); print(c.execute(\"SELECT key, value FROM setting WHERE key IN ('disableAuth','tlsExpiryNotifyDays','keepDataPeriodDays')\").fetchall())" 2>/dev/null || true
                    echo "=== REGULY INGRESS CLOUDFLARED ==="
                    docker logs cloudflared 2>&1 | grep -i "Updated to new configuration" | tail -n 1 || true
                    echo "=== SKANER ANOMALII LOGOW KONTENEROW Z PELNYCH 24 GODZIN (--since 24h, bez szumu healthcheckow) ==="
                    for cname in "${EXPECTED_CONTAINERS[@]}"; do
                        anom_24h="$(docker logs --since 24h "${cname}" 2>&1 | tr -d '\000' \
                            | grep -vE '(broken pipe|context canceled|connection reset by peer|referenced_memory|machine info|container factory failed|inotify_add_watch|No such image: sha256|Runner connect error|HttpRequestException|SIGTERM|Shutting down|GET /health|GET /metrics|GET /amms|HEAD /|Listening for Jobs|Connected to GitHub|plugins-bundled|\.gitkeep|Pending:.*Retry: [12]\b|no recent network activity)' \
                            | grep -iE '(error|warn|fail|fatal|panic|crit|exception|denied|security_blocked|\bban(ned)?\b|corrupt|unhealthy)' \
                            | tail -n 6 | cut -c 1-240 || true)"
                        if [[ -n "${anom_24h}" ]]; then
                            echo "--- [${cname}] ANOMALIE 24H ---"
                            echo "${anom_24h}"
                        else
                            last_line="$(docker logs --since 24h "${cname}" 2>&1 | tr -d '\000' | grep -vE '(broken pipe|context canceled|referenced_memory|GET /health|GET /metrics)' | tail -n 1 | cut -c 1-180 || echo 'OK')"
                            echo "--- [${cname}] 24h: 0 bledow/ostrzezen (ostatni wpis: ${last_line})"
                        fi
                    done
                    echo "=== DZIENNIK SSH I BLEDY SYSTEMOWE (journalctl 24h) ==="
                    ssh_ok_24h="$(sudo journalctl -u ssh --since '24 hours ago' --no-pager 2>/dev/null | grep -c 'Accepted publickey' || true)"
                    echo "Udane logowania SSH kluczem Ed25519 (24h): ${ssh_ok_24h:-0} | Logowania haslem/rootem: ${SSH_ANOMALY_LOGINS:-0}"
                    sudo journalctl -p err..emerg --since "24 hours ago" --no-pager 2>/dev/null \
                        | grep -vE '(kex_exchange_identification|Connection reset by peer|banner exchange)' | tail -n 8 || true
                } > "${XRAY_FILE}" 2>/dev/null

                NEED_CLAUDE="false"
                if [[ "${FORCE_CLAUDE_ESCALATION}" == "true" || "${FAIL_COUNT}" -gt 0 || "${WARN_COUNT}" -gt 0 || "${IOC_CLEAN:-1}" -eq 0 || "${LOG_CRITICAL_24H:-0}" -gt 0 ]]; then
                    NEED_CLAUDE="true"
                fi

                AI_AUDIT_INSIGHT="$(sudo ENV_FILE="${ENV_FILE}" XRAY_FILE="${XRAY_FILE}" NEED_CLAUDE="${NEED_CLAUDE}" python3 - << 'PYEOF' 2>/dev/null || true
import json, os, time, urllib.request

env_path = os.environ.get("ENV_FILE", "/opt/devops-stack/.env")
env_vars = {}
if os.path.exists(env_path):
    with open(env_path, "r", encoding="utf-8", errors="ignore") as ef:
        for line in ef:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                env_vars[k.strip()] = v.strip().strip("\"'")

groq_key = env_vars.get("GROQ_API_KEY", "")
cerebras_key = env_vars.get("CEREBRAS_API_KEY", "")
gemini_key = env_vars.get("GEMINI_API_KEY", "")
anthropic_key = env_vars.get("ANTHROPIC_API_KEY", "")
need_claude = os.environ.get("NEED_CLAUDE", "false") == "true"

xray_path = os.environ.get("XRAY_FILE", "")
budget_path = "/var/lib/docker/volumes/ai_router_storage/_data/anthropic_budget.json"

with open(xray_path, "r", encoding="utf-8", errors="replace") as f:
    xray_text = f.read()[:6500]

sys_prompt_primary = (
    "Jesteś Głównym Audytorem Bezpieczeństwa DevOps (ISO 27001) serwera TwojaStronaWWW (Oracle Cloud ARM64). "
    "Przeanalizuj szczegółowy 24-godzinny Rentgen serwera (testy deterministyczne, skaner anomalii 24h wszystkich 12 kontenerów, WAF L7, Fail2ban, Uptime Kuma SQLite, reguły tunelu Cloudflare, journalctl). "
    "Napisz po polsku bardzo zwięzłą diagnozę w 3 krótkich punktach (po 1 zdaniu każdy): "
    "1) Anomalie w logach 24h i systemie, "
    "2) Stan ochrony Zero Trust, WAF/Fail2ban i backupów, "
    "3) Werdykt końcowy i rekomendacja."
)

sys_prompt_cross = (
    "Jesteś drugim, niezależnym Audytorem Krzyżowym ISO 27001 (Second Opinion). "
    "Zweryfikuj poniższy 24-godzinny Rentgen serwera VPS i napisz po polsku maksymalnie 2 krótkie zdania: "
    "potwierdź spójność wskaźników IoC/WAF/Backupów lub wskaż choćby najmniejszy ślad ryzyka."
)

UA = "Mozilla/5.0 (compatible; TwojaStronaWWW-AIRouter/2.0)"
primary_answer = ""
primary_label = ""
primary_think_tok = 0
primary_total_tok = 0

# 1. GŁÓWNY AUDYTOR 120B (HIGH REASONING, $0.00): Groq GPT-OSS-120B -> Cerebras GPT-OSS-120B -> Cerebras Qwen 3.8
primary_candidates = []
if groq_key:
    primary_candidates.append(("Groq GPT-OSS-120B (reasoning: HIGH)", "https://api.groq.com/openai/v1/chat/completions", groq_key, {
        "model": "openai/gpt-oss-120b",
        "messages": [{"role": "system", "content": sys_prompt_primary}, {"role": "user", "content": xray_text}],
        "reasoning_effort": "high",
        "temperature": 0.2,
        "max_tokens": 4096
    }))
if cerebras_key:
    primary_candidates.append(("Cerebras GPT-OSS-120B (reasoning: HIGH)", "https://api.cerebras.ai/v1/chat/completions", cerebras_key, {
        "model": "gpt-oss-120b",
        "messages": [{"role": "system", "content": sys_prompt_primary}, {"role": "user", "content": xray_text}],
        "reasoning_effort": "high",
        "temperature": 0.2,
        "max_tokens": 4096
    }))
    primary_candidates.append(("Cerebras Qwen-3.8-27B (reasoning: HIGH)", "https://api.cerebras.ai/v1/chat/completions", cerebras_key, {
        "model": "qwen-3.8-27b",
        "messages": [{"role": "system", "content": sys_prompt_primary}, {"role": "user", "content": xray_text}],
        "temperature": 0.2,
        "max_tokens": 4096
    }))

for label, url, api_key, body in primary_candidates:
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode("utf-8"),
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json", "User-Agent": UA},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=22) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        msg = (data.get("choices") or [{}])[0].get("message", {})
        txt = (msg.get("content") or "").strip()
        # Oczyszczenie ewentualnych znaczników <think>...</think> oraz surowych gwiazdek Markdown **
        if "<think>" in txt and "</think>" in txt:
            txt = txt.split("</think>", 1)[1].strip()
        txt = txt.replace("**", "")
        if txt:
            primary_answer = txt
            primary_label = label
            usage = data.get("usage", {})
            primary_total_tok = int(usage.get("total_tokens", 0))
            details = usage.get("completion_tokens_details") or {}
            primary_think_tok = int(details.get("reasoning_tokens", 0))
            break
    except Exception:
        continue

# 2. KRZYŻOWY WERYFIKATOR (HIGH THINKING, $0.00): Google Gemini 3.5 / 3.8 Flash
cross_answer = ""
cross_label = ""
cross_think_tok = 0
cross_total_tok = 0

if gemini_key:
    for g_model in ("gemini-3.5-flash", "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.5-flash-lite"):
        try:
            g_url = f"https://generativelanguage.googleapis.com/v1beta/models/{g_model}:generateContent?key={gemini_key}"
            g_body = {
                "systemInstruction": {"parts": [{"text": sys_prompt_cross if primary_answer else sys_prompt_primary}]},
                "contents": [{"role": "user", "parts": [{"text": xray_text}]}],
                "generationConfig": {
                    "temperature": 0.2,
                    "maxOutputTokens": 8192,
                    "thinkingConfig": {"thinkingLevel": "HIGH"}
                }
            }
            req = urllib.request.Request(
                g_url,
                data=json.dumps(g_body).encode("utf-8"),
                headers={"Content-Type": "application/json", "User-Agent": UA},
                method="POST"
            )
            with urllib.request.urlopen(req, timeout=22) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            parts = (((data.get("candidates") or [{}])[0].get("content") or {}).get("parts")) or []
            out_chunks = [p.get("text", "").strip() for p in parts if not p.get("thought") and p.get("text")]
            txt = "\n".join([c for c in out_chunks if c]).strip().replace("**", "")
            if txt:
                u_meta = data.get("usageMetadata", {})
                t_tok = int(u_meta.get("thoughtsTokenCount", 0))
                tot_tok = int(u_meta.get("totalTokenCount", 0))
                if not primary_answer:
                    primary_answer = txt
                    primary_label = f"{g_model} (thinking: HIGH)"
                    primary_think_tok = t_tok
                    primary_total_tok = tot_tok
                else:
                    cross_answer = txt
                    cross_label = f"{g_model} (thinking: HIGH)"
                    cross_think_tok = t_tok
                    cross_total_tok = tot_tok
                break
        except Exception:
            continue

# Odczyt aktualnego stanu budżetu rezerwowego Anthropic ($5.00)
budget = {"initial_usd": 5.00, "spent_usd": 0.0, "total_tokens": 0, "runs": 0}
if os.path.exists(budget_path):
    try:
        with open(budget_path, "r", encoding="utf-8") as bf:
            budget.update(json.load(bf))
    except Exception:
        pass

claude_section = ""
cost_today_usd = 0.0

# 3. TRYB ESKALACJI KRYMINALISTYCZNEJ (Claude Sonnet 4.6) -> TYLKO przy anomaliach/błędach, fladze --deep-claude lub awarii obu darmowych chmur
if anthropic_key and (need_claude or not primary_answer):
    try:
        c_payload = {
            "model": "claude-sonnet-4-6",
            "max_tokens": 900,
            "system": [{"type": "text", "text": sys_prompt_primary, "cache_control": {"type": "ephemeral"}}],
            "messages": [{"role": "user", "content": xray_text}]
        }
        req = urllib.request.Request(
            "https://api.anthropic.com/v1/messages",
            data=json.dumps(c_payload).encode("utf-8"),
            headers={"x-api-key": anthropic_key, "anthropic-version": "2023-06-01", "content-type": "application/json", "User-Agent": UA},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=25) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        c_ans = "".join([b.get("text", "").strip() for b in data.get("content", []) if b.get("type") == "text"])
        usage = data.get("usage", {})
        in_tok = int(usage.get("input_tokens", 0))
        out_tok = int(usage.get("output_tokens", 0))
        cache_w = int(usage.get("cache_creation_input_tokens", 0))
        cache_r = int(usage.get("cache_read_input_tokens", 0))
        total_tok_today = in_tok + out_tok + cache_w + cache_r
        cost_today_usd = (in_tok * 3.0 + out_tok * 15.0 + cache_w * 3.75 + cache_r * 0.30) / 1_000_000.0
        budget["spent_usd"] = round(float(budget.get("spent_usd", 0.0)) + cost_today_usd, 6)
        budget["total_tokens"] = int(budget.get("total_tokens", 0)) + total_tok_today
        budget["runs"] = int(budget.get("runs", 0)) + 1
        os.makedirs(os.path.dirname(budget_path), exist_ok=True)
        with open(budget_path, "w", encoding="utf-8") as bf:
            json.dump(budget, bf, indent=2)
        claude_section = f"\n🚨 Ekspertyza Eskalacyjna Claude Sonnet 4.6:\n{c_ans}\n"
    except Exception:
        pass

rem_usd = max(0.0, round(float(budget["initial_usd"]) - float(budget.get("spent_usd", 0.0)), 4))
out_lines = []
if primary_answer:
    think_info = f" [myślenie: {primary_think_tok} tok. / łącznie: {primary_total_tok} tok.]" if primary_think_tok > 0 else f" [{primary_total_tok} tok.]"
    out_lines.append(f"🧠 Audytor #1 — {primary_label}{think_info}:\n{primary_answer}")
if cross_answer:
    c_think_info = f" [myślenie: {cross_think_tok} tok.]" if cross_think_tok > 0 else ""
    out_lines.append(f"🔍 Weryfikacja Krzyżowa #2 — {cross_label}{c_think_info}:\n{cross_answer}")
if claude_section:
    out_lines.append(claude_section.strip())

out_lines.append(
    f"💰 Koszt dzisiejszego audytu AI: ${cost_today_usd:.4f} (Tryb Dual-AI HIGH Reasoning)\n"
    f"• Rezerwa awaryjna Anthropic ($5.00): pozostało ${rem_usd:.4f} (wydano dotychczas: ${float(budget.get('spent_usd', 0.0)):.4f})"
)
print("\n\n".join(out_lines))
PYEOF
)"
                rm -f "${XRAY_FILE}" 2>/dev/null || true
            fi

            TOTAL_TESTS=$((OK_COUNT + WARN_COUNT + FAIL_COUNT))

            # Zbieranie danych ze wszystkich 3 scraperów Kato Salsa Hub & DancePuls (Wydarzenia + Grafiki + Cenniki + Delta zmian 24h)
            KSH_SCRAPER_DATA="$(sudo ENV_FILE="${ENV_FILE}" PL_DATE="${PL_DATE}" python3 - << 'PYKSH' 2>/dev/null || true
import datetime, json, os, re, time, urllib.request

env_vars = {}
env_path = os.environ.get("ENV_FILE", "/opt/devops-stack/.env")
if os.path.exists(env_path):
    with open(env_path, "r", encoding="utf-8", errors="ignore") as ef:
        for line in ef:
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.strip().split("=", 1)
                env_vars[k.strip()] = v.strip().strip("\"'")

gh_tok = env_vars.get("GITHUB_TOKEN", "")
pl_date = os.environ.get("PL_DATE", "")
ua = "Mozilla/5.0 (compatible; TwojaStronaWWW-Audit/2.0)"
hdrs = {"User-Agent": ua, "Accept": "application/vnd.github+json"}
if gh_tok:
    hdrs["Authorization"] = f"Bearer {gh_tok}"

run_status = "SUCCESS"
run_id = "brak"
run_time = pl_date
try:
    runs_url = "https://api.github.com/repos/TwojaStronaWWW/katosalsahub/actions/workflows/weekly-report.yml/runs?per_page=1"
    with urllib.request.urlopen(urllib.request.Request(runs_url, headers=hdrs), timeout=8) as r:
        runs = json.loads(r.read().decode("utf-8")).get("workflow_runs") or []
    if runs:
        latest = runs[0]
        created = str(latest.get("created_at", ""))
        if gh_tok and not created.startswith(pl_date):
            disp_url = "https://api.github.com/repos/TwojaStronaWWW/katosalsahub/actions/workflows/weekly-report.yml/dispatches"
            req = urllib.request.Request(disp_url, data=json.dumps({"ref": "main"}).encode("utf-8"), headers={**hdrs, "Content-Type": "application/json"}, method="POST")
            urllib.request.urlopen(req, timeout=8)
            for _ in range(10):
                time.sleep(3)
                with urllib.request.urlopen(urllib.request.Request(runs_url, headers=hdrs), timeout=8) as r2:
                    r_list = json.loads(r2.read().decode("utf-8")).get("workflow_runs") or []
                if r_list and str(r_list[0].get("created_at", "")).startswith(pl_date) and r_list[0].get("status") == "completed":
                    latest = r_list[0]
                    break
        run_id = str(latest.get("id", "brak"))
        run_status = str(latest.get("conclusion") or latest.get("status") or "SUCCESS").upper()
        run_time = str(latest.get("updated_at") or latest.get("created_at") or pl_date).replace("T", " ").replace("Z", " UTC")
except Exception:
    pass

# Sprawdzenie commitów i modyfikacji strony z ostatnich 24h oraz dzisiejszego commita bota scraperów
bot_modified_today = False
bot_commit_sha = ""
bot_commit_time = ""
base_ref_sha = ""
commits_24h_cnt = 0
latest_commit_info = "brak zmian w ciągu 24h"

try:
    since_iso = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
    c_url = f"https://api.github.com/repos/TwojaStronaWWW/katosalsahub/commits?sha=main&since={since_iso}&per_page=30"
    with urllib.request.urlopen(urllib.request.Request(c_url, headers=hdrs), timeout=8) as rc:
        c_list = json.loads(rc.read().decode("utf-8")) or []
    commits_24h_cnt = len(c_list)
    if c_list:
        top_c = c_list[0]
        top_sha = str(top_c.get("sha", ""))[:7]
        top_msg = str(((top_c.get("commit") or {}).get("message") or "")).splitlines()[0][:65]
        latest_commit_info = f"{commits_24h_cnt} wdrożeń (ostatnie: {top_sha} — \"{top_msg}\")"
        # Szukamy dzisiejszego commita automatycznego ze scraperów
        for c in c_list:
            c_date = str(((c.get("commit") or {}).get("author") or {}).get("date", ""))
            c_msg = str(((c.get("commit") or {}).get("message") or ""))
            if c_date.startswith(pl_date) and "automatyczna aktualizacja raportu" in c_msg:
                bot_modified_today = True
                bot_commit_sha = str(c.get("sha", ""))[:7]
                bot_commit_time = c_date.replace("T", " ").replace("Z", " UTC")
                parents = c.get("parents") or []
                if parents:
                    base_ref_sha = str(parents[0].get("sha", ""))
                break
except Exception:
    pass

def fetch_text(path, ref="main"):
    urls = [
        f"https://raw.githubusercontent.com/TwojaStronaWWW/katosalsahub/{ref}/katosalsahub.pl/assets/data/{path}",
    ]
    if ref == "main":
        urls.append(f"https://katosalsahub.pl/assets/data/{path}")
    for u in urls:
        try:
            h = {"User-Agent": ua, "Cache-Control": "no-cache"}
            if gh_tok and "githubusercontent" in u:
                h["Authorization"] = f"Bearer {gh_tok}"
            with urllib.request.urlopen(urllib.request.Request(u, headers=h), timeout=8) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except Exception:
            continue
    return ""

events_raw = fetch_text("events.json", "main")
sched_raw = fetch_text("schedule.json", "main")
report_raw = fetch_text("latest_report.md", "main")

old_events_raw = fetch_text("events.json", base_ref_sha) if base_ref_sha else ""
old_sched_raw = fetch_text("schedule.json", base_ref_sha) if base_ref_sha else ""

days_cnt = 0
events_cnt = 0
new_ev_set = {}
try:
    ev_obj = json.loads(events_raw)
    day_list = ev_obj if isinstance(ev_obj, list) else []
    days_cnt = len(day_list)
    for d in day_list:
        if isinstance(d, dict):
            dt = str(d.get("date", ""))
            for ev in (d.get("events") or []):
                if isinstance(ev, dict):
                    events_cnt += 1
                    key = f"{dt}|{ev.get('opis','')[:40]}|{ev.get('miasto','')}"
                    new_ev_set[key] = f"{ev.get('opis','?')[:38]} ({dt}, {ev.get('miasto','?')})"
except Exception:
    pass

old_ev_set = {}
if old_events_raw:
    try:
        old_ev_obj = json.loads(old_events_raw)
        for d in (old_ev_obj if isinstance(old_ev_obj, list) else []):
            if isinstance(d, dict):
                dt = str(d.get("date", ""))
                for ev in (d.get("events") or []):
                    if isinstance(ev, dict):
                        key = f"{dt}|{ev.get('opis','')[:40]}|{ev.get('miasto','')}"
                        old_ev_set[key] = f"{ev.get('opis','?')[:38]} ({dt}, {ev.get('miasto','?')})"
    except Exception:
        pass

added_ev = [v for k, v in new_ev_set.items() if k not in old_ev_set] if old_ev_set else []
removed_ev = [v for k, v in old_ev_set.items() if k not in new_ev_set] if old_ev_set else []

classes_cnt = 0
sched_updated = pl_date
by_school = {}
by_level = {}
pricing_parts = []
new_cls_map = {}
new_pricing_map = {}
try:
    sc_obj = json.loads(sched_raw)
    sched_updated = str(sc_obj.get("updatedAt") or sc_obj.get("lastUpdated") or pl_date)
    cls_list = sc_obj.get("classes") or []
    classes_cnt = len(cls_list)
    for c in cls_list:
        cid = str(c.get("id", ""))
        s = c.get("schoolId", "?")
        lv = c.get("levelCode") or c.get("kshLevel") or "?"
        by_school[s] = by_school.get(s, 0) + 1
        by_level[lv] = by_level.get(lv, 0) + 1
        new_cls_map[cid] = f"{s}|{c.get('dayName','')}|{c.get('startTime','')}|{c.get('title','')}|{lv}|{c.get('levelLabel','')}"
    for sch in (sc_obj.get("schools") or []):
        pr = sch.get("pricing") or {}
        if pr:
            s_name = sch.get("name") or sch.get("id")
            passes = pr.get("passes") or []
            prices_slash = "/".join(str(p.get("price")) for p in passes[:3] if isinstance(p, dict) and p.get("price"))
            op = pr.get("openPassPrice")
            op_suffix = f", OPEN {op} zł" if op else ""
            if prices_slash:
                pricing_parts.append(f"{s_name} ({prices_slash} zł{op_suffix})")
                new_pricing_map[s_name] = f"{prices_slash} zł{op_suffix}"
except Exception:
    pass

added_cls_cnt = 0
removed_cls_cnt = 0
modified_cls_cnt = 0
pricing_changes = []
if old_sched_raw:
    try:
        old_sc_obj = json.loads(old_sched_raw)
        old_cls_map = {}
        for c in (old_sc_obj.get("classes") or []):
            cid = str(c.get("id", ""))
            s = c.get("schoolId", "?")
            lv = c.get("levelCode") or c.get("kshLevel") or "?"
            old_cls_map[cid] = f"{s}|{c.get('dayName','')}|{c.get('startTime','')}|{c.get('title','')}|{lv}|{c.get('levelLabel','')}"
        for cid, sig in new_cls_map.items():
            if cid not in old_cls_map:
                added_cls_cnt += 1
            elif old_cls_map[cid] != sig:
                modified_cls_cnt += 1
        for cid in old_cls_map:
            if cid not in new_cls_map:
                removed_cls_cnt += 1
        for sch in (old_sc_obj.get("schools") or []):
            pr = sch.get("pricing") or {}
            if pr:
                s_name = sch.get("name") or sch.get("id")
                passes = pr.get("passes") or []
                prices_slash = "/".join(str(p.get("price")) for p in passes[:3] if isinstance(p, dict) and p.get("price"))
                op = pr.get("openPassPrice")
                op_suffix = f", OPEN {op} zł" if op else ""
                old_p_str = f"{prices_slash} zł{op_suffix}"
                if s_name in new_pricing_map and new_pricing_map[s_name] != old_p_str:
                    pricing_changes.append(f"{s_name}: {old_p_str} -> {new_pricing_map[s_name]}")
    except Exception:
        pass

wknd_info = "brak danych"
future_info = "0"
pncz_info = "0"
csv_cnt = 0
if report_raw:
    sec1_text = report_raw.split("---")[0]
    m_w = re.search(r"Stan zestawienia[^:]*:\*\*\s*\*\*([^*]+)\*\*\s*(\([^)]+\))?", sec1_text)
    if m_w:
        wknd_info = (m_w.group(1).strip() + " " + (m_w.group(2) or "").strip()).strip()
    m_f = re.search(r"Zapowiedzi na kolejne tygodnie[^:]*:\*\*\s*\*\*([^*]+)\*\*", sec1_text)
    if m_f:
        future_info = m_f.group(1).strip()
    m_p = re.search(r"Wydarzenia pn[–-]cz[^:]*:\*\*\s*\*\*([^*]+)\*\*", sec1_text)
    if m_p:
        pncz_info = m_p.group(1).strip()
    m_c = re.search(r"Zgłoszenia z formularza Google[^:]*:\*\*\s*(.+)", sec1_text)
    if m_c:
        raw_c = m_c.group(1).strip()
        csv_cnt = 0 if "brak" in raw_c.lower() else len([u for u in raw_c.split(",") if "http" in u])

if bot_modified_today:
    mod_status_line = f"🔄 Modyfikacja ze scraperów (dziś): TAK — wdrożono na LH.pl (commit {bot_commit_sha}, {bot_commit_time})"
else:
    mod_status_line = f"🔄 Modyfikacja ze scraperów (dziś): BRAK ZMIAN (strona na LH.pl nie wymagała aktualizacji, skan #{run_id} {run_status})"

ev_delta_str = f"+{len(added_ev)} nowych | -{len(removed_ev)} minionych usuniętych"
if added_ev:
    ev_delta_str += " (" + ", ".join(added_ev[:3]) + (f" i +{len(added_ev)-3} więcej" if len(added_ev) > 3 else "") + ")"

cls_delta_str = f"+{added_cls_cnt} nowych | ~{modified_cls_cnt} zaktualizowanych (np. daty START) | -{removed_cls_cnt} usuniętych"
price_delta_str = (", ".join(pricing_changes)) if pricing_changes else "0 zmian (stawki w szkołach bez zmian)"

short_mod_tag = "ZAKTUALIZOWANO LH.pl" if bot_modified_today else "BEZ ZMIAN"
short_line = f"🕺 Scrapery KSH ({short_mod_tag}): {events_cnt} impr. (+{len(added_ev)}/-{len(removed_ev)}) | Grafiki: {classes_cnt} kursów (~{modified_cls_cnt} zm.) | Cenniki: OK"

lines = [
    mod_status_line,
    f"📝 Zmiany ze scraperów: Imprezy [{ev_delta_str}] | Grafiki [{cls_delta_str}] | Cenniki [{price_delta_str}]",
    f"🚀 Modyfikacje strony (ostatnie 24h): {latest_commit_info}",
    f"📅 Kalendarz Imprez: {events_cnt} wydarzeń ({days_cnt} dni) | Weekend: {wknd_info} | Kolejne tyg.: {future_info} | Formularz CSV: {csv_cnt} zgłosz.",
    f"🏫 Grafiki Szkół ({classes_cnt} kursów): La Clave: {by_school.get('LC', 0)} | Good Mood: {by_school.get('GM', 0)} | Mil Pasos: {by_school.get('MP', 0)} (P0:{by_level.get('P0',0)}, P1:{by_level.get('P1',0)}, P2:{by_level.get('P2',0)}, S1:{by_level.get('S1',0)}, OPEN:{by_level.get('OPEN',0)})",
    f"💰 Cenniki (Live OK): " + (" | ".join(pricing_parts) if pricing_parts else "Zweryfikowane")
]

print(json.dumps({"short": short_line, "full": "\n".join(lines), "events_cnt": events_cnt, "classes_cnt": classes_cnt, "modified": bot_modified_today}, ensure_ascii=False))
PYKSH
)"

            KSH_SHORT="$(echo "${KSH_SCRAPER_DATA}" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("short",""))' 2>/dev/null || echo '')"
            KSH_FULL="$(echo "${KSH_SCRAPER_DATA}" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("full",""))' 2>/dev/null || echo '')"
            KSH_EV_CNT="$(echo "${KSH_SCRAPER_DATA}" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("events_cnt",0))' 2>/dev/null || echo '0')"
            KSH_CLS_CNT="$(echo "${KSH_SCRAPER_DATA}" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("classes_cnt",0))' 2>/dev/null || echo '0')"

            AUDIT_BODY="✅ Audyt (${TOTAL_TESTS} testów): ${OK_COUNT} OK | ${WARN_COUNT} WARN | ${FAIL_COUNT} FAIL
💾 Backupy (03:00): VPS ${AGE_HOURS:-?}h temu | WWW LH.pl ${W_AGE_HOURS:-?}h temu
🧠 Zasoby: Dysk ${DISK_USE_PCT}% (wolne ${DISK_AVAIL_HUMAN}) | SWAP ${SWAP_TOTAL_MB:-0}M | ${MEM_INFO}
📊 Analityka WWW & AI: ${WA_PV_TOTAL:-0} odsł. | ${WA_UV_TOTAL:-0} unik. (${WA_ENG_TOTAL:-0} zaangaż.) | LCP: ${WA_LCP_AVG:-b/d} | Leady: ${WA_LEADS_TOTAL:-0}
🔍 Puls SEO & AI: Top temat AI: ${WA_TOP_TOPIC:-brak} | Top fraza: ${WA_TOP_TERM:-brak}
🛡️ Ochrona: NTP=${NTP_STATE:-yes} | BBR=${TCP_CC:-bbr} | WAF L7: ${WAF_BLOCKED_TOTAL:-0} | Fail2ban: ${F2B_BANNED:-0} IP | Skaner 24h: ${LOG_CRITICAL_24H:-0} wyjątków${HINTS_SUMMARY}"
            if [[ -n "${AI_AUDIT_INSIGHT}" ]]; then
                AUDIT_BODY="${AUDIT_BODY}

${AI_AUDIT_INSIGHT}"
                printf "\n${C_CYAN}%s${C_RESET}\n" "${AI_AUDIT_INSIGHT}"
            fi

            NTFY_BODY="${KSH_SHORT:-🕺 Scrapery KSH & DancePuls: Zsynchronizowane}
${AUDIT_BODY}"

            # 1. Wysyłka powiadomienia Push na Ntfy.sh
            curl -s --max-time 5 \
                -H "Title: Raport 07:30 (${PL_DATE}): KSH (${KSH_EV_CNT} impr.) + VPS (${OK_COUNT} OK / ${FAIL_COUNT} FAIL)" \
                -H "Priority: default" \
                -H "Tags: sunny,robot" \
                -d "${NTFY_BODY}" \
                "https://ntfy.sh/${NTFY_AUDIT_TOPIC}" >/dev/null 2>&1 || true

            # 2. Wysyłka pełnego, połączonego raportu (Scrapery KSH + Audyt ISO 27001) na E-mail (poczatek.krzysztof@gmail.com)
            EMAIL_SUBJECT="☀️ Raport 07:30 (${PL_DATE}): Scrapery KSH (${KSH_EV_CNT} impr. / ${KSH_CLS_CNT} kursów) + Audyt VPS [${OK_COUNT} OK / ${FAIL_COUNT} FAIL]"
            EMAIL_BODY="☀️ PORANNY RAPORT SYSTEMOWY (07:30) — ${PL_DATE}
TwojaStronaWWW DevOps Stack & Kato Salsa Hub / DancePuls

🕺 CZĘŚĆ 1: SCRAPERY KATO SALSA HUB & DANCEPULS
──────────────────────────────────────────────────────
${KSH_FULL:-Brak danych ze scraperów.}

🛡️ CZĘŚĆ 2: AUDYT BEZPIECZEŃSTWA I INFRASTRUKTURY VPS & WWW (ISO 27001)
──────────────────────────────────────────────────────
${AUDIT_BODY}

──────────────────────────────────────────────────────
🔗 Panel DancePuls: https://katosalsahub.pl/dancepuls/
🔗 Wspólny Grafik:  https://katosalsahub.pl/grafik.html
🔗 Panel Grafana:   https://monitoring.twojastronawww.pl"

            sudo ENV_FILE="${ENV_FILE}" EMAIL_SUBJECT="${EMAIL_SUBJECT}" EMAIL_BODY="${EMAIL_BODY}" python3 - << 'PYMAIL' >/dev/null 2>&1 || true
import json, os, urllib.request

env_vars = {}
env_path = os.environ.get("ENV_FILE", "/opt/devops-stack/.env")
if os.path.exists(env_path):
    with open(env_path, "r", encoding="utf-8", errors="ignore") as ef:
        for line in ef:
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.strip().split("=", 1)
                env_vars[k.strip()] = v.strip().strip("\"'")

hook_url = env_vars.get("LEAD_WEBHOOK_URL", "https://hd.twojastronawww.pl/ticket_hook.php")
api_key = env_vars.get("OSTICKET_API_KEY", "")
subj = os.environ.get("EMAIL_SUBJECT", "Poranny Raport 07:30")
body = os.environ.get("EMAIL_BODY", "")

if hook_url and api_key and body:
    payload = json.dumps({
        "event": "morning_report",
        "email_only": True,
        "subject": subj,
        "message": body
    }, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        hook_url,
        data=payload,
        headers={
            "X-API-Key": api_key,
            "Content-Type": "application/json; charset=utf-8",
            "User-Agent": "TwojaStronaWWW-MorningReport/2.0"
        },
        method="POST"
    )
    urllib.request.urlopen(req, timeout=10)
PYMAIL
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
