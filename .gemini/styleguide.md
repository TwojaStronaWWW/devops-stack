# Wytyczne Code Review dla Google Gemini Code Assist & Google Jules (TwojaStronaWWW)

1. **Język recenzji:** Zawsze pisz podsumowania Pull Requestów oraz komentarze do kodu w języku **POLSKIM**.
2. **Brak szumu (Zero Noise):** Zgłaszaj wyłącznie realne błędy wykonawcze, luki bezpieczeństwa (ISO 27001 / OWASP), naruszenia zasady Separation of Concerns (SoC) lub rozjazdy dokumentacji z kodem.
3. **Standardy nadrzędne (`AGENTS.md` / `GEMINI.md` / `docs/WEB_STANDARDS_RADAR.md`):**
   - **SoC:** Zakaz stylów inline `style="..."` oraz atrybutów `onclick="..."` w plikach HTML.
   - **Bezpieczeństwo PHP i I/O:** Wszelkie modyfikacje plików JSON/CSV wymagają atomowej blokady wyłącznej `flock($fp, LOCK_EX)` przez cały cykl Read-Modify-Write, wczesnego zwalniania sesji `@session_write_close()`, weryfikacji nagłówka `Sec-Fetch-Site` (`cross-site` -> 403) oraz wyłączenia przekierowań w cURL (`CURLOPT_FOLLOWLOCATION => false`).
   - **Zegary i walidacja typów:** Pomiar czasu trwania interakcji musi opierać się o zegar monotoniczny (`performance.now()` / `getMonotonicMs()`), a walidatory liczbowe muszą odrzucać `boolean`, `NaN` oraz `±Infinity` (`isStrictFiniteNumber`).
   - **Testy jednostkowe (`node:test`):** Domyślny `fetch` w `setupMockDom()` blokuje ruch sieciowy (`NETWORK_FORBIDDEN`) — każdy test wymagający sieci musi jawnie zamockować `fetch`.
   - **SEO & AI Search:** Plik `/.well-known/security.txt` musi posiadać aktywną datę `Expires:`, kontener `#tsw-ai-widget-root` musi posiadać `data-nosnippet`, a `/llms.txt` musi być spójny z bazą wiedzy RAG.
4. **Wykluczenia fałszywych alarmów dla Google Jules Suggestions (`services/ai-router`):**
   - **Sekwencyjna kaskada LLM (`llm-cascade.php`):** Wywołania HTTP do kolejnych dostawców LLM w `aiRunModelCascade()` są **celowo sekwencyjne (wzorzec Failover)** — kolejny model zapasowy jest odpytywany wyłącznie po błędzie poprzedniego, aby nie zużywać dziennych limitów Free Tier (RPD/TPM). Nie zgłaszaj sugestii zrównoleglania zapytań w kaskadzie.
   - **Powiadomienia po zamknięciu odpowiedzi (`lead-notifier.php`):** Funkcja `aiDispatchLeadNotifications()` (w tym pętla retry cURL + `usleep` dla Ntfy.sh) wykonuje się **po** `fastcgi_finish_request()` i `Connection: close`, więc nie blokuje czasu odpowiedzi dla klienta.
   - **Lokalny plikowy Cache RAG i probabilistyczny GC (`chat-router.php`):** Odczyt plików cache JSON z dysku oraz losowy Garbage Collector (`mt_rand(1, 50) === 1`) są celowym wzorcem **Zero-Bloat** eliminującym konieczność utrzymywania osobnego serwera Redis.
