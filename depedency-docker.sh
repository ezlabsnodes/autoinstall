#!/bin/bash
set -euo pipefail

# --- Configuration & Utility Functions ---

USERNAME=$(whoami)
ARCH=$(uname -m)
NODE_LTS_VERSION="20" # Target Node.js LTS major version (e.g., 20, 22)

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
    # Use DEBIAN_FRONTEND=noninteractive to suppress interactive prompts
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" || {
        error "Failed to install packages: $*"
    }
}

function command_exists() {
    command -v "$1" &> /dev/null
}

# --- System Checks ---

info "Checking system architecture..."
if [ "$ARCH" != "x86_64" ]; then
    warn "Non-x86_64 architecture detected ($ARCH). Some packages might need adjustment."
fi

if ! sudo -v; then
    error "This script requires sudo privileges."
fi

# Ensure curl is available early, as it's used before the main install list
if ! command_exists curl; then
    info "curl not found. Installing curl now..."
    sudo apt-get update
    install_packages curl
fi

info "Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get autoremove -y

# --- Package Installation ---

info "Installing essential build and development tools..."
install_packages \
    git clang cmake build-essential openssl pkg-config libssl-dev \
    wget htop tmux jq make gcc tar ncdu protobuf-compiler \
    default-jdk aptitude squid apache2-utils file lsof zip unzip \
    iptables iptables-persistent openssh-server sed lz4 aria2 pv \
    python3 python3-venv python3-pip python3-dev screen snapd flatpak \
    nano automake autoconf nvme-cli libgbm-dev libleveldb-dev bsdmainutils unzip \
    ca-certificates gnupg lsb-release software-properties-common

# --- Node.js Installation ---

info "Checking Node.js installation (Targeting LTS v$NODE_LTS_VERSION)..."

if command_exists node; then
    CURRENT_NODE=$(node --version)
    CURRENT_NPM=$(npm --version)
    info "Node.js already installed: $CURRENT_NODE"
    info "npm already installed: $CURRENT_NPM"
    
    # Simple check if current version matches the target major LTS
    # This check is informational; it won't force an update.
    if [[ "$CURRENT_NODE" != v"$NODE_LTS_VERSION".* ]]; then
        warn "Installed Node.js version ($CURRENT_NODE) does not match target LTS v$NODE_LTS_VERSION."
        info "To update, you can reinstall or use a version manager (like nvm/fnm)."
    fi
else
    info "Node.js not found. Setting up NodeSource repository for LTS v$NODE_LTS_VERSION..."
    
    # Use the official NodeSource setup script for the target LTS version
    NODE_SETUP_SCRIPT="setup_$NODE_LTS_VERSION.x"
    if ! curl -fsSL "https://deb.nodesource.com/$NODE_SETUP_SCRIPT" | sudo -E bash -; then
        error "Failed to set up NodeSource repository for v$NODE_LTS_VERSION"
    fi
    
    install_packages nodejs

    if ! command_exists node; then
        error "Node.js installation failed"
    fi
    
    info "Updating npm to latest version..."
    # Suppress the update output unless it fails
    if ! sudo npm install -g npm@latest &> /dev/null; then
        warn "Failed to update npm to latest version. This is usually safe to ignore if Node.js is working."
    fi
    
    info "Node.js installed: $(node --version)"
    info "npm installed: $(npm --version)"
fi

# --- Yarn Installation ---

if ! command_exists yarn; then
    if grep -qi "ubuntu" /etc/os-release 2> /dev/null || uname -r | grep -qi "microsoft"; then
        info "Detected Ubuntu or WSL. Installing Yarn via apt using modern GPG method..."
        
        # 1. Download and dearmor key using the new, non-deprecated method
        YARN_KEYRING="/usr/share/keyrings/yarn-keyring.gpg"
        if ! curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo gpg --dearmor -o "$YARN_KEYRING" 2>/dev/null; then
             warn "Failed to create Yarn GPG keyring. Attempting older method..."
             # Fallback to the old method if the new one fails (e.g., in older environments)
             curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
             echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list > /dev/null
        else
            # 2. Add repository with signed-by parameter
            echo "deb [signed-by=$YARN_KEYRING] https://dl.yarnpkg.com/debian/ stable main" | \
                sudo tee /etc/apt/sources.list.d/yarn.list > /dev/null || warn "Failed to add Yarn repository."
        fi
            
        sudo apt update && sudo apt install -y yarn
    else
        info "Yarn not found. Installing Yarn globally with npm..."
        # Use --silent for cleaner output
        if ! npm install -g --silent yarn; then
            warn "npm install of yarn failed. Check global npm permissions."
        fi
    fi
    
    if ! command_exists yarn; then
        warn "Yarn installation might have failed."
    else
        info "Yarn installed: $(yarn --version)"
    fi
else
    info "Yarn already installed: $(yarn --version)"
fi

# --- Final Verification ---

info "Verifying installations..."

info "=== Installed Versions ==="
info "Node.js: $(node --version 2>/dev/null || echo 'Not installed')"
info "npm: $(npm --version 2>/dev/null || echo 'Not installed')"
info "Yarn: $(yarn --version 2>/dev/null || echo 'Not installed')"

info "Installation completed successfully!"
info "You may need to restart your shell or run 'exec \$SHELL' for changes to take effect."
