#!/usr/bin/env bash
# ==============================================================================
# setup-selfhosted-ntfy.sh
# Inicjalizacja konta administratora oraz tokenu Bearer dla prywatnego serwera
# powiadomień Push Ntfy Self-Hosted (Zero-Trust / RODO / ISO 27001).
# ==============================================================================
set -euo pipefail

CONTAINER_NAME="${NTFY_CONTAINER_NAME:-ntfy}"
ADMIN_USER="${NTFY_ADMIN_USER:-admin}"
TOKEN_LABEL="${NTFY_TOKEN_LABEL:-vps-devops-stack}"
STACK_ENV="${STACK_ENV:-/opt/devops-stack/.env}"

echo "=============================================================================="
echo " Inicjalizacja Ntfy Self-Hosted (Zero-Trust ACL: deny-all)"
echo "=============================================================================="

if ! command -v docker >/dev/null 2>&1; then
    echo "[BŁĄD] Polecenie 'docker' nie jest dostępne w systemie." >&2
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "[BŁĄD] Kontener '${CONTAINER_NAME}' nie jest uruchomiony." >&2
    echo "       Uruchom go najpierw poleceniem:" >&2
    echo "       docker compose -f /opt/devops-stack/compose/docker-compose.yml up -d ntfy" >&2
    exit 1
fi

echo "[1/3] Sprawdzanie / tworzenie konta administratora '${ADMIN_USER}'..."
if docker exec "${CONTAINER_NAME}" ntfy user list 2>&1 | grep -qE "user ${ADMIN_USER}\b"; then
    echo "[OK] Konto administratora '${ADMIN_USER}' już istnieje w bazie user.db."
else
    if [[ -n "${NTFY_ADMIN_PASSWORD:-}" ]]; then
        docker exec -e NTFY_PASSWORD="${NTFY_ADMIN_PASSWORD}" "${CONTAINER_NAME}" \
            ntfy user add --role=admin "${ADMIN_USER}"
        echo "[OK] Konto administratora '${ADMIN_USER}' zostało utworzone nieinteraktywnie."
    else
        echo "[INFO] Wprowadź nowe hasło administratora (min. 32 znaki, bez znaku $, z bazy KeePass):"
        docker exec -it "${CONTAINER_NAME}" ntfy user add --role=admin "${ADMIN_USER}"
        echo "[OK] Konto administratora '${ADMIN_USER}' zostało utworzone."
    fi
fi

echo ""
echo "[2/3] Generowanie tokenu dostępowego Bearer (etykieta: ${TOKEN_LABEL})..."
TOKEN_OUTPUT="$(docker exec "${CONTAINER_NAME}" ntfy token add --label="${TOKEN_LABEL}" "${ADMIN_USER}" 2>&1)"
echo "${TOKEN_OUTPUT}"

EXTRACTED_TOKEN="$(echo "${TOKEN_OUTPUT}" | grep -oE 'tk_[a-zA-Z0-9]+' | head -n1 || true)"

echo ""
echo "=============================================================================="
echo " [3/3] INSTRUKCJA KEEPASS-FIRST SECRET PROVISIONING (ISO 27001)"
echo "=============================================================================="
echo "1. Zapisz poniższe dane w bazie KeePass (Databasekpoczatek.kdbx -> VPS - TwojaStronaWWW):"
echo "   - Użytkownik Ntfy : ${ADMIN_USER} (rola: admin)"
echo "   - Token Ntfy      : ${EXTRACTED_TOKEN:-<skopiuj token tk_... z powyższego komunikatu>}"
echo "   - Publiczny URL   : https://push.twojastronawww.pl"
echo ""
echo "2. Dopisz lub zaktualizuj zmienne w pliku ${STACK_ENV} (chmod 600):"
echo "   NTFY_BASE_URL=http://ntfy:8080"
echo "   NTFY_TOKEN=${EXTRACTED_TOKEN:-tk_twoj_token}"
echo ""
echo "3. Skonfiguruj subskrypcję w aplikacji mobilnej Ntfy (Android / iOS):"
echo "   - Domyślny serwer : https://push.twojastronawww.pl"
echo "   - Logowanie       : Użyj konta '${ADMIN_USER}' lub wygenerowanego tokenu Bearer"
echo "=============================================================================="
