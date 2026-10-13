#!/usr/bin/env bash
# ==============================================================================
# preview-tunnel.sh
# Błyskawiczny, szyfrowany podgląd strony (Quick Tunnel via trycloudflare.com)
# Eliminuje potrzebę utrzymywania publicznych subdomen 'test.nazwastrony.pl'.
# ==============================================================================
set -euo pipefail

TARGET="${1:-http://localhost:3000}"

echo "======================================================================"
echo ">> [Cloudflare Quick Tunnel] Generowanie tymczasowego podglądu staging"
echo ">> Cel docelowy: ${TARGET}"
echo ">> Zero konfiguracji DNS, zero otwartych portów na zaporze."
echo ">> Po zakończeniu testów naciśnij Ctrl+C, aby natychmiast zniszczyć link."
echo "======================================================================"

# Uruchomienie oficjalnego kontenera cloudflared w sieci devops_internal_network
docker run --rm -it \
  --name ephemeral-preview-tunnel \
  --network devops_internal_network \
  cloudflare/cloudflared:latest \
  tunnel --no-autoupdate --url "${TARGET}"
