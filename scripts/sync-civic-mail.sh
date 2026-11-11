#!/usr/bin/env bash
# ==============================================================================
# sync-civic-mail.sh
# Orkiestrator nasłuchu 24/7 skrzynki obywatelskiej (wspolnekamienice.pl):
# - Odpytuje IMAP4_SSL na LH.pl co 5 minut (watch-civic-mail.py)
# - Wysyła natychmiastowy Push (Ntfy) po otrzymaniu odpowiedzi z urzędu / SM
# - Przypomina o upływie 14-dniowego terminu ustawowego UDIP (skarga do WSA)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${STACK_ROOT}/.env}"
PROM_DIR="${STACK_ROOT}/config/node-exporter"
PROM_FILE="${PROM_FILE:-${PROM_DIR}/civic_mail.prom}"
STATE_FILE="${STATE_FILE:-/var/tmp/devops-civic-mail-state.json}"
SLA_FILE="${SLA_FILE:-/var/tmp/devops-civic-cases-sla.json}"

mkdir -p "${PROM_DIR}" 2>/dev/null || true

if [[ "${1:-}" == "--self-test" ]]; then
    python3 "${STACK_ROOT}/scripts/watch-civic-mail.py" --self-test
    exit 0
fi

if [[ -f "${ENV_FILE}" ]]; then
    if [[ -z "${NTFY_TOPIC:-}" ]]; then
        NTFY_TOPIC="$(grep -E '^NTFY_TOPIC=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || echo '')"
    fi
    if [[ -z "${NTFY_BASE_URL:-}" ]]; then
        NTFY_BASE_URL="$(grep -E '^NTFY_BASE_URL=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || echo '')"
    fi
    if [[ -z "${NTFY_TOKEN:-}" ]]; then
        NTFY_TOKEN="$(grep -E '^NTFY_TOKEN=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || echo '')"
    fi
fi

NTFY_BASE_URL="${NTFY_BASE_URL:-https://ntfy.sh}"
NTFY_BASE_URL="${NTFY_BASE_URL%/}"

send_ntfy() {
    local title="$1"
    local priority="$2"
    local tags="$3"
    local body="$4"

    if [[ -z "${NTFY_TOPIC:-}" ]] || [[ "${NTFY_TOPIC}" == "twojastronawww-alerty-prod" ]]; then
        return 0
    fi

    local curl_args=(
        -sS
        --max-time 8
        -H "Title: ${title}"
        -H "Priority: ${priority}"
        -H "Tags: ${tags}"
    )
    if [[ -n "${NTFY_TOKEN:-}" ]]; then
        curl_args+=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    fi

    curl "${curl_args[@]}" -d "${body}" "${NTFY_BASE_URL}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
}

OUTPUT="$(
    STACK_ROOT="${STACK_ROOT}" \
    ENV_FILE="${ENV_FILE}" \
    PROM_FILE="${PROM_FILE}" \
    STATE_FILE="${STATE_FILE}" \
    SLA_FILE="${SLA_FILE}" \
    python3 "${STACK_ROOT}/scripts/watch-civic-mail.py"
)"

if [[ "${1:-}" == "--test-notify" ]]; then
    SUMMARY="$(echo "${OUTPUT}" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
print(f"Skrzynka {d.get(\"mailbox\", \"?\")} podpieta 24/7 na VPS! Wiadomosci w INBOX: {d.get(\"total_messages\", 0)} (nieprzeczytane: {d.get(\"unseen_messages\", 0)}).")
')"
    send_ntfy "Kancelaria Obywatelska: Nasluch 24/7 aktywny" "default" "white_check_mark,mailbox_with_mail" "${SUMMARY}"
    echo "${SUMMARY}"
    exit 0
fi

NEW_COUNT="$(echo "${OUTPUT}" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
print(len(d.get("new_messages") or []))
' 2>/dev/null || echo "0")"

if [[ "${NEW_COUNT}" -gt 0 ]]; then
    MAIL_BODY="$(echo "${OUTPUT}" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
lines = []
for m in d.get("new_messages") or []:
    sig = f" [{m[\"signature\"]}]" if m.get("signature") else ""
    atts = f"\nZalaczniki: {\", \".join(m[\"attachments\"])}" if m.get("attachments") else ""
    lines.append(f"Od: {m.get(\"from\", \"?\")}\nTemat: {m.get(\"subject\", \"?\")}{sig}{atts}\nPodglad: {m.get(\"snippet\", \"\")[:180]}")
print("\n---\n".join(lines))
')"
    send_ntfy "Nowe pismo w skrzynce wspolnekamienice (${NEW_COUNT})" "high" "incoming_envelope,classical_building" "${MAIL_BODY}"
fi

OVERDUE_COUNT="$(echo "${OUTPUT}" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
print(len(d.get("overdue_alerts") or []))
' 2>/dev/null || echo "0")"

if [[ "${OVERDUE_COUNT}" -gt 0 ]]; then
    SLA_BODY="$(echo "${OUTPUT}" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
lines = []
for a in d.get("overdue_alerts") or []:
    lines.append(f"• {a[\"case_code\"]} ({a[\"category\"]}) — termin minal {a[\"deadline_date\"]} ({a[\"days_overdue\"]} dni po terminie). Gotowe do ponaglenia / skargi WSA!")
print("\n".join(lines))
')"
    send_ntfy "UDIP 14 dni: Termin ustawowy minal (${OVERDUE_COUNT})" "high" "hourglass_flowing_sand,scales" "${SLA_BODY}"
fi

exit 0
