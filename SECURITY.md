# Polityka Bezpieczeństwa (Security Policy) – TwojaStronaWWW VPS Infrastructure

## 1. Zakres i Rygor (ISO 27001)
Bezpieczeństwo infrastruktury serwerowej oraz ciągłość działania usług monitoringu i CI/CD są dla nas kwestią priorytetową. Zgodnie z wytycznymi ISO 27001 oraz zasadą Principle of Least Privilege (PoLP) stosujemy rygorystyczne procedury utwardzania systemu (OS Hardening), ochrony tożsamości, izolacji sieciowej i bezpiecznego zarządzania sekretami.

## 2. Podstawowe Zasady Architektury Bezpieczeństwa
- **Zero Trust Network:** Brak otwartych portów publicznych w sieci WAN dla usług wewnętrznych (Grafana, Uptime Kuma, Dozzle). Dostęp wyłącznie przez tunel Cloudflare Zero Trust.
- **Dostęp SSH:** Wyłącznie klucze kryptograficzne Ed25519, blokada logowania hasłem, rate limiting UFW (`limit 22/tcp`) oraz ochrona Fail2ban.
- **Zero Secret Leakage:** Bezwzględny zakaz commitowania kluczy prywatnych (`.pem`, `.key`, `id_ed25519*`), certyfikatów oraz plików `.env`.
- **Kopie Zapasowe:** Szyfrowane symetrycznie archiwami `tar.gz` i przesyłane do Cloudflare R2 (`backup-offsite.sh`).

## 3. Odpowiedzialne Ujawnianie Podatności (Responsible Disclosure)
Jeżeli odkryłeś potencjalną lukę bezpieczeństwa w konfiguracji, kontenerach lub skryptach infrastruktury, prosimy o natychmiastowe zgłoszenie tego faktu bezpośrednio do zespołu technicznego TwojaStronaWWW.

- **Zakaz publicznego ujawniania:** Prosimy o **niepublikowanie** informacji o lukach w publicznych issue GitHub, forach ani mediach społecznościowych przed ich mitygacją.
- **Kontakt ds. bezpieczeństwa:** `kontakt@twojastronawww.pl` (lub bezpośrednio do administratora projektu).
- **Czas reakcji:** Zgłoszenia dotyczące bezpieczeństwa są analizowane priorytetowo (do 24-48 godzin roboczych).

## 4. Zgłoszenie powinno zawierać:
1. Dokładny opis podatności i jej potencjalnego wpływu na infrastrukturę.
2. Kroki niezbędne do odtworzenia problemu (Proof of Concept).
3. Środowisko i wersję kontenera/systemu.
