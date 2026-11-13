<?php

declare(strict_types=1);

namespace Modules\MetaMessenger\Http\Controllers;

use App\Mailbox;
use App\User;
use Illuminate\Http\Request;
use Illuminate\Routing\Controller;
use Modules\MetaMessenger\Models\MessengerAccount;
use Modules\MetaMessenger\Services\MetaGraphApiClient;

class MetaMessengerController extends Controller
{
    public const CREATE_NEW_MAILBOX_VALUE = '__create_new__';

    public function index()
    {
        $this->requireAdmin();

        $accounts   = MessengerAccount::with('mailbox')->orderBy('id')->get();
        $webhookUrl = $this->buildWebhookUrl();
        $isHttps    = str_starts_with((string) config('app.url'), 'https://');

        return view('metamessenger::index', [
            'accounts'   => $accounts,
            'webhookUrl' => $webhookUrl,
            'isHttps'    => $isHttps,
        ]);
    }

    public function create()
    {
        $this->requireAdmin();

        $mailboxes        = Mailbox::orderBy('name')->get();
        $defaultMailboxId = self::CREATE_NEW_MAILBOX_VALUE;

        $precreated = $mailboxes->first(static function ($mb) {
            return strtolower((string) $mb->email) === 'messenger@katosalsahub.pl';
        });
        if ($precreated && !MessengerAccount::where('mailbox_id', $precreated->id)->exists()) {
            $defaultMailboxId = (string) $precreated->id;
        }

        return view('metamessenger::form', [
            'account'          => null,
            'mailboxes'        => $mailboxes,
            'defaultMailboxId' => $defaultMailboxId,
            'generatedToken'   => bin2hex(random_bytes(24)),
            'webhookUrl'       => $this->buildWebhookUrl(),
        ]);
    }

    public function store(Request $request)
    {
        $this->requireAdmin();

        $validated = $request->validate([
            'name'               => 'required|string|max:100',
            'mailbox_choice'     => 'required|string',
            'new_mailbox_name'   => 'nullable|string|max:40',
            'page_id'            => 'required|string|max:64|regex:/^[0-9A-Za-z._-]+$/|unique:meta_messenger_accounts,page_id',
            'ig_account_id'      => 'nullable|string|max:64|regex:/^[0-9A-Za-z._-]+$/',
            'app_id'             => 'nullable|string|max:64|regex:/^[0-9A-Za-z._-]+$/',
            'app_secret'         => 'required|string|min:16|max:255',
            'page_access_token'  => 'required|string|min:20|max:2048',
            'verify_token'       => 'required|string|min:16|max:128',
        ]);

        $mailboxId = $this->resolveMailboxId($request, (string) $validated['name'], (string) $validated['page_id']);

        $account = new MessengerAccount();
        $account->fill([
            'mailbox_id'    => $mailboxId,
            'name'          => trim((string) $validated['name']),
            'page_id'       => trim((string) $validated['page_id']),
            'ig_account_id' => $this->nullIfEmpty($validated['ig_account_id'] ?? null),
            'app_id'        => $this->nullIfEmpty($validated['app_id'] ?? null),
            'verify_token'  => trim((string) $validated['verify_token']),
            'active'        => (bool) $request->input('active', 1),
        ]);
        $account->setAppSecretPlain(trim((string) $validated['app_secret']));
        $account->setPageAccessTokenPlain(trim((string) $validated['page_access_token']));
        $account->save();

        \Session::flash('flash_success_floating', 'Konto Meta Messenger & IG zostało zapisane i zaszyfrowane.');

        return redirect()->route('metamessenger.index');
    }

    public function edit($id)
    {
        $this->requireAdmin();

        $account = MessengerAccount::findOrFail((int) $id);

        return view('metamessenger::form', [
            'account'        => $account,
            'mailboxes'      => Mailbox::orderBy('name')->get(),
            'generatedToken' => $account->verify_token,
            'webhookUrl'     => $this->buildWebhookUrl(),
        ]);
    }

    public function update(Request $request, $id)
    {
        $this->requireAdmin();

        $account = MessengerAccount::findOrFail((int) $id);

        $validated = $request->validate([
            'name'               => 'required|string|max:100',
            'mailbox_choice'     => 'required|string',
            'new_mailbox_name'   => 'nullable|string|max:40',
            'page_id'            => 'required|string|max:64|regex:/^[0-9A-Za-z._-]+$/|unique:meta_messenger_accounts,page_id,' . $account->id,
            'ig_account_id'      => 'nullable|string|max:64|regex:/^[0-9A-Za-z._-]+$/',
            'app_id'             => 'nullable|string|max:64|regex:/^[0-9A-Za-z._-]+$/',
            'app_secret'         => 'nullable|string|min:16|max:255',
            'page_access_token'  => 'nullable|string|min:20|max:2048',
            'verify_token'       => 'required|string|min:16|max:128',
        ]);

        $mailboxId = $this->resolveMailboxId($request, (string) $validated['name'], (string) $validated['page_id']);

        $account->fill([
            'mailbox_id'    => $mailboxId,
            'name'          => trim((string) $validated['name']),
            'page_id'       => trim((string) $validated['page_id']),
            'ig_account_id' => $this->nullIfEmpty($validated['ig_account_id'] ?? null),
            'app_id'        => $this->nullIfEmpty($validated['app_id'] ?? null),
            'verify_token'  => trim((string) $validated['verify_token']),
            'active'        => $request->has('active'),
        ]);

        $newSecret = trim((string) ($validated['app_secret'] ?? ''));
        if ($newSecret !== '') {
            $account->setAppSecretPlain($newSecret);
        }

        $newToken = trim((string) ($validated['page_access_token'] ?? ''));
        if ($newToken !== '') {
            $account->setPageAccessTokenPlain($newToken);
        }

        $account->save();

        \Session::flash('flash_success_floating', 'Ustawienia konta Meta Messenger & IG zostały zaktualizowane.');

        return redirect()->route('metamessenger.index');
    }

    public function destroy($id)
    {
        $this->requireAdmin();

        $account = MessengerAccount::findOrFail((int) $id);
        $account->delete();

        \Session::flash('flash_success_floating', 'Konto Meta Messenger & IG zostało usunięte (historia konwersacji została zachowana).');

        return redirect()->route('metamessenger.index');
    }

    public function testConnection($id)
    {
        $this->requireAdmin();

        $account = MessengerAccount::findOrFail((int) $id);
        $client  = new MetaGraphApiClient();
        $result  = $client->testPageConnection($account);

        if (!$result['ok']) {
            \Session::flash('flash_error_floating', 'Test połączenia nieudany: ' . ($result['error'] ?? 'Nieznany błąd'));
            return redirect()->route('metamessenger.index');
        }

        $msg = 'Połączenie z Meta Graph API aktywne — Fanpage: "' . ($result['page_name'] ?? $account->page_id) . '"';

        if (!empty($result['ig_account_id'])) {
            if (!$account->ig_account_id) {
                $account->ig_account_id = (string) $result['ig_account_id'];
                $account->save();
                $msg .= ' (automatycznie wykryto i zapisano Instagram Business ID: ' . $account->ig_account_id . ')';
            } else {
                $msg .= ' (Instagram Business ID: ' . $result['ig_account_id'] . ')';
            }
        }

        \Session::flash('flash_success_floating', $msg);

        return redirect()->route('metamessenger.index');
    }

    protected function resolveMailboxId(Request $request, string $channelName, string $pageId): int
    {
        $choice = trim((string) $request->input('mailbox_choice', ''));
        if ($choice !== self::CREATE_NEW_MAILBOX_VALUE) {
            $existing = Mailbox::findOrFail((int) $choice);
            return (int) $existing->id;
        }

        $rawMailboxName = trim((string) $request->input('new_mailbox_name', ''));
        $mailboxName    = mb_substr($rawMailboxName !== '' ? $rawMailboxName : $channelName, 0, 40);

        $syntheticEmail = 'messenger-' . preg_replace('/[^0-9a-zA-Z]/', '', $pageId) . '@social.freescout.local';
        if (Mailbox::where('email', $syntheticEmail)->exists()) {
            $syntheticEmail = 'messenger-' . preg_replace('/[^0-9a-zA-Z]/', '', $pageId) . '-' . substr(bin2hex(random_bytes(3)), 0, 6) . '@social.freescout.local';
        }

        $mailbox                     = new Mailbox();
        $mailbox->name               = $mailboxName;
        $mailbox->email              = mb_substr($syntheticEmail, 0, 128);
        $mailbox->from_name          = Mailbox::FROM_NAME_MAILBOX;
        $mailbox->ticket_status      = Mailbox::TICKET_STATUS_PENDING;
        $mailbox->ticket_assignee    = Mailbox::TICKET_ASSIGNEE_REPLYING_UNASSIGNED;
        $mailbox->auto_reply_enabled = 0;
        $mailbox->ratings            = 0;
        $mailbox->signature          = '';
        $mailbox->save(); // MailboxObserver::created creates public + admin personal folders

        $adminIds = User::where('role', User::ROLE_ADMIN)->pluck('id')->all();
        if (!empty($adminIds)) {
            $pivotAttach = [];
            foreach ($adminIds as $adminId) {
                $pivotAttach[(int) $adminId] = [
                    'after_send' => 2,
                    'hide'       => 0,
                    'mute'       => 0,
                ];
            }
            $mailbox->users()->syncWithoutDetaching($pivotAttach);
            $mailbox->syncPersonalFolders($adminIds);
        }

        return (int) $mailbox->id;
    }

    protected function buildWebhookUrl(): string
    {
        $baseUrl = rtrim((string) config('app.url'), '/');
        $subdir  = rtrim((string) \Helper::getSubdirectory(), '/');

        return $baseUrl . $subdir . '/meta-messenger/webhook';
    }

    protected function nullIfEmpty($value): ?string
    {
        $trimmed = trim((string) ($value ?? ''));
        return $trimmed !== '' ? $trimmed : null;
    }

    protected function requireAdmin(): void
    {
        if (!auth()->user() || !auth()->user()->isAdmin()) {
            \Helper::denyAccess();
        }
    }
}
