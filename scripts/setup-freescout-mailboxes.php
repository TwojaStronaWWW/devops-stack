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
declare(strict_types=1);

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

// 3. Dedykowane kafelki komunikatorów Social dla Kato Salsa Hub (tryb czatowy, bez IMAP/SMTP)
function fsFindOrCreateCustomer(string $email, string $firstName, string $lastName): \App\Customer
{
    if (class_exists('\App\Email')) {
        $emailRow = \App\Email::where('email', $email)->first();
        if ($emailRow && $emailRow->customer) {
            return $emailRow->customer;
        }
    }
    return \App\Customer::create($email, [
        'first_name' => $firstName,
        'last_name'  => $lastName,
    ]);
}

function fsRefreshMailboxCounters(\App\Mailbox $mb): void
{
    if (method_exists($mb, 'updateFoldersCounters')) {
        $mb->updateFoldersCounters();
    }
    foreach ($mb->folders()->get() as $folder) {
        if (method_exists($folder, 'updateCountersNow')) {
            $folder->updateCountersNow();
        }
    }
}

$chatDefinitions = [
    [
        'key'   => 'messenger_ig',
        'email' => 'messenger@katosalsahub.pl',
        'name'  => 'Kato Salsa Hub (Messenger & IG)',
    ],
    [
        'key'   => 'whatsapp',
        'email' => 'whatsapp@katosalsahub.pl',
        'name'  => 'Kato Salsa Hub (WhatsApp)',
    ],
];

$chatMailboxes = [];
$socialConfigured = [];

foreach ($chatDefinitions as $chatCfg) {
    /** @var \App\Mailbox $cm */
    $cm = \App\Mailbox::where('email', $chatCfg['email'])->first();
    $cMode = 'updated';
    if (!$cm) {
        $cm = new \App\Mailbox();
        $cm->email = $chatCfg['email'];
        $cMode = 'created';
    }

    $cm->name = $chatCfg['name'];
    $cm->from_name = $fromMailboxConst;
    if (isset($colMap['from_name_custom'])) {
        $cm->from_name_custom = null;
    }
    $cm->signature = '';

    // Tryb czatowy: pusty in_server wyłącza cykliczny pobór IMAP (zero błędów połączenia)
    $cm->in_server = '';
    $cm->in_username = '';
    $cm->in_password = '';
    $cm->out_method = defined('\App\Mailbox::OUT_METHOD_PHP_MAIL') ? \App\Mailbox::OUT_METHOD_PHP_MAIL : 1;
    $cm->out_server = '';
    $cm->out_username = '';
    $cm->out_password = '';

    if (isset($colMap['ticket_status']) && defined('\App\Mailbox::TICKET_STATUS_PENDING')) {
        $cm->ticket_status = \App\Mailbox::TICKET_STATUS_PENDING;
    }
    if (isset($colMap['ticket_assignee']) && defined('\App\Mailbox::TICKET_ASSIGNEE_REPLYING_UNASSIGNED')) {
        $cm->ticket_assignee = \App\Mailbox::TICKET_ASSIGNEE_REPLYING_UNASSIGNED;
    }
    if (isset($colMap['auto_reply_enabled']) || method_exists($cm, 'setAutoReplyEnabledAttribute')) {
        $cm->auto_reply_enabled = 0;
    } elseif (isset($colMap['auto_reply'])) {
        $cm->auto_reply = defined('\App\Mailbox::AUTO_REPLY_DISABLED') ? \App\Mailbox::AUTO_REPLY_DISABLED : 1;
    }
    if (isset($colMap['ratings']) || method_exists($cm, 'setRatingsAttribute')) {
        $cm->ratings = 0;
    }

    $activeState = defined('\App\Mailbox::STATE_ACTIVE') ? \App\Mailbox::STATE_ACTIVE : 1;
    if (method_exists($cm, 'setMeta')) {
        $cm->setMeta('st', $activeState);
        $cm->setMeta('chat_only_tile', 1);
    }

    $cm->save();

    $cm->users()->syncWithoutDetaching([
        $adminId => [
            'after_send' => 2,
            'hide'       => 0,
            'mute'       => 0,
        ],
    ]);
    if (method_exists($cm, 'syncPersonalFolders')) {
        $cm->syncPersonalFolders([$adminId]);
    }

    $chatMailboxes[$chatCfg['key']] = $cm;
    $socialConfigured[] = [
        'id'             => (int) $cm->id,
        'mode'           => $cMode,
        'email'          => $cm->email,
        'name'           => $cm->name,
        'chat_only_tile' => (int) $cm->getMeta('chat_only_tile', 0),
    ];
}

$mailboxesToRefresh = [];

// 3a. Karta instruktażowa w kafelku "Kato Salsa Hub (Messenger & IG)"
if (isset($chatMailboxes['messenger_ig'])) {
    $msgMb = $chatMailboxes['messenger_ig'];
    $mailboxesToRefresh[$msgMb->id] = $msgMb;

    $msgSubject = '[KONFIGURACJA] Podpięcie Fanpage fb.com/KatoSalsaHub oraz Instagram @katosalsahub';
    $msgConv = \App\Conversation::where('subject', $msgSubject)->first();

    if (!$msgConv) {
        $msgCustomer = fsFindOrCreateCustomer('messenger@katosalsahub.pl', 'Kato Salsa Hub', '— Messenger & IG');
        $msgBodyHtml = <<<'HTML'
<div>
  <h3>Instrukcja podpięcia Facebook Messenger (fb.com/KatoSalsaHub) oraz Instagram DM (@katosalsahub)</h3>
  <ol>
    <li>
      <strong>Aplikacja w Meta for Developers:</strong><br>
      Wejdź na <a href="https://developers.facebook.com/apps/" target="_blank" rel="noopener noreferrer">developers.facebook.com/apps</a>, utwórz lub wybierz aplikację typu <em>Business</em> dla portfolio <strong>Kato Salsa Hub</strong>, dodaj produkty <strong>Messenger</strong> oraz <strong>Instagram</strong>, a z zakładki <em>App Settings &rarr; Basic</em> skopiuj <code>App ID</code> oraz <code>App Secret</code>.
    </li>
    <li>
      <strong>Token Fanpage'a (Page Access Token) i Page ID:</strong><br>
      W ustawieniach produktu <em>Messenger &rarr; API Setup</em> połącz stronę <code>fb.com/KatoSalsaHub</code>, wygeneruj bezterminowy <code>Page Access Token</code> (uprawnienia: <code>pages_messaging</code>, <code>pages_manage_metadata</code>, <code>instagram_basic</code>, <code>instagram_manage_messages</code>) i skopiuj numeryczne <code>Facebook Page ID</code>.
    </li>
    <li>
      <strong>Zapis poświadczeń we FreeScoucie (AES-256):</strong><br>
      W górnym menu kliknij <strong>Zarządzaj (Manage) &rarr; <a href="/meta-messenger/settings">Meta Messenger &amp; IG</a> &rarr; Dodaj konto Fanpage / IG</strong>, jako docelową skrzynkę wybierz <code>Kato Salsa Hub (Messenger &amp; IG)</code>, wklej <code>Facebook Page ID</code>, <code>Meta App ID</code>, <code>Meta App Secret</code> oraz <code>Page Access Token</code>, zapisz i skopiuj wygenerowany <code>Verify Token</code>.
    </li>
    <li>
      <strong>Aktywacja Webhooka i test połączenia:</strong><br>
      W Meta for Developers w sekcji <em>Webhooks</em> (dla obiektów <code>Page</code> oraz <code>Instagram</code>) wklej Callback URL: <code>https://poczta.twojastronawww.pl/meta-messenger/webhook</code> oraz <code>Verify Token</code> i zasubskrybuj pole <code>messages</code> (oraz <code>messaging_postbacks</code>). Następnie kliknij we FreeScoucie przycisk <strong>Testuj połączenie</strong> (automatycznie wykryje też połączone konto <code>@katosalsahub</code>) i zamknij tę kartę statusem <strong>Closed</strong>.
    </li>
  </ol>
</div>
HTML;

        $createdRes = \App\Conversation::create([
            'type'        => \App\Conversation::TYPE_CUSTOM,
            'subject'     => $msgSubject,
            'mailbox_id'  => $msgMb->id,
            'source_via'  => \App\Conversation::PERSON_USER,
            'source_type' => defined('\App\Conversation::SOURCE_TYPE_WEB') ? \App\Conversation::SOURCE_TYPE_WEB : 2,
            'state'       => \App\Conversation::STATE_PUBLISHED,
            'status'      => \App\Conversation::STATUS_ACTIVE,
            'user_id'     => $adminId,
        ], [[
            'type'               => \App\Thread::TYPE_NOTE,
            'body'               => $msgBodyHtml,
            'state'              => \App\Thread::STATE_PUBLISHED,
            'status'             => \App\Conversation::STATUS_ACTIVE,
            'created_by_user_id' => $adminId,
            'source_via'         => \App\Conversation::PERSON_USER,
        ]], $msgCustomer);

        if (is_array($createdRes) && !empty($createdRes['conversation'])) {
            /** @var \App\Conversation $newMsgConv */
            $newMsgConv = $createdRes['conversation'];
            $newMsgConv->status = \App\Conversation::STATUS_ACTIVE;
            $newMsgConv->user_id = $adminId;
            $newMsgConv->updateFolder($msgMb);
            $newMsgConv->save();
            if ($adminUser) {
                $newMsgConv->star($adminUser);
            }
        }
    } elseif ((int) $msgConv->mailbox_id !== (int) $msgMb->id) {
        $prevMb = \App\Mailbox::find($msgConv->mailbox_id);
        if ($prevMb) {
            $mailboxesToRefresh[$prevMb->id] = $prevMb;
        }
        if ($adminUser) {
            $msgConv->unstar($adminUser);
        }
        $msgConv->mailbox_id = $msgMb->id;
        $msgConv->load('mailbox');
        $msgConv->updateFolder($msgMb);
        $msgConv->save();
        if ($adminUser && (int) $msgConv->status === \App\Conversation::STATUS_ACTIVE) {
            $msgConv->star($adminUser);
        }
    }
}

// 3b. Przeniesienie / utrzymanie zadania eSIM w kafelku "Kato Salsa Hub (WhatsApp)"
if (isset($chatMailboxes['whatsapp'])) {
    $waMb = $chatMailboxes['whatsapp'];
    $mailboxesToRefresh[$waMb->id] = $waMb;

    $waSubject = '[ZADANIE] Dokupić eSIM (~5 zł/rok) pod WhatsApp Business Kato Salsa Hub';
    $waConv = \App\Conversation::where('subject', $waSubject)->first();

    if (!$waConv) {
        $waCustomer = fsFindOrCreateCustomer('whatsapp@katosalsahub.pl', 'Kato Salsa Hub', '— WhatsApp Business');
        $waBodyHtml = <<<'HTML'
<div>
  <p>
    <strong>⚠️ OSTRZEŻENIE:</strong> Obecnie na Fanpage'u <code>KatoSalsaHub</code> podpięty jest prywatny numer WhatsApp!
    <strong>NIE dodawaj prywatnego numeru do Meta WhatsApp Cloud API</strong> (wypięłoby to prywatną aplikację WhatsApp z telefonu!).
    Gdy dokupisz nowy starter/eSIM fundacyjny (~5–15 zł/rok), najpierw podmień numer WhatsApp na Fanpage'u <code>KatoSalsaHub</code> na nowy numer eSIM (dodatkowy plus OPSEC: ukryjesz swój prywatny numer telefonu na publicznym FB!) i dopiero ten nowy numer podepnij w <code>Meta WhatsApp</code>.
  </p>
  <h3>Instrukcja wdrożenia WhatsApp Business dla Fundacji Kato Salsa Hub</h3>
  <ol>
    <li>
      <strong>Karta eSIM pod dedykowany numer fundacji:</strong><br>
      Kupić najtańszy starter / <strong>eSIM z roczną ważnością konta (~5–15 zł/rok)</strong> wyłącznie pod oficjalnego WhatsAppa Fundacji Kato Salsa Hub <em>(aby nie wypinać prywatnego WhatsAppa z telefonu)</em>, a następnie podmienić numer WhatsApp na Fanpage'u <code>KatoSalsaHub</code> z prywatnego na nowy numer eSIM.
    </li>
    <li>
      <strong>Konfiguracja w Meta Business Suite:</strong><br>
      Wejść na <a href="https://business.facebook.com" target="_blank" rel="noopener noreferrer">business.facebook.com</a> &rarr; <em>Konta WhatsApp</em>, przypiąć nowy numer pod portfolio biznesowe <strong>Kato Salsa Hub</strong> oraz skopiować <code>Phone Number ID</code> i <code>WABA ID</code>.
    </li>
    <li>
      <strong>Podpięcie we FreeScoucie:</strong><br>
      Wkleić identyfikatory w zakładce <strong>Zarządzaj (Manage) &rarr; <a href="/meta-whatsapp/settings">Meta WhatsApp</a></strong> (wskazując ten kafelek <code>Kato Salsa Hub (WhatsApp)</code> oraz webhook <code>https://poczta.twojastronawww.pl/meta-whatsapp/webhook</code>), przetestować wiadomość i zamknąć zadanie statusem <strong>Closed</strong>.
    </li>
  </ol>
</div>
HTML;

        $createdWa = \App\Conversation::create([
            'type'        => \App\Conversation::TYPE_CUSTOM,
            'subject'     => $waSubject,
            'mailbox_id'  => $waMb->id,
            'source_via'  => \App\Conversation::PERSON_USER,
            'source_type' => defined('\App\Conversation::SOURCE_TYPE_WEB') ? \App\Conversation::SOURCE_TYPE_WEB : 2,
            'state'       => \App\Conversation::STATE_PUBLISHED,
            'status'      => \App\Conversation::STATUS_ACTIVE,
            'user_id'     => $adminId,
        ], [[
            'type'               => \App\Thread::TYPE_NOTE,
            'body'               => $waBodyHtml,
            'state'              => \App\Thread::STATE_PUBLISHED,
            'status'             => \App\Conversation::STATUS_ACTIVE,
            'created_by_user_id' => $adminId,
            'source_via'         => \App\Conversation::PERSON_USER,
        ]], $waCustomer);

        if (is_array($createdWa) && !empty($createdWa['conversation'])) {
            /** @var \App\Conversation $newWaConv */
            $newWaConv = $createdWa['conversation'];
            $newWaConv->status = \App\Conversation::STATUS_ACTIVE;
            $newWaConv->user_id = $adminId;
            $newWaConv->updateFolder($waMb);
            $newWaConv->save();
            if ($adminUser) {
                $newWaConv->star($adminUser);
            }
        }
    } elseif ((int) $waConv->mailbox_id !== (int) $waMb->id) {
        $prevWaMb = \App\Mailbox::find($waConv->mailbox_id);
        if ($prevWaMb) {
            $mailboxesToRefresh[$prevWaMb->id] = $prevWaMb;
        }
        if ($adminUser) {
            $waConv->unstar($adminUser);
        }
        $waConv->mailbox_id = $waMb->id;
        $waConv->load('mailbox');
        $waConv->updateFolder($waMb);
        $waConv->save();
        if ($adminUser && (int) $waConv->status === \App\Conversation::STATUS_ACTIVE) {
            $waConv->star($adminUser);
        }
    }
}

foreach ($mailboxesToRefresh as $refreshMb) {
    fsRefreshMailboxCounters($refreshMb);
}

if (class_exists('\Illuminate\Support\Facades\Artisan')) {
    \Illuminate\Support\Facades\Artisan::call('freescout:clear-cache');
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
    'social_tiles'             => $socialConfigured,
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . PHP_EOL;
