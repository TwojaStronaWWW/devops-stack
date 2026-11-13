<?php

declare(strict_types=1);

namespace Modules\MetaMessenger\Providers;

require_once __DIR__ . '/../autoload.php';

use App\Attachment;
use App\Conversation;
use App\CustomerChannel;
use App\Thread;
use Illuminate\Support\ServiceProvider;
use Modules\MetaMessenger\Jobs\SendOutboundReply;
use Modules\MetaMessenger\Models\MessengerAccount;
use Modules\MetaMessenger\Models\MessengerMessage;

class MetaMessengerServiceProvider extends ServiceProvider
{
    public function boot(): void
    {
        $this->loadViewsFrom(__DIR__ . '/../Views', 'metamessenger');
        $this->loadMigrationsFrom(__DIR__ . '/../Database/Migrations');
        $this->registerHooks();
    }

    public function register(): void
    {
        $this->mergeConfigFrom(__DIR__ . '/../Config/config.php', 'metamessenger');
    }

    protected function registerHooks(): void
    {
        // Admin menu item under Manage -> Meta Messenger & IG
        \Eventy::addAction('menu.manage.append', static function (): void {
            if (auth()->user() && auth()->user()->isAdmin()) {
                echo view('metamessenger::menu')->render();
            }
        });

        // Register Messenger (105) & Instagram (106) channels in FreeScout core
        \Eventy::addFilter('channels.list', static function (array $channels): array {
            $channels[MessengerAccount::CHANNEL_MESSENGER] = MessengerAccount::CHANNEL_MESSENGER_NAME;
            $channels[MessengerAccount::CHANNEL_INSTAGRAM] = MessengerAccount::CHANNEL_INSTAGRAM_NAME;
            return $channels;
        }, 20, 1);

        \Eventy::addFilter('channel.name', static function (string $name, $channel = null): string {
            $channelInt = (int) $channel;
            if ($channelInt === MessengerAccount::CHANNEL_MESSENGER) {
                return MessengerAccount::CHANNEL_MESSENGER_NAME;
            }
            if ($channelInt === MessengerAccount::CHANNEL_INSTAGRAM) {
                return MessengerAccount::CHANNEL_INSTAGRAM_NAME;
            }
            return $name;
        }, 20, 2);

        // Outbound reply handler for TYPE_CHAT conversations (triggered by FreeScout after 15s Undo window)
        \Eventy::addAction('chat_conversation.send_reply', function ($conversation, $replies, $customer): void {
            $this->handleOutboundChatReply($conversation, $replies, $customer);
        }, 20, 3);

        // Clean CSS injection (zero inline styles in Blade templates) + dashboard counter visibility for chat-only mailboxes
        \Eventy::addAction('layout.head', function (): void {
            $css = $this->moduleBaseCss();

            if ($this->isCurrentConversationMetaSocial()) {
                $css .= '#toggle-cc, .sidebar-title-email { display: none !important; }';
            }

            $route = \Route::current();
            if ($route && $route->getName() === 'dashboard') {
                $css .= $this->dashboardCounterFixCss();
            }

            if ($css !== '') {
                $nonce = (class_exists('\Helper') && method_exists('\Helper', 'cspNonceAttr'))
                    ? (string) \Helper::cspNonceAttr()
                    : '';
                echo '<style' . $nonce . '>' . $css . '</style>';
            }
        });

        // Inline image thumbnail preview inside Messenger/IG conversation threads
        \Eventy::addAction('thread.attachment_append', function ($attachment, $thread, $conversation, $mailbox): void {
            if (!$conversation || !in_array((int) $conversation->channel, [
                MessengerAccount::CHANNEL_MESSENGER,
                MessengerAccount::CHANNEL_INSTAGRAM,
            ], true)) {
                return;
            }

            if ((int) $attachment->type !== Attachment::TYPE_IMAGE) {
                return;
            }

            echo '<div class="mm-attachment-preview">'
                . '<a href="' . e($attachment->url()) . '" target="_blank" rel="noopener noreferrer">'
                . '<img src="' . e($attachment->url()) . '" alt="' . e($attachment->file_name) . '" class="mm-attachment-thumb">'
                . '</a></div>';
        }, 20, 4);
    }

    /**
     * Handle outbound replies from FreeScout agents to Facebook Messenger / Instagram DM.
     * Signature matches app/Listeners/SendReplyToCustomer.php:89:
     * \Helper::backgroundAction('chat_conversation.send_reply', [$conversation, $replies, $conversation->customer], ...)
     */
    protected function handleOutboundChatReply($conversationSnapshot, $replies, $customerSnapshot = null): void
    {
        $convId = is_object($conversationSnapshot) ? ($conversationSnapshot->id ?? null) : ($conversationSnapshot['id'] ?? null);
        if (!$convId) {
            return;
        }

        $conversation = Conversation::find($convId);
        if (!$conversation) {
            return;
        }

        $platform = MessengerAccount::platformForChannel((int) $conversation->channel);
        if ($platform === null) {
            return; // Conversation belongs to another chat channel (e.g. WhatsApp 103/104)
        }

        $firstPublished = $this->findFirstPublishedReply($replies);
        if (!$firstPublished) {
            return;
        }

        $lastInbound = MessengerMessage::where('conversation_id', $conversation->id)
            ->where('direction', MessengerMessage::DIRECTION_IN)
            ->orderBy('id', 'desc')
            ->first();

        $account = null;
        if ($lastInbound && $lastInbound->account_id) {
            $account = MessengerAccount::find($lastInbound->account_id);
        }
        if (!$account) {
            $account = MessengerAccount::where('mailbox_id', $conversation->mailbox_id)
                ->where('active', true)
                ->orderBy('id')
                ->first();
        }

        if (!$account || !$account->active) {
            SendOutboundReply::addFailureNote(
                $firstPublished,
                'Brak aktywnego konta Meta Messenger & IG powiązanego z tą skrzynką.'
            );
            return;
        }

        $recipientId = $lastInbound ? trim((string) $lastInbound->sender_id) : '';
        if ($recipientId === '') {
            $recipientId = trim((string) CustomerChannel::where('customer_id', $conversation->customer_id)
                ->where('channel', (int) $conversation->channel)
                ->value('channel_id'));
        }

        if ($recipientId === '') {
            SendOutboundReply::addFailureNote(
                $firstPublished,
                'Nie znaleziono identyfikatora odbiorcy (PSID / IGSID) dla tej konwersacji.'
            );
            return;
        }

        if (!is_iterable($replies)) {
            return;
        }

        foreach ($replies as $replyItem) {
            $replyId = is_object($replyItem) ? ($replyItem->id ?? null) : ($replyItem['id'] ?? null);
            if (!$replyId) {
                continue;
            }

            $freshThread = Thread::find($replyId);
            if (!$freshThread
                || (int) $freshThread->type !== Thread::TYPE_MESSAGE
                || (int) $freshThread->state !== Thread::STATE_PUBLISHED
            ) {
                continue;
            }

            if (MessengerMessage::where('thread_id', $freshThread->id)
                ->where('direction', MessengerMessage::DIRECTION_OUT)
                ->exists()
            ) {
                continue;
            }

            SendOutboundReply::dispatch($account->id, $freshThread->id, $recipientId, $platform);
        }
    }

    protected function findFirstPublishedReply($replies): ?Thread
    {
        if (!is_iterable($replies)) {
            return null;
        }

        foreach ($replies as $replyItem) {
            $replyId = is_object($replyItem) ? ($replyItem->id ?? null) : ($replyItem['id'] ?? null);
            if (!$replyId) {
                continue;
            }

            $fresh = Thread::find($replyId);
            if ($fresh
                && (int) $fresh->type === Thread::TYPE_MESSAGE
                && (int) $fresh->state === Thread::STATE_PUBLISHED
            ) {
                return $fresh;
            }
        }

        return null;
    }

    protected function isCurrentConversationMetaSocial(): bool
    {
        $route = \Route::current();
        if (!$route || $route->getName() !== 'conversations.view') {
            return false;
        }

        $conv = Conversation::find($route->parameter('id'));
        if (!$conv) {
            return false;
        }

        return in_array((int) $conv->channel, [
            MessengerAccount::CHANNEL_MESSENGER,
            MessengerAccount::CHANNEL_INSTAGRAM,
        ], true);
    }

    protected function dashboardCounterFixCss(): string
    {
        $mailboxIds = [];

        try {
            $accounts = MessengerAccount::with('mailbox')->where('active', true)->get();
            foreach ($accounts as $account) {
                $mailbox = $account->mailbox;
                if ($mailbox && empty($mailbox->in_server)) {
                    $mailboxIds[(int) $mailbox->id] = (int) $mailbox->id;
                }
            }
        } catch (\Throwable $e) {
            // Table may not be migrated yet during initial boot
        }

        try {
            if (class_exists('\App\Mailbox')) {
                $allMailboxes = \App\Mailbox::get();
                foreach ($allMailboxes as $mailbox) {
                    if (empty($mailbox->in_server)
                        && method_exists($mailbox, 'getMeta')
                        && (int) $mailbox->getMeta('chat_only_tile', 0) === 1
                    ) {
                        $mailboxIds[(int) $mailbox->id] = (int) $mailbox->id;
                    }
                }
            }
        } catch (\Throwable $e) {
            // Ignore DB read issues during CLI bootstrap
        }

        if (empty($mailboxIds)) {
            return '';
        }

        $listSelectors    = [];
        $contentSelectors = [];
        $cardSelectors    = [];

        foreach ($mailboxIds as $mailboxId) {
            $base               = '.dash-card.dash-card-inactive[data-mailbox-id="' . (int) $mailboxId . '"]';
            $listSelectors[]    = $base . ' .dash-card-list';
            $contentSelectors[] = $base . ' .dash-card-inactive-content';
            $cardSelectors[]    = $base;
        }

        return implode(', ', $listSelectors) . ' { display: block; }'
            . implode(', ', $contentSelectors) . ' { display: none; }'
            . implode(', ', $cardSelectors) . ' { background: transparent; }';
    }

    protected function moduleBaseCss(): string
    {
        $route = \Route::current();
        $isModulePage = $route && str_starts_with((string) $route->getName(), 'metamessenger.');

        $common = '.mm-attachment-preview { margin-top: 6px; }'
            . '.mm-attachment-thumb { max-width: 220px; max-height: 220px; border-radius: 4px; }';

        if (!$isModulePage) {
            return $common;
        }

        return $common
            . '.mm-container { margin-top: 20px; }'
            . '.mm-section-title { margin-top: 26px; }'
            . '.mm-section-hr { margin-top: 5px; }'
            . '.mm-inline-form { display: inline; }'
            . '.mm-badge-ok { color: #2e7d32; font-weight: 600; }'
            . '.mm-badge-off { color: #757575; }'
            . '.mm-badge-err { color: #c62828; font-weight: 600; }';
    }
}
