#!/usr/bin/env bash
# ==============================================================================
# setup-backup-timer.sh
# Idempotentna instalacja harmonogramu systemd devops-backup.timer (03:00 UTC)
# Uruchamia w nocy automatyczny backup wolumenów Dockera (backup-offsite.sh)
# oraz backup serwisów WWW z hostingu LH.pl (backup-websites-lh.sh).
# ==============================================================================
set -euo pipefail

STACK_ROOT="${STACK_ROOT:-/opt/devops-stack}"
SERVICE_FILE="/etc/systemd/system/devops-backup.service"
TIMER_FILE="/etc/systemd/system/devops-backup.timer"

cat <<EOF | sudo tee "${SERVICE_FILE}" >/dev/null
[Unit]
Description=TwojaStronaWWW DevOps Stack - Automated Offsite Backup (Volumes & LH.pl Websites)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=ubuntu
WorkingDirectory=${STACK_ROOT}
Environment="STACK_ROOT=${STACK_ROOT}"
ExecStart=/usr/bin/env bash ${STACK_ROOT}/scripts/backup-offsite.sh
ExecStart=/usr/bin/env bash ${STACK_ROOT}/scripts/backup-websites-lh.sh
StandardOutput=journal
StandardError=journal
EOF

cat <<EOF | sudo tee "${TIMER_FILE}" >/dev/null
[Unit]
Description=Run TwojaStronaWWW DevOps Offsite Backups daily at 03:00 UTC

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now devops-backup.timer
echo "[OK] Harmonogram devops-backup.timer został zainstalowany i aktywowany (codziennie o 03:00 UTC)."
systemctl status devops-backup.timer --no-pager | head -n 12
