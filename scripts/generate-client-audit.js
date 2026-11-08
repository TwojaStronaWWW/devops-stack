#!/usr/bin/env node
/**
 * scripts/generate-client-audit.js
 * ==============================================================================
 * TwojaStronaWWW — Generator Audytów Sprzedażowych i Bezpieczeństwa „Przed i Po”
 * (Sales & Security Audit Generator — B2B Client Website Audit & PDF Report)
 *
 * Architektura: Node.js 20+ ESM, zero zewnętrznych zależności npm.
 * Standardy referencyjne: ISO 27001, OWASP ASVS [REF-01]/[REF-05], RFC 9116 [REF-06],
 * WCAG 2.2 AA [REF-04], GEO / llms.txt [REF-07], Schema.org @graph [REF-08].
 *
 * Użycie:
 *   node scripts/generate-client-audit.js <url> [--out <dir>] [--client-name "Nazwa Klienta"]
 *   node scripts/generate-client-audit.js --self-test
 * ==============================================================================
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';

import { DEFAULT_OUT_DIR, escapeHtml, renderAuditHtml, writeAuditArtifacts } from './client-audit-renderer.js';
export { DEFAULT_OUT_DIR, escapeHtml, renderAuditHtml, writeAuditArtifacts };
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.resolve(__dirname, '..');

const USER_AGENT =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 TwojaStronaWWW-Audit/2.0';

/**
 * Normalizuje badany adres URL (domyślnie dodaje https:// jeśli brakuje schematu).
 * @param {string} rawUrl
 * @returns {URL}
 */
export function normalizeTargetUrl(rawUrl) {
  const trimmed = String(rawUrl || '').trim();
  if (!trimmed) {
    throw new Error('Nie podano adresu URL strony do audytu.');
  }
  const withProtocol = /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
  const parsed = new URL(withProtocol);
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error(`Nieobsługiwany protokół URL: ${parsed.protocol}`);
  }
  return parsed;
}

/**
 * Pobiera zasób pomocniczy (np. /.well-known/security.txt, /robots.txt, /sitemap.xml, /llms.txt).
 * @param {string} url
 * @param {number} timeoutMs
 */
async function probeEndpoint(url, timeoutMs = 8000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const t0 = performance.now();
  try {
    const res = await fetch(url, {
      method: 'GET',
      redirect: 'follow',
      signal: controller.signal,
      headers: {
        'User-Agent': USER_AGENT,
        Accept: 'text/plain, application/xml, text/xml, text/markdown, text/html;q=0.8, */*;q=0.5',
      },
    });
    const ttfbMs = Math.round(performance.now() - t0);
    const text = await res.text();
    const contentType = (res.headers.get('content-type') || '').toLowerCase();
    // Odrzucamy fałszywe trafienia, gdy serwer zwraca pełną stronę główną HTML (soft-404) dla plików txt/xml
    const looksLikeHtmlFallback =
      !url.endsWith('.html') &&
      (contentType.includes('text/html') || /^\s*<!doctype html/i.test(text) || /^\s*<html/i.test(text));

    return {
      ok: res.status >= 200 && res.status < 300 && !looksLikeHtmlFallback && text.trim().length > 0,
      status: res.status,
      ttfbMs,
      contentType,
      sizeBytes: Buffer.byteLength(text, 'utf8'),
      sample: text.slice(0, 600),
      looksLikeHtmlFallback,
    };
  } catch (err) {
    return {
      ok: false,
      status: 0,
      ttfbMs: Math.round(performance.now() - t0),
      contentType: '',
      sizeBytes: 0,
      sample: '',
      looksLikeHtmlFallback: false,
      error: err instanceof Error ? err.message : String(err),
    };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Sprawdza, czy wejście po czystym HTTP (port 80) przekierowuje na HTTPS (301/302/307/308).
 * @param {URL} targetUrl
 * @param {number} timeoutMs
 */
async function checkHttpToHttpsRedirect(targetUrl, timeoutMs = 6000) {
  const httpUrl = new URL(targetUrl.toString());
  httpUrl.protocol = 'http:';
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(httpUrl.toString(), {
      method: 'GET',
      redirect: 'manual',
      signal: controller.signal,
      headers: { 'User-Agent': USER_AGENT },
    });
    const location = res.headers.get('location') || '';
    const isRedirect = res.status >= 300 && res.status < 400;
    const redirectsToHttps = isRedirect && /^https:\/\//i.test(location);
    return {
      checked: true,
      status: res.status,
      location,
      redirectsToHttps,
    };
  } catch (err) {
    return {
      checked: false,
      status: 0,
      location: '',
      redirectsToHttps: false,
      error: err instanceof Error ? err.message : String(err),
    };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Pobiera stronę główną i zasoby pomocnicze przez sieć.
 * @param {URL} targetUrl
 */
export async function collectLiveWebsiteSnapshot(targetUrl) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);

  const tStart = performance.now();
  let mainRes;
  let ttfbMs = 0;
  let totalDownloadMs = 0;
  let html = '';

  try {
    mainRes = await fetch(targetUrl.toString(), {
      method: 'GET',
      redirect: 'follow',
      signal: controller.signal,
      headers: {
        'User-Agent': USER_AGENT,
        Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Encoding': 'br, gzip, deflate',
        'Accept-Language': 'pl-PL,pl;q=0.9,en-US;q=0.8,en;q=0.7',
      },
    });
    ttfbMs = Math.max(1, Math.round(performance.now() - tStart));
    html = await mainRes.text();
    totalDownloadMs = Math.max(ttfbMs, Math.round(performance.now() - tStart));
  } finally {
    clearTimeout(timer);
  }

  const finalUrl = new URL(mainRes.url || targetUrl.toString());
  const origin = finalUrl.origin;

  const headersObj = {};
  for (const [k, v] of mainRes.headers.entries()) {
    headersObj[k.toLowerCase()] = v;
  }

  const [httpRedirect, securityTxt, robotsTxt, sitemapXml, llmsTxt] = await Promise.all([
    checkHttpToHttpsRedirect(finalUrl),
    probeEndpoint(`${origin}/.well-known/security.txt`),
    probeEndpoint(`${origin}/robots.txt`),
    probeEndpoint(`${origin}/sitemap.xml`),
    probeEndpoint(`${origin}/llms.txt`),
  ]);

  return {
    requestedUrl: targetUrl.toString(),
    finalUrl: finalUrl.toString(),
    hostname: finalUrl.hostname,
    isHttps: finalUrl.protocol === 'https:',
    status: mainRes.status,
    ttfbMs,
    totalDownloadMs,
    html,
    headers: headersObj,
    httpRedirect,
    probes: {
      securityTxt,
      robotsTxt,
      sitemapXml,
      llmsTxt,
    },
  };
}

/**
 * Analizuje zebrany snapshot (HTML, nagłówki, czasy, sondy) i wylicza pełną punktację 0..100
 * w 4 kategoriach (25 + 30 + 20 + 25 = 100 pkt) wraz z uzasadnieniem biznesowym dla klienta.
 *
 * @param {object} snapshot
 * @param {{ clientName?: string, generatedAt?: string }} [options]
 */
export function evaluateAuditData(snapshot, options = {}) {
  const html = String(snapshot.html || '');
  const headers = {};
  for (const [k, v] of Object.entries(snapshot.headers || {})) {
    headers[k.toLowerCase()] = String(v ?? '');
  }

  const finalUrlStr = String(snapshot.finalUrl || snapshot.requestedUrl || 'https://example.com');
  const parsedUrl = new URL(finalUrlStr);
  const hostname = snapshot.hostname || parsedUrl.hostname;
  const clientName = (options.clientName || hostname).trim();
  const generatedAt = options.generatedAt || new Date().toISOString();

  const ttfbMs = Number(snapshot.ttfbMs ?? 0);
  const totalDownloadMs = Number(snapshot.totalDownloadMs ?? ttfbMs);
  const htmlBytes = Buffer.byteLength(html, 'utf8');
  const htmlKb = Number((htmlBytes / 1024).toFixed(1));

  const checks = [];
  const addCheck = (category, id, title, status, points, maxPoints, detected, businessImpact) => {
    checks.push({
      category,
      id,
      title,
      status, // 'pass' | 'warn' | 'fail'
      points,
      maxPoints,
      detected,
      businessImpact,
    });
  };

  // ============================================================================
  // 1. WYDAJNOŚĆ I SERWER (25 PKT)
  // ============================================================================
  const cat1Name = '1. Wydajność i Serwer';

  // 1.1 Czas odpowiedzi TTFB i pełnego pobrania dokumentu (8 pkt)
  let ttfbPts = 0;
  let ttfbStatus = 'fail';
  if (ttfbMs > 0 && ttfbMs <= 200 && totalDownloadMs <= 500) {
    ttfbPts = 8;
    ttfbStatus = 'pass';
  } else if (ttfbMs > 0 && ttfbMs <= 600 && totalDownloadMs <= 1200) {
    ttfbPts = 5;
    ttfbStatus = 'warn';
  } else if (ttfbMs > 0 && ttfbMs <= 1200) {
    ttfbPts = 2;
    ttfbStatus = 'warn';
  }
  addCheck(
    cat1Name,
    'perf_ttfb',
    'Czas odpowiedzi serwera (TTFB) i pobrania dokumentu HTML',
    ttfbStatus,
    ttfbPts,
    8,
    `TTFB: ${ttfbMs} ms | Pełne pobranie HTML: ${totalDownloadMs} ms`,
    ttfbStatus === 'pass'
      ? 'Serwer odpowiada błyskawicznie (< 200 ms), co wspiera wysoki współczynnik konwersji i ocenę Core Web Vitals.'
      : 'Wolny czas odpowiedzi serwera (powyżej 200–600 ms) zniechęca klientów mobilnych i obniża pozycję w Google (LCP/TTFB).'
  );

  // 1.2 Rozmiar dokumentu HTML w KB (5 pkt)
  let sizePts = 0;
  let sizeStatus = 'fail';
  if (htmlKb > 0 && htmlKb <= 65) {
    sizePts = 5;
    sizeStatus = 'pass';
  } else if (htmlKb > 65 && htmlKb <= 160) {
    sizePts = 3;
    sizeStatus = 'warn';
  }
  addCheck(
    cat1Name,
    'perf_html_size',
    'Rozmiar głównego dokumentu HTML',
    sizeStatus,
    sizePts,
    5,
    `${htmlKb} KB (${htmlBytes.toLocaleString('pl-PL')} B)`,
    sizeStatus === 'pass'
      ? 'Lekki dokument HTML pozwala przeglądarce natychmiast wyrenderować pierwszy ekran (First Contentful Paint).'
      : 'Przeładowany kod HTML (typowy dla kreatorów wizualnych) spowalnia parsowanie strony na smartfonach.'
  );

  // 1.3 Kompresja odpowiedzi Content-Encoding: br / gzip / brak (4 pkt)
  const contentEncoding = (headers['content-encoding'] || '').toLowerCase();
  let compPts = 0;
  let compStatus = 'fail';
  let compLabel = 'Brak kompresji (nieskompresowany transfer tekstowy)';
  if (contentEncoding.includes('br') || contentEncoding.includes('zstd')) {
    compPts = 4;
    compStatus = 'pass';
    compLabel = `Nowoczesna kompresja (${contentEncoding})`;
  } else if (contentEncoding.includes('gzip') || contentEncoding.includes('deflate')) {
    compPts = 3;
    compStatus = 'pass';
    compLabel = `Kompresja standardowa (${contentEncoding})`;
  }
  addCheck(
    cat1Name,
    'perf_compression',
    'Kompresja transferu HTTP (Brotli / Gzip)',
    compStatus,
    compPts,
    4,
    compLabel,
    compStatus === 'pass'
      ? 'Kompresja zmniejsza ilość przesyłanych danych o 70–85%, przyspieszając ładowanie na łączach LTE/5G.'
      : 'Brak kompresji oznacza kilkukrotnie większy transfer danych i wolniejsze wczytywanie strony u klienta.'
  );

  // 1.4 Protokół HTTPS i przekierowanie HTTP -> HTTPS (5 pkt)
  const isHttps = Boolean(snapshot.isHttps ?? parsedUrl.protocol === 'https:');
  const redirectsHttp = Boolean(snapshot.httpRedirect?.redirectsToHttps);
  let httpsPts = 0;
  let httpsStatus = 'fail';
  let httpsDetected = 'Brak szyfrowania HTTPS';
  if (isHttps && redirectsHttp) {
    httpsPts = 5;
    httpsStatus = 'pass';
    httpsDetected = `Aktywny HTTPS + wymuszone przekierowanie HTTP -> HTTPS (${snapshot.httpRedirect?.status || 301})`;
  } else if (isHttps) {
    httpsPts = 3;
    httpsStatus = 'warn';
    httpsDetected = 'Aktywny HTTPS, ale brak automatycznego przekierowania 301 z czystego HTTP';
  }
  addCheck(
    cat1Name,
    'perf_https_redirect',
    'Szyfrowanie TLS/HTTPS oraz przekierowanie HTTP -> HTTPS',
    httpsStatus,
    httpsPts,
    5,
    httpsDetected,
    httpsStatus === 'pass'
      ? 'Pełna ochrona ruchu TLS oraz jednoznaczne przekierowanie chronią przed ostrzeżeniem „Niezabezpieczona” w przeglądarce.'
      : 'Brak pełnego wymuszenia HTTPS naraża formularze kontaktowe i powoduje duplikację adresów http/https w indeksie Google.'
  );

  // 1.5 Nagłówek Cache-Control (3 pkt)
  const cacheControl = headers['cache-control'] || '';
  let cachePts = 0;
  let cacheStatus = 'fail';
  if (cacheControl.trim().length > 0) {
    cachePts = 3;
    cacheStatus = 'pass';
  }
  addCheck(
    cat1Name,
    'perf_cache_control',
    'Polityka pamięci podręcznej przeglądarki (Cache-Control)',
    cacheStatus,
    cachePts,
    3,
    cacheControl ? `Cache-Control: ${cacheControl}` : 'Brak nagłówka Cache-Control',
    cacheStatus === 'pass'
      ? 'Jawna polityka cache przyspiesza kolejne odsłony i odciąża serwer przy powracających klientach.'
      : 'Brak zdefiniowanej polityki Cache-Control zmusza przeglądarkę do ponownego pobierania zasobów przy każdej wizycie.'
  );

  // ============================================================================
  // 2. BEZPIECZEŃSTWO APLIKACJI I NAGŁÓWKI OWASP [REF-01] & [REF-05] (30 PKT)
  // ============================================================================
  const cat2Name = '2. Bezpieczeństwo Aplikacji i Nagłówki OWASP';

  // 2.1 Strict-Transport-Security (HSTS) (5 pkt)
  const hsts = headers['strict-transport-security'] || '';
  let hstsPts = 0;
  let hstsStatus = 'fail';
  if (hsts) {
    const maxAgeMatch = hsts.match(/max-age=(\d+)/i);
    const maxAge = maxAgeMatch ? Number(maxAgeMatch[1]) : 0;
    if (maxAge >= 15552000) {
      hstsPts = 5;
      hstsStatus = 'pass';
    } else {
      hstsPts = 3;
      hstsStatus = 'warn';
    }
  }
  addCheck(
    cat2Name,
    'sec_hsts',
    'Strict-Transport-Security (HSTS) [REF-01]',
    hstsStatus,
    hstsPts,
    5,
    hsts ? `Obecny (${hsts})` : 'BRAK nagłówka HSTS',
    hstsStatus === 'pass'
      ? 'Chroni klientów przed atakami podsłuchu SSL Stripping (Man-in-the-Middle) w publicznych sieciach Wi-Fi.'
      : 'Brak HSTS pozwala na przejęcie niezabezpieczonej sesji przy pierwszym połączeniu z domeną firmy.'
  );

  // 2.2 Content-Security-Policy (CSP) (6 pkt)
  const csp = headers['content-security-policy'] || '';
  let cspPts = 0;
  let cspStatus = 'fail';
  if (csp.trim().length > 0) {
    const hasUnsafeEverything = csp.includes("'unsafe-eval'") && csp.includes('*');
    cspPts = hasUnsafeEverything ? 3 : 6;
    cspStatus = hasUnsafeEverything ? 'warn' : 'pass';
  }
  addCheck(
    cat2Name,
    'sec_csp',
    'Content-Security-Policy (CSP — ochrona przed XSS i wstrzyknięciem skryptów)',
    cspStatus,
    cspPts,
    6,
    csp ? `Skonfigurowany (${csp.slice(0, 90)}${csp.length > 90 ? '…' : ''})` : 'BRAK polityki Content-Security-Policy',
    cspStatus === 'pass'
      ? 'Blokuje wykonanie obcych, złośliwych skryptów JavaScript (XSS) oraz nieautoryzowanych trackerów.'
      : 'Brak CSP oznacza, że w razie luki we wtyczce CMS haker może wstrzyknąć dowolny złośliwy skrypt lub fałszywy formularz płatności.'
  );

  // 2.3 X-Content-Type-Options: nosniff (4 pkt)
  const xcto = (headers['x-content-type-options'] || '').toLowerCase();
  const hasNosniff = xcto === 'nosniff';
  addCheck(
    cat2Name,
    'sec_nosniff',
    'X-Content-Type-Options: nosniff',
    hasNosniff ? 'pass' : 'fail',
    hasNosniff ? 4 : 0,
    4,
    hasNosniff ? 'X-Content-Type-Options: nosniff' : 'BRAK nagłówka nosniff',
    hasNosniff
      ? 'Blokuje zgadywanie typów MIME przez przeglądarkę, uniemożliwiając uruchomienie złośliwego pliku jako skryptu.'
      : 'Brak blokady MIME-sniffingu zwiększa ryzyko wykonania niebezpiecznych plików przesłanych na serwer.'
  );

  // 2.4 X-Frame-Options lub frame-ancestors (4 pkt)
  const xfo = headers['x-frame-options'] || '';
  const hasFrameAncestors = /frame-ancestors\s+([^;]+)/i.test(csp);
  const frameProtected = Boolean(xfo.trim() || hasFrameAncestors);
  addCheck(
    cat2Name,
    'sec_clickjacking',
    'Ochrona przed Clickjackingiem (X-Frame-Options / CSP frame-ancestors)',
    frameProtected ? 'pass' : 'fail',
    frameProtected ? 4 : 0,
    4,
    frameProtected
      ? `${xfo ? `X-Frame-Options: ${xfo}` : ''}${xfo && hasFrameAncestors ? ' + ' : ''}${hasFrameAncestors ? 'CSP frame-ancestors' : ''}`
      : 'BRAK ochrony przed osadzeniem w obcym <iframe>',
    frameProtected
      ? 'Uniemożliwia osadzenie strony firmy w niewidocznej ramce na stronie oszustów (Clickjacking).'
      : 'Każda obca witryna może osadzić Twoją stronę w ramce <iframe> i wyłudzać kliknięcia klientów.'
  );

  // 2.5 Referrer-Policy (3 pkt)
  const referrerPolicy = headers['referrer-policy'] || '';
  const hasReferrerPolicy = referrerPolicy.trim().length > 0;
  addCheck(
    cat2Name,
    'sec_referrer',
    'Polityka prywatności odsyłacza (Referrer-Policy)',
    hasReferrerPolicy ? 'pass' : 'fail',
    hasReferrerPolicy ? 3 : 0,
    3,
    hasReferrerPolicy ? `Referrer-Policy: ${referrerPolicy}` : 'BRAK nagłówka Referrer-Policy',
    hasReferrerPolicy
      ? 'Chroni prywatność użytkowników i zapobiega wyciekowi parametrów URL do zewnętrznych serwisów.'
      : 'Brak kontroli nad nagłówkiem Referer może prowadzić do wycieku wewnętrznych adresów URL i tokenów sesji.'
  );

  // 2.6 Permissions-Policy (3 pkt)
  const permissionsPolicy = headers['permissions-policy'] || '';
  const hasPermissionsPolicy = permissionsPolicy.trim().length > 0;
  addCheck(
    cat2Name,
    'sec_permissions',
    'Kontrola uprawnień sprzętowych przeglądarki (Permissions-Policy)',
    hasPermissionsPolicy ? 'pass' : 'fail',
    hasPermissionsPolicy ? 3 : 0,
    3,
    hasPermissionsPolicy ? `Permissions-Policy: ${permissionsPolicy.slice(0, 80)}` : 'BRAK nagłówka Permissions-Policy',
    hasPermissionsPolicy
      ? 'Jawnie blokuje nieautoryzowany dostęp skryptów trzecich do kamery, mikrofonu, geolokalizacji i płatności.'
      : 'Brak blokady uprawnień API przeglądarki dla zewnętrznych skryptów reklamowych i wtyczek.'
  );

  // 2.7 Cross-Origin-Opener-Policy (COOP) (2 pkt)
  const coop = headers['cross-origin-opener-policy'] || '';
  const hasCoop = coop.trim().length > 0;
  addCheck(
    cat2Name,
    'sec_coop',
    'Izolacja procesu okna przeglądarki (Cross-Origin-Opener-Policy — COOP) [REF-01]',
    hasCoop ? 'pass' : 'fail',
    hasCoop ? 2 : 0,
    2,
    hasCoop ? `Cross-Origin-Opener-Policy: ${coop}` : 'BRAK nagłówka COOP',
    hasCoop
      ? 'Izoluje kontekst okna przeglądarki przed atakami typu Reverse Tabnabbing i Spectre.'
      : 'Brak izolacji okna między domenami (standard Evergreen Web Standards [REF-01]).'
  );

  // 2.8 Wyciek wersji serwera/PHP w Server lub X-Powered-By (1 pkt)
  const serverHeader = headers['server'] || '';
  const poweredBy = headers['x-powered-by'] || '';
  const versionLeakRegex = /(php\/[\d.]+|apache\/[\d.]+|nginx\/[\d.]+|iis\/[\d.]+|openssl\/[\d.]+|litespeed\/[\d.]+)/i;
  const hasVersionLeak = Boolean(poweredBy.trim() !== '' || versionLeakRegex.test(serverHeader));
  addCheck(
    cat2Name,
    'sec_version_leak',
    'Ukrywanie sygnatur i wersji technologii (Server / X-Powered-By) [REF-05]',
    hasVersionLeak ? 'fail' : 'pass',
    hasVersionLeak ? 0 : 1,
    1,
    hasVersionLeak
      ? `Wyciek informacji: ${[serverHeader ? `Server: ${serverHeader}` : '', poweredBy ? `X-Powered-By: ${poweredBy}` : ''].filter(Boolean).join(', ')}`
      : `Brak wycieku wersji (${serverHeader ? `Server: ${serverHeader}` : 'ukryty'}, brak X-Powered-By)`,
    hasVersionLeak
      ? 'Jawne publikowanie wersji PHP/serwera ułatwia automatycznym botom dobranie gotowego exploita (CVE).'
      : 'Serwer nie zdradza wersji interpretera PHP ani dokładnej wersji oprogramowania serwerowego.'
  );

  // 2.9 Obecność pliku /.well-known/security.txt (RFC 9116 [REF-06]) (2 pkt)
  const secTxtProbe = snapshot.probes?.securityTxt || { ok: false, sample: '' };
  const hasSecTxt = Boolean(secTxtProbe.ok);
  const hasSecTxtExpires = hasSecTxt && /expires\s*:/i.test(secTxtProbe.sample || '');
  const secTxtPts = hasSecTxtExpires ? 2 : hasSecTxt ? 1 : 0;
  const secTxtStatus = hasSecTxtExpires ? 'pass' : hasSecTxt ? 'warn' : 'fail';
  addCheck(
    cat2Name,
    'sec_security_txt',
    'Polityka zgłaszania podatności /.well-known/security.txt (RFC 9116 [REF-06])',
    secTxtStatus,
    secTxtPts,
    2,
    hasSecTxtExpires
      ? 'Obecny plik /.well-known/security.txt z aktywną datą Expires'
      : hasSecTxt
        ? 'Obecny plik security.txt, ale brak wymaganego pola Expires:'
        : 'BRAK pliku /.well-known/security.txt',
    secTxtStatus === 'pass'
      ? 'Spełnia międzynarodowy standard RFC 9116 (ISO 27001 / NIS2) dla odpowiedzialnego kontaktu bezpieczeństwa.'
      : 'Brak standardowego punktu kontaktowego RFC 9116 wymaganego przez współczesne audyty cyberbezpieczeństwa.'
  );

  // ============================================================================
  // 3. ARCHITEKTURA KODU VS NARZUT CMS / WORDPRESS (20 PKT)
  // ============================================================================
  const cat3Name = '3. Architektura Kodu vs Narzut CMS / WordPress';

  // 3.1 Wykrywanie śladów ciężkich CMS/kreatorów (8 pkt)
  const cmsSignatures = [
    { key: 'wp-content', label: 'WordPress (wp-content)' },
    { key: 'wp-includes', label: 'WordPress Core (wp-includes)' },
    { key: 'elementor', label: 'Kreator Elementor' },
    { key: 'woocommerce', label: 'WooCommerce' },
    { key: 'jquery-migrate', label: 'Przestarzały jQuery Migrate' },
    { key: 'divi', label: 'Kreator Divi' },
    { key: 'wix.com', label: 'Kreator Wix' },
    { key: 'cdn.shopify.com', label: 'Shopify' },
  ];
  const lowerHtml = html.toLowerCase();
  const detectedCms = cmsSignatures
    .filter((sig) => lowerHtml.includes(sig.key))
    .map((sig) => sig.label);

  let cmsPts = 8;
  let cmsStatus = 'pass';
  if (detectedCms.length >= 2) {
    cmsPts = 0;
    cmsStatus = 'fail';
  } else if (detectedCms.length === 1) {
    cmsPts = 3;
    cmsStatus = 'warn';
  }
  addCheck(
    cat3Name,
    'arch_cms_footprint',
    'Ślady ciężkich systemów CMS i kreatorów wizualnych (WordPress / Elementor / Divi)',
    cmsStatus,
    cmsPts,
    8,
    detectedCms.length === 0
      ? 'Czysty kod (0 śladów WordPressa, Elementora ani starych bibliotek jQuery Migrate)'
      : `Wykryto narzut CMS (${detectedCms.length}): ${detectedCms.join(', ')}`,
    cmsStatus === 'pass'
      ? 'Czysta architektura bez bazy SQL i wtyczek WordPressa eliminuje 99% wektorów włamań i kosztów aktualizacji.'
      : 'Strona oparta na ciężkim CMS/wtyczkach wymaga stałych płatnych aktualizacji, bazy SQL i jest głównym celem automatycznych ataków botnetów.'
  );

  // 3.2 Liczba zewnętrznych blokujących skryptów <script src=...> oraz arkuszy <link rel="stylesheet"> (5 pkt)
  const scriptTags = [...html.matchAll(/<script\b[^>]*\bsrc\s*=\s*["'][^"']+["'][^>]*>/gi)].map((m) => m[0]);
  const blockingScripts = scriptTags.filter(
    (tag) => !/\b(defer|async)\b/i.test(tag) && !/\btype\s*=\s*["']module["']/i.test(tag)
  );
  const stylesheetTags = [
    ...html.matchAll(/<link\b[^>]*\brel\s*=\s*["']stylesheet["'][^>]*>/gi),
  ].map((m) => m[0]);

  const totalExternalAssets = scriptTags.length + stylesheetTags.length;
  let assetsPts = 0;
  let assetsStatus = 'fail';
  if (blockingScripts.length === 0 && totalExternalAssets <= 6) {
    assetsPts = 5;
    assetsStatus = 'pass';
  } else if (blockingScripts.length <= 2 && totalExternalAssets <= 14) {
    assetsPts = 3;
    assetsStatus = 'warn';
  }
  addCheck(
    cat3Name,
    'arch_external_assets',
    'Zewnętrzne skrypty JS i arkusze CSS (blokowanie renderowania)',
    assetsStatus,
    assetsPts,
    5,
    `Skrypty <script src>: ${scriptTags.length} (w tym blokujących bez defer/async: ${blockingScripts.length}) | Arkusze CSS: ${stylesheetTags.length}`,
    assetsStatus === 'pass'
      ? 'Minimalna liczba zasobów i nieblokujące ładowanie skryptów (defer/ES6) gwarantują płynne działanie strony.'
      : 'Duża liczba osobnych plików CSS/JS i blokujących skryptów zatrzymuje rysowanie ekranu na telefonach komórkowych.'
  );

  // 3.3 Liczba stylów inline style="..." (3 pkt)
  const inlineStyleMatches = html.match(/\bstyle\s*=\s*["'][^"']+["']/gi) || [];
  const inlineStyleCount = inlineStyleMatches.length;
  let inlinePts = 0;
  let inlineStatus = 'fail';
  if (inlineStyleCount === 0) {
    inlinePts = 3;
    inlineStatus = 'pass';
  } else if (inlineStyleCount <= 5) {
    inlinePts = 1;
    inlineStatus = 'warn';
  }
  addCheck(
    cat3Name,
    'arch_inline_styles',
    'Separacja warstw kodu (brak stylów inline style="...") [REF-03]',
    inlineStatus,
    inlinePts,
    3,
    inlineStyleCount === 0
      ? 'Zero stylów inline (100% czystej separacji HTML/CSS)'
      : `Wykryto ${inlineStyleCount} atrybutów style="..." w kodzie HTML`,
    inlineStatus === 'pass'
      ? 'Czysta separacja HTML i CSS ułatwia utrzymanie, pozwala na rygorystyczne CSP i zmniejsza rozmiar dokumentu.'
      : 'Style inline (typowe dla page-builderów) zaśmiecają kod HTML i osłabiają politykę bezpieczeństwa Content-Security-Policy.'
  );

  // 3.4 Obecność nowoczesnych formatów obrazów (.avif, .webp) vs stare .jpg/.png (4 pkt)
  const modernImgMatches = html.match(/\.(avif|webp)\b/gi) || [];
  const legacyImgMatches = html.match(/\.(jpe?g|png)\b/gi) || [];
  const hasSvg = /<svg\b|\.svg\b/i.test(html);
  let imgPts = 0;
  let imgStatus = 'fail';
  if (modernImgMatches.length > 0 || (legacyImgMatches.length === 0 && hasSvg)) {
    imgPts = legacyImgMatches.length <= modernImgMatches.length ? 4 : 3;
    imgStatus = 'pass';
  } else if (legacyImgMatches.length <= 2) {
    imgPts = 2;
    imgStatus = 'warn';
  }
  addCheck(
    cat3Name,
    'arch_image_formats',
    'Nowoczesne formaty graficzne Next-Gen (AVIF / WebP / SVG vs JPG / PNG)',
    imgStatus,
    imgPts,
    4,
    `Nowoczesne (.avif/.webp): ${modernImgMatches.length} | Tradycyjne (.jpg/.png): ${legacyImgMatches.length}${hasSvg ? ' | Wektory SVG: tak' : ''}`,
    imgStatus === 'pass'
      ? 'Formaty AVIF/WebP ważą o 50–80% mniej niż tradycyjne pliki JPG/PNG przy zachowaniu ostrości obrazu.'
      : 'Brak kompresji Next-Gen (AVIF/WebP) drastycznie wydłuża czas ładowania zdjęć na urządzeniach mobilnych.'
  );

  // ============================================================================
  // 4. SEO, DOSTĘPNOŚĆ WCAG 2.2 AA I GOTOWOŚĆ NA WYSZUKIWARKI AI — GEO (25 PKT)
  // ============================================================================
  const cat4Name = '4. SEO, Dostępność WCAG 2.2 AA i Wyszukiwarki AI (GEO)';

  // 4.1 Tytuł <title>, <meta name="description">, <link rel="canonical">, OpenGraph (og:title, og:image) (6 pkt)
  const titleMatch = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  const titleText = titleMatch ? titleMatch[1].replace(/\s+/g, ' ').trim() : '';
  const hasTitle = titleText.length >= 5;
  const hasMetaDesc =
    /<meta\b[^>]*\bname\s*=\s*["']description["'][^>]*\bcontent\s*=\s*["'][^"']{10,}["']/i.test(html) ||
    /<meta\b[^>]*\bcontent\s*=\s*["'][^"']{10,}["'][^>]*\bname\s*=\s*["']description["']/i.test(html);
  const hasCanonical = /<link\b[^>]*\brel\s*=\s*["']canonical["'][^>]*>/i.test(html);
  const hasOgTitle = /<meta\b[^>]*\bproperty\s*=\s*["']og:title["'][^>]*>/i.test(html);
  const hasOgImage = /<meta\b[^>]*\bproperty\s*=\s*["']og:image["'][^>]*>/i.test(html);

  const seoItemsCount = [hasTitle, hasMetaDesc, hasCanonical, hasOgTitle, hasOgImage].filter(Boolean).length;
  let seoMetaPts = 0;
  let seoMetaStatus = 'fail';
  if (seoItemsCount === 5) {
    seoMetaPts = 6;
    seoMetaStatus = 'pass';
  } else if (seoItemsCount >= 3) {
    seoMetaPts = 3;
    seoMetaStatus = 'warn';
  } else if (seoItemsCount >= 1) {
    seoMetaPts = 1;
    seoMetaStatus = 'fail';
  }
  addCheck(
    cat4Name,
    'seo_meta_og',
    'Fundamenty On-Page SEO (<title>, meta description, canonical, OpenGraph) [REF-08]',
    seoMetaStatus,
    seoMetaPts,
    6,
    `Title: ${hasTitle ? 'TAK' : 'BRAK'} | Description: ${hasMetaDesc ? 'TAK' : 'BRAK'} | Canonical: ${hasCanonical ? 'TAK' : 'BRAK'} | OG (title/image): ${hasOgTitle && hasOgImage ? 'TAK' : 'NIEPEŁNE'}`,
    seoMetaStatus === 'pass'
      ? 'Kompletne znaczniki meta i OpenGraph gwarantują wysoką klikalność (CTR) w wynikach Google i podglądach na Facebooku/LinkedIn.'
      : 'Braki w podstawowych tagach SEO i OpenGraph obniżają widoczność w wyszukiwarce oraz powodują nieczytelne linki w Social Media.'
  );

  // 4.2 Dane strukturalne Schema.org (application/ld+json i obecność @graph) (5 pkt)
  const ldJsonMatches = [
    ...html.matchAll(/<script\b[^>]*\btype\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi),
  ].map((m) => m[1]);
  const hasLdJson = ldJsonMatches.length > 0;
  const hasSchemaGraph = ldJsonMatches.some((block) => /"@graph"/i.test(block));
  let schemaPts = 0;
  let schemaStatus = 'fail';
  if (hasSchemaGraph) {
    schemaPts = 5;
    schemaStatus = 'pass';
  } else if (hasLdJson) {
    schemaPts = 3;
    schemaStatus = 'warn';
  }
  addCheck(
    cat4Name,
    'seo_schema_graph',
    'Dane strukturalne Schema.org JSON-LD (@graph) [REF-08]',
    schemaStatus,
    schemaPts,
    5,
    hasSchemaGraph
      ? `Obecny pełny graf wiedzy Schema.org JSON-LD (@graph, bloków: ${ldJsonMatches.length})`
      : hasLdJson
        ? 'Obecny podstawowy JSON-LD, ale brak spójnego grafu encji @graph'
        : 'BRAK danych strukturalnych Schema.org (application/ld+json)',
    schemaStatus === 'pass'
      ? 'Strukturalny graf encji (@graph) pozwala wyszukiwarkom Google i modelom AI jednoznacznie zrozumieć ofertę, ceny i lokalizację firmy.'
      : 'Brak zaawansowanego Schema.org utrudnia wyświetlanie rozszerzonych wyników (Rich Snippets / FAQ) w Google.'
  );

  // 4.3 Dostępność WCAG 2.2 AA: atrybut lang na <html>, .skip-link / skip, alt na <img> (5 pkt)
  const hasHtmlLang = /<html\b[^>]*\blang\s*=\s*["'][a-zA-Z-]{2,}["']/i.test(html);
  const hasSkipLink = /skip-link|skip-to-content|przejdź do treści|pomiń nawigację|#main-content/i.test(html);
  const imgTags = [...html.matchAll(/<img\b[^>]*>/gi)].map((m) => m[0]);
  const imgsMissingAlt = imgTags.filter((tag) => !/\balt\s*=\s*["'][^"']*["']/i.test(tag));
  const allImgsHaveAlt = imgTags.length === 0 || imgsMissingAlt.length === 0;

  let wcagPts = 0;
  if (hasHtmlLang) wcagPts += 2;
  if (hasSkipLink) wcagPts += 1;
  if (allImgsHaveAlt) wcagPts += 2;
  const wcagStatus = wcagPts === 5 ? 'pass' : wcagPts >= 3 ? 'warn' : 'fail';
  addCheck(
    cat4Name,
    'seo_wcag_a11y',
    'Dostępność cyfrowa WCAG 2.2 AA (html[lang], .skip-link, opisy alt obrazów) [REF-04]',
    wcagStatus,
    wcagPts,
    5,
    `html[lang]: ${hasHtmlLang ? 'TAK' : 'BRAK'} | Skip-link: ${hasSkipLink ? 'TAK' : 'BRAK'} | Obrazy bez alt: ${imgsMissingAlt.length}/${imgTags.length}`,
    wcagStatus === 'pass'
      ? 'Zgodność z WCAG 2.2 AA zapewnia dostępność dla czytników ekranu, obsługę klawiaturą i lepsze indeksowanie grafik.'
      : 'Błędy dostępności WCAG 2.2 AA utrudniają korzystanie ze strony osobom słabowidzącym i obniżają ocenę w audytach Google Lighthouse.'
  );

  // 4.4 Obecność /robots.txt oraz /sitemap.xml (4 pkt)
  const hasRobots = Boolean(snapshot.probes?.robotsTxt?.ok);
  const hasSitemap =
    Boolean(snapshot.probes?.sitemapXml?.ok) ||
    (hasRobots && /sitemap\s*:/i.test(snapshot.probes?.robotsTxt?.sample || ''));
  const crawlPts = (hasRobots ? 2 : 0) + (hasSitemap ? 2 : 0);
  const crawlStatus = crawlPts === 4 ? 'pass' : crawlPts === 2 ? 'warn' : 'fail';
  addCheck(
    cat4Name,
    'seo_robots_sitemap',
    'Pliki indeksowania dla robotów (/robots.txt oraz /sitemap.xml)',
    crawlStatus,
    crawlPts,
    4,
    `/robots.txt: ${hasRobots ? 'DOSTĘPNY' : 'BRAK'} | /sitemap.xml: ${hasSitemap ? 'DOSTĘPNY' : 'BRAK'}`,
    crawlStatus === 'pass'
      ? 'Roboty wyszukiwarek posiadają jasną mapę podstron i reguły indeksowania.'
      : 'Brak mapy witryny lub pliku robots.txt opóźnia indeksowanie nowych podstron w Google i Bing.'
  );

  // 4.5 Obecność /llms.txt ([REF-07] GEO — widoczność w ChatGPT Search, Perplexity, Google AI Overviews) (5 pkt)
  const hasLlmsTxtFile = Boolean(snapshot.probes?.llmsTxt?.ok);
  const hasLlmsHeadLink = /<link\b[^>]*href\s*=\s*["'][^"']*llms\.txt["']/i.test(html);
  const llmsPts = hasLlmsTxtFile ? 5 : hasLlmsHeadLink ? 2 : 0;
  const llmsStatus = hasLlmsTxtFile ? 'pass' : hasLlmsHeadLink ? 'warn' : 'fail';
  addCheck(
    cat4Name,
    'seo_geo_llms_txt',
    'Gotowość na wyszukiwarki AI — GEO (/llms.txt dla ChatGPT, Perplexity, Gemini) [REF-07]',
    llmsStatus,
    llmsPts,
    5,
    hasLlmsTxtFile
      ? `Aktywny standard /llms.txt (${snapshot.probes?.llmsTxt?.sizeBytes || 0} B)${hasLlmsHeadLink ? ' + podpięty w <head>' : ''}`
      : 'BRAK pliku /llms.txt (strona nieprzystosowana do cytowania przez asystentów AI)',
    llmsStatus === 'pass'
      ? 'Twoja firma posiada ustrukturyzowaną bazę faktów /llms.txt, dzięki czemu ChatGPT, Perplexity i Google AI Overviews precyzyjnie polecają Twoje usługi.'
      : 'W 2026/2027 coraz więcej klientów szuka usług przez ChatGPT i Google AI. Brak /llms.txt sprawia, że AI pomija Twoją stronę lub halucynuje na temat cennika.'
  );

  // Podsumowanie kategorii i wyniku całkowitego
  const categoryMap = new Map();
  for (const item of checks) {
    if (!categoryMap.has(item.category)) {
      categoryMap.set(item.category, { name: item.category, score: 0, maxScore: 0, checks: [] });
    }
    const cat = categoryMap.get(item.category);
    cat.score += item.points;
    cat.maxScore += item.maxPoints;
    cat.checks.push(item);
  }
  const categories = [...categoryMap.values()];
  const totalScore = categories.reduce((sum, c) => sum + c.score, 0);
  const maxTotalScore = categories.reduce((sum, c) => sum + c.maxScore, 0);

  const failCount = checks.filter((c) => c.status === 'fail').length;
  const warnCount = checks.filter((c) => c.status === 'warn').length;
  const passCount = checks.filter((c) => c.status === 'pass').length;
  const securityIssuesCount = checks.filter(
    (c) => c.category === cat2Name && c.status !== 'pass'
  ).length;

  let riskLevel = 'WYSOKIE RYZYKO TECHNICZNE I BIZNESOWE';
  let riskBadgeClass = 'risk-high';
  let grade = 'D';
  if (totalScore >= 90) {
    riskLevel = 'WZORCOWY STANDARD ENTERPRISE (NISKIE RYZYKO)';
    riskBadgeClass = 'risk-low';
    grade = 'A+';
  } else if (totalScore >= 75) {
    riskLevel = 'DOBRY POZIOM (WYMAGANE DOSZCZELNIENIE)';
    riskBadgeClass = 'risk-medium';
    grade = 'B';
  } else if (totalScore >= 50) {
    riskLevel = 'PODWYŻSZONE RYZYKO (LUKI OWASP / SPADEK KONWERSJI)';
    riskBadgeClass = 'risk-medium';
    grade = 'C';
  }

  return {
    meta: {
      generator: 'TwojaStronaWWW Sales & Security Audit Generator v2.0',
      clientName,
      hostname,
      requestedUrl: snapshot.requestedUrl || finalUrlStr,
      finalUrl: finalUrlStr,
      generatedAt,
      httpStatus: snapshot.status || 200,
    },
    summary: {
      totalScore,
      maxTotalScore,
      grade,
      riskLevel,
      riskBadgeClass,
      ttfbMs,
      totalDownloadMs,
      htmlKb,
      passCount,
      warnCount,
      failCount,
      securityIssuesCount,
      detectedCms,
      hasLlmsTxt: hasLlmsTxtFile,
    },
    categories,
    checks,
  };
}


/**
 * Wykonuje wbudowany test jednostkowy (--self-test) bez połączenia sieciowego:
 * 1) bada zamockowaną stronę z narzutem WordPress i brakami nagłówków OWASP (niski wynik),
 * 2) bada zamockowaną wzorcową stronę TwojaStronaWWW Vanilla DevSecOps (wynik 100/100),
 * 3) weryfikuje generowanie raportu HTML A4 i wypisuje SELF_TEST_OK.
 */
export function runSelfTest() {
  // Próbka 1: Przestarzała strona WordPress bez nagłówków bezpieczeństwa
  const legacyWpSnapshot = {
    requestedUrl: 'http://stara-strona-klienta.pl',
    finalUrl: 'http://stara-strona-klienta.pl/',
    hostname: 'stara-strona-klienta.pl',
    isHttps: false,
    status: 200,
    ttfbMs: 1450,
    totalDownloadMs: 2800,
    headers: {
      server: 'Apache/2.4.41 (Ubuntu)',
      'x-powered-by': 'PHP/7.4.33',
    },
    httpRedirect: { checked: true, status: 200, location: '', redirectsToHttps: false },
    probes: {
      securityTxt: { ok: false, status: 404, sample: '' },
      robotsTxt: { ok: false, status: 404, sample: '' },
      sitemapXml: { ok: false, status: 404, sample: '' },
      llmsTxt: { ok: false, status: 404, sample: '' },
    },
    html: `<!DOCTYPE html>
      <html>
      <head>
        <link rel="stylesheet" href="/wp-content/themes/divi/style.css">
        <link rel="stylesheet" href="/wp-content/plugins/elementor/assets/css/frontend.css">
        <script src="/wp-includes/js/jquery/jquery-migrate.min.js"></script>
      </head>
      <body style="margin:0;padding:0;background:#fff;color:#000;font-size:14px;line-height:1.2">
        <img src="/wp-content/uploads/baner.jpg">
        <img src="/wp-content/uploads/oferta.png">
      </body>
      </html>`,
  };

  const legacyAudit = evaluateAuditData(legacyWpSnapshot, {
    clientName: 'Przykładowa Firma WP Sp. z o.o.',
    generatedAt: '2026-11-08T12:00:00.000Z',
  });

  if (legacyAudit.summary.maxTotalScore !== 100) {
    throw new Error(`Suma punktów maksymalnych musi wynosić 100, otrzymano: ${legacyAudit.summary.maxTotalScore}`);
  }
  if (legacyAudit.summary.totalScore >= 25) {
    throw new Error(`Niezabezpieczona strona WP powinna otrzymać niski wynik (<25), otrzymano: ${legacyAudit.summary.totalScore}`);
  }
  if (legacyAudit.summary.detectedCms.length < 3) {
    throw new Error('Nie wykryto oczekiwanych śladów WordPress / Elementor / jQuery Migrate');
  }

  // Próbka 2: Wzorcowa strona TwojaStronaWWW (Vanilla DevSecOps 100/100)
  const perfectSnapshot = {
    requestedUrl: 'https://twojastronawww.pl',
    finalUrl: 'https://twojastronawww.pl/',
    hostname: 'twojastronawww.pl',
    isHttps: true,
    status: 200,
    ttfbMs: 38,
    totalDownloadMs: 95,
    headers: {
      'content-encoding': 'br',
      'cache-control': 'public, max-age=3600, stale-while-revalidate=86400',
      'strict-transport-security': 'max-age=31536000; includeSubDomains; preload',
      'content-security-policy': "default-src 'self'; frame-ancestors 'none'",
      'x-content-type-options': 'nosniff',
      'x-frame-options': 'DENY',
      'referrer-policy': 'strict-origin-when-cross-origin',
      'permissions-policy': 'camera=(), microphone=(), geolocation=()',
      'cross-origin-opener-policy': 'same-origin-allow-popups',
      server: 'cloudflare',
    },
    httpRedirect: {
      checked: true,
      status: 301,
      location: 'https://twojastronawww.pl/',
      redirectsToHttps: true,
    },
    probes: {
      securityTxt: {
        ok: true,
        status: 200,
        sizeBytes: 180,
        sample: 'Contact: mailto:kontakt@twojastronawww.pl\nExpires: 2027-12-31T23:59:00.000Z\n',
      },
      robotsTxt: {
        ok: true,
        status: 200,
        sizeBytes: 120,
        sample: 'User-agent: *\nAllow: /\nAllow: /llms.txt\nSitemap: https://twojastronawww.pl/sitemap.xml\n',
      },
      sitemapXml: {
        ok: true,
        status: 200,
        sizeBytes: 450,
        sample: '<?xml version="1.0" encoding="UTF-8"?><urlset></urlset>',
      },
      llmsTxt: {
        ok: true,
        status: 200,
        sizeBytes: 1240,
        sample: '# TwojaStronaWWW — Inżynieria Stron WWW & AI\n',
      },
    },
    html: `<!DOCTYPE html>
      <html lang="pl">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>TwojaStronaWWW — Szybkie Strony WWW bez WordPressa i Asystenci AI</title>
        <meta name="description" content="Budujemy ultraszybkie i bezpieczne strony internetowe w czystym kodzie oraz wdrażamy czatboty AI 24/7.">
        <link rel="canonical" href="https://twojastronawww.pl/">
        <link rel="alternate" type="text/markdown" href="/llms.txt">
        <meta property="og:title" content="TwojaStronaWWW — Szybkie Strony WWW">
        <meta property="og:image" content="https://twojastronawww.pl/assets/img/og-cover.avif">
        <link rel="stylesheet" href="/assets/css/main.css">
        <script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"WebSite","name":"TwojaStronaWWW"}]}</script>
        <script src="/assets/js/app.js" defer></script>
      </head>
      <body>
        <a class="skip-link" href="#main-content">Przejdź do treści</a>
        <main id="main-content">
          <img src="/assets/img/hero.avif" alt="Architektura TwojaStronaWWW">
        </main>
      </body>
      </html>`,
  };

  const perfectAudit = evaluateAuditData(perfectSnapshot, {
    clientName: 'TwojaStronaWWW Wzorzec',
    generatedAt: '2026-11-08T12:00:00.000Z',
  });

  if (perfectAudit.summary.totalScore !== 100) {
    throw new Error(`Wzorcowa strona powinna otrzymać 100/100 pkt, otrzymano: ${perfectAudit.summary.totalScore}`);
  }

  const htmlReport = renderAuditHtml(legacyAudit);
  const requiredSnippets = [
    'TwojaStronaWWW — Ekspercki Audyt Wydajności, Bezpieczeństwa (ISO/OWASP) i Widoczności AI (GEO)',
    'PRZED I PO',
    'Standard TwojaStronaWWW (Czysty Kod Vanilla DevSecOps)',
    '100 / 100',
    '@media print',
    'Rekomendowany Plan Naprawczy / Migracja',
  ];
  for (const snippet of requiredSnippets) {
    if (!htmlReport.includes(snippet)) {
      throw new Error(`Brak wymaganego fragmentu w wygenerowanym raporcie HTML: ${snippet}`);
    }
  }

  // Test zapisu artefaktów (.json + .html) w katalogu tymczasowym
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tsw-audit-selftest-'));
  try {
    const { jsonPath, htmlPath } = writeAuditArtifacts(legacyAudit, tmpDir);
    if (!fs.existsSync(jsonPath) || !fs.existsSync(htmlPath)) {
      throw new Error('Nie utworzono plików raportu .json / .html w writeAuditArtifacts');
    }
    const parsedJson = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
    if (parsedJson.meta.hostname !== 'stara-strona-klienta.pl') {
      throw new Error('Błędna zawartość zapisanego pliku JSON');
    }
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }

  console.log('SELF_TEST_OK');
}

/**
 * Parsuje argumenty linii poleceń CLI.
 * @param {string[]} argv
 */
export function parseCliArgs(argv) {
  const args = {
    url: '',
    outDir: DEFAULT_OUT_DIR,
    clientName: '',
    selfTest: false,
    help: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (token === '--self-test') {
      args.selfTest = true;
    } else if (token === '--help' || token === '-h') {
      args.help = true;
    } else if (token === '--out' && i + 1 < argv.length) {
      args.outDir = path.resolve(argv[++i]);
    } else if (token.startsWith('--out=')) {
      args.outDir = path.resolve(token.slice('--out='.length));
    } else if (token === '--client-name' && i + 1 < argv.length) {
      args.clientName = argv[++i];
    } else if (token.startsWith('--client-name=')) {
      args.clientName = token.slice('--client-name='.length);
    } else if (!token.startsWith('-') && !args.url) {
      args.url = token;
    }
  }

  return args;
}

function printUsage() {
  console.log(`
Użycie:
  node scripts/generate-client-audit.js <url> [--out <dir>] [--client-name "Nazwa Klienta"]
  node scripts/generate-client-audit.js --self-test

Opcje:
  <url>                     Adres badanej strony klienta (np. https://przykladowa-firma.pl)
  --out <dir>               Katalog wyjściowy dla plików .html i .json (domyślnie: dist/client-audits)
  --client-name "Nazwa"     Czytelna nazwa firmy klienta na nagłówku raportu A4
  --self-test               Uruchamia weryfikację jednostkową offline i wypisuje SELF_TEST_OK
`);
}

async function main() {
  const cli = parseCliArgs(process.argv.slice(2));
  if (cli.help) {
    printUsage();
    process.exit(0);
  }
  if (cli.selfTest) {
    runSelfTest();
    process.exit(0);
  }
  if (!cli.url) {
    printUsage();
    process.exit(1);
  }

  const targetUrl = normalizeTargetUrl(cli.url);
  console.log(`==> [TwojaStronaWWW Audit] Badanie strony: ${targetUrl.toString()} ...`);
  const snapshot = await collectLiveWebsiteSnapshot(targetUrl);
  const audit = evaluateAuditData(snapshot, { clientName: cli.clientName });
  const { jsonPath, htmlPath } = writeAuditArtifacts(audit, cli.outDir);

  console.log(
    `==> Wynik całkowity: ${audit.summary.totalScore} / ${audit.summary.maxTotalScore} pkt (Ocena ${audit.summary.grade} — ${audit.summary.riskLevel})`
  );
  for (const cat of audit.categories) {
    console.log(`    - ${cat.name}: ${cat.score} / ${cat.maxScore} pkt`);
  }
  console.log(`HTML_REPORT=${htmlPath}`);
  console.log(`JSON_REPORT=${jsonPath}`);
}

const isDirectRun =
  process.argv[1] && path.resolve(process.argv[1]) === path.resolve(__filename);

if (isDirectRun) {
  main().catch((err) => {
    console.error(`BŁĄD AUDYTU: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  });
}
