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
});
