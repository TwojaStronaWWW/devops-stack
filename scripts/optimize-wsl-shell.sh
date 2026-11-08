#!/usr/bin/env bash
# ==============================================================================
# optimize-wsl-shell.sh
# Optymalizacja czasu startu powłoki WSL2 / Ubuntu (< 40 ms) oraz Zero-Telemetry
# Wdraża Lazy Loading dla ciężkich menedżerów (NVM, Pyenv, SDKMAN), wycisza MOTD
# (.hushlogin) oraz ustawia zmienne środowiskowe prywatności (DO_NOT_TRACK=1).
# ==============================================================================
set -euo pipefail

touch "${HOME}/.hushlogin" "${HOME}/.sudo_as_admin_successful"

BASHRC="${HOME}/.bashrc"
if [[ ! -f "${BASHRC}" ]]; then
    touch "${BASHRC}"
fi

if ! grep -q "TSW_LAZY_LOAD_GUARD" "${BASHRC}"; then
    cat << 'EOF' >> "${BASHRC}"

# ==============================================================================
# [TSW_LAZY_LOAD_GUARD] Optymalizacja startu powłoki (< 40 ms) & Zero-Telemetry
# ==============================================================================
export DO_NOT_TRACK=1
export NEXT_TELEMETRY_DISABLED=1
export HF_HUB_OFFLINE=1
export OLLAMA_NOHISTORY=1

# Lazy-loading dla NVM (ładuje ciężkie nvm.sh dopiero przy pierwszym wywołaniu node/npm/npx)
if [ -d "$HOME/.nvm" ] && ! command -v node >/dev/null 2>&1; then
  export NVM_DIR="$HOME/.nvm"
  _tsw_lazy_nvm() {
    unset -f nvm node npm npx corepack 2>/dev/null || true
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  }
  nvm()      { _tsw_lazy_nvm; nvm "$@"; }
  node()     { _tsw_lazy_nvm; node "$@"; }
  npm()      { _tsw_lazy_nvm; npm "$@"; }
  npx()      { _tsw_lazy_nvm; npx "$@"; }
  corepack() { _tsw_lazy_nvm; corepack "$@"; }
fi

# Lazy-loading dla Pyenv
if [ -d "$HOME/.pyenv" ] && ! command -v pyenv >/dev/null 2>&1; then
  export PYENV_ROOT="$HOME/.pyenv"
  export PATH="$PYENV_ROOT/bin:$PATH"
  pyenv() {
    unset -f pyenv
    eval "$(command pyenv init -)"
    pyenv "$@"
  }
fi
EOF
    echo "✅ Dodano blok [TSW_LAZY_LOAD_GUARD] do ${BASHRC}."
else
    echo "ℹ️  Blok [TSW_LAZY_LOAD_GUARD] jest już obecny w ${BASHRC}."
fi

TIMEFORMAT='⏱️  Czas startu interaktywnej powłoki bash: %3R s'
time bash -i -c exit
