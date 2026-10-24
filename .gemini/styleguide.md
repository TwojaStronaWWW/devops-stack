# Wytyczne Code Review dla Google Gemini Code Assist & Google Jules (TwojaStronaWWW)

1. **Język recenzji:** Zawsze pisz podsumowania Pull Requestów oraz komentarze do kodu w języku **POLSKIM**.
2. **Brak szumu (Zero Noise):** Zgłaszaj wyłącznie realne błędy wykonawcze, luki bezpieczeństwa (ISO 27001 / OWASP), naruszenia zasady Separation of Concerns (SoC) lub rozjazdy dokumentacji z kodem.
3. **Standardy nadrzędne (`AGENTS.md` / `GEMINI.md` / `docs/WEB_STANDARDS_RADAR.md`):**
   - **SoC:** Zakaz stylów inline `style="..."` oraz atrybutów `onclick="..."` w plikach HTML.
   - **Bezpieczeństwo PHP i I/O:** Wszelkie modyfikacje plików JSON/CSV wymagają atomowej blokady wyłącznej `flock($fp, LOCK_EX)` przez cały cykl Read-Modify-Write, wczesnego zwalniania sesji `@session_write_close()`, weryfikacji nagłówka `Sec-Fetch-Site` (`cross-site` -> 403) oraz wyłączenia przekierowań w cURL (`CURLOPT_FOLLOWLOCATION => false`).
   - **Zegary i walidacja typów:** Pomiar czasu trwania interakcji musi opierać się o zegar monotoniczny (`performance.now()` / `getMonotonicMs()`), a walidatory liczbowe muszą odrzucać `boolean`, `NaN` oraz `±Infinity` (`isStrictFiniteNumber`).
   - **Testy jednostkowe (`node:test`):** Domyślny `fetch` w `setupMockDom()` blokuje ruch sieciowy (`NETWORK_FORBIDDEN`) — każdy test wymagający sieci musi jawnie zamockować `fetch`.
   - **SEO & AI Search:** Plik `/.well-known/security.txt` musi posiadać aktywną datę `Expires:`, kontener `#tsw-ai-widget-root` musi posiadać `data-nosnippet`, a `/llms.txt` musi być spójny z bazą wiedzy RAG.
