# AI Router – raport kontrolny i podręcznik operatora

> Stan na 2026-10-15. Dane liczbowe pochodzą z pomiarów na VPS (`docker stats`, `docker system df`, `docker inspect`) oraz z analizy kodu `services/ai-router/src/`.

## 1. Jak to działa (jeden router, wielu „asystentów”)

Na VPS działa **jeden** kontener `ai-router`. „Asystentami” są **modele LLM w kaskadzie** – router próbuje ich po kolei, aż któryś odpowie. Użytkownik strony widzi jednego czatbota.

```
fuegolingua.pl / katosalsahub.pl / twojastronawww.pl
   widget.js (data-site-id) ──► https://ai.twojastronawww.pl/chat-router.php  (Cloudflare Tunnel)
                                   │
                  CORS whitelist ► rate-limit 5/min/IP ► walidacja site_id ► RAG (data/<site_id>-knowledge.txt, :ro)
                                   │
        ┌──────────────── kaskada (pozycja 0 → N) ────────────────┐
        │ 0 gemini-3.8-flash (GEMINI_MODEL)                       │
        │ 1 gemini-3.7-flash                                      │  Google AI Studio, ten sam klucz,
        │ 2 gemini-3.5-flash                                      │  osobna pula Free Tier na model
        │ 3 gemini-3.5-flash-lite                                 │
        │ 4 gemma-4-31b-it                                        │
        │ 5 groq/openai/gpt-oss-120b          (jeśli GROQ_API_KEY)│  inny dostawca
        │ 6 openrouter/llama-3.3-70b…:free (jeśli OPENROUTER_API_KEY)│ inny dostawca
        └─────────────────────────────────────────────────────────┘
```

**Strony ≠ asystenci:** o tym, „kim” jest asystent na danej stronie, decyduje `site_id` → plik wiedzy (`fuegolingua-knowledge.txt`, `katosalsahub-knowledge.txt`, `twojastronawww-knowledge.txt`). Kod, klucze i kaskada są wspólne.

## 2. Przełączanie i „zawieszanie” modeli (nowość)

Router klasyfikuje każdy błąd i **zawiesza model (cooldown)** – kolejne zapytania pomijają go bez czekania na timeout (22 s/model).

| Odpowiedź dostawcy | Wynik (`result`) | Cooldown |
|---|---|---|
| 200 + tekst | `ok` | – (zdejmuje cooldown) |
| 200 bez tekstu | `empty` | brak (kolejny model w tym samym żądaniu) |
| 200, `finishReason=SAFETY` | `safety` | brak |
| 429, minutowy limit | `rate_limited` | `retryDelay` z odpowiedzi, 5–300 s (domyślnie 60 s) |
| 429, limit dzienny (`PerDay`) | `quota_daily` | do północy czasu Pacyficznego (reset RPD Gemini = **09:00 w Polsce**) |
| 5xx | `unavailable` | 30 s |
| timeout / błąd cURL | `network` | 30 s |
| 404 (model nie istnieje) | `not_found` | 1 h |
| 401/403/`API_KEY_INVALID` | `auth` | 5 min |

Zasady:
- Jeśli **wszystkie** modele są zawieszone, router mimo to próbuje je po kolei (lepsza szansa niż natychmiastowy błąd).
- `API_KEY_INVALID` przerywa kaskadę Gemini (kolejne modele używają tego samego klucza).
- Pozycja modelu, który odpowiedział (`depth`), jest liczona: **0 = pierwszy asystent**, >0 = przełączenie.

## 3. Ile asystentów mamy dokładnie

| Provider | Modele | Stan na VPS |
|---|---|---|
| Gemini API | 5 (gemini-3.8-flash, 3.7-flash, 3.5-flash, 3.5-flash-lite, gemma-4-31b-it) | **aktywny** (`GEMINI_API_KEY` ustawiony) |
| Groq | 1 (`openai/gpt-oss-120b`; llama-3.3 zniknęła z oferty konta) | **aktywny** (`GROQ_API_KEY` ustawiony 2026-10-15) |
| OpenRouter | 1 (llama-3.3-70b-instruct:free) | **nieaktywny** – `OPENROUTER_API_KEY` pusty |

**Efektywnie działa 5 modeli, wszystkie na jednym koncie/kluczu Google.** Jedna awaria klucza lub konta wyłącza całą kaskadę – dlatego zalecane jest dodanie darmowego klucza Groq (alert `AIRouterNoFallbackProvider` przypomina o tym po 1 h).

## 4. Limity darmowe („ile mamy minut/zapytań”)

Limity Free Tier (RPM/RPD/TPM) są **per model, per projekt** i Google zmienia je bez ostrzeżenia – **nie wpisano ich na sztywno**. Aby miały pasek zużycia i alert >80%:

1. Otwórz Google AI Studio → *Rate limits* i odczytaj RPD dla każdego modelu.
2. Ustaw w `/opt/devops-stack/compose/.env` (po zapisie w KeePass wg procedury):
   `MODEL_DAILY_LIMITS=gemini-3.8-flash=<RPD>,gemini-3.7-flash=<RPD>,…`
3. `docker compose up -d ai-router`.

Router liczy **realne zużycie**: `ai_router_model_requests_today` = liczba żądań, które dotarły do API modelu w bieżącej dobie kwotowej (każda próba, także nieudana, zużywa pulę).

## 5. Zasoby (pomiar na VPS)

| Zasób | Wartość |
|---|---|
| RAM kontenera | ~8,6 MiB / limit 128 MiB (6,7 %) |
| CPU | ~0 % (limit 0,5 vCPU) |
| Obraz Docker | 138 MB (`php:8.3-alpine` + cURL) |
| Wolumen `ai_router_storage` | 54 B w momencie pomiaru (rate-limit + statystyki ~1 kB) |
| Dane RAG (`data/`) | 16 KB |
| Dysk hosta | 8,5 GB z 96 GB (9 %) – w limicie Always Free 200 GB |
| Koszt | 0,00 PLN (Free Tier + Always Free) |

Rośnie tylko liczba plików rate-limit (1 plik / unikalne IP) – śledzi to `ai_router_rate_limit_clients` i `ai_router_storage_bytes`.

## 6. Narzędzia kontroli

| Narzędzie | Do czego | Jak |
|---|---|---|
| **Grafana** → *AI Router – Gemini Proxy Monitor* | Wykresy: kto odpowiada, błędy wg przyczyny, zawieszenia, zużycie dzienne, czasy, udział modeli zapasowych, ruch per strona | `scripts\open-dashboard.cmd` |
| **Raport CLI** | Pełny raport tekstowy (zasoby, providerzy, kaskada, statystyki, logi) | `.\scripts\ai-router-report.ps1 [-Since 6h]` albo na VPS `scripts/ai-router-report.sh` |
| **Dozzle** | Logi na żywo (strukturalne JSON: `attempt`, `request`, `skip_cooldown`) | `open-dashboard.cmd` → Dozzle → `ai-router` |
| **Prometheus** | 7 reguł alertów (`config/prometheus/rules/ai-router.yml`) widocznych w zakładce *Alerts* | `127.0.0.1:9090` przez tunel SSH |
| **Uptime Kuma** | Dostępność `/health` | bez zmian |

Przykładowe logi (bez treści pytań, IP i kluczy – ISO 27001):
```
ai-router {"event":"attempt","provider":"gemini","model":"gemini-3.8-flash","result":"unavailable","http":503,"ms":5514,"cooldown":30}
ai-router {"event":"attempt","provider":"gemini","model":"gemini-3.5-flash","result":"ok","http":200,"ms":5634,"cooldown":0}
ai-router {"event":"request","site":"fuegolingua","outcome":"success","http":200,"model":"gemini-3.5-flash","depth":2,"attempts":3,"ms":13385}
```

### Alerty

| Alert | Warunek | Poziom |
|---|---|---|
| `AIRouterDown` | brak scrape 2 min | critical |
| `AIRouterAllModelsFailed` | ≥1 zapytanie HTTP 502 w 10 min | critical |
| `AIRouterPrimaryModelSuspended` | model pozycji 0 zawieszony >5 min | warning |
| `AIRouterModelQuotaNearLimit` | >80 % `MODEL_DAILY_LIMITS` | warning |
| `AIRouterRateLimitSpike` | >20 blokad 429 / 10 min | warning |
| `AIRouterFallbackInUse` | odpowiedzi z pozycji >0 w 15 min | info |
| `AIRouterNoFallbackProvider` | brak Groq/OpenRouter >1 h | info |

> Alertmanager nie jest wdrożony (`alerting.alertmanagers: []`) – alerty są widoczne w Prometheusie/Grafanie, ale nie wysyłają powiadomień.

## 7. Obserwacje i ryzyka

1. **Test lokalny (2026-10-15 13:02):** `gemini-3.8-flash` i `gemini-3.7-flash` zwróciły **HTTP 503** (po 5,5 s i 2,0 s), odpowiedział dopiero `gemini-3.5-flash` (pozycja 2, łącznie 13,4 s). Kaskada zadziałała – ale pokazuje, że pierwszy model bywa niedostępny, a opóźnienie rośnie. Cooldown 30 s ogranicza to dla kolejnych zapytań.
2. **Serwer PHP był jednowątkowy** (`php -S`): jedno wolne żądanie (do 22 s × 6 modeli) blokowało healthcheck i innych klientów. Dodano `PHP_CLI_SERVER_WORKERS=4` (wymaga wdrożenia).
3. **Historyczne logi nie istnieją:** przed tą zmianą router logował tylko `Accepted/Closing`, więc nie da się odtworzyć, który model odpowiadał w przeszłości. Statystyki zaczynają się od wdrożenia.
4. **Brak zapasowego providera** (Groq/OpenRouter) – patrz pkt 3.
5. **`/metrics` jest osiągalny przez ten sam host co czat** (jeśli tunel wystawia `ai.twojastronawww.pl` w całości). Metryki nie zawierają danych wrażliwych (brak IP, treści, kluczy), ale zalecane jest zawężenie reguły ingress w Cloudflare do `/chat-router.php` i `/widget.js` oraz `/health`.
6. Nazwy modeli (`gemini-3.x`, `gemma-4-31b-it`) pochodzą z konfiguracji repo; ich dostępność weryfikuje wyłącznie odpowiedź API (`not_found` w raporcie = model nie istnieje).
