#!/usr/bin/env bash
# ==============================================================================
# 02-install-docker.sh
# Oficjalna instalacja silnika Docker Engine & Compose na Ubuntu (ARM64 & AMD64)
# ==============================================================================
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "BŁĄD: Skrypt musi zostać uruchomiony z uprawnieniami roota (np. sudo bash $0)" >&2
    exit 1
fi

TARGET_USER="${1:-${SUDO_USER:-$(getent passwd "1000" | cut -d: -f1 || echo "ubuntu")}}"
ARCH="$(dpkg --print-architecture)"

echo "==> Wykryto architekturę procesora: ${ARCH}"
echo "==> Przygotowanie instalacji dla użytkownika: ${TARGET_USER}"

# 1. Usunięcie nieoficjalnych lub starych pakietów
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# 2. Instalacja zależności
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release

# 3. Dodanie oficjalnego klucza GPG Dockera
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
chmod a+r /etc/apt/keyrings/docker.gpg

# 4. Dodanie oficjalnego repozytorium Apt
echo \
  "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# 5. Instalacja Docker Engine, CLI, Containerd i Compose Plugin
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 6. Konfiguracja log-rotacji w daemon.json (Prewencja zapełnienia dysku - OOM/Disk Full)
mkdir -p /etc/docker
cat << 'EOF' > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

# 7. Start i włączenie usługi
systemctl enable --now docker 2>/dev/null || service docker start 2>/dev/null || true

# 8. Dodanie użytkownika do grupy docker
usermod -aG docker "${TARGET_USER}"

echo "==> [SUKCES] Docker Engine zainstalowany i skonfigurowany pomyślnie."
echo "Wersja Docker: $(docker --version)"
echo "Wersja Compose: $(docker compose version)"
echo "UWAGA: Aby korzystać z Dockera bez sudo, zaloguj się ponownie lub wykonaj: newgrp docker"
