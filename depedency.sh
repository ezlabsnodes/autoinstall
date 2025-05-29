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
# System Update
# ==========================================
info "Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y

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
    nano automake autoconf nvme-cli libgbm-dev libleveldb-dev bsdmainutils unzip

# ==========================================
# Docker Installation
# ==========================================
info "Setting up Docker..."
install_packages \
    apt-transport-https ca-certificates curl software-properties-common lsb-release gnupg2

# Add Docker repository
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin

# ==========================================
# Docker Compose Installation
# ==========================================
info "Installing Docker Compose..."
sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Install as Docker CLI plugin
DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
mkdir -p $DOCKER_CONFIG/cli-plugins
curl -SL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" -o $DOCKER_CONFIG/cli-plugins/docker-compose
chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose

# ==========================================
# User Configuration
# ==========================================
info "Configuring user groups..."
sudo groupadd -f docker
for user in $USERNAME rumiyah hosting; do
    if id "$user" &>/dev/null; then
        sudo usermod -aG docker "$user"
    else
        warn "User $user does not exist, skipping group addition"
    fi
done

# ==========================================
# Development Tools
# ==========================================
info "Installing development tools..."

# Visual Studio Code
if ! command -v code &> /dev/null; then
    sudo snap install code --classic
else
    info "VS Code already installed"
fi

# Flatpak setup
if ! flatpak remote-list | grep -q flathub; then
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
else
    info "Flathub already configured"
fi

# OpenJDK
sudo add-apt-repository ppa:openjdk-r/ppa -y
sudo apt-get update
install_packages openjdk-17-jdk  # Updated to LTS version

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
# Go Installation
# ==========================================
info "Installing Go ${GO_VERSION}..."
if command -v go &> /dev/null; then
    info "Go already installed: $(go version)"
else
    curl -OL "https://go.dev/dl/go${GO_VERSION}.${GO_ARCH}.tar.gz"

    if file "go${GO_VERSION}.${GO_ARCH}.tar.gz" | grep -q "gzip compressed data"; then
        sudo rm -rf /usr/local/go  # Remove previous installation if exists
        sudo tar -C /usr/local -xzf "go${GO_VERSION}.${GO_ARCH}.tar.gz"
        rm "go${GO_VERSION}.${GO_ARCH}.tar.gz"
        
        # Add to PATH
        export PATH=$PATH:/usr/local/go/bin
        grep -qxF 'export PATH=$PATH:/usr/local/go/bin' ~/.bashrc || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
        
        # Verify
        if ! command -v go &> /dev/null; then
            error "Go installation failed"
        else
            info "Go installed: $(go version)"
        fi
    else
        error "Invalid Go download"
    fi
fi

# ==========================================
# Rust Installation
# ==========================================
info "Installing Rust..."
if command -v rustc &> /dev/null; then
    info "Rust already installed: $(rustc --version)"
else
    export CARGO_HOME="$HOME/.cargo"
    export RUSTUP_HOME="$HOME/.rustup"

    # Install Rust non-interactively
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile default

    # Add to PATH in a way that works for all shells
    {
        echo 'export CARGO_HOME="$HOME/.cargo"'
        echo 'export RUSTUP_HOME="$HOME/.rustup"'
        echo 'export PATH="$CARGO_HOME/bin:$PATH"'
    } >> ~/.bashrc

    # Source the environment immediately
    source "$CARGO_HOME/env"
fi

# ==========================================
# Final Configuration
# ==========================================
info "Final system configuration..."
sudo systemctl enable --now docker
sudo systemctl enable --now netfilter-persistent

# ==========================================
# Completion Message
# ==========================================
cat <<EOF

================================================
INSTALLATION COMPLETE!
- System updated and essential packages installed
- Docker and Docker Compose ${DOCKER_COMPOSE_VERSION} installed
- Development tools (Go ${GO_VERSION}, Rust, Node.js, etc.) installed
- Visual Studio Code installed via Snap
================================================

IMPORTANT NEXT STEPS:
1. Run this command or restart your shell to apply changes:
   source ~/.bashrc

2. Verify installations:
   docker --version
   docker-compose --version
   go version
   rustc --version
   node --version
   npm --version

3. For Docker to work without sudo, you may need to log out and back in.
EOF
