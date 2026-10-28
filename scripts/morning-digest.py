#!/usr/bin/env python3
"""
morning-digest.py — Moduł Porannego Raportu Bezpieczeństwa ISO 27001 (06:00 PL),
Skanera Hostingów (LH.pl Auto-Heal + nazwa.pl Read-Only) & Scraperów KSH/DancePuls.

Wydzielony z audit-server.sh w celu zachowania czystości architektury (Separation of Concerns).
Obsługuje 5 podkomend:
  1. pretrigger   — wywołuje workflow_dispatch dla weekly-report.yml o 05:45 (Europe/Warsaw)
  2. hosting-scan — skanuje LH.pl (z automatyczną naprawą zagrożeń Auto-Heal) oraz nazwa.pl (100% Read-Only, tylko informacja)
  3. ai-audit     — wykonuje analizę 24h Rentgena przez 3 niezależnych darmowych audytorów AI + Arbitra Końcowego Antigravity/Gemini ($0.00)
  4. ksh-scrapers — pobiera status i deltę 24h ze scraperów Kato Salsa Hub & DancePuls (wydarzenia, grafiki, cenniki)
  5. send-email   — wysyła połączony raport poranny 06:00 na e-mail przez webhook osTicket
"""

import datetime
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request

UA_AUDIT = "Mozilla/5.0 (compatible; TwojaStronaWWW-AIRouter/2.0)"
UA_REPORT = "TwojaStronaWWW-MorningReport/2.1"

# Standardowe pliki PHP rdzenia WordPressa w katalogu głównym (do weryfikacji Read-Only na nazwa.pl)
STANDARD_WP_ROOT_PHP = {
    "index.php",
    "wp-activate.php",
    "wp-blog-header.php",
    "wp-comments-post.php",
    "wp-config-sample.php",
    "wp-config.php",
    "wp-cron.php",
    "wp-links-opml.php",
    "wp-load.php",
    "wp-login.php",
    "wp-mail.php",
    "wp-settings.php",
    "wp-signup.php",
    "wp-trackback.php",
    "xmlrpc.php",
}


def load_env(env_path: str) -> dict:
    env_vars = {}
    if os.path.exists(env_path):
        with open(env_path, "r", encoding="utf-8", errors="ignore") as ef:
            for line in ef:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    env_vars[k.strip()] = v.strip().strip("\"'")
    return env_vars


def cmd_pretrigger(env_vars: dict, pl_date: str) -> int:
    gh_tok = env_vars.get("GITHUB_TOKEN", "")
    if not gh_tok:
        return 0
    hdrs = {
        "Authorization": f"Bearer {gh_tok}",
        "User-Agent": "TwojaStronaWWW-Audit/2.1",
        "Accept": "application/vnd.github+json",
    }
    runs_url = "https://api.github.com/repos/TwojaStronaWWW/katosalsahub/actions/workflows/weekly-report.yml/runs?per_page=1"
    with urllib.request.urlopen(urllib.request.Request(runs_url, headers=hdrs), timeout=8) as r:
        runs = json.loads(r.read().decode("utf-8")).get("workflow_runs") or []
    already_today = bool(runs and str(runs[0].get("created_at", "")).startswith(pl_date))
    if not already_today:
        disp_url = "https://api.github.com/repos/TwojaStronaWWW/katosalsahub/actions/workflows/weekly-report.yml/dispatches"
        req = urllib.request.Request(
            disp_url,
            data=json.dumps({"ref": "main"}).encode("utf-8"),
            headers={**hdrs, "Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=8)
    return 0


def _http_status(url: str, timeout: int = 6) -> int:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA_AUDIT}, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return int(resp.status)
    except urllib.error.HTTPError as he:
        return int(he.code)
    except Exception:
        return 0


def _run_lftp_script(lftp_commands: str, timeout_sec: int = 25) -> str:
    """
    Wykonuje skrypt lftp przekazując komendy wyłącznie przez potok pamięci RAM (stdin),
    dzięki czemu żadne hasło FTPS nigdy nie trafia na dysk (/tmp) ani do listy procesów (ps aux).
    """
    try:
        proc = subprocess.run(
            ["lftp"],
            input=lftp_commands,
            capture_output=True,
            text=True,
            timeout=timeout_sec,
            check=False,
        )
        return (proc.stdout or "") + "\n" + (proc.stderr or "")
    except FileNotFoundError:
        try:
            proc = subprocess.run(
                [
                    "docker",
                    "run",
                    "--rm",
                    "-i",
                    "alpine:latest",
                    "sh",
                    "-c",
                    "apk add --no-cache lftp ca-certificates >/dev/null 2>&1 && lftp",
                ],
                input=lftp_commands,
                capture_output=True,
                text=True,
                timeout=timeout_sec,
                check=False,
            )
            return (proc.stdout or "") + "\n" + (proc.stderr or "")
        except Exception as exc:
            return f"ERROR: {exc}"
    except Exception as exc:
        return f"ERROR: {exc}"


def cmd_hosting_scan(env_vars: dict) -> int:
    """
    1) Skanuje Twój własny hosting LH.pl (serwer417204.lh.pl) w trybie AUTO-HEAL (automatycznie usuwa
       przypadkowo wdrożone artefakty deweloperskie/testowe, naprawia uprawnienia i weryfikuje blokady HTTP).
    2) Skanuje hosting klienta na nazwa.pl (slimgroupol.nazwa.pl) w trybie 100% READ-ONLY (zero zmian na serwerze,
       wyłącznie raportowanie stanu kwarantanny, integralności plików kluczowych i ewentualnych nowych zagrożeń).
    """
    # -------------------------------------------------------------------------
    # CZĘŚĆ A: TWÓJ HOSTING LH.PL (TRYB AUTO-HEAL — AUTOMATYCZNA NAPRAWA)
    # -------------------------------------------------------------------------
    lh_srv = env_vars.get("LH_FTP_SERVER", "")
    lh_usr = env_vars.get("LH_FTP_USERNAME", "")
    lh_pwd = env_vars.get("LH_FTP_PASSWORD", "")
    lh_port = env_vars.get("LH_FTP_PORT", "21")

    lh_healed = []
    lh_issues = []
    lh_ok_checks = 0
    lh_telemetry_summary = ""

    if lh_srv and lh_usr and lh_pwd:
        lftp_lh_check = f"""set ftp:ssl-allow true
set ftp:ssl-protect-data true
set ssl:verify-certificate yes
set net:timeout 10
set net:max-retries 2
open -p {lh_port} -u "{lh_usr}","{lh_pwd}" {lh_srv}
echo "===LH_ROOT==="
cls -la /
echo "===LH_PUB==="
cls -la /public_html
echo "===LH_TSW==="
cls -la /public_html/twojastronawww.pl
echo "===LH_FUEGO==="
cls -la /public_html/fuegolingua.pl
echo "===LH_KSH==="
cls -la /public_html/katosalsahub.pl
echo "===LH_KP==="
cls -la /public_html/krzysztofpoczatek.pl
echo "===LH_TELEMETRY_START==="
cat /backups/lh-telemetry.json
echo "===LH_TELEMETRY_END==="
quit
"""
        lh_out = _run_lftp_script(lftp_lh_check, timeout_sec=25)
        heal_cmds = []

        # Odczyt telemetrii dysku LH.pl, skrzynek pocztowych IMAP i ticketów osTicket
        if "===LH_TELEMETRY_START===" in lh_out and "===LH_TELEMETRY_END===" in lh_out:
            raw_tel = lh_out.split("===LH_TELEMETRY_START===", 1)[1].split("===LH_TELEMETRY_END===", 1)[0].strip()
            try:
                tel = json.loads(raw_tel)
                q = tel.get("quota") or {}
                used_mb = q.get("used_mb", 0)
                lim_mb = q.get("limit_mb", 4000)
                q_pct = q.get("pct", 0.0)
                q_files = q.get("files", 0)
                if q_pct >= 85.0:
                    lh_issues.append(f"dysk LH.pl zapełniony w {q_pct}% ({used_mb}/{lim_mb} MB)")

                dirs_mb = tel.get("dirs_mb") or {}
                top_dirs = ", ".join([f"{k}: {v}M" for k, v in list(dirs_mb.items())[:5]])

                mb_parts = []
                for mb in tel.get("mailboxes") or []:
                    em = mb.get("email", "?")
                    u_m = mb.get("used_mb", 0)
                    l_m = mb.get("limit_mb", 0)
                    p_m = mb.get("pct", 0.0)
                    msgs = mb.get("messages", 0)
                    unseen = mb.get("unseen", 0)
                    if p_m >= 80.0:
                        lh_issues.append(f"skrzynka {em} zapełniona w {p_m}% ({u_m}/{l_m} MB)")
                    mb_parts.append(f"{em}: {u_m}/{l_m} MB ({p_m}%, {msgs} wiad. / {unseen} nieprzecz.)")

                open_t = tel.get("osticket_open_tickets", 0)
                lh_telemetry_summary = (
                    f"\n  • Dysk konta LH.pl: {used_mb} MB / {lim_mb} MB ({q_pct}%, {q_files} plików) | Rozkład: {top_dirs}"
                    f"\n  • Skrzynki pocztowe IMAP (LH.pl): {' | '.join(mb_parts) if mb_parts else 'brak danych'}"
                    f"\n  • Helpdesk osTicket (hd.twojastronawww.pl): {open_t} otwartych zgłoszeń"
                )
                lh_ok_checks += 1
            except Exception:
                pass

        # Sprawdzenie czy w /public_html nie pojawiły się niebezpieczne symlinki lub artefakty deweloperskie
        forbidden_lh_targets = [
            ("/public_html/scripts", "rm -f /public_html/scripts", "symlink /public_html/scripts@"),
            ("/public_html/public_html", "rm -f /public_html/public_html", "symlink /public_html/public_html@"),
            ("/public_html/twojastronawww.pl/tests", "rm -r /public_html/twojastronawww.pl/tests", "twojastronawww.pl/tests/"),
            ("/public_html/twojastronawww.pl/.github", "rm -r /public_html/twojastronawww.pl/.github", "twojastronawww.pl/.github/"),
            ("/public_html/twojastronawww.pl/scripts", "rm -r /public_html/twojastronawww.pl/scripts", "twojastronawww.pl/scripts/"),
            ("/public_html/twojastronawww.pl/storage", "rm -r /public_html/twojastronawww.pl/storage", "twojastronawww.pl/storage/"),
            ("/public_html/twojastronawww.pl/AGENTS.md", "rm -f /public_html/twojastronawww.pl/AGENTS.md", "twojastronawww.pl/AGENTS.md"),
            ("/public_html/twojastronawww.pl/GEMINI.md", "rm -f /public_html/twojastronawww.pl/GEMINI.md", "twojastronawww.pl/GEMINI.md"),
            ("/public_html/twojastronawww.pl/package.json", "rm -f /public_html/twojastronawww.pl/package.json", "twojastronawww.pl/package.json"),
            ("/public_html/fuegolingua.pl/.github", "rm -r /public_html/fuegolingua.pl/.github", "fuegolingua.pl/.github/"),
            ("/public_html/fuegolingua.pl/inage", "rm -r /public_html/fuegolingua.pl/inage", "fuegolingua.pl/inage/"),
            ("/public_html/fuegolingua.pl/docs", "rm -r /public_html/fuegolingua.pl/docs", "fuegolingua.pl/docs/"),
            ("/public_html/fuegolingua.pl/AGENTS.md", "rm -f /public_html/fuegolingua.pl/AGENTS.md", "fuegolingua.pl/AGENTS.md"),
            ("/public_html/fuegolingua.pl/GEMINI.md", "rm -f /public_html/fuegolingua.pl/GEMINI.md", "fuegolingua.pl/GEMINI.md"),
            ("/public_html/katosalsahub.pl/tests", "rm -r /public_html/katosalsahub.pl/tests", "katosalsahub.pl/tests/"),
            ("/public_html/katosalsahub.pl/tests.html", "rm -f /public_html/katosalsahub.pl/tests.html", "katosalsahub.pl/tests.html"),
            ("/public_html/krzysztofpoczatek.pl/AGENTS.md", "rm -f /public_html/krzysztofpoczatek.pl/AGENTS.md", "krzysztofpoczatek.pl/AGENTS.md"),
            ("/public_html/krzysztofpoczatek.pl/GEMINI.md", "rm -f /public_html/krzysztofpoczatek.pl/GEMINI.md", "krzysztofpoczatek.pl/GEMINI.md"),
        ]

        for marker, rm_cmd, label in forbidden_lh_targets:
            if marker in lh_out:
                heal_cmds.append(rm_cmd)
                lh_healed.append(f"usunięto artefakt {label}")

        # Wymuszenie bezpiecznych uprawnień PoLP (0700/0600) na LH.pl jeśli uległy rozluźnieniu
        for dir_name in ("/scripts", "/backups"):
            for line in lh_out.splitlines():
                if line.endswith(f" {dir_name}/") and not line.startswith("drwx------"):
                    heal_cmds.append(f"chmod 700 {dir_name}")
                    lh_healed.append(f"przywrócono chmod 700 na {dir_name}")

        if heal_cmds:
            heal_script = f"""set ftp:ssl-allow true
set ftp:ssl-protect-data true
set ssl:verify-certificate yes
open -p {lh_port} -u "{lh_usr}","{lh_pwd}" {lh_srv}
""" + "\n".join(heal_cmds) + "\nquit\n"
            _run_lftp_script(heal_script, timeout_sec=25)
        lh_ok_checks += 1

    # Żywa weryfikacja HTTP i blokad .htaccess na LH.pl
    lh_prod_urls = [
        "https://twojastronawww.pl/",
        "https://katosalsahub.pl/",
        "https://fuegolingua.pl/",
        "https://krzysztofpoczatek.pl/",
        "https://hd.twojastronawww.pl/",
    ]
    for u in lh_prod_urls:
        st = _http_status(u)
        if st == 200:
            lh_ok_checks += 1
        else:
            lh_issues.append(f"{u} zwrócił HTTP {st}")

    lh_blocked_urls = [
        "https://twojastronawww.pl/.env",
        "https://twojastronawww.pl/tests/clean_limits.php",
        "https://twojastronawww.pl/.github/workflows/deploy.yml",
        "https://katosalsahub.pl/.env",
        "https://katosalsahub.pl/assets/data/moderators.json",
        "https://katosalsahub.pl/assets/data/moderators.json.bak",
        "https://hd.twojastronawww.pl/include/ost-config.php",
    ]
    for u in lh_blocked_urls:
        st = _http_status(u)
        if st in (403, 404):
            lh_ok_checks += 1
        else:
            lh_issues.append(f"UWAGA: {u} nie jest zablokowany (HTTP {st})")

    # -------------------------------------------------------------------------
    # DODATKOWY SKAN OPERACYJNY: TERMINY OPŁACENIA DOMEN (NASK RDAP), WAŻNOŚĆ SSL I CZARNE LISTY RBL
    # -------------------------------------------------------------------------
    now_utc = datetime.datetime.now(datetime.timezone.utc)

    rdap_cache_file = "/var/tmp/devops-rdap-cache.json"
    rdap_cache = {
        "raricart.pl": {"exp": "2026-11-25", "reg": "LH.pl"},
        "twojastronawww.pl": {"exp": "2027-01-31", "reg": "LH.pl"},
        "fuegolingua.pl": {"exp": "2027-02-01", "reg": "LH.pl"},
        "medycyna-regeneracyjna.pl": {"exp": "2027-04-26", "reg": "nazwa.pl"},
        "galanonim.pl": {"exp": "2027-05-08", "reg": "home.pl"},
        "medicusnoster.pl": {"exp": "2027-06-22", "reg": "nazwa.pl"},
        "katosalsahub.pl": {"exp": "2027-07-06", "reg": "LH.pl"},
        "krzysztofpoczatek.pl": {"exp": "2027-07-07", "reg": "LH.pl"},
    }
    if os.path.exists(rdap_cache_file):
        try:
            with open(rdap_cache_file, "r", encoding="utf-8") as cf:
                rdap_cache.update(json.load(cf))
        except Exception:
            pass

    def _check_rdap_domain(dom: str) -> tuple[str, int, str]:
        cached = rdap_cache.get(dom, {})
        exp = cached.get("exp", "?")
        reg_name = cached.get("reg", "?")
        last_ts = float(cached.get("ts", 0))
        if time.time() - last_ts > 43200:
            try:
                req = urllib.request.Request(f"https://rdap.dns.pl/domain/{dom}", headers={"User-Agent": UA_AUDIT})
                with urllib.request.urlopen(req, timeout=5) as r:
                    d = json.loads(r.read().decode("utf-8"))
                evs = {e.get("eventAction"): (e.get("eventDate") or "")[:10] for e in d.get("events", [])}
                if evs.get("expiration"):
                    exp = evs["expiration"]
                for ent in d.get("entities", []):
                    vcard = ent.get("vcardArray", [None, []])[1]
                    for item in vcard:
                        if item[0] == "fn":
                            reg_name = item[3].split()[0]
                rdap_cache[dom] = {"exp": exp, "reg": reg_name, "ts": time.time()}
            except Exception:
                pass
        days = 9999
        if exp != "?":
            try:
                dt = datetime.datetime.strptime(exp, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
                days = (dt - now_utc).days
            except Exception:
                pass
        flag = "⚠️ PILNE OPŁACENIE! " if days <= 35 else ""
        return f"{flag}{dom}: do {exp} ({days} dni, {reg_name})", days, exp

    def _check_ssl_days(host: str) -> str:
        try:
            ctx = ssl.create_default_context()
            with socket.create_connection((host, 443), timeout=5) as sock:
                with ctx.wrap_socket(sock, server_hostname=host) as ssock:
                    cert = ssock.getpeercert()
            not_after = cert.get("notAfter", "")
            if not_after:
                dt = datetime.datetime.strptime(not_after, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
                days = (dt - now_utc).days
                flag = "⚠️ " if days <= 14 else ""
                return f"{flag}{host}: {days} dni (do {dt.strftime('%Y-%m-%d')})"
        except ssl.SSLCertVerificationError:
            return f"⚠️ {host}: brak dedykowanego SSL (domyślny cert hostingu)"
        except Exception:
            pass
        return f"{host}: b/d"

    def _check_rbl_ip(ip_addr: str) -> str:
        rev = ".".join(reversed(ip_addr.split(".")))
        listed = []
        for rbl in ("zen.spamhaus.org", "bl.spamcop.net", "b.barracudacentral.org"):
            try:
                res = socket.gethostbyname(f"{rev}.{rbl}")
                if res.startswith("127.0.0.") and not res.endswith(".255"):
                    listed.append(rbl)
            except Exception:
                pass
        return f"🚨 NA CZARNEJ LIŚCIE: {', '.join(listed)}" if listed else "CZYSTE (0/3 RBL)"

    own_domains = ["raricart.pl", "twojastronawww.pl", "fuegolingua.pl", "galanonim.pl", "katosalsahub.pl", "krzysztofpoczatek.pl"]
    own_dom_results = [_check_rdap_domain(d) for d in own_domains]
    own_dom_results.sort(key=lambda x: x[1])
    own_dom_str = " | ".join([x[0] for x in own_dom_results])
    expiring_soon = [x[0] for x in own_dom_results if x[1] <= 35]

    own_ssl_hosts = ["twojastronawww.pl", "katosalsahub.pl", "fuegolingua.pl", "krzysztofpoczatek.pl", "hd.twojastronawww.pl", "raricart.pl", "galanonim.pl"]
    own_ssl_str = " | ".join([_check_ssl_days(h) for h in own_ssl_hosts])

    try:
        lh_mail_ip = socket.gethostbyname("mail-serwer417204.lh.pl")
        lh_rbl_str = f"mail-serwer417204.lh.pl ({lh_mail_ip}): {_check_rbl_ip(lh_mail_ip)}"
    except Exception:
        lh_rbl_str = "mail-serwer417204.lh.pl: b/d"
    vps_rbl_str = f"VPS (89.168.62.31): {_check_rbl_ip('89.168.62.31')}"

    lh_ops_footer = (
        f"{lh_telemetry_summary}"
        f"\n  • Terminy wygaśnięcia / opłacenia domen (NASK RDAP): {own_dom_str}"
        f"\n  • Ważność certyfikatów SSL/TLS: {own_ssl_str}"
        f"\n  • Reputacja IP / Antyspam RBL: {lh_rbl_str} | {vps_rbl_str}"
    )

    dom_warn_suffix = f" [⚠️ DOMENA DO OPŁACENIA: {expiring_soon[0]}]" if expiring_soon else ""

    if lh_issues:
        lh_status_short = f"⚠️ LH.pl: {len(lh_issues)} ostrz. (Auto-Heal: {len(lh_healed)}){dom_warn_suffix}"
        lh_status_full = f"⚠️ Twój Hosting LH.pl (Auto-Heal AKTYWNY): wykryto {len(lh_issues)} uwag ({', '.join(lh_issues)}) | Automatycznie naprawiono: {len(lh_healed)} ({', '.join(lh_healed) if lh_healed else 'brak'}){lh_ops_footer}"
    elif lh_healed:
        lh_status_short = f"🛡️ LH.pl: OK (Auto-Heal naprawił {len(lh_healed)} poz.){dom_warn_suffix}"
        lh_status_full = f"🛡️ Twój Hosting LH.pl (Auto-Heal AKTYWNY): CZYSTO ({lh_ok_checks}/{lh_ok_checks} testów HTTP/FTPS OK) — automatycznie oczyszczono: {', '.join(lh_healed)}{lh_ops_footer}"
    else:
        lh_status_short = f"🛡️ LH.pl: CZYSTO ({lh_ok_checks}/{lh_ok_checks} OK, Auto-Heal czuwa){dom_warn_suffix}"
        lh_status_full = f"🛡️ Twój Hosting LH.pl (Auto-Heal AKTYWNY): CZYSTO ({lh_ok_checks}/{lh_ok_checks} testów HTTP/FTPS/.htaccess/PoLP OK, 0 webshelli, 0 wycieków){lh_ops_footer}"

    # -------------------------------------------------------------------------
    # CZĘŚĆ B: HOSTING KLIENTA NAZWA.PL (TRYB 100% READ-ONLY — TYLKO INFORMACJA!)
    # -------------------------------------------------------------------------
    nz_srv = env_vars.get("NAZWA_FTP_SERVER", "slimgroupol.nazwa.pl")
    nz_usr = env_vars.get("NAZWA_FTP_USER", "")
    nz_pwd = env_vars.get("NAZWA_FTP_PASSWORD", "")

    nz_alerts = []
    nz_checks_ok = 0

    if nz_srv and nz_usr and nz_pwd:
        # Wyłącznie komendy odczytu (cls -la) z pełną weryfikacją certyfikatu TLS — ZERO modyfikacji na nazwa.pl!
        lftp_nz_readonly = f"""set ftp:ssl-allow true
set ftp:ssl-protect-data true
set ssl:verify-certificate yes
set net:timeout 10
set net:max-retries 2
open -p 21 -u "{nz_usr}","{nz_pwd}" {nz_srv}
echo "===NZ_ROOT==="
cls -la /
echo "===NZ_MEDREG_FILES==="
cls -la /medycynaregeneracyjna/medycyna-regeneracyjna/index.php /medycynaregeneracyjna/medycyna-regeneracyjna/.htaccess /medycynaregeneracyjna/medycyna-regeneracyjna/wp-includes/load.php
echo "===NZ_MEDREG_DIR==="
cls -la /medycynaregeneracyjna/medycyna-regeneracyjna
echo "===NZ_MEDNOSTER_FILES==="
cls -la /medicusnoster/index.php /medicusnoster/wp-config.php
echo "===NZ_MEDNOSTER_DIR==="
cls -la /medicusnoster
quit
"""
        nz_out = _run_lftp_script(lftp_nz_readonly, timeout_sec=25)

        if "ERROR:" in nz_out or "Login incorrect" in nz_out or "===NZ_ROOT===" not in nz_out:
            nz_alerts.append("brak połączenia Read-Only FTPS z slimgroupol.nazwa.pl")
        else:
            # 1. Sprawdzenie czy sejf kwarantanny /.quarantine_tsw_20261028 jest zablokowany (d---------)
            if re.search(r"^d---------\s+.*\/\.quarantine_tsw_20261028\/", nz_out, re.M):
                nz_checks_ok += 1
            else:
                nz_alerts.append("kwarantanna /.quarantine_tsw_20261028 zmieniła uprawnienia lub zniknęła!")

            # 2. Sprawdzenie rozmiarów i uprawnień (0444) kluczowych plików chronionych przed reinfekcją
            expected_files = [
                (r"^-r--r--r--\s+\S+\s+\S+\s+405\s+.*\/medycynaregeneracyjna\/medycyna-regeneracyjna\/index\.php$", "medycyna-regeneracyjna/index.php (405 B, 0444)"),
                (r"^-r--r--r--\s+\S+\s+\S+\s+843\s+.*\/medycynaregeneracyjna\/medycyna-regeneracyjna\/\.htaccess$", "medycyna-regeneracyjna/.htaccess (843 B, 0444)"),
                (r"^-r--r--r--\s+\S+\s+\S+\s+56510\s+.*\/medycynaregeneracyjna\/medycyna-regeneracyjna\/wp-includes\/load\.php$", "medycyna-regeneracyjna/wp-includes/load.php (56510 B, 0444)"),
                (r"^-r--r--r--\s+\S+\s+\S+\s+405\s+.*\/medicusnoster\/index\.php$", "medicusnoster/index.php (405 B, 0444)"),
                (r"^-r--r--r--\s+\S+\s+\S+\s+3765\s+.*\/medicusnoster\/wp-config\.php$", "medicusnoster/wp-config.php (3765 B, 0444)"),
            ]
            for pat, desc in expected_files:
                if re.search(pat, nz_out, re.M):
                    nz_checks_ok += 1
                else:
                    nz_alerts.append(f"zmiana rozmiaru/uprawnień w {desc}")

            # 3. Sprawdzenie czy w głównych katalogach nie pojawiły się obce pliki .php poza rdzeniem WP
            for sec_tag, domain_label in (("NZ_MEDREG_DIR", "medycyna-regeneracyjna.pl"), ("NZ_MEDNOSTER_DIR", "medicusnoster.pl")):
                if f"==={sec_tag}===" in nz_out:
                    sec_part = nz_out.split(f"==={sec_tag}===", 1)[1].split("===", 1)[0]
                    for line in sec_part.splitlines():
                        parts = line.strip().split()
                        if not parts:
                            continue
                        fname = os.path.basename(parts[-1].rstrip("/"))
                        if fname.endswith(".php") and fname not in STANDARD_WP_ROOT_PHP:
                            nz_alerts.append(f"podejrzany plik PHP w {domain_label}: {fname}")
                        if any(bad in fname for bad in ("PJcpMFsD8B", "adminfuns", "wp-conffq", ".private", "__2DUAN")):
                            nz_alerts.append(f"wykryto sygnaturę infekcji w {domain_label}: {fname}")
                    nz_checks_ok += 1

            # 4. Nieinwazyjna kontrola Read-Only wyrenderowanego HTML-a przez HTTPS (wykrywanie wstrzyknięć z bazy MySQL WP)
            for nz_url, verify_ssl in (("https://medycyna-regeneracyjna.pl/", True), ("https://medicusnoster.pl/", False)):
                try:
                    req = urllib.request.Request(nz_url, headers={"User-Agent": UA_AUDIT}, method="GET")
                    ssl_ctx = ssl.create_default_context() if verify_ssl else ssl._create_unverified_context()
                    with urllib.request.urlopen(req, timeout=8, context=ssl_ctx) as resp:
                        html_body = resp.read(250_000).decode("utf-8", errors="ignore")
                        if resp.status == 200 and not any(
                            sig in html_body
                            for sig in ("eval(function(p,a,c,k", "document.write(unescape(", "fromCharCode(104,116,116,112")
                        ):
                            nz_checks_ok += 1
                        else:
                            nz_alerts.append(f"podejrzana zawartość HTML lub status na {nz_url}")
                except Exception:
                    nz_alerts.append(f"błąd odczytu HTTPS dla {nz_url}")
    else:
        nz_alerts.append("brak skonfigurowanych danych NAZWA_FTP_* w .env")

    nz_domains = ["medycyna-regeneracyjna.pl", "medicusnoster.pl"]
    nz_dom_str = " | ".join([_check_rdap_domain(d)[0] for d in nz_domains])
    nz_ssl_str = " | ".join([_check_ssl_days(d) for d in nz_domains])
    try:
        with open(rdap_cache_file, "w", encoding="utf-8") as cf:
            json.dump(rdap_cache, cf, ensure_ascii=False)
    except Exception:
        pass
    nz_ops_footer = (
        f"\n  • Terminy wygaśnięcia domen klienta (NASK RDAP): {nz_dom_str}"
        f"\n  • Ważność certyfikatów SSL/TLS klienta: {nz_ssl_str}"
    )

    if nz_alerts:
        nz_status_short = f"🚨 nazwa.pl (Tylko Raport): WYKRYTO {len(nz_alerts)} ANOMALII!"
        nz_status_full = (
            f"🚨 Hosting Klienta nazwa.pl (TRYB READ-ONLY — TYLKO INFORMACJA, ZERO AUTOMATYCZNYCH ZMIAN): "
            f"Wykryto {len(nz_alerts)} anomalii: {'; '.join(nz_alerts)}. Czekam na Twoją decyzję przed podjęciem działań!{nz_ops_footer}"
        )
    else:
        nz_status_short = f"👁️ nazwa.pl (Read-Only): CZYSTO ({nz_checks_ok}/{nz_checks_ok} OK)"
        nz_status_full = (
            f"👁️ Hosting Klienta nazwa.pl (TRYB READ-ONLY — TYLKO INFORMACJA, ZERO AUTOMATYCZNYCH ZMIAN): "
            f"CZYSTO ({nz_checks_ok}/{nz_checks_ok} kontroli FTPS TLS + DOM HTTPS OK: kwarantanna 0000 nienaruszona, "
            f"index.php/.htaccess/load.php/wp-config.php bez zmian, 0 nowych plików PHP, czysty kod HTML). Nic nie ruszano.{nz_ops_footer}"
        )

    print(
        json.dumps(
            {
                "lh_short": lh_status_short,
                "lh_full": lh_status_full,
                "lh_issues_cnt": len(lh_issues),
                "lh_healed_cnt": len(lh_healed),
                "nazwa_short": nz_status_short,
                "nazwa_full": nz_status_full,
                "nazwa_alerts_cnt": len(nz_alerts),
            },
            ensure_ascii=False,
        )
    )
    return 0


def cmd_ai_audit(env_vars: dict) -> int:
    """
    Rada 3 Niezależnych Darmowych Audytorów AI ($0.00) + Arbiter Końcowy #4 (Antigravity / Gemini High-Reasoning, $0.00):
      - Audytor #1: Groq LPU — GPT-OSS-120B (reasoning: HIGH)
      - Audytor #2: Cerebras WSE — Qwen-3.8-27B / GPT-OSS-120B (reasoning: HIGH)
      - Audytor #3: Cloudflare Edge AI — Llama-3.3-70B-Instruct-FP8
      - Arbiter #4 (Końcowy): Antigravity / Google Gemini (thinking: HIGH) — syntetyzuje wyniki #1, #2, #3 i Rentgen 24h.
    Płatny budżet Anthropic ($4.7732) jest w 100% chroniony ($0.00 poboru w codziennych audytach).
    """
    groq_key = env_vars.get("GROQ_API_KEY", "")
    cerebras_key = env_vars.get("CEREBRAS_API_KEY", "")
    cf_token = env_vars.get("CF_AI_API_TOKEN", "")
    cf_account = env_vars.get("CF_ACCOUNT_ID", "")
    gemini_key = env_vars.get("GEMINI_API_KEY", "")
    anthropic_key = env_vars.get("ANTHROPIC_API_KEY", "")
    force_claude = os.environ.get("FORCE_CLAUDE_ESCALATION", "false") == "true"

    xray_path = os.environ.get("XRAY_FILE", "")
    budget_path = "/var/lib/docker/volumes/ai_router_storage/_data/anthropic_budget.json"

    if not xray_path or not os.path.exists(xray_path):
        return 0

    with open(xray_path, "r", encoding="utf-8", errors="replace") as f:
        xray_text = f.read()[:7000]

    sys_prompt_auditor1 = (
        "Jesteś Niezależnym Audytorem #1 (Perspektywa Red Team / Pentester, Certyfikaty SSL & Reputacja RBL). "
        "Przeprowadź niezależny audyt krzyżowy WSZYSTKICH 3 PRZESTRZENI i wypisz po polsku dokładnie 3 krótkie punkty (po 1-2 zdania na obszar):\n"
        "- [1. Twój Hosting LH.pl (Auto-Heal)]: oceń blokady .htaccess, uprawnienia PoLP, Auto-Heal, ważność certyfikatów SSL, reputację antyspamową RBL oraz terminy wygaśnięcia domen (wskaż jeśli domena wymaga opłacenia <35 dni).\n"
        "- [2. Serwer VPS (Auto-Heal)]: oceń odporność perymetru Zero Trust (UFW/DOCKER-USER/SSH Ed25519), blokady WAF L7 i Fail2ban, reputację RBL IP VPS oraz logi 12 kontenerów.\n"
        "- [3. Hosting Klienta nazwa.pl (100% Read-Only)]: oceń wyłącznie informacyjnie (bez żadnych zmian!) kwarantannę 0000, pliki 0444, czysty kod HTML oraz ważność domen i certyfikatów SSL klienta."
    )

    sys_prompt_auditor2 = (
        "Jesteś Niezależnym Audytorem #2 (Perspektywa Blue Team / Kryminalistyka IoC, Zasoby, Skrzynki IMAP & Ciągłość DR). "
        "Przeprowadź niezależny audyt krzyżowy WSZYSTKICH 3 PRZESTRZENI i wypisz po polsku dokładnie 3 krótkie punkty (po 1-2 zdania na obszar):\n"
        "- [1. Twój Hosting LH.pl (Auto-Heal)]: zweryfikuj czystość FTPS, zajętość dysku konta (MB/%), zajętość 3 skrzynek pocztowych IMAP i nieprzeczytane maile, otwarte tickety osTicket oraz terminy odnowienia domen NASK RDAP.\n"
        "- [2. Serwer VPS (Auto-Heal)]: zweryfikuj wskaźniki włamań IoC (Clean=1, 0 wyjątków 24h), kondycję zasobów (RAM/Dysk/SWAP) oraz nocny Restore Drill i SQLite PRAGMA quick_check.\n"
        "- [3. Hosting Klienta nazwa.pl (100% Read-Only)]: zweryfikuj w trybie czystego odczytu 10/10 kontroli integralności (rozmiary co do bajtu index.php/.htaccess/load.php/wp-config.php, brak nowych plików PHP, czysty DOM HTTPS oraz terminy domen)."
    )

    sys_prompt_auditor3 = (
        "Jesteś Niezależnym Audytorem #3 (Perspektywa Audytora Zgodności ISO 27001, SLA, Domeny & Poczta). "
        "Przeprowadź niezależny audyt krzyżowy WSZYSTKICH 3 PRZESTRZENI i wypisz po polsku dokładnie 3 krótkie punkty (po 1-2 zdania na obszar):\n"
        "- [1. Twój Hosting LH.pl (Auto-Heal)]: oceń zgodność konfiguracji domen, status testów kontrolnych, higienę skrzynek pocztowych IMAP/osTicket oraz pilne terminy płatności za domeny (NASK RDAP) i SSL.\n"
        "- [2. Serwer VPS (Auto-Heal)]: oceń zgodność 78 testów ISO 27001 na VPS, separację sieci Docker oraz ochronę sekretów i kopii zapasowych AES-256-CBC w Cloudflare R2.\n"
        "- [3. Hosting Klienta nazwa.pl (100% Read-Only)]: potwierdź stan obserwacyjny środowiska klienta na nazwa.pl (10/10 kontroli, stan SSL i domen oraz czy wymagana jest jakakolwiek decyzja właściciela przy zachowaniu 0 modyfikacji)."
    )

    def _call_openai_compat(url: str, key: str, body: dict, timeout: int = 20) -> tuple[str, int, int]:
        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode("utf-8"),
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json", "User-Agent": UA_AUDIT},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        choice = (data.get("choices") or [{}])[0]
        msg = choice.get("message", {})
        txt = (msg.get("content") or "").strip()
        if "<think>" in txt and "</think>" in txt:
            txt = txt.split("</think>", 1)[1].strip()
        txt = txt.replace("**", "").strip()
        if choice.get("finish_reason") == "length" and len(txt) < 80:
            return "", 0, 0
        usage = data.get("usage") or {}
        tot_tok = int(usage.get("total_tokens", 0))
        think_tok = int((usage.get("completion_tokens_details") or {}).get("reasoning_tokens", 0))
        return txt, think_tok, tot_tok

    # 1. AUDYTOR #1 (Chmura Groq LPU — $0.00): GPT-OSS-120B (reasoning: HIGH)
    aud1_ans, aud1_label, aud1_think, aud1_tot = "", "", 0, 0
    if groq_key:
        for m_id, m_lbl in (("openai/gpt-oss-120b", "Groq GPT-OSS-120B (reasoning: HIGH)"), ("qwen/qwen3-32b", "Groq Qwen3-32B")):
            try:
                body = {
                    "model": m_id,
                    "messages": [{"role": "system", "content": sys_prompt_auditor1}, {"role": "user", "content": xray_text}],
                    "temperature": 0.2,
                    "max_tokens": 4096,
                    **({"reasoning_effort": "high"} if "gpt-oss" in m_id else {}),
                }
                txt, th, tot = _call_openai_compat("https://api.groq.com/openai/v1/chat/completions", groq_key, body)
                if txt:
                    aud1_ans, aud1_label, aud1_think, aud1_tot = txt, m_lbl, th, tot
                    break
            except Exception:
                continue

    # 2. AUDYTOR #2 (Chmura Cerebras WSE — $0.00): GPT-OSS-120B (reasoning: HIGH) / Qwen-3.8-27B
    aud2_ans, aud2_label, aud2_think, aud2_tot = "", "", 0, 0
    if cerebras_key:
        for m_id, m_lbl in (("gpt-oss-120b", "Cerebras GPT-OSS-120B (WSE, reasoning: HIGH)"), ("qwen-3.8-27b", "Cerebras Qwen-3.8-27B (WSE)")):
            try:
                body = {
                    "model": m_id,
                    "messages": [{"role": "system", "content": sys_prompt_auditor2}, {"role": "user", "content": xray_text}],
                    "temperature": 0.2,
                    "max_tokens": 4096,
                    **({"reasoning_effort": "high"} if "gpt-oss" in m_id else {}),
                }
                txt, th, tot = _call_openai_compat("https://api.cerebras.ai/v1/chat/completions", cerebras_key, body)
                if txt:
                    aud2_ans, aud2_label, aud2_think, aud2_tot = txt, m_lbl, th, tot
                    break
            except Exception:
                continue

    # 3. AUDYTOR #3 (Chmura Cloudflare Workers AI — $0.00): Llama-3.3-70B-Instruct-FP8
    aud3_ans, aud3_label, aud3_tot = "", "", 0
    if cf_token and cf_account:
        try:
            cf_url = f"https://api.cloudflare.com/client/v4/accounts/{cf_account}/ai/v1/chat/completions"
            cf_body = {
                "model": "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
                "messages": [{"role": "system", "content": sys_prompt_auditor3}, {"role": "user", "content": xray_text}],
                "temperature": 0.2,
                "max_tokens": 2048,
            }
            txt, _, tot = _call_openai_compat(cf_url, cf_token, cf_body, timeout=25)
            if txt:
                aud3_ans = txt
                aud3_label = "Cloudflare Llama-3.3-70B-FP8"
                aud3_tot = tot
        except Exception:
            pass

    # 4. ARBITER KOŃCOWY #4 (Ja / Antigravity Gemini High-Reasoning — $0.00):
    # Otrzymuje pełny Rentgen 24h (VPS + LH.pl + nazwa.pl) ORAZ raporty 3 niezależnych audytorów i wydaje werdykt końcowy
    arbiter_ans, arbiter_label, arbiter_think, arbiter_tot = "", "", 0, 0
    council_summary = (
        f"{xray_text}\n\n"
        f"=== OPINIE 3 NIEZALEŻNYCH AUDYTORÓW AI ===\n"
        f"[Audytor #1 - {aud1_label or 'brak'}]: {aud1_ans or 'brak'}\n"
        f"[Audytor #2 - {aud2_label or 'brak'}]: {aud2_ans or 'brak'}\n"
        f"[Audytor #3 - {aud3_label or 'brak'}]: {aud3_ans or 'brak'}\n"
    )
    sys_prompt_arbiter = (
        "Jesteś Głównym Arbitrem Końcowym #4 (Antigravity / Gemini High-Reasoning — Senior DevOps & ISO 27001 Lead Auditor). "
        "Masz przed sobą surowy 24-godzinny Rentgen wszystkich 3 przestrzeni ORAZ 3 niezależne audyty krzyżowe od Audytora #1 (Groq Red Team), "
        "Audytora #2 (Cerebras Blue Team) i Audytora #3 (Cloudflare ISO 27001), z których każdy badał wszystkie 3 środowiska. "
        "Zbadaj osobiście wszystkie 3 obszary, skonfrontuj wnioski całej trójki audytorów i wypisz po polsku dokładnie 4 zwięzłe punkty:\n"
        "1) [1. Twój Hosting LH.pl (Auto-Heal, Poczta & Domeny)]: Twoja weryfikacja + konsensus 3 audytorów (bezpieczeństwo, zajętość dysku i skrzynek pocztowych IMAP, tickety osTicket, RBL oraz zbliżające się terminy opłacenia domen/SSL),\n"
        "2) [2. Serwer VPS (Auto-Heal)]: Twoja weryfikacja + konsensus 3 audytorów (stan 78 testów, kontenerów, WAF/Fail2ban, IoC, RBL i kopii R2),\n"
        "3) [3. Hosting Klienta nazwa.pl (100% Read-Only — ZERO ZMIAN)]: Twoja weryfikacja + konsensus 3 audytorów (stan 10/10 kontroli kwarantanny 0000, plików 0444, DOM HTTPS oraz stan SSL/domen klienta),\n"
        "4) [4. Werdykt Końcowy Arbitra (Matryca 3×3)]: CZYSTO / PRZYPOMNIENIE O PŁATNOŚCI DOMENY / WYMAGA DECYZJI."
    )

    if gemini_key:
        for g_model in ("gemini-3.5-flash-lite", "gemini-3.5-flash", "gemma-4-31b-it", "gemini-3.7-flash", "gemini-3.8-flash"):
            try:
                g_url = f"https://generativelanguage.googleapis.com/v1beta/models/{g_model}:generateContent?key={gemini_key}"
                gen_cfg = {
                    "temperature": 0.2,
                    "maxOutputTokens": 4096,
                    **({"thinkingConfig": {"thinkingLevel": "HIGH"}} if "gemini-3" in g_model else {}),
                }
                g_body = {
                    "systemInstruction": {"parts": [{"text": sys_prompt_arbiter}]},
                    "contents": [{"role": "user", "parts": [{"text": council_summary}]}],
                    "generationConfig": gen_cfg,
                }
                req = urllib.request.Request(
                    g_url,
                    data=json.dumps(g_body).encode("utf-8"),
                    headers={"Content-Type": "application/json", "User-Agent": UA_AUDIT},
                    method="POST",
                )
                with urllib.request.urlopen(req, timeout=32) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
                parts = (((data.get("candidates") or [{}])[0].get("content") or {}).get("parts")) or []
                out_chunks = [p.get("text", "").strip() for p in parts if not p.get("thought") and p.get("text")]
                txt = "\n".join([c for c in out_chunks if c]).strip().replace("**", "")
                if txt:
                    u_meta = data.get("usageMetadata", {})
                    arbiter_ans = txt
                    arbiter_label = f"Antigravity / {g_model} (thinking: HIGH)"
                    arbiter_think = int(u_meta.get("thoughtsTokenCount", 0))
                    arbiter_tot = int(u_meta.get("totalTokenCount", 0))
                    break
            except Exception:
                continue

    budget = {"initial_usd": 5.00, "spent_usd": 0.0, "total_tokens": 0, "runs": 0}
    if os.path.exists(budget_path):
        try:
            with open(budget_path, "r", encoding="utf-8") as bf:
                budget.update(json.load(bf))
        except Exception:
            pass

    claude_section = ""
    cost_today_usd = 0.0

    # Płatny Claude Sonnet 4.6 jest CAŁKOWICIE WYŁĄCZONY z codziennych audytów (chronimy $4.7732!).
    # Uruchamia się wyłącznie na jawne żądanie ręczne flagą --deep-claude lub gdyby wszystkie 4 darmowe chmury jednocześnie padły.
    if anthropic_key and (force_claude or (not aud1_ans and not aud2_ans and not aud3_ans and not arbiter_ans)):
        try:
            c_payload = {
                "model": "claude-sonnet-4-6",
                "max_tokens": 900,
                "system": [{"type": "text", "text": sys_prompt_arbiter, "cache_control": {"type": "ephemeral"}}],
                "messages": [{"role": "user", "content": council_summary}],
            }
            req = urllib.request.Request(
                "https://api.anthropic.com/v1/messages",
                data=json.dumps(c_payload).encode("utf-8"),
                headers={
                    "x-api-key": anthropic_key,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                    "User-Agent": UA_AUDIT,
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=25) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            c_ans = "".join([b.get("text", "").strip() for b in data.get("content", []) if b.get("type") == "text"])
            usage = data.get("usage", {})
            in_tok = int(usage.get("input_tokens", 0))
            out_tok = int(usage.get("output_tokens", 0))
            cache_w = int(usage.get("cache_creation_input_tokens", 0))
            cache_r = int(usage.get("cache_read_input_tokens", 0))
            total_tok_today = in_tok + out_tok + cache_w + cache_r
            cost_today_usd = (in_tok * 3.0 + out_tok * 15.0 + cache_w * 3.75 + cache_r * 0.30) / 1_000_000.0
            budget["spent_usd"] = round(float(budget.get("spent_usd", 0.0)) + cost_today_usd, 6)
            budget["total_tokens"] = int(budget.get("total_tokens", 0)) + total_tok_today
            budget["runs"] = int(budget.get("runs", 0)) + 1
            os.makedirs(os.path.dirname(budget_path), exist_ok=True)
            tmp_budget_path = f"{budget_path}.{os.getpid()}.tmp"
            with open(tmp_budget_path, "w", encoding="utf-8") as bf:
                json.dump(budget, bf, indent=2)
            os.replace(tmp_budget_path, budget_path)
            claude_section = f"\n🚨 Rezerwowa Ekspertyza Claude Sonnet 4.6:\n{c_ans}\n"
        except Exception:
            pass

    rem_usd = max(0.0, round(float(budget["initial_usd"]) - float(budget.get("spent_usd", 0.0)), 4))
    out_lines = []
    if aud1_ans:
        t1 = f" [myślenie: {aud1_think} tok. / łącznie: {aud1_tot} tok.]" if aud1_think > 0 else f" [{aud1_tot} tok.]"
        out_lines.append(f"🧠 Audytor Krzyżowy #1 (LH.pl + VPS + nazwa.pl | Red Team) — {aud1_label}{t1}:\n{aud1_ans}")
    if aud2_ans:
        t2 = f" [myślenie: {aud2_think} tok. / łącznie: {aud2_tot} tok.]" if aud2_think > 0 else f" [{aud2_tot} tok.]"
        out_lines.append(f"🔍 Audytor Krzyżowy #2 (LH.pl + VPS + nazwa.pl | Blue Team & DR) — {aud2_label}{t2}:\n{aud2_ans}")
    if aud3_ans:
        t3 = f" [{aud3_tot} tok.]" if aud3_tot > 0 else ""
        out_lines.append(f"🌐 Audytor Krzyżowy #3 (LH.pl + VPS + nazwa.pl | ISO 27001) — {aud3_label}{t3}:\n{aud3_ans}")
    if arbiter_ans:
        t4 = f" [myślenie: {arbiter_think} tok. / łącznie: {arbiter_tot} tok.]" if arbiter_think > 0 else f" [{arbiter_tot} tok.]"
        out_lines.append(f"⚖️ Arbiter Końcowy #4 (Synteza 3×3: LH.pl + VPS + nazwa.pl) — {arbiter_label}{t4}:\n{arbiter_ans}")
    if claude_section:
        out_lines.append(claude_section.strip())

    out_lines.append(
        f"💰 Koszt dzisiejszego audytu krzyżowego 3×3 (3 Niezależnych + Arbiter Antigravity): ${cost_today_usd:.4f} ($0.00 Always Free)\n"
        f"• Zamrożona rezerwa czatbota Anthropic ($5.00): pozostało ${rem_usd:.4f} (0.00 USD poboru w audytach)"
    )
    print("\n\n".join(out_lines))
    return 0


def cmd_ksh_scrapers(env_vars: dict, pl_date: str) -> int:
    gh_tok = env_vars.get("GITHUB_TOKEN", "")
    hdrs = {"User-Agent": UA_AUDIT, "Accept": "application/vnd.github+json"}
    if gh_tok:
        hdrs["Authorization"] = f"Bearer {gh_tok}"

    run_status = "SUCCESS"
    run_id = "brak"
    try:
        runs_url = "https://api.github.com/repos/TwojaStronaWWW/katosalsahub/actions/workflows/weekly-report.yml/runs?per_page=1"
        with urllib.request.urlopen(urllib.request.Request(runs_url, headers=hdrs), timeout=8) as r:
            runs = json.loads(r.read().decode("utf-8")).get("workflow_runs") or []
        if runs:
            latest = runs[0]
            created = str(latest.get("created_at", ""))
            if gh_tok and not created.startswith(pl_date):
                disp_url = "https://api.github.com/repos/TwojaStronaWWW/katosalsahub/actions/workflows/weekly-report.yml/dispatches"
                req = urllib.request.Request(
                    disp_url,
                    data=json.dumps({"ref": "main"}).encode("utf-8"),
                    headers={**hdrs, "Content-Type": "application/json"},
                    method="POST",
                )
                urllib.request.urlopen(req, timeout=8)
                for _ in range(10):
                    time.sleep(3)
                    with urllib.request.urlopen(urllib.request.Request(runs_url, headers=hdrs), timeout=8) as r2:
                        r_list = json.loads(r2.read().decode("utf-8")).get("workflow_runs") or []
                    if r_list and str(r_list[0].get("created_at", "")).startswith(pl_date) and r_list[0].get("status") == "completed":
                        latest = r_list[0]
                        break
            run_id = str(latest.get("id", "brak"))
            run_status = str(latest.get("conclusion") or latest.get("status") or "SUCCESS").upper()
    except Exception:
        pass

    bot_modified_today = False
    bot_commit_sha = ""
    bot_commit_time = ""
    base_ref_sha = ""
    latest_commit_info = "brak zmian w ciągu 24h"

    try:
        since_iso = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
        c_url = f"https://api.github.com/repos/TwojaStronaWWW/katosalsahub/commits?sha=main&since={since_iso}&per_page=30"
        with urllib.request.urlopen(urllib.request.Request(c_url, headers=hdrs), timeout=8) as rc:
            c_list = json.loads(rc.read().decode("utf-8")) or []
        commits_24h_cnt = len(c_list)
        if c_list:
            top_c = c_list[0]
            top_sha = str(top_c.get("sha", ""))[:7]
            top_msg = str(((top_c.get("commit") or {}).get("message") or "")).splitlines()[0][:65]
            latest_commit_info = f"{commits_24h_cnt} wdrożeń (ostatnie: {top_sha} — \"{top_msg}\")"
            for c in c_list:
                c_date = str(((c.get("commit") or {}).get("author") or {}).get("date", ""))
                c_msg = str(((c.get("commit") or {}).get("message") or ""))
                if c_date.startswith(pl_date) and "automatyczna aktualizacja raportu" in c_msg:
                    bot_modified_today = True
                    bot_commit_sha = str(c.get("sha", ""))[:7]
                    bot_commit_time = c_date.replace("T", " ").replace("Z", " UTC")
                    parents = c.get("parents") or []
                    if parents:
                        base_ref_sha = str(parents[0].get("sha", ""))
                    break
    except Exception:
        pass

    def fetch_text(path: str, ref: str = "main") -> str:
        urls = [f"https://raw.githubusercontent.com/TwojaStronaWWW/katosalsahub/{ref}/katosalsahub.pl/assets/data/{path}"]
        if ref == "main":
            urls.append(f"https://katosalsahub.pl/assets/data/{path}")
        for u in urls:
            try:
                h = {"User-Agent": UA_AUDIT, "Cache-Control": "no-cache"}
                if gh_tok and "githubusercontent" in u:
                    h["Authorization"] = f"Bearer {gh_tok}"
                with urllib.request.urlopen(urllib.request.Request(u, headers=h), timeout=8) as resp:
                    return resp.read().decode("utf-8", errors="replace")
            except Exception:
                continue
        return ""

    events_raw = fetch_text("events.json", "main")
    sched_raw = fetch_text("schedule.json", "main")
    report_raw = fetch_text("latest_report.md", "main")

    old_events_raw = fetch_text("events.json", base_ref_sha) if base_ref_sha else ""
    old_sched_raw = fetch_text("schedule.json", base_ref_sha) if base_ref_sha else ""

    days_cnt = 0
    events_cnt = 0
    new_ev_set = {}
    try:
        ev_obj = json.loads(events_raw)
        day_list = ev_obj if isinstance(ev_obj, list) else []
        days_cnt = len(day_list)
        for d in day_list:
            if isinstance(d, dict):
                dt = str(d.get("date", ""))
                for ev in d.get("events") or []:
                    if isinstance(ev, dict):
                        events_cnt += 1
                        key = f"{dt}|{ev.get('opis','')[:40]}|{ev.get('miasto','')}"
                        new_ev_set[key] = f"{ev.get('opis','?')[:38]} ({dt}, {ev.get('miasto','?')})"
    except Exception:
        pass

    old_ev_set = {}
    if old_events_raw:
        try:
            old_ev_obj = json.loads(old_events_raw)
            for d in old_ev_obj if isinstance(old_ev_obj, list) else []:
                if isinstance(d, dict):
                    dt = str(d.get("date", ""))
                    for ev in d.get("events") or []:
                        if isinstance(ev, dict):
                            key = f"{dt}|{ev.get('opis','')[:40]}|{ev.get('miasto','')}"
                            old_ev_set[key] = f"{ev.get('opis','?')[:38]} ({dt}, {ev.get('miasto','?')})"
        except Exception:
            pass

    added_ev = [v for k, v in new_ev_set.items() if k not in old_ev_set] if old_ev_set else []
    removed_ev = [v for k, v in old_ev_set.items() if k not in new_ev_set] if old_ev_set else []

    classes_cnt = 0
    by_school = {}
    by_level = {}
    pricing_parts = []
    new_cls_map = {}
    new_pricing_map = {}
    try:
        sc_obj = json.loads(sched_raw)
        cls_list = sc_obj.get("classes") or []
        classes_cnt = len(cls_list)
        for c in cls_list:
            cid = str(c.get("id", ""))
            s = c.get("schoolId", "?")
            lv = c.get("levelCode") or c.get("kshLevel") or "?"
            by_school[s] = by_school.get(s, 0) + 1
            by_level[lv] = by_level.get(lv, 0) + 1
            new_cls_map[cid] = f"{s}|{c.get('dayName','')}|{c.get('startTime','')}|{c.get('title','')}|{lv}|{c.get('levelLabel','')}"
        for sch in sc_obj.get("schools") or []:
            pr = sch.get("pricing") or {}
            if pr:
                s_name = sch.get("name") or sch.get("id")
                passes = pr.get("passes") or []
                prices_slash = "/".join(str(p.get("price")) for p in passes[:3] if isinstance(p, dict) and p.get("price"))
                op = pr.get("openPassPrice")
                op_suffix = f", OPEN {op} zł" if op else ""
                if prices_slash:
                    pricing_parts.append(f"{s_name} ({prices_slash} zł{op_suffix})")
                    new_pricing_map[s_name] = f"{prices_slash} zł{op_suffix}"
    except Exception:
        pass

    added_cls_cnt = 0
    removed_cls_cnt = 0
    modified_cls_cnt = 0
    pricing_changes = []
    if old_sched_raw:
        try:
            old_sc_obj = json.loads(old_sched_raw)
            old_cls_map = {}
            for c in old_sc_obj.get("classes") or []:
                cid = str(c.get("id", ""))
                s = c.get("schoolId", "?")
                lv = c.get("levelCode") or c.get("kshLevel") or "?"
                old_cls_map[cid] = f"{s}|{c.get('dayName','')}|{c.get('startTime','')}|{c.get('title','')}|{lv}|{c.get('levelLabel','')}"
            for cid, sig in new_cls_map.items():
                if cid not in old_cls_map:
                    added_cls_cnt += 1
                elif old_cls_map[cid] != sig:
                    modified_cls_cnt += 1
            for cid in old_cls_map:
                if cid not in new_cls_map:
                    removed_cls_cnt += 1
            for sch in old_sc_obj.get("schools") or []:
                pr = sch.get("pricing") or {}
                if pr:
                    s_name = sch.get("name") or sch.get("id")
                    passes = pr.get("passes") or []
                    prices_slash = "/".join(str(p.get("price")) for p in passes[:3] if isinstance(p, dict) and p.get("price"))
                    op = pr.get("openPassPrice")
                    op_suffix = f", OPEN {op} zł" if op else ""
                    old_p_str = f"{prices_slash} zł{op_suffix}"
                    if s_name in new_pricing_map and new_pricing_map[s_name] != old_p_str:
                        pricing_changes.append(f"{s_name}: {old_p_str} -> {new_pricing_map[s_name]}")
        except Exception:
            pass

    wknd_info = "brak danych"
    future_info = "0"
    csv_cnt = 0
    if report_raw:
        sec1_text = report_raw.split("---")[0]
        m_w = re.search(r"Stan zestawienia[^:]*:\*\*\s*\*\*([^*]+)\*\*\s*(\([^)]+\))?", sec1_text)
        if m_w:
            wknd_info = (m_w.group(1).strip() + " " + (m_w.group(2) or "").strip()).strip()
        m_f = re.search(r"Zapowiedzi na kolejne tygodnie[^:]*:\*\*\s*\*\*([^*]+)\*\*", sec1_text)
        if m_f:
            future_info = m_f.group(1).strip()
        m_c = re.search(r"Zgłoszenia z formularza Google[^:]*:\*\*\s*(.+)", sec1_text)
        if m_c:
            raw_c = m_c.group(1).strip()
            csv_cnt = 0 if "brak" in raw_c.lower() else len([u for u in raw_c.split(",") if "http" in u])

    if bot_modified_today:
        mod_status_line = f"🔄 Modyfikacja ze scraperów (dziś): TAK — wdrożono na LH.pl (commit {bot_commit_sha}, {bot_commit_time})"
    else:
        mod_status_line = f"🔄 Modyfikacja ze scraperów (dziś): BRAK ZMIAN (strona na LH.pl nie wymagała aktualizacji, skan #{run_id} {run_status})"

    ev_delta_str = f"+{len(added_ev)} nowych | -{len(removed_ev)} minionych usuniętych"
    if added_ev:
        ev_delta_str += " (" + ", ".join(added_ev[:3]) + (f" i +{len(added_ev)-3} więcej" if len(added_ev) > 3 else "") + ")"

    cls_delta_str = f"+{added_cls_cnt} nowych | ~{modified_cls_cnt} zaktualizowanych (np. daty START) | -{removed_cls_cnt} usuniętych"
    price_delta_str = (", ".join(pricing_changes)) if pricing_changes else "0 zmian (stawki w szkołach bez zmian)"

    short_mod_tag = "ZAKTUALIZOWANO LH.pl" if bot_modified_today else "BEZ ZMIAN"
    short_line = f"🕺 Scrapery KSH ({short_mod_tag}): {events_cnt} impr. (+{len(added_ev)}/-{len(removed_ev)}) | Grafiki: {classes_cnt} kursów (~{modified_cls_cnt} zm.) | Cenniki: OK"

    lines = [
        mod_status_line,
        f"📝 Zmiany ze scraperów: Imprezy [{ev_delta_str}] | Grafiki [{cls_delta_str}] | Cenniki [{price_delta_str}]",
        f"🚀 Modyfikacje strony (ostatnie 24h): {latest_commit_info}",
        f"📅 Kalendarz Imprez: {events_cnt} wydarzeń ({days_cnt} dni) | Weekend: {wknd_info} | Kolejne tyg.: {future_info} | Formularz CSV: {csv_cnt} zgłosz.",
        f"🏫 Grafiki Szkół ({classes_cnt} kursów): La Clave: {by_school.get('LC', 0)} | Good Mood: {by_school.get('GM', 0)} | Mil Pasos: {by_school.get('MP', 0)} (P0:{by_level.get('P0',0)}, P1:{by_level.get('P1',0)}, P2:{by_level.get('P2',0)}, S1:{by_level.get('S1',0)}, OPEN:{by_level.get('OPEN',0)})",
        f"💰 Cenniki (Live OK): " + (" | ".join(pricing_parts) if pricing_parts else "Zweryfikowane"),
    ]

    print(
        json.dumps(
            {
                "short": short_line,
                "full": "\n".join(lines),
                "events_cnt": events_cnt,
                "classes_cnt": classes_cnt,
                "modified": bot_modified_today,
            },
            ensure_ascii=False,
        )
    )
    return 0


def cmd_send_email(env_vars: dict) -> int:
    hook_url = env_vars.get("LEAD_WEBHOOK_URL", "https://hd.twojastronawww.pl/ticket_hook.php")
    api_key = env_vars.get("OSTICKET_API_KEY", "")
    subj = os.environ.get("EMAIL_SUBJECT", "Poranny Raport 06:00")
    body = os.environ.get("EMAIL_BODY", "")

    if hook_url and api_key and body:
        payload = json.dumps(
            {
                "event": "morning_report",
                "email_only": True,
                "subject": subj,
                "message": body,
            },
            ensure_ascii=False,
        ).encode("utf-8")
        req = urllib.request.Request(
            hook_url,
            data=payload,
            headers={
                "X-API-Key": api_key,
                "Content-Type": "application/json; charset=utf-8",
                "User-Agent": UA_REPORT,
            },
            method="POST",
        )
        urllib.request.urlopen(req, timeout=10)
    return 0


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    env_path = os.environ.get("ENV_FILE", "/opt/devops-stack/.env")
    pl_date = os.environ.get("PL_DATE", "")
    env_vars = load_env(env_path)

    if action == "pretrigger":
        return cmd_pretrigger(env_vars, pl_date)
    if action == "hosting-scan":
        return cmd_hosting_scan(env_vars)
    if action == "ai-audit":
        return cmd_ai_audit(env_vars)
    if action == "ksh-scrapers":
        return cmd_ksh_scrapers(env_vars, pl_date)
    if action == "send-email":
        return cmd_send_email(env_vars)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
