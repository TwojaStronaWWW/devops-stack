#!/usr/bin/env bash
# ==============================================================================
# generate-client-audit.sh — Generator Audytów Sprzedażowych „Przed i Po”
# (HTML A4 + JSON + opcjonalny wydruk PDF przez Chromium / Chrome / Edge)
#
# Użycie:
#   ./scripts/generate-client-audit.sh https://twojastronawww.pl --client-name "Nazwa" [--open]
#   ./scripts/generate-client-audit.sh --self-test
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JS_SCRIPT="${SCRIPT_DIR}/generate-client-audit.js"

if [ ! -f "$JS_SCRIPT" ]; then
  echo "BŁĄD: Brak pliku ${JS_SCRIPT}" >&2
  exit 1
fi

OPEN_AFTER=0
FORWARD_ARGS=()

for arg in "$@"; do
  if [ "$arg" = "--open" ]; then
    OPEN_AFTER=1
  else
    FORWARD_ARGS+=("$arg")
  fi
done

if [ "${#FORWARD_ARGS[@]}" -eq 0 ]; then
  node "$JS_SCRIPT" --help
  exit 1
fi

OUTPUT="$(node "$JS_SCRIPT" "${FORWARD_ARGS[@]}")"
printf '%s\n' "$OUTPUT"

# Jeśli uruchomiono --self-test, kończymy po weryfikacji
for arg in "${FORWARD_ARGS[@]}"; do
  if [ "$arg" = "--self-test" ] || [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
    exit 0
  fi
done

HTML_PATH="$(printf '%s\n' "$OUTPUT" | sed -n 's/^HTML_REPORT=//p' | head -n 1)"
if [ -z "$HTML_PATH" ] || [ ! -f "$HTML_PATH" ]; then
  echo "BŁĄD: Nie udało się odczytać ścieżki raportu HTML." >&2
  exit 1
fi

PDF_PATH="${HTML_PATH%.html}.pdf"
BROWSER_BIN=""
for candidate in google-chrome chromium chromium-browser microsoft-edge msedge; do
  if command -v "$candidate" >/dev/null 2>&1; then
    BROWSER_BIN="$candidate"
    break
  fi
done

if [ -n "$BROWSER_BIN" ]; then
  echo "==> Generowanie pliku PDF przez ${BROWSER_BIN} (--headless --print-to-pdf)..."
  "$BROWSER_BIN" --headless --disable-gpu --no-pdf-header-footer "--print-to-pdf=${PDF_PATH}" "file://${HTML_PATH}" >/dev/null 2>&1 || true
  if [ -f "$PDF_PATH" ]; then
    echo "PDF_REPORT=${PDF_PATH}"
  fi
fi

if [ "$OPEN_AFTER" -eq 1 ]; then
  TARGET_OPEN="$HTML_PATH"
  [ -f "$PDF_PATH" ] && TARGET_OPEN="$PDF_PATH"
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$TARGET_OPEN" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then
    open "$TARGET_OPEN"
  fi
fi
