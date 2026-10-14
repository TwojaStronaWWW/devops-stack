#!/usr/bin/env bash
# ==============================================================================
# scripts/oracle-arm-hunter.sh
# Automatyczny łowca darmowej instancji Oracle Cloud ARM (VM.Standard.A1.Flex)
# ==============================================================================
# Rozwiązuje problem "Out of host capacity" w regionach o wysokim obłożeniu (np. eu-paris-1).
# Działa w pętli z losowym opóźnieniem (anti-rate-limit), a po utworzeniu maszyny
# wysyła natychmiastowe powiadomienie push na telefon przez Ntfy.
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/oracle-hunter.env"

# Domyślne wartości
DISPLAY_NAME="${DISPLAY_NAME:-vps-oracle-arm-prod}"
OCPUS="${OCPUS:-4}"
MEMORY_IN_GBS="${MEMORY_IN_GBS:-24}"
BOOT_VOLUME_SIZE_IN_GBS="${BOOT_VOLUME_SIZE_IN_GBS:-100}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-60}"
NTFY_TOPIC="${NTFY_TOPIC:-kpoczatek-vps-alerty}"
SSH_AUTHORIZED_KEY_PATH="${SSH_AUTHORIZED_KEY_PATH:-/mnt/c/Users/pocza/.ssh/id_ed25519.pub}"
COMPARTMENT_OCID="${COMPARTMENT_OCID:-}"
AVAILABILITY_DOMAIN="${AVAILABILITY_DOMAIN:-}"
SUBNET_OCID="${SUBNET_OCID:-}"
IMAGE_OCID="${IMAGE_OCID:-}"

# Wczytaj plik konfiguracyjny jeśli istnieje
if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
fi

# ==============================================================================
# Pomoc i diagnostyka
# ==============================================================================
print_help() {
    cat <<EOF
Użycie: $0 [OPCJA]

Opcje:
  --discover     Wykryj automatycznie Twoje identyfikatory OCID (AD, VCN Subnet, Ubuntu Image) i zapisz w oracle-hunter.env
  --test-notify  Wyślij testowe powiadomienie push do Ntfy (https://ntfy.sh/${NTFY_TOPIC})
  --help         Wyświetl tę pomoc

Zmienne środowiskowe lub plik scripts/oracle-hunter.env:
  COMPARTMENT_OCID          OCID przedziału (tenancy lub compartment)
  AVAILABILITY_DOMAIN       Nazwa domeny dostępności (np. gXgC:EU-PARIS-1-AD-1)
  SUBNET_OCID               OCID podsieci publicznej w Twojej sieci VCN
  IMAGE_OCID                OCID oficjalnego obrazu Ubuntu Canonical ARM64
  SSH_AUTHORIZED_KEY_PATH   Ścieżka do klucza publicznego (domyślnie: /mnt/c/Users/pocza/.ssh/id_ed25519.pub)
  NTFY_TOPIC                Kanał w Ntfy do powiadomień (domyślnie: kpoczatek-vps-alerty)
  POLL_INTERVAL_SECONDS     Czas oczekiwania między próbami (domyślnie: 60)
EOF
    exit 0
}

# ==============================================================================
# Weryfikacja zależności
# ==============================================================================
check_prerequisites() {
    if ! command -v oci &>/dev/null; then
        echo "======================================================================"
        echo "❌ BŁĄD: Narzędzie OCI CLI nie jest zainstalowane w Twoim środowisku!"
        echo "======================================================================"
        echo "Aby zainstalować OCI CLI w WSL2, wykonaj w terminalu:"
        echo '  bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults'
        echo "Następnie zrestartuj terminal lub uruchom: exec -l \$SHELL"
        echo "======================================================================"
        exit 1
    fi

    if [[ ! -f "${HOME}/.oci/config" ]]; then
        echo "======================================================================"
        echo "❌ BŁĄD: Brak pliku konfiguracyjnego OCI (~/.oci/config)!"
        echo "======================================================================"
        echo "1. Wejdź w konsolę Oracle Cloud -> Profil -> User Settings -> API keys"
        echo "2. Kliknij 'Add API key', pobierz klucz prywatny .pem i kliknij 'Add'"
        echo "3. Skopiuj wygenerowaną treść konfiguracji do pliku: ~/.oci/config"
        echo "======================================================================"
        exit 1
    fi

    # Sprawdzenie klucza SSH
    if [[ ! -f "${SSH_AUTHORIZED_KEY_PATH}" ]]; then
        if [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
            SSH_AUTHORIZED_KEY_PATH="${HOME}/.ssh/id_ed25519.pub"
        elif [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
            SSH_AUTHORIZED_KEY_PATH="${HOME}/.ssh/id_rsa.pub"
        else
            echo "❌ BŁĄD: Nie znaleziono publicznego klucza SSH pod ścieżką: ${SSH_AUTHORIZED_KEY_PATH}"
            echo "Upewnij się, że klucz istnieje lub wygeneruj nowy: ssh-keygen -t ed25519"
            exit 1
        fi
    fi
}

# ==============================================================================
# Powiadomienia Ntfy
# ==============================================================================
send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-high}"
    local tags="${4:-tada,cloud}"

    if [[ -n "${NTFY_TOPIC}" ]] && command -v curl &>/dev/null; then
        curl -s \
            -H "Title: ${title}" \
            -H "Priority: ${priority}" \
            -H "Tags: ${tags}" \
            -d "${message}" \
            "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null 2>&1 || true
    fi
}

# ==============================================================================
# Tryb automatycznego wykrywania zasobów OCI (--discover)
# ==============================================================================
discover_resources() {
    check_prerequisites
    echo "🔍 [OCI Discovery] Odpytywanie API Oracle Cloud o konfigurację konta..."

    # 1. Pobierz Tenancy OCID z ~/.oci/config
    local tenancy_id
    tenancy_id="$(grep -E '^tenancy=' "${HOME}/.oci/config" | head -n1 | cut -d= -f2 | tr -d ' \r\n')"
    if [[ -z "${tenancy_id}" ]]; then
        echo "❌ Nie udało się odczytać tenancy z ~/.oci/config"
        exit 1
    fi
    echo "  ✔ Tenancy / Compartment: ${tenancy_id}"

    # 2. Pobierz Availability Domain
    echo "  ⏳ Pobieranie domen dostępności (Availability Domains)..."
    local ad
    ad="$(oci iam availability-domain list --query 'data[0].name' --raw-output 2>/dev/null || true)"
    if [[ -z "${ad}" || "${ad}" == "None" ]]; then
        echo "❌ Błąd pobierania Availability Domain. Sprawdź połączenie z OCI API."
        exit 1
    fi
    echo "  ✔ Wykryto Availability Domain: ${ad}"

    # 3. Pobierz Subnet OCID (tylko publiczną podsieć, zezwalającą na Public IP)
    echo "  ⏳ Wyszukiwanie publicznej podsieci w VCN..."
    local subnet
    subnet="$(oci network subnet list --compartment-id "${tenancy_id}" --query 'data[?"prohibit-public-ip-on-vnic"==`false`].id | [0]' --raw-output 2>/dev/null || true)"
    if [[ -z "${subnet}" || "${subnet}" == "null" || "${subnet}" == "None" ]]; then
        # Fallback do pierwszej podsieci
        subnet="$(oci network subnet list --compartment-id "${tenancy_id}" --query 'data[0].id' --raw-output 2>/dev/null || true)"
    fi

    # 4. Pobierz oficjalny obraz Canonical Ubuntu ARM64
    echo "  ⏳ Wyszukiwanie najnowszego obrazu Canonical Ubuntu ARM (aarch64)..."
    local image
    image="$(oci compute image list \
        --compartment-id "${tenancy_id}" \
        --operating-system "Canonical Ubuntu" \
        --shape "VM.Standard.A1.Flex" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || true)"

    if [[ -z "${image}" || "${image}" == "null" || "${image}" == "None" ]]; then
        echo "⚠️ Nie znaleziono obrazu Ubuntu ARM przez filtr specyficzny dla shape. Wyszukuję ogólne obrazy aarch64..."
        image="$(oci compute image list \
            --compartment-id "${tenancy_id}" \
            --operating-system "Canonical Ubuntu" \
            --sort-by TIMECREATED \
            --sort-order DESC \
            --query 'data[?contains("display-name", `aarch64`)].id | [0]' \
            --raw-output 2>/dev/null || true)"
    fi
    echo "  ✔ Wykryto Image OCID: ${image}"

    # Zapisz do pliku scripts/oracle-hunter.env
    cat > "${CONFIG_FILE}" <<EOF
# Wygenerowano automatycznie: $(date '+%Y-%m-%d %H:%M:%S')
DISPLAY_NAME="${DISPLAY_NAME}"
COMPARTMENT_OCID="${tenancy_id}"
AVAILABILITY_DOMAIN="${ad}"
SUBNET_OCID="${subnet}"
IMAGE_OCID="${image}"
OCPUS=${OCPUS}
MEMORY_IN_GBS=${MEMORY_IN_GBS}
BOOT_VOLUME_SIZE_IN_GBS=${BOOT_VOLUME_SIZE_IN_GBS}
SSH_AUTHORIZED_KEY_PATH="${SSH_AUTHORIZED_KEY_PATH}"
NTFY_TOPIC="${NTFY_TOPIC}"
POLL_INTERVAL_SECONDS=${POLL_INTERVAL_SECONDS}
EOF

    echo "======================================================================"
    echo "✅ Konfiguracja zapisana pomyślnie w pliku: ${CONFIG_FILE}"
    echo "Możesz teraz uruchomić łowcę poleceniem: ./scripts/oracle-arm-hunter.sh"
    echo "======================================================================"
    exit 0
}

# ==============================================================================
# Obsługa flag
# ==============================================================================
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    print_help
elif [[ "${1:-}" == "--discover" ]]; then
    discover_resources
elif [[ "${1:-}" == "--test-notify" ]]; then
    echo "Wysyłanie testowego alertu na telefon do https://ntfy.sh/${NTFY_TOPIC}..."
    send_notification "Test Oracle Hunter" "To jest testowe powiadomienie z Twojego skryptu Oracle ARM Hunter!" "default" "bell,cloud"
    echo "Wysłano pomyślnie!"
    exit 0
fi

# ==============================================================================
# Główna pętla polowania (Hunting Loop)
# ==============================================================================
check_prerequisites

# Jeśli brakuje kluczowych OCID, zaproponuj uruchomienie --discover
if [[ -z "${COMPARTMENT_OCID}" || -z "${AVAILABILITY_DOMAIN}" || -z "${SUBNET_OCID}" || -z "${IMAGE_OCID}" ]]; then
    echo "ℹ️ Wykryto brakujące identyfikatory OCID. Uruchamiam automatyczną detekcję (--discover)..."
    discover_resources
fi

echo "======================================================================"
echo "🎯 START: Oracle Cloud ARM Instance Hunter (VM.Standard.A1.Flex)"
echo "======================================================================"
echo "Parametry docelowej maszyny:"
echo "  • Nazwa:             ${DISPLAY_NAME}"
echo "  • Konfiguracja:      ${OCPUS} OCPU | ${MEMORY_IN_GBS} GB RAM | ${BOOT_VOLUME_SIZE_IN_GBS} GB Dysk"
echo "  • Region / AD:       ${AVAILABILITY_DOMAIN}"
echo "  • Obraz systemu:     ${IMAGE_OCID}"
echo "  • Podsieć VCN:       ${SUBNET_OCID}"
echo "  • Klucz SSH:         ${SSH_AUTHORIZED_KEY_PATH}"
echo "  • Kanał Ntfy:        https://ntfy.sh/${NTFY_TOPIC}"
echo "  • Interwał bazowy:   ${POLL_INTERVAL_SECONDS}s"
echo "======================================================================"
echo "Wciśnij [Ctrl + C], aby zatrzymać skrypt w dowolnym momencie."
echo ""

ATTEMPT=1
START_TIME=$(date +%s)

while true; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo -n "[${TIMESTAMP}] Próba #${ATTEMPT}: Wysyłanie żądania do API Oracle... "

    # Wywołanie API OCI CLI
    OUTPUT=$(oci compute instance launch \
        --availability-domain "${AVAILABILITY_DOMAIN}" \
        --compartment-id "${COMPARTMENT_OCID}" \
        --shape "VM.Standard.A1.Flex" \
        --shape-config "{\"ocpus\": ${OCPUS}, \"memoryInGBs\": ${MEMORY_IN_GBS}}" \
        --image-id "${IMAGE_OCID}" \
        --subnet-id "${SUBNET_OCID}" \
        --assign-public-ip true \
        --display-name "${DISPLAY_NAME}" \
        --boot-volume-size-in-gbs "${BOOT_VOLUME_SIZE_IN_GBS}" \
        --ssh-authorized-keys-file "${SSH_AUTHORIZED_KEY_PATH}" 2>&1)
    STATUS=$?

    if [[ ${STATUS} -eq 0 ]]; then
        echo ""
        echo "======================================================================"
        echo "🎉🎉🎉 [SUKCES!] MASZYNA ARM ZOSTAŁA UTWORZONA! 🎉🎉🎉"
        echo "======================================================================"
        
        # Zapisz odpowiedź do pliku json dla audytu
        echo "${OUTPUT}" > "${SCRIPT_DIR}/oracle-instance-created.json"
        
        INSTANCE_ID=$(echo "${OUTPUT}" | grep -o '"id": "[^"]*' | head -n1 | cut -d'"' -f4 || echo "Nieznany")
        echo "Identyfikator instancji (OCID): ${INSTANCE_ID}"
        echo "Szczegóły zostały zapisane w: scripts/oracle-instance-created.json"

        # Wysłanie powiadomienia push na telefon
        send_notification \
            "🎉 Oracle ARM VPS Utworzony!" \
            "Twój darmowy serwer ARM (${OCPUS} OCPU / ${MEMORY_IN_GBS} GB RAM) w Paryżu został pomyślnie utworzony po ${ATTEMPT} próbach! Sprawdź konsolę Oracle." \
            "urgent" \
            "tada,partying_face,rocket"

        echo "Wysłano alert na telefon przez Ntfy: https://ntfy.sh/${NTFY_TOPIC}"
        echo "======================================================================"
        exit 0
    fi

    # Analiza błędu
    if echo "${OUTPUT}" | grep -iq "Out of host capacity"; then
        # Dodajemy losowy jitter (np. 0-10s), aby nie trafić w powtarzalne okna czasowe
        JITTER=$((RANDOM % 11))
        SLEEP_TIME=$((POLL_INTERVAL_SECONDS + JITTER))
        echo "⏳ Brak wolnych procesorów ARM (Out of host capacity). Ponawiam za ${SLEEP_TIME}s..."
    elif echo "${OUTPUT}" | grep -iq "TooManyRequests"; then
        SLEEP_TIME=120
        echo "⚠️ Wykryto limit API (TooManyRequests). Schładzanie połączenia przez ${SLEEP_TIME}s..."
    elif echo "${OUTPUT}" | grep -iq "NotAuthorizedOrNotFound"; then
        echo ""
        echo "❌ BŁĄD AUTORYZACJI LUB ZASOBU: Nieprawidłowy identyfikator OCID lub brak uprawnień."
        echo "${OUTPUT}"
        exit 1
    elif echo "${OUTPUT}" | grep -iq "InvalidParameter"; then
        echo ""
        echo "❌ BŁĄD PARAMETRÓW: Błędny parametr w żądaniu."
        echo "${OUTPUT}"
        exit 1
    else
        JITTER=$((RANDOM % 11))
        SLEEP_TIME=$((POLL_INTERVAL_SECONDS + JITTER))
        echo "⚠️ Nieoczekiwana odpowiedź API. Ponawiam za ${SLEEP_TIME}s..."
        echo "Treść: $(echo "${OUTPUT}" | tr '\n' ' ' | cut -c1-150)..."
    fi

    ATTEMPT=$((ATTEMPT + 1))
    sleep "${SLEEP_TIME}"
done
