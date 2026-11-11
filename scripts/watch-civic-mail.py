#!/usr/bin/env python3
"""
watch-civic-mail.py — Nasłuch 24/7 IMAP4_SSL i Strażnik Terminów 14 Dni UDIP
dla skrzynki obywatelskiej wspolnekamienice.pl (LH.pl -> Ntfy + Prometheus).

Zgodność z ISO 27001 / Always Free:
- 100% Python 3 stdlib (brak dodatkowych kontenerów RAM, wykonanie oneshot < 0.5 s).
- Odczyt IMAP w trybie readonly + BODY.PEEK[] (nie narusza flagi nieprzeczytania wiadomości).
- Eksport metryk Prometheus Textfile Collector (civic_mail.prom).
"""

from __future__ import annotations

import datetime as dt
import email
import imaplib
import json
import os
import re
import ssl
import sys
import time
from email.header import decode_header
from email.message import EmailMessage, Message
from pathlib import Path
from typing import Any

EZD_REGEX = re.compile(
    r"\b(?:[A-ZŚŁŻŹĆŃ]{2,5}[.\-/]\d{3,5}[.\-/]\d{1,5}[.\-/]\d{4}(?:[.\-/][A-Z0-9]{1,6})?|WE/\d+/\d{4}/[A-Z0-9]+)\b"
)


def load_env(env_path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if env_path.exists():
        for raw in env_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.strip()
            if len(v) >= 2 and ((v[0] == '"' and v[-1] == '"') or (v[0] == "'" and v[-1] == "'")):
                v = v[1:-1]
            data[k.strip()] = v.replace('\\"', '"')
    for k, v in os.environ.items():
        if k.startswith("CIVIC_MAIL_"):
            data[k] = v
    return data


def decode_hdr(raw_val: str | None) -> str:
    if not raw_val:
        return ""
    out: list[str] = []
    for chunk, enc in decode_header(raw_val):
        if isinstance(chunk, bytes):
            try:
                out.append(chunk.decode(enc or "utf-8", errors="replace"))
            except LookupError:
                out.append(chunk.decode("utf-8", errors="replace"))
        else:
            out.append(str(chunk))
    return "".join(out).strip()


def extract_preview_and_attachments(msg: Message) -> tuple[str, list[str]]:
    texts: list[str] = []
    atts: list[str] = []
    if msg.is_multipart():
        for part in msg.walk():
            cdisp = str(part.get("Content-Disposition") or "")
            fname = part.get_filename()
            ctype = part.get_content_type()
            if fname or "attachment" in cdisp.lower():
                atts.append(decode_hdr(fname) or "zalacznik")
            elif ctype == "text/plain":
                raw = part.get_payload(decode=True) or b""
                cs = part.get_content_charset() or "utf-8"
                try:
                    texts.append(raw.decode(cs, errors="replace"))
                except LookupError:
                    texts.append(raw.decode("utf-8", errors="replace"))
    else:
        raw = msg.get_payload(decode=True) or b""
        cs = msg.get_content_charset() or "utf-8"
        try:
            texts.append(raw.decode(cs, errors="replace"))
        except LookupError:
            texts.append(raw.decode("utf-8", errors="replace"))

    joined = re.sub(r"<[^>]+>", " ", " ".join(texts))
    snippet = " ".join(joined.split())[:260]
    return snippet, atts


def write_prom(prom_path: Path, metrics: dict[str, int | float]) -> None:
    try:
        prom_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = prom_path.with_suffix(".prom.tmp")
        lines = [
            "# HELP devops_civic_mail_configured Whether civic mail IMAP credentials are configured",
            "# TYPE devops_civic_mail_configured gauge",
            f"devops_civic_mail_configured {int(metrics.get('configured', 0))}",
            "# HELP devops_civic_mail_up Whether last IMAP poll succeeded (1=OK, 0=FAIL)",
            "# TYPE devops_civic_mail_up gauge",
            f"devops_civic_mail_up {int(metrics.get('up', 0))}",
            "# HELP devops_civic_mail_messages_total Total messages in civic INBOX",
            "# TYPE devops_civic_mail_messages_total gauge",
            f"devops_civic_mail_messages_total {int(metrics.get('total_messages', 0))}",
            "# HELP devops_civic_mail_unseen_total Unseen messages in civic INBOX",
            "# TYPE devops_civic_mail_unseen_total gauge",
            f"devops_civic_mail_unseen_total {int(metrics.get('unseen_messages', 0))}",
            "# HELP devops_civic_mail_open_cases_total Open UDIP/SM civic cases tracked",
            "# TYPE devops_civic_mail_open_cases_total gauge",
            f"devops_civic_mail_open_cases_total {int(metrics.get('open_cases', 0))}",
            "# HELP devops_civic_mail_overdue_cases_total Overdue civic cases past statutory deadline",
            "# TYPE devops_civic_mail_overdue_cases_total gauge",
            f"devops_civic_mail_overdue_cases_total {int(metrics.get('overdue_cases', 0))}",
            "# HELP devops_civic_mail_last_check_timestamp_seconds Unix timestamp of last check",
            "# TYPE devops_civic_mail_last_check_timestamp_seconds gauge",
            f"devops_civic_mail_last_check_timestamp_seconds {int(time.time())}",
        ]
        tmp_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        tmp_path.replace(prom_path)
    except Exception:
        pass


def check_sla_deadlines(sla_path: Path, state: dict[str, Any]) -> tuple[int, int, list[dict[str, Any]]]:
    if not sla_path.exists():
        return 0, 0, []
    try:
        data = json.loads(sla_path.read_text(encoding="utf-8"))
    except Exception:
        return 0, 0, []

    today = dt.date.today()
    today_iso = today.isoformat()
    alerted: dict[str, str] = state.setdefault("alerted_overdue", {})
    open_cnt = 0
    overdue_cnt = 0
    newly_alerted: list[dict[str, Any]] = []

    for c in data.get("cases") or []:
        if c.get("status") != "OPEN":
            continue
        open_cnt += 1
        try:
            dline = dt.date.fromisoformat(str(c["deadline_date"]))
        except Exception:
            continue
        days_over = (today - dline).days
        if days_over > 0:
            overdue_cnt += 1
            code = str(c.get("case_code", "?"))
            # Przypomnij maksymalnie raz dziennie dla przeterminowanej sprawy
            if alerted.get(code) != today_iso:
                alerted[code] = today_iso
                newly_alerted.append(
                    {
                        "case_code": code,
                        "category": c.get("category", "udip"),
                        "deadline_date": str(c["deadline_date"]),
                        "days_overdue": days_over,
                    }
                )

    return open_cnt, overdue_cnt, newly_alerted


def run_self_test() -> int:
    msg = EmailMessage()
    msg["Subject"] = "Odpowiedź na wniosek NK.0174.14.2026.JS"
    msg["From"] = "KZGM Katowice <poczta@kzgm.katowice.pl>"
    msg.set_content("W załączeniu przekazujemy wykaz 24 kamienic.")
    snippet, atts = extract_preview_and_attachments(msg)
    assert "wykaz 24 kamienic" in snippet
    assert atts == []
    m = EZD_REGEX.search(msg["Subject"])
    assert m is not None and m.group(0) == "NK.0174.14.2026.JS"
    print(json.dumps({"self_test": "OK"}))
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return run_self_test()

    stack_root = Path(os.environ.get("STACK_ROOT", "/opt/devops-stack"))
    env_file = Path(os.environ.get("ENV_FILE", str(stack_root / ".env")))
    prom_file = Path(os.environ.get("PROM_FILE", str(stack_root / "config/node-exporter/civic_mail.prom")))
    state_file = Path(os.environ.get("STATE_FILE", "/var/tmp/devops-civic-mail-state.json"))
    sla_file = Path(os.environ.get("SLA_FILE", "/var/tmp/devops-civic-cases-sla.json"))

    cfg = load_env(env_file)
    addr = cfg.get("CIVIC_MAIL_ADDRESS", "").strip()
    pwd = cfg.get("CIVIC_MAIL_PASSWORD", "").strip()
    imap_host = cfg.get("CIVIC_MAIL_IMAP_HOST", "mail21.lh.pl").strip()
    imap_port = int(cfg.get("CIVIC_MAIL_IMAP_PORT", "993"))

    if not addr or not pwd:
        write_prom(prom_file, {"configured": 0, "up": 1})
        print(json.dumps({"configured": False, "new_messages": [], "overdue_alerts": []}))
        return 0

    state: dict[str, Any] = {}
    if state_file.exists():
        try:
            state = json.loads(state_file.read_text(encoding="utf-8"))
        except Exception:
            state = {}

    open_cnt, overdue_cnt, overdue_alerts = check_sla_deadlines(sla_file, state)
    new_messages: list[dict[str, Any]] = []

    try:
        ctx = ssl.create_default_context()
        with imaplib.IMAP4_SSL(imap_host, imap_port, ssl_context=ctx, timeout=15) as imap:
            imap.login(addr, pwd)
            sel_status, _ = imap.select("INBOX", readonly=True)
            if sel_status != "OK":
                raise RuntimeError("IMAP SELECT INBOX failed")

            uid_val_resp = imap.response("UIDVALIDITY")[1]
            uidvalidity = int(uid_val_resp[0]) if (uid_val_resp and uid_val_resp[0]) else 1

            _, all_data = imap.uid("search", None, "ALL")
            _, unseen_data = imap.uid("search", None, "UNSEEN")
            all_uids = [int(x) for x in all_data[0].split()] if (all_data and all_data[0]) else []
            unseen_cnt = len(unseen_data[0].split()) if (unseen_data and unseen_data[0]) else 0
            max_uid = max(all_uids) if all_uids else 0

            prev_uidval = int(state.get("uidvalidity") or 0)
            prev_last_uid = int(state.get("last_uid") or 0)

            # Pierwsze uruchomienie lub zmiana UIDVALIDITY: inicjalizacja kursora bez spamu historią
            if prev_uidval != uidvalidity or prev_last_uid == 0:
                state["uidvalidity"] = uidvalidity
                state["last_uid"] = max_uid
            elif max_uid > prev_last_uid:
                fresh_uids = [u for u in all_uids if u > prev_last_uid][-10:]
                for u in fresh_uids:
                    f_stat, f_data = imap.uid("fetch", str(u).encode("ascii"), "(BODY.PEEK[])")
                    if f_stat != "OK" or not f_data or not isinstance(f_data[0], tuple):
                        continue
                    parsed = email.message_from_bytes(f_data[0][1])
                    subj = decode_hdr(parsed.get("Subject")) or "(brak tematu)"
                    frm = decode_hdr(parsed.get("From"))
                    snippet, atts = extract_preview_and_attachments(parsed)
                    sig_m = EZD_REGEX.search(f"{subj} {snippet}")
                    new_messages.append(
                        {
                            "uid": u,
                            "from": frm,
                            "subject": subj,
                            "signature": sig_m.group(0) if sig_m else "",
                            "attachments": atts,
                            "snippet": snippet,
                        }
                    )
                state["last_uid"] = max_uid

        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
        os.chmod(state_file, 0o600)

        write_prom(
            prom_file,
            {
                "configured": 1,
                "up": 1,
                "total_messages": len(all_uids),
                "unseen_messages": unseen_cnt,
                "open_cases": open_cnt,
                "overdue_cases": overdue_cnt,
            },
        )
        print(
            json.dumps(
                {
                    "configured": True,
                    "up": True,
                    "mailbox": addr,
                    "total_messages": len(all_uids),
                    "unseen_messages": unseen_cnt,
                    "new_messages": new_messages,
                    "overdue_alerts": overdue_alerts,
                },
                ensure_ascii=False,
            )
        )
        return 0
    except Exception as exc:
        write_prom(
            prom_file,
            {
                "configured": 1,
                "up": 0,
                "open_cases": open_cnt,
                "overdue_cases": overdue_cnt,
            },
        )
        print(json.dumps({"configured": True, "up": False, "error": str(exc)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
