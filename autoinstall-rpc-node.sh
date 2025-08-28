#!/usr/bin/env bash
set -Eeuo pipefail

# ===== Pretty logging =====
green(){ echo -e "\033[1;32m$*\033[0m"; }
yellow(){ echo -e "\033[1;33m$*\033[0m"; }
red(){ echo -e "\033[1;31m$*\033[0m" >&2; }

trap 'red "[ERROR] Script failed on line $LINENO"' ERR

# Re-exec as root if needed (optimize step requires root)
if [ "$EUID" -ne 0 ]; then
  echo "[INFO] Elevating to root..."
  exec sudo -E bash "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive

# ====== Step 1: Write and run optimize.sh ======
green "[1/5] Writing optimize.sh…"
cat >/root/optimize.sh <<'OPTIM'
#!/bin/bash
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
status() { echo -e "\n${BLUE}>>> $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warning() { echo -e "${YELLOW}⚠ $*${NC}"; }
error() { echo -e "${RED}✗ $*${NC}"; exit 1; }

SERVICES_TO_DISABLE=( avahi-daemon cups bluetooth ModemManager )

[ "$(id -u)" -eq 0 ] || error "Run as root."

status "Optimizing system limits..."
if ! grep -q "# Kuzco Optimization" /etc/security/limits.conf; then
cat <<EOF >> /etc/security/limits.conf

# Kuzco Optimization
* soft nofile 1048576
* hard nofile 1048576
* soft nproc unlimited
* hard nproc unlimited
* soft memlock unlimited
* hard memlock unlimited
root soft nofile 1048576
root hard nofile 1048576
root soft nproc unlimited
root hard nproc unlimited
root soft memlock unlimited
root hard memlock unlimited
EOF
  success "Added limits to /etc/security/limits.conf"
else
  success "System limits already configured (skipped)"
fi

ulimit -n 1048576 >/dev/null 2>&1 || warning "Couldn't raise current session limits (reboot may be required)"
success "Tried setting file descriptor limit"

mkdir -p /etc/systemd/system.conf.d/
cat <<EOF > /etc/systemd/system.conf.d/limits.conf
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
DefaultLimitMEMLOCK=infinity
EOF
success "Configured systemd limits"

if [ -f /etc/pam.d/common-session ] && ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
  echo "session required pam_limits.so" >> /etc/pam.d/common-session
  success "Added PAM limits configuration"
elif [ ! -f /etc/pam.d/common-session ]; then
  warning "PAM common-session file not found"
else
  success "PAM limits already configured (skipped)"
fi

status "Optimizing kernel parameters..."
if [ ! -f /etc/sysctl.d/99-kuzco.conf ]; then
cat <<'EOF' > /etc/sysctl.d/99-kuzco.conf
# Network
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.ip_local_port_range=1024 65535

# Memory
vm.swappiness=10
vm.dirty_ratio=60
vm.dirty_background_ratio=2

# File handles
fs.file-max=1048576
fs.nr_open=1048576

# IPC (Important for DHT)
kernel.msgmax=65536
kernel.msgmnb=65536
kernel.shmall=4294967296
kernel.shmmax=17179869184

# Process handling
kernel.pid_max=4194304
kernel.threads-max=4194304
vm.max_map_count=262144
EOF
  sysctl -p /etc/sysctl.d/99-kuzco.conf >/dev/null 2>&1 || true
  success "Kernel parameters optimized"
else
  success "Kernel parameters already optimized (skipped)"
fi

status "Disabling unnecessary services..."
for s in "${SERVICES_TO_DISABLE[@]}"; do
  if systemctl is-enabled "$s" 2>/dev/null | grep -q enabled; then
    systemctl disable --now "$s" >/dev/null 2>&1 && success "Disabled $s" || warning "Failed to disable $s"
  else
    success "$s already disabled (skipped)"
  fi
done

status "Performing final updates..."
if command -v apt-get >/dev/null; then
  apt-get update >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get -y upgrade >/dev/null 2>&1 || warning "Upgrade failed"
  apt-get -y autoremove >/dev/null 2>&1 || true
  apt-get clean >/dev/null 2>&1 || true
elif command -v dnf >/dev/null; then
  dnf -y update >/dev/null 2>&1 || warning "Update failed"
  dnf -y autoremove >/dev/null 2>&1 || true
  dnf clean all >/dev/null 2>&1 || true
elif command -v yum >/dev/null; then
  yum -y update >/dev/null 2>&1 || warning "Update failed"
  yum -y autoremove >/dev/null 2>&1 || true
  yum clean all >/dev/null 2>&1 || true
fi

status "Applying all changes…"
systemctl daemon-reload >/dev/null 2>&1 && success "Systemd daemon reloaded" || warning "Failed to reload systemd"

status "Current limits verification:"
echo -e "${BLUE}Session limits:${NC}"; ulimit -a | grep -E 'open files|processes|locked memory'
echo -e "\n${BLUE}System-wide limits:${NC}"; grep -E 'file-max|nr_open' /proc/sys/fs/ || true

echo -e "\n${GREEN}✔ Optimization complete!${NC}"
echo -e "${YELLOW}Some changes require a reboot to take full effect.${NC}"
echo -e "Reboot command: ${GREEN}reboot${NC}\n"
OPTIM

chmod +x /root/optimize.sh
green "Running optimize.sh…"
bash /root/optimize.sh

# ====== Step 2: Write and run depedency-lite.sh (as provided) ======
green "[2/5] Writing depedency-lite.sh…"
cat >/root/depedency-lite.sh <<'DEPS'
#!/bin/bash
set -euo pipefail

USERNAME=$(whoami)
ARCH=$(uname -m)
DOCKER_COMPOSE_VERSION="v2.26.1"

info(){ echo -e "\033[1;32m[INFO] $1\033[0m"; }
warn(){ echo -e "\033[1;33m[WARN] $1\033[0m"; }
error(){ echo -e "\033[1;31m[ERROR] $1\033[0m" >&2; exit 1; }
install_packages(){ info "Installing packages: $*"; sudo apt-get install -y "$@" || error "Failed to install: $*"; }
command_exists(){ command -v "$1" &>/dev/null; }

info "Checking system architecture..."
[ "$ARCH" = "x86_64" ] || warn "Non-x86_64 detected ($ARCH), some packages might need adjustment"

sudo -v || error "This script requires sudo privileges"

info "Updating system packages..."
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get autoremove -y

info "Installing essential build tools..."
install_packages \
  git clang cmake build-essential openssl pkg-config libssl-dev \
  wget htop tmux jq make gcc tar ncdu protobuf-compiler \
  default-jdk aptitude squid apache2-utils file lsof zip unzip \
  openssh-server sed lz4 aria2 pv \
  python3 python3-venv python3-pip python3-dev screen snapd flatpak \
  nano automake autoconf nvme-cli libgbm-dev libleveldb-dev bsdmainutils unzip \
  ca-certificates curl gnupg lsb-release software-properties-common

info "Checking Node.js installation..."
if command_exists node; then
  info "Node.js already installed: $(node --version)"
  info "npm already installed: $(npm --version)"
  info "Checking for Node.js LTS updates…"
  LATEST_NODE_VERSION=$(curl -fsSL https://nodejs.org/dist/latest-v18.x/SHASUMS256.txt | grep -oP 'node-v\K\d+\.\d+\.\d+-linux-x64' | head -1 | cut -d'-' -f1 || true)
  if [ -n "$LATEST_NODE_VERSION" ] && [ "$(node --version | cut -d'v' -f2)" != "$LATEST_NODE_VERSION" ]; then
    warn "Newer Node.js LTS available ($LATEST_NODE_VERSION). Consider: sudo npm i -g n && sudo n lts"
  fi
else
  info "Adding NodeSource repository…"
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - || error "NodeSource setup failed"
  install_packages nodejs
  command_exists node || error "Node.js installation failed"
  info "Updating npm to latest…"
  sudo npm install -g npm@latest || warn "Failed to update npm"
  info "Node.js: $(node --version) | npm: $(npm --version)"
fi

if ! command_exists yarn; then
  if grep -qi "ubuntu" /etc/os-release 2>/dev/null || uname -r | grep -qi "microsoft"; then
    info "Installing Yarn via apt…"
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
    sudo apt update && sudo apt install -y yarn
  else
    info "Installing Yarn globally with npm…"
    npm install -g --silent yarn
  fi
  command_exists yarn && info "Yarn: $(yarn --version)" || warn "Yarn installation might have failed"
else
  info "Yarn already installed: $(yarn --version)"
fi

info "Checking Docker installation…"
if ! command_exists docker; then
  info "Installing Docker Engine & plugins…"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USERNAME" || true
  info "Docker installed."
else
  info "Docker already installed: $(docker --version)"
fi

info "Checking Docker Compose (standalone)…"
if ! command_exists docker-compose; then
  info "Installing docker-compose ${DOCKER_COMPOSE_VERSION}…"
  sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
  command_exists docker-compose && info "docker-compose: $(docker-compose --version)" || warn "docker-compose install might have failed"
else
  info "docker-compose already installed: $(docker-compose --version)"
fi

info "=== Installed Versions ==="
info "Node.js: $(node --version 2>/dev/null || echo 'Not installed')"
info "npm: $(npm --version 2>/dev/null || echo 'Not installed')"
info "Yarn: $(yarn --version 2>/dev/null || echo 'Not installed')"
info "Docker: $(docker --version 2>/dev/null || echo 'Not installed')"
info "Docker Compose(plugin): $(docker compose version 2>/dev/null | head -n1 || echo 'Not installed')"
info "docker-compose(standalone): $(docker-compose --version 2>/dev/null || echo 'Not installed')"

info "Dependency installation complete."
DEPS

chmod +x /root/depedency-lite.sh
green "Running depedency-lite.sh…"
bash /root/depedency-lite.sh

# ====== Step 3: Create directories & JWT ======
green "[3/5] Creating Ethereum directories and JWT…"
mkdir -p /root/ethereum/execution
mkdir -p /root/ethereum/consensus
if [ ! -f /root/ethereum/jwt.hex ]; then
  openssl rand -hex 32 > /root/ethereum/jwt.hex
fi

# ====== Step 4: Write docker-compose.yml (Sepolia: geth + prysm) ======
green "[4/5] Writing /root/ethereum/docker-compose.yml…"
cat >/root/ethereum/docker-compose.yml <<'YAML'
services:
  geth:
    image: ethereum/client-go:stable
    container_name: geth
    network_mode: host
    restart: unless-stopped
    ports:
      - 30303:30303
      - 30303:30303/udp
      - 8545:8545
      - 8546:8546
      - 8551:8551
    volumes:
      - /root/ethereum/execution:/data
      - /root/ethereum/jwt.hex:/data/jwt.hex
    command:
      - --sepolia
      - --http
      - --http.api=eth,net,web3
      - --http.addr=0.0.0.0
      - --authrpc.addr=0.0.0.0
      - --authrpc.vhosts=*
      - --authrpc.jwtsecret=/data/jwt.hex
      - --authrpc.port=8551
      - --syncmode=snap
      - --datadir=/data
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  prysm:
    image: gcr.io/prysmaticlabs/prysm/beacon-chain
    container_name: prysm
    network_mode: host
    restart: unless-stopped
    volumes:
      - /root/ethereum/consensus:/data
      - /root/ethereum/jwt.hex:/data/jwt.hex
    depends_on:
      - geth
    ports:
      - 4000:4000
      - 3500:3500
    command:
      - --sepolia
      - --accept-terms-of-use
      - --datadir=/data
      - --disable-monitoring
      - --rpc-host=0.0.0.0
      - --execution-endpoint=http://127.0.0.1:8551
      - --jwt-secret=/data/jwt.hex
      - --rpc-port=4000
      - --grpc-gateway-corsdomain=*
      - --grpc-gateway-host=0.0.0.0
      - --grpc-gateway-port=3500
      - --min-sync-peers=3
      - --checkpoint-sync-url=https://checkpoint-sync.sepolia.ethpandaops.io
      - --genesis-beacon-api-url=https://checkpoint-sync.sepolia.ethpandaops.io
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
YAML

# ====== Step 5: Bring up with Docker Compose ======
green "[5/5] Starting Docker Compose…"
cd /root/ethereum

# Prefer plugin "docker compose", fallback to standalone "docker-compose"
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  red "Docker Compose not found. Please reinstall dependencies."; exit 1
fi

$COMPOSE_CMD up -d

green "All set! Sepolia geth + prysm are running."

echo
echo "Useful commands:"
echo "  $COMPOSE_CMD -f /root/ethereum/docker-compose.yml ps"
echo "  docker logs -f geth"
echo "  docker logs -f prysm"
echo
echo "JSON-RPC (execution):   http://<your-server-ip>:8545"
echo "Auth RPC (engine API):  http://<your-server-ip>:8551"
echo "Prysm RPC:              http://<your-server-ip>:4000"
echo "Prysm gRPC-Gateway:     http://<your-server-ip>:3500"
