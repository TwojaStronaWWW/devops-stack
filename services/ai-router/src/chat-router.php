<?php
declare(strict_types=1);

/**
 * AI Chat Router - TwojaStronaWWW DevOps Stack (Main Orchestrator)
 *
 * Scentralizowany mikro-router AI pośredniczący między stronami WWW a 15-modelową kaskadą LLM.
 * Architektura modułowa:
 * - ai-stats.php         : Telemetria Prometheus, Cooldown modeli i Cookieless Web Analytics v3
 * - router-endpoints.php : Endpointy GET (/widget.js, /amms, /radar, /health, /metrics) i POST (/analytics)
 * - llm-cascade.php      : Instrukcje RAG oraz kaskada Mistral/Gemini/Groq/Cerebras/WorkersAI/OpenRouter/Anthropic
 * - lead-notifier.php    : Ekstrakcja namiarów Zero-PII i powiadomienia 1-Klik Ntfy.sh + osTicket
 */

header_remove('X-Powered-By');
header('Strict-Transport-Security: max-age=31536000; includeSubDomains');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header('Permissions-Policy: geolocation=(), microphone=(), camera=()');

$requestUri = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
$isFromCloudflare = !empty($_SERVER['HTTP_CF_CONNECTING_IP']) || !empty($_SERVER['HTTP_CF_RAY']);

require_once __DIR__ . '/ai-stats.php';
require_once __DIR__ . '/router-endpoints.php';
require_once __DIR__ . '/llm-cascade.php';
require_once __DIR__ . '/lead-notifier.php';

// 1. Obsługa wczesnych endpointów GET (/widget.js, /radar-data, /radar, /amms, /docs-pdf/*, /amms-page, /metrics, /health)
aiHandleEarlyGetEndpoints($requestUri, $isFromCloudflare);

// 1b. Telemetria żądań czatu (jedno miejsce zapisu wyniku niezależnie od ścieżki exit)
$aiStart           = microtime(true);
$aiSite            = 'unknown';
$usedModel         = null;
$aiDepth           = null;
$aiAttempts        = 0;
$aiSecurityBlocked = false;
register_shutdown_function(function () use (&$aiSite, &$usedModel, &$aiDepth, &$aiAttempts, &$aiSecurityBlocked, $aiStart, $requestUri): void {
    $code = http_response_code() ?: 200;
    if (($_SERVER['REQUEST_METHOD'] ?? '') === 'OPTIONS' || $code === 204 || $requestUri === '/analytics' || $requestUri === '/collect' || $requestUri === '/amms-page') {
        return; // preflight CORS oraz beacony analityki WWW nie są zapytaniami czatu
    }
    $outcome = match (true) {
        $aiSecurityBlocked => 'security_blocked',
        $code === 200 => 'success',
        $code === 400 => 'bad_request',
        $code === 403 => 'cors_forbidden',
        $code === 404 => 'no_knowledge_base',
        $code === 405 => 'method_not_allowed',
        $code === 429 => 'rate_limited',
        $code === 500 => 'config_error',
        $code === 502 => 'all_models_failed',
        default       => 'other',
    };
    aiRecordRequest($aiSite, $outcome, $code, (microtime(true) - $aiStart) * 1000, $usedModel, $aiDepth, $aiAttempts);
});

// 2. ZABEZPIECZENIE CORS & BIAŁA LISTA DOMEN
$defaultAllowedOrigins = [
    'https://katosalsahub.pl',
    'https://www.katosalsahub.pl',
    'https://dancepuls.katosalsahub.pl',
    'https://dancepuls.pl',
    'https://www.dancepuls.pl',
    'https://fuegolingua.pl',
    'https://www.fuegolingua.pl',
    'https://twojastronawww.pl',
    'https://www.twojastronawww.pl',
    'https://raricart.pl',
    'https://www.raricart.pl',
    'https://test.raricart.pl',
    'https://laclave.pl',
    'https://www.laclave.pl',
    'https://milpasoskatowice.pl',
    'https://www.milpasoskatowice.pl',
    'https://goodmood.dance',
    'https://www.goodmood.dance',
    'https://tanecznakompania.pl',
    'https://www.tanecznakompania.pl',
    'https://radar-p1.pages.dev'
];
$allowedOriginsEnv = getenv('ALLOWED_ORIGINS');
$allowedOrigins = $allowedOriginsEnv
    ? array_values(array_unique(array_merge($defaultAllowedOrigins, array_map('trim', explode(',', $allowedOriginsEnv)))))
    : $defaultAllowedOrigins;

$origin = $_SERVER['HTTP_ORIGIN'] ?? '';

if ($origin !== '') {
    $isAllowed = in_array($origin, $allowedOrigins, true) ||
                 (!$isFromCloudflare && (bool)preg_match('/^https?:\/\/(localhost|127\.0\.0\.1)(:[0-9]+)?$/', $origin));

    if ($isAllowed) {
        header("Access-Control-Allow-Origin: {$origin}");
        header('Access-Control-Allow-Credentials: true');
        header('Access-Control-Allow-Methods: POST, OPTIONS');
        header('Access-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With');
        header('Access-Control-Max-Age: 86400');
    } else {
        http_response_code(403);
        echo json_encode([
            'success' => false,
            'error'   => 'CORS Forbidden: Niedozwolone źródło żądania.'
        ], JSON_UNESCAPED_UNICODE);
        exit;
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode([
        'success' => false,
        'error'   => 'Method Not Allowed: Wymagana metoda POST.'
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// 2b. ENDPOINT BEZCIASTECZKOWEJ ANALITYKI RUCHU WWW (POST /analytics | /collect)
aiHandleAnalyticsEndpoint($requestUri, $isFromCloudflare);

// Wczytanie zmiennych z lokalnego pliku .env (jako bezpieczny fallback poza kontenerem)
if (!getenv('GEMINI_API_KEY')) {
    $envCandidates = [
        dirname(__DIR__, 3) . '/.env',
        dirname(__DIR__, 2) . '/.env',
        '/app/.env'
    ];
    foreach ($envCandidates as $envPath) {
        if (file_exists($envPath) && is_readable($envPath)) {
            $lines = file($envPath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
            foreach ($lines as $line) {
                $line = trim($line);
                if ($line === '' || str_starts_with($line, '#') || !str_contains($line, '=')) continue;
                [$k, $v] = explode('=', $line, 2);
                $k = trim($k);
                $v = trim($v, " \t\n\r\0\x0B\"'");
                if (!getenv($k)) {
                    putenv("{$k}={$v}");
                    $_ENV[$k] = $v;
                }
            }
            break;
        }
    }
}

// 3. IDENTYFIKACJA KLIENTA I RATE LIMITING (PER IP + PENALTY BOX)
$clientIp = getClientIp();
$rateLimitWindow = 60;
$rateLimitMax = 5;

$storageDir = is_dir('/app/storage/rate_limits')
    ? '/app/storage/rate_limits'
    : (dirname(__DIR__) . '/storage/rate_limits');

if (!is_dir($storageDir)) {
    @mkdir($storageDir, 0755, true);
}

$rateFile = $storageDir . '/' . hash('sha256', $clientIp) . '.json';
$fp = @fopen($rateFile, 'c+');

if ($fp) {
    if (flock($fp, LOCK_EX)) {
        $content = stream_get_contents($fp);
        $data = $content ? json_decode($content, true) : null;
        if (!is_array($data)) {
            $data = [];
        }
        $now = time();

        $blockedUntil = (int)($data['blocked_until'] ?? 0);
        if ($blockedUntil > $now) {
            $retryAfter = $blockedUntil - $now;
            $banReason = (string)($data['ban_reason'] ?? 'security_penalty_box');
            flock($fp, LOCK_UN);
            fclose($fp);

            header("Retry-After: {$retryAfter}");
            if ($banReason === 'rate_limit_abuse') {
                http_response_code(429);
                echo json_encode([
                    'success'     => false,
                    'error'       => 'Adres IP tymczasowo zablokowany (Penalty Box 15 min) z powodu wielokrotnego przekroczenia limitu zapytań.',
                    'retry_after' => $retryAfter
                ], JSON_UNESCAPED_UNICODE);
            } else {
                $aiSecurityBlocked = true;
                http_response_code(403);
                echo json_encode([
                    'success'     => false,
                    'error'       => 'Forbidden: Adres IP zablokowany na 15 minut (Penalty Box) po wykryciu próby ataku WAF / Prompt Injection.',
                    'retry_after' => $retryAfter
                ], JSON_UNESCAPED_UNICODE);
            }
            exit;
        }

        $timestamps = is_array($data['timestamps'] ?? null) ? $data['timestamps'] : [];
        $timestamps = array_values(array_filter($timestamps, fn($ts) => is_int($ts) && $ts > ($now - $rateLimitWindow)));

        if (count($timestamps) >= $rateLimitMax) {
            $violations = (int)($data['violations'] ?? 0) + 1;
            $data['timestamps'] = $timestamps;
            $data['violations'] = $violations;
            if ($violations >= 3) {
                $data['blocked_until'] = $now + 900;
                $data['ban_reason'] = 'rate_limit_abuse';
                $retryAfter = 900;
            } else {
                $oldest = $timestamps[0];
                $retryAfter = max(1, $rateLimitWindow - ($now - $oldest));
            }
            ftruncate($fp, 0);
            rewind($fp);
            fwrite($fp, json_encode($data));
            fflush($fp);
            flock($fp, LOCK_UN);
            fclose($fp);

            http_response_code(429);
            header("Retry-After: {$retryAfter}");
            echo json_encode([
                'success'     => false,
                'error'       => 'Zbyt wiele zapytań. Limit wynosi 5 na minutę. Odczekaj chwilę.',
                'retry_after' => $retryAfter
            ], JSON_UNESCAPED_UNICODE);
            exit;
        }

        $timestamps[] = $now;
        $data['timestamps'] = $timestamps;
        ftruncate($fp, 0);
        rewind($fp);
        fwrite($fp, json_encode($data));
        fflush($fp);
        flock($fp, LOCK_UN);
    }
    fclose($fp);
}

// Lekki Garbage Collection starych plików rate-limit (>1h) oraz cache (>24h)
$cacheDir = is_dir('/app/storage') ? '/app/storage/cache' : (dirname(__DIR__) . '/storage/cache');
if (!is_dir($cacheDir)) {
    @mkdir($cacheDir, 0755, true);
}
$cacheTtl = max(60, (int)(getenv('AI_CACHE_TTL') ?: 86400));

if (mt_rand(1, 50) === 1) {
    if (is_dir($storageDir)) {
        $expireBefore = time() - 3600;
        foreach (glob($storageDir . '/*.json') ?: [] as $oldRateFile) {
            if (@filemtime($oldRateFile) < $expireBefore) {
                @unlink($oldRateFile);
            }
        }
    }
    if (is_dir($cacheDir)) {
        $cacheExpireBefore = time() - $cacheTtl;
        foreach (glob($cacheDir . '/*.json') ?: [] as $oldCacheFile) {
            if (@filemtime($oldCacheFile) < $cacheExpireBefore) {
                @unlink($oldCacheFile);
            }
        }
    }
}

// 4. PARSOWANIE I WALIDACJA WEJŚCIA (PAYLOAD + WAF L7)
$rawInput = file_get_contents('php://input');
if (!$rawInput) {
    http_response_code(400);
    echo json_encode([
        'success' => false,
        'error'   => 'Bad Request: Brak danych w ciele żądania.'
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

$payload = json_decode($rawInput, true);
if (json_last_error() !== JSON_ERROR_NONE || !is_array($payload)) {
    http_response_code(400);
    echo json_encode([
        'success' => false,
        'error'   => 'Bad Request: Niepoprawny format JSON.'
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

$siteId = trim((string)($payload['site_id'] ?? ''));
$question = trim((string)($payload['question'] ?? $payload['message'] ?? ''));
$rawHistory = is_array($payload['history'] ?? null) ? $payload['history'] : [];
$kbVersion = substr(preg_replace('/[^a-zA-Z0-9._:-]/', '', trim((string)($payload['kb_version'] ?? ''))) ?: 'v0', 0, 64);
$dynamicContext = trim((string)($payload['dynamic_context'] ?? ''));
if (mb_strlen($dynamicContext) > 12000) {
    $dynamicContext = mb_substr($dynamicContext, 0, 12000);
}

if (!preg_match('/^[a-z0-9_-]{2,32}$/i', $siteId)) {
    http_response_code(400);
    echo json_encode([
        'success' => false,
        'error'   => 'Bad Request: Niepoprawny identyfikator witryny (site_id).'
    ], JSON_UNESCAPED_UNICODE);
    exit;
}
$aiSite = strtolower($siteId);

// ZERO TRUST: Baza wiedzy AMMS i struktura Oracle są ściśle wewnętrzne — blokada zapytań z publicznego internetu (Cloudflare WAN)
if (in_array($aiSite, ['amms', 'amms-assistant', 'asseco-amms'], true) && $isFromCloudflare) {
    http_response_code(403);
    echo json_encode([
        'success' => false,
        'error'   => 'Forbidden: Wewnętrzny Asystent AMMS i baza wiedzy Oracle są dostępne wyłącznie przez szyfrowany tunel SSH (127.0.0.1). Dostęp z publicznego internetu jest zablokowany.'
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

if (mb_strlen($question) < 2 || mb_strlen($question) > 2000) {
    http_response_code(400);
    echo json_encode([
        'success' => false,
        'error'   => 'Bad Request: Treść pytania musi zawierać od 2 do 2000 znaków.'
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// WAF / Prompt Injection & Exploit Guard (< 0.5 ms)
$qLower = mb_strtolower($question);
$promptInjectionPattern = '/(ignore\s+(all\s+)?(previous|prior)\s+instructions|disregard\s+(all\s+)?(previous|prior)|zignoruj\s+(wszystkie\s+)?(wcze[śs]niejsze|poprzednie)\s+(instrukcje|zasady)|reveal\s+your\s+(system\s+)?prompt|poka[żz]\s+(sw[óo]j\s+)?system\s+prompt|you\s+are\s+now\s+dan\b|developer\s+mode\s+enabled)/iu';
$exploitPayloadPattern  = '/(<\s*script\b|javascript\s*:|on(error|load|mouseover)\s*=|\bunion\s+all\s+select\b|\bdrop\s+table\b|\/etc\/(passwd|shadow)|\.\.\/\.\.\/)/iu';

if (preg_match($promptInjectionPattern, $qLower) || preg_match($exploitPayloadPattern, $qLower)) {
    $aiSecurityBlocked = true;
    $wafReason = preg_match($promptInjectionPattern, $qLower) ? 'prompt_injection' : 'exploit_payload';
    banClientIp($rateFile, 900, $wafReason);
    aiLog('security_blocked', ['site' => $aiSite, 'reason' => $wafReason, 'penalty_box_sec' => 900]);
    header('Retry-After: 900');
    http_response_code(403);
    echo json_encode([
        'success'     => false,
        'error'       => 'Forbidden: Żądanie zostało zablokowane przez filtr bezpieczeństwa (WAF / Prompt Injection Guard). Adres IP umieszczony w Penalty Box (15 min).',
        'retry_after' => 900
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// Sanityzacja historii rozmowy (max 8 ostatnich wiadomości)
$sanitizedHistory = [];
foreach (array_slice($rawHistory, -8) as $turn) {
    if (!is_array($turn)) continue;
    $role = strtolower(trim((string)($turn['role'] ?? '')));
    $text = trim((string)($turn['text'] ?? $turn['content'] ?? ''));
    if ($text === '' || mb_strlen($text) > 1200) {
        $text = mb_substr($text, 0, 1200);
    }
    if ($text === '') continue;

    $normalizedRole = ($role === 'assistant' || $role === 'model' || $role === 'bot') ? 'model' : 'user';
    $sanitizedHistory[] = [
        'role' => $normalizedRole,
        'text' => $text
    ];
}

// 5. DYNAMICZNY RAG (ŁADOWANIE BAZY WIEDZY TXT LUB HYBRYDOWEJ BAZY SQLITE FTS5 AMMS + INTELIGENTNY CACHE)
$rawDir = realpath('/app/data') ?: realpath(dirname(__DIR__) . '/data');
$normalizedDataDir = $rawDir ? rtrim(str_replace('\\', '/', $rawDir), '/') : '';

$isAmmsSite = ($aiSite === 'amms');
$ammsChannel = strtolower(trim((string)($payload['channel'] ?? 'general')));
if (!preg_match('/^[a-z0-9_-]{2,24}$/', $ammsChannel)) {
    $ammsChannel = 'general';
}
$requestedReasoningMode = strtolower(trim((string)($payload['reasoning_mode'] ?? $payload['reasoning'] ?? 'auto')));
if (!in_array($requestedReasoningMode, ['auto', 'fast', 'standard', 'high'], true)) {
    $requestedReasoningMode = 'auto';
}

$ammsSources = [];
$ammsRagStats = null;
$ammsReasoningTier = 'fast';
$ammsReasoningLabel = 'Standard RAG';
$ammsDetectedDbQuery = ($isAmmsSite && $ammsChannel === 'oracle');

$knowledgeContent = null;
$loadedFile = null;
$loadedFilePath = null;

$ragSearchQuery = $question;
if (!empty($sanitizedHistory) && mb_strlen($question, 'UTF-8') < 90) {
    for ($hIdx = count($sanitizedHistory) - 1; $hIdx >= 0; $hIdx--) {
        if (($sanitizedHistory[$hIdx]['role'] ?? '') === 'user') {
            $ragSearchQuery = $sanitizedHistory[$hIdx]['text'] . ' ' . $question;
            break;
        }
    }
}

$sqliteCandidate = $rawDir ? ($rawDir . '/' . $aiSite . '-knowledge.sqlite') : '';
$ammsRagClassPath = __DIR__ . '/amms-rag-search.php';

if ($sqliteCandidate !== '' && is_file($sqliteCandidate) && is_readable($sqliteCandidate) && is_file($ammsRagClassPath)) {
    require_once $ammsRagClassPath;
    $reasoningProfile = AmmsRagSearch::detectReasoningProfile($ragSearchQuery, $requestedReasoningMode, $ammsChannel);
    $ammsReasoningTier = $reasoningProfile['tier'];
    $ammsReasoningLabel = $reasoningProfile['label'];
    $ammsDetectedDbQuery = !empty($reasoningProfile['is_db_query']);

    try {
        $ammsRag = new AmmsRagSearch($sqliteCandidate);
        $searchRes = $ammsRag->searchKnowledge($ragSearchQuery, 14, 68000, '/docs-pdf/', $ammsDetectedDbQuery);
        if (trim($searchRes['context']) !== '') {
            $knowledgeContent = $searchRes['context'];
            $ammsSources = $searchRes['sources'];
            $ammsRagStats = $searchRes['stats'];
            $loadedFile = basename($sqliteCandidate);
            $loadedFilePath = $sqliteCandidate;
        }
    } catch (Throwable $e) {
        aiLog('amms_sqlite_error', ['site' => $aiSite, 'msg' => $e->getMessage()]);
    }
}

if ($knowledgeContent === null) {
    $possibleFiles = [
        $rawDir . '/' . strtolower($siteId) . '-knowledge.txt',
        $rawDir . '/' . strtolower($siteId) . '.txt',
        $rawDir . '/' . strtolower($siteId) . '.md',
    ];

    foreach ($possibleFiles as $filePath) {
        $real = realpath($filePath);
        if ($real) {
            $normalizedReal = str_replace('\\', '/', $real);
            if ($normalizedDataDir !== '' && str_starts_with($normalizedReal, $normalizedDataDir) && is_readable($real)) {
                $knowledgeContent = file_get_contents($real, false, null, 0, 100000);
                $loadedFile = basename($real);
                $loadedFilePath = $real;
                break;
            }
        }
    }

    if ($isAmmsSite && is_file($ammsRagClassPath)) {
        require_once $ammsRagClassPath;
        $reasoningProfile = AmmsRagSearch::detectReasoningProfile($ragSearchQuery, $requestedReasoningMode, $ammsChannel);
        $ammsReasoningTier = $reasoningProfile['tier'];
        $ammsReasoningLabel = $reasoningProfile['label'];
        $ammsDetectedDbQuery = !empty($reasoningProfile['is_db_query']);
    }
}

if ($knowledgeContent === null || trim($knowledgeContent) === '') {
    http_response_code(404);
    echo json_encode([
        'success' => false,
        'error'   => "Nie znaleziono bazy wiedzy dla witryny: '{$siteId}'."
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// Detekcja namiarów kontaktowych (Zero-PII na dysku) i ekstrakcja tematów pytań
$leadInfo = aiExtractContactLeads($question, $sanitizedHistory, $isAmmsSite);
$hasContactLead = !empty($leadInfo['hasContactLead']);
aiExtractAndRecordTopics($aiSite, $question, $hasContactLead);

// Pamięć podręczna odpowiedzi RAG (< 5 ms)
$normalizedQ = trim((string)preg_replace('/[\p{P}\p{S}\s]+/u', ' ', mb_strtolower(trim($question))));
if ($normalizedQ === '') {
    $normalizedQ = preg_replace('/\s+/u', ' ', mb_strtolower(trim($question))) ?: '';
}
$historySig = empty($sanitizedHistory) ? 'turn0' : hash('sha256', (string)json_encode($sanitizedHistory, JSON_UNESCAPED_UNICODE));
$kbMtime    = $loadedFilePath ? (int)@filemtime($loadedFilePath) : 0;
$dynSig     = ($kbVersion !== 'v0' || $dynamicContext !== '' || $isAmmsSite) ? hash('sha256', "{$kbVersion}|{$ammsReasoningTier}|{$ammsChannel}|" . ($ammsDetectedDbQuery ? 'db' : 'doc') . "|{$dynamicContext}") : 'static';
$cacheKey   = hash('sha256', "{$aiSite}|{$kbMtime}|{$dynSig}|{$historySig}|{$normalizedQ}");
$cacheFile  = $cacheDir . '/' . $cacheKey . '.json';

if (!$hasContactLead && is_file($cacheFile) && (time() - (int)@filemtime($cacheFile)) < $cacheTtl) {
    $cachedRaw = @file_get_contents($cacheFile);
    $cachedJson = $cachedRaw ? json_decode($cachedRaw, true) : null;
    if (is_array($cachedJson) && !empty($cachedJson['answer'])) {
        $usedModel = (string)($cachedJson['model'] ?? 'cache');
        $aiDepth = null;
        aiRecordCacheHit($aiSite);
        $cachedResponse = [
            'success'    => true,
            'site_id'    => $siteId,
            'model'      => $usedModel,
            'cached'     => true,
            'kb_version' => $kbVersion,
            'answer'     => (string)$cachedJson['answer']
        ];
        if ($isAmmsSite || !empty($cachedJson['sources'])) {
            $cachedResponse['sources'] = is_array($cachedJson['sources'] ?? null) ? $cachedJson['sources'] : $ammsSources;
            $cachedResponse['reasoning_tier'] = (string)($cachedJson['reasoning_tier'] ?? $ammsReasoningTier);
            $cachedResponse['reasoning_label'] = (string)($cachedJson['reasoning_label'] ?? $ammsReasoningLabel);
            if ($ammsRagStats !== null) {
                $cachedResponse['rag_stats'] = $ammsRagStats;
            }
        }
        http_response_code(200);
        echo json_encode($cachedResponse, JSON_UNESCAPED_UNICODE);
        exit;
    }
}

// 6. INTEGRACJA Z SILNIKIEM AI (15-MODELOWA KASKADA FALLBACKU LLM)
$geminiApiKey = getenv('GEMINI_API_KEY') ?: '';
$groqApiKey = getenv('GROQ_API_KEY') ?: '';
$cerebrasApiKey = getenv('CEREBRAS_API_KEY') ?: '';
$mistralApiKey = getenv('MISTRAL_API_KEY') ?: '';
$cfAiToken = getenv('CF_AI_API_TOKEN') ?: '';
$cfAccountId = preg_replace('/[^a-f0-9]/i', '', (string)(getenv('CF_ACCOUNT_ID') ?: ''));
$openRouterApiKey = getenv('OPENROUTER_API_KEY') ?: '';
$anthropicApiKey = getenv('ANTHROPIC_API_KEY') ?: '';

if ($geminiApiKey === '' && $groqApiKey === '' && $cerebrasApiKey === '' && $mistralApiKey === '' && ($cfAiToken === '' || $cfAccountId === '') && $openRouterApiKey === '' && $anthropicApiKey === '') {
    http_response_code(500);
    echo json_encode([
        'success' => false,
        'error'   => 'Błąd konfiguracji serwera: brak klucza GEMINI_API_KEY w środowisku.'
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// Automatyczna korekta wycofanych modeli (1.5 / 2.0 / 2.5) na najnowszy darmowy gemini-3.8-flash (patrz aiConfiguredModel)
$configuredModel = aiConfiguredModel();
$systemInstruction = aiBuildSystemInstruction($siteId, $isAmmsSite, $knowledgeContent, $dynamicContext, $kbVersion);

$isAmmsHighReasoning = ($isAmmsSite && $ammsReasoningTier === 'high');
$isAmmsDbQuery = $isAmmsSite && (
    $ammsDetectedDbQuery
    || $ammsChannel === 'oracle'
    || !empty($ammsRagStats['is_db_mode'])
    || (class_exists('AmmsRagSearch') && AmmsRagSearch::isDatabaseOrArchitectureQuery($ragSearchQuery, $ammsChannel))
);

$cascadeResult = aiRunModelCascade([
    'question'            => $question,
    'sanitizedHistory'    => $sanitizedHistory,
    'systemInstruction'   => $systemInstruction,
    'isAmmsSite'          => $isAmmsSite,
    'isAmmsDbQuery'       => $isAmmsDbQuery,
    'isAmmsHighReasoning' => $isAmmsHighReasoning,
    'ammsReasoningTier'   => $ammsReasoningTier,
    'configuredModel'     => $configuredModel,
    'geminiApiKey'        => $geminiApiKey,
    'groqApiKey'          => $groqApiKey,
    'cerebrasApiKey'      => $cerebrasApiKey,
    'mistralApiKey'       => $mistralApiKey,
    'cfAiToken'           => $cfAiToken,
    'cfAccountId'         => $cfAccountId,
    'openRouterApiKey'    => $openRouterApiKey,
    'anthropicApiKey'     => $anthropicApiKey,
], $aiAttempts, $aiDepth);

$answer = $cascadeResult['answer'];
$usedModel = $cascadeResult['usedModel'];
$lastErrorMsg = (string)$cascadeResult['lastErrorMsg'];

if ($answer === null) {
    http_response_code(502);
    echo json_encode([
        'success' => false,
        'error'   => $lastErrorMsg
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// Zapis odpowiedzi w pamięci podręcznej RAG (atomowo, z pominięciem komunikatów SAFETY oraz wiadomości z danymi kontaktowymi Zero-PII)
if (!$hasContactLead && is_dir($cacheDir) && !str_starts_with($answer, 'Przepraszam, zapytanie narusza zasady')) {
    $tmpCache = $cacheFile . '.' . getmypid() . '.tmp';
    $cachePayload = [
        'answer'          => $answer,
        'model'           => $usedModel,
        'ts'              => time(),
        'sources'         => $ammsSources,
        'reasoning_tier'  => $ammsReasoningTier,
        'reasoning_label' => $ammsReasoningLabel,
    ];
    if (@file_put_contents($tmpCache, json_encode($cachePayload, JSON_UNESCAPED_UNICODE)) !== false) {
        @rename($tmpCache, $cacheFile);
    }
}

// 7. CZYSTY ZWROT DANYCH DO FRONTENDU (NATYCHMIASTOWY FLUSH PRZED WEBHOOKAMI)
$finalResponse = [
    'success' => true,
    'site_id' => $siteId,
    'model'   => $usedModel,
    'cached'  => false,
    'answer'  => $answer
];
if ($isAmmsSite || !empty($ammsSources)) {
    $finalResponse['sources'] = $ammsSources;
    $finalResponse['reasoning_tier'] = $ammsReasoningTier;
    $finalResponse['reasoning_label'] = $ammsReasoningLabel;
    if ($ammsRagStats !== null) {
        $finalResponse['rag_stats'] = $ammsRagStats;
    }
}
$jsonBodyOut = (string)json_encode($finalResponse, JSON_UNESCAPED_UNICODE);
ignore_user_abort(true);
http_response_code(200);
header('Connection: close');
header('Content-Length: ' . strlen($jsonBodyOut));
echo $jsonBodyOut;
if (function_exists('fastcgi_finish_request')) {
    fastcgi_finish_request();
} else {
    while (ob_get_level() > 0) {
        @ob_end_flush();
    }
    flush();
}

// Asynchroniczna wysyłka powiadomień o leadach (Ntfy.sh 1-Klik + osTicket) po zamknięciu połączenia z przeglądarką
aiDispatchLeadNotifications($aiSite, $question, $answer, (string)$usedModel, $sanitizedHistory, $isAmmsSite, $leadInfo);
