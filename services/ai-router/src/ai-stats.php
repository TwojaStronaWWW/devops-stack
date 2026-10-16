<?php
declare(strict_types=1);

/**
 * AI Router - moduł telemetrii, kontroli kaskady modeli i logowania.
 *
 * Funkcje:
 *  - trwałe liczniki (JSON w /app/storage/metrics/stats.json, flock) współdzielone
 *    przez wszystkie procesy PHP_CLI_SERVER_WORKERS,
 *  - cooldown (zawieszanie) modeli po błędach 429 / 5xx / 404 / auth,
 *  - strukturalne logi JSON na stderr (widoczne w `docker logs` i Dozzle),
 *  - renderowanie metryk Prometheus (/metrics).
 *
 * Bezpieczeństwo (ISO 27001): w logach i metrykach NIGDY nie ma treści pytań,
 * odpowiedzi, adresów IP ani kluczy API.
 */

const AI_STATS_COOLDOWN_MIN = 5;
const AI_STATS_COOLDOWN_MAX = 300;

/** Poprawny model startowy (korekta wycofanych modeli). */
function aiConfiguredModel(): string
{
    $model = trim((string)(getenv('GEMINI_MODEL') ?: 'gemini-3.8-flash'));
    if (in_array($model, ['', 'gemini-1.5-flash', 'gemini-1.5-pro', 'gemini-2.0-flash', 'gemini-2.5-flash', 'gemini-2.5-flash-lite'], true)) {
        $model = 'gemini-3.8-flash';
    }
    return $model;
}

/** Kaskada modeli Gemini w kolejności prób (osobna pula Free Tier na każdy model). */
function aiGeminiChain(string $configured): array
{
    return array_values(array_unique([
        'gemini-3.5-flash',
        $configured,
        'gemini-3.5-flash-lite',
        'gemini-3.7-flash',
        'gemini-3.8-flash',
        'gemma-4-31b-it',
    ]));
}

/** Pełna kaskada (z providerami) w kolejności prób - tylko aktywne providery. */
function aiFullChain(): array
{
    $chain = [];
    if ((getenv('GEMINI_API_KEY') ?: '') !== '') {
        foreach (aiGeminiChain(aiConfiguredModel()) as $m) {
            $chain[] = ['model' => $m, 'provider' => 'gemini'];
        }
    }
    if ((getenv('GROQ_API_KEY') ?: '') !== '') {
        $chain[] = ['model' => 'groq/' . (getenv('GROQ_MODEL') ?: 'openai/gpt-oss-120b'), 'provider' => 'groq'];
    }
    if ((getenv('OPENROUTER_API_KEY') ?: '') !== '') {
        $chain[] = ['model' => 'openrouter/' . (getenv('OPENROUTER_MODEL') ?: 'nvidia/nemotron-3-super-120b-a12b:free'), 'provider' => 'openrouter'];
    }
    return $chain;
}

function aiStatsFile(): string
{
    $base = is_dir('/app/storage') ? '/app/storage' : (dirname(__DIR__) . '/storage');
    $dir = $base . '/metrics';
    if (!is_dir($dir)) {
        @mkdir($dir, 0755, true);
    }
    return $dir . '/stats.json';
}

/** Doba kwotowa Gemini (reset RPD o północy czasu Pacyficznego). */
function aiQuotaDay(): string
{
    return (new DateTime('now', new DateTimeZone('America/Los_Angeles')))->format('Y-m-d');
}

function aiSecondsToQuotaReset(): int
{
    $tz = new DateTimeZone('America/Los_Angeles');
    $now = new DateTime('now', $tz);
    $reset = (new DateTime('tomorrow', $tz));
    return max(1, $reset->getTimestamp() - $now->getTimestamp());
}

function aiStatsDefault(): array
{
    return [
        'requests'    => [],  // "site|outcome" => n
        'cache_hits'  => [],  // site => n
        'req_lat_sum' => 0.0,
        'req_lat_cnt' => 0,
        'depth'       => [],  // pozycja modelu, który odpowiedział => n
        'models'      => [],  // model => dane
    ];
}

function aiModelDefault(string $provider): array
{
    return [
        'provider'        => $provider,
        'attempts'        => [],   // result => n
        'ok_lat_sum'      => 0.0,
        'ok_lat_cnt'      => 0,
        'today_day'       => aiQuotaDay(),
        'today_attempts'  => 0,
        'today_ok'        => 0,
        'last_ok'         => 0,
        'last_err'        => 0,
        'last_err_result' => '',
        'cooldown_until'  => 0,
        'skipped'         => 0,
    ];
}

/** Odczyt stanu (blokada współdzielona). */
function aiStatsRead(): array
{
    $file = aiStatsFile();
    $fp = @fopen($file, 'r');
    if (!$fp) {
        return aiStatsDefault();
    }
    flock($fp, LOCK_SH);
    $raw = stream_get_contents($fp);
    flock($fp, LOCK_UN);
    fclose($fp);
    $data = $raw ? json_decode($raw, true) : null;
    return is_array($data) ? array_replace(aiStatsDefault(), $data) : aiStatsDefault();
}

/** Atomowa modyfikacja stanu (blokada wyłączna). Błędy zapisu nie mogą zepsuć odpowiedzi czatu. */
function aiStatsMutate(callable $fn): void
{
    try {
        $fp = @fopen(aiStatsFile(), 'c+');
        if (!$fp) {
            return;
        }
        if (flock($fp, LOCK_EX)) {
            $raw = stream_get_contents($fp);
            $data = $raw ? json_decode($raw, true) : null;
            $data = is_array($data) ? array_replace(aiStatsDefault(), $data) : aiStatsDefault();
            $fn($data);
            ftruncate($fp, 0);
            rewind($fp);
            fwrite($fp, json_encode($data));
            fflush($fp);
            flock($fp, LOCK_UN);
        }
        fclose($fp);
    } catch (Throwable $e) {
        aiLog('stats_error', ['message' => $e->getMessage()]);
    }
}

/** Strukturalny log JSON (stderr -> docker logs / Dozzle). */
function aiLog(string $event, array $ctx = []): void
{
    error_log('ai-router ' . json_encode(
        ['event' => $event] + $ctx,
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
    ));
}

/**
 * Klasyfikacja wyniku nieudanej próby.
 * @return array{0:string,1:int} [result, cooldownSeconds]
 */
function aiClassify(int $httpCode, ?array $json, string $curlError, string $body = ''): array
{
    if ($curlError !== '' || $httpCode === 0) {
        return ['network', 120];
    }
    $blob = is_array($json) ? json_encode($json) : $body;
    $blob = is_string($blob) ? $blob : '';

    if ($httpCode === 429) {
        $hasRetryDelay = (bool)preg_match('/"retryDelay"\s*:\s*"(\d+)(?:\.\d+)?s"/', $blob, $m);
        $isPerMinute = stripos($blob, 'PerMinute') !== false || stripos($blob, 'per minute') !== false;
        if (!$hasRetryDelay && !$isPerMinute && (stripos($blob, 'PerDay') !== false || stripos($blob, 'RequestsPerDay') !== false)) {
            return ['quota_daily', min(aiSecondsToQuotaReset(), 900)];
        }
        $cd = $hasRetryDelay ? (int)$m[1] : 60;
        return ['rate_limited', max(AI_STATS_COOLDOWN_MIN, min(120, $cd))];
    }
    if ($httpCode === 404) {
        return ['not_found', 3600];
    }
    if ($httpCode === 401 || $httpCode === 403 || ($httpCode === 400 && stripos($blob, 'API_KEY_INVALID') !== false)) {
        return ['auth', 300];
    }
    if ($httpCode >= 500) {
        return ['unavailable', 120];
    }
    return ['other', 0];
}

/** Ile sekund model jest jeszcze zawieszony (0 = aktywny). */
function aiCooldownRemaining(array $stats, string $model): int
{
    $until = (int)($stats['models'][$model]['cooldown_until'] ?? 0);
    return max(0, $until - time());
}

/**
 * Rejestruje próbę użycia modelu.
 * $result: ok | empty | safety | rate_limited | quota_daily | unavailable | not_found | auth | network | other
 */
function aiRecordAttempt(string $provider, string $model, string $result, int $httpCode, float $latencyMs, int $cooldown = 0): void
{
    aiStatsMutate(function (array &$s) use ($provider, $model, $result, $httpCode, $latencyMs, $cooldown): void {
        if (!isset($s['models'][$model])) {
            $s['models'][$model] = aiModelDefault($provider);
        }
        $m = &$s['models'][$model];
        $day = aiQuotaDay();
        if (($m['today_day'] ?? '') !== $day) {
            $m['today_day'] = $day;
            $m['today_attempts'] = 0;
            $m['today_ok'] = 0;
        }
        $m['attempts'][$result] = (int)($m['attempts'][$result] ?? 0) + 1;
        if ($httpCode > 0) {
            $m['today_attempts']++; // żądanie dotarło do API dostawcy (zużywa pulę RPD)
        }
        if ($result === 'ok' || $result === 'safety') {
            $m['today_ok']++;
            $m['last_ok'] = time();
            $m['ok_lat_sum'] += $latencyMs / 1000;
            $m['ok_lat_cnt']++;
            $m['cooldown_until'] = 0;
        } else {
            $m['last_err'] = time();
            $m['last_err_result'] = $result;
            if ($cooldown > 0) {
                $m['cooldown_until'] = time() + $cooldown;
            }
        }
    });
    aiLog('attempt', [
        'provider' => $provider,
        'model'    => $model,
        'result'   => $result,
        'http'     => $httpCode,
        'ms'       => (int)round($latencyMs),
        'cooldown' => $cooldown,
    ]);
}

function aiRecordSkip(string $provider, string $model, int $remaining): void
{
    aiStatsMutate(function (array &$s) use ($provider, $model): void {
        if (!isset($s['models'][$model])) {
            $s['models'][$model] = aiModelDefault($provider);
        }
        $s['models'][$model]['skipped']++;
    });
    aiLog('skip_cooldown', ['provider' => $provider, 'model' => $model, 'remaining_s' => $remaining]);
}

function aiRecordCacheHit(string $site): void
{
    aiStatsMutate(function (array &$s) use ($site): void {
        $s['cache_hits'][$site] = (int)($s['cache_hits'][$site] ?? 0) + 1;
    });
    aiLog('cache_hit', ['site' => $site]);
}

/** Rejestruje wynik całego żądania czatu (wywoływane z shutdown function). */
function aiRecordRequest(string $site, string $outcome, int $httpCode, float $latencyMs, ?string $model, ?int $depth, int $attempts): void
{
    aiStatsMutate(function (array &$s) use ($site, $outcome, $latencyMs, $depth): void {
        $key = $site . '|' . $outcome;
        $s['requests'][$key] = (int)($s['requests'][$key] ?? 0) + 1;
        if ($outcome === 'success') {
            $s['req_lat_sum'] += $latencyMs / 1000;
            $s['req_lat_cnt']++;
            if ($depth !== null) {
                $s['depth'][(string)$depth] = (int)($s['depth'][(string)$depth] ?? 0) + 1;
            }
        }
    });
    aiLog('request', [
        'site'     => $site,
        'outcome'  => $outcome,
        'http'     => $httpCode,
        'model'    => $model,
        'depth'    => $depth,
        'attempts' => $attempts,
        'ms'       => (int)round($latencyMs),
    ]);
}

/** Limity dzienne z env: MODEL_DAILY_LIMITS="gemini-3.8-flash=500,gemma-4-31b-it=14400" (z domyślnymi progami Free Tier RPD). */
function aiDailyLimits(): array
{
    $out = [
        'gemini-3.8-flash'                                 => 500,
        'gemini-3.7-flash'                                 => 500,
        'gemini-3.5-flash'                                 => 500,
        'gemini-3.5-flash-lite'                            => 1500,
        'gemini-2.5-flash'                                 => 500,
        'gemini-2.5-flash-lite'                            => 1500,
        'gemini-3-flash-preview'                           => 500,
        'gemini-2.5-pro'                                   => 100,
        'gemma-4-31b-it'                                   => 14400,
        'gemma-3-27b-it'                                   => 14400,
        'groq/openai/gpt-oss-120b'                         => 1000,
        'openrouter/nvidia/nemotron-3-super-120b-a12b:free' => 200,
    ];
    foreach (explode(',', (string)(getenv('MODEL_DAILY_LIMITS') ?: '')) as $pair) {
        if (str_contains($pair, '=')) {
            [$k, $v] = explode('=', $pair, 2);
            if (trim($k) !== '' && ctype_digit(trim($v))) {
                $out[trim($k)] = (int)trim($v);
            }
        }
    }
    return $out;
}

function aiEsc(string $v): string
{
    return str_replace(['\\', '"', "\n"], ['\\\\', '\\"', '\\n'], $v);
}

/** Renderowanie metryk Prometheus (format 0.0.4). */
function aiRenderMetrics(): string
{
    $s = aiStatsRead();
    $now = time();
    $day = aiQuotaDay();
    $chain = aiFullChain();
    $limits = aiDailyLimits();
    $o = [];

    $o[] = '# HELP ai_router_status Status dostepnosci mikro-routera AI (1 = UP)';
    $o[] = '# TYPE ai_router_status gauge';
    $o[] = 'ai_router_status 1';
    foreach (['gemini' => 'GEMINI_API_KEY', 'groq' => 'GROQ_API_KEY', 'openrouter' => 'OPENROUTER_API_KEY'] as $prov => $env) {
        if ($prov === 'gemini') {
            $o[] = '# HELP ai_router_api_key_configured Czy klucz GEMINI_API_KEY jest skonfigurowany (1 = tak, 0 = nie)';
            $o[] = '# TYPE ai_router_api_key_configured gauge';
            $o[] = 'ai_router_api_key_configured ' . ((getenv($env) ?: '') !== '' ? 1 : 0);
            $o[] = '# HELP ai_router_provider_configured Czy klucz API providera jest skonfigurowany (1/0)';
            $o[] = '# TYPE ai_router_provider_configured gauge';
        }
        $o[] = 'ai_router_provider_configured{provider="' . $prov . '"} ' . ((getenv($env) ?: '') !== '' ? 1 : 0);
    }

    $o[] = '# HELP ai_router_model_info Kolejnosc modeli w kaskadzie (position 0 = pierwszy wybor)';
    $o[] = '# TYPE ai_router_model_info gauge';
    foreach ($chain as $i => $c) {
        $o[] = 'ai_router_model_info{model="' . aiEsc($c['model']) . '",provider="' . $c['provider'] . '",position="' . $i . '"} 1';
    }

    $o[] = '# HELP ai_router_requests_total Zadania czatu wg strony i wyniku';
    $o[] = '# TYPE ai_router_requests_total counter';
    foreach ($s['requests'] as $key => $n) {
        [$site, $outcome] = array_pad(explode('|', (string)$key, 2), 2, 'unknown');
        $o[] = 'ai_router_requests_total{site="' . aiEsc($site) . '",outcome="' . aiEsc($outcome) . '"} ' . (int)$n;
    }

    $o[] = '# HELP ai_router_cache_hits_total Odpowiedzi zwrocone z pamieci podrecznej RAG (0 tokenow API)';
    $o[] = '# TYPE ai_router_cache_hits_total counter';
    $cacheHitsMap = is_array($s['cache_hits'] ?? null) ? $s['cache_hits'] : [];
    foreach (['fuegolingua', 'katosalsahub', 'twojastronawww'] as $defaultSite) {
        if (!isset($cacheHitsMap[$defaultSite])) {
            $cacheHitsMap[$defaultSite] = 0;
        }
    }
    foreach ($cacheHitsMap as $cSite => $cCount) {
        $o[] = 'ai_router_cache_hits_total{site="' . aiEsc((string)$cSite) . '"} ' . (int)$cCount;
    }

    $o[] = '# HELP ai_router_request_duration_seconds Laczny czas udanych zadan czatu';
    $o[] = '# TYPE ai_router_request_duration_seconds summary';
    $o[] = 'ai_router_request_duration_seconds_sum ' . round((float)$s['req_lat_sum'], 3);
    $o[] = 'ai_router_request_duration_seconds_count ' . (int)$s['req_lat_cnt'];

    $o[] = '# HELP ai_router_answers_by_depth_total Ile odpowiedzi dal model z danej pozycji kaskady (0 = pierwszy, >0 = przelaczenie)';
    $o[] = '# TYPE ai_router_answers_by_depth_total counter';
    foreach ($s['depth'] as $d => $n) {
        $o[] = 'ai_router_answers_by_depth_total{depth="' . aiEsc((string)$d) . '"} ' . (int)$n;
    }

    // Definicje metryk per model: nazwa => [typ, opis]. Próbki grupowane pod jednym nagłówkiem HELP/TYPE.
    $meta = [
        'ai_router_model_attempts_total'                   => ['counter', 'Proby uzycia modelu wg wyniku'],
        'ai_router_model_skipped_total'                    => ['counter', 'Pominiecia modelu z powodu cooldownu'],
        'ai_router_model_suspended'                        => ['gauge', 'Czy model jest zawieszony (cooldown) 1/0'],
        'ai_router_model_cooldown_remaining_seconds'       => ['gauge', 'Pozostaly czas zawieszenia modelu'],
        'ai_router_model_requests_today'                   => ['gauge', 'Zadania do API modelu w biezacej dobie kwotowej (reset o polnocy czasu Pacyficznego)'],
        'ai_router_model_ok_today'                         => ['gauge', 'Udane odpowiedzi modelu w biezacej dobie kwotowej'],
        'ai_router_model_daily_limit'                      => ['gauge', 'Skonfigurowany limit dzienny (MODEL_DAILY_LIMITS), jesli podano'],
        'ai_router_model_ok_latency_seconds'               => ['summary', 'Czas udanych odpowiedzi modelu'],
        'ai_router_model_last_success_timestamp_seconds'   => ['gauge', 'Moment ostatniej udanej odpowiedzi'],
        'ai_router_model_last_error_timestamp_seconds'     => ['gauge', 'Moment ostatniego bledu'],
    ];
    $series = array_fill_keys(array_keys($meta), []);

    $providerOf = [];
    foreach ($chain as $c) {
        $providerOf[$c['model']] = $c['provider'];
    }

    $defaultResults = ['ok' => 0, 'rate_limited' => 0, 'quota_daily' => 0, 'unavailable' => 0, 'not_found' => 0, 'auth' => 0, 'network' => 0];
    $names = array_unique(array_merge(array_column($chain, 'model'), array_keys($s['models'])));
    foreach ($names as $name) {
        $name = (string)$name;
        $m = $s['models'][$name] ?? aiModelDefault($providerOf[$name] ?? 'unknown');
        $l = 'model="' . aiEsc($name) . '",provider="' . aiEsc((string)($providerOf[$name] ?? $m['provider'])) . '"';
        $attemptsMap = array_replace($defaultResults, is_array($m['attempts'] ?? null) ? $m['attempts'] : []);
        foreach ($attemptsMap as $res => $n) {
            $series['ai_router_model_attempts_total'][] = 'ai_router_model_attempts_total{' . $l . ',result="' . aiEsc((string)$res) . '"} ' . (int)$n;
        }
        $series['ai_router_model_skipped_total'][] = 'ai_router_model_skipped_total{' . $l . '} ' . (int)$m['skipped'];
        $rem = max(0, (int)$m['cooldown_until'] - $now);
        $series['ai_router_model_suspended'][] = 'ai_router_model_suspended{' . $l . '} ' . ($rem > 0 ? 1 : 0);
        $series['ai_router_model_cooldown_remaining_seconds'][] = 'ai_router_model_cooldown_remaining_seconds{' . $l . '} ' . $rem;
        $sameDay = ($m['today_day'] ?? '') === $day;
        $series['ai_router_model_requests_today'][] = 'ai_router_model_requests_today{' . $l . '} ' . ($sameDay ? (int)$m['today_attempts'] : 0);
        $series['ai_router_model_ok_today'][] = 'ai_router_model_ok_today{' . $l . '} ' . ($sameDay ? (int)$m['today_ok'] : 0);
        $limitVal = $limits[$name] ?? 500;
        $series['ai_router_model_daily_limit'][] = 'ai_router_model_daily_limit{' . $l . '} ' . (int)$limitVal;
        $series['ai_router_model_ok_latency_seconds'][] = 'ai_router_model_ok_latency_seconds_sum{' . $l . '} ' . round((float)$m['ok_lat_sum'], 3);
        $series['ai_router_model_ok_latency_seconds'][] = 'ai_router_model_ok_latency_seconds_count{' . $l . '} ' . (int)$m['ok_lat_cnt'];
        $series['ai_router_model_last_success_timestamp_seconds'][] = 'ai_router_model_last_success_timestamp_seconds{' . $l . '} ' . (int)$m['last_ok'];
        $series['ai_router_model_last_error_timestamp_seconds'][] = 'ai_router_model_last_error_timestamp_seconds{' . $l . '} ' . (int)$m['last_err'];
    }
    foreach ($meta as $metric => [$type, $help]) {
        $o[] = "# HELP {$metric} {$help}";
        $o[] = "# TYPE {$metric} {$type}";
        foreach ($series[$metric] as $line) {
            $o[] = $line;
        }
    }
    $dir = dirname(aiStatsFile(), 2) . '/rate_limits';
    $files = is_dir($dir) ? (glob($dir . '/*.json') ?: []) : [];
    $cacheDir = dirname(aiStatsFile(), 2) . '/cache';
    $cacheFiles = is_dir($cacheDir) ? (glob($cacheDir . '/*.json') ?: []) : [];
    $bytes = 0;
    foreach ($files as $f) {
        $bytes += (int)@filesize($f);
    }
    foreach ($cacheFiles as $cf) {
        $bytes += (int)@filesize($cf);
    }
    $bytes += (int)@filesize(aiStatsFile());
    $o[] = '# HELP ai_router_storage_bytes Rozmiar danych stanu routera (rate-limit + cache + statystyki)';
    $o[] = '# TYPE ai_router_storage_bytes gauge';
    $o[] = 'ai_router_storage_bytes ' . $bytes;
    $o[] = '# HELP ai_router_rate_limit_clients Liczba plikow rate-limit (unikalni klienci)';
    $o[] = '# TYPE ai_router_rate_limit_clients gauge';
    $o[] = 'ai_router_rate_limit_clients ' . count($files);
    $o[] = '# HELP ai_router_cache_entries Liczba zapisanych odpowiedzi w pamieci podrecznej RAG';
    $o[] = '# TYPE ai_router_cache_entries gauge';
    $o[] = 'ai_router_cache_entries ' . count($cacheFiles);

    return implode("\n", $o) . "\n";
}
