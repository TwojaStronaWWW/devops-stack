import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.join(__dirname, '..', '..');
const ROUTER_SRC_DIR = path.join(ROOT_DIR, 'services', 'ai-router', 'src');
const ROUTER_STORAGE_DIR = path.join(ROOT_DIR, 'services', 'ai-router', 'storage');

function hasPhpCli() {
  const res = spawnSync('php', ['-v'], { stdio: 'ignore' });
  return res.status === 0;
}

function getFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, '127.0.0.1', () => {
      const addr = srv.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
      srv.close((err) => (err ? reject(err) : resolve(port)));
    });
    srv.on('error', reject);
  });
}

async function waitForServer(baseUrl, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${baseUrl}/health`);
      if (res.ok) return;
    } catch {
      // serwer jeszcze startuje
    }
    await new Promise((r) => setTimeout(r, 80));
  }
  throw new Error(`Lokalny serwer PHP nie wystartował w ciągu ${timeoutMs}ms`);
}

describe('Defensywne testy regresji bezpieczeństwa (OWASP / ISO 27001 / Zero Trust)', () => {
  describe('Statyczna weryfikacja utwardzenia infrastruktury (Zero Trust & OS Hardening)', () => {
    it('żaden plik Docker Compose nie może wystawiać portów na 0.0.0.0 (wymagany bindowany localhost 127.0.0.1)', () => {
      const composeFiles = ['docker-compose.yml', 'extensions.yml', 'runners.yml'];
      for (const file of composeFiles) {
        const content = fs.readFileSync(path.join(ROOT_DIR, 'compose', file), 'utf-8');
        const portLines = [...content.matchAll(/^\s*-\s*["']?(\d[\d.:]+:\d+)["']?\s*$/gm)].map((m) => m[1]);
        for (const mapping of portLines) {
          assert.ok(
            mapping.startsWith('127.0.0.1:'),
            `Wykryto niebezpieczne mapowanie portu bez 127.0.0.1 w compose/${file}: ${mapping}`
          );
        }
      }
    });

    it('wszystkie kontenery w docker-compose.yml, extensions.yml i runners.yml powinny wymuszać no-new-privileges:true oraz limity pamięci RAM', () => {
      const mainCompose = fs.readFileSync(path.join(ROOT_DIR, 'compose', 'docker-compose.yml'), 'utf-8');
      const noNewPrivCount = (mainCompose.match(/no-new-privileges:true/g) || []).length;
      const memLimitCount = (mainCompose.match(/memory:\s*\d+[MG]/g) || []).length;

      // W docker-compose.yml jest 8 usług (uptime-kuma, prometheus, grafana, node-exporter, cadvisor, dozzle, github-exporter, ai-router)
      assert.ok(noNewPrivCount >= 8, `Zbyt mało deklaracji no-new-privileges:true w docker-compose.yml (${noNewPrivCount} < 8)`);
      assert.ok(memLimitCount >= 8, `Brak limitów pamięci RAM dla wszystkich kontenerów w docker-compose.yml (${memLimitCount} < 8)`);

      const runnersCompose = fs.readFileSync(path.join(ROOT_DIR, 'compose', 'runners.yml'), 'utf-8');
      const runnersNoNewPriv = (runnersCompose.match(/no-new-privileges:true/g) || []).length;
      assert.ok(runnersNoNewPriv >= 4, `Brak deklaracji no-new-privileges:true dla wszystkich runnerów w compose/runners.yml (${runnersNoNewPriv} < 4)`);
    });

    it('skrypt 01-harden-os.sh powinien wymuszać twardą politykę SSH, UFW, Fail2ban, wyłączenie rpcbind oraz ochronę jądra (sysctl / noexec)', () => {
      const hardenScript = fs.readFileSync(path.join(ROOT_DIR, 'scripts', '01-harden-os.sh'), 'utf-8');
      assert.match(hardenScript, /^PermitRootLogin no$/m);
      assert.match(hardenScript, /^PasswordAuthentication no$/m);
      assert.match(hardenScript, /^AuthenticationMethods publickey$/m);
      assert.match(hardenScript, /ufw default deny incoming/);
      assert.match(hardenScript, /ufw limit 22\/tcp/);
      assert.match(hardenScript, /systemctl mask rpcbind\.service rpcbind\.socket/);
      assert.match(hardenScript, /net\.ipv4\.tcp_syncookies\s*=\s*1/);
      assert.match(hardenScript, /net\.ipv4\.conf\.all\.rp_filter\s*=\s*1/);
      assert.match(hardenScript, /noexec,nosuid,nodev/);
    });

    it('składnia PHP w plikach źródłowych AI Routera powinna być wolna od błędów (php -l)', { skip: !hasPhpCli() }, () => {
      for (const phpFile of ['chat-router.php', 'ai-stats.php']) {
        const res = spawnSync('php', ['-l', path.join(ROUTER_SRC_DIR, phpFile)], { encoding: 'utf-8' });
        assert.strictEqual(res.status, 0, `Błąd składni PHP w ${phpFile}: ${res.stderr || res.stdout}`);
      }
    });
  });

  describe('Dynamiczne testy odporności API AI Routera (CORS, Path Traversal, Rate Limit, Zero-PII)', { skip: !hasPhpCli() }, () => {
    let phpProc = null;
    let baseUrl = '';
    const createdRateFiles = new Set();
    let statsExistedBefore = false;
    let statsBackup = null;
    const statsFilePath = path.join(ROUTER_STORAGE_DIR, 'metrics', 'stats.json');

    function trackIpRateFile(ip) {
      const hash = crypto.createHash('sha256').update(ip).digest('hex');
      createdRateFiles.add(path.join(ROUTER_STORAGE_DIR, 'rate_limits', `${hash}.json`));
    }

    function cleanAllRateLimitFiles() {
      const dirs = [
        path.join(ROUTER_STORAGE_DIR, 'rate_limits'),
        path.resolve('/app/storage/rate_limits'),
      ];
      for (const dir of dirs) {
        if (fs.existsSync(dir)) {
          for (const f of fs.readdirSync(dir)) {
            if (f.endsWith('.json')) {
              try {
                fs.unlinkSync(path.join(dir, f));
              } catch {
                // ignoruj
              }
            }
          }
        }
      }
    }

    before(async () => {
      cleanAllRateLimitFiles();
      if (fs.existsSync(statsFilePath)) {
        statsExistedBefore = true;
        statsBackup = fs.readFileSync(statsFilePath);
      }

      const port = await getFreePort();
      baseUrl = `http://127.0.0.1:${port}`;
      phpProc = spawn('php', ['-S', `127.0.0.1:${port}`, '-t', ROUTER_SRC_DIR, path.join(ROUTER_SRC_DIR, 'chat-router.php')], {
        env: {
          ...process.env,
          GEMINI_API_KEY: '',
          GROQ_API_KEY: '',
          OPENROUTER_API_KEY: '',
          ALLOWED_ORIGINS: 'https://twojastronawww.pl,https://katosalsahub.pl,https://fuegolingua.pl',
        },
        stdio: 'ignore',
      });

      await waitForServer(baseUrl);
    });

    after(async () => {
      if (phpProc) {
        phpProc.kill();
        await new Promise((r) => setTimeout(r, 150));
      }
      cleanAllRateLimitFiles();
      for (const f of createdRateFiles) {
        if (fs.existsSync(f)) {
          try {
            fs.unlinkSync(f);
          } catch {
            // ignoruj błędy sprzątania
          }
        }
      }
      if (statsExistedBefore && statsBackup !== null) {
        fs.writeFileSync(statsFilePath, statsBackup);
      } else if (!statsExistedBefore && fs.existsSync(statsFilePath)) {
        try {
          fs.unlinkSync(statsFilePath);
        } catch {
          // ignoruj
        }
      }
    });

    it('endpoint /health powinien zwracać nagłówki bezpieczeństwa X-Content-Type-Options: nosniff, X-Frame-Options: DENY i ukrywać X-Powered-By', async () => {
      const res = await fetch(`${baseUrl}/health`);
      assert.strictEqual(res.status, 200);
      assert.strictEqual(res.headers.get('x-content-type-options'), 'nosniff');
      assert.strictEqual(res.headers.get('x-frame-options'), 'DENY');
      assert.strictEqual(res.headers.get('x-powered-by'), null);
      const body = await res.json();
      assert.strictEqual(body.status, 'UP');
    });

    it('powinien blokować żądania z nieautoryzowanych domen oraz fałszowanie Origin: http://localhost przez Cloudflare (HTTP 403)', async () => {
      const res = await fetch(`${baseUrl}/chat-router.php`, {
        method: 'POST',
        headers: {
          Origin: 'https://evil-phishing-site.example.com',
          'Content-Type': 'application/json',
          'CF-Connecting-IP': '198.51.100.10',
        },
        body: JSON.stringify({ site_id: 'twojastronawww', question: 'Test CORS' }),
      });
      trackIpRateFile('198.51.100.10');

      assert.strictEqual(res.status, 403);
      assert.strictEqual(res.headers.get('access-control-allow-origin'), null);
      const data = await res.json();
      assert.strictEqual(data.success, false);
      assert.match(data.error, /CORS Forbidden/);

      // Próba obejścia CORS z internetu przez podanie Origin: http://localhost przy obecnym CF-Connecting-IP
      const spoofRes = await fetch(`${baseUrl}/chat-router.php`, {
        method: 'POST',
        headers: {
          Origin: 'http://localhost:3000',
          'Content-Type': 'application/json',
          'CF-Connecting-IP': '198.51.100.12',
        },
        body: JSON.stringify({ site_id: 'twojastronawww', question: 'Test spoofing localhost' }),
      });
      trackIpRateFile('198.51.100.12');
      assert.strictEqual(spoofRes.status, 403);
    });

    it('powinien akceptować preflight OPTIONS z autoryzowanej domeny na białej liście CORS (HTTP 204)', async () => {
      const res = await fetch(`${baseUrl}/chat-router.php`, {
        method: 'OPTIONS',
        headers: {
          Origin: 'https://twojastronawww.pl',
          'Access-Control-Request-Method': 'POST',
        },
      });

      assert.strictEqual(res.status, 204);
      assert.strictEqual(res.headers.get('access-control-allow-origin'), 'https://twojastronawww.pl');
    });

    it('powinien odrzucać niebezpieczne lub nieprawidłowe metody HTTP (GET, PUT, DELETE -> HTTP 405)', async () => {
      for (const method of ['GET', 'PUT', 'DELETE']) {
        const res = await fetch(`${baseUrl}/chat-router.php`, {
          method,
          headers: { 'CF-Connecting-IP': '198.51.100.11' },
        });
        trackIpRateFile('198.51.100.11');
        assert.strictEqual(res.status, 405, `Metoda ${method} powinna zwrócić 405`);
      }
    });

    it('powinien blokować próby ataków Path Traversal, LFI, Command Injection oraz XSS w parametrze site_id (HTTP 400)', async () => {
      const maliciousSiteIds = [
        '../../etc/passwd',
        '..\\..\\Windows\\win.ini',
        'twojastronawww/../../.env',
        'site;id;uname -a',
        '<script>alert(1)</script>',
        'a', // za krótki (<2 znaków)
        'x'.repeat(40), // za długi (>32 znaków)
      ];

      let ipOctet = 20;
      for (const payloadSiteId of maliciousSiteIds) {
        const ip = `198.51.100.${ipOctet++}`;
        trackIpRateFile(ip);
        const res = await fetch(`${baseUrl}/chat-router.php`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'CF-Connecting-IP': ip,
          },
          body: JSON.stringify({ site_id: payloadSiteId, question: 'Ile kosztuje strona?' }),
        });

        assert.strictEqual(res.status, 400, `Payload site_id="${payloadSiteId}" powinien zostać odrzucony kodem 400`);
        const body = await res.json();
        assert.strictEqual(body.success, false);
        assert.match(body.error, /site_id/);
      }
    });

    it('powinien odrzucać uszkodzony JSON, puste ciało oraz pytania przekraczające limit 2000 znaków (HTTP 400)', async () => {
      const ip = '198.51.100.50';
      trackIpRateFile(ip);

      // 1. Uszkodzony JSON
      const badJsonRes = await fetch(`${baseUrl}/chat-router.php`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': ip },
        body: '{invalid_json:',
      });
      assert.strictEqual(badJsonRes.status, 400);

      // 2. Pytanie za krótkie (1 znak)
      const shortRes = await fetch(`${baseUrl}/chat-router.php`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': ip },
        body: JSON.stringify({ site_id: 'twojastronawww', question: 'a' }),
      });
      assert.strictEqual(shortRes.status, 400);

      // 3. Pytanie za długie (>2000 znaków - ochrona przed Token Exhaustion)
      const longRes = await fetch(`${baseUrl}/chat-router.php`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': ip },
        body: JSON.stringify({ site_id: 'twojastronawww', question: 'A'.repeat(2050) }),
      });
      assert.strictEqual(longRes.status, 400);
    });

    it('powinien zwracać 404 dla nieistniejącej bazy wiedzy bez ujawniania ścieżek systemu plików', async () => {
      const ip = '198.51.100.60';
      trackIpRateFile(ip);
      const res = await fetch(`${baseUrl}/chat-router.php`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': ip },
        body: JSON.stringify({ site_id: 'nieistniejaca_witryna', question: 'Test izolacji RAG' }),
      });

      assert.strictEqual(res.status, 404);
      const body = await res.json();
      assert.strictEqual(body.success, false);
      // Upewniamy się, że odpowiedź nie zdradza ścieżek serwera (/app/data ani E:\Projekty)
      assert.strictEqual(body.error.includes('/app/'), false);
      assert.strictEqual(body.error.toLowerCase().includes('projekty'), false);
    });

    it('powinien egzekwować IP Rate Limiting (max 5 zapytań/min per IP -> 6. zapytanie zwraca HTTP 429 z Retry-After)', async () => {
      const floodIp = '203.0.113.199';
      trackIpRateFile(floodIp);

      for (let i = 1; i <= 5; i++) {
        const res = await fetch(`${baseUrl}/chat-router.php`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': floodIp },
          body: JSON.stringify({ site_id: 'nieistniejaca_witryna', question: `Pytanie testowe nr ${i}` }),
        });
        assert.strictEqual(res.status, 404, `Zapytanie #${i} powinno przejść przez limiter (status 404 z braku bazy)`);
      }

      // 6. zapytanie z tego samego IP w tym samym oknie 60s musi zostać zablokowane przez Rate Limiter
      const blockedRes = await fetch(`${baseUrl}/chat-router.php`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': floodIp },
        body: JSON.stringify({ site_id: 'twojastronawww', question: 'Szóste zapytanie ponad limit' }),
      });

      assert.strictEqual(blockedRes.status, 429);
      assert.ok(blockedRes.headers.get('retry-after'), 'Brak nagłówka Retry-After przy odpowiedzi 429');
      const blockedBody = await blockedRes.json();
      assert.strictEqual(blockedBody.success, false);
      assert.ok(Number(blockedBody.retry_after) >= 1);
    });

    it('endpoint /metrics powinien zachowywać rygor Zero-PII (brak adresów IP, treści pytań i niezwalidowanych site_id)', async () => {
      const secretMarkerQuestion = 'TAJNE_HASLO_KLIENTA_998877';
      const ip = '198.51.100.88';
      trackIpRateFile(ip);

      await fetch(`${baseUrl}/chat-router.php`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': ip },
        body: JSON.stringify({ site_id: '../../etc/passwd', question: secretMarkerQuestion }),
      });

      const metricsRes = await fetch(`${baseUrl}/metrics`);
      assert.strictEqual(metricsRes.status, 200);
      assert.strictEqual(metricsRes.headers.get('x-content-type-options'), 'nosniff');
      const metricsText = await metricsRes.text();

      assert.match(metricsText, /ai_router_status 1/);
      assert.strictEqual(metricsText.includes(secretMarkerQuestion), false, 'Wyciek treści pytania do /metrics!');
      assert.strictEqual(metricsText.includes(ip), false, 'Wyciek adresu IP klienta do /metrics!');
      assert.strictEqual(metricsText.includes('203.0.113.199'), false, 'Wyciek adresu IP z rate-limitera do /metrics!');
      assert.strictEqual(metricsText.includes('/etc/passwd'), false, 'Wyciek niezwalidowanego site_id do etykiet /metrics!');

      // Publiczny dostęp z internetu przez Cloudflare Tunnel do /metrics musi być zablokowany (HTTP 403)
      const wanMetricsRes = await fetch(`${baseUrl}/metrics`, {
        headers: { 'CF-Connecting-IP': '198.51.100.99' },
      });
      assert.strictEqual(wanMetricsRes.status, 403);
    });
  });
});
