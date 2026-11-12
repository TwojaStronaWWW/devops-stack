<?php
/**
 * setup-freescout-mailboxes.php
 * Idempotentna konfiguracja OPSEC Lockdown, ochrony flag IMAP Outlooka (ImapLeaveUnread)
 * oraz izolowanych skrzynek IMAP/SMTP wewnątrz kontenera FreeScout (nfrastack/freescout).
 *
 * Uruchamianie (Zero-Secrets-in-Args):
 *   docker exec -i -u nginx \
 *     -e FS_MB_KATOSALSA_PASS -e FS_MB_TSW_PASS -e FS_MB_WK_PASS \
 *     -e FS_MB_IK_EMAIL -e FS_MB_IK_PASS \
 *     -e FS_MB_MAXBIT_EMAIL -e FS_MB_MAXBIT_PASS \
 *     freescout php < scripts/setup-freescout-mailboxes.php
 */

declare(strict_types=1);

$basePath = is_dir('/www/html') ? '/www/html' : '/var/www/html';
require $basePath . '/vendor/autoload.php';

$app = require_once $basePath . '/bootstrap/app.php';
$kernel = $app->make(\Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();

function fsReadEnvSecret(string $plainKey, string $b64Key): string
{
    $b64 = trim((string) getenv($b64Key));
    if ($b64 !== '') {
        $decoded = base64_decode($b64, true);
        if (is_string($decoded) && $decoded !== '') {
            return $decoded;
        }
    }
    return (string) getenv($plainKey);
}

/**
 * Instaluje i aktywuje lekki moduł ImapLeaveUnread w trwałym wolumenie /data/Modules,
 * który chroni flagi nieprzeczytanych wiadomości (\Seen) na serwerze IMAP (np. dla aktywnego Outlooka)
 * dla skrzynek z ustawionym meta['leave_unread_on_imap'] = 1.
 */
function fsEnsureImapLeaveUnreadModule(string $basePath): bool
{
    $modulesRoot = is_dir('/data/Modules') ? '/data/Modules' : ($basePath . '/Modules');
    $modDir = $modulesRoot . '/ImapLeaveUnread';
    if (!is_dir($modDir)) {
        @mkdir($modDir, 0775, true);
    }

    $moduleJson = json_encode([
        'name'        => 'ImapLeaveUnread',
        'alias'       => 'imapleaveunread',
        'description' => 'Preserves unread (\\Seen) flags on IMAP server for mailboxes with meta.leave_unread_on_imap=1 (Outlook sync protection).',
        'version'     => '1.0.0',
        'active'      => 1,
        'order'       => 1,
        'providers'   => [],
        'aliases'     => new \stdClass(),
        'files'       => ['start.php'],
        'requires'    => [],
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;

    $startPhp = <<<'PHP'
<?php

if (class_exists('\Eventy')) {
    \Eventy::addFilter('fetch_emails.unseen', function ($unseen, $mailbox) {
        if ($mailbox && method_exists($mailbox, 'getMeta') && (int) $mailbox->getMeta('leave_unread_on_imap', 0) === 1) {
            return 0;
        }
        return $unseen;
    }, 20, 2);

    \Eventy::addFilter('fetch_emails.set_seen_flag', function ($flag, $message, $mailbox) {
        if ($mailbox && method_exists($mailbox, 'getMeta') && (int) $mailbox->getMeta('leave_unread_on_imap', 0) === 1) {
            return [];
        }
        return $flag;
    }, 20, 3);
}
PHP;

    $wasActive = class_exists('\App\Module') ? (bool) \App\Module::isActive('imapleaveunread') : false;
    $changed = (!is_file($modDir . '/module.json')) || (!is_file($modDir . '/start.php')) || !$wasActive;

    file_put_contents($modDir . '/module.json', $moduleJson);
    file_put_contents($modDir . '/start.php', $startPhp . PHP_EOL);

    if (class_exists('\App\Module') && method_exists('\App\Module', 'setActive')) {
        \App\Module::setActive('imapleaveunread', true);
        if (method_exists('\App\Module', 'clearModulesCache')) {
            \App\Module::clearModulesCache();
        }
    }
    if ($changed && class_exists('\Illuminate\Support\Facades\Artisan')) {
        \Illuminate\Support\Facades\Artisan::call('freescout:clear-cache');
    } elseif (class_exists('\Module') && method_exists('\Module', 'clearCache')) {
        \Module::clearCache();
    }

    return class_exists('\App\Module') ? (bool) \App\Module::isActive('imapleaveunread') : true;
}

// 1. Twardy OPSEC Lockdown (zero pixel-trackingu i zero stopki FreeScout)
\App\Option::set('open_tracking', 0);
\App\Option::set('email_branding', 0);

// 1b. Aktywacja ochrony flag nieprzeczytanych wiadomości IMAP (dla współdzielonego Outlooka)
$imapLeaveUnreadActive = fsEnsureImapLeaveUnreadModule($basePath);

$fromMailboxConst = defined('\App\Mailbox::FROM_NAME_MAILBOX') ? \App\Mailbox::FROM_NAME_MAILBOX : 1;
$fromCustomConst  = defined('\App\Mailbox::FROM_NAME_CUSTOM') ? \App\Mailbox::FROM_NAME_CUSTOM : 3;

// 2. Definicje izolowanych tożsamości skrzynek pocztowych
$definitions = [];

$kshPass = fsReadEnvSecret('FS_MB_KATOSALSA_PASS', 'FS_MB_KATOSALSA_PASS_B64');
if ($kshPass !== '') {
    $definitions[] = [
        'email'                => 'kontakt@katosalsahub.pl',
        'name'                 => 'Fundacja Kato Salsa Hub',
        'from_name'            => $fromMailboxConst,
        'from_name_custom'     => null,
        'host'                 => 'mail21.lh.pl',
        'pass'                 => $kshPass,
        'signature'            => '<br>--<br>Fundacja Kato Salsa Hub<br>katosalsahub.pl',
        'leave_unread_on_imap' => 0,
    ];
}

$tswPass = fsReadEnvSecret('FS_MB_TSW_PASS', 'FS_MB_TSW_PASS_B64');
if ($tswPass !== '') {
    $definitions[] = [
        'email'                => 'kontakt@twojastronawww.pl',
        'name'                 => 'TwojaStronaWWW (IT)',
        'from_name'            => $fromMailboxConst,
        'from_name_custom'     => null,
        'host'                 => 'mail21.lh.pl',
        'pass'                 => $tswPass,
        'signature'            => '<br>--<br>Krzysztof Początek IT — TwojaStronaWWW<br>twojastronawww.pl',
        'leave_unread_on_imap' => 0,
    ];
}

$wkPass = fsReadEnvSecret('FS_MB_WK_PASS', 'FS_MB_WK_PASS_B64');
if ($wkPass !== '') {
    // 100% OPSEC: całkowita izolacja od działalności IT / TwojaStronaWWW
    $definitions[] = [
        'email'                => 'kontakt@wspolnekamienice.pl',
        'name'                 => 'Wspólne Kamienice',
        'from_name'            => $fromMailboxConst,
        'from_name_custom'     => null,
        'host'                 => 'mail21.lh.pl',
        'pass'                 => $wkPass,
        'signature'            => '<br>--<br>Inicjatywa Wspólne Kamienice',
        'leave_unread_on_imap' => 0,
    ];
}

$ikEmail = trim((string) getenv('FS_MB_IK_EMAIL'));
$ikPass  = fsReadEnvSecret('FS_MB_IK_PASS', 'FS_MB_IK_PASS_B64');
if ($ikEmail !== '' && $ikPass !== '') {
    $definitions[] = [
        'email'                => $ikEmail,
        'name'                 => 'Audyt Katowice',
        'from_name'            => $fromMailboxConst,
        'from_name_custom'     => null,
        'host'                 => 'mail.infomaniak.com',
        'pass'                 => $ikPass,
        'signature'            => '<br>--<br>Audyt Katowice',
        'leave_unread_on_imap' => 0,
    ];
}

$maxbitPass  = fsReadEnvSecret('FS_MB_MAXBIT_PASS', 'FS_MB_MAXBIT_PASS_B64');
$maxbitEmail = trim((string) getenv('FS_MB_MAXBIT_EMAIL'));
if ($maxbitEmail === '') {
    $maxbitEmail = 'krzysztof.poczatek@maxbit.com.pl';
}
if ($maxbitPass !== '') {
    // Kafelek w panelu: "Maxbit (Służbowa)", ale w nagłówku From: "Krzysztof Początek" (FROM_NAME_CUSTOM = 3)
    // oraz ochrona flag \Seen w Outlooku (leave_unread_on_imap = 1 -> BODY.PEEK + deduplikacja po Message-ID)
    $definitions[] = [
        'email'                => $maxbitEmail,
        'name'                 => 'Maxbit (Służbowa)',
        'from_name'            => $fromCustomConst,
        'from_name_custom'     => 'Krzysztof Początek',
        'host'                 => 's190.cyber-folks.pl',
        'pass'                 => $maxbitPass,
        'signature'            => '<br>Pozdrawiam,<br>Krzysztof Początek',
        'leave_unread_on_imap' => 1,
    ];
}

$colList = \Illuminate\Support\Facades\Schema::getColumnListing('mailboxes');
$colMap = array_flip($colList);

$adminUser = \App\User::orderBy('id', 'asc')->first();
$adminId = $adminUser ? (int) $adminUser->id : 1;

$configured = [];

foreach ($definitions as $cfg) {
    /** @var \App\Mailbox $m */
    $m = \App\Mailbox::where('email', $cfg['email'])->first();
    $mode = 'updated';
    if (!$m) {
        $m = new \App\Mailbox();
        $m->email = $cfg['email'];
        $mode = 'created';
    }

    $m->name = $cfg['name'];
    $m->from_name = $cfg['from_name'];
    if (isset($colMap['from_name_custom'])) {
        $m->from_name_custom = $cfg['from_name_custom'];
    }
    $m->signature = $cfg['signature'];

    // Przychodząca poczta IMAP4_SSL (port 993, ścisła walidacja certyfikatu TLS)
    $m->in_protocol = defined('\App\Mailbox::IN_PROTOCOL_IMAP') ? \App\Mailbox::IN_PROTOCOL_IMAP : 1;
    $m->in_server = $cfg['host'];
    $m->in_port = 993;
    $m->in_encryption = defined('\App\Mailbox::IN_ENCRYPTION_SSL') ? \App\Mailbox::IN_ENCRYPTION_SSL : 2;
    $m->in_validate_cert = 1;
    $m->in_username = $cfg['email'];
    $m->in_password = $cfg['pass'];
    if (method_exists($m, 'setInImapFolders')) {
        $m->setInImapFolders(['INBOX']);
    }

    // Wychodząca poczta SMTPS (port 465 SSL)
    $m->out_method = defined('\App\Mailbox::OUT_METHOD_SMTP') ? \App\Mailbox::OUT_METHOD_SMTP : 3;
    $m->out_server = $cfg['host'];
    $m->out_port = 465;
    $m->out_encryption = defined('\App\Mailbox::OUT_ENCRYPTION_SSL') ? \App\Mailbox::OUT_ENCRYPTION_SSL : 2;
    if (isset($colMap['out_auth'])) {
        $m->out_auth = 1;
    }
    $m->out_username = $cfg['email'];
    $m->out_password = $cfg['pass'];

    // Wyłączenie auto-respondera i ocen satysfakcji (OPSEC & czysta korespondencja)
    if (isset($colMap['auto_reply_enabled']) || method_exists($m, 'setAutoReplyEnabledAttribute')) {
        $m->auto_reply_enabled = 0;
    } elseif (isset($colMap['auto_reply'])) {
        $m->auto_reply = defined('\App\Mailbox::AUTO_REPLY_DISABLED') ? \App\Mailbox::AUTO_REPLY_DISABLED : 1;
    }

    if (isset($colMap['ratings']) || method_exists($m, 'setRatingsAttribute')) {
        $m->ratings = 0;
    }

    $activeState = defined('\App\Mailbox::STATE_ACTIVE') ? \App\Mailbox::STATE_ACTIVE : 1;
    if (method_exists($m, 'setMeta')) {
        $m->setMeta('st', $activeState);
        if (!empty($cfg['leave_unread_on_imap'])) {
            $m->setMeta('leave_unread_on_imap', 1);
        } else {
            $m->setMeta('leave_unread_on_imap', 0);
        }
    }

    $m->save();

    $m->users()->syncWithoutDetaching([
        $adminId => [
            'after_send' => 2,
            'hide'       => 0,
            'mute'       => 0,
        ],
    ]);

    if (method_exists($m, 'syncPersonalFolders')) {
        $m->syncPersonalFolders([$adminId]);
    }

    $configured[] = [
        'id'                   => (int) $m->id,
        'mode'                 => $mode,
        'email'                => $m->email,
        'name'                 => $m->name,
        'imap_host'            => $m->in_server . ':' . $m->in_port,
        'smtp_host'            => $m->out_server . ':' . $m->out_port,
        'from_name'            => (int) $m->from_name,
        'from_name_custom'     => $m->from_name_custom,
        'leave_unread_on_imap' => (int) $m->getMeta('leave_unread_on_imap', 0),
    ];
}

if (class_exists('\Helper') && method_exists('\Helper', 'queueWorkerRestart')) {
    \Helper::queueWorkerRestart();
}

echo json_encode([
    'ok'                       => true,
    'opsec_lockdown'           => [
        'open_tracking'  => (int) \App\Option::get('open_tracking'),
        'email_branding' => (int) \App\Option::get('email_branding'),
    ],
    'imap_leave_unread_module' => $imapLeaveUnreadActive,
    'admin_user_id'            => $adminId,
    'mailboxes'                => $configured,
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . PHP_EOL;
