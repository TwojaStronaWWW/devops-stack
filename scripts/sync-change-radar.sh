#!/usr/bin/env bash
# ==============================================================================
# sync-change-radar.sh
# Orkiestrator Radaru Zmian na Stronach Zewnętrznych (Lightweight Change Radar):
# - CeZ P1 / e-Zdrowie / Śląski OW NFZ / MF KSeF (his_med)
# - Cenniki domen i hostingu LH.pl (hosting_domains)
# - Dotacje i konkursy NGO Katowice — Fundacja Kato Salsa Hub (ngo_katowice)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${STACK_ROOT}/.env}"
PROM_DIR="${STACK_ROOT}/config/node-exporter"
PROM_FILE="${PROM_FILE:-${PROM_DIR}/change_radar.prom}"
TARGETS_FILE="${TARGETS_FILE:-${STACK_ROOT}/config/change-radar/targets.json}"
STATE_FILE="${STATE_FILE:-/var/tmp/devops-change-radar-state.json}"
REPORT_FILE="${REPORT_FILE:-/var/tmp/devops-change-radar-report.json}"

mkdir -p "${PROM_DIR}" 2>/dev/null || true

if [[ "${1:-}" == "--self-test" ]]; then
    python3 "${STACK_ROOT}/scripts/watch-external-changes.py" --self-test
    exit 0
fi

# Wczytanie konfiguracji Ntfy.sh z pliku .env (jeśli istnieje)
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

RADAR_OUTPUT="$(
    STACK_ROOT="${STACK_ROOT}" \
    TARGETS_FILE="${TARGETS_FILE}" \
    PROM_FILE="${PROM_FILE}" \
    STATE_FILE="${STATE_FILE}" \
    REPORT_FILE="${REPORT_FILE}" \
    python3 "${STACK_ROOT}/scripts/watch-external-changes.py"
)"

CHANGES_COUNT="$(
    echo "${RADAR_OUTPUT}" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read() or "{}")
    print(int(data.get("changes_detected_total") or 0))
except Exception:
    print(0)
' 2>/dev/null || echo "0"
)"

if [[ "${CHANGES_COUNT}" -gt 0 ]] && [[ -n "${NTFY_TOPIC:-}" ]] && [[ "${NTFY_TOPIC}" != "twojastronawww-alerty-prod" ]]; then
    NOTIFICATION_BODY="$(
        echo "${RADAR_OUTPUT}" | python3 -c '
import json, sys
data = json.loads(sys.stdin.read() or "{}")
changes = data.get("changes") or []
lines = []
for idx, chg in enumerate(changes, 1):
    name = chg.get("name") or chg.get("id")
    cat = chg.get("category") or "general"
    url = chg.get("url") or ""
    lines.append(f"{idx}. [{cat}] {name}")
    if url:
        lines.append(f"   URL: {url}")
    for dline in (chg.get("diff") or [])[:15]:
        lines.append(f"   {dline}")
    lines.append("")
print("\n".join(lines).strip())
' 2>/dev/null || echo "Wykryto zmiany na monitorowanych stronach zewnętrznych (${CHANGES_COUNT})."
    )"

    CURL_ARGS=(
        -sS
        --max-time 8
        -H "Title: Radar Zmian: Wykryto aktualizacje (${CHANGES_COUNT})"
        -H "Priority: default"
        -H "Tags: satellite,mag,page_facing_up"
    )
    if [[ -n "${NTFY_TOKEN:-}" ]]; then
        CURL_ARGS+=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    fi

    curl "${CURL_ARGS[@]}" \
        -d "${NOTIFICATION_BODY}" \
        "${NTFY_BASE_URL}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
fi

exit 0
