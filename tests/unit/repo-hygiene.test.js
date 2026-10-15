import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
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
      '.github/pull_request_template.md',
      '.github/dependabot.yml',
      '.github/workflows/lint-compose.yml',
      '.github/workflows/deploy.yml',
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
  });

  it('moduł services/ai-router powinien posiadać kompletną strukturę (Dockerfile, kod PHP, RAG, tester)', () => {
    const requiredRouterFiles = [
      path.join(ROOT_DIR, 'services', 'ai-router', 'Dockerfile'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'chat-router.php'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'widget.js'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'data', 'katosalsahub-knowledge.txt'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'data', 'fuegolingua-knowledge.txt'),
      path.join(ROOT_DIR, 'services', 'ai-router', 'data', 'twojastronawww-knowledge.txt'),
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

  it('skrypt chat-router.php powinien realizować wymogi bezpieczeństwa, pamięci konwersacji i kaskadowego fallbacku modeli (ISO 27001)', () => {
    const routerPhp = path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'chat-router.php');
    const content = fs.readFileSync(routerPhp, 'utf-8');

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

  it('docker-compose.yml powinien zawierać zdefiniowany serwis ai-router oraz wolumen ai_router_storage', () => {
    const composePath = path.join(ROOT_DIR, 'compose', 'docker-compose.yml');
    const content = fs.readFileSync(composePath, 'utf-8');

    assert.match(content, /ai-router:/);
    assert.match(content, /ai_router_storage:/);
    assert.match(content, /127\.0\.0\.1:8085:8080/);
    assert.match(content, /data:\/app\/data:ro/);
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
  });

  it('wszystkie pliki Docker Compose powinny definiować czytelne etykiety dev.dozzle.name dla kontenerów', () => {
    const composeMain = fs.readFileSync(path.join(ROOT_DIR, 'compose', 'docker-compose.yml'), 'utf-8');
    const composeExt = fs.readFileSync(path.join(ROOT_DIR, 'compose', 'extensions.yml'), 'utf-8');
    const composeRunners = fs.readFileSync(path.join(ROOT_DIR, 'compose', 'runners.yml'), 'utf-8');

    assert.match(composeMain, /dev\.dozzle\.name:\s*"uptime-kuma • Monitoring Stron WWW"/);
    assert.match(composeMain, /dev\.dozzle\.name:\s*"prometheus • Baza Metryk TSDB"/);
    assert.match(composeMain, /dev\.dozzle\.name:\s*"grafana • Dashboardy i Wykresy"/);
    assert.match(composeMain, /dev\.dozzle\.name:\s*"ai-router • Czatbot AI & Gemini"/);
    assert.match(composeExt, /dev\.dozzle\.name:\s*"cloudflared • Tunel Zero Trust"/);
    assert.match(composeRunners, /dev\.dozzle\.name:\s*"runner-twojastronawww • CI\/CD TwojaStronaWWW"/);
    assert.match(composeRunners, /dev\.dozzle\.name:\s*"runner-zeslownikiem • CI\/CD ZeSłownikiem"/);
  });

  it('skrypt setup-kuma.js powinien być idempotentny (usuwać duplikaty) i posiadać poprawny URL DancePuls', () => {
    const kumaScript = fs.readFileSync(path.join(ROOT_DIR, 'scripts', 'setup-kuma.js'), 'utf-8');
    assert.match(kumaScript, /https:\/\/dancepuls\.katosalsahub\.pl\//);
    assert.strictEqual(kumaScript.includes('https://dancepuls.pl"'), false, 'Wykryto stary, niedziałający URL https://dancepuls.pl');
    assert.match(kumaScript, /deleteMonitor/);
    assert.match(kumaScript, /monitorList/);
  });

  it('telemetria AI Routera (ai-stats.php) nie powinna logować treści pytań, IP ani kluczy API (ISO 27001)', () => {
    const statsPath = path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'ai-stats.php');
    assert.ok(fs.existsSync(statsPath), 'Brak services/ai-router/src/ai-stats.php');
    const stats = fs.readFileSync(statsPath, 'utf-8');
    assert.strictEqual(stats.includes('AIzaSy'), false, 'Klucz API w ai-stats.php');
    assert.strictEqual(/REMOTE_ADDR|CF_CONNECTING_IP|X_FORWARDED_FOR/.test(stats), false, 'ai-stats.php nie może operować na adresach IP');
    assert.match(stats, /function aiRenderMetrics/);
    assert.match(stats, /function aiCooldownRemaining/);

    const router = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'chat-router.php'), 'utf-8');
    assert.match(router, /require_once __DIR__ \. '\/ai-stats\.php'/);
    assert.match(router, /register_shutdown_function/);
    // Do logów trafiają tylko metadane - nigdy $question/$knowledgeContent/$geminiApiKey
    assert.strictEqual(/aiLog\([^;]*\$(question|knowledgeContent|geminiApiKey|groqApiKey|openRouterApiKey)/.test(router), false);
  });

  it('dashboard AI Router w Grafanie powinien być poprawnym JSON-em z unikalnymi ID paneli i metrykami kaskady', () => {
    const dashPath = path.join(ROOT_DIR, 'config', 'grafana', 'provisioning', 'dashboards', 'definitions', 'ai-router-overview.json');
    const dash = JSON.parse(fs.readFileSync(dashPath, 'utf-8'));
    const ids = dash.panels.map((p) => p.id);
    assert.strictEqual(new Set(ids).size, ids.length, 'Zduplikowane ID paneli w dashboardzie ai-router-overview');
    const exprs = JSON.stringify(dash.panels);
    for (const metric of ['ai_router_model_suspended', 'ai_router_model_requests_today', 'ai_router_answers_by_depth_total', 'ai_router_model_attempts_total']) {
      assert.ok(exprs.includes(metric), `Dashboard nie wizualizuje metryki ${metric}`);
    }
  });

  it('reguły alertów Prometheusa dla AI Routera powinny być zamontowane i wczytywane', () => {
    const rules = path.join(ROOT_DIR, 'config', 'prometheus', 'rules', 'ai-router.yml');
    assert.ok(fs.existsSync(rules), 'Brak config/prometheus/rules/ai-router.yml');
    const rulesContent = fs.readFileSync(rules, 'utf-8');
    for (const alertName of ['AIRouterDown', 'AIRouterAllModelsFailed', 'AIRouterPrimaryModelSuspended', 'AIRouterModelQuotaNearLimit']) {
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

  it('narzędzia raportowe AI Routera (ai-router-report.sh/.ps1) powinny istnieć', () => {
    const sh = path.join(ROOT_DIR, 'scripts', 'ai-router-report.sh');
    const ps1 = path.join(ROOT_DIR, 'scripts', 'ai-router-report.ps1');
    assert.ok(fs.existsSync(sh), 'Brak scripts/ai-router-report.sh');
    assert.ok(fs.existsSync(ps1), 'Brak scripts/ai-router-report.ps1');
    assert.match(fs.readFileSync(sh, 'utf-8').split(/\r?\n/)[0], /^#!\/(usr\/bin\/env bash|bin\/bash)\s*$/);
  });

  it('utwardzenia bezpieczeństwa (Grafana PoLP Viewer, FTPS TLS, szyfrowanie AES-256 backupów, GC rate-limit, .env.bak*) powinny być aktywne', () => {
    const gitignore = fs.readFileSync(path.join(ROOT_DIR, '.gitignore'), 'utf-8');
    assert.match(gitignore, /\.env\.bak\*/);

    const compose = fs.readFileSync(path.join(ROOT_DIR, 'compose', 'docker-compose.yml'), 'utf-8');
    assert.match(compose, /GF_AUTH_ANONYMOUS_ORG_ROLE=\$\{GF_AUTH_ANONYMOUS_ORG_ROLE:-Viewer\}/);

    const lhBackup = fs.readFileSync(path.join(ROOT_DIR, 'scripts', 'backup-websites-lh.sh'), 'utf-8');
    assert.strictEqual(lhBackup.includes('set ftp:ssl-allow no'), false, 'Skrypt backup-websites-lh.sh nie może wymuszać nieszyfrowanego FTP');
    assert.match(lhBackup, /set ftp:ssl-protect-data true/);
    assert.match(lhBackup, /openssl enc -aes-256-cbc -pbkdf2/);

    const offsiteBackup = fs.readFileSync(path.join(ROOT_DIR, 'scripts', 'backup-offsite.sh'), 'utf-8');
    assert.match(offsiteBackup, /openssl enc -aes-256-cbc -pbkdf2/);
    assert.match(offsiteBackup, /runner_gal_anonim_web_data/);

    const routerPhp = fs.readFileSync(path.join(ROOT_DIR, 'services', 'ai-router', 'src', 'chat-router.php'), 'utf-8');
    assert.match(routerPhp, /filemtime\(\$oldRateFile\)/);
  });
});

