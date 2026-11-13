<?php

declare(strict_types=1);

namespace Modules\MetaMessenger\Jobs;

use App\Conversation;
use App\Thread;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Support\Facades\Log;
use Modules\MetaMessenger\Models\MessengerAccount;
use Modules\MetaMessenger\Models\MessengerMessage;
use Modules\MetaMessenger\Services\MetaGraphApiClient;

class SendOutboundReply implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable;

    public const NOTE_MARKER = '[Meta Messenger/IG — błąd wysyłki]';

    public int $tries = 3;

    protected int $accountId;
    protected int $threadId;
    protected string $recipientId;
    protected string $platform;

    public function __construct(int $accountId, int $threadId, string $recipientId, string $platform)
    {
        $this->accountId   = $accountId;
        $this->threadId    = $threadId;
        $this->recipientId = $recipientId;
        $this->platform    = $platform;
    }

    public function handle(): void
    {
        // Re-read fresh Thread after FreeScout's 15s Undo window
        $thread = Thread::find($this->threadId);
        if (!$thread
            || (int) $thread->type !== Thread::TYPE_MESSAGE
            || (int) $thread->state !== Thread::STATE_PUBLISHED
        ) {
            return;
        }

        // Idempotency guard: never send the same FreeScout reply twice
        if (MessengerMessage::where('thread_id', $thread->id)
            ->where('direction', MessengerMessage::DIRECTION_OUT)
            ->exists()
        ) {
            return;
        }

        $account = MessengerAccount::with('mailbox')->find($this->accountId);
        if (!$account || !$account->active) {
            self::addFailureNote(
                $thread,
                'Kanał Meta Messenger & IG jest wyłączony lub został usunięty w ustawieniach FreeScout.'
            );
            return;
        }

        $apiClient   = new MetaGraphApiClient();
        $text        = $this->extractPlainText((string) $thread->body);
        $attachments = $thread->attachments;
        $recordedMids = [];

        if ($text !== '') {
            $res = $apiClient->sendText($account, $this->recipientId, $text, $this->platform);
            if (!$res['ok']) {
                if (!empty($res['transient'])) {
                    throw new \RuntimeException(
                        '[MetaMessenger] Transient Meta API error: ' . ($res['error_message'] ?? 'unknown')
                    );
                }

                $reason = MetaGraphApiClient::describeGraphError(
                    (int) ($res['error_code'] ?? 0),
                    (int) ($res['error_subcode'] ?? 0),
                    (string) ($res['error_message'] ?? ''),
                    $this->platform
                );
                Log::error('[MetaMessenger] Outbound text send failed', [
                    'account_id'      => $account->id,
                    'conversation_id' => $thread->conversation_id,
                    'thread_id'       => $thread->id,
                    'error_code'      => $res['error_code'] ?? 0,
                    'error_subcode'   => $res['error_subcode'] ?? 0,
                ]);

                $this->recordOutboundRow($account, $thread, 'failed_thread_' . $thread->id);
                self::addFailureNote($thread, $reason);
                return;
            }

            foreach ($res['mids'] as $mid) {
                $recordedMids[] = $mid;
            }
        }

        if ($attachments && $attachments->count() > 0) {
            foreach ($attachments as $index => $attachment) {
                $localPath = $attachment->getLocalFilePath();
                $attRes    = $apiClient->sendAttachment(
                    $account,
                    $this->recipientId,
                    (string) $localPath,
                    (string) $attachment->file_name,
                    (string) $attachment->mime_type
                );

                if (!$attRes['ok']) {
                    if (!empty($attRes['transient']) && empty($recordedMids)) {
                        throw new \RuntimeException(
                            '[MetaMessenger] Transient attachment upload error: ' . ($attRes['error_message'] ?? 'unknown')
                        );
                    }

                    $reason = MetaGraphApiClient::describeGraphError(
                        (int) ($attRes['error_code'] ?? 0),
                        (int) ($attRes['error_subcode'] ?? 0),
                        (string) ($attRes['error_message'] ?? ''),
                        $this->platform
                    );
                    self::addFailureNote(
                        $thread,
                        'Załącznik "' . $attachment->file_name . '" nie został dostarczony. ' . $reason
                    );
                } elseif (!empty($attRes['mid'])) {
                    $recordedMids[] = (string) $attRes['mid'];
                } else {
                    $recordedMids[] = 'sent_att_' . $thread->id . '_' . $index;
                }
            }
        }

        if (empty($recordedMids) && $text !== '') {
            $recordedMids[] = 'sent_thread_' . $thread->id;
        }

        foreach ($recordedMids as $idx => $mid) {
            $uniqueMid = $idx === 0 ? $mid : ($mid ?: ('sent_thread_' . $thread->id . '_' . $idx));
            $this->recordOutboundRow($account, $thread, $uniqueMid);
        }
    }

    public static function addFailureNote(Thread $replyThread, string $explanation): void
    {
        if (!$replyThread->conversation_id) {
            return;
        }

        $alreadyNoted = Thread::where('conversation_id', $replyThread->conversation_id)
            ->where('type', Thread::TYPE_NOTE)
            ->where('body', 'like', self::NOTE_MARKER . '%')
            ->where('created_at', '>=', now()->subMinutes(3))
            ->exists();

        if ($alreadyNoted) {
            return;
        }

        $conversation = Conversation::find($replyThread->conversation_id);
        if (!$conversation) {
            return;
        }

        $note                  = new Thread();
        $note->conversation_id = $conversation->id;
        $note->user_id         = $replyThread->created_by_user_id ?: $replyThread->user_id;
        $note->type            = Thread::TYPE_NOTE;
        $note->status          = Conversation::STATUS_ACTIVE;
        $note->state           = Thread::STATE_PUBLISHED;
        $note->body            = htmlspecialchars(self::NOTE_MARKER . ' ' . $explanation, ENT_QUOTES, 'UTF-8');
        $note->source_via      = Thread::PERSON_USER;
        $note->source_type     = Thread::SOURCE_TYPE_WEB;
        $note->customer_id     = $conversation->customer_id;
        $note->save();

        // Reopen conversation if agent closed/pended it assuming delivery succeeded
        if ((int) $conversation->status !== Conversation::STATUS_ACTIVE) {
            $conversation->status = Conversation::STATUS_ACTIVE;
            $conversation->updateFolder();
            $conversation->save();
            if ($conversation->mailbox) {
                $conversation->mailbox->updateFoldersCounters();
            }
        }
    }

    protected function recordOutboundRow(MessengerAccount $account, Thread $thread, string $mid): void
    {
        MessengerMessage::firstOrCreate(
            ['mid' => mb_substr($mid, 0, 191)],
            [
                'account_id'      => $account->id,
                'conversation_id' => $thread->conversation_id,
                'thread_id'       => $thread->id,
                'platform'        => $this->platform,
                'sender_id'       => mb_substr($this->recipientId, 0, 64),
                'direction'       => MessengerMessage::DIRECTION_OUT,
            ]
        );
    }

    protected function extractPlainText(string $html): string
    {
        if (trim($html) === '') {
            return '';
        }

        if (class_exists('\Helper') && method_exists('\Helper', 'htmlToText')) {
            return trim((string) \Helper::htmlToText($html));
        }

        $withNewlines = preg_replace('/<br\s*\/?>/i', "\n", $html) ?? $html;
        return trim(html_entity_decode(strip_tags($withNewlines), ENT_QUOTES, 'UTF-8'));
    }
}
