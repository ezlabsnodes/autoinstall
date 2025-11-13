#!/bin/bash
set -euo pipefail

USERNAME=$(whoami)
ARCH=$(uname -m)
REQUIRED_NODE_MAJOR=20

function info() {
    echo -e "\033[1;32m[INFO] $1\033[0m"
}

function warn() {
    echo -e "\033[1;33m[WARN] $1\033[0m"
}

function error() {
    echo -e "\033[1;31m[ERROR] $1\033[0m" >&2
    exit 1
}

function install_packages() {
    info "Installing packages: $*"
    sudo apt-get install -y "$@" || {
        error "Failed to install packages: $*"
    }
}

function command_exists() {
    command -v "$1" &> /dev/null
}

info "Checking system architecture..."
if [ "$ARCH" != "x86_64" ]; then
    warn "Non-x86_64 architecture detected ($ARCH), some packages might need adjustment"
fi

if ! sudo -v; then
    error "This script requires sudo privileges"
fi

info "Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get autoremove -y

info "Installing essential build tools..."
install_packages \
    git clang cmake build-essential openssl pkg-config libssl-dev \
    wget htop tmux jq make gcc tar ncdu protobuf-compiler \
    default-jdk aptitude squid apache2-utils file lsof zip unzip \
    iptables iptables-persistent openssh-server sed lz4 aria2 pv \
    python3 python3-venv python3-pip python3-dev screen snapd flatpak \
    nano automake autoconf nvme-cli libgbm-dev libleveldb-dev bsdmainutils unzip \
    ca-certificates curl gnupg lsb-release software-properties-common

info "Checking Node.js installation..."

CURRENT_NODE_MAJOR=0
if command_exists node; then
    CURRENT_NODE=$(node --version)
    CURRENT_NODE_MAJOR=$(echo "$CURRENT_NODE" | sed 's/v//' | cut -d'.' -f1)
    info "Node.js currently installed: $CURRENT_NODE"

    if [ "$CURRENT_NODE_MAJOR" -lt "$REQUIRED_NODE_MAJOR" ]; then
        warn "Node.js version is too old (< $REQUIRED_NODE_MAJOR.x), removing old version..."
        # Hapus Node.js yang diinstall via apt
        sudo apt-get remove -y nodejs || true
        sudo apt-get purge -y nodejs || true

        # Bersihkan kemungkinan instalasi manual
        sudo rm -f /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx || true
        sudo rm -rf /usr/local/lib/node_modules || true

        CURRENT_NODE_MAJOR=0
    else
        info "Existing Node.js version already >= $REQUIRED_NODE_MAJOR.x, keeping it."
    fi
fi

if ! command_exists node || [ "$CURRENT_NODE_MAJOR" -lt "$REQUIRED_NODE_MAJOR" ]; then
    info "Installing Node.js v$REQUIRED_NODE_MAJOR.x from NodeSource..."

    if ! curl -fsSL "https://deb.nodesource.com/setup_${REQUIRED_NODE_MAJOR}.x" | sudo -E bash -; then
        error "Failed to set up NodeSource repository for Node.js $REQUIRED_NODE_MAJOR.x"
    fi

    install_packages nodejs

    if ! command_exists node; then
        error "Node.js installation failed"
    fi

    info "Updating npm to latest version..."
    if ! sudo npm install -g npm@latest; then
        warn "Failed to update npm to latest version"
    fi
fi

info "Node.js installed: $(node --version)"
info "npm installed: $(npm --version)"

# ---- Yarn ----
if ! command_exists yarn; then
    if grep -qi "ubuntu" /etc/os-release 2> /dev/null || uname -r | grep -qi "microsoft"; then
        info "Detected Ubuntu or WSL Ubuntu. Installing Yarn via apt..."
        curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
        echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
        sudo apt-get update && sudo apt-get install -y yarn
    else
        info "Yarn not found. Installing Yarn globally with npm..."
        npm install -g --silent yarn
    fi

    if ! command_exists yarn; then
        warn "Yarn installation might have failed"
    else
        info "Yarn installed: $(yarn --version)"
    fi
else
    info "Yarn already installed: $(yarn --version)"
fi

info "Verifying installations..."

info "=== Installed Versions ==="
info "Node.js: $(node --version 2>/dev/null || echo 'Not installed')"
info "npm: $(npm --version 2>/dev/null || echo 'Not installed')"
info "Yarn: $(yarn --version 2>/dev/null || echo 'Not installed')"

info "Installation completed successfully!"
info "You may need to restart your shell or run 'source ~/.bashrc' for changes to take effect."
