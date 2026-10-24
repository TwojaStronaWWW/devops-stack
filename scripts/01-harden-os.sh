#!/usr/bin/env bash
# ==============================================================================
# 01-harden-os.sh
# Kompleksowy hardening systemu operacyjnego Ubuntu (ISO 27001 / CIS Benchmark baseline)
# Ochrona przed włamaniami, atakami brute-force, skanowaniem oraz exploitami.
# ==============================================================================
set -euo pipefail

echo "======================================================================"
echo ">> [1/8] Weryfikacja uprawnień i środowiska..."
echo "======================================================================"
if [[ "${EUID}" -ne 0 ]]; then
    echo "BŁĄD: Skrypt musi zostać uruchomiony z uprawnieniami roota (np. sudo bash $0)" >&2
    exit 1
fi

TARGET_USER="${1:-${SUDO_USER:-$(getent passwd "1000" | cut -d: -f1 || echo "ubuntu")}}"
echo "Konfiguracja stosowana dla użytkownika: ${TARGET_USER}"

echo "======================================================================"
echo ">> [2/8] Weryfikacja kluczy SSH (Ochrona przed lock-outem)..."
echo "======================================================================"
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

echo "======================================================================"
echo ">> [3/8] Aktualizacja pakietów i instalacja pakietów bezpieczeństwa..."
echo "======================================================================"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y ufw fail2ban unattended-upgrades curl iptables ca-certificates

echo "======================================================================"
echo ">> [4/8] SSH Hardening (ISO 27001 baseline)..."
echo "======================================================================"
# Zablokowanie interaktywnej powłoki odziedziczonego konta opc (Oracle Cloud) oraz usunięcie kluczy roota
usermod -s /usr/sbin/nologin opc 2>/dev/null || true
rm -f /root/.ssh/authorized_keys 2>/dev/null || true

SSH_HARDEN_CONF="/etc/ssh/sshd_config.d/99-security-hardening.conf"
mkdir -p /etc/ssh/sshd_config.d
cat << EOF > "${SSH_HARDEN_CONF}"
# Security Hardening (ISO 27001 / CIS Benchmark)
# 1. Całkowity zakaz logowania na konto root oraz biała lista kont
PermitRootLogin no
AllowUsers ${TARGET_USER}
# 2. Zakaz uwierzytelniania hasłem (wyłącznie klucze kryptograficzne)
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
# 3. Ograniczenie liczby prób autoryzacji przed rozłączeniem i pełny dziennik audytowy
MaxAuthTries 3
LogLevel VERBOSE
# 4. Wyłączenie zbędnych i podatnych funkcji
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

sshd -t && (systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true)

echo "======================================================================"
echo ">> [5/8] Zapora sieciowa UFW (Stateful Firewall & Rate Limiting)..."
echo "======================================================================"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Port SSH z ograniczeniem częstotliwości (Rate Limiting: max 6 połączeń / 30s)
ufw limit 22/tcp comment 'SSH Rate Limited'

# Porty webowe (tylko w przypadku bezpośredniego wystawiania bez tunelu Cloudflare)
# W modelu Zero Trust / Cloudflare Tunnels porty 80 i 443 NIE muszą być otwierane.
# ufw allow 80/tcp comment 'HTTP'
# ufw allow 443/tcp comment 'HTTPS'

# Wyłączenie i zamaskowanie zbędnego demona rpcbind (port 111 TCP/UDP - CIS Benchmark / ISO 27001)
systemctl disable --now rpcbind.service rpcbind.socket 2>/dev/null || true
systemctl mask rpcbind.service rpcbind.socket 2>/dev/null || true

ufw --force enable
ufw status verbose

echo "======================================================================"
echo ">> [6/8] Fail2Ban (Intrusion Prevention System - IPS)..."
echo "======================================================================"
cat << 'EOF' > /etc/fail2ban/jail.local
[DEFAULT]
# Czas blokady agresora: 1 godzina (progresywnie do 7 dni dla recydywistów)
bantime           = 1h
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 7d
# Okno czasowe zliczania prób: 10 minut
findtime          = 10m
# Maksymalna liczba błędów przed banem: 3
maxretry          = 3
banaction         = ufw

[sshd]
enabled = true
port    = ssh
mode    = aggressive
EOF

systemctl enable --now fail2ban 2>/dev/null || service fail2ban restart 2>/dev/null || true

echo "======================================================================"
echo ">> [7/8] Unattended Upgrades (Automatyczne łatki bezpieczeństwa)..."
echo "======================================================================"
cat << 'EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat << 'EOF' > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}:${distro_codename}-updates";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
    "Docker CE:${distro_codename}";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

systemctl enable --now unattended-upgrades 2>/dev/null || true

echo "======================================================================"
echo ">> [8/8] Kernel & Network Hardening (Anti-Spoofing & Anti-DoS)..."
echo "======================================================================"
SYSCTL_CONF="/etc/sysctl.d/99-security-hardening.conf"
cat << 'EOF' > "${SYSCTL_CONF}"
# Ochrona przed zalewaniem pakietami SYN (SYN Flood DoS)
net.ipv4.tcp_syncookies = 1

# Ochrona przed fałszowaniem adresów IP (IP Spoofing - Reverse Path Filtering)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ochrona przed atakami typu Man-In-The-Middle poprzez pakiety ICMP redirect
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Ignorowanie żądań broadcast ping (ochrona przed atakiem Smurf)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Wymagane trasowanie pakietów dla mostka sieciowego Dockera
net.ipv4.ip_forward = 1

# Utwardzenie przestrzeni adresowej i eBPF JIT w jądrze (CIS Benchmark)
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 2
net.core.bpf_jit_harden = 2

# Algorytm kontroli przeciążenia Google TCP BBR (wyższa przepustowość i niższe opóźnienia tunelu Cloudflare i R2)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Zwiększone limity inotify dla 12+ kontenerów Docker i runnerów CI/CD (ochrona przed "inotify watch limit reached")
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# Optymalizacja zarządzania pamięcią wirtualną i Page Cache (dla SQLite FTS5 i TSDB)
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF

modprobe tcp_bbr 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || true

# Ochrona łańcucha DOCKER-USER przed przypadkowym wystawieniem portu kontenera na interfejs WAN
# + Natychmiastowy hook systemd (ExecStartPost) nakładający regułę w 0ms po każdym starcie/restarcie docker.service
cat << 'EOF' > /usr/local/sbin/devops-docker-user-guard.sh
#!/usr/bin/env bash
WAN_IFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
if [[ -n "${WAN_IFACE}" ]] && iptables -L DOCKER-USER -n >/dev/null 2>&1; then
    iptables -D DOCKER-USER -i "${WAN_IFACE}" -j DROP 2>/dev/null || true
    iptables -D DOCKER-USER -i "${WAN_IFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null || true
    iptables -I DOCKER-USER 1 -i "${WAN_IFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null || true
    iptables -I DOCKER-USER 2 -i "${WAN_IFACE}" -j DROP 2>/dev/null || true
fi
EOF
chmod 700 /usr/local/sbin/devops-docker-user-guard.sh

mkdir -p /etc/systemd/system/docker.service.d
cat << 'EOF' > /etc/systemd/system/docker.service.d/10-docker-user-guard.conf
[Service]
ExecStartPost=-/usr/local/sbin/devops-docker-user-guard.sh
EOF
systemctl daemon-reload 2>/dev/null || true
/usr/local/sbin/devops-docker-user-guard.sh 2>/dev/null || true

# Zabezpieczenie pamięci współdzielonej /dev/shm przed uruchamianiem exploitów
if grep -q " /dev/shm " /etc/fstab 2>/dev/null; then
    sed -i 's|.* /dev/shm .*|tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0|' /etc/fstab
else
    echo "tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> /etc/fstab
fi
mount -o remount,noexec,nosuid,nodev /dev/shm 2>/dev/null || true

echo "======================================================================"
echo ">> [9/9] Optymalizacja pamięci SWAP, NTP (ISO 27001 A.8.17) i Journald..."
echo "======================================================================"
# Wymuszenie synchronizacji zegara atomowego NTP (wymóg ISO 27001 A.8.17 / S3 R2 / OAuth2 JWT)
timedatectl set-ntp true 2>/dev/null || true
systemctl enable --now systemd-timesyncd 2>/dev/null || true

TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
CURRENT_SWAP_MB=$(free -m | awk '/^Swap:/{print $2}')

if [[ "${CURRENT_SWAP_MB}" -lt 1024 ]]; then
    echo "Brak aktywnego pliku SWAP (RAM: ${TOTAL_MEM_MB}MB, SWAP: ${CURRENT_SWAP_MB}MB). Konfiguracja 2GB poduszki SWAP..."
    if [[ ! -f /swapfile ]]; then
        fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
        chmod 600 /swapfile
        mkswap /swapfile
    fi
    swapon /swapfile 2>/dev/null || true
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    sysctl vm.swappiness=10 >/dev/null 2>&1 || true
    sysctl vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
    echo ">> Utworzono i aktywowano 2GB SWAP (swappiness=10, vfs_cache_pressure=50)."
else
    echo "Dostępny RAM: ${TOTAL_MEM_MB}MB, SWAP: ${CURRENT_SWAP_MB}MB - poduszka SWAP aktywna."
fi

# Ograniczenie rozmiaru logów systemowych systemd-journald do 200 MB (ochrona dysku 200 GB Always Free)
mkdir -p /etc/systemd/journald.conf.d
cat << 'EOF' > /etc/systemd/journald.conf.d/size-limit.conf
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
MaxRetentionSec=14day
EOF
systemctl restart systemd-journald 2>/dev/null || true

# Automatyczne rozszerzenie partycji root (/dev/sda1, ext4) online do pełnego rozmiaru Boot Volume OCI Always Free (do 200 GB)
if [[ -e /sys/class/block/sda/device/rescan ]]; then
    echo 1 > /sys/class/block/sda/device/rescan 2>/dev/null || true
    partprobe /dev/sda 2>/dev/null || true
    growpart /dev/sda 1 2>/dev/null || true
    resize2fs /dev/sda1 2>/dev/null || true
fi

echo "======================================================================"
echo ">> [SUKCES] Pełny hardening systemu zakończony pomyślnie."
echo "======================================================================"
