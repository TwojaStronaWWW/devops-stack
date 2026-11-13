<?php

declare(strict_types=1);

return [
    'name'                => 'MetaMessenger',
    'graph_api_version'   => 'v21.0',
    'graph_api_base'      => 'https://graph.facebook.com',
    'webhook_max_bytes'   => 262144, // 256 KiB DoS guard
    'attachment_max_mb'   => 25,
    'allowed_cdn_domains' => [
        'fbcdn.net',
        'fbsbx.com',
        'lookaside.fbsbx.com',
        'cdninstagram.com',
    ],
];
