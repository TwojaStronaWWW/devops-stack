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
    $phoneRegex = '/(?:\+?48[\s.\-()]*)?(?:\d[\s.\-()]*){8}\d/u';

    $hasEmail = !$isAmmsSite && (bool)preg_match_all($emailRegex, $question, $emailMatchesQ);
    $hasPhone = !$isAmmsSite && (bool)preg_match_all($phoneRegex, $question, $phoneMatchesQ);
    $hasContactLead = $hasEmail || $hasPhone;

    $extractedEmails = $hasEmail ? array_values(array_unique(array_map('strtolower', $emailMatchesQ[0]))) : [];
    $rawPhones       = $hasPhone ? $phoneMatchesQ[0] : [];

    // Jeśli klient podał namiar w bieżącej wiadomości, sprawdź czy we wcześniejszych wiadomościach tej rozmowy podał też drugi kanał
    if ($hasContactLead && !empty($sanitizedHistory)) {
        foreach ($sanitizedHistory as $hTurn) {
            if (($hTurn['role'] ?? '') !== 'user') continue;
            if (preg_match_all($emailRegex, $hTurn['text'], $hEm)) {
                foreach ($hEm[0] as $em) {
                    $extractedEmails[] = strtolower($em);
                }
            }
            if (preg_match_all($phoneRegex, $hTurn['text'], $hPh)) {
                foreach ($hPh[0] as $ph) {
                    $rawPhones[] = $ph;
                }
            }
        }
        $extractedEmails = array_values(array_unique($extractedEmails));
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
            $formatted = trim((string)$rawPh);
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
        'hasContactLead'  => $hasContactLead,
        'extractedEmails' => $extractedEmails,
        'extractedPhones' => $extractedPhones,
        'dialPhones'      => $dialPhones,
        'contactChannel'  => $contactChannel,
    ];
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
    $leadWebhookUrl = trim((string)(getenv('LEAD_WEBHOOK_URL') ?: ''));
    $osTicketApiKey = trim((string)(getenv('OSTICKET_API_KEY') ?: ''));
    $webhookHeaders = $osTicketApiKey !== '' ? ["X-API-Key: {$osTicketApiKey}"] : [];

    $priorUserQuestions = [];
    foreach ($sanitizedHistory as $hTurn) {
        if (($hTurn['role'] ?? '') === 'user' && trim((string)($hTurn['text'] ?? '')) !== '') {
            $priorUserQuestions[] = '• ' . trim((string)$hTurn['text']);
        }
    }

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
                $leadLines[]  = "📞 TELEFON: {$phoneListStr}";
                $titleParts[] = "TEL: {$extractedPhones[0]}";
                $ntfyActions[] = "view, Zadzwon ({$extractedPhones[0]}), tel:{$dialPhones[0]}";
            }
            if (!empty($extractedEmails)) {
                $emailListStr = implode(', ', $extractedEmails);
                $leadLines[]  = "✉️ E-MAIL: {$emailListStr}";
                $titleParts[] = "EMAIL: {$extractedEmails[0]}";
                $ntfyActions[] = "view, Napisz e-mail ({$extractedEmails[0]}), mailto:{$extractedEmails[0]}";
            }

            if (count($ntfyActions) < 3) {
                $ntfyActions[] = 'view, Otworz Helpdesk, https://hd.twojastronawww.pl/scp/';
            }

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

            $ntfyTitle = 'Lead (' . $aiSite . ') - ' . implode(' | ', $titleParts);
            $ntfyHeaders = [
                "Title: {$ntfyTitle}",
                'Priority: high',
                'Tags: telephone_receiver,sparkles'
            ];
            if (!empty($ntfyActions)) {
                $ntfyHeaders[] = 'Actions: ' . implode('; ', $ntfyActions);
            }

            $ntfyBody = implode("\n", $leadLines);
            $ntfyDelivered = false;
            $leadHttpCode = 0;
            for ($attempt = 1; $attempt <= 2; $attempt++) {
                $chLead = curl_init("https://ntfy.sh/{$ntfyTopic}");
                curl_setopt_array($chLead, [
                    CURLOPT_POST           => true,
                    CURLOPT_POSTFIELDS     => $ntfyBody,
                    CURLOPT_HTTPHEADER     => $ntfyHeaders,
                    CURLOPT_RETURNTRANSFER => true,
                    CURLOPT_TIMEOUT        => 3,
                    CURLOPT_CONNECTTIMEOUT => 2
                ]);
                @curl_exec($chLead);
                $leadHttpCode = (int)curl_getinfo($chLead, CURLINFO_HTTP_CODE);
                curl_close($chLead);
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

        if ($leadWebhookUrl !== '' && filter_var($leadWebhookUrl, FILTER_VALIDATE_URL)) {
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

            $chNtfy = curl_init("https://ntfy.sh/{$ntfyTopic}");
            curl_setopt_array($chNtfy, [
                CURLOPT_POST           => true,
                CURLOPT_POSTFIELDS     => implode("\n", $hotLines),
                CURLOPT_HTTPHEADER     => [
                    "Title: Goracy Lead na Czatbocie ({$aiSite})",
                    'Priority: high',
                    'Tags: speech_balloon,fire',
                    'Actions: view, Otworz Helpdesk, https://hd.twojastronawww.pl/scp/'
                ],
                CURLOPT_RETURNTRANSFER => true,
                CURLOPT_TIMEOUT        => 3,
                CURLOPT_CONNECTTIMEOUT => 2
            ]);
            @curl_exec($chNtfy);
            curl_close($chNtfy);
        }

        if ($leadWebhookUrl !== '' && filter_var($leadWebhookUrl, FILTER_VALIDATE_URL)) {
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
        }
    }
}
