#!/usr/bin/env python3
"""
discover-endpoints.py
Skaner Inżynierii Wstecznej Ukrytych Endpointów API, SPA State, JSON-LD, RSS oraz WP-JSON
dla ekosystemu TwojaStronaWWW (Radar Zmian Zewnętrznych VPS + DancePuls / Kato Salsa Hub).

Użycie:
  python3 scripts/discover-endpoints.py <URL> [--probe-cms]
  python3 scripts/discover-endpoints.py --self-test

Wykrywane warstwy (Zero-Dependency, 100% Python Standard Library):
  1. NEXT_DATA / SPA State (<script id="__NEXT_DATA__" type="application/json">) z automatycznym
     odkrywaniem tablic danych (json_path + json_fields).
  2. JSON-LD Schema.org (<script type="application/ld+json"> -> Event, DanceEvent, NewsArticle, Product).
  3. Kanały RSS 2.0 / Atom XML (<link rel="alternate" type="application/rss+xml"> + sondowanie ?format=feed&type=rss).
  4. Ukryte endpointy XHR / Fetch / REST / GraphQL / Supabase / SharePoint zaszyte w kodzie HTML/JS.
  5. Sondowanie REST API CMS (--probe-cms: WordPress /wp-json/wp/v2/posts, The Events Calendar /wp-json/tribe/events/v1/events).
"""

import json
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

MAX_BYTES = 2 * 1024 * 1024
DEFAULT_TIMEOUT = 10.0
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)


def fetch_raw(url, timeout=DEFAULT_TIMEOUT):
    ctx = ssl.create_default_context()
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,application/json;q=0.8,*/*;q=0.7",
            "Accept-Language": "pl-PL,pl;q=0.9,en-US;q=0.8,en;q=0.7",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        status = getattr(resp, "status", 200)
        ct = resp.headers.get("Content-Type", "")
        raw = resp.read(MAX_BYTES).decode("utf-8", errors="replace")
        return status, ct, raw


def _find_candidate_arrays_in_json(node, prefix="", results=None, depth=0):
    """Rekurencyjnie szuka w drzewie JSON tablic słowników (list[dict]) wyglądających na kolekcje wpisów/wydarzeń."""
    if results is None:
        results = []
    if depth > 12:
        return results

    if isinstance(node, list):
        dict_items = [x for x in node if isinstance(x, dict)]
        if len(dict_items) >= 1:
            sample_keys = list(dict_items[0].keys())
            interesting_keys = [
                k for k in sample_keys
                if any(w in k.lower() for w in ("title", "name", "date", "url", "path", "route", "slug", "id", "start", "desc"))
            ]
            if interesting_keys or len(dict_items) >= 2:
                results.append({
                    "json_path": prefix.lstrip("."),
                    "items_count": len(dict_items),
                    "sample_keys": sample_keys[:12],
                    "recommended_fields": (interesting_keys or sample_keys)[:4],
                })
        for idx, item in enumerate(node[:3]):
            _find_candidate_arrays_in_json(item, f"{prefix}.{idx}", results, depth + 1)
    elif isinstance(node, dict):
        for k, v in node.items():
            _find_candidate_arrays_in_json(v, f"{prefix}.{k}", results, depth + 1)

    return results


def analyze_html_payload(raw_html, base_url="https://example.com"):
    """Analizuje pobrany dokument HTML/JSON/XML i zwraca ustrukturyzowany raport wykrytych endpointów."""
    findings = {
        "url": base_url,
        "next_data": [],
        "json_ld": [],
        "rss_feeds": [],
        "xhr_api_patterns": [],
        "recommended_target_config": None,
    }

    if not raw_html:
        return findings

    # 1. Detekcja __NEXT_DATA__ (Next.js)
    m_next = re.search(
        r'<script[^>]+id=["\']__NEXT_DATA__["\'][^>]*>(.*?)</script>',
        raw_html,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if m_next:
        try:
            next_obj = json.loads(m_next.group(1))
            arrays = _find_candidate_arrays_in_json(next_obj)
            # Sortuj po liczbie elementów malejąco
            arrays.sort(key=lambda x: x["items_count"], reverse=True)
            findings["next_data"] = arrays[:5]
        except Exception:
            pass

    # 2. Detekcja JSON-LD (<script type="application/ld+json">)
    ld_blocks = re.findall(
        r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>',
        raw_html,
        flags=re.IGNORECASE | re.DOTALL,
    )
    for block in ld_blocks:
        try:
            parsed = json.loads(block.strip())
            nodes = parsed if isinstance(parsed, list) else (parsed.get("@graph") if isinstance(parsed, dict) and "@graph" in parsed else [parsed])
            for n in (nodes if isinstance(nodes, list) else [nodes]):
                if isinstance(n, dict) and "@type" in n:
                    findings["json_ld"].append({
                        "type": n.get("@type"),
                        "keys": list(n.keys())[:10],
                    })
        except Exception:
            pass

    # 3. Detekcja kanałów RSS / Atom w <link rel="alternate">
    rss_links = re.findall(
        r'<link[^>]+type=["\']application/(?:rss|atom)\+xml["\'][^>]*>',
        raw_html,
        flags=re.IGNORECASE,
    )
    for rtag in rss_links:
        m_href = re.search(r'href=["\']([^"\']+)["\']', rtag, flags=re.IGNORECASE)
        if m_href:
            full_rss = urllib.parse.urljoin(base_url, m_href.group(1).strip())
            if full_rss not in findings["rss_feeds"]:
                findings["rss_feeds"].append(full_rss)

    # 4. Detekcja ukrytych wywołań XHR / REST / GraphQL / WP-JSON / SharePoint w kodzie
    api_matches = set()
    for pat in (
        r'["\']((?:https?://[^"\']+|/[^"\']*?)(?:wp-json|api/v\d+|graphql|_api/web/lists|page-data/[^"\']+\.json|\.json\b|\?format=feed)[^"\']*)["\']',
        r'operation:\s*["\']GetListItems["\'][^}]*listName:\s*["\']([^"\']+)["\']',
    ):
        for m in re.finditer(pat, raw_html, flags=re.IGNORECASE):
            val = m.group(1).strip()
            if not any(ignore in val.lower() for ignore in ("manifest.json", "package.json", "tsconfig.json", "schema.org")):
                api_matches.add(urllib.parse.urljoin(base_url, val) if val.startswith("/") else val)

    findings["xhr_api_patterns"] = sorted(api_matches)[:15]

    # 5. Rekomendacja najlepszego trybu dla config/change-radar/targets.json
    if findings["next_data"]:
        best = findings["next_data"][0]
        findings["recommended_target_config"] = {
            "mode": "next_data",
            "url": base_url,
            "json_path": best["json_path"],
            "json_fields": best["recommended_fields"],
        }
    elif findings["rss_feeds"]:
        findings["recommended_target_config"] = {
            "mode": "rss",
            "url": findings["rss_feeds"][0],
        }
    elif findings["json_ld"]:
        findings["recommended_target_config"] = {
            "mode": "json_ld",
            "url": base_url,
            "json_fields": ["startDate", "name", "url"],
        }
    else:
        findings["recommended_target_config"] = {
            "mode": "html",
            "url": base_url,
            "extract_regex": "(?is)<main\\b[^>]*>(.*?)</main>|<article\\b[^>]*>(.*?)</article>",
        }

    return findings


def probe_cms_endpoints(base_url):
    """Sonduje popularne ukryte endpointy CMS (WordPress REST API, The Events Calendar, Joomla RSS)."""
    parsed = urllib.parse.urlparse(base_url)
    origin = f"{parsed.scheme}://{parsed.netloc}"
    candidates = [
        ("wp_posts_json", f"{origin}/wp-json/wp/v2/posts?per_page=3"),
        ("wp_tribe_events_json", f"{origin}/wp-json/tribe/events/v1/events?per_page=3"),
        ("rss_feed_query", f"{base_url.rstrip('/')}{'&' if '?' in base_url else '?'}format=feed&type=rss"),
        ("rss_feed_path", f"{origin}/feed/"),
    ]
    alive = []
    for label, u in candidates:
        try:
            st, ct, body = fetch_raw(u, timeout=5.0)
            if st == 200 and body and (
                "json" in ct.lower()
                or "xml" in ct.lower()
                or "rss" in ct.lower()
                or body.lstrip().startswith(("{", "[", "<?xml", "<rss", "<feed"))
            ):
                alive.append({"type": label, "url": u, "content_type": ct, "bytes": len(body)})
        except Exception:
            pass
    return alive


def run_self_test():
    sample_doc = """
    <!DOCTYPE html>
    <html>
    <head>
        <link rel="alternate" type="application/rss+xml" title="Aktualności RSS" href="/aktualnosci?format=feed&type=rss" />
        <script type="application/ld+json">
        {"@context":"https://schema.org","@type":"DanceEvent","name":"Salsa Cubana Night","startDate":"2026-11-14"}
        </script>
    </head>
    <body>
        <script id="__NEXT_DATA__" type="application/json">
        {"props":{"pageProps":{"announcements":[
            {"createDate":"2026-11-08","name":"Komunikat 1","path":"/k/1"},
            {"createDate":"2026-11-07","name":"Komunikat 2","path":"/k/2"}
        ]}}}
        </script>
        <script>
        fetch("/api/v1/events?city=katowice");
        </script>
    </body>
    </html>
    """
    res = analyze_html_payload(sample_doc, "https://example.pl/komunikaty")
    assert len(res["next_data"]) >= 1, "Nie wykryto drzewa __NEXT_DATA__"
    assert res["next_data"][0]["json_path"] == "props.pageProps.announcements", "Błędna ścieżka json_path"
    assert len(res["json_ld"]) == 1 and res["json_ld"][0]["type"] == "DanceEvent", "Nie wykryto JSON-LD DanceEvent"
    assert "https://example.pl/aktualnosci?format=feed&type=rss" in res["rss_feeds"], "Nie wykryto kanału RSS"
    assert "https://example.pl/api/v1/events?city=katowice" in res["xhr_api_patterns"], "Nie wykryto endpointu XHR /api/v1/events"
    assert res["recommended_target_config"]["mode"] == "next_data", "Błędna rekomendacja trybu"
    print("SELF_TEST_OK")
    return 0


def main():
    if "--self-test" in sys.argv or len(sys.argv) < 2:
        if "--self-test" in sys.argv:
            sys.exit(run_self_test())
        print("Użycie: python3 scripts/discover-endpoints.py <URL> [--probe-cms] | --self-test")
        sys.exit(1)

    target_url = sys.argv[1].strip()
    do_probe = "--probe-cms" in sys.argv

    status, ct, raw_body = fetch_raw(target_url)
    report = analyze_html_payload(raw_body, base_url=target_url)
    report["http_status"] = status
    report["content_type"] = ct
    if do_probe:
        report["probed_cms_endpoints"] = probe_cms_endpoints(target_url)

    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
