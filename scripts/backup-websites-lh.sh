#!/usr/bin/env bash
# ==============================================================================
# backup-websites-lh.sh
# Automatyczny backup serwisów WWW z hostingu LH.pl na serwer VPS (ISO 27001)
# Pobiera zawartość stron przez bezpieczny transfer FTP/SFTP, kompresuje
# i opcjonalnie przesyła kopię offsite do Cloudflare R2 / S3.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Ładowanie zmiennych środowiskowych jeśli plik .env istnieje
if [[ -f "${STACK_ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${STACK_ROOT}/.env"
    set +a
fi

umask 077
BACKUP_DIR="${LH_BACKUP_DIR:-/opt/devops-stack/backups/websites}"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
R2_RETENTION_DAYS="${R2_RETENTION_DAYS:-14}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_URL="${NTFY_URL:-https://ntfy.sh/${NTFY_TOPIC}}"
METRICS_DIR="${PROMETHEUS_METRICS_DIR:-${STACK_ROOT}/config/node-exporter}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

# Konfiguracja hostingu LH.pl (wartości pobierane z GitHub Secrets / .env)
LH_FTP_SERVER="${LH_FTP_SERVER:-}"
LH_FTP_PORT="${LH_FTP_PORT:-21}"
LH_FTP_USERNAME="${LH_FTP_USERNAME:-}"
LH_FTP_PASSWORD="${LH_FTP_PASSWORD:-}"
LH_REMOTE_DIR="${LH_REMOTE_DIR:-/public_html}"
LH_FTP_SSL="${LH_FTP_SSL:-true}"
LH_FTP_VERIFY_CERT="${LH_FTP_VERIFY_CERT:-no}"

# Opcjonalny backup baz danych MySQL/MariaDB z LH.pl (np. osTicket Helpdesk, WordPress - lista po przecinku LH_DB_NAMES lub pojedyncza LH_DB_NAME)
LH_DB_HOST="${LH_DB_HOST:-}"
LH_DB_NAME="${LH_DB_NAME:-}"
LH_DB_NAMES="${LH_DB_NAMES:-${LH_DB_NAME}}"
LH_DB_USER="${LH_DB_USER:-}"
LH_DB_PASSWORD="${LH_DB_PASSWORD:-${LH_DB_PASS:-}}"

# S3 / Cloudflare R2 + opcjonalne szyfrowanie symetryczne AES-256-CBC (ISO 27001)
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_BUCKET="${S3_BUCKET:-twojastronawww-backups}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${S3_SECRET_KEY:-}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"

START_TIME="$(date +%s)"
STATUS=0
OFFSITE_STATUS=0
BACKUP_VERIFIED=0
DB_BACKUP_VERIFIED=1
BUNDLE_SIZE_BYTES=0
STAGING_DIR=""

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}" 2>/dev/null || true

send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    local tags="${4:-package}"

    if [[ -z "${NTFY_TOPIC}" ]]; then
        return 0
    fi

    curl -s \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -H "Tags: ${tags}" \
        -d "${message}" \
        "${NTFY_URL}" >/dev/null 2>&1 || true
}

write_prometheus_metrics() {
    local status="$1"
    local offsite_status="$2"
    local size_bytes="$3"
    local end_time
    end_time="$(date +%s)"
    local duration=$(( end_time - START_TIME ))

    if [[ -d "${METRICS_DIR}" ]]; then
        local metrics_file="${METRICS_DIR}/backup_websites.prom"
        cat <<EOF > "${metrics_file}.tmp"
# HELP devops_backup_websites_last_timestamp_seconds Czas uniksowy zakonczenia ostatniego backupu stron LH
# TYPE devops_backup_websites_last_timestamp_seconds gauge
devops_backup_websites_last_timestamp_seconds ${end_time}

# HELP devops_backup_websites_status Status wykonania backupu stron WWW (1 = sukces, 0 = oczekuje/blad)
# TYPE devops_backup_websites_status gauge
devops_backup_websites_status ${status}

# HELP devops_backup_websites_verified Status weryfikacji integralnosci archiwum stron WWW tar -tzf (1 = poprawne, 0 = blad)
# TYPE devops_backup_websites_verified gauge
devops_backup_websites_verified ${BACKUP_VERIFIED}

# HELP devops_backup_websites_db_verified Status weryfikacji zrzutow baz MySQL z LH.pl (1 = poprawne lub niewymagane, 0 = blad zrzutu)
# TYPE devops_backup_websites_db_verified gauge
devops_backup_websites_db_verified ${DB_BACKUP_VERIFIED}

# HELP devops_backup_websites_size_bytes Rozmiar archiwum kopii stron WWW w bajtach
# TYPE devops_backup_websites_size_bytes gauge
devops_backup_websites_size_bytes ${size_bytes}

# HELP devops_backup_websites_offsite_status Status wysylki kopii stron offsite do chmury (1 = wyslano, 0 = brak/blad)
# TYPE devops_backup_websites_offsite_status gauge
devops_backup_websites_offsite_status ${offsite_status}

# HELP devops_backup_websites_duration_seconds Czas trwania procedury backupu stron w sekundach
# TYPE devops_backup_websites_duration_seconds gauge
devops_backup_websites_duration_seconds ${duration}
EOF
        mv "${metrics_file}.tmp" "${metrics_file}"
        chmod 644 "${metrics_file}" 2>/dev/null || true
        echo "--> [METRYKI] Zaktualizowano metryki stron WWW: ${metrics_file}"
    fi
}

cleanup_staging() {
    docker run --rm -v "${BACKUP_DIR}:/backups" alpine:latest \
        sh -c "rm -rf /backups/staging_*" >/dev/null 2>&1 || true
    rm -rf "${BACKUP_DIR}"/staging_* 2>/dev/null || true
}

on_error() {
    local exit_code=$?
    local line_no="${1:-unknown}"
    echo "==> [BŁĄD KRYTYCZNY] Procedura backupu stron LH przerwana na linii ${line_no} (kod: ${exit_code})!"
    cleanup_staging
    write_prometheus_metrics 0 0 0
    send_notification \
        "🚨 Błąd: Backup Stron LH.pl Przerwany!" \
        "Nocny backup stron WWW zakończył się błędem na linii ${line_no} (kod wyjścia: ${exit_code}). Sprawdź logi: journalctl -u devops-backup.service" \
        "high" \
        "rotating_light,warning"
    exit "${exit_code}"
}
trap 'on_error $LINENO' ERR

echo "=============================================================================="
echo "==> Rozpoczynanie procedury backupu stron WWW z hostingu LH: ${TIMESTAMP}"
echo "=============================================================================="

if [[ -z "${LH_FTP_SERVER}" || -z "${LH_FTP_USERNAME}" || -z "${LH_FTP_PASSWORD}" ]]; then
    echo "--> [INFO] Brak skonfigurowanych danych dostępowych LH.pl w .env (LH_FTP_SERVER / USERNAME / PASSWORD)."
    echo "--> Pobierz dane z GitHub Secrets i uzupełnij plik .env na serwerze."
    write_prometheus_metrics 0 0 0
    exit 0
fi

# Czyszczenie ewentualnych pozostałości po wcześniejszych przerwanych przebiegach
cleanup_staging

STAGING_DIR="${BACKUP_DIR}/staging_${TIMESTAMP}"
ARCHIVE_NAME="lh_websites_backup_${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"

echo "--> [1/3] Pobieranie plików stron z hostingu LH (${LH_FTP_SERVER}, FTPS SSL=${LH_FTP_SSL})..."
mkdir -p "${STAGING_DIR}"

# Pobieranie danych za pomocą dedykowanego, izolowanego kontenera z lftp (z obsługą FTPS TLS)
# Flaga --no-perms oraz normalizacja właściciela (HOST_UID:HOST_GID) i uprawnień (u+rwX) zapobiegają
# błędom "tar: ./.env: Permission denied" dla plików z restrykcyjnym chmod 0600 na serwerze FTP.
LFTP_CMD_FILE="$(mktemp)"
chmod 600 "${LFTP_CMD_FILE}"
cat <<EOF > "${LFTP_CMD_FILE}"
set ftp:ssl-allow ${LH_FTP_SSL}
set ftp:ssl-protect-data true
set ssl:verify-certificate ${LH_FTP_VERIFY_CERT}
set net:timeout 15
set net:max-retries 3
open -p "${LH_FTP_PORT}" -u "${LH_FTP_USERNAME}","${LH_FTP_PASSWORD}" "${LH_FTP_SERVER}"
mirror --verbose --delete --no-perms --parallel=3 "${LH_REMOTE_DIR}" /target
quit
EOF

docker run --rm \
    -v "${STAGING_DIR}:/target" \
    -v "${LFTP_CMD_FILE}:/cmd:ro" \
    alpine:latest \
    sh -c "apk add --no-cache lftp ca-certificates >/dev/null 2>&1 && lftp -f /cmd && chown -R ${HOST_UID}:${HOST_GID} /target && chmod -R u+rwX /target"

rm -f "${LFTP_CMD_FILE}"

# Opcjonalny zrzut baz danych MySQL/MariaDB (np. osTicket Helpdesk, WordPress) z weryfikacją spójności gzip + Dump completed
if [[ -n "${LH_DB_HOST}" && -n "${LH_DB_NAMES}" && -n "${LH_DB_USER}" && -n "${LH_DB_PASSWORD}" ]]; then
    IFS=',' read -r -a DB_ARRAY <<< "${LH_DB_NAMES}"
    for raw_db in "${DB_ARRAY[@]}"; do
        db_name="$(echo "${raw_db}" | tr -d '[:space:]')"
        [[ -z "${db_name}" ]] && continue
        echo "--> [1b/3] Wykonywanie i weryfikacja zrzutu bazy danych MySQL (${db_name}@${LH_DB_HOST})..."
        if docker run --rm \
            -v "${STAGING_DIR}:/target" \
            -e MYSQL_PWD="${LH_DB_PASSWORD}" \
            alpine:latest \
            sh -c "set -o pipefail && apk add --no-cache mysql-client gzip >/dev/null 2>&1 && mysqldump --single-transaction --quick -h '${LH_DB_HOST}' -u '${LH_DB_USER}' '${db_name}' | gzip -9 > '/target/_db_${db_name}.sql.gz' && gzip -t '/target/_db_${db_name}.sql.gz' && zcat '/target/_db_${db_name}.sql.gz' | tail -n 5 | grep -q 'Dump completed' && chown ${HOST_UID}:${HOST_GID} '/target/_db_${db_name}.sql.gz'"; then
            echo "--> [OK] Zrzut bazy danych ${db_name} zweryfikowany (gzip -t + Dump completed) i zapisany w archiwum."
        else
            DB_BACKUP_VERIFIED=0
            echo "--> [WARN] Nie udało się wykonać lub zweryfikować zrzutu bazy danych MySQL: ${db_name}!"
            send_notification \
                "⚠️ Ostrzeżenie: Błąd zrzutu bazy MySQL (${db_name})" \
                "Podczas nocnego backupu stron LH.pl nie powiódł się zrzut bazy MySQL '${db_name}' (${LH_DB_HOST}). Kopia plików FTP jest kontynuowana." \
                "high" \
                "warning,database"
        fi
    done
fi

echo "--> [2/3] Kompresja i archiwizacja kopii stron WWW..."
tar -czf "${ARCHIVE_PATH}" -C "${STAGING_DIR}" .
cleanup_staging

echo "--> [2a/3] Weryfikacja integralności archiwum (tar -tzf)..."
if tar -tzf "${ARCHIVE_PATH}" >/dev/null 2>&1; then
    BACKUP_VERIFIED=1
    echo "--> [OK] Integralność archiwum stron WWW zweryfikowana pomyślnie."
else
    BACKUP_VERIFIED=0
    echo "--> [BŁĄD] Archiwum ${ARCHIVE_NAME} jest uszkodzone!"
    write_prometheus_metrics 0 0 0
    exit 1
fi

UPLOAD_NAME="${ARCHIVE_NAME}"
if [[ -n "${BACKUP_ENCRYPTION_KEY}" ]] && command -v openssl >/dev/null 2>&1; then
    echo "--> [2b/3] Szyfrowanie spoczynkowe archiwum (AES-256-CBC PBKDF2)..."
    BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY}" openssl enc -aes-256-cbc -pbkdf2 -salt \
        -in "${ARCHIVE_PATH}" \
        -out "${ARCHIVE_PATH}.enc" \
        -pass env:BACKUP_ENCRYPTION_KEY
    rm -f "${ARCHIVE_PATH}"
    ARCHIVE_NAME="${ARCHIVE_NAME}.enc"
    ARCHIVE_PATH="${ARCHIVE_PATH}.enc"
    UPLOAD_NAME="${ARCHIVE_NAME}"
fi

chmod 600 "${ARCHIVE_PATH}" 2>/dev/null || true
ARCHIVE_SIZE="$(du -h "${ARCHIVE_PATH}" | awk '{print $1}')"
BUNDLE_SIZE_BYTES="$(wc -c < "${ARCHIVE_PATH}" | tr -d ' ')"
STATUS=1
echo "--> [OK] Utworzono archiwum: ${ARCHIVE_NAME} (${ARCHIVE_SIZE})"

# Wysyłka offsite do chmury (R2 / S3) + rotacja chmurowa (RETENTION_DAYS)
if [[ -n "${S3_ACCESS_KEY}" && -n "${S3_SECRET_KEY}" && -n "${S3_ENDPOINT}" ]]; then
    echo "--> [3/3] Wysyłka archiwum stron offsite do chmury: ${S3_BUCKET}..."

    if docker run --rm \
        -v "${BACKUP_DIR}:/data:ro" \
        -e RCLONE_CONFIG_R2_TYPE=s3 \
        -e RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
        -e RCLONE_CONFIG_R2_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
        -e RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
        -e RCLONE_CONFIG_R2_ENDPOINT="${S3_ENDPOINT}" \
        -e RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
        rclone/rclone:latest \
        copy "/data/${UPLOAD_NAME}" "r2:${S3_BUCKET}/websites/"; then
        
        OFFSITE_STATUS=1
        echo "==> [SUKCES CHMURY] Backup stron ${ARCHIVE_NAME} wysłany do ${S3_BUCKET}/websites/."

        echo "--> [3a/3] Rotacja chmurowa R2: usuwanie kopii stron starszych niż ${R2_RETENTION_DAYS} dni (ochrona limitu 10 GB Free Tier)..."
        docker run --rm \
            -e RCLONE_CONFIG_R2_TYPE=s3 \
            -e RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
            -e RCLONE_CONFIG_R2_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
            -e RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
            -e RCLONE_CONFIG_R2_ENDPOINT="${S3_ENDPOINT}" \
            -e RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
            rclone/rclone:latest \
            delete --min-age "${R2_RETENTION_DAYS}d" "r2:${S3_BUCKET}/websites/" >/dev/null 2>&1 || true
        
        send_notification \
            "✅ Sukces: Backup Stron LH w Chmurze" \
            "Kopia ${ARCHIVE_NAME} (${ARCHIVE_SIZE}) została zsynchronizowana z LH i przesłana offsite do chmury (retencja lokalna: ${RETENTION_DAYS}d, R2: ${R2_RETENTION_DAYS}d)." \
            "low" \
            "globe,cloud"
    else
        OFFSITE_STATUS=0
        echo "==> [BŁĄD CHMURY] Błąd wysyłki stron offsite."
        send_notification \
            "⚠️ Błąd: Wysyłka stron do chmury nie powiodła się" \
            "Kopia lokalna ${ARCHIVE_NAME} została utworzona, ale transfer do chmury zakończył się błędem." \
            "high" \
            "warning"
    fi
else
    echo "--> [INFO] Klucze S3 nie są zdefiniowane. Kopia zapisana lokalnie: ${ARCHIVE_PATH}"
    OFFSITE_STATUS=0

    send_notification \
        "💾 Backup Stron LH Zakończony (Lokalnie)" \
        "Kopia ${ARCHIVE_NAME} (${ARCHIVE_SIZE}) zsynchronizowana z hostingu LH pomyślnie." \
        "low" \
        "floppy_disk"
fi

# Zapisanie metryk Prometheusa
write_prometheus_metrics "${STATUS}" "${OFFSITE_STATUS}" "${BUNDLE_SIZE_BYTES}"

# Rotacja starych kopii lokalnych (usuwanie kopii starszych niż RETENTION_DAYS dni)
echo "==> Rotacja lokalna: usuwanie kopii stron starszych niż ${RETENTION_DAYS} dni..."
find "${BACKUP_DIR}" -type f \( -name "lh_websites_backup_*.tar.gz" -o -name "lh_websites_backup_*.tar.gz.enc" \) -mtime +"${RETENTION_DAYS}" -exec rm -f {} +

echo "=============================================================================="
echo "==> [ZAKOŃCZONO] Procedura backupu stron LH zakończona pomyślnie (retencja: ${RETENTION_DAYS} dni)."
echo "=============================================================================="
