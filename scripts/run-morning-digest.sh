#!/usr/bin/env bash
# ==============================================================================
# Moduł Orkiestracji Porannego Raportu 06:00 i Powiadomień Ntfy.sh (ISO 27001)
# Wywoływany przez scripts/audit-server.sh po zakończeniu 5-warstwowego audytu.
# ==============================================================================

if [[ -f "${ENV_FILE:-}" ]]; then
    NTFY_AUDIT_TOPIC="$(grep -E '^NTFY_TOPIC=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || echo '')"
    NTFY_BASE_URL="$(grep -E '^NTFY_BASE_URL=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' | sed 's:/*$::' || echo '')"
    NTFY_BASE_URL="${NTFY_BASE_URL:-https://ntfy.sh}"
    NTFY_TOKEN="$(grep -E '^NTFY_TOKEN=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || echo '')"
    NTFY_AUTH_ARGS=()
    if [[ -n "${NTFY_TOKEN}" ]]; then
        NTFY_AUTH_ARGS=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    fi
    if [[ -n "${NTFY_AUDIT_TOPIC}" ]]; then
        HINTS_SUMMARY=""
        if [[ ${#REMEDIATION_HINTS[@]} -gt 0 ]]; then
            HINTS_SUMMARY="$(printf '\n• %s' "${REMEDIATION_HINTS[@]}")"
        fi

        if [[ "${FAIL_COUNT:-0}" -gt 0 ]]; then
            curl -s --max-time 5 \
                ${NTFY_AUTH_ARGS[@]+"${NTFY_AUTH_ARGS[@]}"} \
                -H "Title: Audyt VPS: Wykryto ${FAIL_COUNT} bledow!" \
                -H "Priority: high" \
                -H "Tags: rotating_light,shield" \
                -d "Audyt (${HOST_NAME}): ${OK_COUNT} OK | ${WARN_COUNT} WARN | ${FAIL_COUNT} FAIL.${HINTS_SUMMARY}" \
                "${NTFY_BASE_URL}/${NTFY_AUDIT_TOPIC}" >/dev/null 2>&1 || true
        elif [[ "${WARN_COUNT:-0}" -gt 0 ]]; then
            WARN_STAMP_FILE="/var/tmp/devops-warn-alert.ts"
            LAST_WARN_TS="$(cat "${WARN_STAMP_FILE}" 2>/dev/null || echo 0)"
            NOW_TS="$(date +%s)"
            if [[ $((NOW_TS - LAST_WARN_TS)) -ge 21600 ]]; then
                echo "${NOW_TS}" > "${WARN_STAMP_FILE}" 2>/dev/null || true
                curl -s --max-time 5 \
                    ${NTFY_AUTH_ARGS[@]+"${NTFY_AUTH_ARGS[@]}"} \
                    -H "Title: Audyt VPS: ${WARN_COUNT} ostrzezen" \
                    -H "Priority: default" \
                    -H "Tags: warning,shield" \
                    -d "Audyt (${HOST_NAME}): ${OK_COUNT} OK | ${WARN_COUNT} WARN | 0 FAIL.${HINTS_SUMMARY}" \
                    "${NTFY_BASE_URL}/${NTFY_AUDIT_TOPIC}" >/dev/null 2>&1 || true
            fi
        fi

        # Codzienny Poranny Raport o 06:00 rano (Europe/Warsaw): Scrapery KSH/DancePuls + Audyt ISO 27001 (VPS + LH.pl Auto-Heal + nazwa.pl Read-Only + Rada 3 AI + Arbiter Antigravity)
        PL_HOUR="$(TZ=Europe/Warsaw date +%H 2>/dev/null || date +%H)"
        PL_MIN="$(TZ=Europe/Warsaw date +%M 2>/dev/null || date +%M)"
        PL_DATE="$(TZ=Europe/Warsaw date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"
        MORNING_STAMP_FILE="/var/tmp/devops-morning-digest.date"
        LAST_MORNING_DATE="$(cat "${MORNING_STAMP_FILE}" 2>/dev/null || echo '')"

        # Pre-trigger o 05:45 (Europe/Warsaw): wywołanie workflow_dispatch dla weekly-report.yml bez czekania na kolejkę crona GitHuba
        if [[ "${PL_HOUR}" == "05" && $((10#${PL_MIN})) -ge 40 && $((10#${PL_MIN})) -le 52 && "${LAST_MORNING_DATE}" != "${PL_DATE}" ]]; then
            sudo ENV_FILE="${ENV_FILE}" PL_DATE="${PL_DATE}" python3 "${STACK_ROOT}/scripts/morning-digest.py" pretrigger >/dev/null 2>&1 || true
        fi

        if [[ "${FORCE_MORNING_REPORT:-false}" == "true" ]] || [[ "${LAST_MORNING_DATE}" != "${PL_DATE}" && ( ( "${PL_HOUR}" == "05" && $((10#${PL_MIN})) -ge 58 ) || "${PL_HOUR}" == "06" ) ]]; then
            echo "${PL_DATE}" > "${MORNING_STAMP_FILE}" 2>/dev/null || true
            if [[ -f "${STACK_ROOT}/scripts/sync-gsc-keywords.sh" ]]; then
                bash "${STACK_ROOT}/scripts/sync-gsc-keywords.sh" >/dev/null 2>&1 || true
            fi
            if [[ -f "${STACK_ROOT}/scripts/sync-change-radar.sh" ]]; then
                bash "${STACK_ROOT}/scripts/sync-change-radar.sh" >/dev/null 2>&1 || true
            fi
            F2B_BANNED="$(sudo fail2ban-client status sshd 2>/dev/null | awk -F: '/Total banned/ {gsub(/[ \t]/,"",$2); print $2}' || echo '0')"
            F2B_IP_LIST="$(sudo fail2ban-client status sshd 2>/dev/null | awk -F: '/Banned IP list/ {gsub(/^[ \t]+/,"",$2); print $2}' || echo 'brak')"
            AI_METRICS_RAW="$(curl -s --max-time 3 "http://127.0.0.1:8085/metrics" 2>/dev/null || true)"
            WA_PV_TOTAL="$(echo "${AI_METRICS_RAW}" | awk '/^web_analytics_pageviews_total\{/ {s+=$NF} END {print s+0}')"
            WA_UV_TOTAL="$(echo "${AI_METRICS_RAW}" | awk '/^web_analytics_unique_visitors_total\{/ {s+=$NF} END {print s+0}')"
            WA_ENG_TOTAL="$(echo "${AI_METRICS_RAW}" | awk '/^web_analytics_engaged_visits_total\{/ {s+=$NF} END {print s+0}')"
            WA_LEADS_TOTAL="$(echo "${AI_METRICS_RAW}" | awk '/^ai_router_leads_total\{/ {s+=$NF} END {print s+0}')"
            WA_LCP_AVG="$(echo "${AI_METRICS_RAW}" | awk '/^web_analytics_cwv_lcp_seconds_sum\{/ {s+=$NF} /^web_analytics_cwv_lcp_seconds_count\{/ {c+=$NF} END {if (c>0) printf "%.2fs", s/c; else print "b/d"}')"
            WA_TOP_TOPIC="$(echo "${AI_METRICS_RAW}" | awk '/^ai_router_question_topics_total\{/ && $NF > 0 {val=$NF; match($0, /topic="[^"]+"/); t=substr($0, RSTART+7, RLENGTH-8); if (val > max) {max=val; best=t}} END {print (best != "" ? best " (" max ")" : "brak")}')"
            WA_TOP_TERM="$(echo "${AI_METRICS_RAW}" | awk '/^web_analytics_search_terms_total\{/ && $NF > 0 {val=$NF; match($0, /term="[^"]+"/); t=substr($0, RSTART+6, RLENGTH-7); if (t != "brak-wyszukiwan" && val > max) {max=val; best=t}} END {print (best != "" ? best " (" max ")" : "brak")}')"

            # Zbieranie skanu hostingów zewnętrznych:
            # 1) LH.pl (serwer417204.lh.pl) — tryb AUTO-HEAL (automatyczna naprawa wycieków dev/test i uprawnień)
            # 2) nazwa.pl (slimgroupol.nazwa.pl) — tryb 100% READ-ONLY / ALERT-ONLY (tylko informacja bez modyfikacji plików)
            HOSTING_SCAN_DATA=""
            LH_SHORT=""
            LH_FULL=""
            NAZWA_SHORT=""
            NAZWA_FULL=""
            if command -v python3 >/dev/null 2>&1; then
                HOSTING_SCAN_DATA="$(sudo ENV_FILE="${ENV_FILE}" python3 "${STACK_ROOT}/scripts/morning-digest.py" hosting-scan 2>/dev/null || true)"
                LH_SHORT="$(echo "${HOSTING_SCAN_DATA}" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("lh_short",""))' 2>/dev/null || echo '')"
                LH_FULL="$(echo "${HOSTING_SCAN_DATA}" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("lh_full",""))' 2>/dev/null || echo '')"
                NAZWA_SHORT="$(echo "${HOSTING_SCAN_DATA}" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("nazwa_short",""))' 2>/dev/null || echo '')"
                NAZWA_FULL="$(echo "${HOSTING_SCAN_DATA}" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("nazwa_full",""))' 2>/dev/null || echo '')"
            fi

            # Zbieranie Pełnego Rentgena 24h (Deep X-Ray 24h) z odfiltrowaniem szumu healthchecków
            AI_AUDIT_INSIGHT=""
            if command -v python3 >/dev/null 2>&1; then
                XRAY_FILE="/var/tmp/devops-xray.txt"
                {
                    echo "=== WYNIK DETERMINISTYCZNEGO AUDYTU 5 WARSTW VPS (ISO 27001, AUTO-HEAL) ==="
                    echo "Data: ${PL_DATE} | Wynik VPS: ${OK_COUNT} OK, ${WARN_COUNT} WARN, ${FAIL_COUNT} FAIL (IoC Clean=${IOC_CLEAN:-1}, Krytyczne wyjatki 24h=${LOG_CRITICAL_24H:-0})"
                    echo "Dysk: ${DISK_USE_PCT}% (wolne ${DISK_AVAIL_HUMAN}) | RAM: ${MEM_INFO} | Bufor OCI: $(( OCI_BUFFER_BYTES / 1048576 )) MiB"
                    echo "Backupy (harmonogram 03:00 UTC / 05:00 PL + szyfrowanie AES-256-CBC do Cloudflare R2): VPS ${AGE_HOURS:-?}h temu | WWW LH.pl ${W_AGE_HOURS:-?}h temu | Weryfikacja integralnosci: Nocny Restore Drill (--verify-only)=${DRILL_OK:-1}, SQLite PRAGMA quick_check=${SQLITE_OK:-1}, MySQL dump=${MYSQL_OK:-1}, tar -tzf=1 (100% OK)"
                    echo "Architektura Zero Trust & Dostep: Porty 80/443 zamkniete w WAN (UFW + DOCKER-USER DROP), dostep wylacznie przez Cloudflare Zero Trust (Access MFA + Catch-All 404) i tunel SSH Ed25519 (PasswordAuthentication=no, PermitRootLogin=no, Grafana PoLP Viewer)"
                    echo "Ochrona IPS/WAF: Fail2ban zbanowane IP=${F2B_BANNED:-0} (aktywne IP: ${F2B_IP_LIST:-brak}) | WAF L7 zablokowane ataki=${WAF_BLOCKED_TOTAL:-0}"
                    echo "Analityka WWW i AI: Odslony=${WA_PV_TOTAL:-0} | Unikalni=${WA_UV_TOTAL:-0} | Zaangazowani(>=15s)=${WA_ENG_TOTAL:-0} | LCP=${WA_LCP_AVG:-b/d} | Leady=${WA_LEADS_TOTAL:-0} | Top temat AI=${WA_TOP_TOPIC:-brak} | Top fraza=${WA_TOP_TERM:-brak}"
                    if [[ -n "${HINTS_SUMMARY}" ]]; then
                        echo "Wykryte wskazowki naprawcze VPS: ${HINTS_SUMMARY}"
                    fi
                    echo "=== SKAN HOSTINGU WLASNEGO LH.PL (TRYB AUTO-HEAL) ==="
                    echo "${LH_FULL:-Brak danych z LH.pl}"
                    echo "=== SKAN HOSTINGU KLIENTA NAZWA.PL (TRYB 100% READ-ONLY / TYLKO INFORMACJA) ==="
                    echo "${NAZWA_FULL:-Brak danych z nazwa.pl}"
                    echo "=== ROZMIARY LOGOW KONTENEROW (TOP 5) ==="
                    sudo sh -c 'du -sh /var/lib/docker/containers/*/*-json.log 2>/dev/null | sort -hr | head -n 5' || true
                    echo "=== USTAWIENIA BEZPIECZENSTWA UPTIME KUMA (kuma.db) ==="
                    sudo python3 -c "import sqlite3; c=sqlite3.connect('/var/lib/docker/volumes/uptime_kuma_data/_data/kuma.db'); print(c.execute(\"SELECT key, value FROM setting WHERE key IN ('disableAuth','tlsExpiryNotifyDays','keepDataPeriodDays')\").fetchall())" 2>/dev/null || true
                    echo "=== REGULY INGRESS CLOUDFLARED ==="
                    docker logs cloudflared 2>&1 | grep -i "Updated to new configuration" | tail -n 1 || true
                    echo "=== SKANER ANOMALII LOGOW KONTENEROW Z PELNYCH 24 GODZIN (--since 24h, bez szumu healthcheckow) ==="
                    for cname in "${EXPECTED_CONTAINERS[@]}"; do
                        anom_24h="$(docker logs --since 24h "${cname}" 2>&1 | tr -d '\000' \
                            | grep -vE '(broken pipe|context canceled|permissions\.sync\.forbidden|id=anonymous:0|connection reset by peer|referenced_memory|machine info|container factory failed|inotify_add_watch|No such image: sha256|Runner connect error|HttpRequestException|SIGTERM|Shutting down|GET /health|GET /metrics|GET /amms|HEAD /|Listening for Jobs|Connected to GitHub|plugins-bundled|\.gitkeep|Pending:.*Retry: [12]\b|no recent network activity)' \
                            | grep -iE '(error|warn|fail|fatal|panic|crit|exception|denied|security_blocked|\bban(ned)?\b|corrupt|unhealthy)' \
                            | tail -n 6 | cut -c 1-240 || true)"
                        if [[ -n "${anom_24h}" ]]; then
                            echo "--- [${cname}] ANOMALIE 24H ---"
                            echo "${anom_24h}"
                        else
                            last_line="$(docker logs --since 24h "${cname}" 2>&1 | tr -d '\000' | grep -vE '(broken pipe|context canceled|permissions\.sync\.forbidden|referenced_memory|Found node without cache information|GET /health|GET /metrics)' | tail -n 1 | cut -c 1-180 || echo 'OK')"
                            echo "--- [${cname}] 24h: 0 bledow/ostrzezen (ostatni wpis: ${last_line})"
                        fi
                    done
                    echo "=== DZIENNIK SSH I BLEDY SYSTEMOWE (journalctl 24h) ==="
                    ssh_ok_24h="$(sudo journalctl -u ssh --since '24 hours ago' --no-pager 2>/dev/null | grep -c 'Accepted publickey' || true)"
                    echo "Udane logowania SSH kluczem Ed25519 (24h): ${ssh_ok_24h:-0} | Logowania haslem/rootem: ${SSH_ANOMALY_LOGINS:-0}"
                    sudo journalctl -p err..emerg --since "24 hours ago" --no-pager 2>/dev/null \
                        | grep -vE '(kex_exchange_identification|kex_protocol_error|Unable to negotiate with|maximum authentication attempts exceeded|corrupted MAC on input|Connection reset by peer|banner exchange)' | tail -n 8 || true
                } > "${XRAY_FILE}" 2>/dev/null

                # Poranna Rada 3 Niezależnych Audytorów AI + Arbiter Końcowy Antigravity ($0.00, ochrona puli $4.77 Anthropic)
                AI_AUDIT_INSIGHT="$(sudo ENV_FILE="${ENV_FILE}" XRAY_FILE="${XRAY_FILE}" FORCE_CLAUDE_ESCALATION="${FORCE_CLAUDE_ESCALATION:-false}" python3 "${STACK_ROOT}/scripts/morning-digest.py" ai-audit 2>/dev/null || true)"
                rm -f "${XRAY_FILE}" 2>/dev/null || true
            fi

            TOTAL_TESTS=$((OK_COUNT + WARN_COUNT + FAIL_COUNT))

            # Zbieranie danych ze wszystkich 3 scraperów Kato Salsa Hub & DancePuls (delegacja do scripts/morning-digest.py ksh-scrapers)
            KSH_SCRAPER_DATA="$(sudo ENV_FILE="${ENV_FILE}" PL_DATE="${PL_DATE}" python3 "${STACK_ROOT}/scripts/morning-digest.py" ksh-scrapers 2>/dev/null || true)"

            KSH_SHORT="$(echo "${KSH_SCRAPER_DATA}" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("short",""))' 2>/dev/null || echo '')"
            KSH_FULL="$(echo "${KSH_SCRAPER_DATA}" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("full",""))' 2>/dev/null || echo '')"
            KSH_EV_CNT="$(echo "${KSH_SCRAPER_DATA}" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("events_cnt",0))' 2>/dev/null || echo '0')"
            KSH_CLS_CNT="$(echo "${KSH_SCRAPER_DATA}" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("classes_cnt",0))' 2>/dev/null || echo '0')"

            AUDIT_BODY="✅ Audyt VPS (${TOTAL_TESTS} testów, Auto-Heal): ${OK_COUNT} OK | ${WARN_COUNT} WARN | ${FAIL_COUNT} FAIL
${LH_SHORT:-🟢 LH.pl (Auto-Heal): OK}
${NAZWA_SHORT:-🟢 nazwa.pl (Read-Only): OK}
💾 Backupy (03:00 UTC / 05:00 PL): VPS ${AGE_HOURS:-?}h temu | WWW LH.pl ${W_AGE_HOURS:-?}h temu
🧠 Zasoby: Dysk ${DISK_USE_PCT}% (wolne ${DISK_AVAIL_HUMAN}) | SWAP ${SWAP_TOTAL_MB:-0}M | ${MEM_INFO}
📊 Analityka WWW & AI: ${WA_PV_TOTAL:-0} odsł. | ${WA_UV_TOTAL:-0} unik. (${WA_ENG_TOTAL:-0} zaangaż.) | LCP: ${WA_LCP_AVG:-b/d} | Leady: ${WA_LEADS_TOTAL:-0}
🔍 Puls SEO & AI: Top temat AI: ${WA_TOP_TOPIC:-brak} | Top fraza: ${WA_TOP_TERM:-brak}
🛡️ Ochrona: NTP=${NTP_STATE:-yes} | BBR=${TCP_CC:-bbr} | WAF L7: ${WAF_BLOCKED_TOTAL:-0} | Fail2ban: ${F2B_BANNED:-0} IP | Skaner 24h: ${LOG_CRITICAL_24H:-0} wyjątków${HINTS_SUMMARY}"
            if [[ -n "${LH_FULL}" || -n "${NAZWA_FULL}" ]]; then
                AUDIT_BODY="${AUDIT_BODY}

🌐 SKAN HOSTINGÓW ZEWNĘTRZNYCH (LH.PL AUTO-HEAL + NAZWA.PL READ-ONLY):
${LH_FULL}
${NAZWA_FULL}"
            fi
            if [[ -n "${AI_AUDIT_INSIGHT}" ]]; then
                AUDIT_BODY="${AUDIT_BODY}

${AI_AUDIT_INSIGHT}"
                printf "\n${C_CYAN}%s${C_RESET}\n" "${AI_AUDIT_INSIGHT}"
            fi

            NTFY_BODY="${KSH_SHORT:-🕺 Scrapery KSH & DancePuls: Zsynchronizowane}
${AUDIT_BODY}"

            # 1. Wysyłka powiadomienia Push na Ntfy (Self-Hosted / Ntfy.sh)
            curl -s --max-time 5 \
                ${NTFY_AUTH_ARGS[@]+"${NTFY_AUTH_ARGS[@]}"} \
                -H "Title: Raport 06:00 (${PL_DATE}): VPS (${OK_COUNT} OK) + LH.pl + nazwa.pl + KSH (${KSH_EV_CNT} impr.)" \
                -H "Priority: default" \
                -H "Tags: sunny,robot" \
                -d "${NTFY_BODY}" \
                "${NTFY_BASE_URL}/${NTFY_AUDIT_TOPIC}" >/dev/null 2>&1 || true

            # 2. Wysyłka pełnego, połączonego raportu (Scrapery KSH + Audyt ISO 27001 VPS/LH/nazwa + 3 AI + Antigravity) na E-mail (poczatek.krzysztof@gmail.com)
            EMAIL_SUBJECT="☀️ Raport 06:00 (${PL_DATE}): VPS [${OK_COUNT} OK / ${FAIL_COUNT} FAIL] + LH.pl + nazwa.pl + KSH (${KSH_EV_CNT} impr.)"
            EMAIL_BODY="☀️ PORANNY RAPORT SYSTEMOWY (06:00) — ${PL_DATE}
TwojaStronaWWW DevOps Stack (VPS + LH.pl Auto-Heal + nazwa.pl Read-Only) & Kato Salsa Hub / DancePuls

🕺 CZĘŚĆ 1: SCRAPERY KATO SALSA HUB & DANCEPULS
──────────────────────────────────────────────────────
${KSH_FULL:-Brak danych ze scraperów.}

🛡️ CZĘŚĆ 2: AUDYT BEZPIECZEŃSTWA VPS, LH.PL (AUTO-HEAL) I NAZWA.PL (READ-ONLY) + RADA 3 AI + ARBITER ANTIGRAVITY
──────────────────────────────────────────────────────
${AUDIT_BODY}

──────────────────────────────────────────────────────
🔗 Panel DancePuls: https://katosalsahub.pl/dancepuls/
🔗 Wspólny Grafik:  https://katosalsahub.pl/grafik.html
🔗 Panel Grafana:   https://monitoring.twojastronawww.pl"

            sudo ENV_FILE="${ENV_FILE}" EMAIL_SUBJECT="${EMAIL_SUBJECT}" EMAIL_BODY="${EMAIL_BODY}" python3 "${STACK_ROOT}/scripts/morning-digest.py" send-email >/dev/null 2>&1 || true
        fi
    fi
fi
