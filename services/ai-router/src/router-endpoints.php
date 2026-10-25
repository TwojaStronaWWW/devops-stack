<?php
declare(strict_types=1);

/**
 * AI Router Endpoints & Client IP Utilities — TwojaStronaWWW DevOps Stack
 *
 * Moduł obsługujący endpointy pomocnicze GET (/widget.js, /ai-widget.js, /radar-data, /radar,
 * /amms, /docs-pdf/*, /amms-page, /metrics, /health), bezciasteczkową analitykę ruchu WWW
 * POST (/analytics, /collect) oraz identyfikację i blokowanie IP (Penalty Box).
 */

/**
 * Wczytuje zmienne środowiskowe z pliku .env (bez nadpisywania już ustawionych zmiennych)
 */
function load_env(string $envPath): int {
    if (!file_exists($envPath) || !is_readable($envPath)) {
        return 0;
    }
    $loaded = 0;
    $lines = file($envPath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
    foreach ($lines as $line) {
        $line = trim($line);
        if ($line === '' || str_starts_with($line, '#') || !str_contains($line, '=')) {
            continue;
        }
        [$k, $v] = explode('=', $line, 2);
        $k = trim($k);
        $v = trim($v, " \t\n\r\0\x0B\"'");
        if ($k !== '' && !getenv($k)) {
            putenv("{$k}={$v}");
            $_ENV[$k] = $v;
            $loaded++;
        }
    }
    return $loaded;
}

/**
 * Pobiera rzeczywisty adres IP klienta z uwzględnieniem Cloudflare Tunnel
 */
function getClientIp(): string {
    // Priorytet dla Cloudflare Tunnel
    if (!empty($_SERVER['HTTP_CF_CONNECTING_IP'])) {
        $ip = trim($_SERVER['HTTP_CF_CONNECTING_IP']);
        if (filter_var($ip, FILTER_VALIDATE_IP)) {
            return $ip;
        }
    }

    // Fallback dla standardowych proxy
    if (!empty($_SERVER['HTTP_X_FORWARDED_FOR'])) {
        $ips = explode(',', $_SERVER['HTTP_X_FORWARDED_FOR']);
        $candidate = trim($ips[0]);
        if (filter_var($candidate, FILTER_VALIDATE_IP)) {
            return $candidate;
        }
    }

    return filter_var($_SERVER['REMOTE_ADDR'] ?? '127.0.0.1', FILTER_VALIDATE_IP) ?: '127.0.0.1';
}

/**
 * Nakłada tymczasową blokadę (Penalty Box) na adres IP agresora w pliku rate-limit
 */
function banClientIp(string $rateFile, int $seconds, string $reason): void {
    $fp = @fopen($rateFile, 'c+');
    if ($fp && flock($fp, LOCK_EX)) {
        $content = stream_get_contents($fp);
        $data = $content ? json_decode($content, true) : [];
        if (!is_array($data)) {
            $data = [];
        }
        $data['blocked_until'] = time() + $seconds;
        $data['ban_reason'] = $reason;
        ftruncate($fp, 0);
        rewind($fp);
        fwrite($fp, json_encode($data));
        fflush($fp);
        flock($fp, LOCK_UN);
    }
    if ($fp) {
        fclose($fp);
    }
}

/**
 * Obsługuje wczesne endpointy GET (/widget.js, /radar-data, /radar, /amms, /docs-pdf/*, /amms-page, /metrics, /health)
 */
function aiHandleEarlyGetEndpoints(string $requestUri, bool $isFromCloudflare): void {
    // Serwowanie uniwersalnego widgetu JS (Single Source of Truth v4.0: /widget.js UMD oraz /ai-widget.js ESM)
    if ($requestUri === '/widget.js' || $requestUri === '/ai-widget.js') {
        header('Content-Type: application/javascript; charset=UTF-8');
        header('X-Content-Type-Options: nosniff');
        header('Access-Control-Allow-Origin: *');
        header('Cache-Control: public, max-age=3600');
        $widgetPath = __DIR__ . '/widget.js';
        if (file_exists($widgetPath)) {
            readfile($widgetPath);
            if ($requestUri === '/ai-widget.js') {
                echo "\nexport const QUICK_PROMPTS_MAP = globalThis.QUICK_PROMPTS_MAP;\n";
                echo "export const THEME_PRESETS = globalThis.THEME_PRESETS;\n";
                echo "export const normalizeCacheQuery = globalThis.normalizeCacheQuery;\n";
                echo "export const normalizeSearchText = globalThis.normalizeSearchText;\n";
                echo "export const computeKnowledgeVersion = globalThis.computeKnowledgeVersion;\n";
                echo "export const searchKnowledgeEntries = globalThis.searchKnowledgeEntries;\n";
                echo "export const buildDynamicContext = globalThis.buildDynamicContext;\n";
                echo "export const formatMarkdown = globalThis.formatMarkdown;\n";
                echo "export const getLocalFallbackAnswer = globalThis.getLocalFallbackAnswer;\n";
                echo "export const initAiWidget = globalThis.initAiWidget;\n";
            }
        } else {
            http_response_code(404);
            echo '/* widget.js not found */';
        }
        exit;
    }

    // Serwowanie telemetrii JSON dla Radaru P1 (GET /radar-data) oraz panelu HTML (GET /radar | /p1-radar)
    if ($requestUri === '/radar-data') {
        header('Content-Type: application/json; charset=UTF-8');
        header('X-Content-Type-Options: nosniff');
        header('X-Frame-Options: DENY');
        header('X-Robots-Tag: noindex, nofollow, noarchive');
        header('Cache-Control: no-store, no-cache, must-revalidate');
        $reqMethod = $_SERVER['REQUEST_METHOD'] ?? 'GET';
        if ($reqMethod !== 'GET' && $reqMethod !== 'HEAD') {
            http_response_code(405);
            echo json_encode(['success' => false, 'error' => 'Method Not Allowed'], JSON_UNESCAPED_UNICODE);
            exit;
        }
        $radarCandidates = [
            '/app/storage/p1_radar.json',
            dirname(__DIR__) . '/storage/p1_radar.json',
        ];
        $radarJsonPath = '';
        foreach ($radarCandidates as $candidate) {
            if (is_file($candidate) && is_readable($candidate)) {
                $radarJsonPath = $candidate;
                break;
            }
        }
        if ($radarJsonPath === '') {
            http_response_code(503);
            echo json_encode(['success' => false, 'error' => 'Telemetria P1 jest w trakcie inicjalizacji.'], JSON_UNESCAPED_UNICODE);
            exit;
        }
        $rawRadar = @file_get_contents($radarJsonPath);
        $decodedRadar = $rawRadar ? json_decode($rawRadar, true) : null;
        if (!is_array($decodedRadar)) {
            http_response_code(503);
            echo json_encode(['success' => false, 'error' => 'Trwa odświeżanie pliku telemetrii P1.'], JSON_UNESCAPED_UNICODE);
            exit;
        }
        http_response_code(200);
        echo json_encode([
            'success' => true,
            'data'    => $decodedRadar,
        ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        exit;
    }

    if ($requestUri === '/radar' || $requestUri === '/p1-radar' || $requestUri === '/p1-radar.html') {
        header('Content-Type: text/html; charset=UTF-8');
        header('X-Content-Type-Options: nosniff');
        header('X-Frame-Options: DENY');
        header('X-Robots-Tag: noindex, nofollow');
        $radarHtmlPath = __DIR__ . '/p1-radar.html';
        if (is_file($radarHtmlPath)) {
            readfile($radarHtmlPath);
        } else {
            header('Location: https://radar-p1.pages.dev/', true, 302);
        }
        exit;
    }

    // Serwowanie interfejsu Asystenta AMMS w stylu Microsoft Teams (GET /amms | /amms-teams | /amms.html)
    // ZERO TRUST: Dostęp wyłącznie przez szyfrowany tunel SSH (127.0.0.1) — całkowita blokada ruchu z publicznego internetu (Cloudflare WAN)
    if ($requestUri === '/amms' || $requestUri === '/amms-teams' || $requestUri === '/amms.html' || str_starts_with($requestUri, '/docs-pdf/') || $requestUri === '/amms-page') {
        if ($isFromCloudflare) {
            header('Content-Type: application/json; charset=UTF-8');
            header('X-Content-Type-Options: nosniff');
            header('X-Frame-Options: DENY');
            http_response_code(403);
            echo json_encode([
                'success' => false,
                'error'   => 'Forbidden: Wewnętrzny Asystent AMMS oraz baza wiedzy Oracle są dostępne wyłącznie przez autoryzowany tunel SSH (127.0.0.1). Dostęp z publicznego internetu jest zablokowany.'
            ], JSON_UNESCAPED_UNICODE);
            exit;
        }
    }

    if ($requestUri === '/amms' || $requestUri === '/amms-teams' || $requestUri === '/amms.html') {
        header('Content-Type: text/html; charset=UTF-8');
        header('X-Content-Type-Options: nosniff');
        header('X-Frame-Options: DENY');
        header('Referrer-Policy: no-referrer');
        header("Content-Security-Policy: frame-ancestors 'none'");
        $ammsHtmlPath = __DIR__ . '/amms-teams.html';
        if (file_exists($ammsHtmlPath)) {
            readfile($ammsHtmlPath);
        } else {
            http_response_code(404);
            echo '<!DOCTYPE html><html lang="pl"><body><h1>Interfejs AMMS Teams nie został jeszcze zbudowany.</h1></body></html>';
        }
        exit;
    }

    // Bezpieczne serwowanie oryginalnych plików PDF dokumentacji AMMS (GET /docs-pdf/<nazwa.pdf>), jeśli są wgrane do data/docs-pdf/
    if (str_starts_with($requestUri, '/docs-pdf/')) {
        $requestedPdf = rawurldecode(substr($requestUri, strlen('/docs-pdf/')));
        $safePdfName = basename($requestedPdf);
        $dataBaseDir = realpath('/app/data') ?: realpath(dirname(__DIR__) . '/data');
        $pdfFullPath = $dataBaseDir ? realpath($dataBaseDir . '/docs-pdf/' . $safePdfName) : false;
        if ($pdfFullPath && str_ends_with(strtolower($safePdfName), '.pdf') && is_readable($pdfFullPath)) {
            header('Content-Type: application/pdf');
            header('X-Content-Type-Options: nosniff');
            header('X-Frame-Options: SAMEORIGIN');
            header('Cache-Control: private, max-age=86400');
            readfile($pdfFullPath);
            exit;
        }
        header('Content-Type: application/json; charset=UTF-8');
        http_response_code(404);
        echo json_encode(['success' => false, 'error' => 'Plik PDF nie jest dostępny na serwerze (użyj podglądu strony z bazy SQLite).'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    // Endpoint podglądu i kartkowania pojedynczej strony dokumentacji AMMS z bazy SQLite (GET /amms-page?file=...&page=X)
    if ($requestUri === '/amms-page') {
        header('Content-Type: application/json; charset=UTF-8');
        header('X-Content-Type-Options: nosniff');
        header('X-Frame-Options: DENY');

        $fileParam = trim((string)($_GET['file'] ?? ''));
        $pageParam = max(1, (int)($_GET['page'] ?? 1));
        $partParam = max(0, (int)($_GET['part'] ?? 0));

        if ($fileParam === '' || str_contains($fileParam, '..') || str_contains($fileParam, '/') || str_contains($fileParam, '\\')) {
            http_response_code(400);
            echo json_encode(['success' => false, 'error' => 'Bad Request: Nieprawidłowa nazwa pliku źródłowego.'], JSON_UNESCAPED_UNICODE);
            exit;
        }

        $dataBaseDir = realpath('/app/data') ?: realpath(dirname(__DIR__) . '/data');
        $sqliteFile = $dataBaseDir ? ($dataBaseDir . '/amms-knowledge.sqlite') : '';
        $ragClassFile = __DIR__ . '/amms-rag-search.php';

        if ($sqliteFile === '' || !is_file($sqliteFile) || !is_file($ragClassFile)) {
            http_response_code(404);
            echo json_encode(['success' => false, 'error' => 'Baza wiedzy AMMS SQLite lub wskazany plik nie jest dostępny.'], JSON_UNESCAPED_UNICODE);
            exit;
        }

        require_once $ragClassFile;
        try {
            $rag = new AmmsRagSearch($sqliteFile);
            $details = $rag->getPageDetails($fileParam, $pageParam, $partParam);
            if ($details === null) {
                http_response_code(404);
                echo json_encode(['success' => false, 'error' => 'Nie znaleziono wskazanej strony w bazie wiedzy AMMS.'], JSON_UNESCAPED_UNICODE);
                exit;
            }
            http_response_code(200);
            echo json_encode(['success' => true, 'page_data' => $details], JSON_UNESCAPED_UNICODE);
        } catch (Throwable $e) {
            http_response_code(500);
            echo json_encode(['success' => false, 'error' => 'Błąd odczytu strony z bazy wiedzy AMMS.'], JSON_UNESCAPED_UNICODE);
        }
        exit;
    }

    // ENDPOINT METRYK PROMETHEUSA (/metrics) ORAZ HEALTHCHECK (/health)
    if ($requestUri === '/metrics' || ($requestUri === '/health' && str_contains($_SERVER['HTTP_USER_AGENT'] ?? '', 'Prometheus'))) {
        if ($isFromCloudflare) {
            header('Content-Type: application/json; charset=UTF-8');
            header('X-Content-Type-Options: nosniff');
            header('X-Frame-Options: DENY');
            http_response_code(403);
            echo json_encode([
                'success' => false,
                'error'   => 'Forbidden: Endpoint telemetrii jest dostępny wyłącznie w sieci wewnętrznej.'
            ], JSON_UNESCAPED_UNICODE);
            exit;
        }
        header('Content-Type: text/plain; version=0.0.4; charset=UTF-8');
        header('X-Content-Type-Options: nosniff');
        http_response_code(200);
        echo aiRenderMetrics();
        exit;
    }

    // Wymuszenie formatu JSON i kodowania UTF-8 dla pozostałych endpointów API
    header('Content-Type: application/json; charset=UTF-8');
    header('X-Content-Type-Options: nosniff');
    header('X-Frame-Options: DENY');
    header("Content-Security-Policy: default-src 'none'; frame-ancestors 'none'");

    if ($requestUri === '/health') {
        http_response_code(200);
        echo json_encode([
            'status'    => 'UP',
            'service'   => 'ai-router',
            'timestamp' => time(),
            'uptime'    => 'ok'
        ], JSON_UNESCAPED_UNICODE);
        exit;
    }
}

/**
 * Obsługuje endpoint bezciasteczkowej analityki ruchu WWW (POST /analytics | /collect)
 * 100% Cookieless RODO, Zero-PII (dzienny skrót SHA-256 bez zapisu IP)
 */
function aiHandleAnalyticsEndpoint(string $requestUri, bool $isFromCloudflare): void {
    if ($requestUri !== '/analytics' && $requestUri !== '/collect') {
        return;
    }

    $rawBeacon = file_get_contents('php://input');
    $beacon = $rawBeacon ? json_decode($rawBeacon, true) : null;
    if (!is_array($beacon)) {
        http_response_code(400);
        echo json_encode(['success' => false, 'error' => 'Bad Request: Invalid JSON']);
        exit;
    }

    $ua = (string)($_SERVER['HTTP_USER_AGENT'] ?? '');
    $rawType = strtolower(trim((string)($beacon['type'] ?? 'pageview')));
    if ($rawType !== 'gsc_sync' && preg_match('/(bot|crawler|spider|lighthouse|headless|uptime-kuma|curl|python)/i', $ua)) {
        http_response_code(202);
        echo json_encode(['success' => true, 'skipped' => 'bot']);
        exit;
    }

    $allowedAnalyticsSites = ['katosalsahub', 'dancepuls', 'fuegolingua', 'twojastronawww', 'raricart', 'radar-p1'];
    $bSite = strtolower(trim((string)($beacon['site_id'] ?? '')));
    if (!preg_match('/^[a-z0-9_-]{2,32}$/', $bSite) || !in_array($bSite, $allowedAnalyticsSites, true)) {
        http_response_code(400);
        echo json_encode(['success' => false, 'error' => 'Bad Request: Invalid site_id']);
        exit;
    }

    // Ochrona Penalty Box i lekki Rate Limiter dla beaconów analityki (max 30 zdarzeń / 60s per IP)
    $bIp = getClientIp();
    $bRateDir = is_dir('/app/storage/rate_limits')
        ? '/app/storage/rate_limits'
        : (dirname(__DIR__) . '/storage/rate_limits');
    if (!is_dir($bRateDir)) {
        @mkdir($bRateDir, 0755, true);
    }
    $bRateFile = $bRateDir . '/' . hash('sha256', $bIp) . '.json';
    $bFp = @fopen($bRateFile, 'c+');
    if ($bFp) {
        if (flock($bFp, LOCK_EX)) {
            $bRaw = stream_get_contents($bFp);
            $bData = $bRaw ? json_decode($bRaw, true) : [];
            if (!is_array($bData)) {
                $bData = [];
            }
            $bNow = time();
            if (((int)($bData['blocked_until'] ?? 0)) > $bNow) {
                $retryAfter = (int)$bData['blocked_until'] - $bNow;
                flock($bFp, LOCK_UN);
                fclose($bFp);
                header("Retry-After: {$retryAfter}");
                http_response_code(403);
                echo json_encode(['success' => false, 'error' => 'Forbidden: IP in Penalty Box']);
                exit;
            }
            $aTimestamps = is_array($bData['analytics_timestamps'] ?? null) ? $bData['analytics_timestamps'] : [];
            $aTimestamps = array_values(array_filter($aTimestamps, fn($ts) => is_int($ts) && $ts > ($bNow - 60)));
            if (count($aTimestamps) >= 30) {
                flock($bFp, LOCK_UN);
                fclose($bFp);
                header('Retry-After: 30');
                http_response_code(429);
                echo json_encode(['success' => false, 'error' => 'Too Many Analytics Beacons']);
                exit;
            }
            $aTimestamps[] = $bNow;
            $bData['analytics_timestamps'] = $aTimestamps;
            ftruncate($bFp, 0);
            rewind($bFp);
            fwrite($bFp, json_encode($bData));
            fflush($bFp);
            flock($bFp, LOCK_UN);
        }
        fclose($bFp);
    }

    $rawType = strtolower(trim((string)($beacon['type'] ?? 'pageview')));
    if ($rawType === 'gsc_sync') {
        if ($isFromCloudflare) {
            http_response_code(403);
            echo json_encode(['success' => false, 'error' => 'Forbidden: GSC sync allowed only from internal network']);
            exit;
        }
        $gscRows = is_array($beacon['rows'] ?? null) ? $beacon['rows'] : [];
        aiRecordGscKeywords($bSite, $gscRows);
        http_response_code(202);
        echo json_encode(['success' => true, 'synced' => count($gscRows)]);
        exit;
    }

    $bType = in_array($rawType, ['pageview', 'search', 'event', 'engaged'], true) ? $rawType : 'pageview';
    $rawPath = trim((string)($beacon['path'] ?? '/'));
    $bPath = substr(preg_replace('/[^a-zA-Z0-9_\/#.-]/', '', $rawPath) ?: '/', 0, 48);
    if (!str_starts_with($bPath, '/')) {
        $bPath = '/' . $bPath;
    }

    $utmSource = strtolower(trim((string)($beacon['utm_source'] ?? '')));
    $referrer  = strtolower(trim((string)($beacon['referrer'] ?? '')));
    $bSource   = 'direct';
    $sourceProbe = $utmSource !== '' ? $utmSource : $referrer;
    if ($sourceProbe !== '') {
        if (preg_match('/(chatgpt\.com|openai\.com|perplexity\.ai|claude\.ai|gemini\.google\.com|copilot\.microsoft\.com|you\.com)/', $sourceProbe)) {
            $bSource = 'ai_search';
        } elseif (preg_match('/(facebook|fb\.com|fbclid|messenger)/', $sourceProbe)) {
            $bSource = 'facebook';
        } elseif (preg_match('/(instagram|ig\b)/', $sourceProbe)) {
            $bSource = 'instagram';
        } elseif (preg_match('/(tiktok|ttclid)/', $sourceProbe)) {
            $bSource = 'tiktok';
        } elseif (preg_match('/(youtube\.|youtu\.be)/', $sourceProbe)) {
            $bSource = 'youtube';
        } elseif (preg_match('/(duckduckgo\.)/', $sourceProbe)) {
            $bSource = 'duckduckgo';
        } elseif (preg_match('/(bing\.|msn\.com)/', $sourceProbe)) {
            $bSource = 'bing';
        } elseif (preg_match('/(google\.|gclid|yahoo\.|ecosia\.)/', $sourceProbe)) {
            $bSource = 'google';
        } elseif (!preg_match('/(katosalsahub\.pl|dancepuls\.pl|fuegolingua\.pl|twojastronawww\.pl|raricart\.pl|radar-p1\.pages\.dev|localhost|127\.0\.0\.1)/', $sourceProbe)) {
            $bSource = 'other';
        }
    }

    if (preg_match('/(iPad|Tablet|PlayBook|Silk)|(Android(?!.*Mobile))/i', $ua)) {
        $bDevice = 'tablet';
    } elseif (preg_match('/(Mobile|Android|iPhone|Windows Phone)/i', $ua)) {
        $bDevice = 'mobile';
    } else {
        $bDevice = 'desktop';
    }
    $rawCountry = strtoupper(trim((string)($_SERVER['HTTP_CF_IPCOUNTRY'] ?? 'PL')));
    $bCountry = (preg_match('/^[A-Z]{2}$/', $rawCountry) && $rawCountry !== 'XX') ? $rawCountry : 'PL';

    $visitorHash = substr(hash('sha256', aiAnalyticsDay() . '|' . $bSite . '|' . $bIp . '|' . $ua), 0, 16);

    $rawTerm = trim((string)($beacon['term'] ?? $beacon['search_term'] ?? $beacon['utm_term'] ?? ''));
    $bTerm = mb_substr(trim((string)preg_replace('/[^a-ząćęłńóśźż0-9 _-]/iu', '', mb_strtolower($rawTerm))), 0, 40);
    if (mb_strlen($bTerm) < 2) {
        $bTerm = '';
    }

    $rawEvent = strtolower(trim((string)($beacon['event'] ?? $beacon['event_name'] ?? '')));
    $bEvent = substr(preg_replace('/[^a-z0-9_-]/', '', $rawEvent) ?: '', 0, 32);

    $bLcpMs = isset($beacon['lcp_ms']) && is_numeric($beacon['lcp_ms']) ? (float)$beacon['lcp_ms'] : 0.0;

    aiRecordWebAnalytics($bSite, $bType, $bPath, $bSource, $bDevice, $bCountry, $visitorHash, $bTerm, $bEvent, $bLcpMs);
    if ($bType === 'pageview' && $bTerm !== '') {
        aiRecordWebAnalytics($bSite, 'search', $bPath, $bSource, $bDevice, $bCountry, $visitorHash, $bTerm);
    }

    http_response_code(202);
    echo json_encode(['success' => true]);
    exit;
}
