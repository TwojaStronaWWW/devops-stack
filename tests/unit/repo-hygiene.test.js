import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ROOT_DIR = path.join(__dirname, '..', '..');

describe('Higiena repozytorium DevOps i bezpieczeństwo infrastruktury (ISO 27001)', () => {
  it('plik package.json powinien posiadać wymagane skrypty CI (test, check, prepare)', () => {
    const pkgPath = path.join(ROOT_DIR, 'package.json');
    assert.ok(fs.existsSync(pkgPath), 'Brak package.json w głównym katalogu');
    const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf-8'));

    assert.ok(pkg.scripts, 'Brak sekcji scripts w package.json');
    assert.ok(pkg.scripts.test, 'Brak skryptu test');
    assert.ok(pkg.scripts.check, 'Brak skryptu check');
    assert.ok(pkg.scripts.prepare, 'Brak skryptu prepare');
  });

  it('kluczowe pliki dokumentacji i standardów architektonicznych powinny istnieć', () => {
    const requiredDocs = [
      'AGENTS.md',
      'GEMINI.md',
      'README.md',
      'DISASTER_RECOVERY.md',
      'SECURITY.md',
      'LICENSE',
      '.editorconfig',
      '.gitattributes',
      '.npmrc',
      '.gitleaks.toml',
      '.github/pull_request_template.md',
      '.github/dependabot.yml',
      '.github/workflows/lint-compose.yml',
      '.github/workflows/deploy.yml',
      '.github/workflows/external-watchdog.yml',
    ];

    for (const doc of requiredDocs) {
      assert.ok(fs.existsSync(path.join(ROOT_DIR, doc)), `Brak wymaganego pliku: ${doc}`);
    }
  });

  it('główne pliki Docker Compose powinny istnieć i być niepuste', () => {
    const composeFiles = [
      path.join(ROOT_DIR, 'compose', 'docker-compose.yml'),
      path.join(ROOT_DIR, 'compose', 'runners.yml'),
      path.join(ROOT_DIR, 'compose', 'extensions.yml'),
    ];

    for (const cFile of composeFiles) {
      assert.ok(fs.existsSync(cFile), `Brak pliku compose: ${cFile}`);
      const stat = fs.statSync(cFile);
      assert.ok(stat.size > 0, `Plik compose jest pusty: ${cFile}`);
    }
  });

  it('szablony zmiennych środowiskowych .env.example oraz oracle-hunter.env.example powinny istnieć', () => {
    assert.ok(fs.existsSync(path.join(ROOT_DIR, '.env.example')), 'Brak .env.example');
    assert.ok(
      fs.existsSync(path.join(ROOT_DIR, 'scripts', 'oracle-hunter.env.example')),
      'Brak scripts/oracle-hunter.env.example'
    );
  });

  it('kluczowe pliki źródłowe nie mogą zawierać pozostałości po konfliktach gita (merge conflict markers)', () => {
    const extensionsToCheck = ['.yml', '.yaml', '.json', '.sh', '.ps1', '.cmd', '.md'];
    const CONFLICT_START = '<'.repeat(7) + ' ';
    const CONFLICT_END = '>'.repeat(7) + ' ';

    function scanDir(dir) {
      const entries = fs.readdirSync(dir, { withFileTypes: true });
      for (const entry of entries) {
        if (entry.name.startsWith('.git') || entry.name === 'node_modules') continue;
        const fullPath = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          scanDir(fullPath);
        } else if (extensionsToCheck.some((ext) => entry.name.endsWith(ext))) {
          const content = fs.readFileSync(fullPath, 'utf-8');
          assert.strictEqual(
            content.includes(CONFLICT_START) || content.includes(CONFLICT_END),
            false,
            `Wykryto marker konfliktu git w pliku: ${path.relative(ROOT_DIR, fullPath)}`
          );
        }
      }
    }

    scanDir(ROOT_DIR);
  });

  it('plik .gitignore powinien bezwzględnie chronić prywatne klucze, certyfikaty i pliki środowiskowe (ISO 27001)', () => {
    const gitignorePath = path.join(ROOT_DIR, '.gitignore');
    assert.ok(fs.existsSync(gitignorePath), 'Brak .gitignore');
    const content = fs.readFileSync(gitignorePath, 'utf-8');

    assert.match(content, /\.env/);
    assert.match(content, /\*\.pem/);
    assert.match(content, /\*\.key/);
    assert.match(content, /id_ed25519/);
    assert.match(content, /id_rsa/);
    assert.match(content, /backups\//);
    assert.match(content, /volumes\//);
    assert.match(content, /node_modules\//);
    assert.match(content, /\*password\*/);
    assert.match(content, /docs\/audits\//);
    assert.match(content, /\*\.kdbx/);
    assert.match(content, /\*token\*\.json/);
    assert.match(content, /\.chrome-\*\//);
  });

  it('skrypty automatyzacji 1-klik open-dashboard powinny istnieć i być zdefiniowane', () => {
    const ps1Path = path.join(ROOT_DIR, 'scripts', 'open-dashboard.ps1');
    const cmdPath = path.join(ROOT_DIR, 'scripts', 'open-dashboard.cmd');

    assert.ok(fs.existsSync(ps1Path), 'Brak scripts/open-dashboard.ps1');
    assert.ok(fs.existsSync(cmdPath), 'Brak scripts/open-dashboard.cmd');
    assert.ok(fs.statSync(ps1Path).size > 0, 'Plik scripts/open-dashboard.ps1 jest pusty');
    assert.ok(fs.statSync(cmdPath).size > 0, 'Plik scripts/open-dashboard.cmd jest pusty');
  });

  it('skrypty procedur backupu (wolumeny i hosting LH) powinny istnieć i posiadać poprawny shebang', () => {
    const backupScripts = [
      path.join(ROOT_DIR, 'scripts', 'backup-offsite.sh'),
      path.join(ROOT_DIR, 'scripts', 'backup-volumes.sh'),
      path.join(ROOT_DIR, 'scripts', 'backup-websites-lh.sh'),
    ];

    for (const bScript of backupScripts) {
      assert.ok(fs.existsSync(bScript), `Brak skryptu backupu: ${bScript}`);
      assert.ok(fs.statSync(bScript).size > 0, `Skrypt backupu jest pusty: ${bScript}`);
      const firstLine = fs.readFileSync(bScript, 'utf-8').split(/\r?\n/)[0];
      assert.match(firstLine, /^#!\/(usr\/bin\/env bash|bin\/bash)\s*$/);
    }
  });

  it('hooki gita (.githooks/pre-commit oraz .githooks/commit-msg) powinny istnieć i posiadać poprawny shebang', () => {
    const preCommitPath = path.join(ROOT_DIR, '.githooks', 'pre-commit');
    const commitMsgPath = path.join(ROOT_DIR, '.githooks', 'commit-msg');

    assert.ok(fs.existsSync(preCommitPath), 'Brak .githooks/pre-commit');
    assert.ok(fs.existsSync(commitMsgPath), 'Brak .githooks/commit-msg');

    const preCommitFirst = fs.readFileSync(preCommitPath, 'utf-8').split(/\r?\n/)[0];
    const commitMsgFirst = fs.readFileSync(commitMsgPath, 'utf-8').split(/\r?\n/)[0];

    assert.match(preCommitFirst, /^#!\/(usr\/bin\/env bash|bin\/bash)\s*$/);
    assert.match(commitMsgFirst, /^#!\/(usr\/bin\/env bash|bin\/bash)\s*$/);
  });

  it('pliki definicji dashboardów Grafany w formacie JSON powinny być poprawnym JSON-em', () => {
    const kumaDashboard = path.join(
      ROOT_DIR,
      'config',
      'grafana',
      'provisioning',
      'dashboards',
      'definitions',
      'uptime-kuma-overview.json'
    );
    assert.ok(fs.existsSync(kumaDashboard), 'Brak dashboardu uptime-kuma-overview.json');
    assert.doesNotThrow(() => {
      JSON.parse(fs.readFileSync(kumaDashboard, 'utf-8'));
    }, 'Błąd parsowania JSON w uptime-kuma-overview.json');
  });

  it('konfiguracja Dependabot powinna nadzorować akcje GitHub oraz obrazy Docker', () => {
    const depPath = path.join(ROOT_DIR, '.github', 'dependabot.yml');
    assert.ok(fs.existsSync(depPath), 'Brak .github/dependabot.yml');
    const content = fs.readFileSync(depPath, 'utf-8');

    assert.match(content, /package-ecosystem:\s*"github-actions"/i);
    assert.match(content, /package-ecosystem:\s*"docker"/i);
    assert.match(content, /package-ecosystem:\s*"npm"/i);
  });

  it('moduł services/ai-router powinien posiadać kompletną strukturę (Dockerfile, kod PHP, RAG, tester)', () => {
    const requiredRouterFiles = [
      path.join(ROOT_DIR, 'services', 'ai-router', 'Dockerfile'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'sites-registry.php'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'chat-router.php'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'router-endpoints.php'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'llm-cascade.php'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'lead-notifier.php'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'pii-guard.php'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'ai-stats.php'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'web-analytics.php'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'web-analytics-labels.php'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'amms-rag-search.php'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'amms-teams.html'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'widget.js'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'data', 'katosalsahub-knowledge.txt'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'data', 'dancepuls-knowledge.txt'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'data', 'raricart-knowledge.txt'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'data', 'fuegolingua-knowledge.txt'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'data', 'twojastronawww-knowledge.txt'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'data', 'amms-knowledge.txt'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'data', 'radar-p1-knowledge.txt'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'data', 'medicusnoster-knowledge.txt'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'storage', 'rate_limits', '.gitkeep'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'public-test', 'index.html'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'public-test', 'app.js'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'public-test', 'style.css'),
    ];

    for (const rFile of requiredRouterFiles) {
      assert.ok(fs.existsSync(rFile), `Brak wymaganego pliku routera: ${rFile}`);
      assert.ok(fs.statSync(rFile).size > 0, `Plik routera jest pusty: ${rFile}`);
    }
  });

  function readRouterCombinedPhp() {
    return ['sites-registry.php', 'chat-router.php', 'router-endpoints.php', 'llm-cascade.php', 'lead-notifier.php']
      .map((f) => fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'src', f), 'utf-8'))
      .join('\n');
  }

  function readStatsCombinedPhp() {
    return ['ai-stats.php', 'web-analytics.php', 'web-analytics-labels.php']
      .map((f) => fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'src', f), 'utf-8'))
      .join('\n');
  }

  it('skrypt chat-router.php powinien realizować wymogi bezpieczeństwa, pamięci konwersacji i kaskadowego fallbacku modeli (ISO 27001)', () => {
    const content = readRouterCombinedPhp();

    // Brak zahardkodowanego klucza API
    assert.strictEqual(content.includes('AIzaSy'), false, 'Wykryto zahardkodowany klucz Gemini API w chat-router.php');
    // Odczyt z env
    assert.match(content, /getenv\(['"]GEMINI_API_KEY['"]\)/);
    // Odczyt z nagłówka Cloudflare
    assert.match(content, /HTTP_CF_CONNECTING_IP/);
    // Endpoint healthcheck
    assert.match(content, /\/health/);
    // Zabezpieczenie Content-Type
    assert.match(content, /application\/json/);
    // Domyślny model gemini-3.8-flash oraz kaskada fallbacku i pamięć Multi-Turn
    assert.match(content, /gemini-3\.8-flash/);
    assert.match(content, /\$sanitizedHistory/);
  });

  it('docker-compose.yml powinien zawierać zdefiniowany serwis ai-router, wolumen ai_router_storage oraz utwardzony stos FreeScout + MariaDB', () => {
    const composePath = path.join(ROOT_DIR, 'compose', 'docker-compose.yml');
    const content = fs.readFileSync(composePath, 'utf-8');

    assert.match(content, /ai-router:/);
    assert.match(content, /ai_router_storage:/);
    assert.match(content, /127\.0\.0\.1:8085:8080/);
    assert.match(content, /data:\/app\/data:ro/);
    assert.match(content, /freescout-db:/);
    assert.match(content, /freescout:/);
    assert.match(content, /127\.0\.0\.1:8088:80/);
    assert.match(content, /freescout_db_data:/);
    assert.match(content, /freescout_data:/);
    assert.match(content, /freescout_logs:/);
  });

  it('skrypty diagnostyki i audytu żywego serwera (audit-server.sh, verify-remote.ps1/.cmd) powinny istnieć i eksportować metryki', () => {
    const auditSh = path.join(ROOT_DIR, 'scripts', 'audit-server.sh');
    const verifyPs1 = path.join(ROOT_DIR, 'scripts', 'verify-remote.ps1');
    const verifyCmd = path.join(ROOT_DIR, 'scripts', 'verify-remote.cmd');

    assert.ok(fs.existsSync(auditSh), 'Brak scripts/audit-server.sh');
    assert.ok(fs.existsSync(verifyPs1), 'Brak scripts/verify-remote.ps1');
    assert.ok(fs.existsSync(verifyCmd), 'Brak scripts/verify-remote.cmd');

    const auditContent = fs.readFileSync(auditSh, 'utf-8');
    const firstLine = auditContent.split(/\r?\n/)[0];
    assert.match(firstLine, /^#!\/(usr\/bin\/env bash|bin\/bash)\s*$/);
    assert.match(auditContent, /devops_audit_status/);
    assert.match(auditContent, /audit\.prom/);
    assert.match(auditContent, /amms-knowledge\.sqlite/);
    assert.match(auditContent, /http:\/\/127\.0\.0\.1:8085\/amms/);
    assert.match(auditContent, /sync-gsc-keywords\.sh/);
    assert.strictEqual(auditContent.includes('${STACK_DIR}'), false, 'W audit-server.sh wykryto niezdefiniowaną zmienną ${STACK_DIR} zamiast ${STACK_ROOT}!');
  });

  it('wszystkie pliki Docker Compose powinny definiować czytelne etykiety dev.dozzle.name dla kontenerów', () => {
    const composeMain = fs.readFileSync(path.join(ROOT_DIR, 'compose', 'docker-compose.yml'), 'utf-8');
    const composeExt = fs.readFileSync(path.join(ROOT_DIR, 'compose', 'extensions.yml'), 'utf-8');
    const composeRunners = fs.readFileSync(path.join(ROOT_DIR, 'compose', 'runners.yml'), 'utf-8');

    assert.match(composeMain, /dev\.dozzle\.name:\s*"uptime-kuma • Monitoring Stron WWW"/);
    assert.match(composeMain, /dev\.dozzle\.name:\s*"prometheus • Baza Metryk TSDB"/);
    assert.match(composeMain, /dev\.dozzle\.name:\s*"grafana • Dashboardy i Wykresy"/);
    assert.match(composeMain, /dev\.dozzle\.name:\s*"ai-router • Czatbot AI & AMMS"/);
    assert.match(composeMain, /dev\.dozzle\.name:\s*"freescout-db • Baza Poczty MariaDB"/);
    assert.match(composeMain, /dev\.dozzle\.name:\s*"freescout • Centrum Poczty & Helpdesk"/);
    assert.match(composeExt, /dev\.dozzle\.name:\s*"cloudflared • Tunel Zero Trust"/);
    assert.match(composeRunners, /dev\.dozzle\.name:\s*"runner-twojastronawww • CI\/CD TwojaStronaWWW"/);
    assert.match(composeRunners, /dev\.dozzle\.name:\s*"runner-zeslownikiem • CI\/CD ZeSłownikiem"/);
  });

  it('skrypt setup-kuma.js powinien być idempotentny (usuwać duplikaty) i posiadać poprawny URL DancePuls', () => {
    const kumaScript = fs.readFileSync(path.join(ROOT_DIR, 'scripts', 'setup-kuma.js'), 'utf-8');
    assert.match(kumaScript, /https:\/\/katosalsahub\.pl\/dancepuls\//);
    assert.strictEqual(kumaScript.includes('https://dancepuls.pl"'), false, 'Wykryto stary, niedziałający URL https://dancepuls.pl');
    assert.match(kumaScript, /deleteMonitor/);
    assert.match(kumaScript, /monitorList/);
  });

  it('telemetria AI Routera (ai-stats.php + web-analytics.php) nie powinna logować treści pytań, IP ani kluczy API (ISO 27001)', () => {
    const statsPath = path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'ai-stats.php');
    assert.ok(fs.existsSync(statsPath), 'Brak services/ai-router/src/ai-stats.php');
    const stats = readStatsCombinedPhp();
    assert.strictEqual(stats.includes('AIzaSy'), false, 'Klucz API w ai-stats.php');
    assert.strictEqual(/REMOTE_ADDR|CF_CONNECTING_IP|X_FORWARDED_FOR/.test(stats), false, 'ai-stats.php nie może operować na adresach IP');
    assert.match(stats, /function aiRenderMetrics/);
    assert.match(stats, /function aiCooldownRemaining/);

    const router = readRouterCombinedPhp();
    assert.match(router, /require_once __DIR__ \. '\/ai-stats\.php'/);
    assert.match(router, /register_shutdown_function/);
    // Do logów trafiają tylko metadane - nigdy $question/$knowledgeContent/$geminiApiKey/$cerebrasApiKey/$mistralApiKey/$cfAiToken
    assert.strictEqual(/aiLog\([^;]*\$(question|knowledgeContent|geminiApiKey|groqApiKey|cerebrasApiKey|mistralApiKey|cfAiToken|openRouterApiKey)/.test(router), false);
    assert.strictEqual(router.includes('csk-'), false, 'Wykryto zahardkodowany klucz Cerebras API w chat-router.php');
    assert.strictEqual(router.includes('mstrl_'), false, 'Wykryto zahardkodowany klucz Mistral API w chat-router.php');
    assert.strictEqual(router.includes('cfut_'), false, 'Wykryto zahardkodowany token Cloudflare Workers AI w chat-router.php');
  });

  it('dashboard AI Router oraz Centrum Monitoringu w Grafanie powinny być poprawnym JSON-em z unikalnymi ID paneli i pełną telemetrią', () => {
    const dashPath = path.join(ROOT_DIR, 'config', 'grafana', 'provisioning', 'dashboards', 'definitions', 'ai-router-overview.json');
    const dash = JSON.parse(fs.readFileSync(dashPath, 'utf-8'));
    const ids = dash.panels.map((p) => p.id);
    assert.strictEqual(new Set(ids).size, ids.length, 'Zduplikowane ID paneli w dashboardzie ai-router-overview');
    const exprs = JSON.stringify(dash.panels);
    for (const metric of [
      'ai_router_model_suspended',
      'ai_router_model_requests_today',
      'ai_router_model_skipped_today',
      'ai_router_answers_by_depth_total',
      'ai_router_model_attempts_total',
      'ai_router_cache_hits_total',
      'ai_router_cache_entries',
      'ai_router_leads_total',
      'ai_router_amms_sqlite_status',
      'ai_router_amms_sqlite_size_bytes',
    ]) {
      assert.ok(exprs.includes(metric), `Dashboard ai-router-overview nie wizualizuje metryki ${metric}`);
    }

    const kumaDashPath = path.join(ROOT_DIR, 'config', 'grafana', 'provisioning', 'dashboards', 'definitions', 'uptime-kuma-overview.json');
    const kumaDash = JSON.parse(fs.readFileSync(kumaDashPath, 'utf-8'));
    const kumaIds = kumaDash.panels.map((p) => p.id);
    assert.strictEqual(new Set(kumaIds).size, kumaIds.length, 'Zduplikowane ID paneli w dashboardzie uptime-kuma-overview');
    const kumaExprs = JSON.stringify(kumaDash.panels);
    for (const metric of [
      'cloudflared_tunnel_ha_connections',
      'devops_backup_verified',
      'devops_backup_websites_db_verified',
      'devops_audit_status',
      'devops_fail2ban_banned_total',
      'devops_ntp_synchronized',
      'devops_security_ioc_clean',
      'devops_backup_restore_drill_verified',
      'ai_router_amms_sqlite_status',
      'ai_router_amms_sqlite_size_bytes',
    ]) {
      assert.ok(kumaExprs.includes(metric), `Dashboard uptime-kuma-overview nie wizualizuje metryki ${metric}`);
    }

    const webDashPath = path.join(ROOT_DIR, 'config', 'grafana', 'provisioning', 'dashboards', 'definitions', 'web-analytics-overview.json');
    const webDash = JSON.parse(fs.readFileSync(webDashPath, 'utf-8'));
    const webIds = webDash.panels.map((p) => p.id);
    assert.strictEqual(new Set(webIds).size, webIds.length, 'Zduplikowane ID paneli w dashboardzie web-analytics-overview');
    assert.ok(Array.isArray(webDash.templating?.list) && webDash.templating.list.some((v) => v.name === 'site'), 'Brak zmiennej $site w web-analytics-overview.json');
    const periodVar = webDash.templating?.list?.find((v) => v.name === 'period');
    assert.ok(periodVar, 'Brak zmiennej przełącznika dnia $period w web-analytics-overview.json');
    assert.strictEqual(periodVar.current?.value, 'auto', 'Domyślną wartością przełącznika $period w Grafanie musi być auto (do 09:00 Wczoraj / po 09:00 Dziś)');
    const periodOptionValues = (periodVar.options || []).map((o) => o.value);
    for (const pOpt of ['auto', 'today', 'yesterday', 'total']) {
      assert.ok(periodOptionValues.includes(pOpt), `Brak opcji '${pOpt}' w przełączniku $period dashboardu web-analytics-overview.json`);
    }
    const uvPanel = webDash.panels.find((p) => p.id === 301);
    assert.ok(uvPanel, 'Brak panelu 301 (Unikalni Odwiedzający) w web-analytics-overview.json');
    assert.strictEqual(
      uvPanel.targets[0].expr.includes('web_analytics_unique_visitors_today'),
      false,
      'Panel 301 nie może łączyć operatorem OR metryki bez etykiety effective_label (powoduje to zduplikowany kafelek Value)'
    );
    const webExprs = JSON.stringify(webDash.panels);
    for (const metric of [
      'web_analytics_period_unique_visitors',
      'web_analytics_period_pageviews',
      'web_analytics_period_sources',
      'web_analytics_period_engaged_visits',
      'web_analytics_period_devices',
      'web_analytics_period_countries',
      'web_analytics_period_search_terms',
      'web_analytics_period_events',
      'web_analytics_period_lcp_seconds_sum',
      'ai_router_period_question_topics',
      'web_analytics_unique_visitors_today',
      'web_analytics_unique_visitors_total',
      'web_analytics_engaged_visits_total',
      'web_analytics_pageviews_total',
      'web_analytics_sources_total',
      'web_analytics_devices_total',
      'web_analytics_countries_total',
      'web_analytics_search_terms_total',
      'web_analytics_events_total',
      'web_analytics_cwv_lcp_seconds_sum',
    ]) {
      assert.ok(webExprs.includes(metric), `Dashboard web-analytics-overview nie wizualizuje metryki ${metric}`);
    }
  });

  it('reguły alertów Prometheusa dla AI Routera oraz infrastruktury VPS powinny być zamontowane i wczytywane', () => {
    const rules = path.join(ROOT_DIR, 'config', 'prometheus', 'rules', 'ai-router.yml');
    assert.ok(fs.existsSync(rules), 'Brak config/prometheus/rules/ai-router.yml');
    const rulesContent = fs.readFileSync(rules, 'utf-8');
    for (const alertName of [
      'AIRouterDown',
      'AIRouterAllModelsFailed',
      'AIRouterPrimaryModelSuspended',
      'AIRouterModelQuotaNearLimit',
      'WebsiteOrServiceDown',
      'SSLCertificateExpiringSoon',
      'VPSHostDiskSpaceLow',
      'VPSHostMemoryLow',
      'VPSHostHighCPU',
      'VPSHostInodesLow',
      'VPSClockNotSynchronized',
      'ChangeRadarStaleOrFailed',
      'P1RadarSyncStale',
    ]) {
      assert.match(rulesContent, new RegExp(`alert:\\s*${alertName}`));
    }
    assert.match(fs.readFileSync(path.join(ROOT_DIR, 'config', 'prometheus', 'prometheus.yml'), 'utf-8'), /\/etc\/prometheus\/rules\/\*\.yml/);
    const compose = fs.readFileSync(path.join(ROOT_DIR, 'compose', 'docker-compose.yml'), 'utf-8');
    assert.match(compose, /config\/prometheus\/rules:\/etc\/prometheus\/rules:ro/);
    assert.match(compose, /PHP_CLI_SERVER_WORKERS=4/);
  });

  it('uid źródła danych Prometheus w provisioningu Grafany powinien zgadzać się z uid używanym w dashboardach', () => {
    const dsYml = fs.readFileSync(path.join(ROOT_DIR, 'config', 'grafana', 'provisioning', 'datasources', 'prometheus.yml'), 'utf-8');
    assert.match(dsYml, /uid:\s*prometheus\s*$/m, 'Brak stałego uid: prometheus w źródle danych Grafany');
    const defsDir = path.join(ROOT_DIR, 'config', 'grafana', 'provisioning', 'dashboards', 'definitions');
    for (const f of fs.readdirSync(defsDir).filter((n) => n.endsWith('.json'))) {
      const uids = new Set([...fs.readFileSync(path.join(defsDir, f), 'utf-8').matchAll(/"datasource":\s*\{[^}]*"uid":\s*"([^"]+)"/g)].map((m) => m[1]));
      for (const uid of [...uids].filter((u) => !u.startsWith('--'))) { // '-- Grafana --' to wbudowane źródło adnotacji
        assert.strictEqual(uid, 'prometheus', `Dashboard ${f} używa nieznanego uid źródła danych: ${uid}`);
      }
    }
  });

  it('narzędzia raportowe AI Routera (ai-router-report.sh/.ps1) oraz lokalnego audytu diffu (ai-review-staged.sh/.ps1) powinny istnieć', () => {
    const sh = path.join(ROOT_DIR, 'scripts', 'ai-router-report.sh');
    const ps1 = path.join(ROOT_DIR, 'scripts', 'ai-router-report.ps1');
    const revSh = path.join(ROOT_DIR, 'scripts', 'ai-review-staged.sh');
    const revPs1 = path.join(ROOT_DIR, 'scripts', 'ai-review-staged.ps1');
    assert.ok(fs.existsSync(sh), 'Brak scripts/ai-router-report.sh');
    assert.ok(fs.existsSync(ps1), 'Brak scripts/ai-router-report.ps1');
    assert.ok(fs.existsSync(revSh), 'Brak scripts/ai-review-staged.sh');
    assert.ok(fs.existsSync(revPs1), 'Brak scripts/ai-review-staged.ps1');
    assert.match(fs.readFileSync(sh, 'utf-8').split(/\r?\n/)[0], /^#!\/(usr\/bin\/env bash|bin\/bash)\s*$/);
    assert.match(fs.readFileSync(revSh, 'utf-8').split(/\r?\n/)[0], /^#!\/(usr\/bin\/env bash|bin\/bash)\s*$/);
  });

  it('utwardzenia bezpieczeństwa (Grafana PoLP Viewer, FTPS TLS, szyfrowanie AES-256 backupów, GC rate-limit, .env.bak*) powinny być aktywne', () => {
    const gitignore = fs.readFileSync(path.join(ROOT_DIR, '.gitignore'), 'utf-8');
    assert.match(gitignore, /\.env\.bak\*/);

    const compose = fs.readFileSync(path.join(ROOT_DIR, 'compose', 'docker-compose.yml'), 'utf-8');
    assert.match(compose, /GF_AUTH_ANONYMOUS_ORG_ROLE=\$\{GF_AUTH_ANONYMOUS_ORG_ROLE:-Viewer\}/);

    const lhBackup = fs.readFileSync(path.join(ROOT_DIR, 'scripts', 'backup-websites-lh.sh'), 'utf-8');
    assert.strictEqual(lhBackup.includes('set ftp:ssl-allow no'), false, 'Skrypt backup-websites-lh.sh nie może wymuszać nieszyfrowanego FTP');
    assert.match(lhBackup, /set ftp:ssl-protect-data true/);
    assert.match(lhBackup, /LH_FTP_VERIFY_CERT="\$\{LH_FTP_VERIFY_CERT:-yes\}"/);
    assert.match(lhBackup, /openssl enc -aes-256-cbc -pbkdf2/);

    const offsiteBackup = fs.readFileSync(path.join(ROOT_DIR, 'scripts', 'backup-offsite.sh'), 'utf-8');
    assert.match(offsiteBackup, /openssl enc -aes-256-cbc -pbkdf2/);
    assert.match(offsiteBackup, /runner_gal_anonim_web_data/);
    assert.match(offsiteBackup, /freescout_db_data/);
    assert.match(offsiteBackup, /freescout_data/);
    assert.match(offsiteBackup, /freescout_logs/);
    assert.match(offsiteBackup, /mariadb-dump/);

    assert.ok(fs.existsSync(path.join(ROOT_DIR, 'scripts', 'setup-freescout-mailboxes.php')), 'Brak scripts/setup-freescout-mailboxes.php');
    assert.ok(fs.existsSync(path.join(ROOT_DIR, 'scripts', 'setup-freescout-mailboxes.sh')), 'Brak scripts/setup-freescout-mailboxes.sh');
    assert.ok(fs.existsSync(path.join(ROOT_DIR, 'scripts', 'install-freescout-social-modules.sh')), 'Brak scripts/install-freescout-social-modules.sh');
    assert.ok(fs.existsSync(path.join(ROOT_DIR, 'services', 'freescout', 'modules', 'MetaMessenger', 'module.json')), 'Brak services/freescout/modules/MetaMessenger/module.json');
    assert.ok(fs.existsSync(path.join(ROOT_DIR, 'scripts', 'sync-freescout-ntfy.sh')), 'Brak scripts/sync-freescout-ntfy.sh');
    assert.ok(fs.existsSync(path.join(ROOT_DIR, 'scripts', 'setup-freescout-ntfy-timer.sh')), 'Brak scripts/setup-freescout-ntfy-timer.sh');

    const routerPhp = readRouterCombinedPhp();
    assert.match(routerPhp, /filemtime\(\$oldRateFile\)/);
    assert.match(routerPhp, /CURLOPT_FOLLOWLOCATION\s*=>\s*false/);
    assert.match(routerPhp, /CURLOPT_MAXREDIRS\s*=>\s*0/);
    assert.match(routerPhp, /CURLPROTO_HTTPS/);
    assert.match(routerPhp, /HTTP_SEC_FETCH_SITE/);

    const statsPhp = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'ai-stats.php'), 'utf-8');
    assert.match(statsPhp, /\.bak/);

    const secReviewYml = fs.readFileSync(path.join(ROOT_DIR, '.github', 'workflows', 'ai-security-review.yml'), 'utf-8');
    assert.match(secReviewYml, /services\/ai-router\/\*\*/);
    assert.match(secReviewYml, /scripts\/\*\*/);
    assert.match(secReviewYml, /author_association/);

    const syncP1Sh = [
      fs.readFileSync(path.join(ROOT_DIR, 'scripts', 'sync-p1-status.sh'), 'utf-8'),
      fs.readFileSync(path.join(ROOT_DIR, 'scripts', 'p1-status-engine.py'), 'utf-8'),
    ].join('\n');
    assert.match(syncP1Sh, /def write_file_atomic/);
    assert.match(syncP1Sh, /ssl_verified_ctx = ssl\.create_default_context\(\)/);
  });

  it('ulepszenia Enterprise (Cache RAG <5ms, Detektor Leadów i Kontaktów Ntfy, izolacja sieci runnerów, weryfikacja tar -tzf + SQLite + MySQL, timer audytu i backupów 24/7) powinny być wdrożone', () => {
    const statsPhp = readStatsCombinedPhp();
    assert.match(statsPhp, /ai_router_cache_hits_total/);
    assert.match(statsPhp, /ai_router_cache_entries/);
    assert.match(statsPhp, /ai_router_leads_total/);
    assert.match(statsPhp, /function aiRecordCacheHit/);
    assert.match(statsPhp, /function aiRecordLead/);

    const routerPhp = readRouterCombinedPhp();
    assert.match(routerPhp, /aiRecordCacheHit/);
    assert.match(routerPhp, /aiRecordLead/);
    assert.match(routerPhp, /hot_lead_detected/);
    assert.match(routerPhp, /contact_lead_captured/);
    assert.match(routerPhp, /LEAD_WEBHOOK_URL/);
    assert.match(routerPhp, /TELEFON:/);
    assert.match(routerPhp, /E-MAIL:/);
    assert.match(routerPhp, /Actions:/);
    assert.match(routerPhp, /thinkingLevel/);
    assert.match(routerPhp, /MAX_TOKENS/);
    assert.match(routerPhp, /'reasoning'\s*=>\s*\['effort'\s*=>\s*'none'\]/);

    const ntfyScript = fs.readFileSync(path.join(ROOT_DIR, 'scripts', 'setup-ntfy.js'), 'utf-8');
    assert.match(ntfyScript, /import\s+\{\s*io\s*\}\s+from\s+"socket\.io-client"/);
    assert.match(ntfyScript, /deleteNotification/);

    const warmCacheSh = path.join(ROOT_DIR, 'scripts', 'warm-ai-cache.sh');
    assert.ok(fs.existsSync(warmCacheSh), 'Brak scripts/warm-ai-cache.sh');
    const warmCacheContent = fs.readFileSync(warmCacheSh, 'utf-8');
    assert.match(warmCacheContent.split(/\r?\n/)[0], /^#!\/(usr\/bin\/env bash|bin\/bash)\s*$/);
    assert.match(warmCacheContent, /blocked_until/, 'warm-ai-cache.sh musi chronić aktywne blokady Penalty Box (blocked_until)');

    const runnersYml = fs.readFileSync(path.join(ROOT_DIR, 'compose', 'runners.yml'), 'utf-8');
    assert.match(runnersYml, /name:\s*devops_runners_network/);

    const extensionsYml = fs.readFileSync(path.join(ROOT_DIR, 'compose', 'extensions.yml'), 'utf-8');
    assert.match(extensionsYml, /--metrics\s+0\.0\.0\.0:2000/);

    const promYml = fs.readFileSync(path.join(ROOT_DIR, 'config', 'prometheus', 'prometheus.yml'), 'utf-8');
    assert.match(promYml, /cloudflared:2000/);

    const rulesYml = fs.readFileSync(path.join(ROOT_DIR, 'config', 'prometheus', 'rules', 'ai-router.yml'), 'utf-8');
    assert.match(rulesYml, /alert:\s*CloudflareTunnelDown/);
    assert.match(rulesYml, /alert:\s*AIRouterModelDeprecated/);
    assert.match(rulesYml, /alert:\s*VPSSecurityBreachIoCDetected/);

    const offsiteBackup = fs.readFileSync(path.join(ROOT_DIR, 'scripts', 'backup-offsite.sh'), 'utf-8');
    assert.match(offsiteBackup, /devops_backup_verified/);
    assert.match(offsiteBackup, /devops_backup_sqlite_verified/);
    assert.match(offsiteBackup, /PRAGMA quick_check/);
    assert.match(offsiteBackup, /RETENTION_DAYS="\$\{RETENTION_DAYS:-30\}"/);
    assert.match(offsiteBackup, /R2_RETENTION_DAYS="\$\{R2_RETENTION_DAYS:-14\}"/);
    assert.match(offsiteBackup, /delete --min-age "\$\{R2_RETENTION_DAYS\}d"/);
    assert.match(offsiteBackup, /amms-knowledge\.sqlite\.gz\.enc/);
    assert.match(offsiteBackup, /docker image prune -f/);

    const deployYml = fs.readFileSync(path.join(ROOT_DIR, '.github', 'workflows', 'deploy.yml'), 'utf-8');
    assert.match(deployYml, /docker image prune -f/);
    assert.match(deployYml, /docker builder prune/);

    const auditSh = fs.readFileSync(path.join(ROOT_DIR, 'scripts', 'audit-server.sh'), 'utf-8');
    const morningDigestPyPath = path.join(ROOT_DIR, 'scripts', 'morning-digest.py');
    assert.ok(fs.existsSync(morningDigestPyPath), 'Brak scripts/morning-digest.py');
    const morningDigestPy = fs.readFileSync(morningDigestPyPath, 'utf-8');
    const combinedAuditAndDigest = auditSh + '\n' + morningDigestPy;
    assert.match(auditSh, /docker image prune -f/);
    assert.match(auditSh, /devops_oci_keepalive_buffer_bytes/);
    assert.match(auditSh, /devops_ntp_synchronized/);
    assert.match(auditSh, /github_request_failures_total/);
    assert.match(auditSh, /devops_waf_blocked_total/);
    assert.match(auditSh, /devops_log_critical_24h_total/);
    assert.match(combinedAuditAndDigest, /"reasoning_effort":\s*"high"/);
    assert.match(combinedAuditAndDigest, /"thinkingLevel":\s*"HIGH"/);

    const lhBackup = fs.readFileSync(path.join(ROOT_DIR, 'scripts', 'backup-websites-lh.sh'), 'utf-8');
    assert.match(lhBackup, /devops_backup_websites_verified/);
    assert.match(lhBackup, /devops_backup_websites_db_verified/);
    assert.match(lhBackup, /LH_DB_NAMES/);
    assert.match(lhBackup, /RETENTION_DAYS="\$\{RETENTION_DAYS:-30\}"/);
    assert.match(lhBackup, /R2_RETENTION_DAYS="\$\{R2_RETENTION_DAYS:-14\}"/);
    assert.match(lhBackup, /mirror --verbose --delete --no-perms/);
    assert.match(lhBackup, /delete --min-age "\$\{R2_RETENTION_DAYS\}d"/);

    const setupAuditTimer = path.join(ROOT_DIR, 'scripts', 'setup-audit-timer.sh');
    assert.ok(fs.existsSync(setupAuditTimer), 'Brak scripts/setup-audit-timer.sh');

    const setupBackupTimer = path.join(ROOT_DIR, 'scripts', 'setup-backup-timer.sh');
    assert.ok(fs.existsSync(setupBackupTimer), 'Brak scripts/setup-backup-timer.sh');
    assert.match(fs.readFileSync(setupBackupTimer, 'utf-8').split(/\r?\n/)[0], /^#!\/(usr\/bin\/env bash|bin\/bash)\s*$/);

    const restoreBackup = path.join(ROOT_DIR, 'scripts', 'restore-backup.sh');
    assert.ok(fs.existsSync(restoreBackup), 'Brak scripts/restore-backup.sh');
    const restoreBackupContent = fs.readFileSync(restoreBackup, 'utf-8');
    assert.match(restoreBackupContent.split(/\r?\n/)[0], /^#!\/(usr\/bin\/env bash|bin\/bash)\s*$/);
    assert.match(restoreBackupContent, /amms-knowledge\.sqlite\.gz\.enc/);

    const syncGscSh = path.join(ROOT_DIR, 'scripts', 'sync-gsc-keywords.sh');
    assert.ok(fs.existsSync(syncGscSh), 'Brak scripts/sync-gsc-keywords.sh');
    assert.match(fs.readFileSync(syncGscSh, 'utf-8').split(/\r?\n/)[0], /^#!\/(usr\/bin\/env bash|bin\/bash)\s*$/);
    assert.match(statsPhp, /ai_router_question_topics_total/);
    assert.match(statsPhp, /web_analytics_gsc_keyword_clicks_total/);
    assert.match(statsPhp, /web_analytics_gsc_keyword_position/);
  });

  it('weryfikacja krzyżowa (Cross-Template Contract): VPS AI Router, warm-ai-cache.sh oraz _site-template powinny zachowywać 100% spójność kontraktu', () => {
    const warmCache = fs.readFileSync(path.join(ROOT_DIR, 'scripts', 'warm-ai-cache.sh'), 'utf-8');
    const routerPhp = readRouterCombinedPhp();
    const vpsWidget = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'widget.js'), 'utf-8');

    // Kontrakt pól JSON obsługiwanych przez chat-router.php
    for (const field of ['site_id', 'question', 'kb_version', 'dynamic_context', 'history']) {
      assert.match(routerPhp, new RegExp(`\\$payload\\['${field}'\\]`));
    }

    // Sprawdzenie, czy wszystkie szybkie pytania z widgetu są rozgrzewane w warm-ai-cache.sh
    for (const prompt of [
      'Ile kosztuje strona WWW?',
      'Dlaczego kod zamiast WordPressa?',
      'Wdrożenie czatbota AI (RAG)',
      'Jak wygląda współpraca?',
      'Bezpłatna lekcja próbna',
      'Ile kosztuje kurs hiszpańskiego?',
      'Zajęcia indywidualne czy grupowe?',
      'Hiszpański w biznesie / branżowy',
      'Co dzieje się w Wolnych Ludziach w niedzielę (15:00–18:00)?',
      'Gdzie tańczymy w Katowicach i gdzie za darmo zaparkować?',
      'Czym zajmuje się społeczność i Fundacja Kato Salsa Hub?',
      'Wyjaśnij figury: Dile Que No, Enchufla i Setenta',
      'Jak wygląda wycena i rezerwacja terminu?',
      'Czy można połączyć kilka stoisk na jednym przyjęciu?',
      'Czym jest aplikacja DancePuls?',
      'Jak działa trening rytmu i clave?',
      'Co zrobić w gabinecie lub aptece, gdy nie działa e-Recepta (P1)?',
    ]) {
      assert.ok(warmCache.includes(prompt), `Brak pytania '${prompt}' w scripts/warm-ai-cache.sh`);
      assert.ok(vpsWidget.includes(prompt), `Brak pytania '${prompt}' w services/ai-router/src/widget.js`);
    }

    // Jeśli w workspace istnieje bliźniaczy szablon _site-template, zweryfikuj krzyżowo jego pliki
    const siteTemplateDir = path.join(ROOT_DIR, '..', '_site-template');
    if (fs.existsSync(siteTemplateDir)) {
      const siteWidget = fs.readFileSync(path.join(siteTemplateDir, 'assets', 'js', 'ai-widget.js'), 'utf-8');
      const siteAgents = fs.readFileSync(path.join(siteTemplateDir, 'AGENTS.md'), 'utf-8');
      const siteBlueprint = fs.readFileSync(path.join(siteTemplateDir, 'BLUEPRINT.md'), 'utf-8');

      assert.match(vpsWidget, /15-modelowej kaskady/);
      assert.match(siteWidget, /15-modelowej kaskady/);
      assert.match(siteWidget, /hasContactPii/);
      assert.match(siteAgents, /15-modelową kaskadę/);
      assert.match(siteBlueprint, /15-Modelowa Kaskada/);
    }
  });

  it('Asystent Ekspercki AMMS & Oracle DBA (Dual-Stream SQLite FTS5 RAG + Adaptive HIGH Reasoning + MS Teams UI) powinien być kompletnie skonfigurowany', () => {
    const ragPhp = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'amms-rag-search.php'), 'utf-8');
    const routerPhp = readRouterCombinedPhp();
    const teamsHtml = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'amms-teams.html'), 'utf-8');

    assert.match(ragPhp, /class AmmsRagSearch/);
    assert.match(ragPhp, /detectReasoningProfile/);
    assert.match(ragPhp, /searchKnowledge/);
    assert.match(ragPhp, /getPageDetails/);
    assert.match(ragPhp, /bm25\(chunks_fts/);

    assert.match(routerPhp, /amms-rag-search\.php/);
    assert.match(routerPhp, /\/amms-page/);
    assert.match(routerPhp, /\['sources'\]\s*=\s*\$ammsSources/);
    assert.match(routerPhp, /\['reasoning_tier'\]\s*=\s*\$ammsReasoningTier/);
    // Gwarancja izolacji modeli SQL (codestral-latest / cohere/north-mini-code:free) wyłącznie dla Asystenta AMMS ($isAmmsSite && $isAmmsDbQuery)
    assert.match(routerPhp, /\$isAmmsSite\s*&&\s*\$isAmmsDbQuery\s*&&\s*\$mistralApiKey\s*!==\s*''/);
    assert.match(routerPhp, /\$orModel\s*===\s*'cohere\/north-mini-code:free'\s*&&\s*!\(\$isAmmsSite\s*&&\s*\$isAmmsDbQuery\)/);

    assert.match(teamsHtml, /renderPageSnapshotDataUrl/);
    assert.match(teamsHtml, /openLightboxForSource/);
    assert.match(teamsHtml, /Poprzednia strona/);
    assert.match(teamsHtml, /Następna strona/);

    assert.ok(fs.existsSync(path.join(ROOT_DIR, 'scripts', 'open-amms-assistant.ps1')), 'Brak scripts/open-amms-assistant.ps1');
    assert.ok(fs.existsSync(path.join(ROOT_DIR, 'scripts', 'open-amms-assistant.cmd')), 'Brak scripts/open-amms-assistant.cmd');
  });

  it('4 nowe moduły Enterprise (Self-Hosted Ntfy, PrivateBin Zero-Knowledge Vault, Generator Audytów B2B Przed i Po, Radar Zmian Zewnętrznych) powinny być kompletnie skonfigurowane i przechodzić self-test', () => {
    // 1. Opcja 1: Self-Hosted Ntfy (RODO / ISO 27001)
    const ntfyCfgPath = path.join(ROOT_DIR, 'config', 'ntfy', 'server.yml');
    assert.ok(fs.existsSync(ntfyCfgPath), 'Brak config/ntfy/server.yml');
    const ntfyCfg = fs.readFileSync(ntfyCfgPath, 'utf-8');
    assert.match(ntfyCfg, /auth-default-access:\s*"deny-all"/);
    assert.match(ntfyCfg, /enable-signup:\s*false/);
    assert.match(ntfyCfg, /enable-metrics:\s*true/);
    assert.ok(fs.existsSync(path.join(ROOT_DIR, 'scripts', 'setup-selfhosted-ntfy.sh')), 'Brak scripts/setup-selfhosted-ntfy.sh');

    const leadPhp = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'lead-notifier.php'), 'utf-8');
    assert.match(leadPhp, /NTFY_BASE_URL/);
    assert.match(leadPhp, /NTFY_TOKEN/);

    // 2. Opcja 2: PrivateBin Zero-Knowledge Vault ("Burn After Reading")
    const pbinCfgPath = path.join(ROOT_DIR, 'config', 'privatebin', 'conf.php');
    assert.ok(fs.existsSync(pbinCfgPath), 'Brak config/privatebin/conf.php');
    const pbinCfg = fs.readFileSync(pbinCfgPath, 'utf-8');
    assert.match(pbinCfg, /burnafterreadingselected\s*=\s*true/);
    assert.match(pbinCfg, /discussion\s*=\s*false/);
    assert.match(pbinCfg, /fileupload\s*=\s*false/);
    assert.ok(fs.existsSync(path.join(ROOT_DIR, 'scripts', 'create-secret-link.ps1')), 'Brak scripts/create-secret-link.ps1');
    assert.ok(fs.existsSync(path.join(ROOT_DIR, 'scripts', 'create-secret-link.sh')), 'Brak scripts/create-secret-link.sh');

    // 3. Opcja 3: Generator Audytów Sprzedażowych B2B "Przed i Po"
    const auditGenJs = path.join(ROOT_DIR, 'scripts', 'generate-client-audit.js');
    assert.ok(fs.existsSync(auditGenJs), 'Brak scripts/generate-client-audit.js');
    assert.ok(fs.existsSync(path.join(ROOT_DIR, 'scripts', 'generate-client-audit.ps1')), 'Brak scripts/generate-client-audit.ps1');
    assert.ok(fs.existsSync(path.join(ROOT_DIR, 'scripts', 'generate-client-audit.sh')), 'Brak scripts/generate-client-audit.sh');
    const selfTestRes = spawnSync(process.execPath, [auditGenJs, '--self-test'], { encoding: 'utf-8' });
    assert.strictEqual(selfTestRes.status, 0, `generate-client-audit.js --self-test nie powiódł się: ${selfTestRes.stderr || selfTestRes.stdout}`);
    assert.match(selfTestRes.stdout, /SELF_TEST_OK/);

    // 4. Opcja 4: Radar Zmian na Stronach Zewnętrznych (Change Detection Radar + Endpoint Discovery)
    const radarTargetsPath = path.join(ROOT_DIR, 'config', 'change-radar', 'targets.json');
    assert.ok(fs.existsSync(radarTargetsPath), 'Brak config/change-radar/targets.json');
    const radarTargets = JSON.parse(fs.readFileSync(radarTargetsPath, 'utf-8'));
    assert.ok(Array.isArray(radarTargets.targets) && radarTargets.targets.length >= 6, 'Za mało zdefiniowanych celów w config/change-radar/targets.json');
    const watchPyPath = path.join(ROOT_DIR, 'scripts', 'watch-external-changes.py');
    const discoverPyPath = path.join(ROOT_DIR, 'scripts', 'discover-endpoints.py');
    assert.ok(fs.existsSync(watchPyPath), 'Brak scripts/watch-external-changes.py');
    assert.ok(fs.existsSync(discoverPyPath), 'Brak scripts/discover-endpoints.py');
    assert.ok(fs.existsSync(path.join(ROOT_DIR, 'scripts', 'sync-change-radar.sh')), 'Brak scripts/sync-change-radar.sh');
    const watchPyContent = fs.readFileSync(watchPyPath, 'utf-8');
    assert.match(watchPyContent, /__NEXT_DATA__/);
    assert.match(watchPyContent, /mode == "rss"/);
  });

  it('standardy Evergreen Web Standards Radar ([REF-02]..[REF-07]) powinny być wdrożone w plikach PHP, HTML, CSS, JS i skryptach (.sh / .githooks z końcami linii LF)', () => {
    // 1. Wszystkie skrypty .sh oraz .githooks/* muszą mieć końce linii LF (brak CRLF)
    const shDirs = [path.join(ROOT_DIR, 'scripts'), path.join(ROOT_DIR, '.githooks')];
    for (const dir of shDirs) {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const fullPath = path.join(dir, entry.name);
        if (entry.isFile() && (entry.name.endsWith('.sh') || dir.endsWith('.githooks'))) {
          const raw = fs.readFileSync(fullPath, 'utf-8');
          assert.strictEqual(raw.includes('\r\n'), false, `Wykryto CRLF w pliku powłoki: ${fullPath}`);
        }
      }
    }

    // 2. Wszystkie pliki .php w services/ai-router/src oraz config/privatebin muszą mieć declare(strict_types=1);
    const phpDirs = [path.join(ROOT_DIR, 'services', 'ai-router', 'src'), path.join(ROOT_DIR, 'config', 'privatebin')];
    for (const dir of phpDirs) {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        if (entry.isFile() && entry.name.endsWith('.php')) {
          const content = fs.readFileSync(path.join(dir, entry.name), 'utf-8');
          assert.match(content, /declare\(strict_types=1\);/, `Brak declare(strict_types=1); w ${entry.name}`);
        }
      }
    }

    // 3. Brak stylów inline (style="...") oraz atrybutów onclick="..." w plikach frontendu HTML i generatorze raportów
    for (const relHtml of [
      'services/ai-router/public-test/index.html',
      'services/ai-router/src/amms-teams.html',
      'scripts/client-audit-renderer.js',
    ]) {
      const content = fs.readFileSync(path.join(ROOT_DIR, relHtml), 'utf-8');
      assert.strictEqual(/\bstyle\s*=\s*["']/i.test(content), false, `Wykryto styl inline style="..." w ${relHtml}`);
      assert.strictEqual(/\bonclick\s*=\s*["']/i.test(content), false, `Wykryto handler inline onclick="..." w ${relHtml}`);
    }

    // 4. [REF-02], [REF-03], [REF-04], [REF-06], [REF-07] w public-test oraz amms-teams.html
    const publicIndexHtml = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'public-test', 'index.html'), 'utf-8');
    const publicStyleCss = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'public-test', 'style.css'), 'utf-8');
    const publicAppJs = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'public-test', 'app.js'), 'utf-8');
    const publicSecTxt = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'public-test', '.well-known', 'security.txt'), 'utf-8');

    assert.match(publicIndexHtml, /class="skip-link"/);
    assert.match(publicIndexHtml, /type="speculationrules"/);
    assert.match(publicIndexHtml, /href="\/llms\.txt"/);
    assert.match(publicStyleCss, /scrollbar-gutter:\s*stable/);
    assert.match(publicStyleCss, /text-wrap:\s*balance/);
    assert.match(publicStyleCss, /text-wrap:\s*pretty/);
    assert.match(publicStyleCss, /@view-transition/);
    assert.match(publicAppJs, /AbortController/);
    assert.match(publicSecTxt, /Expires:\s*2027-12-31T23:59:59\.000Z/);
  });

  it('powinien posiadać wdrożone usprawnienia z researchu UnknowNews (WebMCP w widget.js, pii-guard.php w chat-router.php, CSP + escapeHtml + Decision Model w amms-teams.html oraz benchmarki Moz/Nolan Lawson)', () => {
    const widgetJs = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'widget.js'), 'utf-8');
    assert.match(widgetJs, /function isValidPesel\(/);
    assert.match(widgetJs, /function maskSensitivePlPii\(/);
    assert.match(widgetJs, /function registerWebMcpTools\(/);
    assert.match(widgetJs, /ask_site_assistant/);
    assert.match(widgetJs, /readOnlyHint:\s*true/);
    assert.match(widgetJs, /question:\s*maskSensitivePlPii\(trimmed\)/);

    const piiGuardPhp = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'pii-guard.php'), 'utf-8');
    for (const fnName of [
      'is_valid_pesel',
      'is_valid_nip',
      'is_valid_regon',
      'is_valid_pl_id',
      'mask_sensitive_pl_pii',
      'pseudonymize_entity_hmac',
      'restore_stream_chunk',
      'flush_stream_restorer',
    ]) {
      assert.match(piiGuardPhp, new RegExp(`function\\s+${fnName}\\s*\\(`), `Brak funkcji ${fnName} w pii-guard.php`);
    }

    const chatRouterPhp = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'chat-router.php'), 'utf-8');
    assert.match(chatRouterPhp, /require_once __DIR__ \. '\/pii-guard\.php';/);
    assert.match(chatRouterPhp, /mask_sensitive_pl_pii\(/);
    assert.match(chatRouterPhp, /iframe\\b\[\^>\]\*\\bsrcdoc\\s\*=/);
    assert.match(chatRouterPhp, /mathlive#virtual-keyboard-message/);

    const routerEndpointsPhp = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'router-endpoints.php'), 'utf-8');
    assert.match(
      routerEndpointsPhp,
      /Content-Security-Policy:\s*frame-ancestors 'none'; script-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'none'/
    );

    const ammsTeamsHtml = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'amms-teams.html'), 'utf-8');
    assert.match(ammsTeamsHtml, /function escapeHtml\(/);
    assert.match(ammsTeamsHtml, /escapeHtml\(src\.source_file/);
    assert.match(ammsTeamsHtml, /escapeHtml\(src\.section_title/);
    assert.match(ammsTeamsHtml, /escapeHtml\(src\.badge_label/);
    assert.match(ammsTeamsHtml, /escapeHtml\(src\.citation/);
    assert.match(ammsTeamsHtml, /escapeHtml\(data\.error/);
    assert.match(ammsTeamsHtml, /msg-decision-badge/);
    assert.match(ammsTeamsHtml, /Decision Model/);

    const clientAuditJs = fs.readFileSync(path.join(ROOT_DIR, 'scripts', 'generate-client-audit.js'), 'utf-8');
    const knowledgeTxt = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'data', 'twojastronawww-knowledge.txt'), 'utf-8');
    const agentsMd = fs.readFileSync(path.join(ROOT_DIR, 'AGENTS.md'), 'utf-8');
    const radarMd = fs.readFileSync(path.join(ROOT_DIR, 'docs', 'WEB_STANDARDS_RADAR.md'), 'utf-8');

    assert.match(clientAuditJs, /63,8%/);
    assert.match(clientAuditJs, /72,7%/);
    assert.match(clientAuditJs, /142 KiB/);
    assert.match(clientAuditJs, /2 090 ms/);
    assert.match(knowledgeTxt, /63,8%/);
    assert.match(knowledgeTxt, /72,7%/);
    assert.match(knowledgeTxt, /142 KiB/);
    assert.match(knowledgeTxt, /2 090 ms/);
    assert.match(agentsMd, /document\.modelContext/);
    assert.match(radarMd, /document\.modelContext/);
  });
});



