#!/bin/bash
set -euo pipefail

# ==========================================
# Configuration Variables
# ==========================================
GO_VERSION="1.22.2"
GO_ARCH="linux-amd64"
DOCKER_COMPOSE_VERSION="v2.26.1"
USERNAME=$(whoami)

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
    sudo apt-get install -y --no-install-recommends "$@" || {
        error "Failed to install packages: $*"
    }
}

# ==========================================
# Switch to Faster APT Mirror
# ==========================================
info "Switching APT source to local mirror..."
sudo sed -i 's|http://.*.ubuntu.com|http://kambing.ui.ac.id|g' /etc/apt/sources.list

# ==========================================
# System Update
# ==========================================
info "Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y

# ==========================================
# Essential Build Tools
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
DOCKER_COMPOSE_URL="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64"
sudo curl -L "$DOCKER_COMPOSE_URL" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
mkdir -p $DOCKER_CONFIG/cli-plugins
curl -L "$DOCKER_COMPOSE_URL" -o $DOCKER_CONFIG/cli-plugins/docker-compose
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

if ! command -v code &> /dev/null; then
    sudo snap install code --classic
else
    info "VS Code already installed"
fi

if ! flatpak remote-list | grep -q flathub; then
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
else
    info "Flathub already configured"
fi

sudo add-apt-repository ppa:openjdk-r/ppa -y
sudo apt-get update
install_packages openjdk-17-jdk

# ==========================================
# Node.js + npm
# ==========================================
info "Installing Node.js LTS..."
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    install_packages nodejs
    sudo npm install -g npm@latest
    npm config set registry https://registry.npmmirror.com
else
    info "Node.js already installed: $(node --version)"
    info "npm already installed: $(npm --version)"
fi
sudo npm install -g yarn

# ==========================================
# Go Installation
# ==========================================
info "Installing Go ${GO_VERSION}..."
GO_TARBALL="go${GO_VERSION}.${GO_ARCH}.tar.gz"
GO_URL="https://golang.google.cn/dl/${GO_TARBALL}"

if [ ! -f "$GO_TARBALL" ]; then
    if command -v aria2c &>/dev/null; then
        aria2c -x 4 -s 4 "$GO_URL"
    else
        curl -OL "$GO_URL"
    fi
fi

if file "$GO_TARBALL" | grep -q "gzip compressed data"; then
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "$GO_TARBALL"
    rm "$GO_TARBALL"
    export PATH=$PATH:/usr/local/go/bin
    grep -qxF 'export PATH=$PATH:/usr/local/go/bin' ~/.bashrc || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
    info "Go installed: $(/usr/local/go/bin/go version)"
else
    error "Invalid Go download"
fi

# ==========================================
# Rust Installation
# ==========================================
info "Installing Rust..."
if ! command -v rustc &> /dev/null; then
    export CARGO_HOME="$HOME/.cargo"
    export RUSTUP_HOME="$HOME/.rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile default

    {
        echo 'export CARGO_HOME="$HOME/.cargo"'
        echo 'export RUSTUP_HOME="$HOME/.rustup"'
        echo 'export PATH="$CARGO_HOME/bin:$PATH"'
    } >> ~/.bashrc

    source "$CARGO_HOME/env"
else
    info "Rust already installed: $(rustc --version)"
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
- Docker + Docker Compose ${DOCKER_COMPOSE_VERSION} installed
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

3. Logout/login to activate Docker group membership (if needed).
EOF
