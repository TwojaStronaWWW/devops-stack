#!/usr/bin/env bash
set -euo pipefail
cd /opt/devops-stack/sites/medicusnoster
git fetch -q origin main
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)
if [ "$LOCAL" != "$REMOTE" ]; then
  git reset --hard origin/main >/dev/null
fi
