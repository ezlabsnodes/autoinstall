#!/usr/bin/env bash
set -Eeuo pipefail

# ================= UI helpers =================
green(){ echo -e "\033[1;32m$*\033[0m"; }
yellow(){ echo -e "\033[1;33m$*\033[0m"; }
red(){ echo -e "\033[1;31m$*\033[0m" >&2; }

# Never prompt for apt
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# ================= Privilege escalation (no prompts) =================
SUDO=""
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  if sudo -n true >/dev/null 2>&1; then
    SUDO="sudo -n"
  else
    red "Butuh hak root, tetapi passwordless sudo tidak tersedia dan kita tidak akan mem-prompt password.
- Jalankan script ini sebagai root:   curl -fsSL <url> | sudo -n bash
- ATAU aktifkan NOPASSWD untuk user (OVH biasanya default NOPASSWD).
- ATAU jalankan dari akun root (ssh root@server jika diizinkan)."
    exit 1
  fi
fi

# Helper untuk menjalankan perintah (echo + jalankan)
run(){ echo "+ $*"; eval "$@"; }

# Minimal prereqs BEFORE installing deps (tanpa lsb-release agar tidak gagal di awal)
REQ_PKGS=("curl" "tee" "awk" "sed" "grep" "cat" "printf")

# ================= Preflight =================
for p in "${REQ_PKGS[@]}"; do
  command -v "$p" >/dev/null 2>&1 || { red "Required package '$p' not found."; exit 1; }
done

USER_NAME=${SUDO_USER:-$(whoami)}
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
AZTEC_HOME="$HOME_DIR"
AZTEC_BIN="$AZTEC_HOME/.aztec/bin"

# Optional: coba pasang lsb-release jika ada apt
if ! command -v lsb_release >/dev/null 2>&1; then
  yellow "[OPTIONAL] Installing lsb-release…"
  ${SUDO} apt-get update -y >/dev/null 2>&1 || true
  ${SUDO} apt-get install -y lsb-release >/dev/null 2>&1 || true
fi

# ================= dependency-lite.sh =================
green "[1/6] Writing depedency-lite.sh…"
cat > depedency-lite.sh <<'BASH'
#!/bin/bash
set -euo pipefail

info(){  echo -e "\033[1;32m[INFO] $1\033[0m"; }
warn(){  echo -e "\033[1;33m[WARN] $1\033[0m"; }
error(){ echo -e "\033[1;31m[ERROR] $1\033[0m" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
USERNAME=${SUDO_USER:-$(whoami)}
ARCH=$(uname -m)

# Tentukan SUDO non-interaktif atau kosong jika root
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true >/dev/null 2>&1; then
    SUDO="sudo -n"
  else
    error "Tidak ada root & tidak ada passwordless sudo; batal (tanpa prompt password)."
  fi
fi

command_exists(){ command -v "$1" >/dev/null 2>&1; }

install_packages(){
  info "Installing packages: $*"
  ${SUDO} apt-get install -y "$@" || error "Failed to install packages: $*"
}

info "Arch: $ARCH"
if [ "$ARCH" != "x86_64" ]; then
  warn "Non-x86_64 detected ($ARCH)."
fi

info "Updating system packages…"
${SUDO} apt-get update
${SUDO} apt-get -y full-upgrade || error "Failed to upgrade packages."
${SUDO} apt-get -y autoremove || warn "Autoremove failed."

info "Installing essential build tools and utilities…"
install_packages \
  git clang cmake build-essential openssl pkg-config libssl-dev \
  wget htop tmux jq make gcc tar ncdu protobuf-compiler \
  default-jdk openssh-server sed lz4 aria2 pv \
  python3 python3-pip python3-dev screen \
  nano automake autoconf unzip \
  ca-certificates curl gnupg lsb-release software-properties-common

info "Checking Docker…"
if ! command_exists docker; then
  info "Installing Docker Engine & Compose plugin…"
  ${SUDO} install -m 0755 -d /etc/apt/keyrings || error "keyrings dir"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | ${SUDO} gpg --dearmor -o /etc/apt/keyrings/docker.gpg || error "docker gpg"
  ${SUDO} chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null

  ${SUDO} apt-get update || error "apt update (docker)"
  install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  info "Add user '$USERNAME' to group docker"
  ${SUDO} usermod -aG docker "$USERNAME" || error "usermod docker"
else
  info "Docker already installed: $(docker --version 2>/dev/null || echo 'unknown')"
  if docker compose version >/dev/null 2>&1; then
    info "Compose plugin: $(docker compose version | head -n1)"
  else
    warn "Docker Compose plugin missing."
  fi
fi

info "Verify:"
info "Docker: $(docker --version 2>/dev/null || echo 'Not installed')"
info "Compose: $(docker compose version 2>/dev/null | head -n1 || echo 'Not installed')"

info "Done. If baru ditambahkan ke grup docker, jalankan 'newgrp docker' atau re-login."
BASH

chmod +x depedency-lite.sh
green "[2/6] Running depedency-lite.sh…"
${SUDO} ./depedency-lite.sh

# ================= Install Aztec CLI =================
green "[3/6] Installing Aztec CLI…"
curl -fsSL https://install.aztec.network -o /tmp/aztec-install.sh
# Auto-answer: continue=y, add-to-PATH=n
printf 'y\nn\n' | bash /tmp/aztec-install.sh

# Add PATH (persist + current session)
if ! grep -q "$AZTEC_HOME/.aztec/bin" "$HOME_DIR/.bashrc" 2>/dev/null; then
  echo "export PATH=\$PATH:$AZTEC_HOME/.aztec/bin" >> "$HOME_DIR/.bashrc"
fi
export PATH="$PATH:$AZTEC_HOME/.aztec/bin"

if [ -x "$AZTEC_BIN/aztec-up" ]; then
  "$AZTEC_BIN/aztec-up" -v 2.0.3
else
  red "aztec-up not found in $AZTEC_BIN"; exit 1
fi

# ================= Prompt input =================
green "[4/6] Configuration input…"
read -rp "ETHEREUM_RPC_URL: " ETHEREUM_RPC_URL
read -rp "CONSENSUS_BEACON_URL: " CONSENSUS_BEACON_URL
read -rp "VALIDATOR_PRIVATE_KEYS (comma separated if multiple): " VALIDATOR_PRIVATE_KEYS
read -rp "COINBASE (Wallet Adress): " COINBASE

for varname in ETHEREUM_RPC_URL CONSENSUS_BEACON_URL VALIDATOR_PRIVATE_KEYS COINBASE; do
  if [ -z "${!varname}" ]; then red "$varname must not be empty."; exit 1; fi
done

# ================= Auto-detect Public IP =================
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

# ================= Create folders & files =================
green "[5/6] Creating directory & config files…"
AZTEC_DIR="$HOME_DIR/aztec"
mkdir -p "$AZTEC_DIR"
cd "$AZTEC_DIR"

[ -f .env ] && cp .env ".env.bak.$(date +%s)"
[ -f docker-compose.yml ] && cp docker-compose.yml "docker-compose.yml.bak.$(date +%s)"

cat > .env <<EOF
ETHEREUM_RPC_URL=${ETHEREUM_RPC_URL}
CONSENSUS_BEACON_URL=${CONSENSUS_BEACON_URL}
VALIDATOR_PRIVATE_KEYS=${VALIDATOR_PRIVATE_KEYS}
COINBASE=${COINBASE}
P2P_IP=${P2P_IP}
GOVERNANCE_PAYLOAD=0x54F7fe24E349993b363A5Fa1bccdAe2589D5E5Ef
EOF

cat > docker-compose.yml <<'YAML'
services:
  aztec-node:
    container_name: aztec-sequencer
    image: aztecprotocol/aztec:2.0.3
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

# ================= Bring up docker compose =================
green "[6/6] Starting docker compose…"
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  red "Docker Compose not found."; exit 1
fi

# Pakai ${SUDO} untuk menghindari delay membership group docker di sesi saat ini
${SUDO} ${COMPOSE_CMD} --env-file "$AZTEC_DIR/.env" up -d

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
