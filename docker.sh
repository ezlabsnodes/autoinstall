#!/bin/bash
set -euo pipefail  # More strict error handling

# ==========================================
# Configuration Variables
# ==========================================
DOCKER_COMPOSE_VERSION="v2.26.1"  # Updated to latest version
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
# Docker Installation
# ==========================================
info "Checking Docker installation..."

if ! command_exists docker; then
    info "Installing Docker..."
    
    # Add Docker's official GPG key
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    sudo apt-get update
    install_packages docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Add user to docker group
    sudo usermod -aG docker $USERNAME
    info "Docker installed. You'll need to log out and back in for group changes to take effect."
else
    info "Docker already installed: $(docker --version)"
    info "Docker Compose already installed: $(docker compose version)"
fi
# ==========================================
# Final Checks
# ==========================================
info "Verifying installations..."

# List installed versions
info "=== Installed Versions ==="
info "Docker: $(docker --version 2>/dev/null || echo 'Not installed')"
info "Docker Compose: $(docker compose version 2>/dev/null || echo 'Not installed')"

info "Installation completed successfully!"
info "You may need to restart your shell or run 'source ~/.bashrc' for changes to take effect."
