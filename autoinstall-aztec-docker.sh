#!/usr/bin/env bash
set -Eeuo pipefail

# ============ UI helpers ============
green(){ echo -e "\033[1;32m$*\033[0m"; }
yellow(){ echo -e "\033[1;33m$*\033[0m"; }
red(){ echo -e "\033[1;31m$*\033[0m" >&2; }

# Minimal prereqs BEFORE installing deps (no lsb-release to avoid early failure)
REQ_PKGS=("curl" "sudo" "tee" "awk" "sed" "grep" "cat" "printf")

# ============ Preflight ============
for p in "${REQ_PKGS[@]}"; do
  command -v "$p" >/dev/null 2>&1 || { red "Required package '$p' not found."; exit 1; }
done

if ! sudo -v >/dev/null 2>&1; then
  red "This script requires sudo privileges."; exit 1
fi

USER_NAME=${SUDO_USER:-$(whoami)}
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
AZTEC_HOME="$HOME_DIR"
AZTEC_BIN="$AZTEC_HOME/.aztec/bin"

# Optional: try to install lsb-release if missing (non-blocking)
if ! command -v lsb_release >/dev/null 2>&1; then
  yellow "[OPTIONAL] Installing lsb-release…"
  sudo apt-get update -y >/dev/null 2>&1 || true
  sudo apt-get install -y lsb-release >/dev/null 2>&1 || true
fi

# ============ Write & run depedency-lite.sh (your original content) ============
green "[1/6] Writing depedency-lite.sh…"
cat > depedency-lite.sh <<'BASH'
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
if ! sudo -v &>/dev/null; then
    error "This script requires sudo privileges."
fi

# ==========================================
# System Update
# ==========================================
info "Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y || error "Failed to update and upgrade packages."
sudo apt-get autoremove -y || warn "Autoremove failed, but continuing."

# ==========================================
# Install Essential Packages
# ==========================================
info "Installing essential build tools and common utilities..."
install_packages \
    git clang cmake build-essential openssl pkg-config libssl-dev \
    wget htop tmux jq make gcc tar ncdu protobuf-compiler \
    default-jdk openssh-server sed lz4 aria2 pv \
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
info "=== Installed Versions ==="
info "Docker: $(docker --version 2>/dev/null || echo 'Not installed')"
info "Docker Compose (plugin): $(docker compose version 2>/dev/null | head -n 1 || echo 'Not installed')"

info "Installation completed successfully!"
info "Please remember to log out and back in (or run 'newgrp docker') for the Docker group changes to take effect for user '$USERNAME'."
BASH

chmod +x depedency-lite.sh
green "[2/6] Running depedency-lite.sh (sudo required)…"
sudo ./depedency-lite.sh

# ============ Install Aztec CLI ============
green "[3/6] Installing Aztec CLI…"
curl -fsSL https://install.aztec.network -o /tmp/aztec-install.sh

# Auto-answer: continue=y, add-to-PATH=n (avoid 'Starting fresh shell…')
# We'll set PATH ourselves to keep this script running.
printf 'y\nn\n' | bash /tmp/aztec-install.sh

# Add PATH (persist + current session)
if ! grep -q "$AZTEC_HOME/.aztec/bin" "$HOME_DIR/.bashrc" 2>/dev/null; then
  echo "export PATH=\$PATH:$AZTEC_HOME/.aztec/bin" >> "$HOME_DIR/.bashrc"
fi
export PATH="$PATH:$AZTEC_HOME/.aztec/bin"

# Ensure aztec-up exists, then upgrade to the requested version
if [ -x "$AZTEC_BIN/aztec-up" ]; then
  "$AZTEC_BIN/aztec-up" -v 2.0.2
else
  red "aztec-up not found in $AZTEC_BIN"; exit 1
fi

# ============ Prompt input ============
green "[4/6] Configuration input…"
read -rp "ETHEREUM_RPC_URL: " ETHEREUM_RPC_URL
read -rp "CONSENSUS_BEACON_URL: " CONSENSUS_BEACON_URL
read -rp "VALIDATOR_PRIVATE_KEYS (comma separated if multiple): " VALIDATOR_PRIVATE_KEYS
read -rp "COINBASE (Wallet Adress): " COINBASE

for varname in ETHEREUM_RPC_URL CONSENSUS_BEACON_URL VALIDATOR_PRIVATE_KEYS COINBASE; do
  if [ -z "${!varname}" ]; then red "$varname must not be empty."; exit 1; fi
done

# ============ Auto-detect Public IP ============
green "Detecting VPS public IP for P2P_IP…"
detect_public_ip() {
  local ip=""
  ip=$(curl -fsS --max-time 8 https://api.ipify.org || true)
  [ -z "$ip" ] && ip=$(curl -fsS --max-time 8 https://ifconfig.me || true)
  [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "$ip"
}
P2P_IP="$(detect_public_ip)"
if [ -z "$P2P_IP" ]; then
  yellow "Auto-detect failed. Please enter P2P_IP manually."
  read -rp "P2P_IP: " P2P_IP
  [ -z "$P2P_IP" ] && { red "P2P_IP is empty."; exit 1; }
else
  green "Public IP detected: $P2P_IP"
fi

# ============ Create folders & files ============
green "[5/6] Creating directory & config files…"
AZTEC_DIR="$HOME_DIR/aztec"
mkdir -p "$AZTEC_DIR"
cd "$AZTEC_DIR"

# Backup existing files if present
[ -f .env ] && cp .env ".env.bak.$(date +%s)"
[ -f docker-compose.yml ] && cp docker-compose.yml "docker-compose.yml.bak.$(date +%s)"

# Write .env
cat > .env <<EOF
ETHEREUM_RPC_URL=${ETHEREUM_RPC_URL}
CONSENSUS_BEACON_URL=${CONSENSUS_BEACON_URL}
VALIDATOR_PRIVATE_KEYS=${VALIDATOR_PRIVATE_KEYS}
COINBASE=${COINBASE}
P2P_IP=${P2P_IP}
GOVERNANCE_PAYLOAD=0x54F7fe24E349993b363A5Fa1bccdAe2589D5E5Ef
EOF

# Write docker-compose.yml
cat > docker-compose.yml <<'YAML'
services:
  aztec-node:
    container_name: aztec-sequencer
    image: aztecprotocol/aztec:2.0.2
    restart: unless-stopped
    environment:
      ETHEREUM_HOSTS: ${ETHEREUM_RPC_URL}
      L1_CONSENSUS_HOST_URLS: ${CONSENSUS_BEACON_URL}
      DATA_DIRECTORY: /data
      VALIDATOR_PRIVATE_KEYS: ${VALIDATOR_PRIVATE_KEYS}
      COINBASE: ${COINBASE}
      P2P_IP: ${P2P_IP}
      GOVERNANCE_PAYLOAD: ${GOVERNANCE_PAYLOAD}
      LOG_LEVEL: info
    entrypoint: >
      sh -c "node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start
      --network testnet
      --node
      --archiver
      --sequencer
      --port 8080"
    ports:
      - 40400:40400/tcp
      - 40400:40400/udp
      - 8080:8080
    volumes:
      - /root/.aztec/testnet/data/:/data
YAML

# ============ Bring up docker compose ============
green "[6/6] Starting docker compose…"
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  red "Docker Compose not found."; exit 1
fi

# Use sudo to avoid group membership delay in current session
sudo $COMPOSE_CMD --env-file "$AZTEC_DIR/.env" up -d

green "Done! Aztec node is running in the background."

echo
echo "Summary:"
echo "  Working dir      : $AZTEC_DIR"
echo "  ENV file         : $AZTEC_DIR/.env"
echo "  Compose file     : $AZTEC_DIR/docker-compose.yml"
echo "  P2P_IP           : $P2P_IP"
echo
echo "Check Logs:"
echo "  docker logs -f aztec-sequencer"
