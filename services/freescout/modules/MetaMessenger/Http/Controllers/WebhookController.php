<?php

declare(strict_types=1);

namespace Modules\MetaMessenger\Http\Controllers;

use Illuminate\Http\Request;
use Illuminate\Routing\Controller;
use Illuminate\Support\Facades\Log;
use Modules\MetaMessenger\Jobs\ProcessInboundMessaging;
use Modules\MetaMessenger\Models\MessengerAccount;
use Modules\MetaMessenger\Models\MessengerMessage;

class WebhookController extends Controller
{
    public const MAX_PAYLOAD_BYTES = 262144; // 256 KiB

    public const REACHABLE_MESSAGE = "MetaMessenger is installed and this webhook endpoint is reachable.\n"
        . "Supports Facebook Page Messenger (object=page) and Instagram DM (object=instagram).\n";

    /**
     * GET /meta-messenger/webhook
     * Meta subscription handshake with constant-time verify_token check across active accounts.
     */
    public function verify(Request $request)
    {
        $mode      = (string) $request->query('hub_mode', '');
        $token     = (string) $request->query('hub_verify_token', '');
        $challenge = (string) $request->query('hub_challenge', '');

        if ($mode === '' && $token === '' && $challenge === '') {
            return response(self::REACHABLE_MESSAGE, 200)
                ->header('Content-Type', 'text/plain; charset=UTF-8');
        }

        if ($mode !== 'subscribe' || $token === '' || $challenge === '') {
            return response('Forbidden', 403);
        }

        $accounts = MessengerAccount::where('active', true)->get();
        $matched  = false;

        foreach ($accounts as $account) {
            $stored = (string) $account->verify_token;
            if ($stored !== '' && hash_equals($stored, $token)) {
                $matched = true;
            }
        }

        if (!$matched) {
            return response('Forbidden', 403);
        }

        return response($challenge, 200)
            ->header('Content-Type', 'text/plain; charset=UTF-8');
    }

    /**
     * POST /meta-messenger/webhook
     * Fail-closed X-Hub-Signature-256 HMAC-SHA256 verification before dispatching any job.
     */
    public function receive(Request $request)
    {
        $maxBytes = (function_exists('app') && app()->bound('config'))
            ? (int) config('metamessenger.webhook_max_bytes', self::MAX_PAYLOAD_BYTES)
            : self::MAX_PAYLOAD_BYTES;
        $contentLength = (int) $request->server('CONTENT_LENGTH', 0);

        if ($contentLength > $maxBytes) {
            return response('Payload Too Large', 413);
        }

        $rawBody = (string) $request->getContent();
        if ($rawBody === '' || strlen($rawBody) > $maxBytes) {
            return response(strlen($rawBody) > $maxBytes ? 'Payload Too Large' : 'Forbidden', strlen($rawBody) > $maxBytes ? 413 : 403);
        }

        $sigHeader = trim((string) $request->header('X-Hub-Signature-256', ''));
        if ($sigHeader === '' || !str_starts_with($sigHeader, 'sha256=')) {
            Log::warning('[MetaMessenger] Webhook rejected: missing or malformed X-Hub-Signature-256 header');
            return response('Forbidden', 403);
        }

        $payload = json_decode($rawBody, true, 16);
        if (!is_array($payload) || json_last_error() !== JSON_ERROR_NONE) {
            Log::warning('[MetaMessenger] Webhook rejected: invalid JSON payload');
            return response('Forbidden', 403);
        }

        $object = (string) ($payload['object'] ?? '');
        if ($object !== 'page' && $object !== 'instagram') {
            return response('Forbidden', 403);
        }

        $entries = $payload['entry'] ?? null;
        if (!is_array($entries) || empty($entries)) {
            return response('Forbidden', 403);
        }

        $platform      = $object === 'instagram' ? MessengerMessage::PLATFORM_INSTAGRAM : MessengerMessage::PLATFORM_MESSENGER;
        $verifiedQueue = [];

        foreach ($entries as $entry) {
            if (!is_array($entry)) {
                return response('Forbidden', 403);
            }

            $entryId = trim((string) ($entry['id'] ?? ''));
            if ($entryId === '') {
                return response('Forbidden', 403);
            }

            $account = $this->resolveAndVerifyAccount($entryId, $platform, $rawBody, $sigHeader);
            if ($account === null) {
                Log::warning('[MetaMessenger] Webhook rejected: account lookup or HMAC signature check failed', [
                    'object'   => $object,
                    'entry_id' => $entryId,
                ]);
                return response('Forbidden', 403);
            }

            $messagingEvents = $entry['messaging'] ?? [];
            if (!is_array($messagingEvents)) {
                continue;
            }

            foreach ($messagingEvents as $event) {
                if (!is_array($event)) {
                    continue;
                }
                if (isset($event['delivery']) || isset($event['read'])) {
                    continue;
                }
                if (!empty($event['message']['is_echo']) || !empty($event['message']['is_deleted'])) {
                    continue;
                }
                $verifiedQueue[] = [$account->id, $platform, $event];
            }
        }

        foreach ($verifiedQueue as [$accountId, $evPlatform, $evPayload]) {
            ProcessInboundMessaging::dispatch($accountId, $evPlatform, $evPayload);
        }

        return response('EVENT_RECEIVED', 200)
            ->header('Content-Type', 'text/plain; charset=UTF-8');
    }

    /**
     * Resolve active account for entry ID and verify X-Hub-Signature-256 fail-closed.
     */
    protected function resolveAndVerifyAccount(
        string $entryId,
        string $platform,
        string $rawBody,
        string $sigHeader
    ): ?MessengerAccount {
        if ($platform === MessengerMessage::PLATFORM_MESSENGER) {
            $account = MessengerAccount::where('page_id', $entryId)
                ->where('active', true)
                ->first();

            if (!$account) {
                return null;
            }

            return $this->verifyHmacForAccount($account, $rawBody, $sigHeader) ? $account : null;
        }

        // Instagram DM: match explicit ig_account_id first
        $directIgAccount = MessengerAccount::where('ig_account_id', $entryId)
            ->where('active', true)
            ->first();

        if ($directIgAccount) {
            return $this->verifyHmacForAccount($directIgAccount, $rawBody, $sigHeader) ? $directIgAccount : null;
        }

        // Fallback if ig_account_id was left blank during initial setup and there is a single matching Meta App Secret
        $candidates = MessengerAccount::whereNull('ig_account_id')
            ->where('active', true)
            ->get();

        $matchedAccounts = [];
        foreach ($candidates as $candidate) {
            if ($this->verifyHmacForAccount($candidate, $rawBody, $sigHeader)) {
                $matchedAccounts[] = $candidate;
            }
        }

        if (count($matchedAccounts) === 1) {
            $matched = $matchedAccounts[0];
            $matched->ig_account_id = $entryId;
            $matched->save();
            return $matched;
        }

        return null;
    }

    protected function verifyHmacForAccount(MessengerAccount $account, string $rawBody, string $sigHeader): bool
    {
        $secret = $account->getDecryptedAppSecret();
        if ($secret === null || $secret === '') {
            return false;
        }

        $expected = 'sha256=' . hash_hmac('sha256', $rawBody, $secret);
        return hash_equals($expected, $sigHeader);
    }
}
