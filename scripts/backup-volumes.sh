#!/usr/bin/env bash
# ==============================================================================
# backup-volumes.sh
# Automatyczny backup wolumenów Dockera w trybie tylko do odczytu (:ro)
# ==============================================================================
set -euo pipefail

umask 077
BACKUP_DIR="${BACKUP_DIR:-/opt/devops-stack/backups}"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

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
chmod 700 "${BACKUP_DIR}" 2>/dev/null || true

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
            sh -c "tar -czf '/target/${VOLUME}_${TIMESTAMP}.tar.gz' -C /source . && chown ${HOST_UID}:${HOST_GID} '/target/${VOLUME}_${TIMESTAMP}.tar.gz' && chmod 600 '/target/${VOLUME}_${TIMESTAMP}.tar.gz'"
            
        echo "--> Zakończono: ${ARCHIVE_FILE} ($(du -h "${ARCHIVE_FILE}" | awk '{print $1}'))"
    else
        echo "--> [POMINIĘTO] Wolumen ${VOLUME} nie istnieje w silniku Dockera."
    fi
done

echo "==> Usuwanie kopii starszych niż ${RETENTION_DAYS} dni z ${BACKUP_DIR}..."
find "${BACKUP_DIR}" -type f -name "*.tar.gz" -mtime +"${RETENTION_DAYS}" -exec rm -f {} +

echo "==> [SUKCES] Procedura backupu zakończona pomyślnie."
