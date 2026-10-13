#!/usr/bin/env bash
# ==============================================================================
# 01-harden-os.sh
# Hardening systemu operacyjnego Ubuntu (ISO 27001 / CIS Benchmark baseline)
# ==============================================================================
set -euo pipefail

echo "==> [1/6] Weryfikacja uprawnień wykonawczych..."
if [[ "${EUID}" -ne 0 ]]; then
    echo "BŁĄD: Skrypt musi zostać uruchomiony z uprawnieniami roota (np. sudo bash $0)" >&2
    exit 1
fi

TARGET_USER="${SUDO_USER:-ubuntu}"
echo "Konfiguracja stosowana dla użytkownika: ${TARGET_USER}"

echo "==> [2/6] Weryfikacja obecności kluczy SSH..."
USER_AUTH_KEYS="/home/${TARGET_USER}/.ssh/authorized_keys"
if [[ ! -f "${USER_AUTH_KEYS}" ]] || [[ ! -s "${USER_AUTH_KEYS}" ]]; then
    echo "OSTRZEŻENIE: Brak kluczy w ${USER_AUTH_KEYS}!" >&2
    echo "Aby uniknąć zablokowania dostępu (lock-out), upewnij się że posiadasz aktywny klucz Ed25519 przed wyłączeniem haseł."
    read -p "Czy na pewno chcesz kontynuować? (tak/NIE): " CONFIRM
    if [[ "${CONFIRM}" != "tak" ]]; then
        echo "Przerwano przez administratora."
        exit 1
    fi
fi

echo "==> [3/6] Aktualizacja pakietów i instalacja narzędzi ochrony..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y ufw fail2ban unattended-upgrades curl umask-

echo "==> [4/6] Konfiguracja SSH (sshd_config.d)..."
SSH_HARDEN_CONF="/etc/ssh/sshd_config.d/99-security-hardening.conf"
cat << 'EOF' > "${SSH_HARDEN_CONF}"
# Security Hardening (ISO 27001)
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

systemctl reload ssh || systemctl reload sshd || echo "Przeładowanie SSH wymaga restartu usługi."

echo "==> [5/6] Konfiguracja zapory sieciowej UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Port SSH (jeśli używasz innego, zmień przed uruchomieniem)
ufw allow 22/tcp comment 'SSH Access'

# Porty webowe (tylko w przypadku wystawiania Reverse Proxy bezpośrednio)
# W modelu Zero Trust / Cloudflare Tunnels porty 80 i 443 NIE muszą być otwierane.
# ufw allow 80/tcp comment 'HTTP'
# ufw allow 443/tcp comment 'HTTPS'

ufw --force enable
ufw status verbose

echo "==> [6/6] Konfiguracja Fail2Ban & Unattended Upgrades..."
cat << 'EOF' > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ssh
mode    = aggressive
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban

# Automatyczne aktualizacje bezpieczeństwa
dpkg-reconfigure -f noninteractive -p low unattended-upgrades

echo "==> [SUKCES] Hardening systemu zakończony pomyślnie."
