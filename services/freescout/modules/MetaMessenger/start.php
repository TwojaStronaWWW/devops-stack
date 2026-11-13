<?php

declare(strict_types=1);

require_once __DIR__ . '/autoload.php';

if (!app()->routesAreCached()) {
    require __DIR__ . '/Http/routes.php';
}
