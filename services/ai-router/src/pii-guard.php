<?php
declare(strict_types=1);

/**
 * Deterministyczna Walidacja i Maskowanie Polskich Danych Osobowych PII (ISO 27001 / RODO)
 * Adaptacja algorytmów sum kontrolnych i pseudonimizacji HMAC-SHA256 z projektu polanon (MIT).
 *
 * UWAGA ARCHITEKTONICZNA:
 * Moduł celowo NIE maskuje numerów telefonów ani adresów e-mail w zgłoszeniach kontaktowych,
 * aby nie blokować kontaktu zwrotnego z klientem (Ntfy 1-Klik / osTicket).
 * Chroni natomiast przed nadmiarowym przetwarzaniem i wyciekiem wrażliwych identyfikatorów:
 * PESEL, seria i numer dowodu osobistego, NIP, REGON oraz rachunki bankowe IBAN/NRB.
 */

/**
 * Waliduje polski numer PESEL (11 cyfr, wagi [1,3,7,9,1,3,7,9,1,3] mod 10, stulecia 1800–2299).
 */
function is_valid_pesel(string $raw): bool {
    $s = (string)preg_replace('/[\s-]+/', '', $raw);
    if (!preg_match('/^\d{11}$/', $s)) {
        return false;
    }

    $month = ((int)substr($s, 2, 2)) % 20;
    $day = (int)substr($s, 4, 2);
    if ($month < 1 || $month > 12 || $day < 1 || $day > 31) {
        return false;
    }

    $weights = [1, 3, 7, 9, 1, 3, 7, 9, 1, 3];
    $sum = 0;
    for ($i = 0; $i < 10; $i++) {
        $sum += ((int)$s[$i]) * $weights[$i];
    }

    $check = (10 - ($sum % 10)) % 10;
    return $check === (int)$s[10];
}

/**
 * Waliduje polski numer NIP (10 cyfr z opcjonalnym prefiksem PL, wagi [6,5,7,2,3,4,5,6,7] mod 11).
 */
function is_valid_nip(string $raw): bool {
    $s = strtoupper((string)preg_replace('/[\s-]+/', '', $raw));
    if (strpos($s, 'PL') === 0) {
        $s = substr($s, 2);
    }
    if (!preg_match('/^\d{10}$/', $s)) {
        return false;
    }

    $weights = [6, 5, 7, 2, 3, 4, 5, 6, 7];
    $sum = 0;
    for ($i = 0; $i < 9; $i++) {
        $sum += ((int)$s[$i]) * $weights[$i];
    }

    $mod = $sum % 11;
    return $mod !== 10 && $mod === (int)$s[9];
}

/**
 * Waliduje polski numer REGON (9-cyfrowy oraz 14-cyfrowy).
 */
function is_valid_regon(string $raw): bool {
    $s = (string)preg_replace('/[\s-]+/', '', $raw);
    if (preg_match('/^\d{9}$/', $s)) {
        $weights = [8, 9, 2, 3, 4, 5, 6, 7];
        $sum = 0;
        for ($i = 0; $i < 8; $i++) {
            $sum += ((int)$s[$i]) * $weights[$i];
        }
        $check = ($sum % 11) % 10;
        return $check === (int)$s[8];
    }

    if (preg_match('/^\d{14}$/', $s)) {
        if (!is_valid_regon(substr($s, 0, 9))) {
            return false;
        }
        $weights14 = [2, 4, 8, 5, 0, 9, 7, 3, 6, 1, 2, 4, 8];
        $sum = 0;
        for ($i = 0; $i < 13; $i++) {
            $sum += ((int)$s[$i]) * $weights14[$i];
        }
        $check = ($sum % 11) % 10;
        return $check === (int)$s[13];
    }

    return false;
}

/**
 * Waliduje serię i numer polskiego dowodu osobistego ([A-Z]{3}\d{6}, wagi [7,3,1,0,7,3,1,7,3] mod 10).
 */
function is_valid_pl_id(string $raw): bool {
    $s = strtoupper((string)preg_replace('/[\s-]+/', '', $raw));
    if (!preg_match('/^[A-Z]{3}\d{6}$/', $s)) {
        return false;
    }

    $weights = [7, 3, 1, 0, 7, 3, 1, 7, 3];
    $sum = 0;
    for ($i = 0; $i < 9; $i++) {
        $val = $i < 3 ? (ord($s[$i]) - 55) : (int)$s[$i];
        $sum += $val * $weights[$i];
    }

    return ($sum % 10) === (int)$s[3];
}

/**
 * Generuje deterministyczny 12-cyfrowy pseudonim HMAC-SHA256 z separacją domen (wzorzec polanon/pseudonyms.py).
 */
function pseudonymize_entity_hmac(
    string $canonicalValue,
    string $label,
    string $secretKey,
    string $scope = 'default'
): string {
    $normVal = mb_strtolower(trim($canonicalValue), 'UTF-8');
    $cleanLabel = strtoupper((string)preg_replace('/[^a-zA-Z0-9_]/', '', $label)) ?: 'ENTITY';
    $hex = hash_hmac('sha256', "polanon-pseudonyms/1\0{$scope}\0{$cleanLabel}\0{$normVal}", $secretKey);
    $num = ((int)hexdec(substr($hex, 0, 12))) % 1000000000000;
    return sprintf('<%s_%012d>', $cleanLabel, $num);
}

/**
 * Wykrywa i maskuje w tekście wrażliwe polskie identyfikatory PII:
 * - numery PESEL (zarówno przechodzące sumę kontrolną, jak i 11 cyfr występujących bezpośrednio po słowie PESEL) -> <PESEL_1>,
 * - numery dowodów osobistych -> <DOWOD_1>,
 * - 26-cyfrowe rachunki bankowe IBAN PL -> <IBAN_1>.
 *
 * Celowo NIE maskuje numeru telefonu ani adresu e-mail, aby zachować drożność kontaktu z klientem.
 *
 * @return array{masked: string, replacements: array<string, string>, count: int}
 */
function mask_sensitive_pl_pii(string $text): array {
    $map = [];
    $counters = [
        'PESEL' => 0,
        'DOWOD' => 0,
        'IBAN'  => 0,
        'ADRES' => 0,
    ];

    $assignToken = static function (string $type, string $original) use (&$map, &$counters): string {
        foreach ($map as $token => $storedOrig) {
            if ($storedOrig === $original) {
                return $token;
            }
        }
        $counters[$type]++;
        $token = "<{$type}_{$counters[$type]}>";
        $map[$token] = $original;
        return $token;
    };

    $maskedText = $text;

    // 1. 26-cyfrowe numery kont IBAN PL (np. PL + 26 cyfr, opcjonalnie rozdzielone spacjami)
    $maskedText = (string)preg_replace_callback(
        '/\bPL\s*(?:\d\s*){26}\b/i',
        static function (array $m) use ($assignToken): string {
            $raw = trim($m[0]);
            return $assignToken('IBAN', $raw);
        },
        $maskedText
    );

    // 2. 11 cyfr występujących bezpośrednio po słowie PESEL (nawet jeśli mają literówkę w cyfrze kontrolnej)
    $maskedText = (string)preg_replace_callback(
        '/\b(pesel[\s:#=-]{0,10})(\d{11})\b/i',
        static function (array $m) use ($assignToken): string {
            return $m[1] . $assignToken('PESEL', $m[2]);
        },
        $maskedText
    );

    // 3. Dowolne 11-cyfrowe ciągi przechodzące sumę kontrolną PESEL (z wykluczeniem prefiksu +48)
    $maskedText = (string)preg_replace_callback(
        '/(?<![+\d])\b\d{11}\b/',
        static function (array $m) use ($assignToken): string {
            if (is_valid_pesel($m[0])) {
                return $assignToken('PESEL', $m[0]);
            }
            return $m[0];
        },
        $maskedText
    );

    // 4a. Seria i numer dowodu osobistego po słowie kluczowym "dowód" / "seria"
    $maskedText = (string)preg_replace_callback(
        '/\b((?:dow[oó]d(?:\s+osobisty)?|nr\s+dowodu|seri[ai])[\s:#=-]{0,12})([A-Z]{3}\s?\d{6})\b/iu',
        static function (array $m) use ($assignToken): string {
            return $m[1] . $assignToken('DOWOD', trim($m[2]));
        },
        $maskedText
    );

    // 4b. Seria i numer dowodu osobistego (przechodzące sumę kontrolną is_valid_pl_id)
    $maskedText = (string)preg_replace_callback(
        '/\b[A-Z]{3}\s?\d{6}\b/',
        static function (array $m) use ($assignToken): string {
            if (is_valid_pl_id($m[0])) {
                return $assignToken('DOWOD', $m[0]);
            }
            return $m[0];
        },
        $maskedText
    );

    // 5. Polskie adresy uliczne odporne na wykładniczy backtracking ReDoS
    // (port wzorca z polanon/recognizers_pl.py z limitem słów ulicy <= 8 po prefiksie ul./ulica/al./os./pl.)
    $maskedText = (string)preg_replace_callback(
        '/\b(?:ul\.|ulica|ulicy|al\.|aleja|alei|os\.|osiedle|osiedlu|pl\.|plac|placu)[ \t]+[\p{L}\d][\p{L}\d.\'-]{0,30}(?:[ \t]+[\p{L}][\p{L}.\'-]{0,30}){0,7}[ \t]+\d{1,4}[a-zA-Z]?(?:[ \t]*\/[ \t]*\d{1,4}[a-zA-Z]?|[ \t]+(?:m\.?|lok\.?)[ \t]*\d{1,4}[a-zA-Z]?)?\b/iu',
        static function (array $m) use ($assignToken): string {
            return $assignToken('ADRES', trim($m[0]));
        },
        $maskedText
    );

    return [
        'masked'       => $maskedText,
        'replacements' => $map,
        'count'        => count($map),
    ];
}

/**
 * Strumieniowe przywracanie zamaskowanych tokenów PII w chunkach SSE z LLM (port StreamRestorer z polanon/stream_restore.py).
 * Przytrzymuje w $carryBuffer niedomkniętą końcówkę pasującą do /<[A-Z_]*\d*$/ (do 32 znaków)
 * i podmienia tokeny z $replacements dopiero po domknięciu nawiasu `>`, dzięki czemu
 * streaming SSE nigdy nie rozetnie tokenu np. `<PESEL_1>`, `<OSOBA_1>` czy `<ADRES_1>`.
 *
 * @param string $chunk Nowy fragment strumienia tekstu
 * @param string &$carryBuffer Bufor przeniesienia pomiędzy chunkami
 * @param array<string, string> $replacements Mapa token -> wartość oryginalna
 */
function restore_stream_chunk(string $chunk, string &$carryBuffer, array $replacements): string {
    $combined = $carryBuffer . $chunk;
    $carryBuffer = '';

    if ($combined === '') {
        return '';
    }

    if (preg_match('/<[A-Z_]*\d*$/', $combined, $m, PREG_OFFSET_CAPTURE)) {
        $matchStr = $m[0][0];
        $matchOffset = (int)$m[0][1];
        if (strlen($matchStr) <= 32) {
            $carryBuffer = $matchStr;
            $combined = substr($combined, 0, $matchOffset);
        }
    }

    if ($combined === '' || empty($replacements)) {
        return $combined;
    }

    return strtr($combined, $replacements);
}

/**
 * Opróżnia bufor przeniesienia po zakończeniu strumienia SSE (port StreamRestorer.flush z polanon/stream_restore.py).
 *
 * @param string &$carryBuffer Bufor przeniesienia
 * @param array<string, string> $replacements Mapa token -> wartość oryginalna
 */
function flush_stream_restorer(string &$carryBuffer, array $replacements): string {
    if ($carryBuffer === '') {
        return '';
    }

    $remaining = $carryBuffer;
    $carryBuffer = '';

    if (empty($replacements)) {
        return $remaining;
    }

    return strtr($remaining, $replacements);
}
