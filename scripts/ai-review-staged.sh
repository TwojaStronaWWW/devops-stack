#!/usr/bin/env bash
# ==============================================================================
# ai-review-staged.sh
# Headless AI Security Review CLI (Claude / VPS AI Router) dla lokalnych zmian Git
# Analizuje `git diff --cached` (lub `git diff HEAD`) pod kątem ISO 27001, OWASP,
# PHP2Shell (CGI/phar://), sshole (musl) oraz Supply Chain przed commitem/pushem.
# ==============================================================================
set -euo pipefail

DIFF_TEXT="$(git diff --cached 2>/dev/null || true)"
if [[ -z "${DIFF_TEXT}" ]]; then
    DIFF_TEXT="$(git diff HEAD 2>/dev/null || true)"
fi

if [[ -z "${DIFF_TEXT}" ]]; then
    echo "✅ Brak lokalnych zmian w git diff do audytu."
    exit 0
fi

SHORT_DIFF="$(echo "${DIFF_TEXT}" | head -n 160 | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || echo "${DIFF_TEXT}" | head -n 160)"
API_URL="${AI_ROUTER_URL:-https://ai.twojastronawww.pl/chat-router.php}"

PAYLOAD="$(jq -n \
    --arg q "Przeprowadź zwięzły audyt bezpieczeństwa ISO 27001 i OWASP ASVS (LOCK_EX, Sec-Fetch-Site, PHP2Shell/phar://, XSS, Supply Chain .npmrc) dla poniższego git diff w kontekście dynamicznym. Jeśli kod jest bezpieczny, potwierdź krótko po polsku." \
    --arg ctx "${SHORT_DIFF}" \
    '{site_id: "twojastronawww", question: $q, dynamic_context: $ctx}')"

echo "🛡️  Wysyłanie lokalnego diffu do audytu bezpieczeństwa (${API_URL})..."
RES="$(curl -sS --max-time 25 "${API_URL}" \
    -H "Content-Type: application/json" \
    -H "Origin: https://twojastronawww.pl" \
    --data-binary "${PAYLOAD}" || true)"

ANSWER="$(echo "${RES}" | jq -r '.answer // empty' 2>/dev/null || true)"
MODEL="$(echo "${RES}" | jq -r '.model // "AI Router"' 2>/dev/null || echo 'AI Router')"

if [[ -n "${ANSWER}" ]]; then
    echo "======================================================================"
    echo "🤖 Wynik Audytu (${MODEL}):"
    echo "======================================================================"
    echo "${ANSWER}"
    echo "======================================================================"
else
    echo "⚠️  Brak odpowiedzi z bramki AI (sprawdź połączenie lub limit zapytań)."
fi
