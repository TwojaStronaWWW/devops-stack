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
        'gemini-3.5-flash-lite',
        'gemini-3.7-flash',
        'gemini-3.8-flash',
        $configured,
        'gemma-4-31b-it',
    ]));
}

/** Kaskada modeli Groq LPU (osobna pula RPD na każdy model). */
function aiGroqChain(): array
{
    $primary = trim((string)(getenv('GROQ_MODEL') ?: 'openai/gpt-oss-120b'));
    return array_values(array_unique([
        $primary,
        'openai/gpt-oss-120b',
        'qwen/qwen3.8-27b',
    ]));
}

/** Kaskada modeli Cerebras Wafer-Scale Engine (osobna pula RPD na każdy model). */
function aiCerebrasChain(): array
{
    $primary = trim((string)(getenv('CEREBRAS_MODEL') ?: 'gpt-oss-120b'));
    return array_values(array_unique([
        $primary,
        'gpt-oss-120b',
        'qwen-3.8-27b',
    ]));
}

/**
 * Kaskada darmowych modeli OpenRouter (:free).
 * Model specjalistyczny SQL/Code (cohere/north-mini-code:free) jest włączany WYŁĄCZNIE dla zapytań SQL w Asystencie AMMS.
 */
function aiOpenRouterChain(bool $includeAmmsSql = false): array
{
    $primary = trim((string)(getenv('OPENROUTER_MODEL') ?: 'nvidia/nemotron-3-super-120b-a12b:free'));
    $models = [];
    if ($includeAmmsSql) {
        $models[] = 'cohere/north-mini-code:free';
    }
    $models[] = $primary;
    $models[] = 'nvidia/nemotron-3-super-120b-a12b:free';
    $models[] = 'nvidia/nemotron-3-ultra-550b-a55b:free';
    return array_values(array_unique($models));
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
        foreach (aiGroqChain() as $gm) {
            $chain[] = ['model' => 'groq/' . $gm, 'provider' => 'groq'];
        }
    }
    if ((getenv('CEREBRAS_API_KEY') ?: '') !== '') {
        foreach (aiCerebrasChain() as $cm) {
            $chain[] = ['model' => 'cerebras/' . $cm, 'provider' => 'cerebras'];
        }
    }
    if ((getenv('MISTRAL_API_KEY') ?: '') !== '') {
        $sqlModel = trim((string)(getenv('MISTRAL_SQL_MODEL') ?: 'codestral-latest'));
        $chain[] = ['model' => 'mistral/' . $sqlModel, 'provider' => 'mistral', 'amms_sql_only' => true];
    }
    if ((getenv('CF_AI_API_TOKEN') ?: '') !== '' && (getenv('CF_ACCOUNT_ID') ?: '') !== '') {
        $chain[] = ['model' => 'cloudflare/' . (getenv('CF_AI_MODEL') ?: '@cf/meta/llama-3.3-70b-instruct-fp8-fast'), 'provider' => 'cloudflare'];
    }
    if ((getenv('OPENROUTER_API_KEY') ?: '') !== '') {
        foreach (aiOpenRouterChain(true) as $orm) {
            $chain[] = [
                'model'         => 'openrouter/' . $orm,
                'provider'      => 'openrouter',
                'amms_sql_only' => ($orm === 'cohere/north-mini-code:free'),
            ];
        }
    }
    if ((getenv('ANTHROPIC_API_KEY') ?: '') !== '') {
        $chain[] = ['model' => 'anthropic/' . (getenv('ANTHROPIC_MODEL') ?: 'claude-haiku-4-5'), 'provider' => 'anthropic'];
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

/** Doba analityczna dla polskich serwisów WWW (reset o północy czasu Europe/Warsaw). */
function aiAnalyticsDay(): string
{
    return (new DateTime('now', new DateTimeZone('Europe/Warsaw')))->format('Y-m-d');
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
        'requests'      => [],  // "site|outcome" => n
        'cache_hits'    => [],  // site => n
        'leads'         => [],  // "site|type" => n (contact | hot_lead)
        'req_lat_sum'   => 0.0,
        'req_lat_cnt'   => 0,
        'depth'         => [],  // pozycja modelu, który odpowiedział => n
        'models'        => [],  // model => dane
        'web_analytics' => [
            'day'                   => '',
            'pageviews'             => [], // "site|path" => n
            'sources'               => [], // "site|source" => n
            'devices'               => [], // "site|device" => n
            'countries'             => [], // "site|country" => n
            'search_terms'          => [], // "site|term" => n
            'unique_visitors'       => [], // site => [hash => 1]
            'unique_visitors_total' => [], // site => n (monotoniczny counter unikalnych wizyt dziennych)
            'events'                => [], // "site|event" => n (konwersje CTA, otwarcia czatu, radio, itp.)
            'engaged_visits'        => [], // site => n (sesje zaangażowane >= 15s)
            'lcp_sum_ms'            => [], // site => suma czasów LCP (Core Web Vitals) w ms
            'lcp_cnt'               => [], // site => liczba pomiarów LCP
            'ai_topics'             => [], // "site|topic" => n (automatyczna ekstrakcja tematów z pytań AI, Zero-PII)
            'gsc_keywords'          => [], // site => lista wierszy z Google Search Console API (query, clicks, impressions, position)
        ],
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
    if ($httpCode === 400 && stripos($blob, 'credit balance is too low') !== false) {
        return ['quota_daily', 3600];
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

function aiRecordLead(string $site, string $type): void
{
    aiStatsMutate(function (array &$s) use ($site, $type): void {
        if (!isset($s['leads']) || !is_array($s['leads'])) {
            $s['leads'] = [];
        }
        $key = $site . '|' . $type;
        $s['leads'][$key] = (int)($s['leads'][$key] ?? 0) + 1;
    });
}

/**
 * Inkrementuje licznik w słowniku z ochroną przed zatruciem kardynalności (Cardinality Poisoning).
 * Gdy słownik osiągnie $maxSize, wypycha najstarszy wpis o najniższym liczniku (LFU/LRU).
 */
function aiBoundedIncrement(array &$map, string $key, int $maxSize): void
{
    if (isset($map[$key])) {
        $map[$key] = (int)$map[$key] + 1;
        return;
    }
    if (count($map) >= $maxSize) {
        $victimKey = null;
        $minVal = PHP_INT_MAX;
        foreach ($map as $k => $v) {
            $iv = (int)$v;
            if ($iv < $minVal) {
                $minVal = $iv;
                $victimKey = $k;
                if ($iv <= 1) {
                    break;
                }
            }
        }
        if ($victimKey !== null) {
            unset($map[$victimKey]);
        }
    }
    $map[$key] = 1;
}

/**
 * Rejestruje zdarzenie bezciasteczkowej analityki ruchu WWW (Cookieless RODO / Zero-PII).
 */
function aiRecordWebAnalytics(
    string $site,
    string $eventType,
    string $path,
    string $source,
    string $device,
    string $country,
    string $visitorHash,
    string $searchTerm = '',
    string $eventName = '',
    float $lcpMs = 0.0
): void {
    aiStatsMutate(function (array &$s) use ($site, $eventType, $path, $source, $device, $country, $visitorHash, $searchTerm, $eventName, $lcpMs): void {
        if (!isset($s['web_analytics']) || !is_array($s['web_analytics'])) {
            $s['web_analytics'] = aiStatsDefault()['web_analytics'];
        }
        $wa = &$s['web_analytics'];
        $today = aiAnalyticsDay();
        if (($wa['day'] ?? '') !== $today) {
            $wa['day'] = $today;
            $wa['unique_visitors'] = [];
        }

        if ($visitorHash !== '') {
            if (!isset($wa['unique_visitors'][$site]) || !is_array($wa['unique_visitors'][$site])) {
                $wa['unique_visitors'][$site] = [];
            }
            if (!isset($wa['unique_visitors'][$site][$visitorHash]) && count($wa['unique_visitors'][$site]) < 5000) {
                $wa['unique_visitors'][$site][$visitorHash] = 1;
                $wa['unique_visitors_total'] = is_array($wa['unique_visitors_total'] ?? null) ? $wa['unique_visitors_total'] : [];
                $wa['unique_visitors_total'][$site] = (int)($wa['unique_visitors_total'][$site] ?? 0) + 1;
            }
        }

        if ($lcpMs >= 50.0 && $lcpMs <= 30000.0) {
            $wa['lcp_sum_ms'] = is_array($wa['lcp_sum_ms'] ?? null) ? $wa['lcp_sum_ms'] : [];
            $wa['lcp_cnt'] = is_array($wa['lcp_cnt'] ?? null) ? $wa['lcp_cnt'] : [];
            $wa['lcp_sum_ms'][$site] = (float)($wa['lcp_sum_ms'][$site] ?? 0.0) + $lcpMs;
            $wa['lcp_cnt'][$site] = (int)($wa['lcp_cnt'][$site] ?? 0) + 1;
        }

        if ($eventType === 'search' && $searchTerm !== '') {
            $wa['search_terms'] = is_array($wa['search_terms'] ?? null) ? $wa['search_terms'] : [];
            aiBoundedIncrement($wa['search_terms'], $site . '|' . $searchTerm, 80);
            return;
        }

        if ($eventType === 'engaged') {
            $wa['engaged_visits'] = is_array($wa['engaged_visits'] ?? null) ? $wa['engaged_visits'] : [];
            $wa['engaged_visits'][$site] = (int)($wa['engaged_visits'][$site] ?? 0) + 1;
            return;
        }

        if ($eventType === 'event' && $eventName !== '') {
            $wa['events'] = is_array($wa['events'] ?? null) ? $wa['events'] : [];
            aiBoundedIncrement($wa['events'], $site . '|' . $eventName, 60);
            return;
        }

        $wa['pageviews'] = is_array($wa['pageviews'] ?? null) ? $wa['pageviews'] : [];
        aiBoundedIncrement($wa['pageviews'], $site . '|' . $path, 60);

        $wa['sources'] = is_array($wa['sources'] ?? null) ? $wa['sources'] : [];
        $sKey = $site . '|' . $source;
        $wa['sources'][$sKey] = (int)($wa['sources'][$sKey] ?? 0) + 1;

        $wa['devices'] = is_array($wa['devices'] ?? null) ? $wa['devices'] : [];
        $dKey = $site . '|' . $device;
        $wa['devices'][$dKey] = (int)($wa['devices'][$dKey] ?? 0) + 1;

        $wa['countries'] = is_array($wa['countries'] ?? null) ? $wa['countries'] : [];
        aiBoundedIncrement($wa['countries'], $site . '|' . $country, 40);
    });
}

/**
 * Automatyczna, deterministyczna ekstrakcja tematów i słów kluczowych z pytań do czatbota AI (100% Zero-PII).
 * Klasyfikuje pytanie wyłącznie do kanonicznych pojęć ze słownika domenowego (nigdy nie zapisuje surowego tekstu ani PII).
 */
function aiExtractAndRecordTopics(string $site, string $question, bool $hasContactLead = false): void
{
    $asciiMap = [
        'ą' => 'a', 'ć' => 'c', 'ę' => 'e', 'ł' => 'l', 'ń' => 'n', 'ó' => 'o', 'ś' => 's', 'ź' => 'z', 'ż' => 'z',
        'á' => 'a', 'é' => 'e', 'í' => 'i', 'ó' => 'o', 'ú' => 'u', 'ü' => 'u', 'ñ' => 'n',
    ];
    $qNorm = strtr(mb_strtolower($question), $asciiMap);

    // Słownik reguł: [kod_tematu, regex_dopasowania, opcjonalna_kanoniczna_fraza_do_search_terms]
    $rules = [
        ['salsopedia',    '/\b(salsopedi|hasl[oa]|slownik|definicj)/u',                           '🤖 AI: salsopedia'],
        ['figures',       '/\b(enchufl|dile\s*que\s*no|guapea|vacilala|setenta|sombrero|exhibel)/u', '🤖 AI: enchufla / dile que no'],
        ['rueda',         '/\b(rued[ay]|casino|cantante|komend)/u',                               '🤖 AI: rueda de casino'],
        ['music_clave',   '/\b(timb[ay]|clave|cong[ai]|bongo|muzyk|rytm|instrument)/u',           '🤖 AI: muzyka salsa / clave'],
        ['dance_styles',  '/\b(bachat|kizomb|cuban|liniow|on1|on2|styl\b|style\b)/u',             '🤖 AI: style tańca (salsa/bachata)'],
        ['radio',         '/\b(radi[ou]|timba\s*nation|slucha)/u',                                '🤖 AI: radio salsa'],
        ['events_party',  '/\b(potancow|imprez|wydarzen|gdzie\s*tancz|party)/u',                  '🤖 AI: gdzie tańczymy / potańcówki'],
        ['schools',       '/\b(szkol[ay]|instruktor|katowic|slask)/u',                            '🤖 AI: szkoły tańca katowice'],
        ['spanish_trial', '/\b(probn[ae]|darmow[ae]\s*lekcj|pierwsz[ae]\s*lekcj)/u',              '🤖 AI: bezpłatna lekcja próbna'],
        ['spanish_course','/\b(hiszpan|kurs|lekcj|nauk[ai]\s*jezyk|dele\b|siele\b)/u',            '🤖 AI: kurs hiszpańskiego'],
        ['spanish_mode',  '/\b(indywidual|grupow|1\s*na\s*1|konwersacj)/u',                       '🤖 AI: zajęcia indywidualne vs grupowe'],
        ['spanish_biz',   '/\b(biznes|branzow|firm|korporac)/u',                                  '🤖 AI: hiszpański w biznesie'],
        ['code_vs_wp',    '/\b(wordpress|czysty\s*kod|szybkos|pagespeed|lighthouse|szablon)/u',   '🤖 AI: kod zamiast wordpressa'],
        ['ai_rag_bot',    '/\b(czatbot|chatbot|rag\b|wirtualn\w*\s*doradc|wdrozen\w*\s*ai)/u',    '🤖 AI: wdrożenie czatbota ai (rag)'],
        ['seo_google',    '/\b(seo\b|pozycjon|widocznos\w*\s*w\s*google)/u',                      '🤖 AI: pozycjonowanie seo'],
        ['pricing',       '/\b(cen[ay]|cennik|koszt|ile\s*kosztuj|wycen|pakiet|stawk)/u',         '🤖 AI: cennik i koszty'],
        ['cooperation',   '/\b(wspolprac|jak\s*wyglada|czas\s*realizac|umow\b|zapis[ay])/u',      '🤖 AI: jak wygląda współpraca'],
    ];

    $matchedTopics = [];
    $matchedCanonicalTerms = [];

    if ($hasContactLead) {
        $matchedTopics[] = 'contact_lead';
    }

    foreach ($rules as [$topicCode, $pattern, $canonicalTerm]) {
        if (preg_match($pattern, $qNorm)) {
            $matchedTopics[] = $topicCode;
            if ($canonicalTerm !== '') {
                $matchedCanonicalTerms[] = $canonicalTerm;
            }
        }
    }

    if (empty($matchedTopics)) {
        $matchedTopics[] = 'general_inquiry';
    }

    $matchedTopics = array_slice(array_values(array_unique($matchedTopics)), 0, 3);
    $matchedCanonicalTerms = array_slice(array_values(array_unique($matchedCanonicalTerms)), 0, 2);

    aiStatsMutate(function (array &$s) use ($site, $matchedTopics, $matchedCanonicalTerms): void {
        if (!isset($s['web_analytics']) || !is_array($s['web_analytics'])) {
            $s['web_analytics'] = aiStatsDefault()['web_analytics'];
        }
        $wa = &$s['web_analytics'];
        $wa['ai_topics'] = is_array($wa['ai_topics'] ?? null) ? $wa['ai_topics'] : [];
        foreach ($matchedTopics as $tCode) {
            aiBoundedIncrement($wa['ai_topics'], $site . '|' . $tCode, 60);
        }
        $wa['search_terms'] = is_array($wa['search_terms'] ?? null) ? $wa['search_terms'] : [];
        foreach ($matchedCanonicalTerms as $cTerm) {
            aiBoundedIncrement($wa['search_terms'], $site . '|' . $cTerm, 80);
        }
    });
}

/**
 * Zapisuje zaimportowane słowa kluczowe SEO z Google Search Console API dla danego serwisu.
 */
function aiRecordGscKeywords(string $site, array $rows): void
{
    $cleanRows = [];
    foreach ($rows as $r) {
        if (!is_array($r)) continue;
        $rawQuery = trim((string)($r['query'] ?? ''));
        $q = mb_substr(trim((string)preg_replace('/[^a-ząćęłńóśźżáéíóúüñ0-9 _-]/iu', '', mb_strtolower($rawQuery))), 0, 48);
        if (mb_strlen($q) < 2) continue;
        $cleanRows[] = [
            'query'       => $q,
            'clicks'      => max(0, (int)($r['clicks'] ?? 0)),
            'impressions' => max(0, (int)($r['impressions'] ?? 0)),
            'position'    => round(max(1.0, (float)($r['position'] ?? 1.0)), 1),
        ];
        if (count($cleanRows) >= 30) break;
    }

    aiStatsMutate(function (array &$s) use ($site, $cleanRows): void {
        if (!isset($s['web_analytics']) || !is_array($s['web_analytics'])) {
            $s['web_analytics'] = aiStatsDefault()['web_analytics'];
        }
        $wa = &$s['web_analytics'];
        $wa['gsc_keywords'] = is_array($wa['gsc_keywords'] ?? null) ? $wa['gsc_keywords'] : [];
        $wa['gsc_keywords'][$site] = $cleanRows;
    });
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
        'groq/qwen/qwen3.8-27b'                            => 1000,
        'cerebras/gpt-oss-120b'                            => 2400,
        'cerebras/qwen-3.8-27b'                            => 648000,
        'mistral/codestral-latest'                         => 1500,
        'cloudflare/@cf/meta/llama-3.3-70b-instruct-fp8-fast' => 1000,
        'openrouter/cohere/north-mini-code:free'           => 200,
        'openrouter/nvidia/nemotron-3-super-120b-a12b:free' => 200,
        'openrouter/nvidia/nemotron-3-ultra-550b-a55b:free' => 200,
        'anthropic/claude-haiku-4-5'                       => 1000,
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

/** Czytelna nazwa pozycji i modelu w kaskadzie (np. "#1 Gemini 3.5 Flash") dla Grafany i raportów CLI. */
function aiReadableSourceLabel(int $pos, string $model): string
{
    $num = $pos + 1;
    $map = [
        'gemini-3.5-flash'                                    => 'Gemini 3.5 Flash',
        'gemini-3.5-flash-lite'                               => 'Gemini 3.5 Lite',
        'gemini-3.7-flash'                                    => 'Gemini 3.7 Flash',
        'gemini-3.8-flash'                                    => 'Gemini 3.8 Flash',
        'gemma-4-31b-it'                                      => 'Gemma 4 31B',
        'groq/openai/gpt-oss-120b'                            => 'Groq GPT-120B',
        'groq/qwen/qwen3.8-27b'                               => 'Groq Qwen 3.8 27B',
        'cerebras/gpt-oss-120b'                               => 'Cerebras 120B',
        'cerebras/qwen-3.8-27b'                               => 'Cerebras Qwen 27B',
        'mistral/codestral-latest'                            => 'Codestral SQL (AMMS)',
        'cloudflare/@cf/meta/llama-3.3-70b-instruct-fp8-fast' => 'CF Llama 3.3 70B',
        'openrouter/cohere/north-mini-code:free'              => 'Cohere Code SQL (AMMS)',
        'openrouter/nvidia/nemotron-3-super-120b-a12b:free'   => 'Nemotron 120B',
        'openrouter/nvidia/nemotron-3-ultra-550b-a55b:free'   => 'Nemotron Ultra 550B',
        'anthropic/claude-haiku-4-5'                          => 'Claude Haiku 4.5',
    ];
    $short = $map[$model] ?? $model;
    return '#' . $num . ' ' . $short;
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
    foreach (['gemini' => 'GEMINI_API_KEY', 'groq' => 'GROQ_API_KEY', 'cerebras' => 'CEREBRAS_API_KEY', 'mistral' => 'MISTRAL_API_KEY', 'cloudflare' => 'CF_AI_API_TOKEN', 'openrouter' => 'OPENROUTER_API_KEY', 'anthropic' => 'ANTHROPIC_API_KEY'] as $prov => $env) {
        if ($prov === 'gemini') {
            $o[] = '# HELP ai_router_api_key_configured Czy klucz GEMINI_API_KEY jest skonfigurowany (1 = tak, 0 = nie)';
            $o[] = '# TYPE ai_router_api_key_configured gauge';
            $o[] = 'ai_router_api_key_configured ' . ((getenv($env) ?: '') !== '' ? 1 : 0);
            $o[] = '# HELP ai_router_provider_configured Czy klucz API providera jest skonfigurowany (1/0)';
            $o[] = '# TYPE ai_router_provider_configured gauge';
        }
        if ($prov === 'mistral' && (getenv($env) ?: '') === '') {
            continue;
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
    $reqMap = is_array($s['requests'] ?? null) ? $s['requests'] : [];
    foreach (['amms', 'katosalsahub', 'dancepuls', 'raricart', 'fuegolingua', 'twojastronawww'] as $defaultSite) {
        if (!isset($reqMap[$defaultSite . '|success'])) {
            $reqMap[$defaultSite . '|success'] = 0;
        }
    }
    foreach ($reqMap as $key => $n) {
        [$site, $outcome] = array_pad(explode('|', (string)$key, 2), 2, 'unknown');
        $o[] = 'ai_router_requests_total{site="' . aiEsc($site) . '",outcome="' . aiEsc($outcome) . '"} ' . (int)$n;
    }

    $o[] = '# HELP ai_router_cache_hits_total Odpowiedzi zwrocone z pamieci podrecznej RAG (0 tokenow API)';
    $o[] = '# TYPE ai_router_cache_hits_total counter';
    $cacheHitsMap = is_array($s['cache_hits'] ?? null) ? $s['cache_hits'] : [];
    foreach (['amms', 'fuegolingua', 'katosalsahub', 'twojastronawww', 'raricart', 'dancepuls'] as $defaultSite) {
        if (!isset($cacheHitsMap[$defaultSite])) {
            $cacheHitsMap[$defaultSite] = 0;
        }
    }
    foreach ($cacheHitsMap as $cSite => $cCount) {
        $o[] = 'ai_router_cache_hits_total{site="' . aiEsc((string)$cSite) . '"} ' . (int)$cCount;
    }

    $o[] = '# HELP ai_router_leads_total Pozyskane leady kontaktowe i zaangazowane sesje czatu (Zero-PII)';
    $o[] = '# TYPE ai_router_leads_total counter';
    $leadsMap = is_array($s['leads'] ?? null) ? $s['leads'] : [];
    foreach (['fuegolingua', 'katosalsahub', 'twojastronawww', 'raricart', 'dancepuls'] as $defaultSite) {
        foreach (['contact', 'hot_lead'] as $lType) {
            $lKey = $defaultSite . '|' . $lType;
            if (!isset($leadsMap[$lKey])) {
                $leadsMap[$lKey] = 0;
            }
        }
    }
    foreach ($leadsMap as $lKey => $lCount) {
        [$lSite, $lType] = array_pad(explode('|', (string)$lKey, 2), 2, 'contact');
        $o[] = 'ai_router_leads_total{site="' . aiEsc($lSite) . '",type="' . aiEsc($lType) . '"} ' . (int)$lCount;
    }

    $o[] = '# HELP ai_router_request_duration_seconds Laczny czas udanych zadan czatu';
    $o[] = '# TYPE ai_router_request_duration_seconds summary';
    $o[] = 'ai_router_request_duration_seconds_sum ' . round((float)$s['req_lat_sum'], 3);
    $o[] = 'ai_router_request_duration_seconds_count ' . (int)$s['req_lat_cnt'];

    $o[] = '# HELP ai_router_answers_by_depth_total Ile odpowiedzi dal model z danej pozycji kaskady (0 = pierwszy, >0 = przelaczenie)';
    $o[] = '# TYPE ai_router_answers_by_depth_total counter';
    foreach ($chain as $idx => $c) {
        $mName = $c['model'];
        $mOk = (int)($s['models'][$mName]['attempts']['ok'] ?? 0) + (int)($s['models'][$mName]['attempts']['safety'] ?? 0);
        $sourceLabel = aiReadableSourceLabel($idx, $mName);
        $o[] = 'ai_router_answers_by_depth_total{depth="' . $idx . '",model="' . aiEsc($mName) . '",source="' . aiEsc($sourceLabel) . '"} ' . $mOk;
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

    // Telemetria Asystenta Eksperckiego AMMS & Oracle DBA (Dual-Stream SQLite FTS5 RAG)
    $dataBaseDir = is_dir('/app/data') ? '/app/data' : (dirname(__DIR__) . '/data');
    $ammsSqliteFile = $dataBaseDir . '/amms-knowledge.sqlite';
    $ammsSqliteExists = is_file($ammsSqliteFile);
    $ammsSqliteBytes = $ammsSqliteExists ? (int)@filesize($ammsSqliteFile) : 0;
    $o[] = '# HELP ai_router_amms_sqlite_status Status bazy wiedzy SQLite FTS5 Asystenta AMMS & Oracle DBA (1 = aktywna, 0 = brak)';
    $o[] = '# TYPE ai_router_amms_sqlite_status gauge';
    $o[] = 'ai_router_amms_sqlite_status ' . ($ammsSqliteBytes > 1000000 ? 1 : 0);
    $o[] = '# HELP ai_router_amms_sqlite_size_bytes Rozmiar bazy wiedzy SQLite FTS5 Asystenta AMMS w bajtach';
    $o[] = '# TYPE ai_router_amms_sqlite_size_bytes gauge';
    $o[] = 'ai_router_amms_sqlite_size_bytes ' . $ammsSqliteBytes;
    $o[] = '# HELP ai_router_amms_chunks_total Liczba zindeksowanych fragmentow wiedzy BM25 (314 PDF + 69 plikow bazy Oracle)';
    $o[] = '# TYPE ai_router_amms_chunks_total gauge';
    $o[] = 'ai_router_amms_chunks_total ' . ($ammsSqliteBytes > 1000000 ? 25227 : 0);
    $o[] = '# HELP ai_router_amms_pages_total Liczba stron dokumentacji AMMS ze zrzutami wizualnymi WebP';
    $o[] = '# TYPE ai_router_amms_pages_total gauge';
    $o[] = 'ai_router_amms_pages_total ' . ($ammsSqliteBytes > 1000000 ? 12291 : 0);

    // Bezciasteczkowa Analityka Ruchu WWW (Cookieless RODO / Zero-PII)
    $wa = is_array($s['web_analytics'] ?? null) ? $s['web_analytics'] : [];
    $waSameDay = (($wa['day'] ?? '') === aiAnalyticsDay());
    $knownSites = ['katosalsahub', 'dancepuls', 'fuegolingua', 'twojastronawww', 'raricart'];

    $o[] = '# HELP web_analytics_unique_visitors_today Unikalni odwiedzajacy dzis wg anonimowego skrotu SHA-256 (Cookieless RODO, Europe/Warsaw)';
    $o[] = '# TYPE web_analytics_unique_visitors_today gauge';
    $uvMap = ($waSameDay && is_array($wa['unique_visitors'] ?? null)) ? $wa['unique_visitors'] : [];
    foreach ($knownSites as $defSite) {
        $uvCount = isset($uvMap[$defSite]) && is_array($uvMap[$defSite]) ? count($uvMap[$defSite]) : 0;
        $o[] = 'web_analytics_unique_visitors_today{site="' . aiEsc($defSite) . '"} ' . $uvCount;
    }

    $o[] = '# HELP web_analytics_unique_visitors_total Laczna historyczna liczba unikalnych dziennych wizyt wg strony (Cookieless counter)';
    $o[] = '# TYPE web_analytics_unique_visitors_total counter';
    $uvTotalMap = is_array($wa['unique_visitors_total'] ?? null) ? $wa['unique_visitors_total'] : [];
    foreach ($knownSites as $defSite) {
        $uvTodayFallback = isset($uvMap[$defSite]) && is_array($uvMap[$defSite]) ? count($uvMap[$defSite]) : 0;
        $uvTotalVal = max((int)($uvTotalMap[$defSite] ?? 0), $uvTodayFallback);
        $o[] = 'web_analytics_unique_visitors_total{site="' . aiEsc($defSite) . '"} ' . $uvTotalVal;
    }

    $o[] = '# HELP web_analytics_engaged_visits_total Liczba zaangazowanych sesji uzytkownikow (aktywnosc >= 15s na stronie)';
    $o[] = '# TYPE web_analytics_engaged_visits_total counter';
    $engMap = is_array($wa['engaged_visits'] ?? null) ? $wa['engaged_visits'] : [];
    foreach ($knownSites as $defSite) {
        $o[] = 'web_analytics_engaged_visits_total{site="' . aiEsc($defSite) . '"} ' . (int)($engMap[$defSite] ?? 0);
    }

    $o[] = '# HELP web_analytics_pageviews_total Laczna liczba odslon podstron i sekcji SPA (Cookieless)';
    $o[] = '# TYPE web_analytics_pageviews_total counter';
    $pvMap = is_array($wa['pageviews'] ?? null) ? $wa['pageviews'] : [];
    foreach (['katosalsahub|/', 'katosalsahub|/salsopedia.html', 'katosalsahub|/grafik.html', 'dancepuls|/', 'fuegolingua|/', 'fuegolingua|/cennik.html', 'twojastronawww|/', 'twojastronawww|/jak-pracuje.html', 'raricart|/', 'raricart|/pakiety'] as $defPv) {
        if (!isset($pvMap[$defPv])) {
            $pvMap[$defPv] = 0;
        }
    }
    $pathLabels = [
        '/'                => '🏠 / (Strona główna)',
        '/salsopedia.html' => '📖 /salsopedia.html (Słownik 179 haseł)',
        '/grafik.html'     => '📅 /grafik.html (Wspólny Grafik Szkół Tańca)',
        '/jak-pracuje.html'=> '⚙️ /jak-pracuje.html (Proces współpracy i SLA)',
        '/cennik.html'     => '💰 /cennik.html (Cennik kursów FuegoLingua)',
        '/privacy.html'    => '🔒 /privacy.html (Polityka prywatności)',
        '/pakiety'         => '🍽️ /pakiety (Pakiety i wycena Raricart)',
        '/pakiety.php'     => '🍽️ /pakiety.php (Pakiety i wycena Raricart)',
        '/polityka-prywatnosci'     => '🔒 /polityka-prywatnosci (Polityka prywatności)',
        '/polityka-prywatnosci.php' => '🔒 /polityka-prywatnosci.php (Polityka prywatności)',
        '/#onas'           => '👨‍🍳 /#onas (O Nas)',
        '/#oferta'         => '🥂 /#oferta (Oferta i stacje Live Food)',
        '/#realizacje'     => '📸 /#realizacje (Galeria realizacji)',
        '/#szkoly'         => '🎓 /#szkoly (Szkoły tańca)',
        '/#wydarzenia'     => '🎉 /#wydarzenia (Wydarzenia i imprezy)',
        '/#radio'          => '📻 /#radio (Radio Salsa)',
        '/#mapa'           => '🗺️ /#mapa (Mapa szkół i klubów)',
        '/#style'          => '💃 /#style (Style taneczne)',
        '/#artykuly'       => '📰 /#artykuly (Artykuły i poradniki)',
        '/#slownik'        => '📚 /#slownik (Sekcja słownika)',
        '/#faq'            => '❓ /#faq (Pytania FAQ)',
        '/#cennik'         => '💰 /#cennik (Oferta i cennik)',
        '/#pricing'        => '💰 /#pricing (Pakiety i cennik)',
        '/#portfolio'      => '🚀 /#portfolio (Realizacje i wdrożenia)',
        '/#contact'        => '📞 /#contact (Formularz wyceny)',
        '/#kontakt'        => '📞 /#kontakt (Sekcja kontaktu)',
        '/#kursy'          => '🇪🇸 /#kursy (Kursy językowe)',
    ];
    foreach ($pvMap as $pvKey => $pvCount) {
        [$pvSite, $pvPath] = array_pad(explode('|', (string)$pvKey, 2), 2, '/');
        $pvLabel = $pathLabels[$pvPath] ?? ('📄 ' . $pvPath);
        $o[] = 'web_analytics_pageviews_total{site="' . aiEsc($pvSite) . '",path="' . aiEsc($pvPath) . '",label="' . aiEsc($pvLabel) . '"} ' . (int)$pvCount;
    }

    $o[] = '# HELP web_analytics_sources_total Zrodla wejsc uzytkownikow (Google, AI Search, Facebook, Instagram, TikTok, Direct, Inne)';
    $o[] = '# TYPE web_analytics_sources_total counter';
    $srcMap = is_array($wa['sources'] ?? null) ? $wa['sources'] : [];
    foreach ($knownSites as $defSite) {
        foreach (['direct', 'google', 'ai_search', 'facebook', 'instagram'] as $defSrc) {
            $sKey = $defSite . '|' . $defSrc;
            if (!isset($srcMap[$sKey])) {
                $srcMap[$sKey] = 0;
            }
        }
    }
    $sourceLabels = [
        'direct'     => '🔗 Bezpośrednie (wpisany adres / zakładka / Messenger)',
        'google'     => '🔍 Google (wyszukiwarka SEO)',
        'ai_search'  => '🤖 AI Search (ChatGPT / Perplexity / Claude / Gemini)',
        'facebook'   => '📘 Facebook',
        'instagram'  => '📸 Instagram',
        'bing'       => '🔍 Bing',
        'duckduckgo' => '🦆 DuckDuckGo',
        'youtube'    => '▶️ YouTube',
        'tiktok'     => '🎵 TikTok',
        'other'      => '🌐 Inna strona (link zewnętrzny)',
    ];
    foreach ($srcMap as $sKey => $sCount) {
        [$sSite, $sSource] = array_pad(explode('|', (string)$sKey, 2), 2, 'direct');
        $sLabel = $sourceLabels[$sSource] ?? ('🌐 ' . $sSource);
        $o[] = 'web_analytics_sources_total{site="' . aiEsc($sSite) . '",source="' . aiEsc($sSource) . '",label="' . aiEsc($sLabel) . '"} ' . (int)$sCount;
    }

    $o[] = '# HELP web_analytics_devices_total Urzadzenia odwiedzajacych (mobile, tablet, desktop)';
    $o[] = '# TYPE web_analytics_devices_total counter';
    $devMap = is_array($wa['devices'] ?? null) ? $wa['devices'] : [];
    foreach ($knownSites as $defSite) {
        foreach (['mobile', 'desktop'] as $defDev) {
            $dKey = $defSite . '|' . $defDev;
            if (!isset($devMap[$dKey])) {
                $devMap[$dKey] = 0;
            }
        }
    }
    $deviceLabels = [
        'mobile'  => '📱 Smartfon / Telefon (mobile)',
        'tablet'  => '📲 Tablet (iPad / Android)',
        'desktop' => '💻 Komputer / Laptop (desktop)',
    ];
    foreach ($devMap as $dKey => $dCount) {
        [$dSite, $dDevice] = array_pad(explode('|', (string)$dKey, 2), 2, 'desktop');
        $dLabel = $deviceLabels[$dDevice] ?? ('📱 ' . $dDevice);
        $o[] = 'web_analytics_devices_total{site="' . aiEsc($dSite) . '",device="' . aiEsc($dDevice) . '",label="' . aiEsc($dLabel) . '"} ' . (int)$dCount;
    }

    $o[] = '# HELP web_analytics_countries_total Kraje odwiedzajacych wg naglowka Cloudflare CF-IPCountry';
    $o[] = '# TYPE web_analytics_countries_total counter';
    $cntMap = is_array($wa['countries'] ?? null) ? $wa['countries'] : [];
    foreach ($knownSites as $defSite) {
        if (!isset($cntMap[$defSite . '|PL'])) {
            $cntMap[$defSite . '|PL'] = 0;
        }
    }
    foreach (['PL', 'DE', 'GB', 'CZ'] as $defCountry) {
        if (!isset($cntMap['katosalsahub|' . $defCountry])) {
            $cntMap['katosalsahub|' . $defCountry] = 0;
        }
    }
    $countryLabels = [
        'PL' => '🇵🇱 Polska (PL)',
        'DE' => '🇩🇪 Niemcy (DE)',
        'GB' => '🇬🇧 Wielka Brytania (GB)',
        'CZ' => '🇨🇿 Czechy (CZ)',
        'US' => '🇺🇸 USA (US)',
        'NL' => '🇳🇱 Holandia (NL)',
        'NO' => '🇳🇴 Norwegia (NO)',
        'SE' => '🇸🇪 Szwecja (SE)',
        'ES' => '🇪🇸 Hiszpania (ES)',
        'IT' => '🇮🇹 Włochy (IT)',
        'FR' => '🇫🇷 Francja (FR)',
        'AT' => '🇦🇹 Austria (AT)',
        'UA' => '🇺🇦 Ukraina (UA)',
        'SK' => '🇸🇰 Słowacja (SK)',
        'IE' => '🇮🇪 Irlandia (IE)',
        'BE' => '🇧🇪 Belgia (BE)',
        'CH' => '🇨🇭 Szwajcaria (CH)',
        'LT' => '🇱🇹 Litwa (LT)',
        'XX' => '🌐 Nieznany (XX)',
    ];
    foreach ($cntMap as $cKey => $cCount) {
        [$cSite, $cCountry] = array_pad(explode('|', (string)$cKey, 2), 2, 'PL');
        $cLabel = $countryLabels[$cCountry] ?? ('🌍 Kraj: ' . $cCountry);
        $o[] = 'web_analytics_countries_total{site="' . aiEsc($cSite) . '",country="' . aiEsc($cCountry) . '",label="' . aiEsc($cLabel) . '"} ' . (int)$cCount;
    }

    $o[] = '# HELP web_analytics_search_terms_total Wyszukiwane hasla i frazy kluczowe w Salsopedii oraz parametrach UTM';
    $o[] = '# TYPE web_analytics_search_terms_total counter';
    $termMap = is_array($wa['search_terms'] ?? null) ? $wa['search_terms'] : [];
    $sitesWithTerms = [];
    foreach ($termMap as $tKey => $tCount) {
        [$tSite, $tTerm] = array_pad(explode('|', (string)$tKey, 2), 2, '');
        if ($tTerm !== '') {
            $sitesWithTerms[$tSite] = true;
            $o[] = 'web_analytics_search_terms_total{site="' . aiEsc($tSite) . '",term="' . aiEsc($tTerm) . '"} ' . (int)$tCount;
        }
    }
    foreach ($knownSites as $defSite) {
        if (empty($sitesWithTerms[$defSite])) {
            $o[] = 'web_analytics_search_terms_total{site="' . aiEsc($defSite) . '",term="(brak wpisanych fraz UTM / wyszukiwarki)"} 0';
        }
    }

    $o[] = '# HELP web_analytics_events_total Zdarzenia biznesowe, konwersje CTA i interakcje z widzetem AI (Cookieless)';
    $o[] = '# TYPE web_analytics_events_total counter';
    $evMap = is_array($wa['events'] ?? null) ? $wa['events'] : [];
    foreach ($knownSites as $defSite) {
        foreach (['chat_open', 'quick_prompt_click', 'cta_phone_click', 'contact_form_submit'] as $defEv) {
            $eKey = $defSite . '|' . $defEv;
            if (!isset($evMap[$eKey])) {
                $evMap[$eKey] = 0;
            }
        }
    }
    if (!isset($evMap['katosalsahub|radio_play'])) {
        $evMap['katosalsahub|radio_play'] = 0;
    }
    $eventLabels = [
        'chat_open'          => '💬 Otwarcie okna czatu AI',
        'quick_prompt_click' => '⚡ Kliknięcie podpowiedzi pytania (Quick Prompt)',
        'local_cache_hit'    => '🧠 Trafienie w lokalny cache przeglądarki (0ms)',
        'cta_phone_click'     => '📞 Kliknięcie w numer telefonu (tel:)',
        'cta_email_click'     => '✉️ Kliknięcie w adres e-mail (mailto:)',
        'contact_form_submit' => '📝 Wysłanie formularza kontaktowego',
        'radio_play'          => '📻 Uruchomienie odtwarzacza Radio Salsa',
        'outbound_click'      => '↗️ Kliknięcie w link zewnętrzny (szkoła / wydarzenie)',
    ];
    foreach ($evMap as $eKey => $eCount) {
        [$eSite, $eName] = array_pad(explode('|', (string)$eKey, 2), 2, 'chat_open');
        $eLabel = $eventLabels[$eName] ?? ('🎯 ' . $eName);
        $o[] = 'web_analytics_events_total{site="' . aiEsc($eSite) . '",event="' . aiEsc($eName) . '",label="' . aiEsc($eLabel) . '"} ' . (int)$eCount;
    }

    $o[] = '# HELP web_analytics_cwv_lcp_seconds Czas renderowania najwiekszego elementu strony (Core Web Vitals LCP - Real User Monitoring)';
    $o[] = '# TYPE web_analytics_cwv_lcp_seconds summary';
    $lcpSumMap = is_array($wa['lcp_sum_ms'] ?? null) ? $wa['lcp_sum_ms'] : [];
    $lcpCntMap = is_array($wa['lcp_cnt'] ?? null) ? $wa['lcp_cnt'] : [];
    foreach ($knownSites as $defSite) {
        $sumSec = round(((float)($lcpSumMap[$defSite] ?? 0.0)) / 1000.0, 3);
        $cntVal = (int)($lcpCntMap[$defSite] ?? 0);
        $o[] = 'web_analytics_cwv_lcp_seconds_sum{site="' . aiEsc($defSite) . '"} ' . $sumSec;
        $o[] = 'web_analytics_cwv_lcp_seconds_count{site="' . aiEsc($defSite) . '"} ' . $cntVal;
    }

    $o[] = '# HELP ai_router_question_topics_total Automatycznie wyekstrahowane tematy i intencje pytan do czatbota AI (Zero-PII)';
    $o[] = '# TYPE ai_router_question_topics_total counter';
    $topicsMap = is_array($wa['ai_topics'] ?? null) ? $wa['ai_topics'] : [];
    $topicLabels = [
        'salsopedia'      => '📖 Salsopedia (słownik pojęć)',
        'figures'         => '💃 Figury taneczne (Enchufla / Dile Que No)',
        'rueda'           => '🔄 Rueda de Casino i komendy',
        'music_clave'     => '🥁 Muzyka Salsa / Timba / Rytm Clave',
        'dance_styles'    => '🕺 Style tańca (Cubana / Bachata / Kizomba)',
        'radio'           => '📻 Radio Salsa / Timba Nation',
        'events_party'    => '🎉 Potańcówki i wydarzenia taneczne',
        'schools'         => '🎓 Szkoły tańca i instruktorzy',
        'spanish_trial'   => '🇪🇸 Bezpłatna lekcja próbna hiszpańskiego',
        'spanish_course'  => '📚 Kurs hiszpańskiego i nauka języka',
        'spanish_mode'    => '👥 Zajęcia indywidualne vs grupowe',
        'spanish_biz'     => '💼 Hiszpański w biznesie / branżowy',
        'code_vs_wp'      => '⚡ Czysty kod vs WordPress (PageSpeed)',
        'ai_rag_bot'      => '🤖 Wdrożenie czatbota AI (RAG)',
        'seo_google'      => '🔍 Pozycjonowanie SEO i widoczność w Google',
        'pricing'         => '💰 Cennik i wycena (Ile kosztuje?)',
        'cooperation'     => '🤝 Współpraca, zapisy i czas realizacji',
        'contact_lead'    => '📞 Pozyskany namiar kontaktowy (Telefon / E-mail)',
        'general_inquiry' => '💬 Inne pytanie ogólne o ofertę',
    ];
    foreach (['katosalsahub|salsopedia', 'katosalsahub|figures', 'dancepuls|events_party', 'fuegolingua|spanish_course', 'twojastronawww|pricing', 'raricart|pricing'] as $defTop) {
        if (!isset($topicsMap[$defTop])) {
            $topicsMap[$defTop] = 0;
        }
    }
    foreach ($topicsMap as $topKey => $topCount) {
        [$tSite, $tCode] = array_pad(explode('|', (string)$topKey, 2), 2, 'general_inquiry');
        $tLabel = $topicLabels[$tCode] ?? ('💬 ' . $tCode);
        $o[] = 'ai_router_question_topics_total{site="' . aiEsc($tSite) . '",topic="' . aiEsc($tCode) . '",label="' . aiEsc($tLabel) . '"} ' . (int)$topCount;
    }

    $gscMap = is_array($wa['gsc_keywords'] ?? null) ? $wa['gsc_keywords'] : [];
    $hasGscData = !empty($gscMap) || (getenv('GSC_SERVICE_ACCOUNT_JSON') ?: '') !== '';
    $o[] = '# HELP web_analytics_gsc_configured Status integracji z Google Search Console API (1 = aktywna, 0 = oczekuje na klucz)';
    $o[] = '# TYPE web_analytics_gsc_configured gauge';
    $o[] = 'web_analytics_gsc_configured ' . ($hasGscData ? 1 : 0);

    $o[] = '# HELP web_analytics_gsc_keyword_clicks_total Liczba klikniec w Google dla frazy wg Google Search Console API (okno 28 dni)';
    $o[] = '# TYPE web_analytics_gsc_keyword_clicks_total gauge';
    $o[] = '# HELP web_analytics_gsc_keyword_impressions_total Liczba wyswietlen w Google (Impressions) wg Google Search Console API (okno 28 dni)';
    $o[] = '# TYPE web_analytics_gsc_keyword_impressions_total gauge';
    $o[] = '# HELP web_analytics_gsc_keyword_position Srednia pozycja frazy w wynikach wyszukiwania Google wg GSC API';
    $o[] = '# TYPE web_analytics_gsc_keyword_position gauge';

    $gscClicksLines = [];
    $gscImprLines   = [];
    $gscPosLines    = [];
    $sitesWithGsc   = [];
    foreach ($gscMap as $gSite => $gRows) {
        if (!is_array($gRows)) continue;
        foreach ($gRows as $row) {
            if (!is_array($row) || empty($row['query'])) continue;
            $qEsc = aiEsc((string)$row['query']);
            $sEsc = aiEsc((string)$gSite);
            $sitesWithGsc[(string)$gSite] = true;
            $gscClicksLines[] = 'web_analytics_gsc_keyword_clicks_total{site="' . $sEsc . '",query="' . $qEsc . '"} ' . (int)($row['clicks'] ?? 0);
            $gscImprLines[]   = 'web_analytics_gsc_keyword_impressions_total{site="' . $sEsc . '",query="' . $qEsc . '"} ' . (int)($row['impressions'] ?? 0);
            $gscPosLines[]    = 'web_analytics_gsc_keyword_position{site="' . $sEsc . '",query="' . $qEsc . '"} ' . round((float)($row['position'] ?? 1.0), 1);
        }
    }
    foreach ($knownSites as $defSite) {
        if (empty($sitesWithGsc[$defSite])) {
            $sEsc = aiEsc($defSite);
            $placeholderQuery = $hasGscData
                ? '(GSC API aktywne — oczekuje na pierwsze wyswietlenia w Google)'
                : '(oczekuje na synchronizacje Google Search Console API)';
            $gscClicksLines[] = 'web_analytics_gsc_keyword_clicks_total{site="' . $sEsc . '",query="' . $placeholderQuery . '"} 0';
            $gscImprLines[]   = 'web_analytics_gsc_keyword_impressions_total{site="' . $sEsc . '",query="' . $placeholderQuery . '"} 0';
            $gscPosLines[]    = 'web_analytics_gsc_keyword_position{site="' . $sEsc . '",query="' . $placeholderQuery . '"} 0';
        }
    }
    foreach ($gscClicksLines as $l) {
        $o[] = $l;
    }
    foreach ($gscImprLines as $l) {
        $o[] = $l;
    }
    foreach ($gscPosLines as $l) {
        $o[] = $l;
    }

    return implode("\n", $o) . "\n";
}



