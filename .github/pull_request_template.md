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

- [ ] Walidacja składni Docker Compose (`docker compose config`)
- [ ] Testy higieny i bezpieczeństwa repozytorium (`npm run check`)
- [ ] Weryfikacja twardych limitów Oracle Always Free (max 4 OCPU, 24 GB RAM, 200 GB Storage)
- [ ] Brak wystawiania portów do WAN bez tunelu Cloudflare Zero Trust (UFW ports clean)
- [ ] Brak commitowania sekretów, kluczy prywatnych (`.pem`, `.key`, `id_ed25519*`), metryk (`*.prom`) ani `.env`
- [ ] Zgodność z zarządzaniem sekretami: poświadczenia zaktualizowane w sejfie KeePass oraz GitHub Secrets
- [ ] Weryfikacja procedury kopii zapasowych: wolumeny Dockera oraz hosting LH.pl objęte backupem i telemetrią w Grafanie
- [ ] Sprawdzono składnię skryptów powłoki (`bash -n scripts/*.sh`)
- [ ] Zgodność z ISO 27001 / PoLP (usługi działające jako non-root, dedykowane sieci dockerowe)
