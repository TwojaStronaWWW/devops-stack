# AI Router – raport kontrolny i podręcznik operatora

> Stan na 2026-10-16. Dane liczbowe pochodzą z pomiarów na żywym serwerze VPS (`89.168.62.31`, `docker stats`, `docker system df`, `docker inspect`) oraz z kodu produkcyjnego `services/ai-router/src/`.

## 1. Jak to działa (jeden router, pamięć podręczna RAG `< 5 ms` i 11 „asystentów” w kaskadzie)

Na VPS działa **jeden** kontener `ai-router`. „Asystentami” są **modele LLM w 11-stopniowej kaskadzie** – router najpierw sprawdza atomową pamięć podręczną RAG (`/app/storage/cache`), a przy braku wpisu odpytuje modele po kolei, aż któryś odpowie. Użytkownik strony widzi jednego czatbota.

```
fuegolingua.pl / katosalsahub.pl / twojastronawww.pl
   ai-widget.js / widget.js (data-site-id) ──► https://ai.twojastronawww.pl/chat-router.php (Cloudflare Tunnel)
                                                  │
   CORS whitelist ► rate-limit 5/min/IP (+GC) ► walidacja site_id ► RAG (data/<site_id>-knowledge.txt, :ro)
                                                  │
                          ┌───────────────────────┴───────────────────────┐
                          ▼                                               ▼
        [ TRAFIENIE W CACHE RAG (< 5 ms) ]               [ BRAK W CACHE (COLD QUERY) ]
        Zwrot odpowiedzi w ~1.8 ms (0 tokenów)           ┌────── Kaskada 11 modeli (pozycja 0 → 10) ────┐
        Auto-inwalidacja po filemtime bazy wiedzy        │ 0  gemini-3.5-flash (MINIMAL, ~1.5s, RPD:500)│
        Pre-warming: scripts/warm-ai-cache.sh            │ 1  gemini-3.5-flash-lite  (MINIMAL, RPD:1500)│
                                                         │ 2  gemini-3.7-flash       (LOW, RPD: 500)    │
                                                         │ 3  gemini-3.8-flash       (LOW, RPD: 500)    │
                                                         │ 4  gemma-4-31b-it         (RPD: 14400)       │
                                                         │ 5  groq/openai/gpt-oss-120b (~0.6s, RPD:1000)│
                                                         │ 6  cerebras/gpt-oss-120b    (~0.15s, RPD:2400│
                                                         │ 7  cerebras/qwen-3.8-27b    (~0.15s, 648000) │
                                                         │ 8  cloudflare/llama-3.3-70b-fp8-fast (1000)  │
                                                         │ 9  openrouter/nemotron-3-super-120b:free(200)│
                                                         │ 10 anthropic/claude-haiku-4-5 ($5 bezpiecznik│
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
     - `'reasoning' => ['effort' => 'none']` dla modelu `nvidia/nemotron-3-super-120b-a12b:free` na OpenRouterze (`reasoning_tokens = 0`),
     - domyślnie wyłączone *Extended Thinking* oraz włączony *Prompt Caching* (`cache_control: ephemeral`, `-90%` kosztu wejścia) dla `anthropic/claude-haiku-4-5`.
   - Dodatkowo strażnik `finishReason === 'MAX_TOKENS'` (`length` / `max_tokens`) bezwzględnie odrzuca każdą uciętą odpowiedź i przełącza na kolejny model.
2. **Smart Fast-Fail do Groq LPU (`~0.6 s`) i Cerebras WSE (`~0.15 s`):**
   - Timeout pojedynczej próby Gemini wynosi **`4 s`** (`CURLOPT_CONNECTTIMEOUT = 2 s`).
   - Jeśli pierwszy model Gemini przekroczy timeout sieciowy LUB suma błędów i modeli pominiętych przez cooldown wyniesie $\ge 2$ (`$geminiTransientFailures + $geminiSkipped >= 2`), router **przerywa pętlę Google i w `0 ms` przeskakuje do `groq/openai/gpt-oss-120b` oraz `cerebras/gpt-oss-120b`**, które odpowiadają w `~0.15–0.8 s`.

## 3. Aktywni dostawcy i modele na VPS (6 kluczy API / 11 modeli)

| Provider | Modele w kaskadzie | Stan na VPS |
|---|---|---|
| Google AI Studio (`GEMINI_API_KEY`) | 5 (`gemini-3.5-flash`, `gemini-3.5-flash-lite`, `gemini-3.7-flash`, `gemini-3.8-flash`, `gemma-4-31b-it`) | **AKTYWNY** (`ai_router_provider_configured{provider="gemini"} 1`) |
| Groq Cloud (`GROQ_API_KEY`) | 1 (`openai/gpt-oss-120b`) | **AKTYWNY** (`ai_router_provider_configured{provider="groq"} 1`) |
| Cerebras WSE (`CEREBRAS_API_KEY`) | 2 (`gpt-oss-120b`, `qwen-3.8-27b`) | **AKTYWNY** (`ai_router_provider_configured{provider="cerebras"} 1`) |
| Cloudflare Workers AI (`CF_AI_API_TOKEN`) | 1 (`@cf/meta/llama-3.3-70b-instruct-fp8-fast`) | **AKTYWNY** (`ai_router_provider_configured{provider="cloudflare"} 1`) |
| OpenRouter (`OPENROUTER_API_KEY`) | 1 (`nvidia/nemotron-3-super-120b-a12b:free` — wyłącznie modele `:free`) | **AKTYWNY** (`ai_router_provider_configured{provider="openrouter"} 1`) |
| Anthropic Claude (`ANTHROPIC_API_KEY`) | 1 (`claude-haiku-4-5` — ostatni bezpiecznik Pre-paid $5 z Prompt Cachingiem) | **AKTYWNY** (`ai_router_provider_configured{provider="anthropic"} 1`) |

**Łącznie działa 11 niezależnych modeli u 6 dostawców chmurowych.** Nawet całkowita awaria wszystkich 10 darmowych modeli powoduje automatyczne przełączenie na ostatni bezpiecznik `anthropic/claude-haiku-4-5`.

## 4. Limity darmowe RPD, Cache RAG i Detektor „Gorącego Leada”

1. **Domyślne limity dzienne (RPD Free Tier + bezpiecznik Pre-paid) wbudowane w `ai-stats.php`:**
   - `gemini-3.5-flash-lite`: `1 500` zapytań/doba
   - `gemini-3.8-flash`, `gemini-3.7-flash`, `gemini-3.5-flash`: po `500` zapytań/doba
   - `gemma-4-31b-it`: `14 400` zapytań/doba
   - `groq/openai/gpt-oss-120b`: `1 000` zapytań/doba
   - `cerebras/gpt-oss-120b`: `2 400` zapytań/doba (`1 000 000` tokenów/doba)
   - `cerebras/qwen-3.8-27b`: `648 000` zapytań/doba (`450` RPM, `216 000 000` tokenów/doba)
   - `cloudflare/@cf/meta/llama-3.3-70b-instruct-fp8-fast`: `1 000` zapytań/doba (`10 000` Neurons/doba)
   - `openrouter/nvidia/nemotron-3-super-120b-a12b:free`: `200` zapytań/doba
   - `anthropic/claude-haiku-4-5`: `1 000` zapytań/doba (bufor Pre-paid 5 USD z Prompt Cachingiem `-90%`)
   - Łączna dzienna pula wynosi **ponad 670 000 darmowych zapytań na dobę + bufor awaryjny Claude Haiku 4.5** (można ją nadpisać zmienną `MODEL_DAILY_LIMITS` w `.env`).
2. **Pamięć podręczna RAG (`/app/storage/cache`):**
   - Identyczne pytania (po rozmytej normalizacji interpunkcji, symboli, białych znaków i wielkości liter — `/[\p{P}\p{S}\s]+/u`) są zwracane z dysku w **`~1.8 ms`** (`"cached": true`), nie zużywając ani jednego zapytania z puli RPD.
   - Klucz SHA-256 uwzględnia `filemtime` pliku wiedzy `<site_id>-knowledge.txt`, `kb_version` oraz `dynamic_context` — każda aktualizacja bazy wiedzy natychmiast unieważnia stare wpisy cache.
3. **Detektor „Gorącego Leada” i Natychmiastowy Ekstraktor Namiarów Kontaktowych 1-Klik (Zero-PII na dysku):**
   - **Przechwycenie namiaru (`event=contact_lead_captured`):** Gdy klient wpisze na czacie numer telefonu lub adres e-mail, router automatycznie wyciąga i formatuje numer (`📞 TELEFON: +48 XXX XXX XXX`) oraz e-mail (`✉️ E-MAIL: ...`) z bieżącej wiadomości oraz wcześniejszych tur rozmowy.
   - **Priorytetowa ekspozycja na samej górze powiadomienia:** Wyekstrahowany telefon i e-mail trafiają bezpośrednio do nagłówka `Title:` oraz **dwóch pierwszych linii wiadomości Push w Ntfy.sh** (dzięki czemu właściciel nigdy nie musi szukać numeru w treści rozmowy), wraz z przyciskami akcji 1-Klik (`Zadzwoń` $\rightarrow$ `tel:+48...`, `Napisz e-mail` $\rightarrow$ `mailto:...`), historią wcześniejszych pytań klienta oraz opcjonalną wysyłką JSON do `LEAD_WEBHOOK_URL`.
   - **Gorący Lead (`event=hot_lead_detected`):** Gdy klient zadaje **4. pytanie w jednej sesji rozmowy** (`count($sanitizedHistory) === 6`), router wysyła sygnał o zaangażowanym kliencie na stronie.
   - **Telemetria konwersji Zero-PII:** Licznik `ai_router_leads_total{site="...",type="contact|hot_lead"}` zlicza pozyskane leady per strona bez zapisywania jakichkolwiek danych osobowych na dysku.

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
| **Grafana** → *AI Router – Gemini Proxy Monitor* | Wykresy: kto odpowiada (modele + Cache RAG `<5ms`), błędy wg przyczyny, zawieszenia, paski dziennego limitu RPD, czasy odpowiedzi, ruch i leady per strona | `scripts\open-dashboard.cmd` |
| **Grafana** → *Analityka Ruchu WWW & SEO (Cookieless)* | Unikalni odwiedzający dziś, odsłony podstron, źródła wejść (Google, Bezpośrednie, FB, IG), urządzenia (Smartfon vs Komputer), kraje GeoIP z flagami, wyszukiwane hasła | `scripts\open-dashboard.cmd` |
| **Raport CLI** | Pełny raport tekstowy (zasoby, providerzy, kaskada, statystyki cache RAG, pozyskane leady `ai_router_leads_total`, próby modeli, logi) | `.\scripts\ai-router-report.ps1` albo na VPS `scripts/ai-router-report.sh` |
| **Dozzle** | Logi na żywo (strukturalne JSON: `attempt`, `request`, `skip_cooldown`, `security_attack_blocked`, `contact_lead_captured`, `hot_lead_detected`) | `open-dashboard.cmd` → Dozzle → `ai-router` |
| **Prometheus + Strażnik 24/7 (`devops-audit.timer`)** | 18 reguł alertów (`config/prometheus/rules/ai-router.yml`) sprawdzanych co 15 min przez `audit-server.sh` + poranny przegląd 08:00 **Claude Sonnet 4.6 Deep X-Ray** do **Ntfy.sh** | `npm run audit` |
| **Uptime Kuma** | Dostępność `http://ai-router:8080/health` (z automatycznym odświeżaniem cache DNS `nscd -i hosts` po wdrożeniu) | `open-dashboard.cmd` → Uptime Kuma |

### Reguły Alertów Prometheusa (`config/prometheus/rules/ai-router.yml`)

| Alert | Warunek | Poziom |
|---|---|---|
| `AIRouterDown` | brak scrape `ai-router:8080` przez 2 min | critical |
| `AIRouterAllModelsFailed` | ≥1 zapytanie HTTP 502 (wszystkie 11 modeli zawiodły) w 10 min | critical |
| `AIRouterPrimaryModelSuspended` | model pozycji 0 zawieszony >5 min | warning |
| `AIRouterModelQuotaNearLimit` | >80 % dziennego limitu RPD | warning |
| `AIRouterRateLimitSpike` | >20 blokad 429 / 10 min | warning |
| `AIRouterSecurityAttackDetected` | ≥3 zablokowane ataki WAF (Prompt Injection / XSS / SQLi / LFI) w 10 min | warning |
| `AIRouterModelDeprecated` | ≥1 błąd HTTP 404 (`not_found`) modelu w kaskadzie | warning |
| `AIRouterFallbackInUse` | odpowiedzi z pozycji >0 w 15 min | info |
| `AIRouterNoFallbackProvider` | brak skonfigurowanego Groq i OpenRouter >1 h | info |
| `WebsiteOrServiceDown` | `monitor_status == 0` w Uptime Kuma przez 2 min | critical |
| `SSLCertificateExpiringSoon` | `monitor_cert_days_remaining < 14` | warning |
| `VPSHostDiskSpaceLow` | <20 % wolnego miejsca na `/` przez 5 min | warning |
| `VPSHostMemoryLow` | <15 % dostępnej pamięci RAM na hoście przez 5 min | warning |
| `VPSBackupFailedOrStale` | błąd backupu wolumenów, błąd `tar -tzf` / `PRAGMA quick_check` / Restore Drill lub brak backupu >26 h | warning |
| `WebsitesBackupFailedOrStale` | błąd backupu stron LH.pl, błąd `tar -tzf` / `mysqldump` lub brak backupu >26 h | warning |
| `CloudflareTunnelDown` | brak telemetrii `cloudflared:2000` przez 2 min | critical |
| `VPSFail2BanAttackSpike` | ≥5 zbanowanych IP przez Fail2Ban w ciągu 15 min | warning |
| `VPSSecurityBreachIoCDetected` | wykrycie śladów kompromitacji IoC (`devops_security_ioc_clean == 0`) | critical |



