#!/usr/bin/env bash
# ==============================================================================
# ai-router-report.sh - pelny raport kontrolny AI Routera (uruchamiany NA VPS)
#
# Zrodla danych (wylacznie odczyt, zero zmian na serwerze):
#   - GET /metrics z kontenera ai-router (liczniki trwale w wolumenie ai_router_storage)
#   - docker logs (strukturalne logi JSON: event=attempt|request|skip_cooldown)
#   - docker inspect/stats/system df oraz df hosta
#
# Uzycie:  ./ai-router-report.sh [okno_logow, domyslnie 24h]
# Z Windows: scripts\ai-router-report.ps1
# Standard: ISO 27001 - raport nie zawiera tresci pytan, adresow IP ani kluczy API.
# ==============================================================================
set -euo pipefail

C="${AI_ROUTER_CONTAINER:-ai-router}"
SINCE="${1:-24h}"

hr()  { printf '\n==== %s ====\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

if ! docker inspect "$C" >/dev/null 2>&1; then
  echo "BLAD: kontener '$C' nie istnieje." >&2
  exit 1
fi

METRICS="$(docker exec "$C" wget -qO- http://127.0.0.1:8080/metrics 2>/dev/null || true)"
if [ -z "$METRICS" ]; then
  echo "OSTRZEZENIE: brak odpowiedzi z /metrics (kontener zdrowy? wdrozona wersja z telemetria?)" >&2
fi

# Pomocnik: wartosc etykiety z linii metryki
lbl() { sed -n "s/.*[{,]$1=\"\([^\"]*\)\".*/\1/p"; }
# Pomocnik: linie danej metryki
met() { printf '%s\n' "$METRICS" | grep -E "^$1(\{| )" || true; }

printf 'RAPORT AI ROUTER - %s (UTC), okno logow: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "$SINCE"

# ------------------------------------------------------------------------------
hr "1. KONTENER I ZASOBY"
docker inspect "$C" --format 'Status: {{.State.Status}} | Health: {{if .State.Health}}{{.State.Health.Status}}{{else}}brak{{end}} | Start: {{.State.StartedAt}} | Restarty: {{.RestartCount}}'
docker inspect "$C" --format 'Limity: RAM={{.HostConfig.Memory}} B, CPU(nano)={{.HostConfig.NanoCpus}}, polityka restartu={{.HostConfig.RestartPolicy.Name}}'
docker stats --no-stream --format 'Zuzycie teraz: CPU={{.CPUPerc}} RAM={{.MemUsage}} ({{.MemPerc}}) PID={{.PIDs}}' "$C"
docker images --format 'Obraz: {{.Repository}}:{{.Tag}} rozmiar={{.Size}}' | grep -i "ai-router" || true
docker system df -v 2>/dev/null | grep -iE 'VOLUME NAME|ai_router_storage' | head -2 || true
docker exec "$C" sh -c 'echo "Dane RAG (/app/data): $(du -sh /app/data 2>/dev/null | cut -f1)"; echo "Stan (/app/storage): $(du -sh /app/storage 2>/dev/null | cut -f1) | plikow rate-limit: $(ls /app/storage/rate_limits 2>/dev/null | wc -l)"' 2>/dev/null || true
df -h / | awk 'NR==2 {print "Dysk hosta: uzyte " $3 " z " $2 " (" $5 ") | wolne " $4}'

# ------------------------------------------------------------------------------
hr "2. PROVIDERZY (klucze skonfigurowane?)"
met ai_router_provider_configured | while read -r line; do
  p="$(printf '%s' "$line" | lbl provider)"; v="${line##* }"
  printf '  %-12s %s\n' "$p" "$([ "$v" = "1" ] && echo 'AKTYWNY' || echo 'brak klucza (nieaktywny)')"
done

# ------------------------------------------------------------------------------
hr "3. KASKADA MODELI (kolejnosc prob) I STAN"
printf '  %-3s %-34s %-10s %-11s %-9s %-8s %-8s %s\n' "#" "MODEL" "PROVIDER" "STAN" "COOLDOWN" "DZIS" "OK DZIS" "LIMIT/DOBA"
met ai_router_model_info | sort -t'"' -k6 | while read -r line; do
  m="$(printf '%s' "$line" | lbl model)"; p="$(printf '%s' "$line" | lbl provider)"; pos="$(printf '%s' "$line" | lbl position)"
  val() { met "$1" | grep "model=\"$m\"" | head -1 | awk '{print $NF}' || true; }
  susp="$(val ai_router_model_suspended)"; cd="$(val ai_router_model_cooldown_remaining_seconds)"
  today="$(val ai_router_model_requests_today)"; ok="$(val ai_router_model_ok_today)"; lim="$(val ai_router_model_daily_limit)"
  printf '  %-3s %-34s %-10s %-11s %-9s %-8s %-8s %s\n' "$pos" "$m" "$p" "$([ "${susp:-0}" = "1" ] && echo ZAWIESZONY || echo aktywny)" "${cd:-0}s" "${today:-0}" "${ok:-0}" "${lim:-nie ustawiono}"
done
echo "  (doba kwotowa Gemini resetuje sie o polnocy czasu Pacyficznego = 09:00 w Polsce)"

# ------------------------------------------------------------------------------
hr "4. WYNIKI ZAPYTAN CZATU (od poczatku statystyk)"
met ai_router_requests_total | while read -r line; do
  printf '  %-14s %-22s %s\n' "$(printf '%s' "$line" | lbl site)" "$(printf '%s' "$line" | lbl outcome)" "${line##* }"
done
echo "  Glebokosc kaskady odpowiedzi (0 = pierwszy asystent, >0 = przelaczenie):"
met ai_router_answers_by_depth_total | while read -r line; do
  printf '    pozycja %-3s odpowiedzi: %s\n' "$(printf '%s' "$line" | lbl depth)" "${line##* }"
done
sum="$(met ai_router_request_duration_seconds_sum | awk '{print $NF}')"; cnt="$(met ai_router_request_duration_seconds_count | awk '{print $NF}')"
awk -v s="${sum:-0}" -v c="${cnt:-0}" 'BEGIN { if (c > 0) printf "  Sredni czas udanej odpowiedzi: %.2f s (n=%d)\n", s/c, c; else print "  Brak udanych odpowiedzi w statystykach." }'

# ------------------------------------------------------------------------------
hr "5. PROBY MODELI WG WYNIKU (przelaczenia i przyczyny)"
printf '  %-34s %-14s %s\n' "MODEL" "WYNIK" "LICZBA"
met ai_router_model_attempts_total | while read -r line; do
  printf '  %-34s %-14s %s\n' "$(printf '%s' "$line" | lbl model)" "$(printf '%s' "$line" | lbl result)" "${line##* }"
done | sort
echo "  Legenda: ok | rate_limited/quota_daily=429 | unavailable=5xx | not_found=404 | auth=zly klucz | network=timeout | empty=pusta odpowiedz"
echo "  Pominiecia z powodu cooldownu:"
met ai_router_model_skipped_total | awk '$NF > 0 {print}' | while read -r line; do
  printf '    %-34s %s\n' "$(printf '%s' "$line" | lbl model)" "${line##* }"
done

# ------------------------------------------------------------------------------
hr "6. LOGI ($SINCE): ZDARZENIA STRUKTURALNE"
LOGS="$(docker logs --since "$SINCE" "$C" 2>&1 | grep -F 'ai-router {' || true)"
if [ -z "$LOGS" ]; then
  echo "  Brak zdarzen strukturalnych w oknie $SINCE (brak ruchu czatu lub starsza wersja bez telemetrii)."
else
  echo "  Zapytania wg wyniku:"
  printf '%s\n' "$LOGS" | grep -F '"event":"request"' | sed -n 's/.*"outcome":"\([^"]*\)".*/\1/p' | sort | uniq -c | sed 's/^/    /' || true
  echo "  Proby modeli wg modelu/wyniku:"
  printf '%s\n' "$LOGS" | grep -F '"event":"attempt"' | sed -n 's/.*"model":"\([^"]*\)","result":"\([^"]*\)".*/\1 \2/p' | sort | uniq -c | sed 's/^/    /' || true
  echo "  Ostatnie 10 problemow (proby nieudane / pominiecia):"
  printf '%s\n' "$LOGS" | grep -E '"event":"(attempt|skip_cooldown)"' | grep -vF '"result":"ok"' | tail -10 | sed 's/^ai-router /    /' || true
  echo "  Ostatnie 10 zapytan:"
  printf '%s\n' "$LOGS" | grep -F '"event":"request"' | tail -10 | sed 's/^ai-router /    /' || true
fi

hr "KONIEC RAPORTU"
exit 0
