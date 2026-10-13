#!/usr/bin/env bash
# ==============================================================================
# backup-offsite.sh
# Automatyczny backup wolumenów i wysyłka offsite do chmury (ISO 27001 / Zero-Trust)
# Obsługuje: Oracle Cloud Object Storage / Cloudflare R2 / AWS S3
# ==============================================================================
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/devops-stack/backups}"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
NTFY_TOPIC="${NTFY_TOPIC:-kpoczatek-vps-alerty}"
NTFY_URL="${NTFY_URL:-https://ntfy.sh/${NTFY_TOPIC}}"

# S3 / Object Storage Configuration (zmienne z .env)
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_BUCKET="${S3_BUCKET:-devops-vps-backups}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${S3_SECRET_KEY:-}"

VOLUMES_TO_BACKUP=(
    "uptime_kuma_data"
    "grafana_data"
    "prometheus_data"
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
            tar -czf "/target/${ARCHIVE_NAME}" -C /source .
            
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
BUNDLE_SIZE="$(du -h "${BUNDLE_PATH}" | awk '{print $1}')"

# Wysyłka offsite do chmury, jeśli skonfigurowano klucze S3 / R2 / Oracle
if [[ -n "${S3_ACCESS_KEY}" && -n "${S3_SECRET_KEY}" && -n "${S3_ENDPOINT}" ]]; then
    echo "--> [3/3] Wysyłka archiwum offsite do chmury: ${S3_BUCKET} (${S3_ENDPOINT})..."

    # Użycie izolowanego kontenera rclone bez zaśmiecania systemu
    docker run --rm \
        -v "${BACKUP_DIR}:/data:ro" \
        -e AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
        -e AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
        rclone/rclone:latest \
        copy "/data/${BUNDLE_NAME}" ":s3,endpoint=${S3_ENDPOINT},provider=Other:${S3_BUCKET}/backups/" \
        --s3-no-check-bucket

    echo "==> [SUKCES CHMURY] Backup ${BUNDLE_NAME} wysłany do ${S3_BUCKET}."
    
    send_notification \
        "✅ Sukces: Backup VPS w Chmurze" \
        "Kopia ${BUNDLE_NAME} (${BUNDLE_SIZE}) została utworzona i przesłana offsite do chmury." \
        "low" \
        "white_check_mark,cloud"
else
    echo "--> [INFO] Klucze chmury (S3_ENDPOINT / S3_ACCESS_KEY) nie są zdefiniowane w .env."
    echo "--> Kopia została bezpiecznie zapisana lokalnie: ${BUNDLE_PATH} (${BUNDLE_SIZE})"

    send_notification \
        "💾 Backup VPS Zakończony (Lokalnie)" \
        "Kopia ${BUNDLE_NAME} (${BUNDLE_SIZE}) utworzona pomyślnie. Skonfiguruj S3 w .env dla wysyłki offsite." \
        "low" \
        "floppy_disk"
fi

# Rotacja lokalna (usuwanie plików starszych niż RETENTION_DAYS)
echo "==> Rotacja: usuwanie kopii starszych niż ${RETENTION_DAYS} dni..."
find "${BACKUP_DIR}" -type f -name "*.tar.gz" -mtime +"${RETENTION_DAYS}" -exec rm -f {} +

echo "=============================================================================="
echo "==> [ZAKOŃCZONO] Procedura backupu zakończona pomyślnie."
echo "=============================================================================="
