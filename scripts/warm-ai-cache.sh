#!/usr/bin/env bash
# ==============================================================================
# Skrypt: warm-ai-cache.sh
# Opis:   Idempotentne rozgrzewanie (Pre-warming) pamięci podręcznej RAG
#         (/app/storage/cache) dla wszystkich przycisków Quick Prompts
#         obsługiwanych witryn (twojastronawww, fuegolingua, katosalsahub).
#         Jeśli odpowiedź dla aktualnego filemtime bazy wiedzy już istnieje
#         w cache, żądanie trwa ~1.8 ms i nie zużywa limitu RPD API.
# ==============================================================================
set -euo pipefail

ROUTER_URL="${AI_ROUTER_LOCAL_URL:-http://127.0.0.1:8085/chat-router.php}"
ORIGIN_HEADER="${AI_ROUTER_WARM_ORIGIN:-https://twojastronawww.pl}"

if ! docker ps --format '{{.Names}}' | grep -q '^ai-router$'; then
    echo "[warm-ai-cache] Kontener ai-router nie jest uruchomiony – pomijam pre-warming."
    exit 0
fi

# Lista par: site_id|pytanie (zgodna z QUICK_PROMPTS_MAP w _site-template/assets/js/ai-widget.js oraz widget.js)
PROMPTS=(
    "twojastronawww|Ile kosztuje strona WWW?"
    "twojastronawww|Dlaczego kod zamiast WordPressa?"
    "twojastronawww|Wdrożenie czatbota AI (RAG)"
    "twojastronawww|Jak wygląda współpraca?"
    "twojastronawww|Jak wygląda proces współpracy?"
    "twojastronawww|Jak działa asystent AI na stronie?"
    "fuegolingua|Bezpłatna lekcja próbna"
    "fuegolingua|Ile kosztuje kurs hiszpańskiego?"
    "fuegolingua|Zajęcia indywidualne czy grupowe?"
    "fuegolingua|Hiszpański w biznesie / branżowy"
    "katosalsahub|Czym jest Salsopedia i jak z niej korzystać?"
    "katosalsahub|Co to jest Enchufla i Dile Que No?"
    "katosalsahub|Gdzie tańczymy i jak działa Radio?"
    "katosalsahub|Jak dodać lub poprawić hasło w Salsopedii?"
    "katosalsahub|Wyjaśnij figury: Dile Que No, Enchufla i Setenta"
    "katosalsahub|Gdzie tańczymy w Katowicach i na Trzech Stawach?"
    "katosalsahub|Jak zacząć od zera (P0) i czy działa Multisport?"
    "katosalsahub|Ile kosztuje karnet?"
    "raricart|Jak działa kreator okładek AI?"
    "raricart|Ile trwa i kosztuje wysyłka obrazu?"
    "raricart|Jakie rozmiary obrazów są dostępne?"
    "raricart|Z jakich materiałów wykonane jest płótno?"
    "dancepuls|Czym jest aplikacja DancePuls?"
    "dancepuls|Jakie style tańca obsługuje DancePuls?"
    "dancepuls|Jak działa trening rytmu i clave?"
    "dancepuls|Czy DancePuls jest darmowy?"
)

echo "==> [warm-ai-cache] Rozgrzewanie pamięci podręcznej RAG (${#PROMPTS[@]} pytań startowych)..."
hits=0
warmed=0

for entry in "${PROMPTS[@]}"; do
    site="${entry%%|*}"
    question="${entry#*|}"

    # Wyczyść lokalny licznik rate-limit (127.0.0.1), aby seria pre-warmingu nie odbiła się od limitu 5/min
    docker exec ai-router sh -c 'rm -f /app/storage/rate_limits/*' 2>/dev/null || true

    payload=$(printf '{"site_id":"%s","question":"%s","history":[]}' "$site" "$question")
    resp=$(curl -s -m 12 -X POST "$ROUTER_URL" \
        -H "Origin: ${ORIGIN_HEADER}" \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "$payload" || true)

    if echo "$resp" | grep -q '"cached":true'; then
        hits=$((hits + 1))
    elif echo "$resp" | grep -q '"success":true'; then
        warmed=$((warmed + 1))
        echo "  + [NOWY WPIS CACHE] ${site}: ${question}"
    else
        echo "  ! [OSTRZEŻENIE] Nie udało się rozgrzać: ${site}: ${question}"
    fi
done

# Wyczyść lokalny plik rate-limit po zakończeniu pre-warmingu
docker exec ai-router sh -c 'rm -f /app/storage/rate_limits/*' 2>/dev/null || true

echo "==> [warm-ai-cache] Gotowe (już w cache: ${hits}, nowo wygenerowane: ${warmed})."
