#!/bin/bash
set -euo pipefail  # More strict error handling

# ==========================================
# Configuration Variables
# ==========================================
USERNAME=$(whoami)  # Get current username
ARCH=$(uname -m)    # System architecture

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

function command_exists() {
    command -v "$1" &> /dev/null
}

# ==========================================
# System Checks
# ==========================================
info "Checking system architecture..."
if [ "$ARCH" != "x86_64" ]; then
    warn "Non-x86_64 architecture detected ($ARCH), some packages might need adjustment"
fi

# Check for sudo privileges
if ! sudo -v; then
    error "This script requires sudo privileges"
fi

# ==========================================
# System Update
# ==========================================
info "Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get autoremove -y

# ==========================================
# Install Essential Packages
# ==========================================
info "Installing essential build tools..."
install_packages \
    git clang cmake build-essential openssl pkg-config libssl-dev \
    wget htop tmux jq make gcc tar ncdu protobuf-compiler \
    default-jdk aptitude squid apache2-utils file lsof zip unzip \
    iptables iptables-persistent openssh-server sed lz4 aria2 pv \
    python3 python3-venv python3-pip python3-dev screen snapd flatpak \
    nano automake autoconf nvme-cli libgbm-dev libleveldb-dev bsdmainutils unzip \
    ca-certificates curl gnupg lsb-release software-properties-common

# ==========================================
# Node.js Installation (Latest LTS Version)
# ==========================================
info "Checking Node.js installation..."

if command_exists node; then
    CURRENT_NODE=$(node --version)
    CURRENT_NPM=$(npm --version)
    info "Node.js already installed: $CURRENT_NODE"
    info "npm already installed: $CURRENT_NPM"
    
    # Check for updates
    info "Checking for Node.js updates..."
    LATEST_NODE_VERSION=$(curl -fsSL https://nodejs.org/dist/latest-v18.x/SHASUMS256.txt | grep -oP 'node-v\K\d+\.\d+\.\d+-linux-x64' | head -1 | cut -d'-' -f1)
    if [ "$(node --version | cut -d'v' -f2)" != "$LATEST_NODE_VERSION" ]; then
        warn "Newer Node.js version available ($LATEST_NODE_VERSION)"
        info "Consider updating using:"
        info "  sudo npm install -g n"
        info "  sudo n lts"
    fi
else
    # Install NodeSource setup script with proper error handling
    info "Adding NodeSource repository..."
    if ! curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -; then
        error "Failed to set up NodeSource repository"
    fi
    
    install_packages nodejs

    # Verify installation
    if ! command_exists node; then
        error "Node.js installation failed"
    fi
    
    # Update npm to latest version
    info "Updating npm to latest version..."
    if ! sudo npm install -g npm@latest; then
        warn "Failed to update npm to latest version"
    fi
    
    info "Node.js installed: $(node --version)"
    info "npm installed: $(npm --version)"
fi

# Install Yarn if not present
if ! command_exists yarn; then
    info "Installing Yarn..."
    if ! sudo npm install -g yarn; then
        warn "Failed to install Yarn"
    else
        info "Yarn installed: $(yarn --version)"
    fi
else
    info "Yarn already installed: $(yarn --version)"
fi
# ==========================================
# Final Checks
# ==========================================
info "Verifying installations..."

# List installed versions
info "=== Installed Versions ==="
info "Node.js: $(node --version 2>/dev/null || echo 'Not installed')"
info "npm: $(npm --version 2>/dev/null || echo 'Not installed')"
info "Yarn: $(yarn --version 2>/dev/null || echo 'Not installed')"

info "Installation completed successfully!"
info "You may need to restart your shell or run 'source ~/.bashrc' for changes to take effect."
