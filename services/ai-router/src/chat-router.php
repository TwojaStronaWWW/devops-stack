<?php
declare(strict_types=1);

/**
 * AI Chat Router - TwojaStronaWWW DevOps Stack
 * 
 * Scentralizowany mikro-router AI pośredniczący między stronami WWW a Google Gemini API.
 * Standardy: PHP 8+, Zero-Bloat, ISO 27001, CORS Whitelist, IP Rate Limiter (Cloudflare).
 */

$requestUri = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);

// Serwowanie uniwersalnego widgetu JS dla zewnętrznych stron WWW
if ($requestUri === '/widget.js') {
    header('Content-Type: application/javascript; charset=UTF-8');
    header('Access-Control-Allow-Origin: *');
    header('Cache-Control: public, max-age=3600');
    $widgetPath = __DIR__ . '/widget.js';
    if (file_exists($widgetPath)) {
        readfile($widgetPath);
    } else {
        http_response_code(404);
        echo '/* widget.js not found */';
    }
    exit;
}

// Wymuszenie formatu JSON i kodowania UTF-8 dla endpointów API
header('Content-Type: application/json; charset=UTF-8');
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');

// -----------------------------------------------------------------------------
// 1. ENDPOINT KONTROLNY (HEALTHCHECK) DLA UPTIME KUMA & DOCKERA
// -----------------------------------------------------------------------------
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

// -----------------------------------------------------------------------------
// 2. ZABEZPIECZENIE CORS & BIAŁA LISTA DOMEN
// -----------------------------------------------------------------------------
$allowedOriginsEnv = getenv('ALLOWED_ORIGINS');
$allowedOrigins = $allowedOriginsEnv
    ? array_map('trim', explode(',', $allowedOriginsEnv))
    : [
        'https://katosalsahub.pl',
        'https://www.katosalsahub.pl',
        'https://fuegolingua.pl',
        'https://www.fuegolingua.pl',
        'https://twojastronawww.pl',
        'https://www.twojastronawww.pl'
    ];

$origin = $_SERVER['HTTP_ORIGIN'] ?? '';

// Obsługa Origin zapytań przeglądarkowych
if ($origin !== '') {
    // Sprawdzenie czy domena jest na białej liście lub czy to lokalny dev (http://localhost:*)
    $isAllowed = in_array($origin, $allowedOrigins, true) ||
                 preg_match('/^https?:\/\/(localhost|127\.0\.0\.1)(:[0-9]+)?$/', $origin);

    if ($isAllowed) {
        header("Access-Control-Allow-Origin: {$origin}");
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

// Obsługa zapytania Preflight (OPTIONS)
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

// Tylko żądania POST są akceptowane dla czatu
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode([
        'success' => false,
        'error'   => 'Method Not Allowed: Wymagana metoda POST.'
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// -----------------------------------------------------------------------------
// 3. IDENTYFIKACJA KLIENTA I RATE LIMITING (PER IP)
// -----------------------------------------------------------------------------
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

$clientIp = getClientIp();
$rateLimitWindow = 60; // 60 sekund
$rateLimitMax = 5;     // maksymalnie 5 zapytań na minutę

$storageDir = is_dir('/app/storage/rate_limits')
    ? '/app/storage/rate_limits'
    : (dirname(__DIR__) . '/storage/rate_limits');

if (!is_dir($storageDir)) {
    @mkdir($storageDir, 0755, true);
}

// Unikalny plik per IP zabezpieczający przed kolizjami i race conditions
$rateFile = $storageDir . '/' . hash('sha256', $clientIp) . '.json';
$fp = @fopen($rateFile, 'c+');

if ($fp) {
    if (flock($fp, LOCK_EX)) {
        $content = stream_get_contents($fp);
        $data = $content ? json_decode($content, true) : null;
        $now = time();

        $timestamps = is_array($data['timestamps'] ?? null) ? $data['timestamps'] : [];
        // Filtrujemy tylko zapytania z ostatnich 60 sekund
        $timestamps = array_values(array_filter($timestamps, fn($ts) => is_int($ts) && $ts > ($now - $rateLimitWindow)));

        if (count($timestamps) >= $rateLimitMax) {
            $oldest = $timestamps[0];
            $retryAfter = max(1, $rateLimitWindow - ($now - $oldest));
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

        // Rejestrujemy bieżące zapytanie
        $timestamps[] = $now;
        ftruncate($fp, 0);
        rewind($fp);
        fwrite($fp, json_encode(['timestamps' => $timestamps]));
        fflush($fp);
        flock($fp, LOCK_UN);
    }
    fclose($fp);
}

// -----------------------------------------------------------------------------
// 4. PARSOWANIE I WALIDACJA WEJŚCIA (PAYLOAD)
// -----------------------------------------------------------------------------
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

// Rygorystyczna sanityzacja site_id (anty Path Traversal)
if (!preg_match('/^[a-z0-9_-]{2,32}$/i', $siteId)) {
    http_response_code(400);
    echo json_encode([
        'success' => false,
        'error'   => 'Bad Request: Niepoprawny identyfikator witryny (site_id).'
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

// -----------------------------------------------------------------------------
// 5. DYNAMICZNY RAG (ŁADOWANIE BAZY WIEDZY)
// -----------------------------------------------------------------------------
$rawDir = realpath('/app/data') ?: realpath(dirname(__DIR__) . '/data');
$normalizedDataDir = $rawDir ? rtrim(str_replace('\\', '/', $rawDir), '/') : '';

$possibleFiles = [
    $rawDir . '/' . strtolower($siteId) . '-knowledge.txt',
    $rawDir . '/' . strtolower($siteId) . '.txt',
    $rawDir . '/' . strtolower($siteId) . '.md',
];

$knowledgeContent = null;
$loadedFile = null;

foreach ($possibleFiles as $filePath) {
    $real = realpath($filePath);
    if ($real) {
        $normalizedReal = str_replace('\\', '/', $real);
        // Weryfikacja czy plik istnieje i leży ściśle wewnątrz katalogu dataDir
        if ($normalizedDataDir !== '' && str_starts_with($normalizedReal, $normalizedDataDir) && is_readable($real)) {
            $knowledgeContent = file_get_contents($real, false, null, 0, 100000); // Max 100 KB
            $loadedFile = basename($real);
            break;
        }
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

// -----------------------------------------------------------------------------
// 6. INTEGRACJA Z GOOGLE GEMINI API (CURL)
// -----------------------------------------------------------------------------
$geminiApiKey = getenv('GEMINI_API_KEY');
if (!$geminiApiKey) {
    http_response_code(500);
    echo json_encode([
        'success' => false,
        'error'   => 'Błąd konfiguracji serwera: brak klucza GEMINI_API_KEY w środowisku.'
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

$geminiModel = getenv('GEMINI_MODEL') ?: 'gemini-1.5-flash';

// Budowa System Promptu zgodnie z wytycznymi RAG
$systemInstruction = "Jesteś oficjalnym asystentem na stronie {$siteId}. " .
                     "Odpowiadaj na pytania użytkowników WYŁĄCZNIE na podstawie poniższego kontekstu. " .
                     "Nie zmyślaj. Jeśli w kontekście nie ma odpowiedzi, odpowiedz grzecznie: 'Przepraszam, ale nie posiadam takich informacji w mojej bazie wiedzy. Zachęcam do bezpośredniego kontaktu z obsługą strony.' " .
                     "Odpowiadaj zwięźle, uprzejmie i w tym samym języku, w którym zadano pytanie.\n\n" .
                     "Kontekst wiedzy:\n" . $knowledgeContent;

$geminiPayload = [
    'system_instruction' => [
        'parts' => [
            ['text' => $systemInstruction]
        ]
    ],
    'contents' => [
        [
            'role'  => 'user',
            'parts' => [
                ['text' => $question]
            ]
        ]
    ],
    'generationConfig' => [
        'temperature'     => 0.2,
        'maxOutputTokens' => 800
    ]
];

$apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/{$geminiModel}:generateContent?key={$geminiApiKey}";

$curlOptions = [
    CURLOPT_URL            => $apiUrl,
    CURLOPT_POST           => true,
    CURLOPT_POSTFIELDS     => json_encode($geminiPayload, JSON_UNESCAPED_UNICODE),
    CURLOPT_HTTPHEADER     => [
        'Content-Type: application/json',
        'User-Agent: TwojaStronaWWW-AIRouter/1.0'
    ],
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT        => 25,
    CURLOPT_CONNECTTIMEOUT => 5,
    CURLOPT_SSL_VERIFYPEER => true,
    CURLOPT_SSL_VERIFYHOST => 2
];

// Automatyczna detekcja certyfikatów CA w środowisku lokalnym Windows
if (PHP_OS_FAMILY === 'Windows' && !ini_get('curl.cainfo')) {
    $windowsCaCandidates = [
        'C:/Program Files/Git/usr/ssl/certs/ca-bundle.crt',
        'C:/Program Files/Git/ucrt64/etc/ssl/certs/ca-bundle.crt',
        'C:/Program Files/Git/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem'
    ];
    foreach ($windowsCaCandidates as $caCandidate) {
        if (file_exists($caCandidate)) {
            $curlOptions[CURLOPT_CAINFO] = $caCandidate;
            break;
        }
    }
}

$ch = curl_init();
curl_setopt_array($ch, $curlOptions);

$responseBody = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$curlError = curl_error($ch);
curl_close($ch);

if ($responseBody === false || $curlError !== '') {
    http_response_code(502);
    echo json_encode([
        'success' => false,
        'error'   => 'Błąd komunikacji z modelem AI: ' . ($curlError ?: 'Nieznany błąd cURL.')
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

$geminiResponse = json_decode($responseBody, true);

if ($httpCode !== 200 || !is_array($geminiResponse)) {
    http_response_code(502);
    $apiErrorMessage = $geminiResponse['error']['message'] ?? 'Nieoczekiwana odpowiedź API Gemini.';
    echo json_encode([
        'success' => false,
        'error'   => 'Błąd Gemini API: ' . $apiErrorMessage
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// Ekstrakcja czystego tekstu odpowiedzi
$answer = $geminiResponse['candidates'][0]['content']['parts'][0]['text'] ?? null;

if ($answer === null || trim($answer) === '') {
    $finishReason = $geminiResponse['candidates'][0]['finishReason'] ?? 'UNKNOWN';
    $answer = ($finishReason === 'SAFETY')
        ? 'Przepraszam, zapytanie narusza zasady bezpieczeństwa treści.'
        : 'Przepraszam, nie udało się wygenerować odpowiedzi.';
}

// -----------------------------------------------------------------------------
// 7. CZYSTY ZWROT DANYCH DO FRONTENDU
// -----------------------------------------------------------------------------
http_response_code(200);
echo json_encode([
    'success' => true,
    'site_id' => $siteId,
    'answer'  => trim($answer)
], JSON_UNESCAPED_UNICODE);
