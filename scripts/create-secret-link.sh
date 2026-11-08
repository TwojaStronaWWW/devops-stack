#!/usr/bin/env bash
# ==============================================================================
# create-secret-link.sh
# Pomocnik administratora do bezpiecznego przekazywania haseł klientom
# przez PrivateBin (Zero-Knowledge Vault — "Burn After Reading").
# Standard: ISO 27001 Out-of-Band Credential Sharing
# ==============================================================================
set -euo pipefail

LOCAL_PORT="${PRIVATEBIN_LOCAL_PORT:-8087}"
LOCAL_URL="http://127.0.0.1:${LOCAL_PORT}"
PUBLIC_URL="${PRIVATEBIN_PUBLIC_URL:-https://sejf.twojastronawww.pl}"
SHOULD_OPEN="true"

for arg in "$@"; do
  case "${arg}" in
    --open|-Open|-o)
      SHOULD_OPEN="true"
      ;;
    --no-open|--check|-n)
      SHOULD_OPEN="false"
      ;;
    --help|-h)
      echo "Użycie: $0 [--open | --no-open]"
      echo "  --open     Otwórz Sejf Haseł w przeglądarce (domyślnie przy braku argumentów)"
      echo "  --no-open  Tylko sprawdź status i wyświetl ściągę bezpieczeństwa ISO 27001"
      exit 0
      ;;
  esac
done

echo "======================================================================"
echo ">> [PrivateBin Zero-Knowledge Vault] Jednorazowy Sejf Haseł (AES-256-GCM)"
echo "======================================================================"

TARGET_URL="${PUBLIC_URL}"

if curl -fsS --max-time 2 "${LOCAL_URL}" >/dev/null 2>&1 || (echo >/dev/tcp/127.0.0.1/"${LOCAL_PORT}") >/dev/null 2>&1; then
  echo ">> [OK] Wykryto aktywny lokalny tunel na porcie ${LOCAL_PORT} (${LOCAL_URL})."
  TARGET_URL="${LOCAL_URL}"
else
  echo ">> [INFO] Lokalny tunel na porcie ${LOCAL_PORT} (${LOCAL_URL}) nie jest aktywny."
  echo ">>        Użycie publicznego adresu Cloudflare Zero Trust: ${PUBLIC_URL}"
  TARGET_URL="${PUBLIC_URL}"
fi

echo ""
echo "----------------------------------------------------------------------"
echo " ŚCIĄGA BEZPIECZEŃSTWA ISO 27001 (Out-of-Band Credential Sharing):"
echo "  1. Wklej poświadczenia w Sejfie (opcja 'Zniszcz po przeczytaniu' jest domyślnie włączona)."
echo "  2. Ustaw dodatkowe hasło w polu 'Hasło' (wymagane dla poświadczeń produkcyjnych)."
echo "  3. Kliknij 'Utwórz' — klucz AES-256-GCM znajduje się po znaku '#' i NIGDY nie trafia na serwer."
echo "  4. Wyślij LINK klientowi 1. kanałem (np. e-mail / osTicket), a HASŁO 2. kanałem (np. SMS / Signal)."
echo "  5. Uwaga: Klientowi zawsze wysyłaj link z domeną publiczną (${PUBLIC_URL}#...), a nie 127.0.0.1!"
echo "----------------------------------------------------------------------"
echo ">> Adres lokalny (tunel SSH): ${LOCAL_URL}"
echo ">> Adres publiczny (Klient):  ${PUBLIC_URL}"
echo ""

if [ "${SHOULD_OPEN}" = "true" ]; then
  echo ">> Otwieranie Sejfu Haseł w przeglądarce: ${TARGET_URL}"
  if command -v wslview >/dev/null 2>&1; then
    wslview "${TARGET_URL}" >/dev/null 2>&1 &
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${TARGET_URL}" >/dev/null 2>&1 &
  elif command -v cmd.exe >/dev/null 2>&1; then
    cmd.exe /c start "" "${TARGET_URL}" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then
    open "${TARGET_URL}" >/dev/null 2>&1 &
  else
    echo ">> [INFO] Brak środowiska graficznego — otwórz ręcznie: ${TARGET_URL}"
  fi
fi
