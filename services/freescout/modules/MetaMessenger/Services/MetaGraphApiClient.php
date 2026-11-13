<?php

declare(strict_types=1);

namespace Modules\MetaMessenger\Services;

use Illuminate\Support\Facades\Log;
use Modules\MetaMessenger\Models\MessengerAccount;
use Modules\MetaMessenger\Models\MessengerMessage;

class MetaGraphApiClient
{
    public const DEFAULT_API_VERSION = 'v21.0';
    public const GRAPH_BASE_URL      = 'https://graph.facebook.com';
    public const MAX_REDIRECTS       = 3;

    /**
     * Fetch user profile from Meta Graph API with 5s timeout and safe OPSEC fallback.
     *
     * @return array{first_name: string, last_name: string, display_name: string, username: string}
     */
    public function fetchUserProfile(MessengerAccount $account, string $senderId, string $platform): array
    {
        $fallback = $this->buildFallbackProfile($senderId, $platform);
        $token    = $account->getDecryptedPageAccessToken();

        if ($token === null || $senderId === '') {
            return $fallback;
        }

        // Instagram IGSID nodes expose name,username; Messenger PSID nodes expose first_name,last_name,name.
        // We try the full requested field set first if supported, or platform-native fields on Graph #100 field error.
        $fieldSets = $platform === MessengerMessage::PLATFORM_INSTAGRAM
            ? ['name,username', 'first_name,last_name,name,username']
            : ['first_name,last_name,name', 'first_name,last_name,name,username'];

        foreach ($fieldSets as $fields) {
            $url = $this->buildGraphUrl(rawurlencode($senderId) . '?fields=' . rawurlencode($fields));
            $res = $this->requestJson('GET', $url, $token, null, 5);

            if (!$res['ok'] || !is_array($res['data'])) {
                $errCode = (int) ($res['error_code'] ?? 0);
                if ($errCode === 100) {
                    continue;
                }
                break;
            }

            $data      = $res['data'];
            $firstName = trim((string) ($data['first_name'] ?? ''));
            $lastName  = trim((string) ($data['last_name'] ?? ''));
            $fullName  = trim((string) ($data['name'] ?? ''));
            $username  = ltrim(trim((string) ($data['username'] ?? '')), '@');

            if ($firstName === '' && $fullName !== '') {
                $parts     = preg_split('/\s+/u', $fullName, 2) ?: [];
                $firstName = trim((string) ($parts[0] ?? ''));
                $lastName  = trim((string) ($parts[1] ?? ''));
            }

            if ($firstName === '' && $username !== '') {
                $firstName = '@' . $username;
                $lastName  = '';
            }

            if ($firstName === '') {
                return $fallback;
            }

            $display = trim($firstName . ' ' . $lastName);
            if ($username !== '' && stripos($display, $username) === false) {
                $display .= ' (@' . $username . ')';
            }

            return [
                'first_name'   => mb_substr($firstName, 0, 120),
                'last_name'    => mb_substr($lastName, 0, 120),
                'display_name' => mb_substr($display, 0, 190),
                'username'     => mb_substr($username, 0, 100),
            ];
        }

        return $fallback;
    }

    /**
     * Verify Page Access Token and discover connected Instagram Business Account ID.
     *
     * @return array{ok: bool, page_name?: string, page_id?: string, ig_account_id?: ?string, error?: string}
     */
    public function testPageConnection(MessengerAccount $account): array
    {
        $token = $account->getDecryptedPageAccessToken();
        if ($token === null) {
            return [
                'ok'    => false,
                'error' => 'Nie można odszyfrować Page Access Token (sprawdź APP_KEY lub zapisz token ponownie).',
            ];
        }

        $url = $this->buildGraphUrl(rawurlencode($account->page_id) . '?fields=id,name,instagram_business_account{id,username}');
        $res = $this->requestJson('GET', $url, $token, null, 10);

        if (!$res['ok'] || !is_array($res['data'])) {
            return [
                'ok'    => false,
                'error' => $res['error_message'] ?: ('Błąd połączenia z Meta Graph API (HTTP ' . $res['http_code'] . ').'),
            ];
        }

        $data   = $res['data'];
        $igNode = $data['instagram_business_account'] ?? null;
        $igId   = is_array($igNode) && !empty($igNode['id']) ? (string) $igNode['id'] : null;

        return [
            'ok'            => true,
            'page_id'       => (string) ($data['id'] ?? $account->page_id),
            'page_name'     => (string) ($data['name'] ?? $account->name),
            'ig_account_id' => $igId,
        ];
    }

    /**
     * Send text reply via POST https://graph.facebook.com/v21.0/{page_id}/messages.
     * Splits text safely if longer than platform per-message character limits.
     *
     * @return array{ok: bool, mids: array<int, string>, error_code?: int, error_subcode?: int, error_message?: string, transient?: bool}
     */
    public function sendText(MessengerAccount $account, string $recipientId, string $text, string $platform): array
    {
        $token = $account->getDecryptedPageAccessToken();
        if ($token === null) {
            return [
                'ok'            => false,
                'mids'          => [],
                'error_code'    => 190,
                'error_subcode' => 0,
                'error_message' => 'Brak czytelnego Page Access Token (błąd deszyfrowania APP_KEY).',
                'transient'     => false,
            ];
        }

        $maxChars = $platform === MessengerMessage::PLATFORM_INSTAGRAM ? 950 : 1900;
        $chunks   = $this->splitTextIntoChunks($text, $maxChars);
        $mids     = [];
        $url      = $this->buildGraphUrl(rawurlencode($account->page_id) . '/messages');

        foreach ($chunks as $chunk) {
            $body = [
                'recipient'      => ['id' => $recipientId],
                'messaging_type' => 'RESPONSE',
                'message'        => ['text' => $chunk],
            ];

            $res = $this->requestJson('POST', $url, $token, $body, 15);
            if (!$res['ok']) {
                return [
                    'ok'            => false,
                    'mids'          => $mids,
                    'error_code'    => (int) ($res['error_code'] ?? 0),
                    'error_subcode' => (int) ($res['error_subcode'] ?? 0),
                    'error_message' => (string) ($res['error_message'] ?? 'Nieznany błąd Meta Graph API'),
                    'transient'     => (bool) ($res['transient'] ?? false),
                ];
            }

            $mid = (string) ($res['data']['message_id'] ?? '');
            if ($mid !== '') {
                $mids[] = $mid;
            }
        }

        return [
            'ok'   => true,
            'mids' => $mids,
        ];
    }

    /**
     * Upload and send local FreeScout attachment via multipart Graph API request (zero APP_URL leak).
     *
     * @return array{ok: bool, mid?: string, error_code?: int, error_subcode?: int, error_message?: string, transient?: bool}
     */
    public function sendAttachment(
        MessengerAccount $account,
        string $recipientId,
        string $localFilePath,
        string $fileName,
        string $mimeType
    ): array {
        $token = $account->getDecryptedPageAccessToken();
        if ($token === null) {
            return [
                'ok'            => false,
                'error_code'    => 190,
                'error_subcode' => 0,
                'error_message' => 'Brak czytelnego Page Access Token.',
                'transient'     => false,
            ];
        }

        if (!is_file($localFilePath) || !is_readable($localFilePath)) {
            return [
                'ok'            => false,
                'error_code'    => 0,
                'error_subcode' => 0,
                'error_message' => 'Plik załącznika nie istnieje na dysku lokalnym FreeScout.',
                'transient'     => false,
            ];
        }

        $metaType = $this->mapMimeToMetaAttachmentType($mimeType);
        $url      = $this->buildGraphUrl(rawurlencode($account->page_id) . '/messages');

        $postFields = [
            'recipient'      => json_encode(['id' => $recipientId], JSON_UNESCAPED_SLASHES),
            'messaging_type' => 'RESPONSE',
            'message'        => json_encode([
                'attachment' => [
                    'type'    => $metaType,
                    'payload' => ['is_reusable' => false],
                ],
            ], JSON_UNESCAPED_SLASHES),
            'filedata'       => new \CURLFile($localFilePath, $mimeType ?: 'application/octet-stream', $fileName),
        ];

        $ch = curl_init($url);
        if ($ch === false) {
            return [
                'ok'            => false,
                'error_code'    => 0,
                'error_subcode' => 0,
                'error_message' => 'Nie udało się zainicjować cURL.',
                'transient'     => false,
            ];
        }

        curl_setopt_array($ch, [
            CURLOPT_POST           => true,
            CURLOPT_POSTFIELDS     => $postFields,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_PROTOCOLS      => CURLPROTO_HTTPS,
            CURLOPT_SSL_VERIFYPEER => true,
            CURLOPT_SSL_VERIFYHOST => 2,
            CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_TIMEOUT        => 30,
            CURLOPT_HTTPHEADER     => [
                'Authorization: Bearer ' . $token,
                'Accept: application/json',
            ],
        ]);

        $raw   = curl_exec($ch);
        $errno = curl_errno($ch);
        $err   = curl_error($ch);
        $code  = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        unset($ch);

        if ($errno !== 0 || !is_string($raw)) {
            return [
                'ok'            => false,
                'error_code'    => 0,
                'error_subcode' => 0,
                'error_message' => 'Błąd sieci cURL przy wysyłce załącznika: ' . $err,
                'transient'     => true,
            ];
        }

        $decoded = json_decode($raw, true, 16);
        if ($code >= 200 && $code < 300 && is_array($decoded)) {
            return [
                'ok'  => true,
                'mid' => (string) ($decoded['message_id'] ?? ''),
            ];
        }

        $metaErr = is_array($decoded) && isset($decoded['error']) && is_array($decoded['error'])
            ? $decoded['error']
            : [];

        return [
            'ok'            => false,
            'error_code'    => (int) ($metaErr['code'] ?? $code),
            'error_subcode' => (int) ($metaErr['error_subcode'] ?? 0),
            'error_message' => (string) ($metaErr['message'] ?? ('HTTP ' . $code)),
            'transient'     => $code >= 500 || $code === 429,
        ];
    }

    /**
     * Download inbound attachment from Meta CDN with strict SSRF & DNS-rebinding protection.
     *
     * @return array{bytes: string, mime_type: string, filename: string}|null
     */
    public function downloadMediaAttachment(string $initialUrl, string $fallbackType = 'file'): ?array
    {
        $maxBytes   = ((int) $this->getConfig('metamessenger.attachment_max_mb', 25)) * 1024 * 1024;
        $currentUrl = trim($initialUrl);

        for ($hop = 0; $hop <= self::MAX_REDIRECTS; $hop++) {
            $validated = $this->validateMetaCdnUrl($currentUrl);
            if ($validated === null) {
                Log::warning('[MetaMessenger] Blocked attachment download outside allowed Meta CDN allowlist', [
                    'hop'  => $hop,
                    'host' => parse_url($currentUrl, PHP_URL_HOST) ?: 'invalid',
                ]);
                return null;
            }

            $ch = curl_init($currentUrl);
            if ($ch === false) {
                return null;
            }

            $redirectLocation = null;
            $contentType      = 'application/octet-stream';
            $abortedBySize    = false;

            curl_setopt_array($ch, [
                CURLOPT_RETURNTRANSFER => true,
                CURLOPT_FOLLOWLOCATION => false, // Enforced OWASP ASVS [REF-05]; redirects re-validated per hop
                CURLOPT_PROTOCOLS      => CURLPROTO_HTTPS,
                CURLOPT_SSL_VERIFYPEER => true,
                CURLOPT_SSL_VERIFYHOST => 2,
                CURLOPT_CONNECTTIMEOUT => 5,
                CURLOPT_TIMEOUT        => 20,
                CURLOPT_RESOLVE        => [
                    $validated['host'] . ':443:' . $validated['ip'],
                ],
                CURLOPT_USERAGENT      => 'FreeScout-MetaMessenger/1.0',
                CURLOPT_HEADERFUNCTION => static function ($curl, string $headerLine) use (&$redirectLocation, &$contentType): int {
                    $len = strlen($headerLine);
                    $parts = explode(':', $headerLine, 2);
                    if (count($parts) === 2) {
                        $name  = strtolower(trim($parts[0]));
                        $value = trim($parts[1]);
                        if ($name === 'location') {
                            $redirectLocation = $value;
                        } elseif ($name === 'content-type') {
                            $contentType = trim(explode(';', $value)[0]);
                        }
                    }
                    return $len;
                },
                CURLOPT_NOPROGRESS       => false,
                CURLOPT_PROGRESSFUNCTION => static function ($resource, $dlTotal, $dlNow, $ulTotal = 0, $ulNow = 0) use ($maxBytes, &$abortedBySize): int {
                    if ($dlTotal > $maxBytes || $dlNow > $maxBytes) {
                        $abortedBySize = true;
                        return 1;
                    }
                    return 0;
                },
            ]);

            $body = curl_exec($ch);
            $code = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
            unset($ch);

            if ($abortedBySize) {
                Log::warning('[MetaMessenger] Attachment exceeded max size limit and was skipped.');
                return null;
            }

            if (in_array($code, [301, 302, 303, 307, 308], true) && is_string($redirectLocation) && $redirectLocation !== '') {
                $currentUrl = $redirectLocation;
                continue;
            }

            if ($code >= 200 && $code < 300 && is_string($body) && $body !== '' && strlen($body) <= $maxBytes) {
                $ext      = $this->guessExtension($contentType, $currentUrl, $fallbackType);
                $filename = 'meta_' . $fallbackType . '_' . date('Ymd_His') . '_' . substr(bin2hex(random_bytes(4)), 0, 6) . '.' . $ext;

                return [
                    'bytes'     => $body,
                    'mime_type' => $contentType ?: 'application/octet-stream',
                    'filename'  => $filename,
                ];
            }

            return null;
        }

        return null;
    }

    /**
     * Validate URL against strict HTTPS + Meta CDN domain allowlist + public-IP resolution (anti-SSRF).
     *
     * @return array{host: string, ip: string}|null
     */
    public function validateMetaCdnUrl(string $url): ?array
    {
        $parts = parse_url($url);
        if (!is_array($parts)) {
            return null;
        }

        $scheme = strtolower((string) ($parts['scheme'] ?? ''));
        $host   = strtolower(rtrim((string) ($parts['host'] ?? ''), '.'));
        $port   = isset($parts['port']) ? (int) $parts['port'] : 443;

        if ($scheme !== 'https' || $host === '' || $port !== 443) {
            return null;
        }

        if (isset($parts['user']) || isset($parts['pass'])) {
            return null;
        }

        if (filter_var($host, FILTER_VALIDATE_IP)) {
            return null; // Raw IP literals are never valid Meta CDN URLs
        }

        $allowedDomains = $this->getConfig('metamessenger.allowed_cdn_domains', [
            'fbcdn.net',
            'fbsbx.com',
            'lookaside.fbsbx.com',
            'cdninstagram.com',
        ]);

        $domainMatched = false;
        foreach ($allowedDomains as $allowed) {
            $allowed = strtolower(trim((string) $allowed, '.'));
            if ($allowed !== '' && ($host === $allowed || str_ends_with($host, '.' . $allowed))) {
                $domainMatched = true;
                break;
            }
        }

        if (!$domainMatched) {
            return null;
        }

        $ips = gethostbynamel($host);
        if (!is_array($ips) || empty($ips)) {
            return null;
        }

        foreach ($ips as $ip) {
            $validPublic = filter_var(
                $ip,
                FILTER_VALIDATE_IP,
                FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE
            );
            if ($validPublic === false) {
                return null;
            }
        }

        return [
            'host' => $host,
            'ip'   => $ips[0],
        ];
    }

    /**
     * Format human-readable Polish error explanation for FreeScout internal note.
     */
    public static function describeGraphError(int $code, int $subcode, string $rawMessage, string $platform): string
    {
        $channelLabel = $platform === MessengerMessage::PLATFORM_INSTAGRAM ? 'Instagram DM' : 'Facebook Messenger';

        if ($code === 10 && $subcode === 2018278) {
            return "Wiadomość {$channelLabel} nie została dostarczona: minęło 24-godzinne okno odpowiedzi Mety od ostatniej wiadomości rozmówcy (kod 10 / 2018278).";
        }

        if ($code === 10 && $subcode === 2018028) {
            return "Wiadomość {$channelLabel} odrzucona przez Metę (kod 10 / 2018028): aplikacja Meta działa jeszcze w trybie Standard Access (odpowiadać można na razie wyłącznie kontom z rolą Admin/Developer/Tester w aplikacji Meta — dla użytkowników publicznych wymagane jest Advanced Access dla pages_messaging).";
        }

        if ($code === 190) {
            return "Wiadomość {$channelLabel} nie została wysłana: Page Access Token wygasł lub został unieważniony (kod 190). Zaktualizuj token w Manage → Meta Messenger & IG.";
        }

        if ($code === 10) {
            return "Wiadomość {$channelLabel} nie została dostarczona z powodu ograniczeń uprawnień lub 24-godzinnego okna odpowiedzi Meta API (kod 10" . ($subcode ? " / {$subcode}" : '') . "): {$rawMessage}";
        }

        return "Błąd wysyłki {$channelLabel} (kod {$code}" . ($subcode ? " / {$subcode}" : '') . "): {$rawMessage}";
    }

    /**
     * @param array<string, mixed>|null $jsonBody
     * @return array{ok: bool, http_code: int, data?: array<string, mixed>, error_code?: int, error_subcode?: int, error_message?: string, transient?: bool}
     */
    protected function requestJson(string $method, string $url, string $bearerToken, ?array $jsonBody = null, int $timeoutSeconds = 10): array
    {
        $ch = curl_init($url);
        if ($ch === false) {
            return [
                'ok'            => false,
                'http_code'     => 0,
                'error_code'    => 0,
                'error_subcode' => 0,
                'error_message' => 'Nie można zainicjować cURL.',
                'transient'     => false,
            ];
        }

        $headers = [
            'Authorization: Bearer ' . $bearerToken,
            'Accept: application/json',
        ];

        $opts = [
            CURLOPT_CUSTOMREQUEST  => $method,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_PROTOCOLS      => CURLPROTO_HTTPS,
            CURLOPT_SSL_VERIFYPEER => true,
            CURLOPT_SSL_VERIFYHOST => 2,
            CURLOPT_CONNECTTIMEOUT => min(3, $timeoutSeconds),
            CURLOPT_TIMEOUT        => $timeoutSeconds,
        ];

        if ($jsonBody !== null) {
            $encoded   = json_encode($jsonBody, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            $headers[] = 'Content-Type: application/json';
            $opts[CURLOPT_POSTFIELDS] = $encoded !== false ? $encoded : '{}';
        }

        $opts[CURLOPT_HTTPHEADER] = $headers;
        curl_setopt_array($ch, $opts);

        $raw   = curl_exec($ch);
        $errno = curl_errno($ch);
        $err   = curl_error($ch);
        $code  = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        unset($ch);

        if ($errno !== 0 || !is_string($raw)) {
            return [
                'ok'            => false,
                'http_code'     => 0,
                'error_code'    => 0,
                'error_subcode' => 0,
                'error_message' => 'cURL error (' . $errno . '): ' . $err,
                'transient'     => true,
            ];
        }

        $decoded = json_decode($raw, true, 16);
        if ($code >= 200 && $code < 300 && is_array($decoded)) {
            return [
                'ok'        => true,
                'http_code' => $code,
                'data'      => $decoded,
            ];
        }

        $metaErr = is_array($decoded) && isset($decoded['error']) && is_array($decoded['error'])
            ? $decoded['error']
            : [];

        return [
            'ok'            => false,
            'http_code'     => $code,
            'error_code'    => (int) ($metaErr['code'] ?? $code),
            'error_subcode' => (int) ($metaErr['error_subcode'] ?? 0),
            'error_message' => (string) ($metaErr['message'] ?? ('HTTP ' . $code)),
            'transient'     => $code >= 500 || $code === 429,
        ];
    }

    protected function buildGraphUrl(string $pathAndQuery): string
    {
        $base    = rtrim((string) $this->getConfig('metamessenger.graph_api_base', self::GRAPH_BASE_URL), '/');
        $version = trim((string) $this->getConfig('metamessenger.graph_api_version', self::DEFAULT_API_VERSION), '/');

        return $base . '/' . $version . '/' . ltrim($pathAndQuery, '/');
    }

    protected function getConfig(string $key, $default = null)
    {
        if (function_exists('app')) {
            try {
                $container = app();
                if (is_object($container) && method_exists($container, 'bound') && $container->bound('config')) {
                    return config($key, $default);
                }
            } catch (\Throwable $e) {
                return $default;
            }
        }

        return $default;
    }

    /**
     * @return array{first_name: string, last_name: string, display_name: string, username: string}
     */
    protected function buildFallbackProfile(string $senderId, string $platform): array
    {
        $suffix = substr(preg_replace('/[^a-zA-Z0-9]/', '', $senderId) ?: '0000', -4);
        if ($platform === MessengerMessage::PLATFORM_INSTAGRAM) {
            $handle = '@ig_user_' . $suffix;
            return [
                'first_name'   => $handle,
                'last_name'    => '',
                'display_name' => $handle,
                'username'     => 'ig_user_' . $suffix,
            ];
        }

        return [
            'first_name'   => 'Messenger User',
            'last_name'    => '#' . $suffix,
            'display_name' => 'Messenger User #' . $suffix,
            'username'     => '',
        ];
    }

    /**
     * @return array<int, string>
     */
    protected function splitTextIntoChunks(string $text, int $maxLength): array
    {
        $text = trim($text);
        if ($text === '') {
            return [];
        }

        if (mb_strlen($text) <= $maxLength) {
            return [$text];
        }

        $chunks    = [];
        $remaining = $text;

        while (mb_strlen($remaining) > $maxLength) {
            $slice = mb_substr($remaining, 0, $maxLength);
            $break = max((int) mb_strrpos($slice, "\n"), (int) mb_strrpos($slice, ' '));
            if ($break < (int) ($maxLength * 0.5)) {
                $break = $maxLength;
            }
            $chunks[]  = trim(mb_substr($remaining, 0, $break));
            $remaining = ltrim(mb_substr($remaining, $break));
        }

        if ($remaining !== '') {
            $chunks[] = $remaining;
        }

        return array_values(array_filter($chunks, static fn (string $c): bool => $c !== ''));
    }

    protected function mapMimeToMetaAttachmentType(string $mimeType): string
    {
        $mimeType = strtolower(trim($mimeType));
        if (str_starts_with($mimeType, 'image/')) {
            return 'image';
        }
        if (str_starts_with($mimeType, 'video/')) {
            return 'video';
        }
        if (str_starts_with($mimeType, 'audio/')) {
            return 'audio';
        }
        return 'file';
    }

    protected function guessExtension(string $mimeType, string $url, string $fallbackType): string
    {
        $map = [
            'image/jpeg'      => 'jpg',
            'image/jpg'       => 'jpg',
            'image/png'       => 'png',
            'image/gif'       => 'gif',
            'image/webp'      => 'webp',
            'video/mp4'       => 'mp4',
            'video/quicktime' => 'mov',
            'audio/mpeg'      => 'mp3',
            'audio/mp4'       => 'm4a',
            'audio/ogg'       => 'ogg',
            'audio/wav'       => 'wav',
            'application/pdf' => 'pdf',
        ];

        $mimeLower = strtolower($mimeType);
        if (isset($map[$mimeLower])) {
            return $map[$mimeLower];
        }

        $urlPath = (string) parse_url($url, PHP_URL_PATH);
        $ext     = strtolower((string) pathinfo($urlPath, PATHINFO_EXTENSION));
        if ($ext !== '' && preg_match('/^[a-z0-9]{2,5}$/', $ext)) {
            return $ext;
        }

        return match ($fallbackType) {
            'image', 'sticker' => 'jpg',
            'video'            => 'mp4',
            'audio'            => 'm4a',
            default            => 'bin',
        };
    }
}
