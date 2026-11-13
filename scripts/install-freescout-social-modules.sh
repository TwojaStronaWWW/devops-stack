#!/usr/bin/env bash
# ==============================================================================
# install-freescout-social-modules.sh
# Idempotentna instalacja, aktywacja i migracja modułów komunikatorów Social
# we FreeScoucie (MetaMessenger v1.0.0 [FB+IG] + MetaWhatsApp v2.1.0).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
META_MESSENGER_SRC="${STACK_ROOT}/services/freescout/modules/MetaMessenger"
WHATSAPP_REPO_URL="https://github.com/losimo/freescout-meta-whatsapp.git"
WHATSAPP_TAG="v2.1.0"

FORCE_WHATSAPP="0"
if [[ "${1:-}" == "--force-whatsapp" ]]; then
    FORCE_WHATSAPP="1"
fi

if [[ ! -f "${META_MESSENGER_SRC}/module.json" ]]; then
    echo "[BŁĄD] Brak modułu źródłowego w ${META_MESSENGER_SRC}/module.json!" >&2
    exit 1
fi

if ! docker inspect -f '{{.State.Running}}' freescout 2>/dev/null | grep -qx "true"; then
    echo "[BŁĄD] Kontener 'freescout' nie jest uruchomiony!" >&2
    exit 1
fi

echo "[1/4] Instalacja modułu MetaMessenger (Facebook Messenger + Instagram DM) do /data/Modules/MetaMessenger..."
docker exec -u root freescout sh -c 'mkdir -p /data/Modules && rm -rf /data/Modules/MetaMessenger.tmp'
docker cp "${META_MESSENGER_SRC}" freescout:/data/Modules/MetaMessenger.tmp
docker exec -u root freescout sh -c 'rm -rf /data/Modules/MetaMessenger && mv /data/Modules/MetaMessenger.tmp /data/Modules/MetaMessenger'

WA_PRESENT="$(docker exec freescout sh -c 'test -f /data/Modules/MetaWhatsApp/module.json && echo 1 || echo 0')"
if [[ "${WA_PRESENT}" != "1" || "${FORCE_WHATSAPP}" == "1" ]]; then
    echo "[2/4] Pobieranie przypiętego wydania MetaWhatsApp (${WHATSAPP_TAG}) z ${WHATSAPP_REPO_URL}..."
    TMP_WA_DIR="$(mktemp -d)"
    cleanup_tmp() {
        rm -rf "${TMP_WA_DIR}"
    }
    trap cleanup_tmp EXIT

    git clone --quiet --depth 1 --branch "${WHATSAPP_TAG}" "${WHATSAPP_REPO_URL}" "${TMP_WA_DIR}/MetaWhatsApp"
    rm -rf "${TMP_WA_DIR}/MetaWhatsApp/.git"

    docker exec -u root freescout sh -c 'rm -rf /data/Modules/MetaWhatsApp.tmp'
    docker cp "${TMP_WA_DIR}/MetaWhatsApp" freescout:/data/Modules/MetaWhatsApp.tmp
    docker exec -u root freescout sh -c 'rm -rf /data/Modules/MetaWhatsApp && mv /data/Modules/MetaWhatsApp.tmp /data/Modules/MetaWhatsApp'
else
    echo "[2/4] Moduł MetaWhatsApp jest już zainstalowany w /data/Modules/MetaWhatsApp (pominięto klonowanie)."
fi

echo "[3/4] Ustawianie uprawnień właściciela (chown -R 80:82) dla /data/Modules..."
docker exec -u root freescout chown -R 80:82 /data/Modules/MetaMessenger /data/Modules/MetaWhatsApp

echo "[4/4] Aktywacja modułów, migracje bazy MariaDB oraz czyszczenie cache FreeScouta..."
docker exec -i -u nginx freescout sh -s <<'EOS'
set -eu

php -r '
require "/www/html/vendor/autoload.php";
$app = require "/www/html/bootstrap/app.php";
$app->make(\Illuminate\Contracts\Console\Kernel::class)->bootstrap();
if (class_exists("\App\Module")) {
    if (method_exists("\App\Module", "clearModulesCache")) {
        \App\Module::clearModulesCache();
    }
    if (method_exists("\App\Module", "setActive")) {
        \App\Module::setActive("metamessenger", true);
        \App\Module::setActive("metawhatsapp", true);
    }
    if (method_exists("\App\Module", "clearModulesCache")) {
        \App\Module::clearModulesCache();
    }
}
'

php /www/html/artisan freescout:clear-cache
php /www/html/artisan module:enable MetaMessenger
php /www/html/artisan module:migrate MetaMessenger --force
php /www/html/artisan module:enable MetaWhatsApp
php /www/html/artisan module:migrate MetaWhatsApp --force
php /www/html/artisan migrate --force
php /www/html/artisan freescout:clear-cache
php /www/html/artisan queue:restart

php -r '
require "/www/html/vendor/autoload.php";
$app = require "/www/html/bootstrap/app.php";
$app->make(\Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$schema = \Illuminate\Support\Facades\Schema::getFacadeRoot();
echo json_encode([
    "ok" => true,
    "metamessenger_active" => class_exists("\App\Module") ? (bool) \App\Module::isActive("metamessenger") : false,
    "metawhatsapp_active"  => class_exists("\App\Module") ? (bool) \App\Module::isActive("metawhatsapp") : false,
    "meta_messenger_accounts_table" => $schema->hasTable("meta_messenger_accounts"),
    "meta_messenger_messages_table" => $schema->hasTable("meta_messenger_messages"),
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
'
EOS
