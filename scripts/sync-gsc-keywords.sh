#!/usr/bin/env bash
# ==============================================================================
# TWOJASTRONAWWW DEVOPS STACK - GOOGLE SEARCH CONSOLE KEYWORDS SYNC (0 KB JS)
# ==============================================================================
# Pobiera organiczne słowa kluczowe (zapytania Google, kliknięcia, wyświetlenia,
# średnią pozycję z ostatnich 28 dni) bezpośrednio z Google Search Console API
# po stronie serwera VPS i zasila wewnętrzny kolektor AI Routera (/analytics).
# Zero skryptów śledzących na stronach klientów, 100% zgodność z RODO / ISO 27001.
# ==============================================================================

set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/devops-stack}"
ENV_FILE="${STACK_DIR}/.env"
if [[ ! -f "$ENV_FILE" && -f "./.env" ]]; then
    ENV_FILE="./.env"
fi

if [[ -f "$ENV_FILE" ]]; then
    GSC_SERVICE_ACCOUNT_JSON="${GSC_SERVICE_ACCOUNT_JSON:-$(grep -E '^GSC_SERVICE_ACCOUNT_JSON=' "$ENV_FILE" | head -n 1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)}"
    GSC_SITES="${GSC_SITES:-$(grep -E '^GSC_SITES=' "$ENV_FILE" | head -n 1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)}"
fi

GSC_SERVICE_ACCOUNT_JSON="${GSC_SERVICE_ACCOUNT_JSON:-}"
GSC_SITES="${GSC_SITES:-katosalsahub=sc-domain:katosalsahub.pl,dancepuls=sc-domain:dancepuls.pl,fuegolingua=sc-domain:fuegolingua.pl,twojastronawww=sc-domain:twojastronawww.pl}"
AI_ROUTER_URL="${AI_ROUTER_URL:-http://127.0.0.1:8085/analytics}"

if [[ -z "$GSC_SERVICE_ACCOUNT_JSON" ]]; then
    echo "[GSC-SYNC] Brak skonfigurowanego GSC_SERVICE_ACCOUNT_JSON w .env — pomijam synchronizację słów kluczowych Google Search Console."
    exit 0
fi

export GSC_SERVICE_ACCOUNT_JSON
export GSC_SITES
export AI_ROUTER_URL

python3 - <<'PYEOF'
import base64
import datetime
import json
import os
import subprocess
import tempfile
import urllib.parse
import urllib.request

raw_sa = os.environ.get("GSC_SERVICE_ACCOUNT_JSON", "").strip()
sites_cfg = os.environ.get("GSC_SITES", "").strip()
router_url = os.environ.get("AI_ROUTER_URL", "http://127.0.0.1:8085/analytics")

if os.path.isfile(raw_sa):
    with open(raw_sa, "r", encoding="utf-8") as f:
        sa = json.load(f)
else:
    try:
        decoded = base64.b64decode(raw_sa).decode("utf-8")
        sa = json.loads(decoded)
    except Exception:
        sa = json.loads(raw_sa)

client_email = sa["client_email"]
private_key = sa["private_key"]
token_uri = sa.get("token_uri", "https://oauth2.googleapis.com/token")

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")

now = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode("utf-8"))
claim = b64url(json.dumps({
    "iss": client_email,
    "scope": "https://www.googleapis.com/auth/webmasters.readonly",
    "aud": token_uri,
    "iat": now,
    "exp": now + 3600
}).encode("utf-8"))
signing_input = f"{header}.{claim}".encode("ascii")

with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as kf:
    kf.write(private_key)
    key_path = kf.name

try:
    sig = subprocess.check_output(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input
    )
finally:
    try:
        os.remove(key_path)
    except OSError:
        pass

jwt_assertion = f"{header}.{claim}.{b64url(sig)}"
token_req_data = urllib.parse.urlencode({
    "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
    "assertion": jwt_assertion
}).encode("utf-8")

req = urllib.request.Request(token_uri, data=token_req_data, headers={"Content-Type": "application/x-www-form-urlencoded"})
with urllib.request.urlopen(req, timeout=10) as resp:
    access_token = json.loads(resp.read().decode("utf-8"))["access_token"]

print(f"[GSC-SYNC] Pomyślna autoryzacja OAuth2 dla konta: {client_email}")

try:
    sites_req = urllib.request.Request(
        "https://searchconsole.googleapis.com/webmasters/v3/sites",
        headers={"Authorization": f"Bearer {access_token}"}
    )
    with urllib.request.urlopen(sites_req, timeout=10) as sites_resp:
        sites_list = json.loads(sites_resp.read().decode("utf-8")).get("siteEntry", [])
        visible_urls = [s.get("siteUrl", "") for s in sites_list]
        print(f"[GSC-SYNC] Widoczne usługi w Google Search Console ({len(visible_urls)}): {', '.join(visible_urls) if visible_urls else '(brak — dodaj ' + client_email + ' w Search Console -> Użytkownicy i uprawnienia)'}")
except Exception as e:
    visible_urls = []
    print(f"[GSC-SYNC] Nie udało się pobrać listy usług GSC: {e}")

end_date = (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
start_date = (datetime.date.today() - datetime.timedelta(days=30)).isoformat()

for pair in sites_cfg.split(","):
    pair = pair.strip()
    if "=" not in pair:
        continue
    site_id, gsc_prop = [x.strip() for x in pair.split("=", 1)]
    base_domain = gsc_prop.replace("sc-domain:", "").replace("https://", "").replace("http://", "").strip("/")
    candidates = [
        gsc_prop,
        f"sc-domain:{base_domain}",
        f"https://{base_domain}/",
        f"https://www.{base_domain}/"
    ]
    seen = set()
    unique_candidates = [c for c in candidates if not (c in seen or seen.add(c))]

    synced = False
    for prop_candidate in unique_candidates:
        if visible_urls and prop_candidate not in visible_urls:
            continue
        encoded_prop = urllib.parse.quote(prop_candidate, safe="")
        api_url = f"https://searchconsole.googleapis.com/webmasters/v3/sites/{encoded_prop}/searchAnalytics/query"
        payload = json.dumps({
            "startDate": start_date,
            "endDate": end_date,
            "dimensions": ["query"],
            "rowLimit": 25
        }).encode("utf-8")
        try:
            gsc_req = urllib.request.Request(api_url, data=payload, headers={
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json"
            })
            with urllib.request.urlopen(gsc_req, timeout=15) as gsc_resp:
                gsc_data = json.loads(gsc_resp.read().decode("utf-8"))
            rows = []
            for r in gsc_data.get("rows", []):
                keys = r.get("keys", [])
                if not keys:
                    continue
                rows.append({
                    "query": keys[0],
                    "clicks": int(round(float(r.get("clicks", 0)))),
                    "impressions": int(round(float(r.get("impressions", 0)))),
                    "position": round(float(r.get("position", 0.0)), 1)
                })
            sync_payload = json.dumps({
                "type": "gsc_sync",
                "site_id": site_id,
                "rows": rows
            }).encode("utf-8")
            sync_req = urllib.request.Request(router_url, data=sync_payload, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(sync_req, timeout=5) as sync_resp:
                print(f"[GSC-SYNC] Zsynchronizowano {len(rows)} fraz dla {site_id} ({prop_candidate}) -> HTTP {sync_resp.status}")
                synced = True
                break
        except Exception:
            continue
    if not synced:
        sync_payload = json.dumps({
            "type": "gsc_sync",
            "site_id": site_id,
            "rows": []
        }).encode("utf-8")
        try:
            sync_req = urllib.request.Request(router_url, data=sync_payload, headers={"Content-Type": "application/json"})
            urllib.request.urlopen(sync_req, timeout=5).close()
        except Exception:
            pass
PYEOF
