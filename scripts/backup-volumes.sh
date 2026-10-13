#!/usr/bin/env bash
# ==============================================================================
# backup-volumes.sh
# Automatyczny backup wolumenów Dockera w trybie tylko do odczytu (:ro)
# ==============================================================================
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/devops-stack/backups}"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
RETENTION_DAYS=7

VOLUMES_TO_BACKUP=(
    "uptime_kuma_data"
    "grafana_data"
    "prometheus_data"
)

mkdir -p "${BACKUP_DIR}"

echo "==> Rozpoczynanie procedury backupu wolumenów: ${TIMESTAMP}"

for VOLUME in "${VOLUMES_TO_BACKUP[@]}"; do
    if docker volume inspect "${VOLUME}" >/dev/null 2>&1; then
        ARCHIVE_FILE="${BACKUP_DIR}/${VOLUME}_${TIMESTAMP}.tar.gz"
        echo "--> Archiwizacja wolumenu: ${VOLUME} -> ${ARCHIVE_FILE}"
        
        # Wykorzystanie tymczasowego kontenera alpine montującego wolumen w trybie :ro
        docker run --rm \
            -v "${VOLUME}:/source:ro" \
            -v "${BACKUP_DIR}:/target" \
            alpine:latest \
            tar -czf "/target/${VOLUME}_${TIMESTAMP}.tar.gz" -C /source .
            
        echo "--> Zakończono: ${ARCHIVE_FILE} ($(du -h "${ARCHIVE_FILE}" | awk '{print $1}'))"
    else
        echo "--> [POMINIĘTO] Wolumen ${VOLUME} nie istnieje w silniku Dockera."
    fi
done

echo "==> Usuwanie kopii starszych niż ${RETENTION_DAYS} dni z ${BACKUP_DIR}..."
find "${BACKUP_DIR}" -type f -name "*.tar.gz" -mtime +"${RETENTION_DAYS}" -exec rm -f {} +

echo "==> [SUKCES] Procedura backupu zakończona pomyślnie."
