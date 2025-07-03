#!/bin/bash
set -euo pipefail # More strict error handling

# ==========================================
# Configuration Variables
# ==========================================
USERNAME=${SUDO_USER:-$(whoami)} # Get original user if using sudo, else current user
ARCH=$(uname -m)                 # System architecture

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
    warn "Non-x86_64 architecture detected ($ARCH). Some packages or Docker might need adjustment for specific platforms."
fi

# Check for sudo privileges
if ! sudo -v &>/dev/null; then # Use &>/dev/null to suppress sudo password prompt/output
    error "This script requires sudo privileges."
fi

# ==========================================
# System Update
# ==========================================
info "Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y || error "Failed to update and upgrade packages."
sudo apt-get autoremove -y || warn "Autoremove failed, but continuing." # Autoremove often gives non-zero if nothing to remove

# ==========================================
# Install Essential Packages
# ==========================================
info "Installing essential build tools and common utilities..."
install_packages \
    git clang cmake build-essential openssl pkg-config libssl-dev \
    wget htop tmux jq make gcc tar ncdu protobuf-compiler \
    default-jdk iptables iptables-persistent openssh-server sed lz4 aria2 pv \
    python3 python3-pip python3-dev screen \
    nano automake autoconf unzip \
    ca-certificates curl gnupg lsb-release software-properties-common

# ==========================================
# Docker Installation
# ==========================================
info "Checking Docker installation..."

if ! command_exists docker; then
    info "Installing Docker Engine and Docker Compose plugin..."
    
    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings || error "Failed to create /etc/apt/keyrings."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg || error "Failed to download/install Docker GPG key."
    sudo chmod a+r /etc/apt/keyrings/docker.gpg || error "Failed to set permissions for Docker GPG key."

    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null || error "Failed to add Docker repository."

    # Install Docker components
    sudo apt-get update || error "Failed to update apt-get after adding Docker repo."
    install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add user to docker group
    info "Adding user '$USERNAME' to 'docker' group."
    sudo usermod -aG docker "$USERNAME" || error "Failed to add user '$USERNAME' to 'docker' group."
    info "Docker installed. You'll need to log out and back in, or run 'newgrp docker' for group changes to take effect immediately."
else
    info "Docker already installed: $(docker --version)"
    # Check for docker compose plugin existence
    if command_exists docker && docker compose version &>/dev/null; then
        info "Docker Compose plugin is also installed: $(docker compose version | head -n 1)"
    else
        warn "Docker is installed, but Docker Compose plugin might be missing or not functional."
    fi
fi

# ==========================================
# Final Checks
# ==========================================
info "Verifying installations..."

# List installed versions
info "=== Installed Versions ==="
info "Docker: $(docker --version 2>/dev/null || echo 'Not installed')"
# Use 'docker compose version' instead of 'docker-compose --version' for the plugin
info "Docker Compose (plugin): $(docker compose version 2>/dev/null | head -n 1 || echo 'Not installed')"

info "Installation completed successfully!"
info "Please remember to log out and back in (or run 'newgrp docker') for the Docker group changes to take effect for user '$USERNAME'."
