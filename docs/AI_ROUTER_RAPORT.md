# AI Router – raport kontrolny i podręcznik operatora

> Stan na 2026-10-16. Dane liczbowe pochodzą z pomiarów na żywym serwerze VPS (`89.168.62.31`, `docker stats`, `docker system df`, `docker inspect`) oraz z kodu produkcyjnego `services/ai-router/src/`.

## 1. Jak to działa (jeden router, pamięć podręczna RAG `< 5 ms` i 10 „asystentów” w kaskadzie)

Na VPS działa **jeden** kontener `ai-router`. „Asystentami” są **modele LLM w 10-stopniowej kaskadzie** – router najpierw sprawdza atomową pamięć podręczną RAG (`/app/storage/cache`), a przy braku wpisu odpytuje modele po kolei, aż któryś odpowie. Użytkownik strony widzi jednego czatbota.

```
fuegolingua.pl / katosalsahub.pl / twojastronawww.pl
   ai-widget.js / widget.js (data-site-id) ──► https://ai.twojastronawww.pl/chat-router.php (Cloudflare Tunnel)
                                                  │
   CORS whitelist ► rate-limit 5/min/IP (+GC) ► walidacja site_id ► RAG (data/<site_id>-knowledge.txt, :ro)
                                                  │
                          ┌───────────────────────┴───────────────────────┐
                          ▼                                               ▼
        [ TRAFIENIE W CACHE RAG (< 5 ms) ]               [ BRAK W CACHE (COLD QUERY) ]
        Zwrot odpowiedzi w ~1.8 ms (0 tokenów)           ┌────── Kaskada 10 modeli (pozycja 0 → 9) ─────┐
        Auto-inwalidacja po filemtime bazy wiedzy        │ 0 gemini-3.5-flash (MINIMAL, ~1.5s, RPD: 500)│
        Pre-warming: scripts/warm-ai-cache.sh            │ 1 gemini-3.5-flash-lite  (MINIMAL, RPD: 1500)│
                                                         │ 2 gemini-3.7-flash       (LOW, RPD: 500)     │
                                                         │ 3 gemini-3.8-flash       (LOW, RPD: 500)     │
                                                         │ 4 gemma-4-31b-it         (RPD: 14400)        │
                                                         │ 5 groq/openai/gpt-oss-120b (~0.6s, RPD: 1000)│
                                                         │ 6 cerebras/gpt-oss-120b    (~0.15s, RPD:2400)│
                                                         │ 7 cerebras/qwen-3.8-27b    (~0.15s, 648000)  │
                                                         │ 8 cloudflare/llama-3.3-70b-fp8-fast (1000)   │
                                                         │ 9 openrouter/nemotron-3-super-120b:free (200)│
                                                         └──────────────────────────────────────────────┘
```

**Strony ≠ asystenci:** o tym, „kim” jest asystent na danej stronie, decyduje `site_id` → plik wiedzy (`fuegolingua-knowledge.txt`, `katosalsahub-knowledge.txt`, `twojastronawww-knowledge.txt`). Kod, klucze, cache i kaskada są wspólne.

## 2. Przełączanie, „zawieszanie” modeli (Inteligentny Cooldown) i Smart Fast-Fail

Router klasyfikuje każdy błąd i **zawiesza model (cooldown)** – kolejne zapytania pomijają go w `0 ms` bez czekania na timeout (4 s/model w Gemini).

| Odpowiedź dostawcy | Wynik (`result`) | Cooldown |
|---|---|---|
| 200 + pełny tekst (`finishReason=STOP`) | `ok` | – (zdejmuje cooldown) |
| 200, ucięta odpowiedź (`finishReason=MAX_TOKENS`) | `empty` (odrzucona) | **120 s** (nigdy nie trafia do Cache RAG) |
| 200 bez tekstu | `empty` | brak (kolejny model w tym samym żądaniu) |
| 200, `finishReason=SAFETY` | `safety` | brak |
| 429, minutowy limit | `rate_limited` | `retryDelay` z odpowiedzi, 5–300 s (domyślnie 60 s) |
| 429, limit dzienny (`PerDay`) | `quota_daily` | do północy czasu Pacyficznego (reset RPD Gemini = **09:00 w Polsce**) |
| 5xx (`503 High Demand`) | `unavailable` | **180 s (3 min)** |
| timeout (4s) / błąd cURL | `network` | **600 s (10 min)** + **natychmiastowy Fast-Fail do Groq LPU / Cerebras WSE** |
| 404 (model nie istnieje) | `not_found` | 1 h |
| 401/403/`API_KEY_INVALID` | `auth` | 5 min |

### Kluczowe zabezpieczenia wydajności i kompletności odpowiedzi (Lessons Learned):
1. **Ochrona przed ukrytymi tokenami myślenia (`thoughtsTokenCount` / `reasoning_tokens`):**
   - W modelach Gemini 3.x parametr `maxOutputTokens` obejmuje **sumę ukrytych tokenów myślenia (`thoughtsTokenCount`) oraz widocznego tekstu (`candidatesTokenCount`)**. Zbyt niski limit (np. `550`) bez wyłączenia myślenia powodował zużycie `~530` tokenów na wewnętrzne rozważania (`~4.2 s`) i ucinanie odpowiedzi w połowie zdania (`finishReason: MAX_TOKENS`).
   - Dlatego router wymusza `maxOutputTokens: 2048` oraz przekazuje:
     - `'thinkingConfig' => ['thinkingLevel' => 'MINIMAL']` dla modeli `gemini-3.5-*` (redukuje `thoughtsTokenCount` do `0` i czas odpowiedzi z `4.5 s` do **`1.4–2.1 s`**),
     - `'thinkingConfig' => ['thinkingLevel' => 'LOW']` dla modeli `gemini-3.7-flash` i `gemini-3.8-flash` (nie wspierają poziomu `MINIMAL`),
     - `'reasoning_effort' => 'low'` dla `cerebras/gpt-oss-120b` oraz `'disable_reasoning' => true` dla `cerebras/qwen-3.8-27b` (`reasoning_tokens = 0`, generacja w `~17–34 ms`),
     - `'reasoning' => ['effort' => 'none']` dla modelu `nvidia/nemotron-3-super-120b-a12b:free` na OpenRouterze (`reasoning_tokens = 0`).
   - Dodatkowo strażnik `finishReason === 'MAX_TOKENS'` (`length`) bezwzględnie odrzuca każdą uciętą odpowiedź i przełącza na kolejny model.
2. **Smart Fast-Fail do Groq LPU (`~0.6 s`) i Cerebras WSE (`~0.15 s`):**
   - Timeout pojedynczej próby Gemini wynosi **`4 s`** (`CURLOPT_CONNECTTIMEOUT = 2 s`).
   - Jeśli pierwszy model Gemini przekroczy timeout sieciowy LUB suma błędów i modeli pominiętych przez cooldown wyniesie $\ge 2$ (`$geminiTransientFailures + $geminiSkipped >= 2`), router **przerywa pętlę Google i w `0 ms` przeskakuje do `groq/openai/gpt-oss-120b` oraz `cerebras/gpt-oss-120b`**, które odpowiadają w `~0.15–0.8 s`.

## 3. Aktywni dostawcy i modele na VPS (5 kluczy API / 10 modeli)

| Provider | Modele w kaskadzie | Stan na VPS |
|---|---|---|
| Google AI Studio (`GEMINI_API_KEY`) | 5 (`gemini-3.5-flash`, `gemini-3.5-flash-lite`, `gemini-3.7-flash`, `gemini-3.8-flash`, `gemma-4-31b-it`) | **AKTYWNY** (`ai_router_provider_configured{provider="gemini"} 1`) |
| Groq Cloud (`GROQ_API_KEY`) | 1 (`openai/gpt-oss-120b`) | **AKTYWNY** (`ai_router_provider_configured{provider="groq"} 1`) |
| Cerebras WSE (`CEREBRAS_API_KEY`) | 2 (`gpt-oss-120b`, `qwen-3.8-27b`) | **AKTYWNY** (`ai_router_provider_configured{provider="cerebras"} 1`) |
| Cloudflare Workers AI (`CF_AI_API_TOKEN`) | 1 (`@cf/meta/llama-3.3-70b-instruct-fp8-fast`) | **AKTYWNY** (`ai_router_provider_configured{provider="cloudflare"} 1`) |
| OpenRouter (`OPENROUTER_API_KEY`) | 1 (`nvidia/nemotron-3-super-120b-a12b:free` — wyłącznie modele `:free`) | **AKTYWNY** (`ai_router_provider_configured{provider="openrouter"} 1`) |

**Łącznie działa 10 niezależnych modeli u 5 dostawców chmurowych.** Nawet całkowita awaria Google AI Studio powoduje automatyczne przełączenie na Groq Cloud LPU, Cerebras Wafer-Scale Engine, Cloudflare Workers AI lub OpenRouter.

## 4. Limity darmowe RPD, Cache RAG i Detektor „Gorącego Leada”

1. **Domyślne limity dzienne (RPD Free Tier) wbudowane w `ai-stats.php`:**
   - `gemini-3.5-flash-lite`: `1 500` zapytań/doba
   - `gemini-3.8-flash`, `gemini-3.7-flash`, `gemini-3.5-flash`: po `500` zapytań/doba
   - `gemma-4-31b-it`: `14 400` zapytań/doba
   - `groq/openai/gpt-oss-120b`: `1 000` zapytań/doba
   - `cerebras/gpt-oss-120b`: `2 400` zapytań/doba (`1 000 000` tokenów/doba)
   - `cerebras/qwen-3.8-27b`: `648 000` zapytań/doba (`450` RPM, `216 000 000` tokenów/doba)
   - `cloudflare/@cf/meta/llama-3.3-70b-instruct-fp8-fast`: `1 000` zapytań/doba (`10 000` Neurons/doba)
   - `openrouter/nvidia/nemotron-3-super-120b-a12b:free`: `200` zapytań/doba
   - Łączna dzienna pula darmowa wynosi **ponad 670 000 zapytań na dobę** (można ją nadpisać zmienną `MODEL_DAILY_LIMITS` w `.env`).
2. **Pamięć podręczna RAG (`/app/storage/cache`):**
   - Identyczne pytania (po normalizacji białych znaków i wielkości liter) są zwracane z dysku w **`~1.8 ms`** (`"cached": true`), nie zużywając ani jednego zapytania z puli RPD.
   - Klucz SHA-256 uwzględnia `filemtime` pliku wiedzy `<site_id>-knowledge.txt` — każda aktualizacja bazy wiedzy natychmiast unieważnia stare wpisy cache.
3. **Detektor „Gorącego Leada” (Zero-PII):**
   - Gdy klient zadaje **4. pytanie w jednej sesji rozmowy** (`count($sanitizedHistory) === 6`), router rejestruje zdarzenie `hot_lead_detected` i wysyła ciche powiadomienie Push do aplikacji **Ntfy.sh** na telefon właściciela.

## 5. Zasoby (pomiar na żywym VPS `89.168.62.31`)

| Zasób | Wartość |
|---|---|
| RAM kontenera | ~12,1 MiB / limit 128 MiB (9,45 %, 4 workery PHP) |
| CPU | ~0,01 % (limit 0,5 vCPU) |
| Obraz Docker | 138 MB (`php:8.3-alpine` + cURL) |
| Wolumen `ai_router_storage` | ~36 KB (rate-limit + cache RAG + `ai_stats.json` z automatycznym GC) |
| Dane RAG (`data/`) | 20 KB (`:ro`) |
| Dysk hosta | 9,7 GB z 96 GB (11 %) – w limicie Always Free 200 GB |
| Koszt | 0,00 PLN (Free Tier + Always Free) |

## 6. Narzędzia kontroli i powiadomienia Push 24/7

| Narzędzie | Do czego | Jak |
|---|---|---|
| **Grafana** → *AI Router – Gemini Proxy Monitor* | Wykresy: kto odpowiada, błędy wg przyczyny (zainicjalizowane seriami `0`), zawieszenia, paski dziennego limitu RPD, czasy odpowiedzi, ruch per strona | `scripts\open-dashboard.cmd` |
| **Raport CLI** | Pełny raport tekstowy (zasoby, providerzy, kaskada, statystyki cache RAG, próby modeli, logi) | `.\scripts\ai-router-report.ps1` albo na VPS `scripts/ai-router-report.sh` |
| **Dozzle** | Logi na żywo (strukturalne JSON: `attempt`, `request`, `skip_cooldown`, `hot_lead_detected`) | `open-dashboard.cmd` → Dozzle → `ai-router` |
| **Prometheus + Strażnik 24/7 (`devops-audit.timer`)** | 7 reguł alertów (`config/prometheus/rules/ai-router.yml`) sprawdzanych co 15 min przez `audit-server.sh` z wysyłką Push do **Ntfy.sh** | `npm run audit` |
| **Uptime Kuma** | Dostępność `http://ai-router:8080/health` (z automatycznym odświeżaniem cache DNS `nscd -i hosts` po wdrożeniu) | `open-dashboard.cmd` → Uptime Kuma |

### Reguły Alertów Prometheusa (`config/prometheus/rules/ai-router.yml`)

| Alert | Warunek | Poziom |
|---|---|---|
| `AIRouterDown` | brak scrape 2 min | critical |
| `AIRouterAllModelsFailed` | ≥1 zapytanie HTTP 502 w 10 min | critical |
| `AIRouterPrimaryModelSuspended` | model pozycji 0 zawieszony >5 min | warning |
| `AIRouterModelQuotaNearLimit` | >80 % dziennego limitu RPD | warning |
| `AIRouterRateLimitSpike` | >20 blokad 429 / 10 min | warning |
| `AIRouterFallbackInUse` | odpowiedzi z pozycji >0 w 15 min | info |
| `AIRouterNoFallbackProvider` | brak Groq/OpenRouter >1 h | info |

