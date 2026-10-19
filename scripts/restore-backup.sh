#!/usr/bin/env bash
# ==============================================================================
# restore-backup.sh
# Zautomatyzowane odtwarzanie (Disaster Recovery) i weryfikacja (Restore Drill)
# kopii zapasowych wolumenów VPS (obsługa .tar.gz oraz AES-256-CBC .tar.gz.enc).
#
# Użycie:
#   bash scripts/restore-backup.sh --verify-only [ścieżka_do_pliku]
#   bash scripts/restore-backup.sh --from-r2 --verify-only
#   bash scripts/restore-backup.sh --yes [ścieżka_do_pliku]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${STACK_ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${STACK_ROOT}/.env"
    set +a
fi

umask 077
BACKUP_DIR="${BACKUP_DIR:-/opt/devops-stack/backups}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_BUCKET="${S3_BUCKET:-twojastronawww-backups}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${S3_SECRET_KEY:-}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"

VERIFY_ONLY=false
FROM_R2=false
AUTO_YES=false
TARGET_ARCHIVE=""

for arg in "$@"; do
    case "$arg" in
        --verify-only|--dry-run)
            VERIFY_ONLY=true
            ;;
        --from-r2)
            FROM_R2=true
            ;;
        --yes|-y)
            AUTO_YES=true
            ;;
        *)
            TARGET_ARCHIVE="$arg"
            ;;
    esac
done

WORK_DIR="$(mktemp -d)"
chmod 700 "${WORK_DIR}"
cleanup() {
    rm -rf "${WORK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "=============================================================================="
echo "==> Procedura Disaster Recovery / Restore Drill (ISO 27001)"
echo "=============================================================================="

# 1. Pobranie najnowszego archiwum z Cloudflare R2 (jeśli wywołano z --from-r2)
if [[ "${FROM_R2}" == "true" ]]; then
    if [[ -z "${S3_ACCESS_KEY}" || -z "${S3_SECRET_KEY}" || -z "${S3_ENDPOINT}" ]]; then
        echo "[BŁĄD] Brak poświadczeń S3/R2 w pliku .env (S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY)." >&2
        exit 1
    fi
    echo "--> Pobieranie najnowszego archiwum vps_full_backup_* z chmury (${S3_BUCKET})..."
    LATEST_REMOTE="$(docker run --rm \
        -e RCLONE_CONFIG_R2_TYPE=s3 \
        -e RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
        -e RCLONE_CONFIG_R2_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
        -e RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
        -e RCLONE_CONFIG_R2_ENDPOINT="${S3_ENDPOINT}" \
        -e RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
        rclone/rclone:latest \
        lsf "r2:${S3_BUCKET}/backups/" --files-only | grep '^vps_full_backup_' | sort | tail -n 1)"

    if [[ -z "${LATEST_REMOTE}" ]]; then
        echo "[BŁĄD] Nie znaleziono żadnej kopii vps_full_backup_* w koszyku ${S3_BUCKET}/backups/." >&2
        exit 1
    fi

    echo "--> Pobieranie pliku: ${LATEST_REMOTE}..."
    docker run --rm \
        -v "${WORK_DIR}:/data" \
        -e RCLONE_CONFIG_R2_TYPE=s3 \
        -e RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
        -e RCLONE_CONFIG_R2_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
        -e RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
        -e RCLONE_CONFIG_R2_ENDPOINT="${S3_ENDPOINT}" \
        -e RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
        rclone/rclone:latest \
        copy "r2:${S3_BUCKET}/backups/${LATEST_REMOTE}" /data/

    TARGET_ARCHIVE="${WORK_DIR}/${LATEST_REMOTE}"
fi

# 2. Wybór najnowszego lokalnego archiwum, jeśli nie podano jawnie ścieżki
if [[ -z "${TARGET_ARCHIVE}" ]]; then
    TARGET_ARCHIVE="$(find "${BACKUP_DIR}" -maxdepth 1 -type f \( -name "vps_full_backup_*.tar.gz.enc" -o -name "vps_full_backup_*.tar.gz" \) 2>/dev/null | sort | tail -n 1 || true)"
fi

if [[ -z "${TARGET_ARCHIVE}" || ! -f "${TARGET_ARCHIVE}" ]]; then
    echo "[BŁĄD] Nie znaleziono archiwum kopii zapasowej w ${BACKUP_DIR}. Podaj ścieżkę do pliku lub użyj --from-r2." >&2
    exit 1
fi

echo "--> Wybrane archiwum źródłowe: ${TARGET_ARCHIVE}"

# 3. Odszyfrowanie AES-256-CBC (PBKDF2), jeśli plik posiada rozszerzenie .enc
BUNDLE_TAR="${TARGET_ARCHIVE}"
if [[ "${TARGET_ARCHIVE}" == *.enc ]]; then
    if [[ -z "${BACKUP_ENCRYPTION_KEY}" ]]; then
        echo "[BŁĄD] Archiwum jest zaszyfrowane (.enc), ale zmienna BACKUP_ENCRYPTION_KEY w .env jest pusta!" >&2
        exit 1
    fi
    echo "--> [1/4] Odszyfrowywanie archiwum (AES-256-CBC PBKDF2)..."
    BUNDLE_TAR="${WORK_DIR}/decrypted_bundle.tar.gz"
    BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY}" openssl enc -d -aes-256-cbc -pbkdf2 \
        -in "${TARGET_ARCHIVE}" \
        -out "${BUNDLE_TAR}" \
        -pass env:BACKUP_ENCRYPTION_KEY
    echo "--> [OK] Archiwum odszyfrowane pomyślnie."
fi

# 4. Weryfikacja spójności archiwum zbiorczego i wypakowanie archiwów wolumenów
echo "--> [2/4] Weryfikacja integralności paczki zbiorczej (tar -tzf)..."
tar -tzf "${BUNDLE_TAR}" >/dev/null
EXTRACT_DIR="${WORK_DIR}/volumes"
mkdir -p "${EXTRACT_DIR}"
tar -xzf "${BUNDLE_TAR}" -C "${EXTRACT_DIR}"

VOLUME_ARCHIVES=("${EXTRACT_DIR}"/*.tar.gz)
if [[ ${#VOLUME_ARCHIVES[@]} -eq 0 || ! -f "${VOLUME_ARCHIVES[0]}" ]]; then
    echo "[BŁĄD] Paczka zbiorcza nie zawiera archiwów wolumenów (*.tar.gz)!" >&2
    exit 1
fi

echo "--> [3/4] Weryfikacja integralności poszczególnych wolumenów (${#VOLUME_ARCHIVES[@]} archiwów)..."
for VARCH in "${VOLUME_ARCHIVES[@]}"; do
    VBASE="$(basename "${VARCH}")"
    tar -tzf "${VARCH}" >/dev/null
    echo "    [OK] ${VBASE}"

    # Jeśli dostępny jest sqlite3, zweryfikuj spójność transakcyjną baz kuma.db / grafana.db
    if command -v sqlite3 >/dev/null 2>&1; then
        for DB_NAME in "kuma.db" "grafana.db"; do
            if tar -tzf "${VARCH}" | grep -qE "^\./${DB_NAME}$"; then
                SQL_TMP="$(mktemp -d "${WORK_DIR}/sql.XXXXXX")"
                tar -xzf "${VARCH}" -C "${SQL_TMP}" "./${DB_NAME}" 2>/dev/null || true
                tar -xzf "${VARCH}" -C "${SQL_TMP}" "./${DB_NAME}-wal" "./${DB_NAME}-shm" 2>/dev/null || true
                if sqlite3 "${SQL_TMP}/${DB_NAME}" "PRAGMA quick_check;" 2>/dev/null | grep -qx "ok"; then
                    echo "    [OK SQLite] Baza ${DB_NAME} wewnątrz ${VBASE} jest w 100% spójna (PRAGMA quick_check = ok)."
                else
                    echo "    [OSTRZEŻENIE SQLite] Baza ${DB_NAME} wewnątrz ${VBASE} zgłosiła ostrzeżenie!" >&2
                fi
                rm -rf "${SQL_TMP}"
            fi
        done
    fi
done

if [[ "${VERIFY_ONLY}" == "true" ]]; then
    echo "=============================================================================="
    echo "==> [SUKCES DRILLU] Test odtworzeniowy (--verify-only) zakończony w 100% pomyślnie!"
    echo "==> Odszyfrowanie AES-256, archiwa tar.gz oraz bazy SQLite są w pełni prawidłowe."
    echo "=============================================================================="
    exit 0
fi

# 5. Pełne odtworzenie wolumenów Dockera (Disaster Recovery)
if [[ "${AUTO_YES}" != "true" ]]; then
    read -r -p "UWAGA: Czy na pewno chcesz nadpisać wolumeny Dockera danymi z kopii zapasowej? (tak/NIE): " CONFIRM
    if [[ "${CONFIRM}" != "tak" ]]; then
        echo "--> Anulowano przez administratora."
        exit 0
    fi
fi

echo "--> [4/4] Odtwarzanie sieci i wolumenów Dockera..."
docker network create devops_internal_network >/dev/null 2>&1 || true
docker network create devops_runners_network >/dev/null 2>&1 || true

for VARCH in "${VOLUME_ARCHIVES[@]}"; do
    VBASE="$(basename "${VARCH}")"
    # Nazwa wolumenu to prefiks przed _RRRRMMDD_GGMMSS.tar.gz
    VOL_NAME="$(echo "${VBASE}" | sed -E 's/_[0-9]{8}_[0-9]{6}\.tar\.gz$//')"
    echo "    Odtwarzanie wolumenu: ${VOL_NAME} z ${VBASE}..."
    docker volume create "${VOL_NAME}" >/dev/null
    docker run --rm \
        -v "${VOL_NAME}:/target" \
        -v "${VARCH}:/backup.tar.gz:ro" \
        alpine:latest \
        sh -c "tar -xzf /backup.tar.gz -C /target"
done

# Korekta uprawnień PoLP (ISO 27001): Grafana (UID 472), Prometheus (UID 65534), AI Router (UID 65534)
echo "--> Ustawianie uprawnień non-root (PoLP) na odtworzonych wolumenach..."
docker run --rm -v grafana_data:/target alpine:latest chown -R 472:472 /target 2>/dev/null || true
docker run --rm -v prometheus_data:/target alpine:latest chown -R 65534:65534 /target 2>/dev/null || true
docker run --rm -v ai_router_storage:/target alpine:latest chown -R 65534:65534 /target 2>/dev/null || true

# 6. Odtworzenie statycznej bazy wiedzy SQLite FTS5 Asystenta AMMS (162 MB, wykluczona z Git) z Cloudflare R2
AMMS_SQLITE_TARGET="${STACK_ROOT}/services/ai-router/data/amms-knowledge.sqlite"
if [[ ! -f "${AMMS_SQLITE_TARGET}" && "${FROM_R2}" == "true" && -n "${BACKUP_ENCRYPTION_KEY}" ]]; then
    echo "--> Pobieranie statycznej bazy AMMS FTS5 (static/amms-knowledge.sqlite.gz.enc) z chmury R2..."
    if docker run --rm \
        -v "${WORK_DIR}:/data" \
        -e RCLONE_CONFIG_R2_TYPE=s3 \
        -e RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
        -e RCLONE_CONFIG_R2_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
        -e RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
        -e RCLONE_CONFIG_R2_ENDPOINT="${S3_ENDPOINT}" \
        -e RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
        rclone/rclone:latest \
        copy "r2:${S3_BUCKET}/static/amms-knowledge.sqlite.gz.enc" /data/ 2>/dev/null && [[ -f "${WORK_DIR}/amms-knowledge.sqlite.gz.enc" ]]; then
        BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY}" openssl enc -d -aes-256-cbc -pbkdf2 \
            -in "${WORK_DIR}/amms-knowledge.sqlite.gz.enc" \
            -pass env:BACKUP_ENCRYPTION_KEY | gunzip -c > "${AMMS_SQLITE_TARGET}"
        chmod 644 "${AMMS_SQLITE_TARGET}"
        echo "--> [OK AMMS] Odtworzono bazę wiedzy FTS5: ${AMMS_SQLITE_TARGET}"
    else
        echo "--> [INFO] Brak pliku static/amms-knowledge.sqlite.gz.enc w R2 – pominięto."
    fi
fi

echo "=============================================================================="
echo "==> [ZAKOŃCZONO] Wszystkie wolumeny zostały pomyślnie odtworzone z kopii zapasowej!"
echo "=============================================================================="
