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
    "katosalsahub|Czym zajmuje się społeczność i Fundacja Kato Salsa Hub?"
    "katosalsahub|Co dzieje się w Wolnych Ludziach w niedzielę (15:00–18:00)?"
    "katosalsahub|Gdzie tańczymy w Katowicach i gdzie za darmo zaparkować?"
    "katosalsahub|Wyjaśnij figury: Dile Que No, Enchufla i Setenta"
    "katosalsahub|Gdzie tańczymy w Katowicach i na Trzech Stawach?"
    "katosalsahub|Jak zacząć od zera (P0) i czy działa Multisport?"
    "katosalsahub|Ile kosztuje karnet?"
    "raricart|Ile kosztują stacje Live Food (Lody, Pancakes, Sery)?"
    "raricart|Jak działają pakiety łączone 2 i 3 stanowisk z rabatem?"
    "raricart|Jak wygląda dojazd i montaż stacji na weselu lub evencie?"
    "raricart|Jak sprawdzić wolny termin i zarezerwować datę?"
    "dancepuls|Czym jest aplikacja DancePuls?"
    "dancepuls|Jakie style tańca obsługuje DancePuls?"
    "dancepuls|Jak działa trening rytmu i clave?"
    "dancepuls|Czy DancePuls jest darmowy?"
    "radar-p1|Co zrobić w gabinecie lub aptece, gdy nie działa e-Recepta (P1)?"
    "radar-p1|Jak odróżnić awarię centralną P1/NFZ od problemu z lokalnym łączem?"
    "radar-p1|Co zrobić w rejestracji, gdy nie działa eWUŚ?"
    "radar-p1|Jak działa tryb awaryjny i offline24 w KSeF oraz ZUS e-ZLA?"
)

echo "==> [warm-ai-cache] Rozgrzewanie pamięci podręcznej RAG (${#PROMPTS[@]} pytań startowych)..."
hits=0
warmed=0

for entry in "${PROMPTS[@]}"; do
    site="${entry%%|*}"
    question="${entry#*|}"

    # Wyczyść lokalny licznik rate-limit (127.0.0.1 / Docker bridge) bez naruszania aktywnych blokad WAF Penalty Box ("blocked_until")
    docker exec ai-router sh -c 'for f in /app/storage/rate_limits/*.json; do [ -f "$f" ] && ! grep -q "\"blocked_until\"" "$f" && rm -f "$f"; done' 2>/dev/null || true

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

# Wyczyść lokalny plik rate-limit po zakończeniu pre-warmingu (z zachowaniem aktywnych banów Penalty Box)
docker exec ai-router sh -c 'for f in /app/storage/rate_limits/*.json; do [ -f "$f" ] && ! grep -q "\"blocked_until\"" "$f" && rm -f "$f"; done' 2>/dev/null || true

echo "==> [warm-ai-cache] Gotowe (już w cache: ${hits}, nowo wygenerowane: ${warmed})."
