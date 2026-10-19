<?php
/**
 * Moduł Hybrydowego RAG Dual-Stream (SQLite FTS5 BM25) dla dokumentacji i struktury bazy Asseco AMMS (383 pliki).
 *
 * Obsługuje:
 *  - Strumień 1: 314 oficjalnych podręczników i ksiąg konfiguracji PDF (z dokładnymi numerami stron str. X)
 *  - Strumień 2: 69 plików architektury i struktury bazy danych Oracle AMMS (tabele, kolumny, klucze obce FK,
 *                widoki SQL, pakiety PL/SQL, parametry, WildFly, raporty BIRT, OpenAPI REST i SOAP WSDL)
 *  - Generowanie danych do wizualnych zrzutów stron (Page Snapshots) dla czatu w stylu Microsoft Teams
 *  - Adaptacyjną detekcję poziomu rozumowania (Smart Reasoning Tiering: fast / standard / high)
 *
 * Wymagania: PHP 8.x z rozszerzeniem pdo_sqlite.
 */

declare(strict_types=1);

class AmmsRagSearch
{
    private PDO $pdo;

    /** Polskie spójniki i słowa ogólne pomijane w zapytaniach FTS5 */
    private const STOP_WORDS = [
        'jak', 'jaki', 'jaka', 'jakie', 'czy', 'gdzie', 'kiedy', 'jest', 'sa', 'są',
        'oraz', 'albo', 'lub', 'dla', 'pod', 'nad', 'przy', 'tym', 'tego', 'tej',
        'aby', 'sie', 'się', 'nie', 'tak', 'ktory', 'ktora', 'ktore', 'której', 'ktorym',
        'stronie', 'strona', 'strony', 'pokaz', 'pokaż', 'powiedz', 'opisz', 'wyjasnij',
        'wyjaśnij', 'prosze', 'proszę', 'mam', 'chce', 'chcę', 'mozna', 'można',
        'systemie', 'systemu', 'system', 'amms', 'programie', 'aplikacji', 'baza', 'bazie'
    ];

    public function __construct(string $sqliteFilePath)
    {
        if (!is_file($sqliteFilePath)) {
            throw new RuntimeException("Brak pliku bazy wiedzy AMMS: {$sqliteFilePath}");
        }

        $this->pdo = new PDO('sqlite:' . $sqliteFilePath, null, null, [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]);
        $this->pdo->exec('PRAGMA query_only = ON;');
        $this->pdo->exec('PRAGMA temp_store = MEMORY;');
    }

    /**
     * Automatycznie określa optymalny poziom rozumowania (Reasoning Level) na podstawie pytania i wyboru w UI.
     *
     * @return array{tier: string, label: string, is_db_query: bool}
     */
    public static function detectReasoningProfile(string $userQuestion, string $requestedMode = 'auto'): array
    {
        $mode = strtolower(trim($requestedMode));
        $isDbOrArch = self::isDatabaseOrArchitectureQuery($userQuestion);

        if ($mode === 'fast' || $mode === 'low' || $mode === 'minimal') {
            return [
                'tier'        => 'fast',
                'label'       => 'Szybki (LOW Reasoning)',
                'is_db_query' => $isDbOrArch,
            ];
        }

        if ($mode === 'high' || $mode === 'deep') {
            return [
                'tier'        => 'high',
                'label'       => 'Głęboka Analiza (HIGH Reasoning)',
                'is_db_query' => $isDbOrArch,
            ];
        }

        // Tryb Adaptacyjny (Auto):
        // Dla pytań o strukturę bazy Oracle, tabele, klucze obce, SQL, PL/SQL, integracje lub złożone problemy -> HIGH
        $qLower = mb_strtolower($userQuestion, 'UTF-8');
        $complexReasoningPattern = '/\b(sql|select|join|from|where|tabel[aięy]|kolumn[ayę]|klucz\s+obcy|foreign\s+key|relacj[aei]|schemat|struktura\s+bazy|oracle|pl\/?sql|pakiet|procedur[ay]|widok|view|birt|jrxml|wildfly|hazelcast|hl7|rest|soap|wsdl|openapi|dlaczego|przyczyn[ay]|błąd|blad|ora-\d+|porównaj|architektur[ay]|optymalizacj[ai])\b/iu';

        if ($isDbOrArch || preg_match($complexReasoningPattern, $qLower) || mb_strlen($userQuestion, 'UTF-8') > 130) {
            return [
                'tier'        => 'high',
                'label'       => 'Auto -> Głęboka Analiza (HIGH Reasoning)',
                'is_db_query' => true,
            ];
        }

        return [
            'tier'        => 'standard',
            'label'       => 'Auto -> Szybki Ekspert Dokumentacji (Fast RAG)',
            'is_db_query' => false,
        ];
    }

    /**
     * Sprawdza, czy pytanie dotyczy głównie struktury bazy danych Oracle, tabel, SQL lub architektury technicznej.
     */
    public static function isDatabaseOrArchitectureQuery(string $userQuestion): bool
    {
        $qLower = mb_strtolower($userQuestion, 'UTF-8');
        if (preg_match('/\b(tabel[aięy]|kolumn[ayę]|klucz|relacj[aei]|foreign\s+key|fk_|pk_|sql|select|oracle|plsql|pl\/sql|widok|view|slownik\s+tabel|struktura\s+bazy|birt|jrxml|wildfly|openapi|wsdl|soap|rest\s+api)\b/iu', $qLower)) {
            return true;
        }
        // Wykrywanie nazw technicznych z podkreślnikiem (np. AD_USER, PERSONNEL_ID)
        if (preg_match('/\b[a-z]{2,12}_[a-z0-9_]{2,25}\b/i', $userQuestion)) {
            return true;
        }
        return false;
    }

    /**
     * Buduje tokeny FTS5 oraz listę słów kluczowych do podświetlenia na zrzutach stron.
     *
     * @return array{fts_query: string, highlight_words: string[]}
     */
    public function parseQueryTokens(string $userQuestion): array
    {
        $clean = preg_replace('/[^\p{L}\p{N}\s_.-]+/u', ' ', $userQuestion);
        $rawWords = preg_split('/\s+/u', trim((string)$clean), -1, PREG_SPLIT_NO_EMPTY) ?: [];

        $tokens = [];
        $highlightWords = [];

        foreach ($rawWords as $w) {
            $trimmed = trim($w, "._-");
            if ($trimmed === '') {
                continue;
            }
            $lower = mb_strtolower($trimmed, 'UTF-8');
            if (mb_strlen($lower, 'UTF-8') < 2 || in_array($lower, self::STOP_WORDS, true)) {
                continue;
            }

            $safe = str_replace('"', '""', $lower);
            $tokens[] = '"' . $safe . '"*';
            $highlightWords[] = $lower;

            // Rdzeń słowa (stemming fleksyjny, np. "pobyty" -> "pobyt"*, "pacjenta" -> "pacjent"*)
            $charLen = mb_strlen($lower, 'UTF-8');
            if ($charLen >= 6) {
                $stem = mb_substr($lower, 0, $charLen - 2, 'UTF-8');
                if (mb_strlen($stem, 'UTF-8') >= 4 && !in_array($stem, self::STOP_WORDS, true)) {
                    $tokens[] = '"' . str_replace('"', '""', $stem) . '"*';
                    $highlightWords[] = $stem;
                }
            }

            // Wersja bez polskich znaków diakrytycznych (nazwy tabel/kolumn/pakietów w Oracle AMMS, np. PRZYJECIE, POBYT, ZLECENIE)
            $ascii = strtr($lower, [
                'ą' => 'a', 'ć' => 'c', 'ę' => 'e', 'ł' => 'l', 'ń' => 'n',
                'ó' => 'o', 'ś' => 's', 'ź' => 'z', 'ż' => 'z'
            ]);
            if ($ascii !== $lower && strlen($ascii) >= 4) {
                $tokens[] = '"' . str_replace('"', '""', $ascii) . '"*';
                if (strlen($ascii) >= 6) {
                    $tokens[] = '"' . str_replace('"', '""', substr($ascii, 0, -2)) . '"*';
                }
            }

            // Jeśli token zawiera podkreślnik lub kropkę (np. AD.AD_USER lub PERSONNEL_ID), dodaj też pod-tokeny
            if (str_contains($lower, '_') || str_contains($lower, '.')) {
                foreach (preg_split('/[_.-]+/u', $lower, -1, PREG_SPLIT_NO_EMPTY) ?: [] as $sub) {
                    if (mb_strlen($sub, 'UTF-8') >= 2 && !in_array($sub, self::STOP_WORDS, true)) {
                        $tokens[] = '"' . str_replace('"', '""', $sub) . '"*';
                        $highlightWords[] = $sub;
                    }
                }
            }

            // Rozszerzenia skrótów medycznych / AMMS
            if ($lower === 'ip') {
                $tokens[] = '"izba"*';
                $tokens[] = '"przyjec"*';
                $highlightWords[] = 'izba';
            } elseif ($lower === 'sor') {
                $tokens[] = '"ratunkow"*';
            }
        }

        $tokens = array_values(array_unique($tokens));
        $highlightWords = array_values(array_unique($highlightWords));

        if (empty($tokens)) {
            return ['fts_query' => '', 'highlight_words' => []];
        }

        $ftsQuery = implode(' OR ', array_slice($tokens, 0, 28));
        return [
            'fts_query'       => $ftsQuery,
            'highlight_words' => array_slice($highlightWords, 0, 16),
        ];
    }

    /**
     * Dwustrumieniowe wyszukiwanie hybrydowe (PDF + Struktura Bazy Oracle AMMS):
     * Zwraca gotowy kontekst dla promptu LLM oraz bogatą listę źródeł ze zrzutami stron dla UI w stylu Teams.
     *
     * @return array{context: string, sources: array<int, array<string, mixed>>, stats: array<string, mixed>}
     */
    public function searchKnowledge(
        string $userQuestion,
        int $topK = 14,
        int $maxContextBytes = 68000,
        string $pdfBaseUrl = '/docs-pdf/'
    ): array {
        $t0 = microtime(true);
        $parsed = $this->parseQueryTokens($userQuestion);
        $ftsQuery = $parsed['fts_query'];
        $highlightWords = $parsed['highlight_words'];

        if ($ftsQuery === '') {
            return ['context' => '', 'sources' => [], 'stats' => ['ms' => 0, 'chunks' => 0]];
        }

        $isDbQuery = self::isDatabaseOrArchitectureQuery($userQuestion);
        // Podział slotów między dokumentację PDF (strony) a strukturę bazy Oracle / architekturę
        $pdfLimit  = $isDbQuery ? max(5, (int)floor($topK * 0.45)) : max(8, (int)ceil($topK * 0.65));
        $techLimit = max(5, $topK - $pdfLimit + 2);

        $sqlStream = "
            SELECT
                c.id,
                c.citation,
                c.source_file,
                c.page,
                c.part,
                bm25(chunks_fts, 2.5, 3.5, 1.0) AS rank_score,
                c.content
            FROM chunks_fts
            JOIN chunks c ON c.id = chunks_fts.rowid
            WHERE chunks_fts MATCH :query
            ORDER BY rank_score ASC
            LIMIT :limit
        ";

        // Strumień 1: Oficjalne podręczniki PDF z dokładnymi numerami stron (str. X)
        $stmtPdf = $this->pdo->prepare($sqlStream);
        $stmtPdf->bindValue(':query', "({$ftsQuery}) AND source_file : \"pdf\"", PDO::PARAM_STR);
        $stmtPdf->bindValue(':limit', $pdfLimit, PDO::PARAM_INT);
        $stmtPdf->execute();
        $pdfRows = $stmtPdf->fetchAll();

        // Strumień 2: Struktura Bazy Oracle AMMS (01..10, tabele, FK, widoki SQL, PL/SQL, API) z pominięciem duplikatów HTML_czesc
        $stmtTech = $this->pdo->prepare($sqlStream);
        $stmtTech->bindValue(':query', "({$ftsQuery}) NOT source_file : \"pdf\" NOT source_file : \"HTML_czesc\"", PDO::PARAM_STR);
        $stmtTech->bindValue(':limit', $techLimit, PDO::PARAM_INT);
        $stmtTech->execute();
        $techRows = $stmtTech->fetchAll();

        // Przeplatanie (Interleaving) najlepszych trafień z obu strumieni, aby w kartach wizualnych (Top 6)
        // zawsze znalazły się zarówno strony PDF (str. X), jak i schematy bazy danych Oracle (cz. Y)
        $mergedRows = [];
        $maxLen = max(count($pdfRows), count($techRows));
        for ($i = 0; $i < $maxLen; $i++) {
            if ($isDbQuery) {
                if (isset($techRows[$i])) {
                    $mergedRows[] = $techRows[$i];
                }
                if (isset($pdfRows[$i])) {
                    $mergedRows[] = $pdfRows[$i];
                }
            } else {
                if (isset($pdfRows[$i])) {
                    $mergedRows[] = $pdfRows[$i];
                }
                if (isset($techRows[$i])) {
                    $mergedRows[] = $techRows[$i];
                }
            }
        }

        $mergedRows = array_slice($mergedRows, 0, $topK);
        if (empty($mergedRows)) {
            return ['context' => '', 'sources' => [], 'stats' => ['ms' => round((microtime(true) - $t0) * 1000, 2), 'chunks' => 0]];
        }

        $contextBlocks = [
            "=== KONTEKST Z BAZY WIEDZY SYSTEMU ASSECO AMMS (DOKUMENTACJA PDF + STRUKTURA BAZY ORACLE) ===",
            "Instrukcja: Odpowiadaj ściśle na podstawie poniższych fragmentów. Zawsze podawaj dokładne cytowanie źródła i numeru strony w formacie [Nazwa_pliku.pdf, str. X] lub [Nazwa_pliku_bazy.txt, cz. Y].\n"
        ];

        $currentBytes = 0;
        $sourcesMap = [];

        foreach ($mergedRows as $idx => $row) {
            $num = $idx + 1;
            $sourceFile = (string)$row['source_file'];
            $page = (int)$row['page'];
            $part = (int)$row['part'];
            $citation = (string)$row['citation'];
            $content = trim((string)$row['content']);

            $docCategory = self::classifySourceFile($sourceFile);
            $headerLabel = $docCategory === 'pdf'
                ? "DOKUMENTACJA PDF (Strona {$page})"
                : ($docCategory === 'oracle_db' ? "STRUKTURA BAZY ORACLE AMMS (Część {$part})" : "ARCHITEKTURA / API AMMS (Część {$part})");

            $block = "--- FRAGMENT #{$num} [{$headerLabel}] | Źródło: {$citation} ---\n{$content}\n";
            $blockLen = strlen($block);

            if (($currentBytes + $blockLen) <= $maxContextBytes) {
                $contextBlocks[] = $block;
                $currentBytes += $blockLen;
            }

            // Budowa karty źródła / wizualnego zrzutu strony (max 6 unikalnych kart stron dla UI Teams)
            $sourceKey = $docCategory === 'pdf' ? "{$sourceFile}#p{$page}" : "{$sourceFile}#c{$part}";
            if (!isset($sourcesMap[$sourceKey]) && count($sourcesMap) < 6) {
                $isPdf = ($docCategory === 'pdf');
                $displayPage = $isPdf ? $page : $part;
                $totalPages = $this->getTotalPagesForFile($sourceFile, $isPdf);

                $sectionTitle = self::extractSectionTitle($content, $sourceFile);
                $highlightQuote = self::extractBestQuote($content, $highlightWords, 340);

                $pdfUrl = $isPdf
                    ? rtrim($pdfBaseUrl, '/') . '/' . rawurlencode($sourceFile) . '#page=' . $page
                    : null;
                $pageApiUrl = '/amms-page?file=' . rawurlencode($sourceFile)
                    . '&page=' . $page
                    . '&part=' . $part;

                $sourcesMap[$sourceKey] = [
                    'id'                 => 'src_' . (count($sourcesMap) + 1),
                    'citation'           => $citation,
                    'source_file'        => $sourceFile,
                    'doc_type'           => $docCategory,
                    'page'               => $displayPage,
                    'raw_page'           => $page,
                    'part'               => $part,
                    'total_pages'        => $totalPages,
                    'badge_label'        => $isPdf ? "Strona {$page} z {$totalPages}" : "Część {$part} z {$totalPages}",
                    'section_title'      => $sectionTitle,
                    'highlight_quote'    => $highlightQuote,
                    'highlight_keywords' => $highlightWords,
                    'page_snapshot_text' => mb_substr($content, 0, 1600, 'UTF-8'),
                    'preview_url'        => $pdfUrl,
                    'page_api_url'       => $pageApiUrl,
                ];
            }
        }

        return [
            'context' => implode("\n", $contextBlocks),
            'sources' => array_values($sourcesMap),
            'stats'   => [
                'ms'         => round((microtime(true) - $t0) * 1000, 2),
                'chunks'     => count($mergedRows),
                'pdf_hits'   => count($pdfRows),
                'tech_hits'  => count($techRows),
                'is_db_mode' => $isDbQuery,
            ],
        ];
    }

    /**
     * Kompatybilna wstecznie metoda zwracająca sam tekst kontekstu dla promptu LLM.
     */
    public function buildContextForPrompt(string $userQuestion, int $topK = 12, int $maxContextBytes = 65000): string
    {
        return $this->searchKnowledge($userQuestion, $topK, $maxContextBytes)['context'];
    }

    /**
     * Kompatybilna wstecznie metoda zwracająca dopasowane źródła z linkami do stron.
     */
    public function getMatchedSourcesWithPageLinks(string $userQuestion, string $pdfBaseUrl = '/docs-pdf/', int $topK = 5): array
    {
        $res = $this->searchKnowledge($userQuestion, max(8, $topK * 2), 65000, $pdfBaseUrl);
        return array_slice($res['sources'], 0, $topK);
    }

    /**
     * Pobiera pełną zawartość wskazanej strony PDF lub części pliku struktury bazy do podglądu / kartkowania w Lightboxie Teams.
     *
     * @return array<string, mixed>|null
     */
    public function getPageDetails(string $sourceFile, int $page = 1, int $part = 1): ?array
    {
        $sourceFile = trim($sourceFile);
        if ($sourceFile === '') {
            return null;
        }

        $isPdf = str_ends_with(strtolower($sourceFile), '.pdf');
        if ($isPdf) {
            $stmt = $this->pdo->prepare("
                SELECT id, citation, source_file, page, part, content
                FROM chunks
                WHERE source_file = :sf AND page = :page
                ORDER BY part ASC, id ASC
            ");
            $stmt->bindValue(':sf', $sourceFile, PDO::PARAM_STR);
            $stmt->bindValue(':page', max(1, $page), PDO::PARAM_INT);
            $stmt->execute();
            $rows = $stmt->fetchAll();
        } else {
            $targetPart = $part > 0 ? $part : max(1, $page);
            $stmt = $this->pdo->prepare("
                SELECT id, citation, source_file, page, part, content
                FROM chunks
                WHERE source_file = :sf AND part = :part
                ORDER BY id ASC
            ");
            $stmt->bindValue(':sf', $sourceFile, PDO::PARAM_STR);
            $stmt->bindValue(':part', $targetPart, PDO::PARAM_INT);
            $stmt->execute();
            $rows = $stmt->fetchAll();
        }

        if (empty($rows)) {
            return null;
        }

        $combinedText = implode("\n\n", array_map(static fn(array $r): string => trim((string)$r['content']), $rows));
        $totalPages = $this->getTotalPagesForFile($sourceFile, $isPdf);
        $currentNum = $isPdf ? (int)$rows[0]['page'] : (int)$rows[0]['part'];

        return [
            'source_file'   => $sourceFile,
            'citation'      => (string)$rows[0]['citation'],
            'doc_type'      => self::classifySourceFile($sourceFile),
            'is_pdf'        => $isPdf,
            'current_page'  => $currentNum,
            'total_pages'   => $totalPages,
            'has_prev'      => $currentNum > 1,
            'has_next'      => $currentNum < $totalPages,
            'prev_page'     => max(1, $currentNum - 1),
            'next_page'     => min($totalPages, $currentNum + 1),
            'section_title' => self::extractSectionTitle($combinedText, $sourceFile),
            'content'       => $combinedText,
        ];
    }

    private function getTotalPagesForFile(string $sourceFile, bool $isPdf): int
    {
        static $cache = [];
        $key = $sourceFile . '|' . ($isPdf ? 'p' : 'c');
        if (isset($cache[$key])) {
            return $cache[$key];
        }

        $col = $isPdf ? 'page' : 'part';
        $stmt = $this->pdo->prepare("SELECT MAX({$col}) FROM chunks WHERE source_file = :sf");
        $stmt->bindValue(':sf', $sourceFile, PDO::PARAM_STR);
        $stmt->execute();
        $max = (int)$stmt->fetchColumn();
        $cache[$key] = max(1, $max);
        return $cache[$key];
    }

    private static function classifySourceFile(string $sourceFile): string
    {
        $lower = strtolower($sourceFile);
        if (str_ends_with($lower, '.pdf')) {
            return 'pdf';
        }
        if (preg_match('/^(0[1-7]|09|10)_/', $lower)) {
            return 'oracle_db';
        }
        return 'architecture';
    }

    private static function extractSectionTitle(string $content, string $sourceFile): string
    {
        $lines = preg_split('/\r?\n/u', trim($content)) ?: [];
        foreach (array_slice($lines, 0, 8) as $line) {
            $trimmed = trim($line, " \t#=-*");
            if (mb_strlen($trimmed, 'UTF-8') >= 5 && mb_strlen($trimmed, 'UTF-8') <= 110) {
                return $trimmed;
            }
        }
        return preg_replace('/\.(pdf|txt|yaml)$/i', '', $sourceFile) ?: $sourceFile;
    }

    /**
     * Wyciąga najbardziej reprezentatywne zdanie/akapit zawierające słowa kluczowe pytania (do żółtego zakreślacza).
     *
     * @param string[] $keywords
     */
    private static function extractBestQuote(string $content, array $keywords, int $maxLen = 340): string
    {
        $normalized = trim((string)preg_replace('/\s+/u', ' ', $content));
        if (mb_strlen($normalized, 'UTF-8') <= $maxLen) {
            return $normalized;
        }

        $lowerContent = mb_strtolower($normalized, 'UTF-8');
        $bestPos = 0;
        foreach ($keywords as $kw) {
            if (mb_strlen($kw, 'UTF-8') < 3) {
                continue;
            }
            $pos = mb_stripos($lowerContent, $kw, 0, 'UTF-8');
            if ($pos !== false) {
                $bestPos = max(0, $pos - 60);
                break;
            }
        }

        $slice = mb_substr($normalized, $bestPos, $maxLen, 'UTF-8');
        if ($bestPos > 0) {
            $slice = '…' . ltrim($slice);
        }
        if (($bestPos + $maxLen) < mb_strlen($normalized, 'UTF-8')) {
            $slice = rtrim($slice) . '…';
        }
        return $slice;
    }
}
