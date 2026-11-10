<?php
declare(strict_types=1);

/**
 * AI Router Lead Extraction & Notification Dispatcher — TwojaStronaWWW DevOps Stack
 *
 * Moduł odpowiedzialny za ekstrakcję namiarów kontaktowych (telefon / e-mail) bez zapisu PII na dysku
 * oraz asynchroniczną wysyłkę powiadomień Push Ntfy.sh 1-Klik i webhooka osTicket po zamknięciu odpowiedzi HTTP.
 */

/**
 * Wyciąga i normalizuje namiary kontaktowe z wiadomości klienta oraz historii rozmowy (Zero-PII na dysku)
 */
function aiExtractContactLeads(string $question, array $sanitizedHistory, bool $isAmmsSite): array {
    $emailRegex = '/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/u';
    $phoneRegex = '/(?:\+?48[ \t.\-()]*)?(?:\d[ \t.\-()]*){8}\d/u';

    $hasEmail = !$isAmmsSite && (bool)preg_match_all($emailRegex, $question, $emailMatchesQ);
    $hasPhone = !$isAmmsSite && (bool)preg_match_all($phoneRegex, $question, $phoneMatchesQ);
    $hasContactLead = $hasEmail || $hasPhone;

    $extractedEmails    = $hasEmail ? array_values(array_unique(array_map('strtolower', $emailMatchesQ[0]))) : [];
    $rawPhones          = $hasPhone ? $phoneMatchesQ[0] : [];
    $priorUserQuestions = [];

    // Pojedyncza iteracja po historii: zbiera wcześniejsze pytania klienta oraz uzupełnia brakujący kanał kontaktu
    if (!empty($sanitizedHistory)) {
        foreach ($sanitizedHistory as $hTurn) {
            if (($hTurn['role'] ?? '') !== 'user') continue;
            $turnText = trim((string)($hTurn['text'] ?? ''));
            if ($turnText === '') continue;
            $priorUserQuestions[] = '• ' . $turnText;

            if ($hasContactLead) {
                if (preg_match_all($emailRegex, $turnText, $hEm)) {
                    foreach ($hEm[0] as $em) {
                        $extractedEmails[] = strtolower($em);
                    }
                }
                if (preg_match_all($phoneRegex, $turnText, $hPh)) {
                    foreach ($hPh[0] as $ph) {
                        $rawPhones[] = $ph;
                    }
                }
            }
        }
        if ($hasContactLead) {
            $extractedEmails = array_values(array_unique($extractedEmails));
        }
    }

    $extractedPhones = [];
    $dialPhones      = [];
    foreach ($rawPhones as $rawPh) {
        $digits = preg_replace('/\D+/', '', (string)$rawPh) ?: '';
        if (strlen($digits) === 9) {
            $formatted = '+48 ' . substr($digits, 0, 3) . ' ' . substr($digits, 3, 3) . ' ' . substr($digits, 6, 3);
            $dial      = '+48' . $digits;
        } elseif (strlen($digits) === 11 && str_starts_with($digits, '48')) {
            $sub       = substr($digits, 2);
            $formatted = '+48 ' . substr($sub, 0, 3) . ' ' . substr($sub, 3, 3) . ' ' . substr($sub, 6, 3);
            $dial      = '+' . $digits;
        } else {
            $formatted = trim((string)preg_replace('/[^0-9+\- ()]/', '', (string)$rawPh));
            if ($formatted === '') {
                $formatted = '+' . $digits;
            }
            $dial      = '+' . $digits;
        }
        if (!in_array($formatted, $extractedPhones, true)) {
            $extractedPhones[] = $formatted;
            $dialPhones[]      = $dial;
        }
    }

    $hasEmail = !empty($extractedEmails);
    $hasPhone = !empty($extractedPhones);
    $contactChannel = $hasEmail && $hasPhone ? 'email+phone' : ($hasEmail ? 'email' : ($hasPhone ? 'phone' : 'none'));

    return [
        'hasContactLead'     => $hasContactLead,
        'extractedEmails'    => $extractedEmails,
        'extractedPhones'    => $extractedPhones,
        'dialPhones'         => $dialPhones,
        'contactChannel'     => $contactChannel,
        'priorUserQuestions' => $priorUserQuestions,
    ];
}

/**
 * Oczyszcza wartość nagłówka HTTP ze znaków CRLF i NUL (ochrona przed CRLF Header Injection)
 * oraz opcjonalnie ze średników (ochrona przed wstrzyknięciem dodatkowych akcji w nagłówku Ntfy Actions).
 */
function aiSanitizeHeaderValue(string $value, bool $stripSemicolons = false): string {
    $clean = str_replace(["\r", "\n", "\0"], '', $value);
    if ($stripSemicolons) {
        $clean = str_replace(';', '', $clean);
    }
    return trim($clean);
}

/**
 * Weryfikuje zewnętrzny adres URL webhooka pod kątem ochrony przed SSRF
 * (wymaga HTTPS, blokuje localhost, sieci prywatne RFC1918, loopback 127.0.0.0/8 oraz OCI IMDS 169.254.169.254).
 */
function aiIsSafeExternalWebhookUrl(string $url): bool {
    $url = trim($url);
    if ($url === '' || !filter_var($url, FILTER_VALIDATE_URL)) {
        return false;
    }
    $parts = parse_url($url);
    if (!is_array($parts)) {
        return false;
    }
    if (strtolower((string)($parts['scheme'] ?? '')) !== 'https') {
        return false;
    }
    if (isset($parts['user']) || isset($parts['pass'])) {
        return false;
    }
    $host = strtolower(trim((string)($parts['host'] ?? ''), '[]'));
    if (
        $host === ''
        || $host === 'localhost'
        || str_ends_with($host, '.localhost')
        || str_ends_with($host, '.local')
        || str_ends_with($host, '.internal')
        || preg_match('/^(0x[0-9a-f]+|\d+)$/i', $host)
    ) {
        return false;
    }
    $ipFlags = FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE;
    if (filter_var($host, FILTER_VALIDATE_IP) !== false) {
        return filter_var($host, FILTER_VALIDATE_IP, $ipFlags) !== false;
    }
    $resolvedIps = @gethostbynamel($host);
    if (!is_array($resolvedIps) || empty($resolvedIps)) {
        return false;
    }
    foreach ($resolvedIps as $ip) {
        if (filter_var($ip, FILTER_VALIDATE_IP, $ipFlags) === false) {
            return false;
        }
    }
    return true;
}

/**
 * Wysyła powiadomienia Push Ntfy.sh 1-Klik oraz webhook osTicket po zamknięciu odpowiedzi dla klienta
 */
function aiDispatchLeadNotifications(
    string $aiSite,
    string $question,
    string $answer,
    string $usedModel,
    array $sanitizedHistory,
    bool $isAmmsSite,
    array $leadInfo
): void {
    $hasContactLead  = !empty($leadInfo['hasContactLead']);
    $extractedEmails = $leadInfo['extractedEmails'] ?? [];
    $extractedPhones = $leadInfo['extractedPhones'] ?? [];
    $dialPhones      = $leadInfo['dialPhones'] ?? [];
    $contactChannel  = (string)($leadInfo['contactChannel'] ?? 'none');

    $ntfyTopic = trim((string)(getenv('NTFY_TOPIC') ?: ''));
    if ($ntfyTopic !== '' && !preg_match('/^[a-zA-Z0-9_-]{2,64}$/', $ntfyTopic)) {
        aiLog('ntfy_invalid_topic', ['site' => $aiSite]);
        $ntfyTopic = '';
    }
    $ntfyBaseUrl = rtrim(trim((string)(getenv('NTFY_BASE_URL') ?: 'https://ntfy.sh')), '/');
    if ($ntfyBaseUrl === '') {
        $ntfyBaseUrl = 'https://ntfy.sh';
    }
    $ntfyToken = aiSanitizeHeaderValue((string)(getenv('NTFY_TOKEN') ?: ''));
    $isInternalNtfyHttp = (bool)preg_match('#^http://(ntfy|127\.0\.0\.1)(:\d+)?$#i', $ntfyBaseUrl);
    $leadWebhookUrl = trim((string)(getenv('LEAD_WEBHOOK_URL') ?: ''));
    $osTicketApiKey = aiSanitizeHeaderValue((string)(getenv('OSTICKET_API_KEY') ?: ''));
    $webhookHeaders = $osTicketApiKey !== '' ? ["X-API-Key: {$osTicketApiKey}"] : [];

    $priorUserQuestions = is_array($leadInfo['priorUserQuestions'] ?? null) ? $leadInfo['priorUserQuestions'] : [];

    // Przekazanie namiarów kontaktowych (e-mail / telefon) od klienta prosto na telefon właściciela, e-mail i do osTicket (Zero-PII w logach i Prometheusie)
    if ($hasContactLead) {
        aiRecordLead($aiSite, 'contact');
        aiLog('contact_lead_captured', ['site' => $aiSite, 'channel' => $contactChannel]);

        if ($ntfyTopic !== '') {
            $leadLines = [];
            $titleParts = [];
            $ntfyActions = [];

            if (!empty($extractedPhones)) {
                $phoneListStr = implode(', ', $extractedPhones);
                $safePhone0   = str_replace(',', '', aiSanitizeHeaderValue((string)$extractedPhones[0], true));
                $safeDial0    = preg_replace('/[^0-9+]/', '', (string)($dialPhones[0] ?? '')) ?: '';
                $leadLines[]  = "📞 TELEFON: {$phoneListStr}";
                $titleParts[] = "TEL: {$safePhone0}";
                $ntfyActions[] = aiSanitizeHeaderValue("view, Zadzwon ({$safePhone0}), tel:{$safeDial0}", true);
            }
            if (!empty($extractedEmails)) {
                $emailListStr = implode(', ', $extractedEmails);
                $safeEmail0   = str_replace(',', '', aiSanitizeHeaderValue((string)$extractedEmails[0], true));
                $leadLines[]  = "✉️ E-MAIL: {$emailListStr}";
                $titleParts[] = "EMAIL: {$safeEmail0}";
                $ntfyActions[] = aiSanitizeHeaderValue("view, Napisz e-mail ({$safeEmail0}), mailto:{$safeEmail0}", true);
            }

            if (count($ntfyActions) < 3) {
                $ntfyActions[] = 'view, Otworz Helpdesk, https://hd.twojastronawww.pl/scp/';
            }
            $ntfyActions = array_map(static fn(string $action): string => aiSanitizeHeaderValue($action, true), $ntfyActions);

            $leadLines[] = "🌐 STRONA: {$aiSite}";
            $leadLines[] = "────────────────────────";
            $leadLines[] = "💬 Wiadomość klienta:";
            $leadLines[] = "\"{$question}\"";

            if (!empty($priorUserQuestions)) {
                $leadLines[] = "";
                $leadLines[] = "📋 Wcześniejsze pytania w rozmowie:";
                foreach (array_slice($priorUserQuestions, -3) as $pq) {
                    $leadLines[] = $pq;
                }
            }

            $ntfyTitle = aiSanitizeHeaderValue('Lead (' . $aiSite . ') - ' . implode(' | ', $titleParts));
            $ntfyHeaders = [
                "Title: {$ntfyTitle}",
                'Priority: high',
                'Tags: telephone_receiver,sparkles'
            ];
            if (!empty($ntfyActions)) {
                $ntfyHeaders[] = 'Actions: ' . implode('; ', $ntfyActions);
            }
            if ($ntfyToken !== '') {
                $ntfyHeaders[] = 'Authorization: Bearer ' . $ntfyToken;
            }

            $ntfyBody = implode("\n", $leadLines);
            $ntfyDelivered = false;
            $leadHttpCode = 0;
            for ($attempt = 1; $attempt <= 2; $attempt++) {
                $chLead = curl_init("{$ntfyBaseUrl}/{$ntfyTopic}");
                $leadCurlOpts = [
                    CURLOPT_POST           => true,
                    CURLOPT_POSTFIELDS     => $ntfyBody,
                    CURLOPT_HTTPHEADER     => $ntfyHeaders,
                    CURLOPT_RETURNTRANSFER => true,
                    CURLOPT_TIMEOUT        => 3,
                    CURLOPT_CONNECTTIMEOUT => 2,
                    CURLOPT_FOLLOWLOCATION => false,
                    CURLOPT_MAXREDIRS      => 0,
                    CURLOPT_SSL_VERIFYPEER => true,
                    CURLOPT_SSL_VERIFYHOST => 2,
                ];
                if (defined('CURLPROTO_HTTPS')) {
                    $leadCurlOpts[CURLOPT_PROTOCOLS] = ($isInternalNtfyHttp && defined('CURLPROTO_HTTP'))
                        ? (CURLPROTO_HTTP | CURLPROTO_HTTPS)
                        : CURLPROTO_HTTPS;
                    $leadCurlOpts[CURLOPT_REDIR_PROTOCOLS] = CURLPROTO_HTTPS;
                }
                curl_setopt_array($chLead, $leadCurlOpts);
                @curl_exec($chLead);
                $leadHttpCode = (int)curl_getinfo($chLead, CURLINFO_HTTP_CODE);
                unset($chLead);
                if ($leadHttpCode >= 200 && $leadHttpCode < 300) {
                    $ntfyDelivered = true;
                    break;
                }
                if ($attempt === 1) {
                    usleep(200000);
                }
            }
            if (!$ntfyDelivered) {
                aiLog('contact_lead_ntfy_failed', ['site' => $aiSite, 'http' => $leadHttpCode]);
            }
        }

        if ($leadWebhookUrl !== '') {
            if (aiIsSafeExternalWebhookUrl($leadWebhookUrl)) {
                $whRes = executeJsonPost($leadWebhookUrl, [
                    'event'           => 'contact_lead_captured',
                    'site_id'         => $aiSite,
                    'channel'         => $contactChannel,
                    'phones'          => $extractedPhones,
                    'emails'          => $extractedEmails,
                    'message'         => $question,
                    'answer'          => $answer,
                    'prior_questions' => array_slice($priorUserQuestions, -3),
                    'timestamp'       => gmdate('c')
                ], $webhookHeaders, 8);
                if ($whRes['httpCode'] < 200 || $whRes['httpCode'] >= 300) {
                    aiLog('contact_lead_webhook_failed', ['site' => $aiSite, 'http' => $whRes['httpCode']]);
                }
            } else {
                aiLog('lead_webhook_ssrf_blocked', ['site' => $aiSite]);
            }
        }
    } elseif (!$isAmmsSite && count($sanitizedHistory) === 6) {
        // Detektor Gorącego Leada (Zero-PII): sygnał Ntfy + osTicket + E-mail przy 4. pytaniu klienta w sesji rozmowy
        aiRecordLead($aiSite, 'hot_lead');
        aiLog('hot_lead_detected', ['site' => $aiSite, 'turns' => 4]);

        if ($ntfyTopic !== '') {
            $hotLines = [
                "🔥 Klient prowadzi zaangażowaną rozmowę (4. pytanie w sesji) na stronie: {$aiSite} (model: {$usedModel}).",
                "────────────────────────",
                "💬 Bieżące (4.) pytanie klienta:",
                "\"{$question}\""
            ];
            if (!empty($priorUserQuestions)) {
                $hotLines[] = "";
                $hotLines[] = "📋 Wcześniejsze pytania (1-3):";
                foreach (array_slice($priorUserQuestions, -3) as $pq) {
                    $hotLines[] = $pq;
                }
            }

            $hotTitle = aiSanitizeHeaderValue("Goracy Lead na Czatbocie ({$aiSite})");
            $hotHeaders = [
                "Title: {$hotTitle}",
                'Priority: high',
                'Tags: speech_balloon,fire',
                'Actions: view, Otworz Helpdesk, https://hd.twojastronawww.pl/scp/'
            ];
            if ($ntfyToken !== '') {
                $hotHeaders[] = 'Authorization: Bearer ' . $ntfyToken;
            }

            $chNtfy = curl_init("{$ntfyBaseUrl}/{$ntfyTopic}");
            $hotCurlOpts = [
                CURLOPT_POST           => true,
                CURLOPT_POSTFIELDS     => implode("\n", $hotLines),
                CURLOPT_HTTPHEADER     => $hotHeaders,
                CURLOPT_RETURNTRANSFER => true,
                CURLOPT_TIMEOUT        => 3,
                CURLOPT_CONNECTTIMEOUT => 2,
                CURLOPT_FOLLOWLOCATION => false,
                CURLOPT_MAXREDIRS      => 0,
                CURLOPT_SSL_VERIFYPEER => true,
                CURLOPT_SSL_VERIFYHOST => 2,
            ];
            if (defined('CURLPROTO_HTTPS')) {
                $hotCurlOpts[CURLOPT_PROTOCOLS] = ($isInternalNtfyHttp && defined('CURLPROTO_HTTP'))
                    ? (CURLPROTO_HTTP | CURLPROTO_HTTPS)
                    : CURLPROTO_HTTPS;
                $hotCurlOpts[CURLOPT_REDIR_PROTOCOLS] = CURLPROTO_HTTPS;
            }
            curl_setopt_array($chNtfy, $hotCurlOpts);
            @curl_exec($chNtfy);
            unset($chNtfy);
        }

        if ($leadWebhookUrl !== '') {
            if (aiIsSafeExternalWebhookUrl($leadWebhookUrl)) {
                $whRes = executeJsonPost($leadWebhookUrl, [
                    'event'           => 'hot_lead_detected',
                    'site_id'         => $aiSite,
                    'channel'         => 'chat_engagement',
                    'phones'          => [],
                    'emails'          => [],
                    'message'         => $question,
                    'answer'          => $answer,
                    'prior_questions' => array_slice($priorUserQuestions, -3),
                    'timestamp'       => gmdate('c')
                ], $webhookHeaders, 8);
                if ($whRes['httpCode'] < 200 || $whRes['httpCode'] >= 300) {
                    aiLog('hot_lead_webhook_failed', ['site' => $aiSite, 'http' => $whRes['httpCode']]);
                }
            } else {
                aiLog('lead_webhook_ssrf_blocked', ['site' => $aiSite]);
            }
        }
    }
}
