#!/usr/bin/env bash
# ==============================================================================
# sync-p1-status.sh
# Radar Systemów Centralnych e-Zdrowia (Część Biała HIS & Część Szara ERP/Apteka)
# + Zwiadowca Zmian Prawnych i Technicznych (9 publicznych źródeł .gov.pl)
# ==============================================================================
# Architektura: Zero-Bloat, 100% Public OSINT/BIP, Zero-PII, Prometheus + JSON.
# Logika zwiadu i sondowania w: scripts/p1-status-engine.py
# Zapisuje metryki do:
#   1. /opt/devops-stack/config/node-exporter/p1_status.prom (Prometheus / Grafana)
#   2. /var/lib/docker/volumes/ai_router_storage/_data/p1_radar.json (Dashboard /radar)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${STACK_ROOT}/.env"
PROM_DIR="${STACK_ROOT}/config/node-exporter"
PROM_FILE="${PROM_DIR}/p1_status.prom"

STORAGE_DIR="${STACK_ROOT}/services/ai-router/storage"
mkdir -p "${STORAGE_DIR}" "${PROM_DIR}" 2>/dev/null || true

RADAR_JSON="${STORAGE_DIR}/p1_radar.json"
HISTORY_ARCHIVE="${STORAGE_DIR}/p1_history_archive.json"
WATCHER_CACHE="${STORAGE_DIR}/p1_watcher_cache.json"
ALERT_STATE="${STORAGE_DIR}/p1_alert_state.json"
AI_KB_FILE="${STORAGE_DIR}/p1_live_feed.txt"

FORCE_WATCHER="false"
if [[ "${1:-}" == "--force-watcher" ]]; then
    FORCE_WATCHER="true"
fi

ENV_FILE="${ENV_FILE}" \
PROM_FILE="${PROM_FILE}" \
RADAR_JSON="${RADAR_JSON}" \
HISTORY_ARCHIVE="${HISTORY_ARCHIVE}" \
WATCHER_CACHE="${WATCHER_CACHE}" \
ALERT_STATE="${ALERT_STATE}" \
AI_KB_FILE="${AI_KB_FILE}" \
FORCE_WATCHER="${FORCE_WATCHER}" \
python3 "${SCRIPT_DIR}/p1-status-engine.py"

# Synchronizacja pliku JSON bezpośrednio do wolumenu kontenera ai-router (ai_router_storage -> /app/storage/p1_radar.json)
if sudo -n test -d /var/lib/docker/volumes/ai_router_storage/_data 2>/dev/null; then
    sudo -n install -m 644 "${RADAR_JSON}" /var/lib/docker/volumes/ai_router_storage/_data/p1_radar.json 2>/dev/null || true
    if [[ -f "${HISTORY_ARCHIVE}" ]]; then
        sudo -n install -m 644 "${HISTORY_ARCHIVE}" /var/lib/docker/volumes/ai_router_storage/_data/p1_history_archive.json 2>/dev/null || true
    fi
    if [[ -f "${AI_KB_FILE}" ]]; then
        sudo -n install -m 644 "${AI_KB_FILE}" /var/lib/docker/volumes/ai_router_storage/_data/p1_live_feed.txt 2>/dev/null || true
    fi
fi
