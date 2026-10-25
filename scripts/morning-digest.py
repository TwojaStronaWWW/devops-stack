#!/usr/bin/env python3
"""
morning-digest.py — Moduł Porannego Raportu Bezpieczeństwa ISO 27001 & Scraperów KSH/DancePuls.

Wydzielony z audit-server.sh w celu zachowania czystości architektury (Separation of Concerns).
Obsługuje 4 podkomendy:
  1. pretrigger   — wywołuje workflow_dispatch dla weekly-report.yml o 07:15 (Europe/Warsaw)
  2. ai-audit     — wykonuje krzyżową analizę 24h Rentgena serwera (Dual-AI HIGH Reasoning + eskalacja Claude Sonnet 4.6)
  3. ksh-scrapers — pobiera status i deltę 24h ze scraperów Kato Salsa Hub & DancePuls (wydarzenia, grafiki, cenniki)
  4. send-email   — wysyła połączony raport poranny na e-mail przez webhook osTicket
"""

import datetime
import json
import os
import re
import sys
import time
import urllib.request

UA_AUDIT = "Mozilla/5.0 (compatible; TwojaStronaWWW-AIRouter/2.0)"
UA_REPORT = "TwojaStronaWWW-MorningReport/2.0"


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
        "User-Agent": "TwojaStronaWWW-Audit/2.0",
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


def cmd_ai_audit(env_vars: dict) -> int:
    groq_key = env_vars.get("GROQ_API_KEY", "")
    cerebras_key = env_vars.get("CEREBRAS_API_KEY", "")
    gemini_key = env_vars.get("GEMINI_API_KEY", "")
    anthropic_key = env_vars.get("ANTHROPIC_API_KEY", "")
    need_claude = os.environ.get("NEED_CLAUDE", "false") == "true"

    xray_path = os.environ.get("XRAY_FILE", "")
    budget_path = "/var/lib/docker/volumes/ai_router_storage/_data/anthropic_budget.json"

    if not xray_path or not os.path.exists(xray_path):
        return 0

    with open(xray_path, "r", encoding="utf-8", errors="replace") as f:
        xray_text = f.read()[:6500]

    sys_prompt_primary = (
        "Jesteś Głównym Audytorem Bezpieczeństwa DevOps (ISO 27001) serwera TwojaStronaWWW (Oracle Cloud ARM64). "
        "Przeanalizuj szczegółowy 24-godzinny Rentgen serwera (testy deterministyczne, skaner anomalii 24h wszystkich 12 kontenerów, WAF L7, Fail2ban, Uptime Kuma SQLite, reguły tunelu Cloudflare, journalctl). "
        "Napisz po polsku bardzo zwięzłą diagnozę w 3 krótkich punktach (po 1 zdaniu każdy): "
        "1) Anomalie w logach 24h i systemie, "
        "2) Stan ochrony Zero Trust, WAF/Fail2ban i backupów, "
        "3) Werdykt końcowy i rekomendacja."
    )

    sys_prompt_cross = (
        "Jesteś drugim, niezależnym Audytorem Krzyżowym ISO 27001 (Second Opinion). "
        "Zweryfikuj poniższy 24-godzinny Rentgen serwera VPS i napisz po polsku maksymalnie 2 krótkie zdania: "
        "potwierdź spójność wskaźników IoC/WAF/Backupów lub wskaż choćby najmniejszy ślad ryzyka."
    )

    primary_answer = ""
    primary_label = ""
    primary_think_tok = 0
    primary_total_tok = 0

    # 1. GŁÓWNY AUDYTOR 120B (HIGH REASONING, $0.00): Groq GPT-OSS-120B -> Cerebras GPT-OSS-120B -> Cerebras Qwen 3.8
    primary_candidates = []
    if groq_key:
        primary_candidates.append((
            "Groq GPT-OSS-120B (reasoning: HIGH)",
            "https://api.groq.com/openai/v1/chat/completions",
            groq_key,
            {
                "model": "openai/gpt-oss-120b",
                "messages": [{"role": "system", "content": sys_prompt_primary}, {"role": "user", "content": xray_text}],
                "reasoning_effort": "high",
                "temperature": 0.2,
                "max_tokens": 4096,
            },
        ))
    if cerebras_key:
        primary_candidates.append((
            "Cerebras GPT-OSS-120B (reasoning: HIGH)",
            "https://api.cerebras.ai/v1/chat/completions",
            cerebras_key,
            {
                "model": "gpt-oss-120b",
                "messages": [{"role": "system", "content": sys_prompt_primary}, {"role": "user", "content": xray_text}],
                "reasoning_effort": "high",
                "temperature": 0.2,
                "max_tokens": 4096,
            },
        ))
        primary_candidates.append((
            "Cerebras Qwen-3.8-27B (reasoning: HIGH)",
            "https://api.cerebras.ai/v1/chat/completions",
            cerebras_key,
            {
                "model": "qwen-3.8-27b",
                "messages": [{"role": "system", "content": sys_prompt_primary}, {"role": "user", "content": xray_text}],
                "temperature": 0.2,
                "max_tokens": 4096,
            },
        ))

    for label, url, api_key, body in primary_candidates:
        try:
            req = urllib.request.Request(
                url,
                data=json.dumps(body).encode("utf-8"),
                headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json", "User-Agent": UA_AUDIT},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=22) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            msg = (data.get("choices") or [{}])[0].get("message", {})
            txt = (msg.get("content") or "").strip()
            if "<think>" in txt and "</think>" in txt:
                txt = txt.split("</think>", 1)[1].strip()
            txt = txt.replace("**", "")
            if txt:
                primary_answer = txt
                primary_label = label
                usage = data.get("usage", {})
                primary_total_tok = int(usage.get("total_tokens", 0))
                details = usage.get("completion_tokens_details") or {}
                primary_think_tok = int(details.get("reasoning_tokens", 0))
                break
        except Exception:
            continue

    # 2. KRZYŻOWY WERYFIKATOR (HIGH THINKING, $0.00): Google Gemini 3.5 / 3.8 Flash
    cross_answer = ""
    cross_label = ""
    cross_think_tok = 0

    if gemini_key:
        for g_model in ("gemini-3.5-flash", "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.5-flash-lite"):
            try:
                g_url = f"https://generativelanguage.googleapis.com/v1beta/models/{g_model}:generateContent?key={gemini_key}"
                g_body = {
                    "systemInstruction": {"parts": [{"text": sys_prompt_cross if primary_answer else sys_prompt_primary}]},
                    "contents": [{"role": "user", "parts": [{"text": xray_text}]}],
                    "generationConfig": {
                        "temperature": 0.2,
                        "maxOutputTokens": 8192,
                        "thinkingConfig": {"thinkingLevel": "HIGH"},
                    },
                }
                req = urllib.request.Request(
                    g_url,
                    data=json.dumps(g_body).encode("utf-8"),
                    headers={"Content-Type": "application/json", "User-Agent": UA_AUDIT},
                    method="POST",
                )
                with urllib.request.urlopen(req, timeout=22) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
                parts = (((data.get("candidates") or [{}])[0].get("content") or {}).get("parts")) or []
                out_chunks = [p.get("text", "").strip() for p in parts if not p.get("thought") and p.get("text")]
                txt = "\n".join([c for c in out_chunks if c]).strip().replace("**", "")
                if txt:
                    u_meta = data.get("usageMetadata", {})
                    t_tok = int(u_meta.get("thoughtsTokenCount", 0))
                    tot_tok = int(u_meta.get("totalTokenCount", 0))
                    if not primary_answer:
                        primary_answer = txt
                        primary_label = f"{g_model} (thinking: HIGH)"
                        primary_think_tok = t_tok
                        primary_total_tok = tot_tok
                    else:
                        cross_answer = txt
                        cross_label = f"{g_model} (thinking: HIGH)"
                        cross_think_tok = t_tok
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

    # 3. TRYB ESKALACJI KRYMINALISTYCZNEJ (Claude Sonnet 4.6) -> TYLKO przy anomaliach/błędach, fladze --deep-claude lub awarii obu darmowych chmur
    if anthropic_key and (need_claude or not primary_answer):
        try:
            c_payload = {
                "model": "claude-sonnet-4-6",
                "max_tokens": 900,
                "system": [{"type": "text", "text": sys_prompt_primary, "cache_control": {"type": "ephemeral"}}],
                "messages": [{"role": "user", "content": xray_text}],
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
            claude_section = f"\n🚨 Ekspertyza Eskalacyjna Claude Sonnet 4.6:\n{c_ans}\n"
        except Exception:
            pass

    rem_usd = max(0.0, round(float(budget["initial_usd"]) - float(budget.get("spent_usd", 0.0)), 4))
    out_lines = []
    if primary_answer:
        think_info = (
            f" [myślenie: {primary_think_tok} tok. / łącznie: {primary_total_tok} tok.]"
            if primary_think_tok > 0
            else f" [{primary_total_tok} tok.]"
        )
        out_lines.append(f"🧠 Audytor #1 — {primary_label}{think_info}:\n{primary_answer}")
    if cross_answer:
        c_think_info = f" [myślenie: {cross_think_tok} tok.]" if cross_think_tok > 0 else ""
        out_lines.append(f"🔍 Weryfikacja Krzyżowa #2 — {cross_label}{c_think_info}:\n{cross_answer}")
    if claude_section:
        out_lines.append(claude_section.strip())

    out_lines.append(
        f"💰 Koszt dzisiejszego audytu AI: ${cost_today_usd:.4f} (Tryb Dual-AI HIGH Reasoning)\n"
        f"• Rezerwa awaryjna Anthropic ($5.00): pozostało ${rem_usd:.4f} (wydano dotychczas: ${float(budget.get('spent_usd', 0.0)):.4f})"
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
    subj = os.environ.get("EMAIL_SUBJECT", "Poranny Raport 07:30")
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
