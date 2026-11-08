<?php
declare(strict_types=1);

/**
 * AI Router - Moduł Bezciasteczkowej Analityki Ruchu WWW (Cookieless Web Analytics v3) & GSC Sync.
 *
 * Wydzielony z ai-stats.php w celu zachowania Single Responsibility Principle (SRP).
 * Funkcje:
 *  - zarzadzanie dziennymi kubelkami analitycznymi (today / yesterday / 7 dni w strefie Europe/Warsaw),
 *  - rejestracja odslon, zrodel wejsc (w tym AI Search), urzadzen, krajow, fraz, konwersji CTA i LCP,
 *  - deterministyczna ekstrakcja tematow pytan z czatu AI (100% Zero-PII),
 *  - integracja z Google Search Console API (gsc_sync),
 *  - renderowanie metryk web_analytics_* dla Prometheusa i 3. dashboardu Grafany.
 *
 * Bezpieczenstwo (ISO 27001 / RODO): Modul NIGDY nie przetwarza ani nie loguje adresow IP
 * ani surowych tresci pytan uzytkownikow.
 */

/** Doba analityczna dla polskich serwisów WWW (reset o północy czasu Europe/Warsaw, z cache'em w obrębie sekundy). */
function aiAnalyticsDay(): string
{
    static $tz = null;
    static $lastSec = 0;
    static $cached = '';
    $nowSec = time();
    if ($nowSec === $lastSec && $cached !== '') {
        return $cached;
    }
    if ($tz === null) {
        $tz = new DateTimeZone('Europe/Warsaw');
    }
    $lastSec = $nowSec;
    $cached = (new DateTime('@' . $nowSec))->setTimezone($tz)->format('Y-m-d');
    return $cached;
}

/** Poprzednia doba analityczna (Wczoraj) w strefie Europe/Warsaw. */
function aiAnalyticsYesterday(): string
{
    static $tz = null;
    if ($tz === null) {
        $tz = new DateTimeZone('Europe/Warsaw');
    }
    return (new DateTime('now', $tz))->modify('-1 day')->format('Y-m-d');
}

/**
 * Czy w strefie Europe/Warsaw jest jeszcze przed godziną porannego przełączenia (domyślnie 09:00 rano)?
 * Do 08:59:59 widok "auto" w Grafanie prezentuje statystyki z wczoraj, a od 09:00:00 przełącza na dzisiaj.
 */
function aiAnalyticsIsBeforeMorningCutoff(): bool
{
    static $tz = null;
    if ($tz === null) {
        $tz = new DateTimeZone('Europe/Warsaw');
    }
    $cutoffEnv = getenv('ANALYTICS_MORNING_CUTOFF_HOUR');
    $cutoffHour = ($cutoffEnv !== false && $cutoffEnv !== '' && is_numeric($cutoffEnv))
        ? max(0, min(24, (int)$cutoffEnv))
        : 9;
    $currentHour = (int)(new DateTime('@' . time()))->setTimezone($tz)->format('G');
    return $currentHour < $cutoffHour;
}

function aiDailyAnalyticsBucketDefault(): array
{
    return [
        'unique_visitors' => [], // site => [hash => 1] lub int (dla dni historycznych)
        'pageviews'       => [], // "site|path" => n
        'sources'         => [], // "site|source" => n
        'devices'         => [], // "site|device" => n
        'countries'       => [], // "site|country" => n
        'search_terms'    => [], // "site|term" => n
        'events'          => [], // "site|event" => n
        'engaged_visits'  => [], // site => n
        'lcp_sum_ms'      => [], // site => suma czasów LCP w ms
        'lcp_cnt'         => [], // site => liczba pomiarów LCP
        'ai_topics'       => [], // "site|topic" => n
    ];
}

/**
 * Przygotowuje i archiwizuje dzienne kubełki analityczne (today / yesterday / 7 dni historii).
 */
function aiPrepareWebAnalyticsDaily(array &$wa): string
{
    $today = aiAnalyticsDay();
    if (!isset($wa['daily']) || !is_array($wa['daily'])) {
        $wa['daily'] = [];
    }
    $prevDay = (string)($wa['day'] ?? '');
    if ($prevDay !== '' && $prevDay !== $today) {
        if (!isset($wa['daily'][$prevDay]) || !is_array($wa['daily'][$prevDay])) {
            $wa['daily'][$prevDay] = aiDailyAnalyticsBucketDefault();
        }
        if (is_array($wa['unique_visitors'] ?? null) && !empty($wa['unique_visitors'])) {
            $prevUv = is_array($wa['daily'][$prevDay]['unique_visitors'] ?? null)
                ? $wa['daily'][$prevDay]['unique_visitors']
                : [];
            foreach ($wa['unique_visitors'] as $uSite => $uHashes) {
                $cnt = is_array($uHashes) ? count($uHashes) : (int)$uHashes;
                $existingCnt = isset($prevUv[$uSite])
                    ? (is_array($prevUv[$uSite]) ? count($prevUv[$uSite]) : (int)$prevUv[$uSite])
                    : 0;
                $prevUv[(string)$uSite] = max($existingCnt, $cnt);
            }
            $wa['daily'][$prevDay]['unique_visitors'] = $prevUv;
        }
        $wa['day'] = $today;
        $wa['unique_visitors'] = [];
    } elseif ($prevDay === '') {
        $wa['day'] = $today;
    }

    if (!isset($wa['daily'][$today]) || !is_array($wa['daily'][$today])) {
        $wa['daily'][$today] = aiDailyAnalyticsBucketDefault();
    } else {
        $wa['daily'][$today] = array_replace(aiDailyAnalyticsBucketDefault(), $wa['daily'][$today]);
    }

    if (count($wa['daily']) > 7) {
        ksort($wa['daily']);
        $toRemove = array_slice(array_keys($wa['daily']), 0, count($wa['daily']) - 7);
        foreach ($toRemove as $oldDay) {
            unset($wa['daily'][$oldDay]);
        }
    }

    foreach ($wa['daily'] as $dKey => &$dBucket) {
        if ($dKey !== $today && isset($dBucket['unique_visitors']) && is_array($dBucket['unique_visitors'])) {
            foreach ($dBucket['unique_visitors'] as $uSite => $uVal) {
                if (is_array($uVal)) {
                    $dBucket['unique_visitors'][$uSite] = count($uVal);
                }
            }
        }
    }
    unset($dBucket);

    return $today;
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
        $today = aiPrepareWebAnalyticsDaily($wa);
        $dayBucket = &$wa['daily'][$today];

        if ($visitorHash !== '') {
            if (!isset($wa['unique_visitors'][$site]) || !is_array($wa['unique_visitors'][$site])) {
                $wa['unique_visitors'][$site] = [];
            }
            if (!isset($wa['unique_visitors'][$site][$visitorHash]) && count($wa['unique_visitors'][$site]) < 5000) {
                $wa['unique_visitors'][$site][$visitorHash] = 1;
                $wa['unique_visitors_total'] = is_array($wa['unique_visitors_total'] ?? null) ? $wa['unique_visitors_total'] : [];
                $wa['unique_visitors_total'][$site] = (int)($wa['unique_visitors_total'][$site] ?? 0) + 1;
            }
            $dayBucket['unique_visitors'][$site] = count($wa['unique_visitors'][$site]);
        }

        if ($lcpMs >= 50.0 && $lcpMs <= 8000.0) {
            $wa['lcp_sum_ms'] = is_array($wa['lcp_sum_ms'] ?? null) ? $wa['lcp_sum_ms'] : [];
            $wa['lcp_cnt'] = is_array($wa['lcp_cnt'] ?? null) ? $wa['lcp_cnt'] : [];
            // Ochrona przed zatruciem średniej przez pojedynczą kartę otwartą w tle (Winsorizing 3500 ms)
            $clampedLcpMs = min($lcpMs, 3500.0);
            $wa['lcp_sum_ms'][$site] = (float)($wa['lcp_sum_ms'][$site] ?? 0.0) + $clampedLcpMs;
            $wa['lcp_cnt'][$site] = (int)($wa['lcp_cnt'][$site] ?? 0) + 1;
            $dayBucket['lcp_sum_ms'][$site] = (float)($dayBucket['lcp_sum_ms'][$site] ?? 0.0) + $clampedLcpMs;
            $dayBucket['lcp_cnt'][$site] = (int)($dayBucket['lcp_cnt'][$site] ?? 0) + 1;
        }

        if ($eventType === 'search' && $searchTerm !== '') {
            $wa['search_terms'] = is_array($wa['search_terms'] ?? null) ? $wa['search_terms'] : [];
            aiBoundedIncrement($wa['search_terms'], $site . '|' . $searchTerm, 80);
            aiBoundedIncrement($dayBucket['search_terms'], $site . '|' . $searchTerm, 80);
            return;
        }

        if ($eventType === 'engaged') {
            $wa['engaged_visits'] = is_array($wa['engaged_visits'] ?? null) ? $wa['engaged_visits'] : [];
            $wa['engaged_visits'][$site] = (int)($wa['engaged_visits'][$site] ?? 0) + 1;
            $dayBucket['engaged_visits'][$site] = (int)($dayBucket['engaged_visits'][$site] ?? 0) + 1;
            return;
        }

        if ($eventType === 'event' && $eventName !== '') {
            $wa['events'] = is_array($wa['events'] ?? null) ? $wa['events'] : [];
            aiBoundedIncrement($wa['events'], $site . '|' . $eventName, 60);
            aiBoundedIncrement($dayBucket['events'], $site . '|' . $eventName, 60);
            return;
        }

        $wa['pageviews'] = is_array($wa['pageviews'] ?? null) ? $wa['pageviews'] : [];
        aiBoundedIncrement($wa['pageviews'], $site . '|' . $path, 60);
        aiBoundedIncrement($dayBucket['pageviews'], $site . '|' . $path, 60);

        $wa['sources'] = is_array($wa['sources'] ?? null) ? $wa['sources'] : [];
        $sKey = $site . '|' . $source;
        $wa['sources'][$sKey] = (int)($wa['sources'][$sKey] ?? 0) + 1;
        $dayBucket['sources'][$sKey] = (int)($dayBucket['sources'][$sKey] ?? 0) + 1;

        $wa['devices'] = is_array($wa['devices'] ?? null) ? $wa['devices'] : [];
        $dKey = $site . '|' . $device;
        $wa['devices'][$dKey] = (int)($wa['devices'][$dKey] ?? 0) + 1;
        $dayBucket['devices'][$dKey] = (int)($dayBucket['devices'][$dKey] ?? 0) + 1;

        $wa['countries'] = is_array($wa['countries'] ?? null) ? $wa['countries'] : [];
        aiBoundedIncrement($wa['countries'], $site . '|' . $country, 40);
        aiBoundedIncrement($dayBucket['countries'], $site . '|' . $country, 40);
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
        ['p1_erecepta',   '/\b(erecept|e-recept|recept[ay]|drr\b|eskierowan|e-skierowan|apte[kc])/u', '🤖 AI: awaria e-recepty / DRR'],
        ['nfz_ewus_szoi', '/\b(ewus|szoi\b|isi\b|swiad\b|nfz|oswiadczen)/u',                      '🤖 AI: awaria eWUŚ / SZOI NFZ'],
        ['ksef_ezla',     '/\b(ksef|offline24|ezla|e-zla|zwolnien|l4\b|zus)/u',                   '🤖 AI: tryb awaryjny KSeF / e-ZLA'],
        ['p1_errors_sla', '/\b(502\b|503\b|504\b|timeout|wsp\b|ocsp|edm\b|rzm\b|nmvs|rtt\b)/u',   '🤖 AI: kody błędów P1 (502/WSP/RZM)'],
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
        $today = aiPrepareWebAnalyticsDaily($wa);
        $dayBucket = &$wa['daily'][$today];
        $wa['ai_topics'] = is_array($wa['ai_topics'] ?? null) ? $wa['ai_topics'] : [];
        foreach ($matchedTopics as $tCode) {
            aiBoundedIncrement($wa['ai_topics'], $site . '|' . $tCode, 60);
            aiBoundedIncrement($dayBucket['ai_topics'], $site . '|' . $tCode, 60);
        }
        $wa['search_terms'] = is_array($wa['search_terms'] ?? null) ? $wa['search_terms'] : [];
        foreach ($matchedCanonicalTerms as $cTerm) {
            aiBoundedIncrement($wa['search_terms'], $site . '|' . $cTerm, 80);
            aiBoundedIncrement($dayBucket['search_terms'], $site . '|' . $cTerm, 80);
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

/**
 * Renderuje sekcję metryk Prometheus dla Cookieless Web Analytics v3 i Google Search Console API.
 */
function aiRenderWebAnalyticsMetrics(array $s, array &$o): void
{
    $wa = is_array($s['web_analytics'] ?? null) ? $s['web_analytics'] : [];
    $todayDay = aiAnalyticsDay();
    $yesterdayDay = aiAnalyticsYesterday();
    $isBefore9am = aiAnalyticsIsBeforeMorningCutoff();
    $waSameDay = (($wa['day'] ?? '') === $todayDay);
    $waIsYesterday = (($wa['day'] ?? '') === $yesterdayDay);
    $dailyMap = is_array($wa['daily'] ?? null) ? $wa['daily'] : [];
    $knownSites = ['katosalsahub', 'dancepuls', 'fuegolingua', 'twojastronawww', 'raricart', 'radar-p1'];

    $todayBucket = array_replace(
        aiDailyAnalyticsBucketDefault(),
        is_array($dailyMap[$todayDay] ?? null) ? $dailyMap[$todayDay] : []
    );
    $yesterdayBucket = array_replace(
        aiDailyAnalyticsBucketDefault(),
        is_array($dailyMap[$yesterdayDay] ?? null) ? $dailyMap[$yesterdayDay] : []
    );

    if ($waSameDay && is_array($wa['unique_visitors'] ?? null)) {
        foreach ($wa['unique_visitors'] as $uSite => $uHashes) {
            $cnt = is_array($uHashes) ? count($uHashes) : (int)$uHashes;
            $cur = isset($todayBucket['unique_visitors'][$uSite])
                ? (is_array($todayBucket['unique_visitors'][$uSite]) ? count($todayBucket['unique_visitors'][$uSite]) : (int)$todayBucket['unique_visitors'][$uSite])
                : 0;
            $todayBucket['unique_visitors'][$uSite] = max($cur, $cnt);
        }
    } elseif ($waIsYesterday && is_array($wa['unique_visitors'] ?? null)) {
        foreach ($wa['unique_visitors'] as $uSite => $uHashes) {
            $cnt = is_array($uHashes) ? count($uHashes) : (int)$uHashes;
            $cur = isset($yesterdayBucket['unique_visitors'][$uSite])
                ? (is_array($yesterdayBucket['unique_visitors'][$uSite]) ? count($yesterdayBucket['unique_visitors'][$uSite]) : (int)$yesterdayBucket['unique_visitors'][$uSite])
                : 0;
            $yesterdayBucket['unique_visitors'][$uSite] = max($cur, $cnt);
        }
    }

    $o[] = '# HELP web_analytics_unique_visitors_today Unikalni odwiedzajacy dzis wg anonimowego skrotu SHA-256 (Cookieless RODO, Europe/Warsaw)';
    $o[] = '# TYPE web_analytics_unique_visitors_today gauge';
    $uvMap = ($waSameDay && is_array($wa['unique_visitors'] ?? null)) ? $wa['unique_visitors'] : [];
    foreach ($knownSites as $defSite) {
        $tUvRaw = $todayBucket['unique_visitors'][$defSite] ?? ($uvMap[$defSite] ?? 0);
        $uvCount = is_array($tUvRaw) ? count($tUvRaw) : (int)$tUvRaw;
        $o[] = 'web_analytics_unique_visitors_today{site="' . aiEsc($defSite) . '"} ' . $uvCount;
    }

    $o[] = '# HELP web_analytics_unique_visitors_yesterday Unikalni odwiedzajacy wczoraj wg anonimowego skrotu SHA-256 (Cookieless RODO, Europe/Warsaw)';
    $o[] = '# TYPE web_analytics_unique_visitors_yesterday gauge';
    foreach ($knownSites as $defSite) {
        $yUvRaw = $yesterdayBucket['unique_visitors'][$defSite] ?? 0;
        $yUvCount = is_array($yUvRaw) ? count($yUvRaw) : (int)$yUvRaw;
        $o[] = 'web_analytics_unique_visitors_yesterday{site="' . aiEsc($defSite) . '"} ' . $yUvCount;
    }

    $o[] = '# HELP web_analytics_unique_visitors_total Laczna historyczna liczba unikalnych dziennych wizyt wg strony (Cookieless counter)';
    $o[] = '# TYPE web_analytics_unique_visitors_total counter';
    $uvTotalMap = is_array($wa['unique_visitors_total'] ?? null) ? $wa['unique_visitors_total'] : [];
    $totalUvBySite = [];
    foreach ($knownSites as $defSite) {
        $tUvRaw = $todayBucket['unique_visitors'][$defSite] ?? ($uvMap[$defSite] ?? 0);
        $uvTodayFallback = is_array($tUvRaw) ? count($tUvRaw) : (int)$tUvRaw;
        $uvTotalVal = max((int)($uvTotalMap[$defSite] ?? 0), $uvTodayFallback);
        $totalUvBySite[$defSite] = $uvTotalVal;
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
    foreach (['katosalsahub|/', 'katosalsahub|/salsopedia.html', 'katosalsahub|/grafik.html', 'dancepuls|/', 'fuegolingua|/', 'fuegolingua|/cennik.html', 'twojastronawww|/', 'twojastronawww|/jak-pracuje.html', 'raricart|/', 'raricart|/pakiety', 'radar-p1|/'] as $defPv) {
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
        '/#section-white'      => '🏥 /#section-white (Usługi kliniczne P1 & NFZ)',
        '/#section-grey'       => '💊 /#section-grey (Usługi apteczne, KSeF & ERP)',
        '/#geo-poland-section' => '🗺️ /#geo-poland-section (Mapa 16 OW NFZ)',
        '/#section-watcher'    => '🔭 /#section-watcher (Zwiadowca zmian legislacyjnych)',
        '/#glossary-section'   => '📖 /#glossary-section (Słownik awarii i procedur e-Zdrowia)',
        '/#faq-section'        => '❓ /#faq-section (Baza wiedzy i FAQ e-Zdrowia)',
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
        'copy_status_report'       => '📋 Skopiowanie raportu dostępności e-Zdrowia (Radar P1)',
        'export_csv'               => '📥 Eksport pełnego raportu SLA do CSV (Radar P1)',
        'nfz_region_select'        => '🗺️ Wybór regionu OW NFZ na mapie Polski (Radar P1)',
        'wallboard_toggle'         => '📺 Przełączenie trybu TV / Wallboard NOC (Radar P1)',
        'glossary_category_select' => '📖 Filtrowanie kategorii Słownika Awarii (Radar P1)',
        'glossary_scroll_click'    => '📖 Przejście do Słownika Awarii e-Zdrowia (Radar P1)',
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
        'p1_erecepta'     => '💊 Awaria e-Recepty / DRR / e-Skierowania (Radar P1)',
        'nfz_ewus_szoi'   => '🏥 Awaria eWUŚ / SZOI / Rozliczenia NFZ (Radar P1)',
        'ksef_ezla'       => '📑 Tryb awaryjny KSeF offline24 / ZUS e-ZLA (Radar P1)',
        'p1_errors_sla'   => '⚠️ Kody błędów P1 (502/504, WSP/OCSP, RZM) (Radar P1)',
        'contact_lead'    => '📞 Pozyskany namiar kontaktowy (Telefon / E-mail)',
        'general_inquiry' => '💬 Inne pytanie ogólne o ofertę',
    ];
    foreach (['katosalsahub|salsopedia', 'katosalsahub|figures', 'dancepuls|events_party', 'fuegolingua|spanish_course', 'twojastronawww|pricing', 'raricart|pricing', 'radar-p1|p1_erecepta'] as $defTop) {
        if (!isset($topicsMap[$defTop])) {
            $topicsMap[$defTop] = 0;
        }
    }
    foreach ($topicsMap as $topKey => $topCount) {
        [$tSite, $tCode] = array_pad(explode('|', (string)$topKey, 2), 2, 'general_inquiry');
        $tLabel = $topicLabels[$tCode] ?? ('💬 ' . $tCode);
        $o[] = 'ai_router_question_topics_total{site="' . aiEsc($tSite) . '",topic="' . aiEsc($tCode) . '",label="' . aiEsc($tLabel) . '"} ' . (int)$topCount;
    }

    // Metryki okresowe dla przełącznika w Grafanie: period="auto" (do 09:00 Wczoraj / po 09:00 Dziś), "today", "yesterday", "total"
    $totalBucket = [
        'unique_visitors' => $totalUvBySite,
        'pageviews'       => is_array($wa['pageviews'] ?? null) ? $wa['pageviews'] : [],
        'sources'         => is_array($wa['sources'] ?? null) ? $wa['sources'] : [],
        'devices'         => is_array($wa['devices'] ?? null) ? $wa['devices'] : [],
        'countries'       => is_array($wa['countries'] ?? null) ? $wa['countries'] : [],
        'search_terms'    => is_array($wa['search_terms'] ?? null) ? $wa['search_terms'] : [],
        'events'          => is_array($wa['events'] ?? null) ? $wa['events'] : [],
        'engaged_visits'  => is_array($wa['engaged_visits'] ?? null) ? $wa['engaged_visits'] : [],
        'lcp_sum_ms'      => is_array($wa['lcp_sum_ms'] ?? null) ? $wa['lcp_sum_ms'] : [],
        'lcp_cnt'         => is_array($wa['lcp_cnt'] ?? null) ? $wa['lcp_cnt'] : [],
        'ai_topics'       => is_array($wa['ai_topics'] ?? null) ? $wa['ai_topics'] : [],
    ];
    $autoBucket = $isBefore9am ? $yesterdayBucket : $todayBucket;
    $periods = [
        'auto'      => [
            'bucket'   => $autoBucket,
            'uv_label' => $isBefore9am ? 'Unikalni wczoraj (do 09:00)' : 'Unikalni dziś',
        ],
        'today'     => [
            'bucket'   => $todayBucket,
            'uv_label' => 'Unikalni dziś',
        ],
        'yesterday' => [
            'bucket'   => $yesterdayBucket,
            'uv_label' => 'Unikalni wczoraj',
        ],
        'total'     => [
            'bucket'   => $totalBucket,
            'uv_label' => 'Unikalni łącznie',
        ],
    ];

    $o[] = '# HELP web_analytics_period_unique_visitors Unikalni odwiedzajacy wg wybranego okresu (auto: do 09:00 wczoraj / po 09:00 dzis, today, yesterday, total)';
    $o[] = '# TYPE web_analytics_period_unique_visitors gauge';
    foreach ($periods as $pName => $pCfg) {
        $pUvMap = is_array($pCfg['bucket']['unique_visitors'] ?? null) ? $pCfg['bucket']['unique_visitors'] : [];
        $effLabel = aiEsc((string)$pCfg['uv_label']);
        foreach ($knownSites as $defSite) {
            $rawUv = $pUvMap[$defSite] ?? 0;
            $valUv = is_array($rawUv) ? count($rawUv) : (int)$rawUv;
            $o[] = 'web_analytics_period_unique_visitors{site="' . aiEsc($defSite) . '",period="' . $pName . '",effective_label="' . $effLabel . '"} ' . $valUv;
        }
    }

    $o[] = '# HELP web_analytics_period_engaged_visits Zaangazowane sesje (>=15s) wg wybranego okresu (auto, today, yesterday, total)';
    $o[] = '# TYPE web_analytics_period_engaged_visits gauge';
    foreach ($periods as $pName => $pCfg) {
        $pEngMap = is_array($pCfg['bucket']['engaged_visits'] ?? null) ? $pCfg['bucket']['engaged_visits'] : [];
        foreach ($knownSites as $defSite) {
            $o[] = 'web_analytics_period_engaged_visits{site="' . aiEsc($defSite) . '",period="' . $pName . '"} ' . (int)($pEngMap[$defSite] ?? 0);
        }
    }

    $o[] = '# HELP web_analytics_period_pageviews Odslony podstron i sekcji SPA wg wybranego okresu (auto, today, yesterday, total)';
    $o[] = '# TYPE web_analytics_period_pageviews gauge';
    foreach ($periods as $pName => $pCfg) {
        $pPvMap = is_array($pCfg['bucket']['pageviews'] ?? null) ? $pCfg['bucket']['pageviews'] : [];
        foreach ($knownSites as $defSite) {
            if (!isset($pPvMap[$defSite . '|/'])) {
                $pPvMap[$defSite . '|/'] = 0;
            }
        }
        foreach ($pPvMap as $pvKey => $pvCount) {
            [$pvSite, $pvPath] = array_pad(explode('|', (string)$pvKey, 2), 2, '/');
            $pvLabel = $pathLabels[$pvPath] ?? ('📄 ' . $pvPath);
            $o[] = 'web_analytics_period_pageviews{site="' . aiEsc($pvSite) . '",path="' . aiEsc($pvPath) . '",label="' . aiEsc($pvLabel) . '",period="' . $pName . '"} ' . (int)$pvCount;
        }
    }

    $o[] = '# HELP web_analytics_period_sources Zrodla wejsc uzytkownikow wg wybranego okresu (auto, today, yesterday, total)';
    $o[] = '# TYPE web_analytics_period_sources gauge';
    foreach ($periods as $pName => $pCfg) {
        $pSrcMap = is_array($pCfg['bucket']['sources'] ?? null) ? $pCfg['bucket']['sources'] : [];
        foreach ($knownSites as $defSite) {
            foreach (['direct', 'google', 'ai_search', 'facebook', 'instagram'] as $defSrc) {
                $sKey = $defSite . '|' . $defSrc;
                if (!isset($pSrcMap[$sKey])) {
                    $pSrcMap[$sKey] = 0;
                }
            }
        }
        foreach ($pSrcMap as $sKey => $sCount) {
            [$sSite, $sSource] = array_pad(explode('|', (string)$sKey, 2), 2, 'direct');
            $sLabel = $sourceLabels[$sSource] ?? ('🌐 ' . $sSource);
            $o[] = 'web_analytics_period_sources{site="' . aiEsc($sSite) . '",source="' . aiEsc($sSource) . '",label="' . aiEsc($sLabel) . '",period="' . $pName . '"} ' . (int)$sCount;
        }
    }

    $o[] = '# HELP web_analytics_period_devices Urzadzenia odwiedzajacych wg wybranego okresu (auto, today, yesterday, total)';
    $o[] = '# TYPE web_analytics_period_devices gauge';
    foreach ($periods as $pName => $pCfg) {
        $pDevMap = is_array($pCfg['bucket']['devices'] ?? null) ? $pCfg['bucket']['devices'] : [];
        foreach ($knownSites as $defSite) {
            foreach (['mobile', 'desktop'] as $defDev) {
                $dKey = $defSite . '|' . $defDev;
                if (!isset($pDevMap[$dKey])) {
                    $pDevMap[$dKey] = 0;
                }
            }
        }
        foreach ($pDevMap as $dKey => $dCount) {
            [$dSite, $dDevice] = array_pad(explode('|', (string)$dKey, 2), 2, 'desktop');
            $dLabel = $deviceLabels[$dDevice] ?? ('📱 ' . $dDevice);
            $o[] = 'web_analytics_period_devices{site="' . aiEsc($dSite) . '",device="' . aiEsc($dDevice) . '",label="' . aiEsc($dLabel) . '",period="' . $pName . '"} ' . (int)$dCount;
        }
    }

    $o[] = '# HELP web_analytics_period_countries Kraje odwiedzajacych wg wybranego okresu (auto, today, yesterday, total)';
    $o[] = '# TYPE web_analytics_period_countries gauge';
    foreach ($periods as $pName => $pCfg) {
        $pCntMap = is_array($pCfg['bucket']['countries'] ?? null) ? $pCfg['bucket']['countries'] : [];
        foreach ($knownSites as $defSite) {
            if (!isset($pCntMap[$defSite . '|PL'])) {
                $pCntMap[$defSite . '|PL'] = 0;
            }
        }
        foreach ($pCntMap as $cKey => $cCount) {
            [$cSite, $cCountry] = array_pad(explode('|', (string)$cKey, 2), 2, 'PL');
            $cLabel = $countryLabels[$cCountry] ?? ('🌍 Kraj: ' . $cCountry);
            $o[] = 'web_analytics_period_countries{site="' . aiEsc($cSite) . '",country="' . aiEsc($cCountry) . '",label="' . aiEsc($cLabel) . '",period="' . $pName . '"} ' . (int)$cCount;
        }
    }

    $o[] = '# HELP web_analytics_period_search_terms Wyszukiwane hasla i frazy wg wybranego okresu (auto, today, yesterday, total)';
    $o[] = '# TYPE web_analytics_period_search_terms gauge';
    foreach ($periods as $pName => $pCfg) {
        $pTermMap = is_array($pCfg['bucket']['search_terms'] ?? null) ? $pCfg['bucket']['search_terms'] : [];
        $pSitesWithTerms = [];
        foreach ($pTermMap as $tKey => $tCount) {
            [$tSite, $tTerm] = array_pad(explode('|', (string)$tKey, 2), 2, '');
            if ($tTerm !== '') {
                $pSitesWithTerms[$tSite] = true;
                $o[] = 'web_analytics_period_search_terms{site="' . aiEsc($tSite) . '",term="' . aiEsc($tTerm) . '",period="' . $pName . '"} ' . (int)$tCount;
            }
        }
        foreach ($knownSites as $defSite) {
            if (empty($pSitesWithTerms[$defSite])) {
                $o[] = 'web_analytics_period_search_terms{site="' . aiEsc($defSite) . '",term="(brak wpisanych fraz UTM / wyszukiwarki)",period="' . $pName . '"} 0';
            }
        }
    }

    $o[] = '# HELP web_analytics_period_events Zdarzenia biznesowe i konwersje CTA wg wybranego okresu (auto, today, yesterday, total)';
    $o[] = '# TYPE web_analytics_period_events gauge';
    foreach ($periods as $pName => $pCfg) {
        $pEvMap = is_array($pCfg['bucket']['events'] ?? null) ? $pCfg['bucket']['events'] : [];
        foreach ($knownSites as $defSite) {
            foreach (['chat_open', 'quick_prompt_click', 'cta_phone_click', 'contact_form_submit'] as $defEv) {
                $eKey = $defSite . '|' . $defEv;
                if (!isset($pEvMap[$eKey])) {
                    $pEvMap[$eKey] = 0;
                }
            }
        }
        foreach ($pEvMap as $eKey => $eCount) {
            [$eSite, $eName] = array_pad(explode('|', (string)$eKey, 2), 2, 'chat_open');
            $eLabel = $eventLabels[$eName] ?? ('🎯 ' . $eName);
            $o[] = 'web_analytics_period_events{site="' . aiEsc($eSite) . '",event="' . aiEsc($eName) . '",label="' . aiEsc($eLabel) . '",period="' . $pName . '"} ' . (int)$eCount;
        }
    }

    $o[] = '# HELP web_analytics_period_lcp_seconds_sum Suma czasow LCP (s) wg wybranego okresu (auto, today, yesterday, total)';
    $o[] = '# TYPE web_analytics_period_lcp_seconds_sum gauge';
    $pLcpCountLines = [];
    foreach ($periods as $pName => $pCfg) {
        $pLcpSum = is_array($pCfg['bucket']['lcp_sum_ms'] ?? null) ? $pCfg['bucket']['lcp_sum_ms'] : [];
        $pLcpCnt = is_array($pCfg['bucket']['lcp_cnt'] ?? null) ? $pCfg['bucket']['lcp_cnt'] : [];
        foreach ($knownSites as $defSite) {
            $cntVal = (int)($pLcpCnt[$defSite] ?? 0);
            $sumMsVal = (float)($pLcpSum[$defSite] ?? 0.0);
            if ($cntVal === 0 && (int)($lcpCntMap[$defSite] ?? 0) > 0) {
                $cntVal = (int)$lcpCntMap[$defSite];
                $sumMsVal = (float)($lcpSumMap[$defSite] ?? 0.0);
            }
            $sumSec = round($sumMsVal / 1000.0, 3);
            $o[] = 'web_analytics_period_lcp_seconds_sum{site="' . aiEsc($defSite) . '",period="' . $pName . '"} ' . $sumSec;
            $pLcpCountLines[] = 'web_analytics_period_lcp_seconds_count{site="' . aiEsc($defSite) . '",period="' . $pName . '"} ' . $cntVal;
        }
    }
    $o[] = '# HELP web_analytics_period_lcp_seconds_count Liczba pomiarow LCP wg wybranego okresu (auto, today, yesterday, total)';
    $o[] = '# TYPE web_analytics_period_lcp_seconds_count gauge';
    foreach ($pLcpCountLines as $lcpLine) {
        $o[] = $lcpLine;
    }

    $o[] = '# HELP ai_router_period_question_topics Tematy pytan do czatbota AI wg wybranego okresu (auto, today, yesterday, total)';
    $o[] = '# TYPE ai_router_period_question_topics gauge';
    foreach ($periods as $pName => $pCfg) {
        $pTopMap = is_array($pCfg['bucket']['ai_topics'] ?? null) ? $pCfg['bucket']['ai_topics'] : [];
        foreach (['katosalsahub|salsopedia', 'katosalsahub|figures', 'dancepuls|events_party', 'fuegolingua|spanish_course', 'twojastronawww|pricing', 'raricart|pricing', 'radar-p1|p1_erecepta'] as $defTop) {
            if (!isset($pTopMap[$defTop])) {
                $pTopMap[$defTop] = 0;
            }
        }
        foreach ($pTopMap as $topKey => $topCount) {
            [$tSite, $tCode] = array_pad(explode('|', (string)$topKey, 2), 2, 'general_inquiry');
            $tLabel = $topicLabels[$tCode] ?? ('💬 ' . $tCode);
            $o[] = 'ai_router_period_question_topics{site="' . aiEsc($tSite) . '",topic="' . aiEsc($tCode) . '",label="' . aiEsc($tLabel) . '",period="' . $pName . '"} ' . (int)$topCount;
        }
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
}
