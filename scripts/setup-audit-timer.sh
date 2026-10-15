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
OnUnitActiveSec=15min
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now devops-audit.timer
echo "[OK] Harmonogram devops-audit.timer został zainstalowany i aktywowany (co 15 min)."
systemctl status devops-audit.timer --no-pager | head -n 12
