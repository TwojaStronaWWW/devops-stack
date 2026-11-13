#!/usr/bin/env bash
# ==============================================================================
# setup-freescout-mailboxes.sh
# Bezpieczny wrapper uruchamiający konfigurację skrzynek i OPSEC Lockdown
# wewnątrz kontenera FreeScout bez ujawniania haseł w argumentach procesów.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHP_SCRIPT="${SCRIPT_DIR}/setup-freescout-mailboxes.php"
SOCIAL_INSTALLER="${SCRIPT_DIR}/install-freescout-social-modules.sh"

SKIP_SOCIAL="0"
if [[ "${1:-}" == "--skip-social" ]]; then
    SKIP_SOCIAL="1"
fi

if [[ ! -f "${PHP_SCRIPT}" ]]; then
    echo "[BŁĄD] Brak pliku ${PHP_SCRIPT}!" >&2
    exit 1
fi

if ! docker inspect -f '{{.State.Running}}' freescout 2>/dev/null | grep -qx "true"; then
    echo "[BŁĄD] Kontener 'freescout' nie jest uruchomiony!" >&2
    exit 1
fi

if [[ "${SKIP_SOCIAL}" != "1" && -f "${SOCIAL_INSTALLER}" ]]; then
    bash "${SOCIAL_INSTALLER}"
fi

# Przekazanie wyłącznie nazw zmiennych (-e NAZWA bez =wartość) chroni przed wyciekiem do ps aux
docker exec -i -u nginx \
    -e FS_MB_KATOSALSA_PASS \
    -e FS_MB_KATOSALSA_PASS_B64 \
    -e FS_MB_TSW_PASS \
    -e FS_MB_TSW_PASS_B64 \
    -e FS_MB_WK_PASS \
    -e FS_MB_WK_PASS_B64 \
    -e FS_MB_IK_EMAIL \
    -e FS_MB_IK_PASS \
    -e FS_MB_IK_PASS_B64 \
    -e FS_MB_MAXBIT_EMAIL \
    -e FS_MB_MAXBIT_PASS \
    -e FS_MB_MAXBIT_PASS_B64 \
    freescout php < "${PHP_SCRIPT}"
