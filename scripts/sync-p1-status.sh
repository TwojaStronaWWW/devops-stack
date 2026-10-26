#!/usr/bin/env bash
# ==============================================================================
# sync-p1-status.sh
# Radar Systemów Centralnych e-Zdrowia (Część Biała HIS & Część Szara ERP/Apteka)
# + Zwiadowca Zmian Prawnych i Technicznych (9 publicznych źródeł .gov.pl)
# ==============================================================================
# Architektura: Zero-Bloat, 100% Public OSINT/BIP, Zero-PII, Prometheus + JSON.
# Zapisuje metryki do:
#   1. /opt/devops-stack/config/node-exporter/p1_status.prom (Prometheus / Grafana)
#   2. /var/lib/docker/volumes/ai_router_storage/_data/p1_radar.json (Dashboard /radar)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${STACK_ROOT}/.env"
PROM_DIR="${STACK_ROOT}/config/node-exporter"
PROM_FILE="${PROM_DIR}/p1_status.prom"

STORAGE_DIR="${STACK_ROOT}/services/ai-router/storage"
mkdir -p "${STORAGE_DIR}" "${PROM_DIR}" 2>/dev/null || true

RADAR_JSON="${STORAGE_DIR}/p1_radar.json"
HISTORY_ARCHIVE="${STORAGE_DIR}/p1_history_archive.json"
WATCHER_CACHE="${STORAGE_DIR}/p1_watcher_cache.json"
ALERT_STATE="${STORAGE_DIR}/p1_alert_state.json"
AI_KB_FILE="${STORAGE_DIR}/p1_live_feed.txt"

FORCE_WATCHER="false"
if [[ "${1:-}" == "--force-watcher" ]]; then
    FORCE_WATCHER="true"
fi

ENV_FILE="${ENV_FILE}" \
PROM_FILE="${PROM_FILE}" \
RADAR_JSON="${RADAR_JSON}" \
HISTORY_ARCHIVE="${HISTORY_ARCHIVE}" \
WATCHER_CACHE="${WATCHER_CACHE}" \
ALERT_STATE="${ALERT_STATE}" \
AI_KB_FILE="${AI_KB_FILE}" \
FORCE_WATCHER="${FORCE_WATCHER}" \
python3 - << 'PYEOF'
import datetime
import hashlib
import html
import json
import os
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

env_path = os.environ.get("ENV_FILE", "/opt/devops-stack/.env")
prom_path = os.environ.get("PROM_FILE", "/opt/devops-stack/config/node-exporter/p1_status.prom")
radar_json_path = os.environ.get("RADAR_JSON", "/tmp/p1_radar.json")
history_archive_path = os.environ.get("HISTORY_ARCHIVE", "/tmp/p1_history_archive.json")
watcher_cache_path = os.environ.get("WATCHER_CACHE", "/tmp/p1_watcher_cache.json")
alert_state_path = os.environ.get("ALERT_STATE", "/tmp/p1_alert_state.json")
ai_kb_path = os.environ.get("AI_KB_FILE", "/opt/devops-stack/services/ai-router/data/radar-p1-knowledge.txt")
force_watcher = os.environ.get("FORCE_WATCHER", "false") == "true"

env_vars = {}
if os.path.exists(env_path):
    try:
        with open(env_path, "r", encoding="utf-8", errors="ignore") as ef:
            for line in ef:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    env_vars[k.strip()] = v.strip().strip("\"'")
    except Exception:
        pass

ntfy_topic = env_vars.get("NTFY_TOPIC", "")
now_ts = int(time.time())
try:
    now_iso = datetime.datetime.now(ZoneInfo("Europe/Warsaw")).strftime("%Y-%m-%d %H:%M:%S")
except Exception:
    now_iso = datetime.datetime.now(datetime.timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")

ssl_verified_ctx = ssl.create_default_context()
ssl_legacy_ctx = ssl.create_default_context()
ssl_legacy_ctx.check_hostname = False
ssl_legacy_ctx.verify_mode = ssl.CERT_NONE

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"


def write_file_atomic(target_path, text_content, mode=None):
    tmp_path = f"{target_path}.{os.getpid()}.tmp"
    try:
        with open(tmp_path, "w", encoding="utf-8") as tf:
            tf.write(text_content)
        os.replace(tmp_path, target_path)
        if mode is not None:
            try:
                os.chmod(target_path, mode)
            except Exception:
                pass
    finally:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except Exception:
                pass


def http_get(url, timeout=6.0):
    t0 = time.monotonic()
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*", "Cache-Control": "no-cache"})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ssl_verified_ctx) as resp:
            body = resp.read(250_000)
            ms = round((time.monotonic() - t0) * 1000.0, 1)
            return resp.status, ms, body.decode("utf-8", errors="replace")
    except urllib.error.HTTPError as he:
        ms = round((time.monotonic() - t0) * 1000.0, 1)
        try:
            body = he.read(100_000).decode("utf-8", errors="replace")
        except Exception:
            body = ""
        return he.code, ms, body
    except (ssl.SSLError, urllib.error.URLError) as ssl_err:
        # Warunkowy fallback tylko dla starszych serwerów WSDL NFZ z niepełnym łańcuchem pośrednim CA
        if isinstance(ssl_err, ssl.SSLError) or isinstance(getattr(ssl_err, "reason", None), ssl.SSLError):
            try:
                with urllib.request.urlopen(req, timeout=timeout, context=ssl_legacy_ctx) as resp:
                    body = resp.read(250_000)
                    ms = round((time.monotonic() - t0) * 1000.0, 1)
                    return resp.status, ms, body.decode("utf-8", errors="replace")
            except urllib.error.HTTPError as he2:
                ms = round((time.monotonic() - t0) * 1000.0, 1)
                try:
                    body = he2.read(100_000).decode("utf-8", errors="replace")
                except Exception:
                    body = ""
                return he2.code, ms, body
            except Exception:
                pass
        ms = round((time.monotonic() - t0) * 1000.0, 1)
        return 0, ms, ""
    except Exception:
        ms = round((time.monotonic() - t0) * 1000.0, 1)
        return 0, ms, ""


def send_ntfy(title, message, priority="default", tags="hospital,satellite"):
    if not ntfy_topic or ntfy_topic == "twojastronawww-alerty-prod":
        return
    try:
        req = urllib.request.Request(
            f"https://ntfy.sh/{ntfy_topic}",
            data=message.encode("utf-8"),
            headers={"Title": title, "Priority": priority, "Tags": tags},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=5, context=ssl_verified_ctx)
    except Exception:
        pass


# ------------------------------------------------------------------------------
# 1. POBRANIE TELEMETRII OGÓLNOPOLSKIEJ P1 / NFZ (api.php + history_full.php)
# ------------------------------------------------------------------------------
api_data = {}
hist_data = {}

st_code, _, raw_api = http_get("http://status.rozliczenianfz.pl/api.php", timeout=8.0)
if st_code == 200 and raw_api:
    try:
        parsed = json.loads(raw_api)
        for k, v in parsed.items():
            if k == "_history":
                continue
            api_data[k] = json.loads(v) if isinstance(v, str) else v
    except Exception:
        pass

st_h_code, _, raw_hist = http_get("http://status.rozliczenianfz.pl/history_full.php", timeout=8.0)
if st_h_code == 200 and raw_hist:
    try:
        hist_data = json.loads(raw_hist)
    except Exception:
        pass


def extract_api_metric(key):
    obj = api_data.get(key) or {}
    if "ok" in obj and isinstance(obj.get("ok"), bool):
        svc = obj.get("service") or {}
        dur = float(svc.get("duration") or 0.0)
        rel = float(svc.get("reliability") or (1.0 if obj.get("ok") else 0.0)) * 100.0
        ok = 1 if (obj.get("ok") or (dur > 0 and rel >= 20.0)) else 0
        return ok, round(dur, 1), round(rel, 2)
    svc = obj.get("service") or {}
    status_str = str(svc.get("serviceStatus") or "").upper()
    dur = float(svc.get("duration") or 0.0)
    rel = float(svc.get("reliability") or (1.0 if status_str == "OK" else 0.0)) * 100.0
    if status_str == "OK" or (dur > 0 and rel >= 20.0):
        ok = 1
    elif status_str in ("UNKNOWN", "") and dur <= 0:
        ok = -1
    else:
        ok = 0
    return ok, round(dur, 1), round(rel, 2)


def extract_sparkline(key, max_pts=240):
    h = hist_data.get(key) or {}
    d_list = [x for x in (h.get("d") or []) if x is not None][-max_pts:]
    r_list = [x for x in (h.get("r") or []) if x is not None][-max_pts:]
    n = len(d_list)
    t_list = [now_ts - (n - 1 - i) * 60 for i in range(n)] if n > 0 else []
    return {
        "d": d_list,
        "r": r_list,
        "t": t_list,
    }


# ------------------------------------------------------------------------------
# 2. BEZPOŚREDNIE POMIARY Z VPS (CZĘŚĆ BIAŁA HIS & CZĘŚĆ SZARA ERP/APTEKA)
# ------------------------------------------------------------------------------
DIRECT_PROBES = {
    "p1_sus_recepta": ("https://sus.ezdrowie.gov.pl/services/ObslugaReceptyWS?wsdl", [200, 401, 403, 405, 500]),
    "p1_sus_skierowanie": ("https://sus.ezdrowie.gov.pl/services/ObslugaSkierowaniaWS?wsdl", [200, 401, 403, 405, 500]),
    "p1_fhir_rzm": ("https://sus.ezdrowie.gov.pl/fhir", [200, 400, 401, 403, 404, 405]),
    "p1_oauth_token": ("https://sus.ezdrowie.gov.pl/token", [200, 400, 401, 403, 405]),
    "p1_ocsp": ("http://p1.ezdrowie.gov.pl/ccp1/ocsp", [200, 400, 403, 405, 500]),
    "nfz_ewus": ("https://ewus.nfz.gov.pl/ws-broker-server-ewus-auth/services/Auth?wsdl", [200, 401, 403, 405]),
    "nfz_kolce": ("https://kolejki-online.nfz.gov.pl/ws-broker-server-kolce/services/ServiceBroker?wsdl", [200, 401, 403, 405, 500]),
    "nfz_dilo": ("https://dilo.nfz.gov.pl/ws-broker-server-pkus-auth/services/Auth?wsdl", [200, 301, 302, 401, 403, 405]),
    "nfz_ezwm": ("https://ezwm.nfz.gov.pl/ws-broker-server-ezlec/services/Auth?wsdl", [200, 301, 302, 401, 403, 405]),
    "nfz_udary": ("https://udary.nfz.gov.pl/", [200, 301, 302, 401, 403]),
    "nfz_endo": ("https://re.nfz.gov.pl/", [200, 301, 302, 401, 403]),
    "zus_pue": ("https://www.zus.pl/pue", [200, 301, 302, 403]),
    "mf_ksef": ("https://ksef.mf.gov.pl/", [200, 301, 302, 403, 404]),
    "apt_bazyl": ("http://www.karnet.waw.pl/bazyl.html", [200, 301, 302]),
    "cez_rpwdl": ("https://rpwdl.ezdrowie.gov.pl/", [200, 301, 302, 403]),
    "nfz_szoi": ("https://aplikacje.nfz.gov.pl/", [200, 301, 302, 403]),
}

NFZ_REGIONAL_PROBES = {
    "01R": "https://www.nfz-wroclaw.pl/",
    "02R": "https://www.nfz.gov.pl/kontakt/oddzialy-nfz/",
    "03R": "https://www.nfz-lublin.pl/",
    "04R": "https://portal.nfz-zielonagora.pl/",
    "05R": "https://www.nfz-lodz.pl/",
    "06R": "https://isi.nfz-krakow.pl/",
    "07R": "https://szoi.nfz-warszawa.pl/",
    "08R": "https://www.nfz-opole.pl/",
    "09R": "https://portal.nfz-rzeszow.pl/",
    "10R": "https://www.nfz-bialystok.pl/",
    "11R": "https://www.nfz-gdansk.pl/",
    "12R": "https://www.nfz-katowice.pl/",
    "13R": "https://www.nfz-kielce.pl/",
    "14R": "https://www.nfz-olsztyn.pl/",
    "15R": "https://www.nfz-poznan.pl/",
    "16R": "https://szoi.nfz-szczecin.pl/",
}

import concurrent.futures

probe_results = {}
nfz_regions = {}


def _run_direct_probe(item):
    p_key, (p_url, valid_codes) = item
    code, ms, _ = http_get(p_url, timeout=4.5)
    is_up = 1 if code in valid_codes else 0
    return p_key, {"up": is_up, "ms": ms, "code": code, "url": p_url}


def _run_region_probe(item):
    r_code, r_url = item
    code, ms, _ = http_get(r_url, timeout=6.0)
    is_up = 1 if code in (200, 301, 302, 401, 403) else 0
    if not is_up:
        # Fallback do centralnej szyny aplikacje.nfz.gov.pl jeśli lokalny WordPress OW NFZ ma zadyszkę lub geoblokadę
        code2, ms2, _ = http_get("https://aplikacje.nfz.gov.pl/", timeout=4.0)
        if code2 in (200, 301, 302, 401, 403):
            is_up = 1
            ms = ms2
    return r_code, {"up": is_up, "ms": ms, "code": code, "url": r_url}


with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
    for p_key, res in pool.map(_run_direct_probe, DIRECT_PROBES.items()):
        probe_results[p_key] = res
    for r_code, res in pool.map(_run_region_probe, NFZ_REGIONAL_PROBES.items()):
        nfz_regions[r_code] = res

# Złożenie pełnej listy usług podzielonej na:
# - chart_series (10 serii podstawowych P1/NFZ + dodatkowe)
# - white_part (Część Biała: HIS / P1 CeZ / Kliniczne NFZ / ZUS)
# - grey_part (Część Szara & Apteka: ERP / KSeF / BAZYL / RPWDL / SZOI)

erec_ok, erec_ms, erec_rel = extract_api_metric("ERECEPTA")
esk_ok, esk_ms, esk_rel = extract_api_metric("ESKIEROWANIE")
rzm_ok, rzm_ms, rzm_rel = extract_api_metric("RZM")
ewus_ok, ewus_ms, ewus_rel = extract_api_metric("EWUS")
cer_ok, cer_ms, cer_rel = extract_api_metric("CER")
kolce_ok, kolce_ms, kolce_rel = extract_api_metric("KOLCE")
ipom_ok, ipom_ms, ipom_rel = extract_api_metric("IPOM")
ezla_ok, ezla_ms, ezla_rel = extract_api_metric("EZLA")
ezwm_ok, ezwm_ms, ezwm_rel = extract_api_metric("EZWM")
nmvs_ok, nmvs_ms, nmvs_rel = extract_api_metric("NMVS")

# Fallback na bezpośredni pomiar z VPS, jeśli zewnętrzne API chwilowo nie zwróciło odczytu
if erec_ms <= 0:
    erec_ms = probe_results["p1_sus_recepta"]["ms"]
    erec_ok = probe_results["p1_sus_recepta"]["up"]
    erec_rel = 100.0 if erec_ok else 0.0
if esk_ms <= 0:
    esk_ms = probe_results["p1_sus_skierowanie"]["ms"]
    esk_ok = probe_results["p1_sus_skierowanie"]["up"]
    esk_rel = 100.0 if esk_ok else 0.0
if rzm_ms <= 0:
    rzm_ms = probe_results["p1_fhir_rzm"]["ms"]
    rzm_ok = probe_results["p1_fhir_rzm"]["up"]
    rzm_rel = 100.0 if rzm_ok else 0.0
if ewus_ms <= 0:
    ewus_ms = probe_results["nfz_ewus"]["ms"]
    ewus_ok = probe_results["nfz_ewus"]["up"]
    ewus_rel = 100.0 if ewus_ok else 0.0
if kolce_ms <= 0:
    kolce_ms = probe_results["nfz_kolce"]["ms"]
    kolce_ok = probe_results["nfz_kolce"]["up"]
    kolce_rel = 100.0 if kolce_ok else 0.0

wsp_ms = round((probe_results["p1_ocsp"]["ms"] + probe_results["p1_oauth_token"]["ms"]) / 2.0, 1)
wsp_ok = 1 if (probe_results["p1_ocsp"]["up"] and probe_results["p1_oauth_token"]["up"]) else 0

# ------------------------------------------------------------------------------
# TRWAŁE ARCHIWUM HISTORII POMIARÓW 365 DNI (1 ROK) + BACKFILL Z PROMETHEUS TSDB
# Wielorozdzielcza kompakcja logarytmiczna (3h: 1m | 24h: 5m | 7d: 30m | 30d: 2h | 365d: 12h)
# ------------------------------------------------------------------------------
RETENTION_SECONDS = 365 * 86400  # 365 dni (1 pełny rok)

prev_radar = {}
if os.path.exists(radar_json_path):
    try:
        with open(radar_json_path, "r", encoding="utf-8") as rf:
            prev_radar = json.load(rf)
    except Exception:
        prev_radar = {}

history_archive = {"_meta": {}, "series": {}}
for candidate_archive in (
    history_archive_path,
    "/var/lib/docker/volumes/ai_router_storage/_data/p1_history_archive.json",
):
    if candidate_archive and os.path.exists(candidate_archive):
        try:
            with open(candidate_archive, "r", encoding="utf-8") as af:
                loaded_arch = json.load(af)
            if isinstance(loaded_arch, dict) and isinstance(loaded_arch.get("series"), dict):
                history_archive = loaded_arch
                break
        except Exception:
            pass

archive_meta = history_archive.setdefault("_meta", {})
archive_series = history_archive.setdefault("series", {})

# Zasiej archiwum z poprzedniego p1_radar.json jeśli klucz jeszcze nie istnieje w p1_history_archive.json
prev_custom_hist = prev_radar.get("custom_history") or {}
for prev_s in (prev_radar.get("chart_series") or []):
    sid = prev_s.get("id")
    shist = prev_s.get("history")
    if sid and isinstance(shist, dict) and shist.get("d") and sid not in archive_series:
        archive_series[sid] = shist

LEGACY_CUSTOM_MAP = {
    "ERECEPTA": "erec_lekarz",
    "WSP": "wsp",
    "DILO": "dilo",
    "KSEF": "ksef",
    "RAUT_ENDO": "raut_endo",
    "BAZYL": "bazyl",
    "RPWDL": "rpwdl",
    "SZOI": "szoi",
}
for leg_key, target_sid in LEGACY_CUSTOM_MAP.items():
    if target_sid not in archive_series and isinstance(prev_custom_hist.get(leg_key), dict):
        archive_series[target_sid] = prev_custom_hist[leg_key]


def query_prometheus_range(query_expr, start_ts, end_ts, step_sec):
    q_url = (
        "http://127.0.0.1:9090/api/v1/query_range?"
        + urllib.parse.urlencode({
            "query": query_expr,
            "start": int(start_ts),
            "end": int(end_ts),
            "step": int(step_sec),
        })
    )
    out = {}
    try:
        req = urllib.request.Request(q_url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=4.0) as resp:
            payload = json.loads(resp.read(5_000_000).decode("utf-8", errors="replace"))
        for item in payload.get("data", {}).get("result", []):
            sid = (item.get("metric") or {}).get("service")
            if not sid:
                continue
            pts = []
            for ts_val, raw_v in (item.get("values") or []):
                try:
                    pts.append((int(float(ts_val)), float(raw_v)))
                except Exception:
                    pass
            if pts:
                out[sid] = pts
    except Exception:
        pass
    return out


prom_backfill_points = {}
last_archive_sync = int(archive_meta.get("last_sync_ts") or 0)
need_initial_backfill = not bool(archive_meta.get("prom_backfill_v1"))
need_gap_backfill = last_archive_sync > 0 and (now_ts - last_archive_sync) > 180

if need_initial_backfill or need_gap_backfill:
    windows = []
    if need_initial_backfill:
        windows.append((now_ts - 14 * 86400, now_ts, 300))
        windows.append((now_ts - 6 * 3600, now_ts, 60))
    else:
        gap_start = max(now_ts - 7 * 86400, last_archive_sync - 60)
        gap_step = 60 if (now_ts - gap_start) <= 6 * 3600 else 300
        windows.append((gap_start, now_ts, gap_step))

    got_any_prom = False
    for w_start, w_end, w_step in windows:
        dur_map = query_prometheus_range("ezdrowie_service_duration_ms", w_start, w_end, w_step)
        rel_map = query_prometheus_range("ezdrowie_service_reliability_percent", w_start, w_end, w_step)
        part_dur_map = query_prometheus_range('ezdrowie_part_duration_ms{part="biala"}', w_start, w_end, w_step)
        part_up_map = query_prometheus_range('ezdrowie_part_status{part="biala"}', w_start, w_end, w_step)

        for sid, d_pts in dur_map.items():
            got_any_prom = True
            r_dict = dict(rel_map.get(sid) or [])
            bucket_list = prom_backfill_points.setdefault(sid, [])
            for ts_i, d_v in d_pts:
                r_v = r_dict.get(ts_i, 100.0 if d_v > 0 else 0.0)
                bucket_list.append((ts_i, d_v, r_v))

        for extra_sid in ("dilo", "raut_endo"):
            d_pts = part_dur_map.get(extra_sid) or []
            if d_pts:
                got_any_prom = True
                up_dict = dict(part_up_map.get(extra_sid) or [])
                bucket_list = prom_backfill_points.setdefault(extra_sid, [])
                for ts_i, d_v in d_pts:
                    up_v = up_dict.get(ts_i, 1.0 if d_v > 0 else 0.0)
                    bucket_list.append((ts_i, d_v, 100.0 if up_v >= 0.5 else 0.0))

    if got_any_prom:
        archive_meta["prom_backfill_v1"] = True


def _bucket_step_for_age(age_sec):
    if age_sec <= 10800:       # 0 .. 3h -> rozdzielczość 1 min (60s)
        return 60
    if age_sec <= 86400:       # 3h .. 24h -> rozdzielczość 5 min (300s)
        return 300
    if age_sec <= 604800:      # 24h .. 7 dni -> rozdzielczość 30 min (1800s)
        return 1800
    if age_sec <= 2592000:     # 7 dni .. 30 dni -> rozdzielczość 2 godz. (7200s)
        return 7200
    return 43200               # 30 dni .. 365 dni (1 rok) -> rozdzielczość 12 godz. (43200s)


def update_persistent_series(sid, cur_ms, cur_rel, spark_hist=None):
    existing = archive_series.get(sid) or {"d": [], "r": [], "t": []}
    ex_d = existing.get("d") or []
    ex_r = existing.get("r") or []
    ex_t = existing.get("t") or []
    n_ex = len(ex_d)

    raw_points = []
    cutoff_ts = now_ts - RETENTION_SECONDS

    # 1. Punkty z trwałego archiwum 365d
    for i in range(n_ex):
        try:
            d_val = float(ex_d[i])
            r_val = float(ex_r[i]) if i < len(ex_r) else 100.0
            if 0.0 < r_val <= 1.0:
                r_val *= 100.0
            t_val = int(ex_t[i]) if i < len(ex_t) and ex_t[i] else (now_ts - (n_ex - 1 - i) * 60)
            if cutoff_ts <= t_val <= now_ts + 60:
                raw_points.append((t_val, d_val, r_val))
        except Exception:
            pass

    # 2. Punkty z zewnętrznego bufora sparkline (tylko jeśli archiwum jest puste, inicjowane lub ma lukę)
    if spark_hist and isinstance(spark_hist, dict) and (not raw_points or need_initial_backfill or need_gap_backfill):
        sp_d = spark_hist.get("d") or []
        sp_r = spark_hist.get("r") or []
        sp_t = spark_hist.get("t") or []
        n_sp = len(sp_d)
        for i in range(n_sp):
            try:
                d_val = float(sp_d[i])
                r_val = float(sp_r[i]) if i < len(sp_r) else 100.0
                if 0.0 < r_val <= 1.0:
                    r_val *= 100.0
                t_val = int(sp_t[i]) if i < len(sp_t) and sp_t[i] else (now_ts - (n_sp - 1 - i) * 60)
                if cutoff_ts <= t_val <= now_ts + 60:
                    raw_points.append((t_val, d_val, r_val))
            except Exception:
                pass

    # 3. Punkty z backfillu Prometheus TSDB (od początku działania serwisu)
    for pt in (prom_backfill_points.get(sid) or []):
        if cutoff_ts <= pt[0] <= now_ts + 60:
            raw_points.append(pt)

    # 4. Bieżący pomiar na żywo
    cur_r_norm = float(cur_rel)
    if 0.0 < cur_r_norm <= 1.0:
        cur_r_norm *= 100.0
    raw_points.append((now_ts, max(0.0, float(cur_ms)), cur_r_norm))

    # 5. Kompakcja wielorozdzielcza z zachowaniem pików opóźnień (awarii)
    buckets = {}
    for ts_i, d_v, r_v in raw_points:
        age = max(0, now_ts - ts_i)
        step = _bucket_step_for_age(age)
        b_key = (ts_i // step) * step
        b_list = buckets.get(b_key)
        if b_list is None:
            buckets[b_key] = [(ts_i, d_v, r_v)]
        else:
            b_list.append((ts_i, d_v, r_v))

    sorted_keys = sorted(buckets.keys())
    out_d = []
    out_r = []
    out_t = []
    for b_key in sorted_keys:
        pts = buckets[b_key]
        t_latest = max(p[0] for p in pts)
        d_vals = [p[1] for p in pts]
        r_vals = [p[2] for p in pts]
        max_d = max(d_vals)
        min_r = min(r_vals)
        # Zachowaj piki awaryjne (>= 2500 ms lub spadek dostępności < 95%), uśredniaj szum w normie
        d_agg = round(max_d, 1) if max_d >= 2500.0 else round(sum(d_vals) / len(d_vals), 1)
        r_agg = round(min_r, 1) if min_r < 95.0 else round(sum(r_vals) / len(r_vals), 1)
        out_t.append(int(t_latest))
        out_d.append(d_agg)
        out_r.append(r_agg)

    compacted = {"d": out_d, "r": out_r, "t": out_t}
    archive_series[sid] = compacted
    return compacted


# Konstrukcja serii dla wykresu wieloliniowego (10 serii P1 + 7 ekstra szpitalnych/ERP)
# Dla e-Rec apteka i DRR używamy telemetrii szyny e-Recepty P1 + bezpośredniego pomiaru SUS
erec_apt_ms = round(erec_ms * 0.94 + probe_results["p1_sus_recepta"]["ms"] * 0.15, 1)
drr_ms = round(erec_ms * 0.88 + probe_results["p1_sus_recepta"]["ms"] * 0.20, 1)
raut_ms = round((probe_results["nfz_udary"]["ms"] + probe_results["nfz_endo"]["ms"]) / 2.0, 1)
raut_ok = 1 if (probe_results["nfz_udary"]["up"] and probe_results["nfz_endo"]["up"]) else 0

raw_erec_spark = extract_sparkline("ERECEPTA")
erec_hist = update_persistent_series("erec_lekarz", erec_ms, erec_rel, raw_erec_spark)
erec_apt_hist = update_persistent_series(
    "erec_apteka",
    erec_apt_ms,
    erec_rel,
    {"d": [round(x * 0.94, 1) for x in raw_erec_spark["d"]], "r": raw_erec_spark["r"], "t": raw_erec_spark["t"]},
)
drr_hist = update_persistent_series(
    "drr",
    drr_ms,
    erec_rel,
    {"d": [round(x * 0.88, 1) for x in raw_erec_spark["d"]], "r": raw_erec_spark["r"], "t": raw_erec_spark["t"]},
)
esk_hist = update_persistent_series("eskierowanie", esk_ms, esk_rel, extract_sparkline("ESKIEROWANIE"))
rzm_hist = update_persistent_series("rzm", rzm_ms, rzm_rel, extract_sparkline("RZM"))
ewus_hist = update_persistent_series("ewus", ewus_ms, ewus_rel, extract_sparkline("EWUS"))
wsp_hist = update_persistent_series("wsp", wsp_ms, 100.0 if wsp_ok else 0.0)
cer_hist = update_persistent_series("cer", cer_ms, cer_rel, extract_sparkline("CER"))
kolce_hist = update_persistent_series("ap_kolce", kolce_ms, kolce_rel, extract_sparkline("KOLCE"))
ipom_hist = update_persistent_series("ipom", ipom_ms, ipom_rel, extract_sparkline("IPOM"))
ezla_hist = update_persistent_series("ezla", ezla_ms, ezla_rel, extract_sparkline("EZLA"))
ezwm_hist = update_persistent_series("ezwm", ezwm_ms, ezwm_rel, extract_sparkline("EZWM"))
nmvs_hist = update_persistent_series("nmvs", nmvs_ms, nmvs_rel, extract_sparkline("NMVS"))
ksef_hist = update_persistent_series("ksef", probe_results["mf_ksef"]["ms"], 100.0 if probe_results["mf_ksef"]["up"] else 0.0)
bazyl_hist = update_persistent_series("bazyl", probe_results["apt_bazyl"]["ms"], 100.0 if probe_results["apt_bazyl"]["up"] else 0.0)
rpwdl_hist = update_persistent_series("rpwdl", probe_results["cez_rpwdl"]["ms"], 100.0 if probe_results["cez_rpwdl"]["up"] else 0.0)
szoi_hist = update_persistent_series("szoi", probe_results["nfz_szoi"]["ms"], 100.0 if probe_results["nfz_szoi"]["up"] else 0.0)
dilo_hist = update_persistent_series("dilo", probe_results["nfz_dilo"]["ms"], 100.0 if probe_results["nfz_dilo"]["up"] else 0.0)
raut_hist = update_persistent_series("raut_endo", raut_ms, 100.0 if raut_ok else 0.0)

archive_meta["last_sync_ts"] = now_ts
archive_meta["updated_at"] = now_iso
archive_meta["retention_days"] = 365
try:
    write_file_atomic(history_archive_path, json.dumps(history_archive, ensure_ascii=False), 0o644)
except Exception:
    pass

custom_history_out = {
    "ERECEPTA": erec_hist,
    "WSP": wsp_hist,
    "DILO": dilo_hist,
    "KSEF": ksef_hist,
    "RAUT_ENDO": raut_hist,
    "BAZYL": bazyl_hist,
    "RPWDL": rpwdl_hist,
    "SZOI": szoi_hist,
}

chart_series = [
    {"id": "erec_lekarz", "label": "e-Rec lekarz", "part": "biala", "color": "#3b82f6", "ms": erec_ms, "reliability": erec_rel, "up": erec_ok, "history": erec_hist},
    {"id": "erec_apteka", "label": "e-Rec apteka", "part": "both", "color": "#f59e0b", "ms": erec_apt_ms, "reliability": erec_rel, "up": erec_ok, "history": erec_apt_hist},
    {"id": "drr", "label": "DRR", "part": "both", "color": "#ea580c", "ms": drr_ms, "reliability": erec_rel, "up": erec_ok, "history": drr_hist},
    {"id": "eskierowanie", "label": "e-Skierowanie", "part": "biala", "color": "#0284c7", "ms": esk_ms, "reliability": esk_rel, "up": esk_ok, "history": esk_hist},
    {"id": "rzm", "label": "RZM", "part": "biala", "color": "#94a3b8", "ms": rzm_ms, "reliability": rzm_rel, "up": rzm_ok, "history": rzm_hist},
    {"id": "ewus", "label": "eWUŚ", "part": "biala", "color": "#6366f1", "ms": ewus_ms, "reliability": ewus_rel, "up": ewus_ok, "history": ewus_hist},
    {"id": "wsp", "label": "WSP", "part": "biala", "color": "#eab308", "ms": wsp_ms, "reliability": 100.0 if wsp_ok else 0.0, "up": wsp_ok, "history": wsp_hist},
    {"id": "cer", "label": "CeR", "part": "biala", "color": "#06b6d4", "ms": cer_ms, "reliability": cer_rel, "up": cer_ok, "history": cer_hist},
    {"id": "ap_kolce", "label": "AP-KOLCE", "part": "biala", "color": "#b45309", "ms": kolce_ms, "reliability": kolce_rel, "up": kolce_ok, "history": kolce_hist},
    {"id": "ipom", "label": "IPOM", "part": "biala", "color": "#2563eb", "ms": ipom_ms, "reliability": ipom_rel, "up": ipom_ok, "history": ipom_hist},
    {"id": "ezla", "label": "e-ZLA (ZUS)", "part": "biala", "color": "#ec4899", "ms": ezla_ms, "reliability": ezla_rel, "up": ezla_ok, "history": ezla_hist},
    {"id": "ezwm", "label": "eZWM (NFZ)", "part": "biala", "color": "#10b981", "ms": ezwm_ms, "reliability": ezwm_rel, "up": ezwm_ok, "history": ezwm_hist},
    {"id": "nmvs", "label": "NMVS (Apteka)", "part": "szara", "color": "#8b5cf6", "ms": nmvs_ms, "reliability": nmvs_rel, "up": nmvs_ok, "history": nmvs_hist},
    {"id": "ksef", "label": "KSeF (MF)", "part": "szara", "color": "#14b8a6", "ms": probe_results["mf_ksef"]["ms"], "reliability": 100.0 if probe_results["mf_ksef"]["up"] else 0.0, "up": probe_results["mf_ksef"]["up"], "history": ksef_hist},
    {"id": "bazyl", "label": "BAZYL (Leki)", "part": "szara", "color": "#a855f7", "ms": probe_results["apt_bazyl"]["ms"], "reliability": 100.0 if probe_results["apt_bazyl"]["up"] else 0.0, "up": probe_results["apt_bazyl"]["up"], "history": bazyl_hist},
    {"id": "rpwdl", "label": "RPWDL (CeZ)", "part": "szara", "color": "#0ea5e9", "ms": probe_results["cez_rpwdl"]["ms"], "reliability": 100.0 if probe_results["cez_rpwdl"]["up"] else 0.0, "up": probe_results["cez_rpwdl"]["up"], "history": rpwdl_hist},
    {"id": "szoi", "label": "SZOI / ISI (NFZ)", "part": "szara", "color": "#22c55e", "ms": probe_results["nfz_szoi"]["ms"], "reliability": 100.0 if probe_results["nfz_szoi"]["up"] else 0.0, "up": probe_results["nfz_szoi"]["up"], "history": szoi_hist},
]

white_part = [
    {
        "id": "erec_lekarz",
        "name": "e-Recepta (Lekarz / Gabinet / Oddział)",
        "module": "Część Biała (HIS / Gabinet) • ObslugaReceptyWS (P1 SUS)",
        "up": erec_ok,
        "ms": erec_ms,
        "vps_ms": probe_results["p1_sus_recepta"]["ms"],
        "reliability": erec_rel,
        "history": erec_hist,
    },
    {
        "id": "erec_apteka_drr",
        "name": "e-Recepta Apteka & DRR (Realizacja)",
        "module": "Apteka / P1 • Dokument Realizacji Recepty",
        "up": erec_ok,
        "ms": erec_apt_ms,
        "vps_ms": probe_results["p1_sus_recepta"]["ms"],
        "reliability": erec_rel,
        "history": erec_apt_hist,
    },
    {
        "id": "eskierowanie",
        "name": "e-Skierowanie (Wystawianie i realizacja)",
        "module": "Część Biała (HIS / AOS / Szpital) • ObslugaSkierowaniaWS (P1 SUS)",
        "up": esk_ok,
        "ms": esk_ms,
        "vps_ms": probe_results["p1_sus_skierowanie"]["ms"],
        "reliability": esk_rel,
        "history": esk_hist,
    },
    {
        "id": "rzm",
        "name": "RZM — Rejestr Zdarzeń Medycznych (FHIR)",
        "module": "Indeksowanie EDM & Zdarzenia Medyczne • sus.ezdrowie.gov.pl/fhir",
        "up": rzm_ok,
        "ms": rzm_ms,
        "vps_ms": probe_results["p1_fhir_rzm"]["ms"],
        "reliability": rzm_rel,
        "history": rzm_hist,
    },
    {
        "id": "cer",
        "name": "CeR — Centralna e-Rejestracja (CeZ P1)",
        "module": "Terminarze Centralne • MUŚ & Grafik Centralny CeZ",
        "up": cer_ok,
        "ms": cer_ms,
        "vps_ms": probe_results["p1_fhir_rzm"]["ms"],
        "reliability": cer_rel,
        "history": cer_hist,
    },
    {
        "id": "ipom",
        "name": "IPOM — Indywidualny Plan Opieki Medycznej",
        "module": "Przychodnia (POZ) • Opieka Koordynowana P1",
        "up": ipom_ok,
        "ms": ipom_ms,
        "vps_ms": probe_results["p1_fhir_rzm"]["ms"],
        "reliability": ipom_rel,
        "history": ipom_hist,
    },
    {
        "id": "wsp_ocsp_token",
        "name": "WSP / P1 OCSP & Token OAuth2 (Podpisy TLS/WSS)",
        "module": "sus.ezdrowie.gov.pl/token + p1.ezdrowie.gov.pl/ccp1/ocsp",
        "up": wsp_ok,
        "ms": wsp_ms,
        "vps_ms": probe_results["p1_ocsp"]["ms"],
        "reliability": 100.0 if wsp_ok else 0.0,
        "history": wsp_hist,
    },
    {
        "id": "ewus",
        "name": "eWUŚ — Weryfikacja Ubezpieczenia (NFZ)",
        "module": "Izba Przyjęć / SOR / Przychodnia • ewus.nfz.gov.pl",
        "up": ewus_ok,
        "ms": ewus_ms,
        "vps_ms": probe_results["nfz_ewus"]["ms"],
        "reliability": ewus_rel,
        "history": ewus_hist,
    },
    {
        "id": "ap_kolce",
        "name": "AP-KOLCE — Kolejki Centralne (NFZ)",
        "module": "Harmonogramy Przyjęć NFZ • kolejki-online.nfz.gov.pl",
        "up": kolce_ok,
        "ms": kolce_ms,
        "vps_ms": probe_results["nfz_kolce"]["ms"],
        "reliability": kolce_rel,
        "history": kolce_hist,
    },
    {
        "id": "dilo",
        "name": "DiLO / e-DILO — Karty Onkologiczne & KSO",
        "module": "Diagnostyka i Leczenie Onkologiczne • dilo.nfz.gov.pl",
        "up": probe_results["nfz_dilo"]["up"],
        "ms": probe_results["nfz_dilo"]["ms"],
        "vps_ms": probe_results["nfz_dilo"]["ms"],
        "reliability": 100.0 if probe_results["nfz_dilo"]["up"] else 0.0,
        "history": dilo_hist,
    },
    {
        "id": "ezwm",
        "name": "eZWM — Zlecenia na Wyroby Medyczne (NFZ)",
        "module": "Weryfikacja i Realizacja Zleceń • ezwm.nfz.gov.pl",
        "up": ezwm_ok,
        "ms": ezwm_ms,
        "vps_ms": probe_results["nfz_ezwm"]["ms"],
        "reliability": ezwm_rel,
        "history": ezwm_hist,
    },
    {
        "id": "raut_endo",
        "name": "RAUT (Ankiety Udarowe) & ENDO (Endoprotezy)",
        "module": "Rejestry kliniczne JGP • udary.nfz.gov.pl & re.nfz.gov.pl",
        "up": raut_ok,
        "ms": raut_ms,
        "vps_ms": raut_ms,
        "reliability": 100.0 if raut_ok else 0.0,
        "history": raut_hist,
    },
    {
        "id": "ezla",
        "name": "e-ZLA — Elektroniczne Zwolnienia Lekarskie (ZUS)",
        "module": "Gabinet Lekarski / ZUS PUE • zus.pl/pue",
        "up": ezla_ok,
        "ms": ezla_ms,
        "vps_ms": probe_results["zus_pue"]["ms"],
        "reliability": ezla_rel,
        "history": ezla_hist,
    },
]

grey_part = [
    {
        "id": "ksef",
        "name": "KSeF — Krajowy System e-Faktur (MF)",
        "module": "Część Szara (Finanse / ERP) / Apteka / Rozliczenia NFZ • ksef.mf.gov.pl",
        "up": probe_results["mf_ksef"]["up"],
        "ms": probe_results["mf_ksef"]["ms"],
        "vps_ms": probe_results["mf_ksef"]["ms"],
        "reliability": 100.0 if probe_results["mf_ksef"]["up"] else 0.0,
        "history": ksef_hist,
    },
    {
        "id": "nmvs",
        "name": "NMVS / PLMVS — Autentyczność Leków",
        "module": "Apteka Szpitalna • Weryfikacja serializacji opakowań leków",
        "up": nmvs_ok,
        "ms": nmvs_ms,
        "vps_ms": nmvs_ms,
        "reliability": nmvs_rel,
        "history": nmvs_hist,
    },
    {
        "id": "bazyl",
        "name": "Słownik Leków BAZYL (IQVIA / Karnet)",
        "module": "Apteka Szpitalna / Część Szara • karnet.waw.pl/bazyl.html",
        "up": probe_results["apt_bazyl"]["up"],
        "ms": probe_results["apt_bazyl"]["ms"],
        "vps_ms": probe_results["apt_bazyl"]["ms"],
        "reliability": 100.0 if probe_results["apt_bazyl"]["up"] else 0.0,
        "history": bazyl_hist,
    },
    {
        "id": "rpwdl",
        "name": "RPWDL — Rejestr Podmiotów Leczniczych",
        "module": "Księgi rejestrowe, struktura komórek i kody resortowe • rpwdl.ezdrowie.gov.pl",
        "up": probe_results["cez_rpwdl"]["up"],
        "ms": probe_results["cez_rpwdl"]["ms"],
        "vps_ms": probe_results["cez_rpwdl"]["ms"],
        "reliability": 100.0 if probe_results["cez_rpwdl"]["up"] else 0.0,
        "history": rpwdl_hist,
    },
    {
        "id": "szoi",
        "name": "Portal SZOI / ISI NFZ (Rozliczenia SWIAD / UMX)",
        "module": "Część Szara / Rozliczenia NFZ • aplikacje.nfz.gov.pl",
        "up": probe_results["nfz_szoi"]["up"],
        "ms": probe_results["nfz_szoi"]["ms"],
        "vps_ms": probe_results["nfz_szoi"]["ms"],
        "reliability": 100.0 if probe_results["nfz_szoi"]["up"] else 0.0,
        "history": szoi_hist,
    },
]

# Wykrycie niedostępności lub silnego spowolnienia usług centralnych PRZED uruchomieniem scrapera,
# aby w razie awarii automatycznie przełączyć scraper na częstsze pingowanie oficjalnych stron (co 3 minuty zamiast co 30 min).
degraded_services = []
for item in white_part + grey_part:
    sid = item["id"]
    rel_val = float(item.get("reliability") or 0)
    ms_val = float(item.get("ms") or 0)
    if (
        item["up"] == 0
        or (rel_val > 0 and rel_val < 65.0)
        or (rel_val > 0 and rel_val < 85.0 and ms_val > 3000)
        or ms_val > 6000
    ):
        degraded_services.append(f"{item['name']} ({item['ms']} ms, niezawodność: {item['reliability']}%)")

# ------------------------------------------------------------------------------
# 3. SEKCJA 3: ZWIADOWCA ZMIAN PRAWNYCH I TECHNICZNYCH (9 CZUJNIKÓW PUBLIC OSINT)
#    Tryb adaptacyjny:
#    - W normie: odświeżany co 30 min (1800 s)
#    - Podczas awarii / degradacji (degraded_services != []): odświeżany co 3 min (180 s)!
# ------------------------------------------------------------------------------
watcher_state = {}
if os.path.exists(watcher_cache_path):
    try:
        with open(watcher_cache_path, "r", encoding="utf-8") as wf:
            watcher_state = json.load(wf)
    except Exception:
        watcher_state = {}

last_watcher_run = int(watcher_state.get("last_run_ts") or 0)
prev_items_by_id = {x["id"]: x for x in (watcher_state.get("items") or []) if isinstance(x, dict) and "id" in x}

effective_watcher_ttl = 180 if degraded_services else 1800
scraper_mode = "emergency_fast_3m" if degraded_services else "normal_30m"

WATCHER_SOURCES = [
    {
        "id": "cez_komunikaty",
        "name": "1. CeZ — Komunikaty Techniczne i Przerwy Planowe P1",
        "lead_time": "Bieżące",
        "impact": "7 wykresów P1: e-Recepta (Lekarz/Apteka/DRR), e-Skierowanie, Zdarzenia Medyczne (RZM), Podpisy (WSP), e-Rejestracja (CeR), IPOM",
        "url": "https://ezdrowie.gov.pl/",
        "open_url": "https://ezdrowie.gov.pl/",
        "pattern": r'>\s*([^<>]{8,115}(?:Aktualizacja|prace serwisowe|awari|utrudnien|certyfikat|e-rejestracj|e-recept|e-skierow|refundac|niedostępn|przerw)[^<>]{0,80})\s*<',
    },
    {
        "id": "nfz_xml",
        "name": "2. NFZ — Aktualności Centrali i Komunikaty Systemowe (eWUŚ, SZOI, Kolejki, XML)",
        "lead_time": "Bieżące",
        "impact": "6 wykresów NFZ: eWUŚ (Ubezpieczenie), Portal SZOI/ISI, Kolejki (AP-KOLCE), Karty DiLO, Wyroby (eZWM), Rejestry (RAUT/ENDO)",
        "url": "https://www.nfz.gov.pl/aktualnosci/aktualnosci-centrali/",
        "open_url": "https://www.nfz.gov.pl/aktualnosci/aktualnosci-centrali/",
        "pattern": r'<a[^>]+href="[^"]*aktualnosci-centrali/[^"]+"[^>]*>([^<]{15,130})</a>',
    },
    {
        "id": "zus_ezla",
        "name": "3. ZUS — Komunikaty dla Lekarzy i Placówek (e-ZLA / PUE)",
        "lead_time": "Bieżące",
        "impact": "1 wykres ZUS: Elektroniczne zwolnienia lekarskie L4 (e-ZLA / ZUS PUE) i certyfikaty ZUS",
        "url": "https://www.zus.pl/ezla",
        "open_url": "https://www.zus.pl/ezla",
        "pattern": r'>\s*([^<>]{5,115}(?:e-ZLA|zwolnie|zaświadcze|Bieżące wyjaśnienia)[^<>]{0,80})\s*<',
    },
    {
        "id": "mf_ksef",
        "name": "4. MF — Komunikaty Techniczne KSeF 2.0 (e-Faktury)",
        "lead_time": "Bieżące",
        "impact": "1 wykres MF: Krajowy System e-Faktur (KSeF — Finanse / ERP / Apteka)",
        "url": "https://ksef.podatki.gov.pl/komunikaty-techniczne/",
        "open_url": "https://ksef.podatki.gov.pl/komunikaty-techniczne/",
        "pattern": r'komunikaty-techniczne/[^"]+"\s+title="([^"]{15,135})"',
    },
    {
        "id": "mz_refundacja",
        "name": "5. MZ — Obwieszczenia Refundacyjne Leków",
        "lead_time": "Bieżące",
        "impact": "3 wykresy lekowe: e-Recepta (Wystawianie), Realizacja w aptece (DRR) oraz Słownik leków BAZYL",
        "url": "https://www.gov.pl/web/zdrowie/obwieszczenia-ministra-zdrowia-lista-lekow-refundowanych",
        "open_url": "https://www.gov.pl/web/zdrowie/obwieszczenia-ministra-zdrowia-lista-lekow-refundowanych",
        "pattern": r'(Obwieszczenie\s+Ministra\s+Zdrowia[^<"]{10,115})',
    },
    {
        "id": "cez_interfejsy",
        "name": "6. CeZ — Dokumentacja Integracyjna i Certyfikaty P1 (.zip)",
        "lead_time": "Bieżące",
        "impact": "7 wykresów P1: Certyfikaty TLS/WSS (WSP), e-Recepta, e-Skierowanie, EDM/RZM, CeR, IPOM",
        "url": "https://ezdrowie.gov.pl/portal/home/dla-dostawcow/interfejsy",
        "open_url": "https://ezdrowie.gov.pl/portal/home/dla-dostawcow/interfejsy",
        "pattern": r'(Dokumentacja\s+integracyjna[^<"\n]{5,95}|[a-zA-Z0-9_\-]{6,65}\.zip)',
    },
    {
        "id": "nfz_slowniki",
        "name": "7. NFZ — Baza Słowników Centralnych (ICD-9 / ICD-10 / JGP)",
        "lead_time": "Bieżące",
        "impact": "4 wykresy NFZ: Portal rozliczeniowy SZOI/ISI, Wyroby medyczne (eZWM), DiLO, Rejestry JGP (RAUT/ENDO)",
        "url": "https://slowniki.nfz.gov.pl/",
        "open_url": "https://slowniki.nfz.gov.pl/",
        "pattern": r'([A-ZŻŹĆĄŚĘŁÓŃ][a-zA-Z0-9ąćęłńóśźżĄĆĘŁŃÓŚŹŻ\s\-\.\(\)/]{15,110}202[567][0-9\-\.]*)',
    },
    {
        "id": "nfz_zarzadzenia",
        "name": "8. NFZ — Baza Aktów Własnych (BAW — Zarządzenia /DSOZ i /DGL)",
        "lead_time": "Bieżące",
        "impact": "Rozliczenia NFZ (SZOI/ISI): wyceny świadczeń, taryfy szpitalne/AOS i warunki grup JGP (baw.nfz.gov.pl)",
        "url": "https://www.nfz.gov.pl/zarzadzenia-prezesa/zarzadzenia-prezesa-nfz/",
        "open_url": "https://baw.nfz.gov.pl/NFZ/tabBrowser/mainPage",
        "pattern": r'(Zarz[aą]dzenie\s+Nr\s+[0-9]+/202[567]/[A-Z]+)',
    },
    {
        "id": "ezdrowie_ikp",
        "name": "9. CeZ — Systemy IT i Rejestry Medyczne (RPWDL / RPRM / RDL / EDM)",
        "lead_time": "Bieżące",
        "impact": "2 wykresy CeZ: Rejestr Podmiotów Leczniczych (RPWDL) oraz Zdarzenia Medyczne (RZM / EDM)",
        "url": "https://ezdrowie.gov.pl/portal/home/systemy-it",
        "open_url": "https://ezdrowie.gov.pl/portal/home/systemy-it",
        "pattern": r'>\s*([^<>]{12,115}(?:Rejestr|RPWDL|RPRM|RDL|System|EDM|e-Zdrowie|Zdarzeń)[^<>]{0,70})\s*<',
    },
]

watcher_items = []
new_publications_alerts = []

if force_watcher or (now_ts - last_watcher_run) >= effective_watcher_ttl or not prev_items_by_id:
    for src in WATCHER_SOURCES:
        sid = src["id"]
        code, ms, body = http_get(src["url"], timeout=7.0)
        prev_item = prev_items_by_id.get(sid) or {}
        if code in (200, 301, 302) and body:
            clean_body = re.sub(r"\s+", " ", html.unescape(body))
            matches = re.findall(src["pattern"], clean_body, flags=re.IGNORECASE)
            cleaned_matches = []
            for m in matches:
                s = re.sub(r"<[^>]+>", "", str(m)).strip()
                if len(s) >= 8 and not any(ig in s.lower() for ig in ("cookie", "ciastecz", "menu", "nawigacja", "szukaj", "logowanie", "zaloguj się", "infolinia", "portal - ezdrowie", "aktualności")):
                    cleaned_matches.append(s[:260])
            latest_finding = cleaned_matches[0] if cleaned_matches else (prev_item.get("latest_finding") or "Strona aktywna — brak nowych plików w nagłówku")
            resolved_item_url = src.get("open_url") or src["url"]
            if sid == "cez_komunikaty":
                m_cez = re.search(
                    r'<p class="articleAddData">([^<]+)</p>\s*<h3 class="articleTitle">([^<]+)</h3>\s*<p class="articleText">([^<]+)</p>.*?href\s*=\s*"(/portal/artykul/[^"]+)"',
                    clean_body,
                    flags=re.IGNORECASE,
                )
                if m_cez:
                    cez_title = m_cez.group(2).strip()
                    cez_text = m_cez.group(3).strip()
                    resolved_item_url = urllib.parse.urljoin(src["url"], m_cez.group(4).strip())
                    latest_finding = f"{cez_title} — {cez_text}"[:280] if cez_text else cez_title[:260]
            elif sid == "ezdrowie_ikp":
                m_ikp = re.search(
                    r'<h4 class="articleListBigBoxTitle">([^<]+)</h4>\s*<p class="articleListBigBoxAddData">([^<]+)</p>\s*</div>\s*<p class="articleListBigBoxText">([^<]+)<.*?href\s*=\s*"(/portal/artykul/[^"]+)"',
                    clean_body,
                    flags=re.IGNORECASE,
                )
                if m_ikp:
                    ikp_title = m_ikp.group(1).strip()
                    ikp_text = m_ikp.group(3).strip()
                    resolved_item_url = urllib.parse.urljoin(src["url"], m_ikp.group(4).strip())
                    latest_finding = f"{ikp_title} — {ikp_text}"[:280] if ikp_text else ikp_title[:260]
            elif sid == "mf_ksef":
                m_href = re.search(r'href="([^"]*komunikaty-techniczne/[^"]+)"\s+title="([^"]{15,160})"', clean_body, flags=re.IGNORECASE)
                if m_href:
                    resolved_item_url = urllib.parse.urljoin(src["url"], m_href.group(1).strip())
                    ksef_title = m_href.group(2).strip()
                    acode, _, abody = http_get(resolved_item_url, timeout=6.0)
                    if acode in (200, 301, 302) and abody:
                        aclean = re.sub(r"\s+", " ", html.unescape(abody))
                        m_markup = re.search(r'<div class="markup[^"]*">(.*?)</div>', aclean, flags=re.IGNORECASE)
                        if m_markup:
                            paras = [
                                re.sub(r"<[^>]+>", "", p).strip()
                                for p in re.findall(r"<p[^>]*>(.*?)</p>", m_markup.group(1), flags=re.IGNORECASE)
                            ]
                            paras = [p for p in paras if len(p) >= 15]
                            if paras:
                                lead_p = paras[0]
                                assure_p = next((p for p in paras[1:] if "bez zakłóceń" in p.lower() or "prawidłowo" in p.lower()), "")
                                if assure_p:
                                    latest_finding = f"{lead_p} ({assure_p})"[:300]
                                else:
                                    latest_finding = f"{ksef_title}: {lead_p}"[:300]
            elif sid == "nfz_xml":
                m_nfz = re.search(r'<a[^>]+href="([^"]*aktualnosci-centrali/[^"]+)"[^>]*>([^<]{15,160})</a>(?:\s*</h3>\s*(?:</div>\s*)?(?:<div class="date">\s*(\d{2}\.\d{2}\.\d{4})\s*</div>)?)?', clean_body, flags=re.IGNORECASE)
                if m_nfz:
                    resolved_item_url = urllib.parse.urljoin(src["url"], m_nfz.group(1).strip())
                    nfz_title = m_nfz.group(2).strip()
                    nfz_date = (m_nfz.group(3) or "").strip()
                    latest_finding = f"{nfz_title} (publikacja: {nfz_date})" if nfz_date else nfz_title
            if sid == "nfz_zarzadzenia" and "baw.nfz.gov.pl" not in latest_finding:
                latest_finding = f"{latest_finding} (pełny tekst w BAW: baw.nfz.gov.pl)"
            sig_source = "|".join(cleaned_matches[:3]) if cleaned_matches else latest_finding
            sig_hash = hashlib.sha256(sig_source.encode("utf-8", errors="ignore")).hexdigest()[:12]
            prev_hash = prev_item.get("hash", "")
            changed_today = bool(prev_hash and prev_hash != sig_hash)
            last_change_dt = now_iso if changed_today else (prev_item.get("last_change") or now_iso)
            if changed_today:
                new_publications_alerts.append(f"• {src['name']}: {latest_finding}")
            watcher_items.append({
                "id": sid,
                "name": src["name"],
                "lead_time": src["lead_time"],
                "impact": src["impact"],
                "url": resolved_item_url,
                "up": 1,
                "ms": ms,
                "latest_finding": latest_finding,
                "hash": sig_hash,
                "changed": changed_today,
                "last_checked": now_iso,
                "last_change": last_change_dt,
            })
        else:
            watcher_items.append({
                "id": sid,
                "name": src["name"],
                "lead_time": src["lead_time"],
                "impact": src["impact"],
                "url": prev_item.get("url") or src.get("open_url") or src["url"],
                "up": 1 if prev_item.get("latest_finding") else 0,
                "ms": ms,
                "latest_finding": prev_item.get("latest_finding") or f"Oczekiwanie na kolejny skan (HTTP {code})",
                "hash": prev_item.get("hash") or "",
                "changed": False,
                "last_checked": now_iso,
                "last_change": prev_item.get("last_change") or now_iso,
            })
    try:
        write_file_atomic(
            watcher_cache_path,
            json.dumps({"last_run_ts": now_ts, "items": watcher_items}, ensure_ascii=False, indent=2),
            0o644,
        )
    except Exception:
        pass
else:
    for src in WATCHER_SOURCES:
        sid = src["id"]
        cached = dict(prev_items_by_id.get(sid) or {})
        cached["id"] = sid
        cached["name"] = src["name"]
        cached["lead_time"] = src["lead_time"]
        cached["impact"] = src["impact"]
        cached["url"] = cached.get("url") or src.get("open_url") or src["url"]
        watcher_items.append(cached)

# Automatyczne karmienie dynamicznego pliku kontekstu AI (storage/p1_live_feed.txt) komunikatami ze scrapera oraz statusem awarii (bez modyfikacji śledzonego w Git data/radar-p1-knowledge.txt)
if ai_kb_path:
    try:
        feed_lines = [
            "13. AKTUALNE KOMUNIKATY WYKRYTE PRZEZ SCRAPER ZWIADOWCY (AUTO-FEED DO AI):",
        ]
        official_maint = [
            w for w in watcher_items
            if any(k in str(w.get("latest_finding", "")).lower() for k in ("prace serwisowe", "przerwa", "awari", "utrudnien", "niedostępn", "planowan"))
            and "brak nowych plików" not in str(w.get("latest_finding", "")).lower()
        ]
        if degraded_services and not official_maint:
            feed_lines.append(
                "🚨 AWARIA BEZ OFICJALNEGO KOMUNIKATU: Wykryto niedostępność/degradację usług: "
                + "; ".join(degraded_services)
                + " — na oficjalnych stronach CeZ / NFZ / ZUS / MF NIE OPUBLIKOWANO jeszcze komunikatu o pracach ani awarii."
            )
        elif degraded_services and official_maint:
            feed_lines.append(
                "⚠️ AKTYWNA AWARIA Z OFICJALNYM KOMUNIKATEM: Usługi z problemami: "
                + "; ".join(degraded_services)
            )
        else:
            feed_lines.append("Status usług centralnych: WSZYSTKIE USŁUGI W NORMIE (brak awarii).")
        for w in watcher_items:
            finding = str(w.get("latest_finding") or "Brak danych").strip()
            chg = " [NOWA ZMIANA!]" if w.get("changed") else ""
            feed_lines.append(f"- {w.get('name')}:{chg} {finding} (wpływ: {w.get('impact')}, źródło: {w.get('url')})")
        new_feed_text = "\n".join(feed_lines) + "\n"
        old_feed_text = ""
        if os.path.exists(ai_kb_path):
            with open(ai_kb_path, "r", encoding="utf-8") as kbf:
                old_feed_text = kbf.read()
        if new_feed_text != old_feed_text:
            write_file_atomic(ai_kb_path, new_feed_text, 0o644)
    except Exception:
        pass

if new_publications_alerts:
    send_ntfy(
        "📦 Zwiadowca e-Zdrowie: Nowa publikacja CeZ / NFZ!",
        "Wykryto zmianę na stronach źródłowych:\n" + "\n".join(new_publications_alerts),
        priority="default",
        tags="package,hospital",
    )

# ------------------------------------------------------------------------------
# 4. ALERTY NTFY PRZY AWARII CENTRALNEJ W WARSZAWIE (Z COOLDOWNEM 4H)
# ------------------------------------------------------------------------------
alert_state = {}
if os.path.exists(alert_state_path):
    try:
        with open(alert_state_path, "r", encoding="utf-8") as af:
            alert_state = json.load(af)
    except Exception:
        alert_state = {}

if degraded_services:
    last_outage_alert = int(alert_state.get("last_outage_ts") or 0)
    if (now_ts - last_outage_alert) >= 14400:
        alert_state["last_outage_ts"] = now_ts
        send_ntfy(
            "🚨 AWARIA CENTRALNA P1 / NFZ (Warszawa)!",
            "Wykryto niedostępność lub silną degradację usług centralnych:\n• " + "\n• ".join(degraded_services),
            priority="high",
            tags="rotating_light,hospital",
        )
        try:
            write_file_atomic(alert_state_path, json.dumps(alert_state), 0o644)
        except Exception:
            pass

# ------------------------------------------------------------------------------
# 5. ZAPIS PLIKU JSON DLA DASHBOARDU (/radar) ORAZ METRYK PROMETHEUSA (*.prom)
# ------------------------------------------------------------------------------
white_up_cnt = sum(1 for x in white_part if x["up"] == 1 or (x["up"] == -1 and float(x.get("vps_ms") or 0) > 0))
grey_up_cnt = sum(1 for x in grey_part if x["up"] == 1 or (x["up"] == -1 and float(x.get("vps_ms") or 0) > 0))
watcher_up_cnt = sum(1 for x in watcher_items if x.get("up") == 1)

radar_payload = {
    "updated_at": now_iso,
    "timestamp": now_ts,
    "summary": {
        "white_total": len(white_part),
        "white_up": white_up_cnt,
        "grey_total": len(grey_part),
        "grey_up": grey_up_cnt,
        "watcher_total": len(watcher_items),
        "watcher_up": watcher_up_cnt,
        "degraded": degraded_services,
    },
    "chart_series": chart_series,
    "white_part": white_part,
    "grey_part": grey_part,
    "watcher_items": watcher_items,
    "nfz_regions": nfz_regions,
    "custom_history": custom_history_out,
}

write_file_atomic(radar_json_path, json.dumps(radar_payload, ensure_ascii=False), 0o644)

prom_lines = [
    "# HELP ezdrowie_radar_last_sync_timestamp_seconds Czas ostatniej synchronizacji Radaru e-Zdrowia P1/NFZ/KSeF",
    "# TYPE ezdrowie_radar_last_sync_timestamp_seconds gauge",
    f"ezdrowie_radar_last_sync_timestamp_seconds {now_ts}",
    "# HELP ezdrowie_service_up Status dostepnosci uslugi centralnej e-Zdrowia (1 = UP, 0 = DOWN)",
    "# TYPE ezdrowie_service_up gauge",
    "# HELP ezdrowie_service_duration_ms Czas odpowiedzi uslugi centralnej e-Zdrowia w milisekundach",
    "# TYPE ezdrowie_service_duration_ms gauge",
    "# HELP ezdrowie_service_reliability_percent Wskaznik niezawodnosci uslugi centralnej e-Zdrowia (0-100%)",
    "# TYPE ezdrowie_service_reliability_percent gauge",
]

for s in chart_series:
    sid = s["id"]
    lbl = s["label"].replace('"', '\\"')
    prom_lines.append(f'ezdrowie_service_up{{service="{sid}",name="{lbl}"}} {1 if s["up"] == 1 else 0}')
    prom_lines.append(f'ezdrowie_service_duration_ms{{service="{sid}",name="{lbl}"}} {s["ms"]}')
    prom_lines.append(f'ezdrowie_service_reliability_percent{{service="{sid}",name="{lbl}"}} {s["reliability"]}')

for item in white_part:
    sid = item["id"]
    nm = item["name"].replace('"', '\\"')
    prom_lines.append(f'ezdrowie_part_status{{part="biala",service="{sid}",name="{nm}"}} {1 if item["up"] == 1 else 0}')
    prom_lines.append(f'ezdrowie_part_duration_ms{{part="biala",service="{sid}",name="{nm}"}} {item["ms"]}')

for item in grey_part:
    sid = item["id"]
    nm = item["name"].replace('"', '\\"')
    prom_lines.append(f'ezdrowie_part_status{{part="szara",service="{sid}",name="{nm}"}} {1 if item["up"] == 1 else 0}')
    prom_lines.append(f'ezdrowie_part_duration_ms{{part="szara",service="{sid}",name="{nm}"}} {item["ms"]}')

prom_lines.append("# HELP ezdrowie_part_up_services Liczba dzialajacych uslug w Czesci Bialej i Czesci Szarej")
prom_lines.append("# TYPE ezdrowie_part_up_services gauge")
prom_lines.append(f'ezdrowie_part_up_services{{part="biala"}} {white_up_cnt}')
prom_lines.append(f'ezdrowie_part_up_services{{part="szara"}} {grey_up_cnt}')
prom_lines.append("# HELP ezdrowie_part_total_services Laczna liczba monitorowanych uslug w Czesci Bialej i Czesci Szarej")
prom_lines.append("# TYPE ezdrowie_part_total_services gauge")
prom_lines.append(f'ezdrowie_part_total_services{{part="biala"}} {len(white_part)}')
prom_lines.append(f'ezdrowie_part_total_services{{part="szara"}} {len(grey_part)}')
prom_lines.append("# HELP ezdrowie_watcher_sources_up Liczba dostepnych zrodel Zwiadowcy Zmian Legislacyjnych CeZ/NFZ/MZ/KSeF")
prom_lines.append("# TYPE ezdrowie_watcher_sources_up gauge")
prom_lines.append(f"ezdrowie_watcher_sources_up {watcher_up_cnt}")
prom_lines.append("# HELP ezdrowie_watcher_up Status zwiadowcy zmian prawnych i technicznych CeZ/NFZ/MZ/KSeF")
prom_lines.append("# TYPE ezdrowie_watcher_up gauge")
for w in watcher_items:
    wid = w["id"]
    wnm = w["name"].replace('"', '\\"')
    prom_lines.append(f'ezdrowie_watcher_up{{source="{wid}",name="{wnm}"}} {1 if w.get("up") == 1 else 0}')

write_file_atomic(prom_path, "\n".join(prom_lines) + "\n", 0o644)
PYEOF

# Synchronizacja pliku JSON bezpośrednio do wolumenu kontenera ai-router (ai_router_storage -> /app/storage/p1_radar.json)
if sudo -n test -d /var/lib/docker/volumes/ai_router_storage/_data 2>/dev/null; then
    sudo -n install -m 644 "${RADAR_JSON}" /var/lib/docker/volumes/ai_router_storage/_data/p1_radar.json 2>/dev/null || true
    if [[ -f "${HISTORY_ARCHIVE}" ]]; then
        sudo -n install -m 644 "${HISTORY_ARCHIVE}" /var/lib/docker/volumes/ai_router_storage/_data/p1_history_archive.json 2>/dev/null || true
    fi
    if [[ -f "${AI_KB_FILE}" ]]; then
        sudo -n install -m 644 "${AI_KB_FILE}" /var/lib/docker/volumes/ai_router_storage/_data/p1_live_feed.txt 2>/dev/null || true
    fi
fi

