#!/usr/bin/env bash
# ==============================================================================
# sync-freescout-ntfy.sh
# Natychmiastowe powiadomienia Push (0.00 PLN, 100% RODO Self-Hosted Ntfy)
# dla nowych wiadomości przychodzących (threads.type = 1) w centrum poczty FreeScout.
#
# UWAGA OPSEC / BRAK DUPLIKATÓW:
# Skrzynka kontakt@wspolnekamienice.pl jest celowo wykluczona z tego skryptu,
# ponieważ dedykowany strażnik devops-civic-mail.timer (sync-civic-mail.sh)
# wysyła już dla niej bogate powiadomienia z sygnaturą sprawy EZD i zegarem 14 dni UDIP!
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${STACK_ROOT}/.env}"
STATE_FILE="${STATE_FILE:-/var/tmp/devops-freescout-ntfy.state}"
LOCK_FILE="/tmp/devops-freescout-ntfy.lock"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    exit 0
fi

if [[ -f "${ENV_FILE}" ]]; then
    if [[ -z "${NTFY_TOPIC:-}" ]]; then
        NTFY_TOPIC="$(grep -E '^NTFY_TOPIC=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || echo '')"
    fi
    if [[ -z "${NTFY_BASE_URL:-}" ]]; then
        NTFY_BASE_URL="$(grep -E '^NTFY_BASE_URL=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || echo '')"
    fi
    if [[ -z "${NTFY_TOKEN:-}" ]]; then
        NTFY_TOKEN="$(grep -E '^NTFY_TOKEN=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || echo '')"
    fi
fi

if [[ -z "${NTFY_BASE_URL:-}" || "${NTFY_BASE_URL}" == "http://ntfy:8080" ]]; then
    if [[ -n "${NTFY_TOKEN:-}" ]]; then
        NTFY_BASE_URL="http://127.0.0.1:8086"
    else
        NTFY_BASE_URL="https://ntfy.sh"
    fi
fi
NTFY_BASE_URL="${NTFY_BASE_URL%/}"

if ! docker inspect -f '{{.State.Running}}' freescout-db 2>/dev/null | grep -qx "true"; then
    exit 0
fi

RESET_CURSOR=0
if [[ "${1:-}" == "--reset-cursor" ]]; then
    RESET_CURSOR=1
fi

export NTFY_TOPIC="${NTFY_TOPIC:-}"
export NTFY_BASE_URL
export NTFY_TOKEN="${NTFY_TOKEN:-}"
export STATE_FILE
export RESET_CURSOR

python3 - <<'PY'
import json
import os
import subprocess
import sys
import urllib.request

state_file = os.environ.get("STATE_FILE", "/var/tmp/devops-freescout-ntfy.state")
reset_cursor = os.environ.get("RESET_CURSOR", "0") == "1"
ntfy_base = os.environ.get("NTFY_BASE_URL", "https://ntfy.sh").rstrip("/")
ntfy_topic = os.environ.get("NTFY_TOPIC", "").strip()
ntfy_token = os.environ.get("NTFY_TOKEN", "").strip()


def run_mariadb_sql(sql: str) -> str:
    cmd = [
        "docker",
        "exec",
        "-i",
        "freescout-db",
        "sh",
        "-c",
        'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u "$MARIADB_USER" -D "$MARIADB_DATABASE" --default-character-set=utf8mb4 -N -B',
    ]
    res = subprocess.run(cmd, input=sql, capture_output=True, text=True, timeout=15, check=False)
    if res.returncode != 0:
        return ""
    return res.stdout.strip()


def save_state(tid: int) -> None:
    tmp_path = f"{state_file}.{os.getpid()}.tmp"
    old_umask = os.umask(0o077)
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.write(f"{tid}\n")
        os.replace(tmp_path, state_file)
    finally:
        os.umask(old_umask)


# Sprawdzenie czy tabela threads już istnieje (po migracji FreeScout) oraz czy skonfigurowano skrzynki
tbl_chk = run_mariadb_sql("SHOW TABLES LIKE 'threads';")
if not tbl_chk:
    sys.exit(0)

mb_cnt_raw = run_mariadb_sql("SELECT COUNT(*) FROM mailboxes;")
try:
    mb_cnt = int((mb_cnt_raw or "0").splitlines()[0].strip())
except ValueError:
    mb_cnt = 0
if mb_cnt == 0:
    sys.exit(0)

# Pierwsze uruchomienie lub jawny --reset-cursor po imporcie IMAP: inicjalizacja kursora na aktualnym MAX(id)
if reset_cursor or not os.path.exists(state_file):
    max_raw = run_mariadb_sql("SELECT COALESCE(MAX(id), 0) FROM threads;")
    try:
        cur_max = int((max_raw or "0").splitlines()[0].strip())
    except ValueError:
        cur_max = 0
    save_state(cur_max)
    sys.exit(0)

try:
    with open(state_file, "r", encoding="utf-8") as sf:
        last_id = int(sf.read().strip() or "0")
except Exception:
    last_id = 0

# Wykrycie dostępnych kolumn w threads i conversations dla 100% kompatybilności schematu
cols_raw = run_mariadb_sql(
    "SELECT CONCAT(TABLE_NAME, '.', COLUMN_NAME) FROM INFORMATION_SCHEMA.COLUMNS "
    "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN ('threads', 'conversations');"
)
col_set = set(cols_raw.splitlines()) if cols_raw else set()

sender_parts = []
if "threads.from" in col_set:
    sender_parts.append("NULLIF(t.`from`, '')")
if "conversations.customer_email" in col_set:
    sender_parts.append("NULLIF(c.customer_email, '')")
sender_expr = f"COALESCE({', '.join(sender_parts)}, 'Nieznany nadawca')" if sender_parts else "'Nieznany nadawca'"
preview_expr = "LEFT(REPLACE(REPLACE(COALESCE(c.preview, ''), '\\r', ' '), '\\n', ' '), 160)" if "conversations.preview" in col_set else "''"

query = f"""
SELECT JSON_OBJECT(
    'id', t.id,
    'mailbox_email', COALESCE(m.email, ''),
    'mailbox_name', COALESCE(m.name, ''),
    'subject', COALESCE(c.subject, '(brak tematu)'),
    'sender', {sender_expr},
    'preview', {preview_expr},
    'is_recent', IF(t.created_at >= UTC_TIMESTAMP() - INTERVAL 24 HOUR, 1, 0)
)
FROM threads t
INNER JOIN conversations c ON c.id = t.conversation_id
INNER JOIN mailboxes m ON m.id = c.mailbox_id
WHERE t.id > {int(last_id)}
  AND t.type = 1
  AND t.state = 2
ORDER BY t.id ASC
LIMIT 50;
"""

rows_raw = run_mariadb_sql(query)
if not rows_raw:
    sys.exit(0)


def resolve_badge(email_addr: str, mb_name: str) -> str:
    el = email_addr.lower().strip()
    if el == "kontakt@katosalsahub.pl":
        return "[KatoSalsaHub]"
    if el == "kontakt@twojastronawww.pl":
        return "[TwojaStronaWWW]"
    if el == "kontakt@wspolnekamienice.pl":
        return "[Wspólne Kamienice]"
    if el == "krzysztof.poczatek@maxbit.com.pl" or el.endswith("@maxbit.com.pl"):
        return "[Maxbit]"
    if el.endswith("@ik.me") or "audyt" in el:
        return "[Audyt ik.me]"
    return f"[{mb_name or email_addr}]"


def sanitize_header(val: str) -> str:
    # Nagłówki HTTP (RFC 7230) wymagają czystego ASCII lub kodowania — używamy czystego ASCII dla Title, a pełne UTF-8 w body
    clean = val.replace("\r", " ").replace("\n", " ").strip()
    ascii_map = str.maketrans("ąćęłńóśźżĄĆĘŁŃÓŚŹŻ—–", "acelnoszzACELNOSZZ--")
    return clean.translate(ascii_map).encode("ascii", "ignore").decode("ascii")[:120]


new_last_id = last_id
for line in rows_raw.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        item = json.loads(line)
    except Exception:
        continue

    tid = int(item.get("id") or 0)
    if tid > new_last_id:
        new_last_id = tid

    mb_email = str(item.get("mailbox_email") or "").strip()
    # Wykluczenie kontakt@wspolnekamienice.pl: devops-civic-mail.timer (sync-civic-mail.sh)
    # wysyła już dla tej skrzynki wzbogacone powiadomienia z sygnaturą EZD i zegarem 14 dni UDIP!
    if mb_email.lower() == "kontakt@wspolnekamienice.pl":
        continue

    # Ochrona przed powiadamianiem o historycznych mailach (starszych niż 24h) przy podpinaniu nowej skrzynki IMAP
    if int(item.get("is_recent") or 0) != 1:
        continue

    if not ntfy_topic or ntfy_topic == "twojastronawww-alerty-prod":
        continue

    badge = resolve_badge(mb_email, str(item.get("mailbox_name") or ""))
    sender = str(item.get("sender") or "Nieznany nadawca").strip()
    subject = str(item.get("subject") or "(brak tematu)").strip()
    preview = str(item.get("preview") or "").strip()

    title_hdr = sanitize_header(f"Nowy e-mail {badge}: {subject}")
    body_lines = [
        f"Skrzynka: {badge} ({mb_email})",
        f"Od: {sender}",
        f"Temat: {subject}",
    ]
    if preview:
        body_lines.append(f"Podgląd: {preview}")

    headers = {
        "Title": title_hdr,
        "Priority": "default",
        "Tags": "incoming_envelope",
        "Content-Type": "text/plain; charset=utf-8",
    }
    if ntfy_token:
        headers["Authorization"] = f"Bearer {ntfy_token}"

    try:
        req = urllib.request.Request(
            f"{ntfy_base}/{ntfy_topic}",
            data="\n".join(body_lines).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=8):
            pass
    except Exception:
        # Nie przesuwamy kursora powyżej niedostarczonej wiadomości, aby ponowić próbę przy kolejnym cyklu
        sys.exit(0)

if new_last_id > last_id:
    save_state(new_last_id)
PY
