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
 * Normalizuje ścieżkę podstrony lub sekcji SPA do kanonicznej postaci (np. /index.html#faq -> /#faq).
 */
function aiNormalizeAnalyticsPath(string $path): string
{
    $p = trim($path);
    if ($p === '' || $p === '/index.html' || $p === '/index.php') {
        return '/';
    }
    if (str_starts_with($p, '/index.html#')) {
        return '/#' . substr($p, strlen('/index.html#'));
    }
    if (str_starts_with($p, '/index.php#')) {
        return '/#' . substr($p, strlen('/index.php#'));
    }
    if (preg_match('/^(\/[a-zA-Z0-9_.-]+\.html)termterm_/i', $p, $m)) {
        return $m[1];
    }
    if ($p === '/pakiety.php') {
        return '/pakiety';
    }
    if ($p === '/polityka-prywatnosci.php') {
        return '/polityka-prywatnosci';
    }
    return $p;
}

/**
 * Tłumaczy techniczne identyfikatory Salsopedii (term_*) oraz uszkodzone historyczne ciągi (?? AI:) na czytelne polskie nazwy.
 */
function aiNormalizeSearchTerm(string $term): string
{
    static $termMap = [
        'term_1' => 'Abanico (figura)',
        'term_2' => 'Adelante (komenda)',
        'term_3' => 'Alarde (styling)',
        'term_4' => 'Atrás (krok w tył)',
        'term_5' => 'Bachata',
        'term_6' => 'Balsero (figura)',
        'term_7' => 'Básico / Guapea',
        'term_8' => 'Botella (figura)',
        'term_9' => 'Bullsca (komenda)',
        'term_10' => 'Cadena (figura)',
        'term_11' => 'Camina (komenda)',
        'term_12' => 'Candado (węzeł)',
        'term_13' => 'Casino (Salsa kubańska)',
        'term_14' => 'Caminando Arriba',
        'term_15' => 'Cero / Zero (komenda)',
        'term_16' => 'Clave (instrument)',
        'term_16b' => 'Clave (rytm)',
        'term_17' => 'Coca-Cola (figura)',
        'term_18' => 'Columbia (Rumba)',
        'term_19' => 'Conga (instrument)',
        'term_20' => 'Consubeme (komenda)',
        'term_21' => 'Cruzado (krok)',
        'term_22' => 'Cuban Motion (ruch ciała)',
        'term_23' => 'Dame (zmiana partnerki)',
        'term_24' => 'Dame Dos (komenda)',
        'term_25' => 'Dame Una Arriba',
        'term_26' => 'Dedo (figura)',
        'term_27' => 'Despelote',
        'term_28' => 'Dile Que No',
        'term_29' => 'Dile Que Si',
        'term_30' => 'Directo (komenda)',
        'term_31' => 'Echevarria (komenda)',
        'term_32' => 'Enchufla',
        'term_33' => 'Enchufla Doble',
        'term_34' => 'Exhíbela / Sacala',
        'term_35' => 'Festival de Pelota',
        'term_36' => 'Fly (klaśnięcie)',
        'term_37' => 'Guaguancó (Rumba)',
        'term_38' => 'Guapea',
        'term_39' => 'Chango (Orisha)',
        'term_40' => 'Eleggua (Orisha)',
        'term_41' => 'Yemaya (Orisha)',
        'term_42' => 'Oshun (Orisha)',
        'term_45' => 'La Flor (komenda)',
        'term_46' => 'Mambo',
        'term_47' => 'Manos (komenda)',
        'term_48' => 'Mantel (figura)',
        'term_49' => 'Mariposa (figura)',
        'term_50' => 'Martillo (rytm bongosów)',
        'term_51' => 'Montuno',
        'term_52' => 'Ni Pa Ti Ni Pa Mi',
        'term_53' => 'Ochenta y Cuatro (84)',
        'term_54' => 'Fania All-Stars',
        'term_55' => 'Los Van Van',
        'term_56' => 'Havana D\'Primera',
        'term_57' => 'Maykel Blanco y Su Salsa Mayor',
        'term_58' => 'Panque (figura)',
        'term_59' => 'Para Abajo',
        'term_60' => 'Para Arriba',
        'term_61' => 'Para Los Dos',
        'term_62' => 'Paseala',
        'term_63' => 'Pelota (komenda)',
        'term_64' => 'Policia (komenda)',
        'term_65' => 'Prima (Adios)',
        'term_66' => 'Prima con Hermana',
        'term_67' => 'Quedate (komenda)',
        'term_68' => 'Rueda de Casino',
        'term_69' => 'Rumba kubańska',
        'term_70' => 'Sacala (Exhíbela)',
        'term_71' => 'Saloneo',
        'term_72' => 'Salsa',
        'term_73' => 'Setenta (70)',
        'term_74' => 'Setenta Complicado',
        'term_75' => 'Sombrero (figura)',
        'term_76' => 'Son Cubano',
        'term_77' => 'Suena (komenda)',
        'term_78' => 'Tarro (komenda)',
        'term_79' => 'Tiempo España',
        'term_80' => 'Timba kubańska',
        'term_81' => 'Tumba Francesa',
        'term_82' => 'Una Bulla (okrzyk)',
        'term_83' => 'Un Fly (klaśnięcie)',
        'term_84' => 'Vacilala (figura)',
        'term_85' => 'Vacunao (Rumba)',
        'term_86' => 'Vasigal',
        'term_87' => 'Vuelta (obrót)',
        'term_88' => 'Yambu (Rumba)',
        'term_89' => 'Yogurt (komenda)',
        'term_90' => 'Obatala (Orisha)',
        'term_91' => 'Oya (Orisha)',
        'term_92' => 'Ogun (Orisha)',
        'term_93' => 'Bomba',
        'term_94' => 'Plena',
        'term_95' => 'Salsera / Salsero',
        'term_96' => 'Rumbera / Rumbero',
        'term_97' => 'Timbero / Timbera',
        'term_98' => 'Tumbao (rytm)',
        'term_99' => 'Ocho Cortado',
        'term_100' => 'El Gran Combo de Puerto Rico',
        'inst_aniakurowska' => 'Ania „Ana” Kurowska (instruktor)',
        'term_school_1' => 'Szkoła Tańca La Clave (Katowice)',
        'term_school_2' => 'Szkoła Tańca Mil Pasos (Katowice)',
        'term_school_3' => 'Salsa Los Amigos (Katowice / Sosnowiec)',
        'term_school_4' => 'Nova Szkoła Tańca (Katowice)',
        'term_school_5' => 'Śląska Szkoła Tańca Dariusz Kurzeja',
        'term_school_6' => 'KIZLAB (Katowice)',
        'term_school_7' => 'VAMULA.pl Akademia Kizomby (Katowice)',
        'term_school_8' => 'Gravitacja / Dance Plus Plus (Katowice)',
        'term_school_9' => 'Evolution Dance Studio (Katowice)',
        'term_school_10' => 'Dolina Trzech Stawów — Kato Salsa Hub',
        'term_school_11' => 'Szkoła Tańca Mohito (Gliwice / Tychy)',
        'term_school_12' => 'DANCE#LOVEit & Corazon (Bielsko-Biała)',
        'term_school_13' => 'Good Mood — Szkoła Tańca (Katowice)',
        'term_school_14' => 'Taneczna Kompania (Katowice)',
        'term_inst_1' => 'Sebastian Ciosiński (La Clave)',
        'term_inst_2' => 'Ania Seruga (La Clave)',
        'term_inst_3' => 'Dariusz „Darek” Gruszczyk (La Clave)',
        'term_inst_4' => 'Ziemek i Olita (La Clave)',
        'term_inst_5' => 'Klaudia i Adriano (La Clave)',
        'term_inst_6' => 'Marzena i Tomek (La Clave)',
        'term_inst_7' => 'Maciek Zahorodny (La Clave)',
        'term_inst_8' => 'Justyna Sarzyńska (La Clave)',
        'term_inst_9' => 'Daniel Galas (Mil Pasos)',
        'term_inst_10' => 'Anita i Grzegorz (Mil Pasos)',
        'term_inst_11' => 'Iza i Krystian (Mil Pasos)',
        'term_inst_12' => 'Wiola i Konrad (Mil Pasos)',
        'term_inst_13' => 'Jędrzej „Jędrek” Górski (Salsa Los Amigos)',
        'term_inst_14' => 'Iwona (Salsa Los Amigos)',
        'term_inst_15' => 'Regla Maria Peñalver Hernández (Kuba)',
        'term_inst_16' => 'Daniel „Kokosz” Machalica (Good Mood)',
        'term_inst_17' => 'Dariusz Kurzeja (Śląska Szkoła Tańca)',
        'term_inst_18' => 'Pedro y Bella (VAMULA.pl)',
        'term_inst_19' => 'Ela Stępień i Michał Rozewski (KIZLAB)',
        'term_inst_20' => 'Daniel Rojewski i Maja Modliszewska',
        'term_inst_21' => 'Damian Ratajczak (FeelTheSalsa)',
        'term_inst_22' => 'Leidel Portuondo (Kuba)',
        'term_inst_23' => 'Adrian „Dronson” Dronszczyk (Good Mood)',
        'term_inst_24' => 'Claudio Mineo (La Clave / Good Mood)',
        'term_inst_25' => 'Patrycja Franczak / Stosio (Good Mood)',
        'term_inst_26' => 'Krystian Domian (Good Mood)',
        'term_inst_27' => 'Katarzyna Terech i Brajan Nosal (Good Mood)',
        'term_inst_28' => 'Milena „Mili” Jakubowska (Good Mood)',
        'term_inst_29' => 'Krzysztof Kardaś (Good Mood)',
        'term_inst_30' => 'Judyta „Niyaf” Mężyk i Joanna Fujawa',
        'term_inst_31' => 'Kuba Tracz (La Clave)',
        'term_inst_32' => 'Dominik i Natalia (La Clave)',
        'term_inst_33' => 'Martica Zaldivar (La Clave)',
        'term_inst_34' => 'Piotr i Ela (La Clave)',
        'term_inst_35' => 'Anita (La Clave)',
        'term_inst_36' => 'Ula Miś i Michał Saternus',
        'term_inst_37' => 'Dawid Bawor (La Clave)',
        'term_inst_38' => 'Dominika (La Clave)',
        'term_step_new_1' => 'Paso Básico (krok podstawowy)',
        'term_step_new_2' => 'Lateral (Cucaracha)',
        'term_step_new_3' => 'Punta y Talón',
        'term_step_new_4' => 'Suzy Q (Susie Q)',
        'term_step_new_5' => 'Tornillo (krok)',
        'term_step_new_6' => 'Alarde (styling)',
        'term_step_new_7' => 'Tap (akcent stopą)',
        'term_step_new_8' => 'Box Step (krok kwadratowy)',
        'term_step_new_9' => 'Ginga (Kizomba)',
        'term_fig_new_1' => 'Kentucky (figura)',
        'term_fig_new_2' => 'El Uno (figura 1)',
        'term_fig_new_3' => 'El Dos (figura 2)',
        'term_fig_new_4' => 'El Siete (figura 7)',
        'term_fig_new_5' => 'Setenta y Uno (71)',
        'term_fig_new_6' => 'Sombrero Doble',
        'term_fig_new_7' => 'Montaña (figura)',
        'term_fig_new_8' => 'Besito (figura)',
        'term_fig_new_9' => 'Juana la Cubana',
        'term_fig_new_10' => 'Ponle Sabor',
        'term_instr_1' => 'Bongó (bongosy)',
        'term_instr_2' => 'Timbales (pailas)',
        'term_instr_3' => 'Campana (dzwonek kubański)',
        'term_instr_4' => 'Güiro (guayo)',
        'term_instr_5' => 'Güira Dominicana',
        'term_instr_6' => 'Marakasy (maracas)',
        'term_instr_7' => 'Tres Cubano (gitara kubańska)',
        'term_instr_8' => 'Batá (bębny obrzędowe)',
        'term_instr_9' => 'Cajón Cubano',
        'term_instr_10' => 'Catá (guagua)',
        'term_instr_11' => 'Chekeré (shekeré)',
        'term_instr_12' => 'Piano (fortepian — Montuno)',
        'term_instr_13' => 'Baby Bass (kontrabas w Salsie)',
        'term_instr_14' => 'Bombo i Songo (perkusja w Timbie)',
        'term_instr_15' => 'Requinto (gitara w Bachacie)',
        'term_instr_16' => 'Trompeta i Trombón (sekcja dęta)',
        'term_instr_17' => 'Marímbula (bas kubański)',
        'term_ksh_wolni_ludzie' => 'Wolni Ludzie — Potańcówki Kato Salsa Hub',
        'term_ksh_dzialalnosc' => 'Kato Salsa Hub — Działalność Fundacji',
        'term_ksh_nospr' => 'Amfiteatr NOSPR — Plenery Taneczne Katowice',
        'term_timba_nation_radio' => 'Timba Nation Radio (DJ Maikiu)',
        // Naprawa historycznych wpisów z uszkodzonym kodowaniem UTF-8
        '?? ai: salsopedia' => '🤖 AI: salsopedia',
        '?? ai: enchufla / dile que no' => '🤖 AI: enchufla / dile que no',
        '?? ai: rueda de casino' => '🤖 AI: rueda de casino',
        '?? ai: muzyka salsa / clave' => '🤖 AI: muzyka salsa / clave',
        '?? ai: style ta?ca (salsa/bachata)' => '🤖 AI: style tańca (salsa/bachata)',
        '?? ai: radio salsa' => '🤖 AI: radio salsa',
        '?? ai: gdzie ta?czymy / pota?c?wki' => '🤖 AI: gdzie tańczymy / potańcówki',
        '?? ai: szko?y ta?ca katowice' => '🤖 AI: szkoły tańca katowice',
        '?? ai: bezp?atna lekcja pr?bna' => '🤖 AI: bezpłatna lekcja próbna',
        '?? ai: kurs hiszpa?skiego' => '🤖 AI: kurs hiszpańskiego',
        '?? ai: zaj?cia indywidualne vs grupowe' => '🤖 AI: zajęcia indywidualne vs grupowe',
        '?? ai: hiszpa?ski w biznesie' => '🤖 AI: hiszpański w biznesie',
        '?? ai: kod zamiast wordpressa' => '🤖 AI: kod zamiast wordpressa',
        '?? ai: wdro?enie czatbota ai (rag)' => '🤖 AI: wdrożenie czatbota ai (rag)',
        '?? ai: pozycjonowanie seo' => '🤖 AI: pozycjonowanie seo',
        '?? ai: cennik i koszty' => '🤖 AI: cennik i koszty',
        '?? ai: jak wygl?da wsp??praca' => '🤖 AI: jak wygląda współpraca',
        '?? ai: awaria e-recepty / drr' => '🤖 AI: awaria e-recepty / DRR',
        '?? ai: awaria ewu? / szoi nfz' => '🤖 AI: awaria eWUŚ / SZOI NFZ',
        '?? ai: tryb awaryjny ksef / e-zla' => '🤖 AI: tryb awaryjny KSeF / e-ZLA',
        '?? ai: kody b??d?w p1 (502/wsp/rzm)' => '🤖 AI: kody błędów P1 (502/WSP/RZM)',
        '?aneta' => 'żaneta',
    ];

    $tTrim = trim($term);
    $tLow = mb_strtolower($tTrim);
    if (isset($termMap[$tLow])) {
        return $termMap[$tLow];
    }
    if (preg_match('/^\?+\s*ai:\s*(.+)$/iu', $tTrim, $m)) {
        return '🤖 AI: ' . $m[1];
    }
    if (str_starts_with($tLow, 'term_')) {
        $fallback = (string)preg_replace('/^term_(ksh_|inst_|school_|instr_|step_new_|fig_new_)?/i', '', $tLow);
        return 'Hasło Salsopedii: ' . str_replace('_', ' ', $fallback);
    }
    return $tTrim;
}

/**
 * Normalizuje podsumowujące zapytania z Google Search Console do czytelnej polskiej nazwy.
 */
function aiNormalizeGscQuery(string $query): string
{
    static $gscSummaryMap = [
        'katosalsahub ruch organiczny ogolem'   => 'Kato Salsa Hub — pozostały ruch organiczny ogółem',
        'dancepuls ruch organiczny ogolem'      => 'DancePuls — pozostały ruch organiczny ogółem',
        'fuegolingua ruch organiczny ogolem'    => 'FuegoLingua — pozostały ruch organiczny ogółem',
        'twojastronawww ruch organiczny ogolem' => 'TwojaStronaWWW — pozostały ruch organiczny ogółem',
        'raricart ruch organiczny ogolem'       => 'Raricart — pozostały ruch organiczny ogółem',
        'radar-p1 ruch organiczny ogolem'       => 'Radar P1 — pozostały ruch organiczny ogółem',
        'medicusnoster ruch organiczny ogolem'  => 'Medicus Noster — pozostały ruch organiczny ogółem',
    ];
    $qTrim = trim($query);
    return $gscSummaryMap[$qTrim] ?? $qTrim;
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
    $rawPvMap = is_array($wa['pageviews'] ?? null) ? $wa['pageviews'] : [];
    $pvMap = [];
    foreach ($rawPvMap as $pvKey => $pvCount) {
        [$pvSite, $pvPath] = array_pad(explode('|', (string)$pvKey, 2), 2, '/');
        $normPath = aiNormalizeAnalyticsPath($pvPath);
        $normKey = $pvSite . '|' . $normPath;
        $pvMap[$normKey] = (int)($pvMap[$normKey] ?? 0) + (int)$pvCount;
    }
    foreach (['katosalsahub|/', 'katosalsahub|/salsopedia.html', 'katosalsahub|/grafik.html', 'dancepuls|/', 'fuegolingua|/', 'fuegolingua|/cennik.html', 'twojastronawww|/', 'twojastronawww|/jak-pracuje.html', 'raricart|/', 'raricart|/pakiety', 'radar-p1|/'] as $defPv) {
        if (!isset($pvMap[$defPv])) {
            $pvMap[$defPv] = 0;
        }
    }
    $pathLabels = [
        '/'                        => '🏠 / (Strona główna)',
        '/salsopedia.html'         => '📖 /salsopedia.html (Słownik Salsopedii)',
        '/grafik.html'             => '📅 /grafik.html (Wspólny Grafik Szkół Tańca)',
        '/grafik.html#SalsaKatowice' => '📅 /grafik.html#SalsaKatowice (Grafik — Salsa Katowice)',
        '/jak-pracuje.html'        => '⚙️ /jak-pracuje.html (Jak pracuję — etapy i gwarancje)',
        '/cennik.html'             => '💰 /cennik.html (Cennik kursów hiszpańskiego)',
        '/privacy.html'            => '🔒 /privacy.html (Polityka prywatności)',
        '/pakiety'                 => '🍽️ /pakiety (Pakiety i wycena Raricart)',
        '/pakiety.php'             => '🍽️ /pakiety.php (Pakiety i wycena Raricart)',
        '/polityka-prywatnosci'     => '🔒 /polityka-prywatnosci (Polityka prywatności)',
        '/polityka-prywatnosci.php' => '🔒 /polityka-prywatnosci.php (Polityka prywatności)',
        '/#hero'                   => '✨ /#hero (Sekcja powitalna — Góra strony)',
        '/#onas'                   => '👥 /#onas (O nas)',
        '/#oferta'                 => '🥂 /#oferta (Oferta i stacje kulinarne)',
        '/#oferta-lista'           => '📋 /#oferta-lista (Lista pakietów i usług)',
        '/#offer-pancakes'         => '🥞 /#offer-pancakes (Stacja Mini Pancakes)',
        '/#realizacje'             => '📸 /#realizacje (Galeria realizacji)',
        '/#szkoly'                 => '🎓 /#szkoly (Szkoły tańca w regionie)',
        '/#wydarzenia'             => '🎉 /#wydarzenia (Wydarzenia i potańcówki)',
        '/#radio'                  => '📻 /#radio (Radio Salsa na żywo)',
        '/#mapa'                   => '🗺️ /#mapa (Mapa szkół i lokalizacji)',
        '/#style'                  => '💃 /#style (Style taneczne)',
        '/#artykuly'               => '📰 /#artykuly (Artykuły i poradniki)',
        '/#slownik'                => '📚 /#slownik (Słownik pojęć)',
        '/#faq'                    => '❓ /#faq (Częste pytania i odpowiedzi)',
        '/#cennik'                 => '💰 /#cennik (Oferta i cennik)',
        '/#pricing'                => '💰 /#pricing (Pakiety i cennik)',
        '/#portfolio'              => '🚀 /#portfolio (Realizacje i wdrożenia)',
        '/#proces'                 => '🛠️ /#proces (Etapy realizacji współpracy)',
        '/#dla-kogo'               => '🎯 /#dla-kogo (Dla kogo tworzymy strony)',
        '/#contact'                => '📞 /#contact (Formularz wyceny i kontaktu)',
        '/#kontakt'                => '📞 /#kontakt (Sekcja kontaktu)',
        '/#kursy'                  => '🇪🇸 /#kursy (Kursy języka hiszpańskiego)',
        '/#section-white'          => '🏥 /#section-white (Usługi kliniczne P1 i NFZ)',
        '/#section-grey'           => '💊 /#section-grey (Usługi apteczne, KSeF i ERP)',
        '/#geo-poland-section'     => '🗺️ /#geo-poland-section (Mapa 16 oddziałów NFZ)',
        '/#section-watcher'        => '🔭 /#section-watcher (Radar zmian legislacyjnych)',
        '/#glossary-section'       => '📖 /#glossary-section (Słownik awarii e-Zdrowia)',
        '/#faq-section'            => '❓ /#faq-section (Pytania i odpowiedzi e-Zdrowia)',
    ];
    foreach ($pvMap as $pvKey => $pvCount) {
        [$pvSite, $pvPath] = array_pad(explode('|', (string)$pvKey, 2), 2, '/');
        $pvLabel = $pathLabels[$pvPath] ?? ('📄 Podstrona: ' . $pvPath);
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
        'direct'     => '🔗 Bezpośrednie (wpisany adres / zakładka / komunikator)',
        'google'     => '🔍 Wyszukiwarka Google (ruch organiczny SEO)',
        'ai_search'  => '🤖 Wyszukiwarki AI (ChatGPT / Perplexity / Claude / Gemini)',
        'facebook'   => '📘 Facebook (media społecznościowe)',
        'instagram'  => '📸 Instagram (media społecznościowe)',
        'bing'       => '🔍 Wyszukiwarka Bing',
        'duckduckgo' => '🦆 Wyszukiwarka DuckDuckGo',
        'youtube'    => '▶️ YouTube (wideo)',
        'tiktok'     => '🎵 TikTok (wideo)',
        'other'      => '🌐 Inna strona (odesłanie z linku zewnętrznego)',
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
        'mobile'  => '📱 Smartfon / Telefon komórkowy',
        'tablet'  => '📲 Tablet',
        'desktop' => '💻 Komputer stacjonarny / Laptop',
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
        'US' => '🇺🇸 Stany Zjednoczone (US)',
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
        'ZA' => '🇿🇦 Republika Południowej Afryki (ZA)',
        'CA' => '🇨🇦 Kanada (CA)',
        'CN' => '🇨🇳 Chiny (CN)',
        'HK' => '🇭🇰 Hongkong (HK)',
        'GR' => '🇬🇷 Grecja (GR)',
        'KZ' => '🇰🇿 Kazachstan (KZ)',
        'AU' => '🇦🇺 Australia (AU)',
        'DK' => '🇩🇰 Dania (DK)',
        'FI' => '🇫🇮 Finlandia (FI)',
        'PT' => '🇵🇹 Portugalia (PT)',
        'RO' => '🇷🇴 Rumunia (RO)',
        'HU' => '🇭🇺 Węgry (HU)',
        'BG' => '🇧🇬 Bułgaria (BG)',
        'HR' => '🇭🇷 Chorwacja (HR)',
        'TR' => '🇹🇷 Turcja (TR)',
        'JP' => '🇯🇵 Japonia (JP)',
        'KR' => '🇰🇷 Korea Południowa (KR)',
        'SG' => '🇸🇬 Singapur (SG)',
        'IN' => '🇮🇳 Indie (IN)',
        'BR' => '🇧🇷 Brazylia (BR)',
        'MX' => '🇲🇽 Meksyk (MX)',
        'CU' => '🇨🇺 Kuba (CU)',
        'XX' => '🌐 Nieznany kraj (XX)',
    ];
    foreach ($cntMap as $cKey => $cCount) {
        [$cSite, $cCountry] = array_pad(explode('|', (string)$cKey, 2), 2, 'PL');
        $cLabel = $countryLabels[$cCountry] ?? ('🌍 Kraj: ' . $cCountry);
        $o[] = 'web_analytics_countries_total{site="' . aiEsc($cSite) . '",country="' . aiEsc($cCountry) . '",label="' . aiEsc($cLabel) . '"} ' . (int)$cCount;
    }

    $o[] = '# HELP web_analytics_search_terms_total Wyszukiwane hasla i frazy kluczowe w Salsopedii oraz parametrach UTM';
    $o[] = '# TYPE web_analytics_search_terms_total counter';
    $rawTermMap = is_array($wa['search_terms'] ?? null) ? $wa['search_terms'] : [];
    $termMap = [];
    foreach ($rawTermMap as $tKey => $tCount) {
        [$tSite, $tTerm] = array_pad(explode('|', (string)$tKey, 2), 2, '');
        if ($tTerm !== '') {
            $normTerm = aiNormalizeSearchTerm($tTerm);
            $normKey = $tSite . '|' . $normTerm;
            $termMap[$normKey] = (int)($termMap[$normKey] ?? 0) + (int)$tCount;
        }
    }
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
            $o[] = 'web_analytics_search_terms_total{site="' . aiEsc($defSite) . '",term="(brak wpisanych fraz w wybranym okresie)"} 0';
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
        'chat_open'                => '💬 Otwarcie okna czatu AI',
        'quick_prompt_click'       => '⚡ Kliknięcie gotowej podpowiedzi pytania w czacie',
        'local_cache_hit'          => '🧠 Trafienie w lokalną pamięć podręczną przeglądarki (0 ms)',
        'cta_phone_click'          => '📞 Kliknięcie w numer telefonu (połączenie)',
        'cta_email_click'          => '✉️ Kliknięcie w adres e-mail (wiadomość)',
        'contact_form_submit'      => '📝 Wysłanie formularza kontaktowego',
        'radio_play'               => '📻 Uruchomienie odtwarzacza Radio Salsa',
        'outbound_click'           => '↗️ Kliknięcie w link zewnętrzny (szkoła / wydarzenie)',
        'copy_status_report'       => '📋 Skopiowanie raportu dostępności e-Zdrowia (Radar P1)',
        'export_csv'               => '📥 Pobranie pełnego raportu SLA do pliku CSV (Radar P1)',
        'nfz_region_select'        => '🗺️ Wybór oddziału wojewódzkiego NFZ na mapie Polski (Radar P1)',
        'wallboard_toggle'         => '📺 Przełączenie trybu pełnoekranowego TV (Radar P1)',
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
        'salsopedia'      => '📖 Salsopedia (słownik pojęć tanecznych)',
        'figures'         => '💃 Figury taneczne (Enchufla / Dile Que No)',
        'rueda'           => '🔄 Rueda de Casino i komendy',
        'music_clave'     => '🥁 Muzyka Salsa / Timba / Rytm Clave',
        'dance_styles'    => '🕺 Style tańca (Cubana / Bachata / Kizomba)',
        'radio'           => '📻 Radio Salsa / Timba Nation',
        'events_party'    => '🎉 Potańcówki i wydarzenia taneczne',
        'schools'         => '🎓 Szkoły tańca i instruktorzy w regionie',
        'spanish_trial'   => '🇪🇸 Bezpłatna lekcja próbna hiszpańskiego',
        'spanish_course'  => '📚 Kurs hiszpańskiego i nauka języka',
        'spanish_mode'    => '👥 Zajęcia indywidualne a grupowe',
        'spanish_biz'     => '💼 Hiszpański w biznesie i dla firm',
        'code_vs_wp'      => '⚡ Szybkie strony (czysty kod a WordPress)',
        'ai_rag_bot'      => '🤖 Wdrożenie czatbota AI (baza wiedzy RAG)',
        'seo_google'      => '🔍 Pozycjonowanie SEO i widoczność w Google',
        'pricing'         => '💰 Cennik i wycena usług (Ile kosztuje?)',
        'cooperation'     => '🤝 Zasady współpracy, zapisy i czas realizacji',
        'p1_erecepta'     => '💊 Awaria e-Recepty / DRR / e-Skierowania (Radar P1)',
        'nfz_ewus_szoi'   => '🏥 Awaria eWUŚ / SZOI / Rozliczenia NFZ (Radar P1)',
        'ksef_ezla'       => '📑 Tryb awaryjny KSeF / ZUS e-ZLA (Radar P1)',
        'p1_errors_sla'   => '⚠️ Kody błędów P1 (502/504, WSP/OCSP, RZM) (Radar P1)',
        'contact_lead'    => '📞 Pozyskany kontakt od klienta (Telefon / E-mail)',
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
        $rawPPvMap = is_array($pCfg['bucket']['pageviews'] ?? null) ? $pCfg['bucket']['pageviews'] : [];
        $pPvMap = [];
        foreach ($rawPPvMap as $pvKey => $pvCount) {
            [$pvSite, $pvPath] = array_pad(explode('|', (string)$pvKey, 2), 2, '/');
            $normPath = aiNormalizeAnalyticsPath($pvPath);
            $normKey = $pvSite . '|' . $normPath;
            $pPvMap[$normKey] = (int)($pPvMap[$normKey] ?? 0) + (int)$pvCount;
        }
        foreach ($knownSites as $defSite) {
            if (!isset($pPvMap[$defSite . '|/'])) {
                $pPvMap[$defSite . '|/'] = 0;
            }
        }
        foreach ($pPvMap as $pvKey => $pvCount) {
            [$pvSite, $pvPath] = array_pad(explode('|', (string)$pvKey, 2), 2, '/');
            $pvLabel = $pathLabels[$pvPath] ?? ('📄 Podstrona: ' . $pvPath);
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
        $rawPTermMap = is_array($pCfg['bucket']['search_terms'] ?? null) ? $pCfg['bucket']['search_terms'] : [];
        $pTermMap = [];
        foreach ($rawPTermMap as $tKey => $tCount) {
            [$tSite, $tTerm] = array_pad(explode('|', (string)$tKey, 2), 2, '');
            if ($tTerm !== '') {
                $normTerm = aiNormalizeSearchTerm($tTerm);
                $normKey = $tSite . '|' . $normTerm;
                $pTermMap[$normKey] = (int)($pTermMap[$normKey] ?? 0) + (int)$tCount;
            }
        }
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
                $o[] = 'web_analytics_period_search_terms{site="' . aiEsc($defSite) . '",term="(brak wpisanych fraz w wybranym okresie)",period="' . $pName . '"} 0';
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
            $qEsc = aiEsc(aiNormalizeGscQuery((string)$row['query']));
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
                ? '(integracja GSC aktywna — oczekuje na pierwsze wyświetlenia w Google)'
                : '(oczekuje na synchronizację z Google Search Console)';
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
