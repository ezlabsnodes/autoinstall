#!/bin/bash
set -euo pipefail  # More strict error handling

# ==========================================
# Color Variables
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ==========================================
# Configuration Variables
# ==========================================
OLLAMA_MODELS=("hellord/mxbai-embed-large-v1:f16" "llama3.1:latest" "llama3.2:1b")

# ==========================================
# Utility Functions
# ==========================================
function info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

function warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

function error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
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
ARCH=$(uname -m)
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
# Ollama Installation
# ==========================================
info "Checking Ollama installation..."

if ! command_exists ollama; then
    info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    
    # Verify installation
    if ! command_exists ollama; then
        error "Ollama installation failed"
    else
        info "Ollama installed: $(ollama --version)"
    fi
else
    info "Ollama already installed: $(ollama --version)"
fi

# Start and enable Ollama service
info "Setting up Ollama service..."
if command_exists systemctl; then
    sudo systemctl enable ollama && sudo systemctl start ollama
    sleep 2  # Give it a moment to start
else
    warn "Systemd not found, starting Ollama directly"
    ollama serve > /dev/null 2>&1 &
    sleep 2
fi

# Pull Ollama models
info "Pulling Ollama models..."
for model in "${OLLAMA_MODELS[@]}"; do
    info "Pulling model: $model"
    ollama pull "$model" || warn "Failed to pull model: $model"
done

# ==========================================
# Final Checks
# ==========================================
info "Verifying installations..."

# List installed versions
info "=== Installed Versions ==="
info "Ollama: $(ollama --version 2>/dev/null || echo 'Not installed')"

info "Installation completed successfully!"
info "Ollama is running as a service (use 'ollama serve' to manage if not using systemd)"
