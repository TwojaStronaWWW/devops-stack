# Poradnik Stagingu & Testowania Stron via Cloudflare Tunnel (Zero Trust)

> **Cel**: Całkowita rezygnacja z podatnych na wycieki i zbędnych subdomen publicznych (`test.nazwastrony.pl`) oraz brak konieczności otwierania jakichkolwiek portów na zaporze serwera VPS.

---

## 1. Dwa Modele Testowania Przed Wdrożeniem

### Model A: Ephemeral Quick Tunnels (`trycloudflare.com`) - Testy Ad-Hoc
Najszybsza metoda do testowania gałęzi (PR), poprawek frontendowych lub sprawdzania responsywności na smartfonie.

- **Jak to działa?**
  1. Uruchamiasz kontener ze swoją stroną (np. `gal-anonim-web`) w sieci `devops_internal_network` lub na `localhost:3000`.
  2. Wykonujesz polecenie:
     ```bash
     # W Linuksie / WSL2:
     ./scripts/preview-tunnel.sh http://localhost:3000

     # W Windows / PowerShell:
     pwsh scripts/preview-tunnel.ps1 -Target "http://localhost:3000"
     ```
  3. Cloudflare generuje losowy, w pełni bezpieczny link HTTPS:
     ```text
     https://subtle-ocean-preview.trycloudflare.com
     ```
  4. Link jest aktywny tak długo, jak trwa sesja w terminalu. Po naciśnięciu `Ctrl+C` tunel znika, a link natychmiast przestaje działać.
- **Zalety**:
  - **Zero rekordów DNS**: nie musisz nic dodawać w strefie DNS ani czekać na propagację.
  - **Możesz bezpiecznie skasować subdomeny `test.*` ze swojego panelu DNS**.

---

### Model B: Named Tunnels + Cloudflare Zero Trust Access - Stały Staging
Metoda dla stałego środowiska stagingowego przed produkcją.

- **Jak to działa?**
  1. W pliku `compose/extensions.yml` uruchomiony jest kontener `cloudflared` spięty z Twoim kontem Cloudflare Zero Trust.
  2. W panelu Cloudflare (**Zero Trust Dashboard** -> **Networks** -> **Tunnels** -> Twój tunel -> **Public Hostnames**):
     - Hostname: `staging.twojadomena.pl`
     - Service: `HTTP` -> `gal-anonim-web:3000` (nazwa usługi w sieci wewnętrznej Dockera!).
  3. W panelu Cloudflare (**Access** -> **Applications**):
     - Dodajesz aplikację dla `staging.twojadomena.pl`.
     - Ustawiasz politykę: dostęp tylko dla Twojego adresu e-mail (kod PIN jednorazowy wysyłany na pocztę) lub logowanie przez GitHub / Google.
- **Zalety**:
  - Żaden bot, robot indeksujący Google ani intruz nie zobaczy niedokończonej strony.
  - Na serwerze VPS porty 80/443 pozostają całkowicie zamknięte w UFW.
