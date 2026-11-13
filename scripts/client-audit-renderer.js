/**
 * scripts/client-audit-renderer.js
 * ==============================================================================
 * Warstwa prezentacji HTML/CSS A4 (@media print) i zapisu artefaktow
 * dla Generatora Audytow Sprzedazowych B2B TwojaStronaWWW.
 * Wyodrebniona z generate-client-audit.js zgodnie z zasada SRP.
 * ==============================================================================
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.resolve(__dirname, '..');
export const DEFAULT_OUT_DIR = path.join(ROOT_DIR, 'dist', 'client-audits');

/**
 * Escapowanie znak?w HTML do bezpiecznego renderowania w raporcie.
 * @param {unknown} value
 * @returns {string}
 */
export function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/**
 * Generuje kompletny, gotowy do druku / eksportu PDF raport HTML w formacie A4 (@media print).
 * @param {ReturnType<typeof evaluateAuditData>} audit
 * @returns {string}
 */
export function renderAuditHtml(audit) {
  const { meta, summary, categories, checks } = audit;
  const dateFormatted = new Date(meta.generatedAt).toLocaleString('pl-PL', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });

  const scoreToneClass =
    summary.totalScore >= 85 ? 'score-tone-high' : summary.totalScore >= 55 ? 'score-tone-med' : 'score-tone-low';

  const statusBadge = (status, pts, maxPts) => {
    if (status === 'pass') {
      return `<span class="status-pill status-pass">✅ ZALICZONO (${pts}/${maxPts} pkt)</span>`;
    }
    if (status === 'warn') {
      return `<span class="status-pill status-warn">⚠️ OSTRZEŻENIE (${pts}/${maxPts} pkt)</span>`;
    }
    return `<span class="status-pill status-fail">❌ BŁĄD / BRAK (${pts}/${maxPts} pkt)</span>`;
  };

  const categoryDynamicCss = categories
    .map((cat, idx) => {
      const pct = Math.round((cat.score / Math.max(1, cat.maxScore)) * 100);
      return `.progress-fill-${idx} { width: ${pct}%; }`;
    })
    .join('\n      ');

  const categoryCardsHtml = categories
    .map((cat, idx) => {
      const pct = Math.round((cat.score / Math.max(1, cat.maxScore)) * 100);
      const toneClass = pct >= 80 ? 'cat-tone-high' : pct >= 50 ? 'cat-tone-med' : 'cat-tone-low';
      return `
        <div class="cat-card">
          <div class="cat-card-header">
            <span class="cat-title">${escapeHtml(cat.name)}</span>
            <strong class="cat-score ${toneClass}">${cat.score} / ${cat.maxScore} pkt</strong>
          </div>
          <div class="progress-track">
            <div class="progress-fill progress-fill-${idx} ${toneClass}-bg"></div>
          </div>
        </div>`;
    })
    .join('\n');

  const checklistRowsHtml = checks
    .map(
      (c) => `
      <tr>
        <td class="col-check">
          <div class="check-title">${escapeHtml(c.title)}</div>
          <div class="check-cat">${escapeHtml(c.category)}</div>
        </td>
        <td class="col-status">${statusBadge(c.status, c.points, c.maxPoints)}</td>
        <td class="col-detected"><code>${escapeHtml(c.detected)}</code></td>
        <td class="col-impact">${escapeHtml(c.businessImpact)}</td>
      </tr>`
    )
    .join('\n');

  const cmsSummaryText =
    summary.detectedCms.length > 0
      ? `Wykryto: ${summary.detectedCms.join(', ')}`
      : 'Brak ciężkiego CMS (czysta architektura)';
  const securityChecksTotal =
    categories.find((cat) => cat.name.startsWith('2.'))?.checks.length || 11;

  return `<!DOCTYPE html>
<html lang="pl">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Audyt Wydajności, Bezpieczeństwa i AI (GEO) — ${escapeHtml(meta.clientName)} | TwojaStronaWWW</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #0f172a;
      --muted: #475569;
      --border: #cbd5e1;
      --surface: #ffffff;
      --surface-alt: #f8fafc;
      --brand: #0284c7;
      --brand-dark: #0369a1;
      --pass-bg: #dcfce7;
      --pass-fg: #166534;
      --warn-bg: #fef3c7;
      --warn-fg: #92400e;
      --fail-bg: #fee2e2;
      --fail-fg: #991b1b;
    }
    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }
    body {
      font-family: 'Segoe UI', system-ui, -apple-system, BlinkMacSystemFont, Roboto, Helvetica, Arial, sans-serif;
      color: var(--ink);
      background: #e2e8f0;
      line-height: 1.48;
      font-size: 13.5px;
      padding: 24px 12px;
    }
    .page-sheet {
      max-width: 210mm;
      margin: 0 auto;
      background: var(--surface);
      padding: 16mm 15mm;
      box-shadow: 0 12px 32px rgba(15, 23, 42, 0.12);
      border-radius: 8px;
    }
    .report-header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 16px;
      border-bottom: 3px solid var(--brand);
      padding-bottom: 14px;
      margin-bottom: 18px;
    }
    .brand-kicker {
      font-size: 11px;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: var(--brand-dark);
      margin-bottom: 4px;
    }
    .report-title {
      font-size: 20px;
      font-weight: 800;
      color: var(--ink);
      line-height: 1.25;
    }
    .report-subtitle {
      font-size: 12.5px;
      color: var(--muted);
      margin-top: 4px;
    }
    .meta-box {
      text-align: right;
      font-size: 12px;
      color: var(--muted);
      min-width: 210px;
      background: var(--surface-alt);
      padding: 8px 12px;
      border-radius: 6px;
      border: 1px solid var(--border);
    }
    .meta-box strong {
      color: var(--ink);
    }
    .section-heading {
      font-size: 15px;
      font-weight: 800;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--ink);
      margin: 20px 0 10px;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    /* KARTA PORÓWNAWCZA PRZED I PO */
    .before-after-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 14px;
      margin-bottom: 18px;
    }
    .comparison-card {
      border-radius: 8px;
      padding: 14px 16px;
      border: 2px solid var(--border);
    }
    .card-before {
      background: #fffafa;
      border-color: #fca5a5;
    }
    .card-after {
      background: #f0fdf4;
      border-color: #86efac;
    }
    .card-badge {
      display: inline-block;
      font-size: 10.5px;
      font-weight: 800;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      padding: 3px 8px;
      border-radius: 4px;
      margin-bottom: 6px;
    }
    .card-before .card-badge {
      background: var(--fail-bg);
      color: var(--fail-fg);
    }
    .card-after .card-badge {
      background: var(--pass-bg);
      color: var(--pass-fg);
    }
    .comparison-title {
      font-size: 15px;
      font-weight: 800;
      margin-bottom: 6px;
    }
    .score-display {
      font-size: 28px;
      font-weight: 900;
      line-height: 1.1;
      margin: 6px 0 8px;
    }
    .risk-pill {
      display: inline-block;
      font-size: 11px;
      font-weight: 700;
      padding: 2px 8px;
      border-radius: 4px;
      margin-bottom: 10px;
    }
    .risk-high { background: var(--fail-bg); color: var(--fail-fg); }
    .risk-medium { background: var(--warn-bg); color: var(--warn-fg); }
    .risk-low { background: var(--pass-bg); color: var(--pass-fg); }
    .comparison-list {
      list-style: none;
      font-size: 12.5px;
    }
    .comparison-list li {
      padding: 4px 0;
      border-top: 1px dashed rgba(15, 23, 42, 0.12);
    }
    /* KATEGORIE */
    .categories-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 10px;
      margin-bottom: 18px;
    }
    .cat-card {
      background: var(--surface-alt);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 10px 12px;
    }
    .cat-card-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 12.5px;
      margin-bottom: 6px;
    }
    .cat-title {
      font-weight: 700;
    }
    .progress-track {
      height: 7px;
      background: #e2e8f0;
      border-radius: 999px;
      overflow: hidden;
    }
    .progress-fill {
      height: 100%;
      border-radius: 999px;
    }
    /* TABELA KONTROLNA */
    table.audit-table {
      width: 100%;
      border-collapse: collapse;
      font-size: 12px;
      margin-bottom: 18px;
    }
    table.audit-table th,
    table.audit-table td {
      border: 1px solid var(--border);
      padding: 7px 9px;
      vertical-align: top;
      text-align: left;
    }
    table.audit-table th {
      background: #f1f5f9;
      font-weight: 800;
      font-size: 11.5px;
      text-transform: uppercase;
      letter-spacing: 0.03em;
    }
    .col-check { width: 27%; }
    .col-status { width: 17%; white-space: nowrap; }
    .col-detected { width: 24%; }
    .col-impact { width: 32%; color: #334155; }
    .check-title { font-weight: 700; color: var(--ink); }
    .check-cat { font-size: 10.5px; color: var(--muted); margin-top: 2px; }
    .status-pill {
      display: inline-block;
      font-size: 10.5px;
      font-weight: 700;
      padding: 2px 6px;
      border-radius: 4px;
    }
    .status-pass { background: var(--pass-bg); color: var(--pass-fg); }
    .status-warn { background: var(--warn-bg); color: var(--warn-fg); }
    .status-fail { background: var(--fail-bg); color: var(--fail-fg); }
    code {
      font-family: Consolas, 'JetBrains Mono', monospace;
      font-size: 11px;
      background: #f1f5f9;
      padding: 1px 4px;
      border-radius: 3px;
      word-break: break-word;
    }
    /* SEKCJA PLANU NAPRAWCZEGO I OFERTY */
    .remediation-box {
      background: linear-gradient(135deg, #f8fafc 0%, #eff6ff 100%);
      border: 2px solid #93c5fd;
      border-radius: 8px;
      padding: 14px 16px;
      page-break-inside: avoid;
    }
    .offer-grid {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 10px;
      margin-top: 10px;
    }
    .offer-tier {
      background: #ffffff;
      border: 1px solid #bfdbfe;
      border-radius: 6px;
      padding: 10px 12px;
    }
    .offer-tier-featured {
      border: 2px solid var(--brand);
      background: #f0f9ff;
    }
    .offer-tier h4 {
      font-size: 12.5px;
      font-weight: 800;
      color: var(--ink);
      margin-bottom: 4px;
    }
    .offer-price {
      font-size: 16px;
      font-weight: 900;
      color: var(--brand-dark);
      margin-bottom: 6px;
    }
    .offer-desc {
      font-size: 11.5px;
      color: var(--muted);
    }
    .report-footer {
      margin-top: 16px;
      padding-top: 10px;
      border-top: 1px solid var(--border);
      display: flex;
      justify-content: space-between;
      font-size: 11px;
      color: var(--muted);
    }
    .print-toolbar {
      max-width: 210mm;
      margin: 0 auto 12px;
      display: flex;
      justify-content: flex-end;
      gap: 8px;
    }
    .btn-print {
      background: var(--brand);
      color: #fff;
      border: none;
      padding: 8px 16px;
      border-radius: 6px;
      font-weight: 700;
      cursor: pointer;
      font-size: 13px;
    }
    @page {
      size: A4 portrait;
      margin: 10mm 10mm;
    }
    @media print {
      body {
        background: #ffffff;
        padding: 0;
        font-size: 11.5px;
      }
      .print-toolbar {
        display: none !important;
      }
      .page-sheet {
        box-shadow: none;
        padding: 0;
        max-width: 100%;
      }
      tr, .comparison-card, .cat-card, .remediation-box {
        break-inside: avoid;
      }
    }

    html {
      scrollbar-gutter: stable;
    }

    h1, h2, h3, h4 {
      text-wrap: balance;
    }

    p {
      text-wrap: pretty;
    }

    .score-tone-high { color: #15803d; }
    .score-tone-med { color: #b45309; }
    .score-tone-low { color: #b91c1c; }
    .score-grade-tag { font-size: 15px; }
    .cat-tone-high { color: #16a34a; }
    .cat-tone-med { color: #d97706; }
    .cat-tone-low { color: #dc2626; }
    .cat-tone-high-bg { background: #16a34a; }
    .cat-tone-med-bg { background: #d97706; }
    .cat-tone-low-bg { background: #dc2626; }
    .remediation-intro { font-size: 12.5px; color: #1e293b; }
    ${categoryDynamicCss}
  </style>
</head>
<body>
  <div class="print-toolbar">
    <button type="button" id="printAuditBtn" class="btn-print">🖨️ Drukuj / Zapisz jako PDF (A4)</button>
  </div>

  <main class="page-sheet">
    <header class="report-header">
      <div>
        <div class="brand-kicker">TwojaStronaWWW — Inżynieria Webowa &amp; Cyberbezpieczeństwo</div>
        <h1 class="report-title">TwojaStronaWWW — Ekspercki Audyt Wydajności, Bezpieczeństwa (ISO/OWASP) i Widoczności AI (GEO)</h1>
        <p class="report-subtitle">Raport techniczno-biznesowy „PRZED I PO” dla: <strong>${escapeHtml(meta.clientName)}</strong> (<code>${escapeHtml(meta.finalUrl)}</code>)</p>
      </div>
      <div class="meta-box">
        <div><strong>Data badania:</strong> ${escapeHtml(dateFormatted)}</div>
        <div><strong>Domena:</strong> ${escapeHtml(meta.hostname)}</div>
        <div><strong>Status HTTP:</strong> ${escapeHtml(meta.httpStatus)}</div>
        <div><strong>Standard:</strong> OWASP ASVS / WCAG 2.2 / GEO</div>
      </div>
    </header>

    <h2 class="section-heading">📊 Zestawienie Porównawcze „PRZED I PO” (Executive Summary)</h2>
    <section class="before-after-grid">
      <div class="comparison-card card-before">
        <span class="card-badge">STAN OBECNY (PRZED)</span>
        <div class="comparison-title">Obecna strona: ${escapeHtml(meta.hostname)}</div>
        <div class="score-display ${scoreToneClass}">Wynik: ${summary.totalScore} / ${summary.maxTotalScore} <small class="score-grade-tag">(Ocena ${summary.grade})</small></div>
        <div class="risk-pill ${summary.riskBadgeClass}">${escapeHtml(summary.riskLevel)}</div>
        <ul class="comparison-list">
          <li>⏱️ <strong>Czas odpowiedzi serwera (TTFB):</strong> <code>${summary.ttfbMs} ms</code> (pobranie HTML: <code>${summary.totalDownloadMs} ms</code>, rozmiar: <code>${summary.htmlKb} KB</code>)</li>
          <li>🛡️ <strong>Luki bezpieczeństwa OWASP, DNS (SPF/DMARC) i REST API:</strong> <strong>${summary.securityIssuesCount}</strong> z ${securityChecksTotal} punktów kontrolnych</li>
          <li>🧱 <strong>Architektura / narzut CMS:</strong> ${escapeHtml(cmsSummaryText)}</li>
          <li>🤖 <strong>Widoczność w wyszukiwarkach AI (ChatGPT / Perplexity):</strong> ${summary.hasLlmsTxt ? 'Aktywny plik /llms.txt' : 'BRAK pliku /llms.txt (ryzyko pominięcia przez AI)'}</li>
          <li>⚠️ <strong>Bilans testów kontrolnych:</strong> ✅ ${summary.passCount} zaliczonych | ⚠️ ${summary.warnCount} ostrzeżeń | ❌ ${summary.failCount} błędów</li>
        </ul>
      </div>

      <div class="comparison-card card-after">
        <span class="card-badge">PO WDROŻENIU TWOJASTRONAWWW</span>
        <div class="comparison-title">Standard TwojaStronaWWW (Czysty Kod Vanilla DevSecOps)</div>
        <div class="score-display score-tone-high">100 / 100 <small class="score-grade-tag">(Klasa Enterprise A+)</small></div>
        <div class="risk-pill risk-low">GWARANCJA BEZPIECZEŃSTWA I SZYBKOŚCI 24/7</div>
        <ul class="comparison-list">
          <li>⚡ <strong>Błyskawiczny czas ładowania (Benchmark Nolana Lawsona 10/2026):</strong> Nasz kod Vanilla JS to <code>7 KiB</code> (<code>0 ms TBT</code>, <code>&lt; 850 ms LCP</code>) wobec <strong>142 KiB JS</strong> (20x więcej), <strong>2 090 ms LCP</strong> i <strong>71 ms TBT</strong> w Next.js</li>
          <li>🔒 <strong>Pełny pakiet nagłówków OWASP [REF-01]/[REF-05]:</strong> HSTS, rygorystyczne CSP, COOP, CORP, <code>nosniff</code>, <code>security.txt</code></li>
          <li>💎 <strong>0 podatnych wtyczek WordPress:</strong> Czysty kod HTML5 + Vanilla CSS + ES6+ bez bazy danych SQL do zhakowania</li>
          <li>🧠 <strong>Gotowość na AI Search (GEO [REF-07] + WebMCP):</strong> Wdrożony standard <code>/llms.txt</code>, <code>document.modelContext</code>, pełny graf <code>Schema.org @graph</code> + <strong>Asystent AI RAG 24/7</strong></li>
          <li>📈 <strong>100% widoczności ruchu (Raport Moz 11/2026):</strong> <strong>Cookieless Web Analytics v3 (<code>web-analytics.php</code>) + GSC Sync</strong> bez banerów cookies — podczas gdy GA4 traci <strong>63,8% sesji organicznych</strong> i <strong>72,7% konwersji</strong> (71% odrzuceń zgód w UE)</li>
        </ul>
      </div>
    </section>

    <h2 class="section-heading">🎯 Wyniki w 4 Obszarach Technicznych i Biznesowych</h2>
    <section class="categories-grid">
      ${categoryCardsHtml}
    </section>

    <h2 class="section-heading">🔍 Szczegółowa Tabela Kontrolna (${checks.length} Punktów Audytowych ISO / OWASP / DNS / WCAG / GEO)</h2>
    <table class="audit-table">
      <thead>
        <tr>
          <th class="col-check">Obszar i badany parametr</th>
          <th class="col-status">Status i punkty</th>
          <th class="col-detected">Co wykryto na stronie</th>
          <th class="col-impact">Co to oznacza biznesowo dla Twojej firmy</th>
        </tr>
      </thead>
      <tbody>
        ${checklistRowsHtml}
      </tbody>
    </table>

    <h2 class="section-heading">🚀 Rekomendowany Plan Naprawczy / Migracja (Oferta TwojaStronaWWW)</h2>
    <section class="remediation-box">
      <p class="remediation-intro">
        Poniższy plan pozwala trwale wyeliminować wykryte błędy bezpieczeństwa (${summary.securityIssuesCount}), przyspieszyć ładowanie strony kilkukrotnie oraz otworzyć firmę na pozyskiwanie klientów z wyszukiwarek AI (ChatGPT, Google AI Overviews, Perplexity).
      </p>
      <div class="offer-grid">
        <div class="offer-tier">
          <h4>Etap 1: Audyt Wewnętrzny, Pełny Backup i Utwardzenie</h4>
          <div class="offer-price">od 500 zł netto</div>
          <p class="offer-desc">
            Pełna kopia bezpieczeństwa 1:1 plików i baz danych, wdrożenie darmowego Cloudflare SSL/WAF, nagłówków bezpieczeństwa OWASP (HSTS, CSP, nosniff) oraz pliku <code>security.txt</code>.
          </p>
        </div>
        <div class="offer-tier offer-tier-featured">
          <h4>Etap 2 (Rekomendowany): Nowa Strona bez WordPressa</h4>
          <div class="offer-price">wycena indywidualna / 5 500 zł netto</div>
          <p class="offer-desc">
            Przepisanie serwisu na architekturę <strong>TwojaStronaWWW Vanilla DevSecOps</strong>: wynik <strong>100/100</strong>, zero płatnych wtyczek, 100% odporności na wirusy WP, pełna zgodność z WCAG 2.2 AA.
          </p>
        </div>
        <div class="offer-tier">
          <h4>Etap 3: Pakiet Widoczności AI (GEO) + Asystent AI 24/7</h4>
          <div class="offer-price">od 1 500 zł netto</div>
          <p class="offer-desc">
            Wdrożenie standardu <code>/llms.txt</code>, grafu wiedzy <code>Schema.org @graph</code> oraz inteligentnego Asystenta AI odpowiadającego klientom 24/7 z powiadomieniami o leadach na telefon.
          </p>
        </div>
      </div>
    </section>

    <footer class="report-footer">
      <div><strong>TwojaStronaWWW</strong> • Krzysztof Początek • <a href="https://twojastronawww.pl">https://twojastronawww.pl</a> • kontakt@twojastronawww.pl</div>
      <div>Wygenerowano automatycznie przez <code>generate-client-audit.js</code> (ISO 27001 / OWASP ASVS)</div>
    </footer>
  </main>
  <script>
    document.getElementById('printAuditBtn')?.addEventListener('click', function () {
      window.print();
    });
  </script>
</body>
</html>`;
}

/**
 * Zapisuje pliki raportu (.json oraz .html) we wskazanym katalogu.
 * @param {ReturnType<typeof evaluateAuditData>} audit
 * @param {string} outDir
 */
export function writeAuditArtifacts(audit, outDir = DEFAULT_OUT_DIR) {
  fs.mkdirSync(outDir, { recursive: true });
  const safeHost = audit.meta.hostname.replace(/[^a-zA-Z0-9.-]/g, '_');
  const dateSlug = audit.meta.generatedAt.slice(0, 10);
  const baseName = `audit-${safeHost}-${dateSlug}`;

  const jsonPath = path.join(outDir, `${baseName}.json`);
  const htmlPath = path.join(outDir, `${baseName}.html`);

  fs.writeFileSync(jsonPath, JSON.stringify(audit, null, 2), 'utf8');
  fs.writeFileSync(htmlPath, renderAuditHtml(audit), 'utf8');

  return { jsonPath, htmlPath, baseName };
}
