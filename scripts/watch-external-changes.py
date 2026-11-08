#!/usr/bin/env python3
"""
watch-external-changes.py
Lightweight Change Detection Radar (CeZ P1/e-Zdrowie, KSeF, NFZ, LH.pl, NGO Katowice).

Architektura:
- 100% Python Standard Library (urllib.request, ssl, hashlib, difflib, json, re, html.parser, os, sys, time)
- Bezpieczne pobieranie HTTPS z weryfikacją certyfikatu TLS (ssl.create_default_context()),
  limitem rozmiaru odpowiedzi 2 MB (MAX_BYTES = 2_097_152) oraz timeoutem 12s.
- Ekstrakcja i normalizacja czystego tekstu z HTML (usunięcie <script>, <style>, <noscript>, <svg>,
  komentarzy HTML oraz dynamicznych tokenów CSRF / znaczników czasu).
- Atomowy zapis stanu (STATE_FILE) oraz metryk Prometheus Textfile Collector (PROM_FILE)
  metodą .tmp -> os.replace.
- Obsługa flagi --self-test (weryfikacja w pamięci bez zapytań sieciowych -> SELF_TEST_OK).
"""

import difflib
import hashlib
import html
import html.parser
import json
import os
import re
import ssl
import sys
import tempfile
import time
import urllib.error
import urllib.request

MAX_BYTES = 2 * 1024 * 1024  # Limit 2 MB
DEFAULT_TIMEOUT = 12.0       # Timeout 12 sekund
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 "
    "TwojaStronaWWW-ChangeRadar/1.0"
)

ALWAYS_STRIP_TAGS = {"script", "style", "noscript", "svg", "template", "iframe", "head"}
BLOCK_TAGS = {
    "p", "div", "li", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6",
    "article", "section", "main", "header", "footer", "nav", "aside", "br", "hr",
    "blockquote", "pre", "dt", "dd"
}

DEFAULT_IGNORE_PATTERNS = [
    r"(?i)csrf[_-]?token[^\n]*",
    r"(?i)__RequestVerificationToken[^\n]*",
    r"(?i)__VIEWSTATE[^\n]*",
    r"(?i)__EVENTVALIDATION[^\n]*",
    r"\b\d{2}:\d{2}:\d{2}\b",
    r"(?i)(licznik|odwiedzin|wyświetleń|odsłon|online)\s*[:=]?\s*\d+",
    r"(?i)(session[_-]?id|phpsessid|cf_ray)\s*[:=][^\s]+",
]


class NormalizedHTMLParser(html.parser.HTMLParser):
    """Parser HTML wycinający znaczniki techniczne (<script>, <style>, <noscript>, <svg>) i komentarze."""

    def __init__(self, extra_strip_tags=None):
        super().__init__(convert_charrefs=True)
        self.strip_tags = set(ALWAYS_STRIP_TAGS)
        if extra_strip_tags:
            for tag in extra_strip_tags:
                t = str(tag).strip().lower()
                if t and t not in ("main", "article", "section", "body", "html", "div", "table"):
                    self.strip_tags.add(t)
        self._skip_stack = []
        self._chunks = []

    def handle_starttag(self, tag, attrs):
        t = tag.lower()
        if t in self.strip_tags:
            self._skip_stack.append(t)
            return
        if not self._skip_stack and t in BLOCK_TAGS:
            self._chunks.append("\n")

    def handle_endtag(self, tag):
        t = tag.lower()
        if self._skip_stack and t in self.strip_tags:
            if self._skip_stack[-1] == t:
                self._skip_stack.pop()
            elif t in self._skip_stack:
                self._skip_stack.remove(t)
            return
        if not self._skip_stack and t in BLOCK_TAGS:
            self._chunks.append("\n")

    def handle_data(self, data):
        if not self._skip_stack and data:
            self._chunks.append(data)

    def handle_comment(self, data):
        # Komentarze HTML są całkowicie ignorowane
        pass

    def get_text(self):
        return "".join(self._chunks)


def write_file_atomic(target_path, content, mode=0o644):
    """Zapisuje plik metodą atomową (.tmp -> os.replace)."""
    parent_dir = os.path.dirname(os.path.abspath(target_path))
    if parent_dir:
        os.makedirs(parent_dir, exist_ok=True)
    tmp_path = f"{target_path}.{os.getpid()}.tmp"
    try:
        with open(tmp_path, "w", encoding="utf-8", newline="\n") as tf:
            tf.write(content)
        os.replace(tmp_path, target_path)
        if mode is not None:
            try:
                os.chmod(target_path, mode)
            except OSError:
                pass
    finally:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass


def _strip_html_comments_and_noise_tags(raw_html):
    """Wstępne oczyszczenie komentarzy HTML oraz bloków script/style/noscript/svg."""
    cleaned = re.sub(r"(?is)<!--.*?-->", " ", raw_html)
    cleaned = re.sub(r"(?is)<(script|style|noscript|svg)\b[^>]*>.*?</\1>", " ", cleaned)
    return cleaned


def extract_normalized_lines(raw_html, target_cfg=None):
    """
    Wyodrębnia czysty, znormalizowany tekst z dokumentu HTML:
    1. Usuwa <script>, <style>, <noscript>, <svg> oraz komentarze HTML.
    2. Jeśli podano extract_regex i dopasowanie zwraca treść, ekstrahuje sekcję docelową
       (z bezpiecznym fallbackiem do pełnego dokumentu).
    3. Odfiltrowuje dynamiczne znaczniki czasu, tokeny CSRF i wzorce z ignore_patterns.
    4. Zwraca listę znormalizowanych linii tekstu oraz skrót SHA-256.
    """
    target_cfg = target_cfg or {}
    if not raw_html:
        return [], hashlib.sha256(b"").hexdigest()

    pre_cleaned = _strip_html_comments_and_noise_tags(raw_html)
    candidate_html = pre_cleaned

    extract_regex = target_cfg.get("extract_regex")
    if extract_regex:
        try:
            matches = list(re.finditer(extract_regex, pre_cleaned))
            if matches:
                extracted_parts = []
                for m in matches:
                    groups = [g for g in m.groups() if g is not None]
                    extracted_parts.append(" ".join(groups) if groups else m.group(0))
                joined = "\n".join(extracted_parts)
                if len(joined.strip()) >= 32:
                    candidate_html = joined
        except re.error:
            pass

    strip_selectors = target_cfg.get("strip_selectors") or []
    parser = NormalizedHTMLParser(extra_strip_tags=strip_selectors)
    try:
        parser.feed(candidate_html)
        parser.close()
        text = parser.get_text()
    except Exception:
        text = re.sub(r"(?is)<[^>]+>", "\n", candidate_html)

    # Fallback jeśli po wycięciu nav/footer/header zostało zbyt mało tekstu (np. nietypowy szablon strony)
    if len(text.strip()) < 32 and candidate_html != pre_cleaned:
        fallback_parser = NormalizedHTMLParser(extra_strip_tags=[])
        try:
            fallback_parser.feed(pre_cleaned)
            fallback_parser.close()
            text = fallback_parser.get_text()
        except Exception:
            text = re.sub(r"(?is)<[^>]+>", "\n", pre_cleaned)

    text = html.unescape(text)

    compiled_ignores = []
    for pat in DEFAULT_IGNORE_PATTERNS + list(target_cfg.get("ignore_patterns") or []):
        try:
            compiled_ignores.append(re.compile(pat))
        except re.error:
            pass

    normalized_lines = []
    prev_line = None
    for raw_line in text.splitlines():
        line = raw_line
        for creg in compiled_ignores:
            line = creg.sub("", line)
        line = re.sub(r"[ \t\r\f\v]+", " ", line).strip()
        if not line:
            continue
        if line == prev_line:
            continue
        normalized_lines.append(line)
        prev_line = line

    canonical_payload = "\n".join(normalized_lines).encode("utf-8")
    digest = hashlib.sha256(canonical_payload).hexdigest()
    return normalized_lines, digest


def compute_diff_summary(old_lines, new_lines, max_lines=15):
    """
    Generuje czytelny skrót zmian (difflib.unified_diff — dodane linie '+' i usunięte '-',
    maksymalnie max_lines najważniejszych linii).
    """
    diff_iter = difflib.unified_diff(
        old_lines or [],
        new_lines or [],
        fromfile="previous",
        tofile="current",
        lineterm="",
        n=0,
    )
    meaningful = []
    for line in diff_iter:
        if line.startswith("---") or line.startswith("+++") or line.startswith("@@"):
            continue
        if line.startswith("+") or line.startswith("-"):
            trimmed = line[:240]
            meaningful.append(trimmed)
            if len(meaningful) >= max_lines:
                break
    return meaningful


def fetch_url_safely(url, timeout=DEFAULT_TIMEOUT, max_bytes=MAX_BYTES):
    """
    Pobiera stronę z weryfikacją certyfikatu TLS (ssl.create_default_context()),
    nagłówkiem User-Agent, limitem rozmiaru max 2 MB i timeoutem 12s.
    """
    ctx = ssl.create_default_context()
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "pl-PL,pl;q=0.9,en-US;q=0.8,en;q=0.7",
            "Cache-Control": "no-cache",
        },
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        status = getattr(resp, "status", 200)
        raw_bytes = resp.read(max_bytes)
        charset = "utf-8"
        try:
            content_type = resp.headers.get_content_charset()
            if content_type:
                charset = content_type
        except Exception:
            pass
        body = raw_bytes.decode(charset, errors="replace")
        return status, body


def _prom_escape(val):
    return str(val).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def build_prometheus_metrics(status_ok, targets_total, changes_detected_total, target_metrics, now_ts):
    """Buduje zawartość pliku config/node-exporter/change_radar.prom."""
    lines = [
        "# HELP devops_change_radar_status Status przebiegu Radaru Zmian Zewnetrznych (1=OK, 0=blad).",
        "# TYPE devops_change_radar_status gauge",
        f"devops_change_radar_status {1 if status_ok else 0}",
        "# HELP devops_change_radar_targets_total Liczba aktywnych celow monitorowanych przez Radar Zmian.",
        "# TYPE devops_change_radar_targets_total gauge",
        f"devops_change_radar_targets_total {int(targets_total)}",
        "# HELP devops_change_radar_changes_detected_total Liczba wykrytych zmian w ostatnim przebiegu.",
        "# TYPE devops_change_radar_changes_detected_total gauge",
        f"devops_change_radar_changes_detected_total {int(changes_detected_total)}",
        "# HELP devops_change_radar_target_up Dostepnosc monitorowanego celu zewnetrznego (1=UP, 0=DOWN).",
        "# TYPE devops_change_radar_target_up gauge",
    ]
    for tm in target_metrics:
        tid = _prom_escape(tm["id"])
        cat = _prom_escape(tm["category"])
        up_val = 1 if tm.get("up") else 0
        lines.append(f'devops_change_radar_target_up{{id="{tid}",category="{cat}"}} {up_val}')

    lines.extend([
        "# HELP devops_change_radar_target_last_change_timestamp_seconds Znacznik czasu ostatniej wykrytej zmiany na celu.",
        "# TYPE devops_change_radar_target_last_change_timestamp_seconds gauge",
    ])
    for tm in target_metrics:
        tid = _prom_escape(tm["id"])
        cat = _prom_escape(tm["category"])
        last_chg = int(tm.get("last_change_ts") or 0)
        lines.append(
            f'devops_change_radar_target_last_change_timestamp_seconds{{id="{tid}",category="{cat}"}} {last_chg}'
        )

    lines.extend([
        "# HELP devops_change_radar_last_run_timestamp_seconds Znacznik czasu ostatniego uruchomienia Radaru Zmian.",
        "# TYPE devops_change_radar_last_run_timestamp_seconds gauge",
        f"devops_change_radar_last_run_timestamp_seconds {int(now_ts)}",
    ])
    return "\n".join(lines) + "\n"


def resolve_default_state_file():
    env_state = os.environ.get("STATE_FILE")
    if env_state:
        return env_state
    var_tmp = "/var/tmp"
    if os.path.isdir(var_tmp) and os.access(var_tmp, os.W_OK):
        return "/var/tmp/devops-change-radar-state.json"
    return os.path.join(tempfile.gettempdir(), "devops-change-radar-state.json")


def resolve_default_report_file():
    env_report = os.environ.get("REPORT_FILE")
    if env_report:
        return env_report
    var_tmp = "/var/tmp"
    if os.path.isdir(var_tmp) and os.access(var_tmp, os.W_OK):
        return "/var/tmp/devops-change-radar-report.json"
    return os.path.join(tempfile.gettempdir(), "devops-change-radar-report.json")


def run_self_test():
    """
    Testuje w pamięci (bez zapytań sieciowych):
    1. Parser HTML, usuwanie <script>, <style>, <noscript>, <svg>, komentarzy HTML i tokenów CSRF/czasu.
    2. Normalizację tekstu i wyliczanie SHA-256.
    3. Wykrywanie diffu (difflib.unified_diff, max 15 linii).
    4. Generowanie i atomowy zapis metryk Prometheus (.prom).
    """
    sample_html_v1 = """
    <!DOCTYPE html>
    <html>
    <head>
        <title>Test Komunikaty</title>
        <style>body { color: red; }</style>
        <script>console.log("secret token 123");</script>
    </head>
    <body>
        <!-- Dynamiczny komentarz build 998877 -->
        <noscript>Włącz obsługę JS</noscript>
        <svg><path d="M0 0"/></svg>
        <main>
            <h1>Komunikaty techniczne CeZ P1</h1>
            <p>Komunikat nr 1: Planowane prace serwisowe e-Recepty.</p>
            <p>csrf_token: abcdef1234567890</p>
            <p>Godzina generowania: 14:22:09</p>
            <p>Licznik odwiedzin: 4512</p>
        </main>
    </body>
    </html>
    """

    sample_html_v2 = """
    <!DOCTYPE html>
    <html>
    <head>
        <title>Test Komunikaty</title>
        <script>console.log("zmieniony skrypt 999");</script>
    </head>
    <body>
        <!-- Inny komentarz -->
        <main>
            <h1>Komunikaty techniczne CeZ P1</h1>
            <p>Komunikat nr 2: Nowa wersja walidatora HL7 CDA 1.3.2.</p>
            <p>csrf_token: 9999999999999999</p>
            <p>Godzina generowania: 18:05:55</p>
            <p>Licznik odwiedzin: 9981</p>
        </main>
    </body>
    </html>
    """

    cfg = {
        "id": "cez-ezdrowie-komunikaty",
        "category": "his_med",
        "extract_regex": r"(?is)<main\b[^>]*>(.*?)</main>",
        "strip_selectors": ["script", "style", "noscript", "svg"],
        "ignore_patterns": [r"(?i)csrf[_-]?token[^\n]*"],
    }

    lines_v1, sha_v1 = extract_normalized_lines(sample_html_v1, cfg)
    lines_v1_repeat, sha_v1_repeat = extract_normalized_lines(
        sample_html_v1.replace("14:22:09", "23:59:59").replace("4512", "5000"),
        cfg,
    )
    assert sha_v1 == sha_v1_repeat, "Szum dynamiczny (czas/licznik) nie powinien zmieniać skrótu SHA-256"
    assert any("Komunikat nr 1" in ln for ln in lines_v1), "Brak oczekiwanej treści głównej w v1"
    assert not any("console.log" in ln for ln in lines_v1), "Wyciek zawartości <script>"
    assert not any("color: red" in ln for ln in lines_v1), "Wyciek zawartości <style>"

    lines_v2, sha_v2 = extract_normalized_lines(sample_html_v2, cfg)
    assert sha_v1 != sha_v2, "Zmiana merytoryczna powinna zmienić skrót SHA-256"

    diff = compute_diff_summary(lines_v1, lines_v2, max_lines=15)
    assert any(d.startswith("-") and "Komunikat nr 1" in d for d in diff), "Brak usuniętej linii w diffie"
    assert any(d.startswith("+") and "Komunikat nr 2" in d for d in diff), "Brak dodanej linii w diffie"
    assert len(diff) <= 15, "Przekroczono limit 15 linii diffu"

    now_ts = int(time.time())
    prom_text = build_prometheus_metrics(
        status_ok=True,
        targets_total=6,
        changes_detected_total=1,
        target_metrics=[
            {"id": "cez-ezdrowie-komunikaty", "category": "his_med", "up": 1, "last_change_ts": now_ts}
        ],
        now_ts=now_ts,
    )
    required_metrics = [
        "devops_change_radar_status 1",
        "devops_change_radar_targets_total 6",
        "devops_change_radar_changes_detected_total 1",
        'devops_change_radar_target_up{id="cez-ezdrowie-komunikaty",category="his_med"} 1',
        f'devops_change_radar_target_last_change_timestamp_seconds{{id="cez-ezdrowie-komunikaty",category="his_med"}} {now_ts}',
        f"devops_change_radar_last_run_timestamp_seconds {now_ts}",
    ]
    for req_m in required_metrics:
        assert req_m in prom_text, f"Brak wymaganej metryki Prometheus: {req_m}"

    # Weryfikacja atomowego zapisu do pliku tymczasowego
    tmp_prom = os.path.join(tempfile.gettempdir(), f"change_radar_selftest_{os.getpid()}.prom")
    try:
        write_file_atomic(tmp_prom, prom_text)
        assert os.path.exists(tmp_prom), "Plik .prom nie został utworzony atomowo"
    finally:
        if os.path.exists(tmp_prom):
            os.remove(tmp_prom)

    # Weryfikacja pliku konfiguracyjnego config/change-radar/targets.json
    script_dir = os.path.dirname(os.path.abspath(__file__))
    stack_root = os.environ.get("STACK_ROOT") or os.path.abspath(os.path.join(script_dir, ".."))
    targets_file = os.environ.get("TARGETS_FILE") or os.path.join(
        stack_root, "config", "change-radar", "targets.json"
    )
    if os.path.exists(targets_file):
        with open(targets_file, "r", encoding="utf-8") as tf:
            t_cfg = json.load(tf)
        t_list = t_cfg.get("targets") or []
        t_ids = {t.get("id") for t in t_list if isinstance(t, dict)}
        expected_ids = {
            "cez-ezdrowie-komunikaty",
            "nfz-slaski-komunikaty",
            "mf-ksef-komunikaty",
            "lh-pl-domeny-cennik",
            "lh-pl-hosting",
            "katowice-ngo-konkursy",
        }
        assert expected_ids.issubset(t_ids), f"Brak wymaganych celów w targets.json: {expected_ids - t_ids}"

    print("SELF_TEST_OK")
    return 0


def main():
    if "--self-test" in sys.argv:
        sys.exit(run_self_test())

    script_dir = os.path.dirname(os.path.abspath(__file__))
    stack_root = os.environ.get("STACK_ROOT") or os.path.abspath(os.path.join(script_dir, ".."))
    targets_file = os.environ.get("TARGETS_FILE") or os.path.join(
        stack_root, "config", "change-radar", "targets.json"
    )
    prom_file = os.environ.get("PROM_FILE") or os.path.join(
        stack_root, "config", "node-exporter", "change_radar.prom"
    )
    state_file = resolve_default_state_file()
    report_file = resolve_default_report_file()

    now_ts = int(time.time())

    if not os.path.exists(targets_file):
        prom_err = build_prometheus_metrics(False, 0, 0, [], now_ts)
        write_file_atomic(prom_file, prom_err)
        print(json.dumps({"status": "error", "error": f"Missing targets file: {targets_file}"}))
        sys.exit(1)

    try:
        with open(targets_file, "r", encoding="utf-8") as tf:
            config_data = json.load(tf)
    except Exception as exc:
        prom_err = build_prometheus_metrics(False, 0, 0, [], now_ts)
        write_file_atomic(prom_file, prom_err)
        print(json.dumps({"status": "error", "error": f"Invalid JSON in targets file: {exc}"}))
        sys.exit(1)

    raw_targets = config_data.get("targets") or []
    active_targets = [t for t in raw_targets if isinstance(t, dict) and t.get("enabled", True)]

    prev_state = {"targets": {}}
    if os.path.exists(state_file):
        try:
            with open(state_file, "r", encoding="utf-8") as sf:
                loaded_state = json.load(sf)
            if isinstance(loaded_state, dict) and isinstance(loaded_state.get("targets"), dict):
                prev_state = loaded_state
        except Exception:
            prev_state = {"targets": {}}

    prev_targets_map = prev_state.get("targets") or {}
    new_targets_map = dict(prev_targets_map)

    target_metrics = []
    detected_changes = []
    any_target_up = False

    for target in active_targets:
        tid = str(target.get("id") or "").strip()
        tname = str(target.get("name") or tid).strip()
        tcat = str(target.get("category") or "general").strip()
        turl = str(target.get("url") or "").strip()
        if not tid or not turl:
            continue

        prev_entry = prev_targets_map.get(tid) or {}
        last_change_ts = int(prev_entry.get("last_change_ts") or 0)

        try:
            http_status, raw_html = fetch_url_safely(turl, timeout=DEFAULT_TIMEOUT, max_bytes=MAX_BYTES)
            is_up = 1 if (200 <= int(http_status) < 400 and raw_html) else 0
        except Exception:
            http_status = 0
            raw_html = ""
            is_up = 0

        if is_up:
            any_target_up = True
            norm_lines, cur_sha256 = extract_normalized_lines(raw_html, target)
            prev_sha256 = prev_entry.get("sha256")
            prev_lines = prev_entry.get("lines") or []

            if prev_sha256 and prev_sha256 != cur_sha256:
                diff_lines = compute_diff_summary(prev_lines, norm_lines, max_lines=15)
                if diff_lines:
                    last_change_ts = now_ts
                    detected_changes.append({
                        "id": tid,
                        "name": tname,
                        "category": tcat,
                        "url": turl,
                        "old_sha256": prev_sha256,
                        "new_sha256": cur_sha256,
                        "diff": diff_lines,
                    })

            new_targets_map[tid] = {
                "id": tid,
                "name": tname,
                "category": tcat,
                "url": turl,
                "sha256": cur_sha256,
                "lines": norm_lines[:1500],
                "last_check_ts": now_ts,
                "last_change_ts": last_change_ts,
                "last_http_status": http_status,
                "up": 1,
            }
        else:
            if tid in new_targets_map:
                new_targets_map[tid]["last_check_ts"] = now_ts
                new_targets_map[tid]["last_http_status"] = http_status
                new_targets_map[tid]["up"] = 0

        target_metrics.append({
            "id": tid,
            "category": tcat,
            "up": is_up,
            "last_change_ts": last_change_ts,
        })

    overall_status_ok = 1 if (not active_targets or any_target_up) else 0
    changes_count = len(detected_changes)

    # Atomowy zapis stanu
    new_state_payload = {
        "updated_at_ts": now_ts,
        "targets_total": len(active_targets),
        "changes_detected_total": changes_count,
        "targets": new_targets_map,
    }
    write_file_atomic(state_file, json.dumps(new_state_payload, ensure_ascii=False, indent=2))

    # Atomowy zapis metryk Prometheus
    prom_payload = build_prometheus_metrics(
        status_ok=overall_status_ok,
        targets_total=len(active_targets),
        changes_detected_total=changes_count,
        target_metrics=target_metrics,
        now_ts=now_ts,
    )
    write_file_atomic(prom_file, prom_payload)

    # Raport wyjściowy dla scripts/sync-change-radar.sh
    report_payload = {
        "status": "ok" if overall_status_ok else "degraded",
        "timestamp": now_ts,
        "targets_total": len(active_targets),
        "changes_detected_total": changes_count,
        "changes": detected_changes,
    }
    write_file_atomic(report_file, json.dumps(report_payload, ensure_ascii=False, indent=2))
    print(json.dumps(report_payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
