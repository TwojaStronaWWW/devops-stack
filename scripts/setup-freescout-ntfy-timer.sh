#!/usr/bin/env bash
# ==============================================================================
# setup-freescout-ntfy-timer.sh
# Idempotentna instalacja harmonogramu systemd devops-freescout-ntfy.timer (co 60s)
# Monitoruje nowe wątki przychodzące (threads.type=1) we FreeScout i wysyła
# natychmiastowe powiadomienia Push do własnego serwera Ntfy (0.00 PLN, 100% RODO).
# ==============================================================================
set -euo pipefail

STACK_ROOT="${STACK_ROOT:-/opt/devops-stack}"
SERVICE_FILE="/etc/systemd/system/devops-freescout-ntfy.service"
TIMER_FILE="/etc/systemd/system/devops-freescout-ntfy.timer"

cat <<EOF | sudo tee "${SERVICE_FILE}" >/dev/null
[Unit]
Description=FreeScout Central Mail Hub -> Self-Hosted Ntfy Push Notifier (ISO 27001 / Zero-PII Cloud)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=ubuntu
WorkingDirectory=${STACK_ROOT}
Environment="STACK_ROOT=${STACK_ROOT}"
ExecStart=/usr/bin/env bash ${STACK_ROOT}/scripts/sync-freescout-ntfy.sh
StandardOutput=journal
StandardError=journal
EOF

cat <<EOF | sudo tee "${TIMER_FILE}" >/dev/null
[Unit]
Description=Poll FreeScout MariaDB for incoming emails every 60 seconds

[Timer]
OnBootSec=45s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now devops-freescout-ntfy.timer
echo "[OK] Harmonogram devops-freescout-ntfy.timer został zainstalowany i aktywowany (co 60 sek)."
