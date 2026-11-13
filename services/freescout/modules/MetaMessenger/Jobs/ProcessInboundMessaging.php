<?php

declare(strict_types=1);

namespace Modules\MetaMessenger\Jobs;

use App\Attachment;
use App\Conversation;
use App\Customer;
use App\CustomerChannel;
use App\Events\CustomerCreatedConversation;
use App\Events\CustomerReplied;
use App\Thread;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Database\QueryException;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Modules\MetaMessenger\Models\MessengerAccount;
use Modules\MetaMessenger\Models\MessengerMessage;
use Modules\MetaMessenger\Services\MetaGraphApiClient;

class ProcessInboundMessaging implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable;

    public int $tries = 3;

    protected int $accountId;
    protected string $platform;

    /** @var array<string, mixed> */
    protected array $event;

    /**
     * @param array<string, mixed> $event
     */
    public function __construct(int $accountId, string $platform, array $event)
    {
        $this->accountId = $accountId;
        $this->platform  = $platform;
        $this->event     = $event;
    }

    public function handle(): void
    {
        $account = MessengerAccount::with('mailbox')->find($this->accountId);
        if (!$account || !$account->active || !$account->mailbox) {
            Log::warning('[MetaMessenger] Inbound event skipped: account missing, inactive, or mailbox unlinked', [
                'account_id' => $this->accountId,
            ]);
            return;
        }

        // Ignore delivery/read receipts and echo messages sent by the Page/IG business account itself
        if (isset($this->event['delivery']) || isset($this->event['read'])) {
            return;
        }

        $messageNode  = is_array($this->event['message'] ?? null) ? $this->event['message'] : null;
        $postbackNode = is_array($this->event['postback'] ?? null) ? $this->event['postback'] : null;

        if ($messageNode !== null && !empty($messageNode['is_echo'])) {
            return;
        }

        if ($messageNode !== null && !empty($messageNode['is_deleted'])) {
            return;
        }

        $senderId = trim((string) ($this->event['sender']['id'] ?? ''));
        if ($senderId === '' || $senderId === $account->page_id || ($account->ig_account_id && $senderId === $account->ig_account_id)) {
            return;
        }

        $mid = '';
        $text = '';
        $rawAttachments = [];

        if ($messageNode !== null) {
            $mid  = trim((string) ($messageNode['mid'] ?? ''));
            $text = trim((string) ($messageNode['text'] ?? ''));
            if (is_array($messageNode['attachments'] ?? null)) {
                $rawAttachments = $messageNode['attachments'];
            }
        } elseif ($postbackNode !== null) {
            $mid  = trim((string) ($postbackNode['mid'] ?? ''));
            $text = trim((string) ($postbackNode['title'] ?? $postbackNode['payload'] ?? ''));
            if ($mid === '' && $text !== '') {
                $ts  = (string) ($this->event['timestamp'] ?? time());
                $mid = 'postback_' . sha1($account->id . '|' . $senderId . '|' . $ts . '|' . $text);
            }
        } else {
            return;
        }

        if ($mid === '') {
            return;
        }

        // Idempotency guard against Meta webhook retries
        if (MessengerMessage::where('mid', $mid)->exists()) {
            return;
        }

        $apiClient = new MetaGraphApiClient();
        $downloadedFiles = [];
        $fallbackAttachmentNotes = [];

        foreach ($rawAttachments as $att) {
            if (!is_array($att)) {
                continue;
            }
            $attType = strtolower(trim((string) ($att['type'] ?? 'file')));
            $attUrl  = trim((string) ($att['payload']['url'] ?? ''));

            if ($attUrl !== '' && in_array($attType, ['image', 'video', 'audio', 'file', 'sticker'], true)) {
                $downloaded = $apiClient->downloadMediaAttachment($attUrl, $attType);
                if ($downloaded !== null) {
                    $downloaded['att_type'] = $attType;
                    $downloadedFiles[]      = $downloaded;
                } else {
                    $fallbackAttachmentNotes[] = '[Załącznik ' . $attType . ' niedostępny do pobrania]';
                }
            } elseif ($attType !== '') {
                $title = trim((string) ($att['title'] ?? ''));
                $fallbackAttachmentNotes[] = $title !== ''
                    ? ('[' . ucfirst($attType) . ': ' . $title . ']')
                    : ('[Załącznik: ' . $attType . ']');
            }
        }

        if ($text === '' && !empty($fallbackAttachmentNotes)) {
            $text = implode("\n", $fallbackAttachmentNotes);
        } elseif ($text !== '' && !empty($fallbackAttachmentNotes)) {
            $text .= "\n\n" . implode("\n", $fallbackAttachmentNotes);
        }

        if ($text === '' && empty($downloadedFiles)) {
            return;
        }

        $displayText = $text !== ''
            ? $text
            : ('[Załącznik multimedialny: ' . ($downloadedFiles[0]['att_type'] ?? 'plik') . ']');

        $channelConst = MessengerAccount::channelForPlatform($this->platform);

        try {
            DB::transaction(function () use (
                $account,
                $apiClient,
                $channelConst,
                $senderId,
                $mid,
                $displayText,
                $downloadedFiles
            ): void {
                if (MessengerMessage::where('mid', $mid)->exists()) {
                    return;
                }

                $customer = $this->resolveOrCreateCustomer($account, $apiClient, $channelConst, $senderId);

                $conversation = Conversation::where('mailbox_id', $account->mailbox_id)
                    ->where('customer_id', $customer->id)
                    ->where('channel', $channelConst)
                    ->where('status', '!=', Conversation::STATUS_SPAM)
                    ->orderBy('created_at', 'desc')
                    ->first();

                if ($conversation && $conversation->chatShouldStartNew($account->mailbox)) {
                    $conversation = null;
                }

                $isNew    = !$conversation;
                $safeBody = nl2br(htmlspecialchars($displayText, ENT_QUOTES, 'UTF-8'));

                if ($isNew) {
                    $prefix       = $this->platform === MessengerMessage::PLATFORM_INSTAGRAM ? 'Instagram DM' : 'Messenger';
                    $customerName = trim($customer->getFullName()) ?: $senderId;

                    $conversation                        = new Conversation();
                    $conversation->type                  = Conversation::TYPE_CHAT;
                    $conversation->channel               = $channelConst;
                    $conversation->state                 = Conversation::STATE_PUBLISHED;
                    $conversation->subject               = mb_substr($prefix . ': ' . $customerName, 0, Conversation::SUBJECT_MAXLENGTH);
                    $conversation->mailbox_id            = $account->mailbox_id;
                    $conversation->customer_id           = $customer->id;
                    $conversation->customer_email        = '';
                    $conversation->created_by_customer_id = $customer->id;
                    $conversation->source_via            = Conversation::PERSON_CUSTOMER;
                    $conversation->source_type           = Conversation::SOURCE_TYPE_API;
                }

                $prevStatus           = $conversation->status;
                $conversation->status = \Eventy::filter(
                    'conversation.status_changing',
                    Conversation::STATUS_ACTIVE,
                    $conversation
                );

                if ($conversation->last_reply_from != Conversation::PERSON_CUSTOMER || !$conversation->last_reply_at) {
                    $conversation->last_reply_at = now();
                }
                $conversation->last_reply_from = Conversation::PERSON_CUSTOMER;
                $conversation->setPreview($displayText);

                if ($conversation->state == Conversation::STATE_DELETED) {
                    $conversation->state = Conversation::STATE_PUBLISHED;
                }

                $conversation->updateFolder();
                $conversation->save();

                $thread                        = new Thread();
                $thread->conversation_id       = $conversation->id;
                $thread->user_id               = $conversation->user_id;
                $thread->type                  = Thread::TYPE_CUSTOMER;
                $thread->status                = $conversation->status;
                $thread->state                 = Thread::STATE_PUBLISHED;
                $thread->body                  = $safeBody;
                $thread->from                  = mb_substr(trim($customer->getFullName()) ?: $senderId, 0, 190);
                $thread->source_via            = Thread::PERSON_CUSTOMER;
                $thread->source_type           = Thread::SOURCE_TYPE_API;
                $thread->customer_id           = $customer->id;
                $thread->created_by_customer_id = $customer->id;
                $thread->first                 = $isNew;
                $thread->save();

                if (!empty($downloadedFiles)) {
                    foreach ($downloadedFiles as $file) {
                        $category = $this->mapAttachmentCategory($file['att_type']);
                        $typeInt  = Attachment::typeNameToInt($category);
                        Attachment::create(
                            $file['filename'],
                            $file['mime_type'],
                            $typeInt,
                            $file['bytes'],
                            null,
                            false,
                            $thread->id
                        );
                    }
                    $thread->has_attachments = true;
                    $thread->save();
                    $conversation->has_attachments = true;
                    $conversation->save();
                }

                MessengerMessage::create([
                    'account_id'      => $account->id,
                    'conversation_id' => $conversation->id,
                    'thread_id'       => $thread->id,
                    'mid'             => mb_substr($mid, 0, 191),
                    'platform'        => $this->platform,
                    'sender_id'       => mb_substr($senderId, 0, 64),
                    'direction'       => MessengerMessage::DIRECTION_IN,
                ]);

                $this->dispatchFreeScoutEvents($account, $conversation, $thread, $customer, $isNew, $prevStatus);
            });
        } catch (QueryException $e) {
            if ((string) ($e->errorInfo[1] ?? '') === '1062') {
                return; // Concurrent duplicate mid delivery safely ignored
            }
            throw $e;
        }
    }

    protected function resolveOrCreateCustomer(
        MessengerAccount $account,
        MetaGraphApiClient $apiClient,
        int $channelConst,
        string $senderId
    ): Customer {
        $existing = Customer::getCustomerByChannel($channelConst, $senderId);
        if ($existing) {
            return $existing;
        }

        $profile = $apiClient->fetchUserProfile($account, $senderId, $this->platform);

        $customer             = new Customer();
        $customer->first_name = $profile['first_name'];
        $customer->last_name  = $profile['last_name'];
        $customer->save();

        CustomerChannel::create($customer->id, $channelConst, $senderId);

        return $customer;
    }

    protected function dispatchFreeScoutEvents(
        MessengerAccount $account,
        Conversation $conversation,
        Thread $thread,
        Customer $customer,
        bool $isNew,
        $prevStatus
    ): void {
        $account->mailbox->updateFoldersCounters();

        if ($isNew) {
            event(new CustomerCreatedConversation($conversation, $thread));
            \Eventy::action('conversation.created_by_customer', $conversation, $thread, $customer);
        } else {
            event(new CustomerReplied($conversation, $thread));
            \Eventy::action('conversation.customer_replied', $conversation, $thread, $customer);
        }

        if ($prevStatus && $prevStatus != $conversation->status) {
            $systemUser = ($conversation->user_id && $conversation->user)
                ? $conversation->user
                : $account->mailbox->usersHavingAccess()->first();

            if ($systemUser) {
                \Eventy::action('conversation.status_changed', $conversation, $systemUser, false, $prevStatus);
            }
        }
    }

    protected function mapAttachmentCategory(string $attType): string
    {
        return match ($attType) {
            'image', 'sticker' => 'image',
            'video'            => 'video',
            'audio'            => 'audio',
            default            => 'application',
        };
    }
}
