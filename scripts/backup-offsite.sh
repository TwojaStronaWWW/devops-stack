#!/usr/bin/env bash
# ==============================================================================
# backup-offsite.sh
# Automatyczny backup wolumenów i wysyłka offsite do chmury (ISO 27001 / Zero-Trust)
# Obsługuje: Oracle Cloud Object Storage / Cloudflare R2 / AWS S3
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

BACKUP_DIR="${BACKUP_DIR:-/opt/devops-stack/backups}"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
NTFY_TOPIC="${NTFY_TOPIC:-kpoczatek-vps-alerty}"
NTFY_URL="${NTFY_URL:-https://ntfy.sh/${NTFY_TOPIC}}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

# S3 / Object Storage Configuration (zmienne z .env)
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_BUCKET="${S3_BUCKET:-twojastronawww-backups}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${S3_SECRET_KEY:-}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"

VOLUMES_TO_BACKUP=(
    "uptime_kuma_data"
    "grafana_data"
    "prometheus_data"
    "ai_router_storage"
    "runner_zeslownikiem_data"
    "runner_twojastronawww_data"
    "runner_gal_anonim_web_data"
)

mkdir -p "${BACKUP_DIR}"

send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    local tags="${4:-package}"

    curl -s \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -H "Tags: ${tags}" \
        -d "${message}" \
        "${NTFY_URL}" >/dev/null 2>&1 || true
}

START_TIME="$(date +%s)"
OFFSITE_STATUS=0
BACKUP_STATUS=0
BACKUP_VERIFIED=0
SQLITE_VERIFIED=1

# Konfiguracja eksportu metryk dla Prometheusa / Grafany
METRICS_DIR="${PROMETHEUS_METRICS_DIR:-${STACK_ROOT}/config/node-exporter}"

write_prometheus_metrics() {
    local status="$1"
    local offsite_status="$2"
    local size_bytes="$3"
    local end_time
    end_time="$(date +%s)"
    local duration=$(( end_time - START_TIME ))

    if [[ -d "${METRICS_DIR}" ]]; then
        local metrics_file="${METRICS_DIR}/backup.prom"
        cat <<EOF > "${metrics_file}.tmp"
# HELP devops_backup_last_timestamp_seconds Czas uniksowy zakonczenia ostatniego backupu
# TYPE devops_backup_last_timestamp_seconds gauge
devops_backup_last_timestamp_seconds ${end_time}

# HELP devops_backup_status Status wykonania lokalnego backupu (1 = sukces, 0 = blad)
# TYPE devops_backup_status gauge
devops_backup_status ${status}

# HELP devops_backup_verified Status weryfikacji integralnosci archiwum tar -tzf (1 = poprawne, 0 = blad)
# TYPE devops_backup_verified gauge
devops_backup_verified ${BACKUP_VERIFIED}

# HELP devops_backup_sqlite_verified Status weryfikacji spojnosci baz SQLite PRAGMA quick_check (1 = poprawne, 0 = blad)
# TYPE devops_backup_sqlite_verified gauge
devops_backup_sqlite_verified ${SQLITE_VERIFIED}

# HELP devops_backup_size_bytes Rozmiar archiwum zbiorczego kopii zapasowej w bajtach
# TYPE devops_backup_size_bytes gauge
devops_backup_size_bytes ${size_bytes}

# HELP devops_backup_offsite_status Status wysylki offsite do chmury (1 = wyslano, 0 = brak lub blad)
# TYPE devops_backup_offsite_status gauge
devops_backup_offsite_status ${offsite_status}

# HELP devops_backup_duration_seconds Czas trwania procedury backupu w sekundach
# TYPE devops_backup_duration_seconds gauge
devops_backup_duration_seconds ${duration}
EOF
        mv "${metrics_file}.tmp" "${metrics_file}"
        chmod 644 "${metrics_file}" 2>/dev/null || true
        echo "--> [METRYKI] Zaktualizowano metryki Prometheusa: ${metrics_file}"
    fi
}

on_error() {
    local exit_code=$?
    local line_no="${1:-unknown}"
    echo "==> [BŁĄD KRYTYCZNY] Procedura backupu wolumenów VPS przerwana na linii ${line_no} (kod: ${exit_code})!"
    write_prometheus_metrics 0 0 0
    send_notification \
        "🚨 Błąd: Backup Wolumenów VPS Przerwany!" \
        "Nocny backup wolumenów VPS zakończył się błędem na linii ${line_no} (kod wyjścia: ${exit_code}). Sprawdź logi: journalctl -u devops-backup.service" \
        "high" \
        "rotating_light,warning"
    exit "${exit_code}"
}
trap 'on_error $LINENO' ERR

echo "=============================================================================="
echo "==> Rozpoczynanie procedury backupu offsite: ${TIMESTAMP}"
echo "=============================================================================="

ARCHIVES_CREATED=()
TOTAL_SIZE=0

for VOLUME in "${VOLUMES_TO_BACKUP[@]}"; do
    if docker volume inspect "${VOLUME}" >/dev/null 2>&1; then
        ARCHIVE_NAME="${VOLUME}_${TIMESTAMP}.tar.gz"
        ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"
        
        echo "--> [1/3] Archiwizacja wolumenu: ${VOLUME}..."
        
        docker run --rm \
            -v "${VOLUME}:/source:ro" \
            -v "${BACKUP_DIR}:/target" \
            alpine:latest \
            sh -c "tar -czf '/target/${ARCHIVE_NAME}' -C /source . && chown ${HOST_UID}:${HOST_GID} '/target/${ARCHIVE_NAME}'"

        # Weryfikacja spójności transakcyjnej baz SQLite (kuma.db / grafana.db) wewnątrz utworzonego archiwum
        if command -v sqlite3 >/dev/null 2>&1 && [[ "${VOLUME}" == "uptime_kuma_data" || "${VOLUME}" == "grafana_data" ]]; then
            DB_FILENAME="kuma.db"
            [[ "${VOLUME}" == "grafana_data" ]] && DB_FILENAME="grafana.db"
            TMP_SQLITE_DIR="$(mktemp -d)"
            if tar -xzf "${ARCHIVE_PATH}" -C "${TMP_SQLITE_DIR}" "./${DB_FILENAME}" 2>/dev/null; then
                tar -xzf "${ARCHIVE_PATH}" -C "${TMP_SQLITE_DIR}" "./${DB_FILENAME}-wal" "./${DB_FILENAME}-shm" 2>/dev/null || true
                if sqlite3 "${TMP_SQLITE_DIR}/${DB_FILENAME}" "PRAGMA quick_check;" 2>/dev/null | grep -qx "ok"; then
                    echo "--> [OK SQLite] Baza ${DB_FILENAME} (${VOLUME}) przeszła pomyślnie test PRAGMA quick_check."
                else
                    SQLITE_VERIFIED=0
                    echo "--> [OSTRZEŻENIE SQLite] Baza ${DB_FILENAME} (${VOLUME}) zgłosiła niespójność podczas PRAGMA quick_check!"
                fi
            fi
            rm -rf "${TMP_SQLITE_DIR}"
        fi
            
        ARCHIVES_CREATED+=("${ARCHIVE_PATH}")
        FILE_SIZE="$(du -h "${ARCHIVE_PATH}" | awk '{print $1}')"
        echo "--> [OK] Utworzono: ${ARCHIVE_NAME} (${FILE_SIZE})"
    else
        echo "--> [POMINIĘTO] Wolumen ${VOLUME} nie istnieje w systemie."
    fi
done

# Tworzenie pojedynczego archiwum zbiorczego (bundle)
BUNDLE_NAME="vps_full_backup_${TIMESTAMP}.tar.gz"
BUNDLE_PATH="${BACKUP_DIR}/${BUNDLE_NAME}"

echo "--> [2/3] Pakowanie archiwum zbiorczego: ${BUNDLE_NAME}..."
tar -czf "${BUNDLE_PATH}" -C "${BACKUP_DIR}" $(for a in "${ARCHIVES_CREATED[@]}"; do basename "$a"; done)

echo "--> [2a/3] Weryfikacja integralności archiwum (tar -tzf)..."
if tar -tzf "${BUNDLE_PATH}" >/dev/null 2>&1; then
    BACKUP_VERIFIED=1
    echo "--> [OK] Integralność archiwum zweryfikowana pomyślnie."
else
    BACKUP_VERIFIED=0
    echo "--> [BŁĄD] Archiwum ${BUNDLE_NAME} jest uszkodzone!"
    write_prometheus_metrics 0 0 0
    exit 1
fi

if [[ -n "${BACKUP_ENCRYPTION_KEY}" ]] && command -v openssl >/dev/null 2>&1; then
    echo "--> [2b/3] Szyfrowanie spoczynkowe archiwum zbiorczego (AES-256-CBC PBKDF2)..."
    BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY}" openssl enc -aes-256-cbc -pbkdf2 -salt \
        -in "${BUNDLE_PATH}" \
        -out "${BUNDLE_PATH}.enc" \
        -pass env:BACKUP_ENCRYPTION_KEY
    rm -f "${BUNDLE_PATH}"
    BUNDLE_NAME="${BUNDLE_NAME}.enc"
    BUNDLE_PATH="${BUNDLE_PATH}.enc"
fi

BUNDLE_SIZE="$(du -h "${BUNDLE_PATH}" | awk '{print $1}')"
BUNDLE_SIZE_BYTES="$(wc -c < "${BUNDLE_PATH}" | tr -d ' ')"
BACKUP_STATUS=1

# Wysyłka offsite do chmury + rotacja chmurowa (RETENTION_DAYS), jeśli skonfigurowano klucze S3 / R2 / Oracle
if [[ -n "${S3_ACCESS_KEY}" && -n "${S3_SECRET_KEY}" && -n "${S3_ENDPOINT}" ]]; then
    echo "--> [3/3] Wysyłka archiwum offsite do chmury: ${S3_BUCKET} (${S3_ENDPOINT})..."

    # Użycie izolowanego kontenera rclone z oficjalną konfiguracją Cloudflare R2
    if docker run --rm \
        -v "${BACKUP_DIR}:/data:ro" \
        -e RCLONE_CONFIG_R2_TYPE=s3 \
        -e RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
        -e RCLONE_CONFIG_R2_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
        -e RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
        -e RCLONE_CONFIG_R2_ENDPOINT="${S3_ENDPOINT}" \
        -e RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
        rclone/rclone:latest \
        copy "/data/${BUNDLE_NAME}" "r2:${S3_BUCKET}/backups/"; then
        
        OFFSITE_STATUS=1
        echo "==> [SUKCES CHMURY] Backup ${BUNDLE_NAME} wysłany do ${S3_BUCKET}."

        echo "--> [3a/3] Rotacja chmurowa R2: usuwanie kopii VPS starszych niż ${RETENTION_DAYS} dni..."
        docker run --rm \
            -e RCLONE_CONFIG_R2_TYPE=s3 \
            -e RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
            -e RCLONE_CONFIG_R2_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
            -e RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
            -e RCLONE_CONFIG_R2_ENDPOINT="${S3_ENDPOINT}" \
            -e RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
            rclone/rclone:latest \
            delete --min-age "${RETENTION_DAYS}d" "r2:${S3_BUCKET}/backups/" >/dev/null 2>&1 || true
        
        send_notification \
            "✅ Sukces: Backup VPS w Chmurze" \
            "Kopia ${BUNDLE_NAME} (${BUNDLE_SIZE}) została utworzona i przesłana offsite do chmury (retencja: ${RETENTION_DAYS} dni)." \
            "low" \
            "white_check_mark,cloud"
    else
        OFFSITE_STATUS=0
        echo "==> [BŁĄD CHMURY] Nie udało się przesłać backupu offsite."
        send_notification \
            "⚠️ Ostrzeżenie: Błąd wysyłki backupu do chmury" \
            "Lokalna kopia ${BUNDLE_NAME} została utworzona, lecz wysyłka offsite zakończyła się błędem." \
            "high" \
            "warning"
    fi
else
    echo "--> [INFO] Klucze chmury (S3_ENDPOINT / S3_ACCESS_KEY) nie są zdefiniowane w .env."
    echo "--> Kopia została bezpiecznie zapisana lokalnie: ${BUNDLE_PATH} (${BUNDLE_SIZE})"
    OFFSITE_STATUS=0

    send_notification \
        "💾 Backup VPS Zakończony (Lokalnie)" \
        "Kopia ${BUNDLE_NAME} (${BUNDLE_SIZE}) utworzona pomyślnie. Skonfiguruj S3 w .env dla wysyłki offsite." \
        "low" \
        "floppy_disk"
fi

# Zapisanie metryk dla Prometheusa / Grafany
write_prometheus_metrics "${BACKUP_STATUS}" "${OFFSITE_STATUS}" "${BUNDLE_SIZE_BYTES}"

# Rotacja lokalna:
# 1. Archiwa zbiorcze vps_full_backup_* trzymane przez pełne RETENTION_DAYS (30 dni)
# 2. Pojedyncze archiwa cząstkowe wolumenów (zawarte już wewnątrz vps_full_backup_*) starsze niż 1 dzień są czyszczone, aby nie duplikować miejsca
echo "==> Rotacja lokalna: usuwanie kopii zbiorczych starszych niż ${RETENTION_DAYS} dni..."
find "${BACKUP_DIR}" -maxdepth 1 -type f \( -name "vps_full_backup_*.tar.gz" -o -name "vps_full_backup_*.tar.gz.enc" \) -mtime +"${RETENTION_DAYS}" -exec rm -f {} +
find "${BACKUP_DIR}" -maxdepth 1 -type f ! -name "vps_full_backup_*" \( -name "*.tar.gz" -o -name "*.tar.gz.enc" \) -mtime +1 -exec rm -f {} +

echo "=============================================================================="
echo "==> [ZAKOŃCZONO] Procedura backupu zakończona pomyślnie (retencja: ${RETENTION_DAYS} dni)."
echo "=============================================================================="
