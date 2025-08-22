#!/bin/bash
set -euo pipefail  # More strict error handling

# ==========================================
# Configuration Variables
# ==========================================
USERNAME=$(whoami)  # Get current username
ARCH=$(uname -m)    # System architecture
DOCKER_COMPOSE_VERSION="v2.26.1"  # Latest stable version

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
    openssh-server sed lz4 aria2 pv \
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

# ==========================================
# Yarn Installation
# ==========================================
if ! command_exists yarn; then
    # Detect Ubuntu (including WSL Ubuntu) and install Yarn accordingly
    if grep -qi "ubuntu" /etc/os-release 2> /dev/null || uname -r | grep -qi "microsoft"; then
        info "Detected Ubuntu or WSL Ubuntu. Installing Yarn via apt..."
        curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
        echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
        sudo apt update && sudo apt install -y yarn
    else
        info "Yarn not found. Installing Yarn globally with npm..."
        npm install -g --silent yarn
    fi
    
    # Verify installation
    if ! command_exists yarn; then
        warn "Yarn installation might have failed"
    else
        info "Yarn installed: $(yarn --version)"
    fi
else
    info "Yarn already installed: $(yarn --version)"
fi

# ==========================================
# Docker Installation
# ==========================================
info "Checking Docker installation..."

if ! command_exists docker; then
    info "Installing Docker..."
    
    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    sudo apt-get update
    install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add user to docker group
    sudo usermod -aG docker $USERNAME
    info "Docker installed. You'll need to log out and back in for group changes to take effect."
else
    info "Docker already installed: $(docker --version)"
fi

# ==========================================
# Docker Compose Installation
# ==========================================
info "Checking Docker Compose installation..."

if ! command_exists docker-compose; then
    info "Installing Docker Compose standalone..."
    
    # Download and install Docker Compose
    sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    
    # Verify installation
    if ! command_exists docker-compose; then
        warn "Docker Compose installation might have failed"
    else
        info "Docker Compose installed: $(docker-compose --version)"
    fi
else
    info "Docker Compose already installed: $(docker-compose --version)"
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
info "Docker: $(docker --version 2>/dev/null || echo 'Not installed')"
info "Docker Compose: $(docker-compose --version 2>/dev/null || echo 'Not installed')"

info "Installation completed successfully!"
info "You may need to:"
info "1. Log out and back in for Docker group changes to take effect"
info "2. Run 'source ~/.bashrc' for PATH changes to take effect"
