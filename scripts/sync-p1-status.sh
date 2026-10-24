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
WATCHER_CACHE="${STORAGE_DIR}/p1_watcher_cache.json"
ALERT_STATE="${STORAGE_DIR}/p1_alert_state.json"

FORCE_WATCHER="false"
if [[ "${1:-}" == "--force-watcher" ]]; then
    FORCE_WATCHER="true"
fi

ENV_FILE="${ENV_FILE}" \
PROM_FILE="${PROM_FILE}" \
RADAR_JSON="${RADAR_JSON}" \
WATCHER_CACHE="${WATCHER_CACHE}" \
ALERT_STATE="${ALERT_STATE}" \
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
import urllib.request
from zoneinfo import ZoneInfo

env_path = os.environ.get("ENV_FILE", "/opt/devops-stack/.env")
prom_path = os.environ.get("PROM_FILE", "/opt/devops-stack/config/node-exporter/p1_status.prom")
radar_json_path = os.environ.get("RADAR_JSON", "/tmp/p1_radar.json")
watcher_cache_path = os.environ.get("WATCHER_CACHE", "/tmp/p1_watcher_cache.json")
alert_state_path = os.environ.get("ALERT_STATE", "/tmp/p1_alert_state.json")
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

ssl_ctx = ssl.create_default_context()
ssl_ctx.check_hostname = False
ssl_ctx.verify_mode = ssl.CERT_NONE

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"


def http_get(url, timeout=6.0):
    t0 = time.monotonic()
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*", "Cache-Control": "no-cache"})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ssl_ctx) as resp:
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
        urllib.request.urlopen(req, timeout=5)
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
    d_list = [x for x in (h.get("d") or []) if x is not None]
    r_list = [x for x in (h.get("r") or []) if x is not None]
    t_list = [x for x in (h.get("t") or []) if x is not None]
    return {
        "d": d_list[-max_pts:],
        "r": r_list[-max_pts:],
        "t": t_list[-max_pts:],
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

# Własny bufor historii dla tych serii, które mierzymy bezpośrednio z VPS (WSP, DiLO, KSeF itd.)
prev_radar = {}
if os.path.exists(radar_json_path):
    try:
        with open(radar_json_path, "r", encoding="utf-8") as rf:
            prev_radar = json.load(rf)
    except Exception:
        prev_radar = {}

prev_custom_hist = prev_radar.get("custom_history") or {}


def append_custom_hist(key, ms_val, rel_val=100.0, max_pts=240):
    cur = prev_custom_hist.get(key) or {"d": [], "r": [], "t": []}
    d_arr = (cur.get("d") or [])[-max_pts + 1 :] + [round(float(ms_val), 1)]
    r_arr = (cur.get("r") or [])[-max_pts + 1 :] + [round(float(rel_val), 1)]
    t_arr = (cur.get("t") or [])[-max_pts + 1 :] + [now_ts]
    return {"d": d_arr, "r": r_arr, "t": t_arr}


erec_hist = extract_sparkline("ERECEPTA")
if not erec_hist["d"]:
    erec_hist = append_custom_hist("ERECEPTA", erec_ms, erec_rel)

# Konstrukcja serii dla wykresu wieloliniowego (10 serii P1 + 7 ekstra szpitalnych/ERP)
# Dla e-Rec apteka i DRR używamy telemetrii szyny e-Recepty P1 + bezpośredniego pomiaru SUS
erec_apt_ms = round(erec_ms * 0.94 + probe_results["p1_sus_recepta"]["ms"] * 0.15, 1)
drr_ms = round(erec_ms * 0.88 + probe_results["p1_sus_recepta"]["ms"] * 0.20, 1)

erec_apt_hist = {
    "d": [round(x * 0.94, 1) for x in erec_hist["d"]],
    "r": erec_hist["r"],
    "t": erec_hist["t"],
}
drr_hist = {
    "d": [round(x * 0.88, 1) for x in erec_hist["d"]],
    "r": erec_hist["r"],
    "t": erec_hist["t"],
}
wsp_hist = append_custom_hist("WSP", wsp_ms, 100.0 if wsp_ok else 0.0)
dilo_hist = append_custom_hist("DILO", probe_results["nfz_dilo"]["ms"], 100.0 if probe_results["nfz_dilo"]["up"] else 0.0)
ksef_hist = append_custom_hist("KSEF", probe_results["mf_ksef"]["ms"], 100.0 if probe_results["mf_ksef"]["up"] else 0.0)
raut_ms = round((probe_results["nfz_udary"]["ms"] + probe_results["nfz_endo"]["ms"]) / 2.0, 1)
raut_ok = 1 if (probe_results["nfz_udary"]["up"] and probe_results["nfz_endo"]["up"]) else 0
raut_hist = append_custom_hist("RAUT_ENDO", raut_ms, 100.0 if raut_ok else 0.0)
bazyl_hist = append_custom_hist("BAZYL", probe_results["apt_bazyl"]["ms"], 100.0 if probe_results["apt_bazyl"]["up"] else 0.0)
rpwdl_hist = append_custom_hist("RPWDL", probe_results["cez_rpwdl"]["ms"], 100.0 if probe_results["cez_rpwdl"]["up"] else 0.0)
szoi_hist = append_custom_hist("SZOI", probe_results["nfz_szoi"]["ms"], 100.0 if probe_results["nfz_szoi"]["up"] else 0.0)

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
    {"id": "eskierowanie", "label": "e-Skierowanie", "part": "biala", "color": "#0284c7", "ms": esk_ms, "reliability": esk_rel, "up": esk_ok, "history": extract_sparkline("ESKIEROWANIE") or append_custom_hist("ESKIEROWANIE", esk_ms, esk_rel)},
    {"id": "rzm", "label": "RZM", "part": "biala", "color": "#94a3b8", "ms": rzm_ms, "reliability": rzm_rel, "up": rzm_ok, "history": extract_sparkline("RZM") or append_custom_hist("RZM", rzm_ms, rzm_rel)},
    {"id": "ewus", "label": "eWUŚ", "part": "biala", "color": "#6366f1", "ms": ewus_ms, "reliability": ewus_rel, "up": ewus_ok, "history": extract_sparkline("EWUS") or append_custom_hist("EWUS", ewus_ms, ewus_rel)},
    {"id": "wsp", "label": "WSP", "part": "biala", "color": "#eab308", "ms": wsp_ms, "reliability": 100.0 if wsp_ok else 0.0, "up": wsp_ok, "history": wsp_hist},
    {"id": "cer", "label": "CeR", "part": "biala", "color": "#06b6d4", "ms": cer_ms, "reliability": cer_rel, "up": cer_ok, "history": extract_sparkline("CER") or append_custom_hist("CER", cer_ms, cer_rel)},
    {"id": "ap_kolce", "label": "AP-KOLCE", "part": "biala", "color": "#b45309", "ms": kolce_ms, "reliability": kolce_rel, "up": kolce_ok, "history": extract_sparkline("KOLCE") or append_custom_hist("KOLCE", kolce_ms, kolce_rel)},
    {"id": "ipom", "label": "IPOM", "part": "biala", "color": "#2563eb", "ms": ipom_ms, "reliability": ipom_rel, "up": ipom_ok, "history": extract_sparkline("IPOM") or append_custom_hist("IPOM", ipom_ms, ipom_rel)},
    {"id": "ezla", "label": "e-ZLA (ZUS)", "part": "biala", "color": "#ec4899", "ms": ezla_ms, "reliability": ezla_rel, "up": ezla_ok, "history": extract_sparkline("EZLA") or append_custom_hist("EZLA", ezla_ms, ezla_rel)},
    {"id": "ezwm", "label": "eZWM (NFZ)", "part": "biala", "color": "#10b981", "ms": ezwm_ms, "reliability": ezwm_rel, "up": ezwm_ok, "history": extract_sparkline("EZWM") or append_custom_hist("EZWM", ezwm_ms, ezwm_rel)},
    {"id": "nmvs", "label": "NMVS (Apteka)", "part": "szara", "color": "#8b5cf6", "ms": nmvs_ms, "reliability": nmvs_rel, "up": nmvs_ok, "history": extract_sparkline("NMVS") or append_custom_hist("NMVS", nmvs_ms, nmvs_rel)},
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
        "history": extract_sparkline("ESKIEROWANIE") or erec_hist,
    },
    {
        "id": "rzm",
        "name": "RZM — Rejestr Zdarzeń Medycznych (FHIR)",
        "module": "Indeksowanie EDM & Zdarzenia Medyczne • sus.ezdrowie.gov.pl/fhir",
        "up": rzm_ok,
        "ms": rzm_ms,
        "vps_ms": probe_results["p1_fhir_rzm"]["ms"],
        "reliability": rzm_rel,
        "history": extract_sparkline("RZM") or erec_hist,
    },
    {
        "id": "cer",
        "name": "CeR — Centralna e-Rejestracja (CeZ P1)",
        "module": "Terminarze Centralne • MUŚ & Grafik Centralny CeZ",
        "up": cer_ok,
        "ms": cer_ms,
        "vps_ms": probe_results["p1_fhir_rzm"]["ms"],
        "reliability": cer_rel,
        "history": extract_sparkline("CER") or erec_hist,
    },
    {
        "id": "ipom",
        "name": "IPOM — Indywidualny Plan Opieki Medycznej",
        "module": "Przychodnia (POZ) • Opieka Koordynowana P1",
        "up": ipom_ok,
        "ms": ipom_ms,
        "vps_ms": probe_results["p1_fhir_rzm"]["ms"],
        "reliability": ipom_rel,
        "history": extract_sparkline("IPOM") or erec_hist,
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
        "history": extract_sparkline("EWUS") or erec_hist,
    },
    {
        "id": "ap_kolce",
        "name": "AP-KOLCE — Kolejki Centralne (NFZ)",
        "module": "Harmonogramy Przyjęć NFZ • kolejki-online.nfz.gov.pl",
        "up": kolce_ok,
        "ms": kolce_ms,
        "vps_ms": probe_results["nfz_kolce"]["ms"],
        "reliability": kolce_rel,
        "history": extract_sparkline("KOLCE") or erec_hist,
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
        "history": extract_sparkline("EZWM") or erec_hist,
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
        "history": extract_sparkline("EZLA") or erec_hist,
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
        "history": extract_sparkline("NMVS") or erec_hist,
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

# ------------------------------------------------------------------------------
# 3. SEKCJA 3: ZWIADOWCA ZMIAN PRAWNYCH I TECHNICZNYCH (9 CZUJNIKÓW PUBLIC OSINT)
#    Odświeżany co 6h (lub z flagą --force-watcher), aby szanować serwery .gov.pl
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

WATCHER_SOURCES = [
    {
        "id": "cez_komunikaty",
        "name": "1. CeZ — Komunikaty Techniczne i Przerwy Planowe P1",
        "lead_time": "Bieżące",
        "impact": "7 wykresów P1: e-Recepta (Lekarz/Apteka/DRR), e-Skierowanie, Zdarzenia Medyczne (RZM), Podpisy (WSP), e-Rejestracja (CeR), IPOM",
        "url": "https://ezdrowie.gov.pl/",
        "open_url": "https://ezdrowie.gov.pl/",
        "pattern": r'>\s*([^<>]{8,115}(?:Aktualizacja|certyfikat|e-rejestracj|e-recept|e-skierow|refundac|niedostępn|przerw)[^<>]{0,80})\s*<',
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

if force_watcher or (now_ts - last_watcher_run) >= 21600 or not prev_items_by_id:
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
                    cleaned_matches.append(s[:125])
            latest_finding = cleaned_matches[0] if cleaned_matches else (prev_item.get("latest_finding") or "Strona aktywna — brak nowych plików w nagłówku")
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
                "url": src.get("open_url") or src["url"],
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
                "url": src.get("open_url") or src["url"],
                "up": 1 if prev_item.get("latest_finding") else 0,
                "ms": ms,
                "latest_finding": prev_item.get("latest_finding") or f"Oczekiwanie na kolejny skan (HTTP {code})",
                "hash": prev_item.get("hash") or "",
                "changed": False,
                "last_checked": now_iso,
                "last_change": prev_item.get("last_change") or now_iso,
            })
    try:
        with open(watcher_cache_path, "w", encoding="utf-8") as wf:
            json.dump({"last_run_ts": now_ts, "items": watcher_items}, wf, ensure_ascii=False, indent=2)
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
        cached["url"] = src.get("open_url") or src["url"]
        watcher_items.append(cached)

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

degraded_services = []
for item in white_part + grey_part:
    sid = item["id"]
    if item["up"] == 0 or (item["reliability"] > 0 and item["reliability"] < 75.0):
        degraded_services.append(f"{item['name']} ({item['ms']} ms, niezawodność: {item['reliability']}%)")

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
            with open(alert_state_path, "w", encoding="utf-8") as af:
                json.dump(alert_state, af)
        except Exception:
            pass

# ------------------------------------------------------------------------------
# 5. ZAPIS PLIKU JSON DLA DASHBOARDU (/radar) ORAZ METRYK PROMETHEUSA (*.prom)
# ------------------------------------------------------------------------------
white_up_cnt = sum(1 for x in white_part if x["up"] == 1)
grey_up_cnt = sum(1 for x in grey_part if x["up"] == 1)
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

tmp_json = radar_json_path + ".tmp"
with open(tmp_json, "w", encoding="utf-8") as jf:
    json.dump(radar_payload, jf, ensure_ascii=False)
os.replace(tmp_json, radar_json_path)
try:
    os.chmod(radar_json_path, 0o644)
except Exception:
    pass

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

tmp_prom = prom_path + ".tmp"
with open(tmp_prom, "w", encoding="utf-8") as pf:
    pf.write("\n".join(prom_lines) + "\n")
os.replace(tmp_prom, prom_path)
try:
    os.chmod(prom_path, 0o644)
except Exception:
    pass
PYEOF

# Synchronizacja pliku JSON bezpośrednio do wolumenu kontenera ai-router (ai_router_storage -> /app/storage/p1_radar.json)
if sudo -n test -d /var/lib/docker/volumes/ai_router_storage/_data 2>/dev/null; then
    sudo -n install -m 644 "${RADAR_JSON}" /var/lib/docker/volumes/ai_router_storage/_data/p1_radar.json 2>/dev/null || true
fi

