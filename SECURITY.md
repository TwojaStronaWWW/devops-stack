# Polityka Bezpieczeństwa (Security Policy) – TwojaStronaWWW VPS Infrastructure

## 1. Zakres i Rygor (ISO 27001)
Bezpieczeństwo infrastruktury serwerowej oraz ciągłość działania usług monitoringu i CI/CD są dla nas kwestią priorytetową. Zgodnie z wytycznymi ISO 27001 oraz zasadą Principle of Least Privilege (PoLP) stosujemy rygorystyczne procedury utwardzania systemu (OS Hardening), ochrony tożsamości, izolacji sieciowej i bezpiecznego zarządzania sekretami.

## 2. Podstawowe Zasady Architektury Bezpieczeństwa
- **Zero Trust Network & Segmentacja Sieci:** Brak otwartych portów publicznych w sieci WAN dla usług wewnętrznych (Grafana, Uptime Kuma, Dozzle, Prometheus). Dostęp zewnętrzny wyłącznie przez szyfrowany tunel Cloudflare Zero Trust, natomiast kontenery runnerów CI/CD działają w odseparowanej sieci `devops_runners_network` bez dostępu L3 do sieci `devops_internal_network`.
- **Principle of Least Privilege (PoLP):** Dostęp lokalny do Grafany działa domyślnie w roli tylko do odczytu (`Viewer`), Uptime Kuma wymusza uwierzytelnianie (`DISABLE_AUTH=false`), a kontenery działają na nieuprzywilejowanych użytkownikach (`nobody`, `grafana`) z flagą `no-new-privileges:true`.
- **Dostęp SSH & IPS Fail2ban:** Wyłącznie klucze kryptograficzne Ed25519, blokada logowania hasłem (`PasswordAuthentication no`), rate limiting UFW (`limit 22/tcp`) oraz progresywny ban Fail2ban (`1h -> 7d` po 3 błędach, metryka `devops_fail2ban_banned_total`).
- **WAF Warstwy 7 + 15-Minutowy IP Penalty Box:** Bramka `ai-router` blokuje próby Prompt Injection, Jailbreak, XSS, SQLi i Path Traversal kodem `HTTP 403` przed wywołaniem modelu LLM i nakłada 15-minutową blokadę na IP agresora (`outcome="security_blocked"`).
- **Zero Secret Leakage & Zero-PII (Cookieless RODO):** Bezwzględny zakaz commitowania kluczy prywatnych (`.pem`, `.key`, `id_ed25519*`), certyfikatów oraz plików `.env` i `.env.bak*`. Telemetria AI Routera oraz bezciasteczkowej analityki WWW (`ai-stats.php`) nie przetwarza ani nie loguje treści pytań ani adresów IP.
- **Kopie Zapasowe, Nocny Restore Drill i Kryminalistyczny Audyt 24/7 (IoC):** Archiwa wolumenów i stron WWW (FTPS TLS + `mysqldump`) są weryfikowane pod kątem integralności (`tar -tzf` + `PRAGMA quick_check`), szyfrowane AES-256-CBC i przesyłane do Cloudflare R2 (retencja 30 dni lokalnie / 14 dni w R2) wraz z automatycznym nocnym testem odtworzeniowym (`restore-backup.sh --verify-only`). Harmonogram `devops-audit.timer` co 15 minut weryfikuje 5 warstw bezpieczeństwa oraz wskaźniki kompromitacji IoC (`devops_security_ioc_clean`), a o 08:00 rano uruchamia głęboki audyt AI **Claude Sonnet 4.6 Deep X-Ray**.

## 3. Odpowiedzialne Ujawnianie Podatności (Responsible Disclosure)
Jeżeli odkryłeś potencjalną lukę bezpieczeństwa w konfiguracji, kontenerach lub skryptach infrastruktury, prosimy o natychmiastowe zgłoszenie tego faktu bezpośrednio do zespołu technicznego TwojaStronaWWW.

- **Zakaz publicznego ujawniania:** Prosimy o **niepublikowanie** informacji o lukach w publicznych issue GitHub, forach ani mediach społecznościowych przed ich mitygacją.
- **Kontakt ds. bezpieczeństwa:** `kontakt@twojastronawww.pl` (lub bezpośrednio do administratora projektu).
- **Czas reakcji:** Zgłoszenia dotyczące bezpieczeństwa są analizowane priorytetowo (do 24-48 godzin roboczych).

## 4. Zgłoszenie powinno zawierać:
1. Dokładny opis podatności i jej potencjalnego wpływu na infrastrukturę.
2. Kroki niezbędne do odtworzenia problemu (Proof of Concept).
3. Środowisko i wersję kontenera/systemu.
