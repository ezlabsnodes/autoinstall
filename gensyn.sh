#!/bin/bash
set -euo pipefail  # More strict error handling

# ==========================================
# Configuration Variables
# ==========================================
GO_VERSION="1.22.2"  # Updated to latest stable Go version
GO_ARCH="linux-amd64"
DOCKER_COMPOSE_VERSION="v2.26.1"  # Updated to latest version
USERNAME=$(whoami)  # Get current username

# ==========================================
# Utility Functions
# ==========================================
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

# ==========================================
# Install Essential Packages
# ==========================================
info "Installing essential build tools..."
install_packages \
    git clang cmake build-essential openssl pkg-config libssl-dev \
    wget htop tmux jq gcc tar ncdu protobuf-compiler \
    default-jdk aptitude squid apache2-utils file lsof zip unzip sed lz4 aria2 pv\
    python3 python3-venv python3-pip python3-dev screen snapd flatpak \
    nano automake autoconf nvme-cli libgbm-dev libleveldb-dev bsdmainutils
# ==========================================
# Node.js Installation (Latest LTS Version)
# ==========================================
info "Installing Node.js LTS and npm..."
if command -v node &> /dev/null; then
    CURRENT_NODE=$(node --version)
    CURRENT_NPM=$(npm --version)
    info "Node.js already installed: $CURRENT_NODE"
    info "npm already installed: $CURRENT_NPM"
    
    # Check for updates
    info "Checking for Node.js updates..."
    LATEST_NODE_VERSION=$(curl -s https://nodejs.org/dist/latest-v18.x/ | grep -oP 'node-v\K\d+\.\d+\.\d+' | head -1)
    if [ "$(node --version | cut -d'v' -f2)" != "$LATEST_NODE_VERSION" ]; then
        warn "Newer Node.js version available ($LATEST_NODE_VERSION)"
    fi
else
    # Install latest LTS using NodeSource
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    install_packages nodejs

    # Verify installation
    if ! command -v node &> /dev/null; then
        error "Node.js installation failed"
    else
        # Update npm to latest version
        sudo npm install -g npm@latest
        
        info "Node.js installed: $(node --version)"
        info "npm installed: $(npm --version)"
    fi
fi

# Additional tools
sudo npm install -g yarn



# ==========================================
# Completion Message
# ==========================================
cat <<EOF
================================================
INSTALLATION COMPLETE!
EOF
