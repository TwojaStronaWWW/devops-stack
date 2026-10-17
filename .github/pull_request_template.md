## 📝 Opis zmian infrastrukturalnych

<!-- Zwięzły opis tego, co wprowadza niniejszy Pull Request w konfiguracji VPS lub stacku Docker -->

## 🔗 Powiązane zgłoszenia (Issues)

Fixes #
Closes #

## 🏷️ Rodzaj zmiany

- [ ] 🐛 Naprawa konfiguracji / błędu kontenera (Bug fix)
- [ ] ✨ Nowa usługa / kontener w stacku (Feature)
- [ ] ⚡ Optymalizacja zasobów / wydajność OCI (Performance)
- [ ] ♻️ Refaktoryzacja skryptów lub compose (Refactoring)
- [ ] 📝 Dokumentacja / Runbook / Disaster Recovery (Documentation)
- [ ] 🚀 Potok CI/CD / GitHub Actions Runner (CI/CD)
- [ ] 🛡️ Hardening / Bezpieczeństwo ISO 27001 (Security)

## 🛡️ Checklista jakościowa (DevOps Quality Gate)

- [ ] Walidacja składni Docker Compose (`docker compose config`) dla `docker-compose.yml`, `runners.yml` i `extensions.yml`
- [ ] Testy higieny i regresji bezpieczeństwa OWASP / ISO 27001 (`npm run check` — 37/37 PASS)
- [ ] Weryfikacja twardych limitów Oracle Always Free (max 4 OCPU, 24 GB RAM, 200 GB Storage — 0.00 PLN)
- [ ] Brak wystawiania portów na `0.0.0.0` (wyłącznie `127.0.0.1` + szyfrowany tunel Cloudflare Zero Trust `cloudflared:2000`)
- [ ] Dwustrefowa izolacja sieciowa (`devops_internal_network` odseparowana od `devops_runners_network`)
- [ ] Brak commitowania sekretów, kluczy prywatnych (`.pem`, `.key`, `id_ed25519*`), metryk (`*.prom`) ani `.env` / `.env.bak*`
- [ ] Zgodność z zarządzaniem sekretami (KeePass-First): 6 kluczy AI i poświadczenia zaktualizowane w `Databasekpoczatek.kdbx` oraz GitHub Secrets
- [ ] Weryfikacja kopii zapasowych i DR: `backup-offsite.sh` (`PRAGMA quick_check` + `tar -tzf`), `backup-websites-lh.sh` (`FTPS TLS` + `mysqldump`), `restore-backup.sh --verify-only` oraz timery `devops-backup.timer` / `devops-audit.timer`
- [ ] Spójność kontraktu z szablonem stron `_site-template` (`ai-widget.js` ↔ `chat-router.php`: 11 modeli, Cache RAG `< 5 ms`, ekstrakcja leadów `📞 TELEFON` / `✉️ E-MAIL` 1-Klik i Zero-PII)
- [ ] Sprawdzono składnię skryptów powłoki (`bash -n scripts/*.sh`) oraz PHP (`php -l`)
- [ ] Zgodność z ISO 27001 / PoLP (usługi działające jako non-root, `no-new-privileges:true`, limity pamięci RAM)

