<?php
declare(strict_types=1);

/**
 * AI Router - Słowniki Normalizacji i Etykiet dla Cookieless Web Analytics v3 & GSC Sync.
 *
 * Wydzielony z web-analytics.php w celu zachowania Single Responsibility Principle (SRP)
 * i redukcji rozmiaru pliku głównego silnika analitycznego.
 */

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
 * Zwraca reguły klasyfikacji tematów pytań do czatbota AI: [kod_tematu, regex, fraza_kanoniczna].
 */
function aiGetTopicExtractionRules(): array
{
    return [
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
}

/**
 * Zwraca słowniki czytelnych polskich etykiet dla dashboardu Grafany (path, source, device, country, event, topic).
 */
function aiGetWebAnalyticsLabelDictionaries(): array
{
    static $dicts = null;
    if ($dicts !== null) {
        return $dicts;
    }

    $dicts = [
        'path' => [
            '/'                          => '🏠 / (Strona główna)',
            '/salsopedia.html'           => '📖 /salsopedia.html (Słownik Salsopedii)',
            '/grafik.html'               => '📅 /grafik.html (Wspólny Grafik Szkół Tańca)',
            '/grafik.html#SalsaKatowice' => '📅 /grafik.html#SalsaKatowice (Grafik — Salsa Katowice)',
            '/jak-pracuje.html'          => '⚙️ /jak-pracuje.html (Jak pracuję — etapy i gwarancje)',
            '/cennik.html'               => '💰 /cennik.html (Cennik kursów hiszpańskiego)',
            '/privacy.html'              => '🔒 /privacy.html (Polityka prywatności)',
            '/pakiety'                   => '🍽️ /pakiety (Pakiety i wycena Raricart)',
            '/pakiety.php'               => '🍽️ /pakiety.php (Pakiety i wycena Raricart)',
            '/polityka-prywatnosci'      => '🔒 /polityka-prywatnosci (Polityka prywatności)',
            '/polityka-prywatnosci.php'  => '🔒 /polityka-prywatnosci.php (Polityka prywatności)',
            '/#hero'                     => '✨ /#hero (Sekcja powitalna — Góra strony)',
            '/#onas'                     => '👥 /#onas (O nas)',
            '/#oferta'                   => '🥂 /#oferta (Oferta i stacje kulinarne)',
            '/#oferta-lista'             => '📋 /#oferta-lista (Lista pakietów i usług)',
            '/#offer-pancakes'           => '🥞 /#offer-pancakes (Stacja Mini Pancakes)',
            '/#realizacje'               => '📸 /#realizacje (Galeria realizacji)',
            '/#szkoly'                   => '🎓 /#szkoly (Szkoły tańca w regionie)',
            '/#wydarzenia'               => '🎉 /#wydarzenia (Wydarzenia i potańcówki)',
            '/#radio'                    => '📻 /#radio (Radio Salsa na żywo)',
            '/#mapa'                     => '🗺️ /#mapa (Mapa szkół i lokalizacji)',
            '/#style'                    => '💃 /#style (Style taneczne)',
            '/#artykuly'                 => '📰 /#artykuly (Artykuły i poradniki)',
            '/#slownik'                  => '📚 /#slownik (Słownik pojęć)',
            '/#faq'                      => '❓ /#faq (Częste pytania i odpowiedzi)',
            '/#cennik'                   => '💰 /#cennik (Oferta i cennik)',
            '/#pricing'                  => '💰 /#pricing (Pakiety i cennik)',
            '/#portfolio'                => '🚀 /#portfolio (Realizacje i wdrożenia)',
            '/#proces'                   => '🛠️ /#proces (Etapy realizacji współpracy)',
            '/#dla-kogo'                 => '🎯 /#dla-kogo (Dla kogo tworzymy strony)',
            '/#contact'                  => '📞 /#contact (Formularz wyceny i kontaktu)',
            '/#kontakt'                  => '📞 /#kontakt (Sekcja kontaktu)',
            '/#kursy'                    => '🇪🇸 /#kursy (Kursy języka hiszpańskiego)',
            '/#section-white'            => '🏥 /#section-white (Usługi kliniczne P1 i NFZ)',
            '/#section-grey'             => '💊 /#section-grey (Usługi apteczne, KSeF i ERP)',
            '/#geo-poland-section'       => '🗺️ /#geo-poland-section (Mapa 16 oddziałów NFZ)',
            '/#section-watcher'          => '🔭 /#section-watcher (Radar zmian legislacyjnych)',
            '/#glossary-section'         => '📖 /#glossary-section (Słownik awarii e-Zdrowia)',
            '/#faq-section'              => '❓ /#faq-section (Pytania i odpowiedzi e-Zdrowia)',
        ],
        'source' => [
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
        ],
        'device' => [
            'mobile'  => '📱 Smartfon / Telefon komórkowy',
            'tablet'  => '📲 Tablet',
            'desktop' => '💻 Komputer stacjonarny / Laptop',
        ],
        'country' => [
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
        ],
        'event' => [
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
        ],
        'topic' => [
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
        ],
    ];

    return $dicts;
}
