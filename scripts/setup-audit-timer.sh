#!/usr/bin/env bash
# ==============================================================================
# setup-audit-timer.sh
# Idempotentna instalacja harmonogramu systemd devops-audit.timer (co 15 minut)
# Uruchamia skrypt audit-server.sh w tle, odświeża metryki Prometheus (audit.prom)
# oraz wysyła natychmiastowy alert Push (Ntfy.sh) w przypadku awarii lub alarmu.
# ==============================================================================
set -euo pipefail

STACK_ROOT="${STACK_ROOT:-/opt/devops-stack}"
SERVICE_FILE="/etc/systemd/system/devops-audit.service"
TIMER_FILE="/etc/systemd/system/devops-audit.timer"

cat <<EOF | sudo tee "${SERVICE_FILE}" >/dev/null
[Unit]
Description=TwojaStronaWWW DevOps Stack - Autonomous Security & Health Audit (ISO 27001)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=ubuntu
WorkingDirectory=${STACK_ROOT}
Environment="NO_COLOR=1"
Environment="STACK_ROOT=${STACK_ROOT}"
ExecStart=/usr/bin/env bash ${STACK_ROOT}/scripts/audit-server.sh
StandardOutput=journal
StandardError=journal
EOF

cat <<EOF | sudo tee "${TIMER_FILE}" >/dev/null
[Unit]
Description=Run TwojaStronaWWW DevOps Audit every 15 minutes

[Timer]
OnBootSec=2min
OnCalendar=*:00/15
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now devops-audit.timer
echo "[OK] Harmonogram devops-audit.timer został zainstalowany i aktywowany (co 15 min)."

if [[ -f "${STACK_ROOT}/scripts/sync-p1-status.sh" ]]; then
    P1_SERVICE="/etc/systemd/system/devops-p1-radar.service"
    P1_TIMER="/etc/systemd/system/devops-p1-radar.timer"

    cat <<EOF | sudo tee "${P1_SERVICE}" >/dev/null
[Unit]
Description=Radar Systemow e-Zdrowia P1/NFZ/KSeF Sync
After=network-online.target

[Service]
Type=oneshot
User=ubuntu
ExecStart=/bin/bash ${STACK_ROOT}/scripts/sync-p1-status.sh
EOF

    cat <<EOF | sudo tee "${P1_TIMER}" >/dev/null
[Unit]
Description=Run Radar P1/NFZ Sync every 2 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now devops-p1-radar.timer
    echo "[OK] Harmonogram devops-p1-radar.timer został zainstalowany i aktywowany (co 2 min)."
fi

systemctl status devops-audit.timer --no-pager | head -n 12
