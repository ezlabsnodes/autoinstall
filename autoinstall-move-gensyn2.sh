#!/usr/bin/env bash
set -Eeuo pipefail

# ===== UI helpers =====
GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; BLUE='\033[0;34m'; NC='\033[0m'
ok(){ echo -e "${GREEN}$*${NC}"; }
warn(){ echo -e "${YELLOW}$*${NC}"; }
err(){ echo -e "${RED}$*${NC}" >&2; }
status(){ echo -e "\n${BLUE}>>> $*${NC}"; }
trap 'err "Error on line $LINENO. Exiting."' ERR

# Elevate to root if needed
if [ "$EUID" -ne 0 ]; then
  echo "[INFO] Elevating to root…"
  exec sudo -E bash "$0" "$@"
fi
export DEBIAN_FRONTEND=noninteractive

# Resolve invoking user/home
ORIG_USER=${SUDO_USER:-$(logname 2>/dev/null || whoami)}
ORIG_HOME=$(getent passwd "$ORIG_USER" | cut -d: -f6)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# =========================================================
# STEP 1 — CREATE 100G SWAP + OPTIMIZE (REPLACED WITH YOUR SCRIPTS)
# =========================================================
status "[1/4] Creating 100GB swap and optimizing system…"

# (1a) Create 100G swap (exact content you provided)
cat > /usr/local/bin/create-swap-100g.sh <<'SWAP_SCRIPT'
#!/bin/bash
set -euo pipefail

# ==========================================
# Fungsi-fungsi utilitas
# ==========================================
function message() {
    echo -e "\033[0;32m[INFO] $1\033[0m"
}

function warning() {
    echo -e "\033[0;33m[WARN] $1\033[0m"
}

function error() {
    echo -e "\033[0;31m[ERROR] $1\033[0m" >&2
    exit 1
}

# ==========================================
# 1. Verifikasi Environment
# ==========================================
message "Memulai konfigurasi swapfile custom"

# Cek root
if [[ $EUID -ne 0 ]]; then
    error "Script harus dijalankan sebagai root"
fi

# ==========================================
# 2. Ukuran Swap Custom (Otomatis 100G)
# ==========================================
SWAP_SIZE="100G"
SWAPFILE="/swapfile"

message "Swapfile otomatis diatur ke $SWAP_SIZE"

# ==========================================
# 3. Informasi Sistem
# ==========================================
message "\nInformasi sistem:"
TOTAL_RAM_GB=$(free -g | awk '/Mem:/ {print $2}')
if [ "$TOTAL_RAM_GB" -eq 0 ]; then
    TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
    TOTAL_RAM_GB=$(( (TOTAL_RAM_MB + 1023) / 1024 ))
fi

echo " - Total RAM: ${TOTAL_RAM_GB}GB"
echo " - Ukuran swapfile yang akan dibuat: $SWAP_SIZE"

# ==========================================
# 4. Setup Swapfile
# ==========================================
message "\nMenonaktifkan swap yang aktif..."
if swapon --show | grep -q "swap"; then
    swapoff -a || warning "Gagal menonaktifkan beberapa swap aktif."
    message "Semua swap aktif telah dinonaktifkan."
else
    warning "Tidak ada swap aktif yang terdeteksi."
fi

if [[ -f "$SWAPFILE" ]]; then
    message "Menghapus swapfile lama: $SWAPFILE..."
    rm -f "$SWAPFILE" || error "Gagal menghapus swapfile lama."
fi

message "Membuat swapfile baru ($SWAP_SIZE) di $SWAPFILE..."
if ! fallocate -l "$SWAP_SIZE" "$SWAPFILE"; then
    warning "fallocate gagal, mencoba dd..."
    NUMERIC_SIZE=100
    dd if=/dev/zero of="$SWAPFILE" bs=1G count=$NUMERIC_SIZE status=progress ||
        error "Gagal membuat swapfile dengan dd."
fi

chmod 600 "$SWAPFILE" || error "Gagal mengatur permission swapfile."
mkswap "$SWAPFILE" || error "Gagal memformat swapfile."
swapon "$SWAPFILE" || error "Gagal mengaktifkan swapfile."
message "Swapfile aktif."

# ==========================================
# 5. Konfigurasi Permanen
# ==========================================
message "\nMembackup /etc/fstab..."
cp /etc/fstab "/etc/fstab.backup_$(date +%Y%m%d_%H%M%S)" || error "Backup gagal."

if ! grep -q "^${SWAPFILE}" /etc/fstab; then
    echo "${SWAPFILE} none swap sw 0 0" | tee -a /etc/fstab > /dev/null
    message "Swapfile ditambahkan ke /etc/fstab."
else
    sed -i "s|^${SWAPFILE}.*|${SWAPFILE} none swap sw 0 0|" /etc/fstab || error "Update fstab gagal."
    message "Swapfile diupdate di /etc/fstab."
fi

# ==========================================
# 6. Verifikasi
# ==========================================
message "\nVerifikasi hasil:"
swapon --show
free -h
ls -lh "$SWAPFILE"

cat <<EOF

==========================================
KONFIGURASI SWAPFILE SELESAI

Detail:
- Lokasi: $SWAPFILE
- Ukuran: $SWAP_SIZE
- RAM: ${TOTAL_RAM_GB}GB

Verifikasi manual:
free -h
swapon --show
==========================================
EOF

message "Script selesai."
SWAP_SCRIPT
chmod +x /usr/local/bin/create-swap-100g.sh
/usr/local/bin/create-swap-100g.sh

# (1b) Optimize system (exact content you provided)
cat > /usr/local/bin/optimize-system.sh <<'OPT_SCRIPT'
#!/bin/bash
set -e

# ==============================================
# 1. FIRST DEFINE ALL FUNCTIONS AND VARIABLES
# ==============================================

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Status functions
status() { echo -e "\n${BLUE}>>> $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warning() { echo -e "${YELLOW}⚠ $*${NC}"; }
error() { echo -e "${RED}✗ $*${NC}"; exit 1; }

# System services to disable
SERVICES_TO_DISABLE=(
    avahi-daemon
    cups
    bluetooth
    ModemManager
)

# ==============================================
# 2. MAIN SCRIPT LOGIC
# ==============================================

# Check root
if [ "$(id -u)" -ne 0 ]; then
    error "Script must be run as root. Use sudo or switch to root user."
fi

# 1. System Limits Optimization
status "Optimizing system limits..."

# Configure system-wide limits
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

# Apply immediate session limits
ulimit -n 1048576 >/dev/null 2>&1 || warning "Couldn't increase current session limits (reboot required)"
success "Attempted to set immediate file descriptor limit"

# Configure systemd limits
mkdir -p /etc/systemd/system.conf.d/
cat <<EOF > /etc/systemd/system.conf.d/limits.conf
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
DefaultLimitMEMLOCK=infinity
EOF
success "Configured systemd limits"

# Configure pam limits
if [ -f /etc/pam.d/common-session ] && ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
    echo "session required pam_limits.so" >> /etc/pam.d/common-session
    success "Added PAM limits configuration"
elif [ ! -f /etc/pam.d/common-session ]; then
    warning "PAM common-session file not found"
else
    success "PAM limits already configured (skipped)"
fi

# 2. Kernel Parameters Optimization
status "Optimizing kernel parameters..."

if [ ! -f /etc/sysctl.d/99-kuzco.conf ]; then
    cat <<EOF > /etc/sysctl.d/99-kuzco.conf
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
    sysctl -p /etc/sysctl.d/99-kuzco.conf >/dev/null 2>&1
    success "Kernel parameters optimized"
else
    success "Kernel parameters already optimized (skipped)"
fi

# 3. Disable Unnecessary Services
status "Disabling unnecessary services..."

for service in "${SERVICES_TO_DISABLE[@]}"; do
    if systemctl is-enabled "$service" 2>/dev/null | grep -q "enabled"; then
        systemctl disable --now "$service" >/dev/null 2>&1 && \
            success "Disabled $service" || \
            warning "Failed to disable $service"
    else
        success "$service already disabled (skipped)"
    fi
done

# 4. Final System Updates
status "Performing final updates..."

if command -v apt-get >/dev/null; then
    apt-get update >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get -y upgrade >/dev/null 2>&1 || warning "Update failed"
    apt-get -y autoremove >/dev/null 2>&1
    apt-get clean >/dev/null 2>&1
elif command -v yum >/dev/null; then
    yum -y update >/dev/null 2>&1 || warning "Update failed"
    yum -y autoremove >/dev/null 2>&1
    yum clean all >/dev/null 2>&1
elif command -v dnf >/dev/null; then
    dnf -y update >/dev/null 2>&1 || warning "Update failed"
    dnf -y autoremove >/dev/null 2>&1
fi

# 5. Apply All Changes
status "Applying all changes..."
systemctl daemon-reload >/dev/null 2>&1 && \
    success "Systemd daemon reloaded" || \
    warning "Failed to reload systemd daemon"

# Verification
status "Current limits verification:"
echo -e "${BLUE}Session limits:${NC}"
ulimit -a | grep -E 'open files|processes|locked memory'
echo -e "\n${BLUE}System-wide limits:${NC}"
grep -E 'file-max|nr_open' /proc/sys/fs/

# Final message
echo -e "\n${GREEN}✔ Optimization complete!${NC}"
echo -e "${YELLOW}Some changes require a reboot to take full effect.${NC}"
echo -e "Run this command to reboot: ${GREEN}reboot${NC}"

echo -e "\n${BLUE}Verification commands after reboot:${NC}"
echo "1. Check file limits: ${GREEN}ulimit -n${NC} (should show 1048576)"
echo "2. Check kernel settings: ${GREEN}sysctl -a | grep -e file_max -e swappiness${NC}"
echo "3. Check disabled services: ${GREEN}systemctl list-unit-files | grep -E 'avahi|cups|bluetooth|ModemManager'${NC}"
OPT_SCRIPT
chmod +x /usr/local/bin/optimize-system.sh
/usr/local/bin/optimize-system.sh

# =========================================================
# STEP 2 — INSTALL DEPENDENCIES (Node.js, Yarn, Docker, Compose)
# =========================================================
status "[2/4] Installing dependencies…"

cat > /usr/local/bin/ez-deps.sh <<'EODEPS'
#!/usr/bin/env bash
set -euo pipefail
info(){ echo -e "\033[1;32m[INFO] $1\033[0m"; }
warn(){ echo -e "\033[1;33m[WARN] $1\033[0m"; }
error(){ echo -e "\033[1;31m[ERROR] $1\033[0m" >&2; exit 1; }
install_packages(){ info "Installing packages: $*"; sudo apt-get install -y "$@" || error "Failed to install: $*"; }
command_exists(){ command -v "$1" &>/dev/null; }

USERNAME=$(whoami); ARCH=$(uname -m); DOCKER_COMPOSE_VERSION="v2.26.1"

info "Checking system architecture…"
[ "$ARCH" = "x86_64" ] || warn "Non-x86_64 detected ($ARCH)."

sudo -v || error "This script requires sudo privileges"

info "Updating system packages…"
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get autoremove -y

info "Installing essential build tools…"
install_packages \
  git clang cmake build-essential openssl pkg-config libssl-dev \
  wget htop tmux jq make gcc tar ncdu protobuf-compiler \
  default-jdk aptitude squid apache2-utils file lsof zip unzip \
  openssh-server sed lz4 aria2 pv \
  python3 python3-venv python3-pip python3-dev screen snapd flatpak \
  nano automake autoconf nvme-cli libgbm-dev libleveldb-dev bsdmainutils unzip \
  ca-certificates curl gnupg lsb-release software-properties-common

info "Checking Node.js…"
if command_exists node; then
  info "Node: $(node --version) | npm: $(npm --version)"
  LATEST_NODE_VERSION=$(curl -fsSL https://nodejs.org/dist/latest-v18.x/SHASUMS256.txt | grep -oP 'node-v\K\d+\.\d+\.\d+-linux-x64' | head -1 | cut -d'-' -f1 || true)
  if [ -n "${LATEST_NODE_VERSION:-}" ] && [ "$(node --version | cut -d'v' -f2)" != "$LATEST_NODE_VERSION" ]; then
    warn "Newer Node.js available ($LATEST_NODE_VERSION). Consider: sudo npm i -g n && sudo n lts"
  fi
else
  info "Adding NodeSource repository…"
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - || error "Nodesource setup failed"
  install_packages nodejs
  command_exists node || error "Node.js failed to install"
  info "Updating npm to latest…"; sudo npm i -g npm@latest || warn "npm update failed"
  info "Node: $(node --version) | npm: $(npm --version)"
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
  command_exists yarn && info "Yarn: $(yarn --version)" || warn "Yarn install may have failed"
else
  info "Yarn: $(yarn --version)"
fi

info "Checking Docker…"
if ! command_exists docker; then
  info "Installing Docker Engine…"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USERNAME" || true
  info "Docker installed."
else
  info "Docker: $(docker --version)"
fi

info "Checking Docker Compose…"
if ! command_exists docker-compose; then
  info "Installing Docker Compose standalone…"
  sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
  command_exists docker-compose && info "Compose: $(docker-compose --version)" || warn "Compose install may have failed"
else
  info "Compose: $(docker-compose --version)"
fi

info "=== Installed Versions ==="
info "Node.js: $(node --version 2>/dev/null || echo 'Not installed')"
info "npm: $(npm --version 2>/dev/null || echo 'Not installed')"
info "Yarn: $(yarn --version 2>/dev/null || echo 'Not installed')"
info "Docker: $(docker --version 2>/dev/null || echo 'Not installed')"
info "Docker Compose: $(docker-compose --version 2>/dev/null || echo 'Not installed')"
EODEPS
chmod +x /usr/local/bin/ez-deps.sh
/usr/local/bin/ez-deps.sh

# Ensure extras for gensyn
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y expect unzip >/dev/null 2>&1 || true

# =========================================================
# STEP 3 — ENSURE /root/ezlabs & REQUIRED FILES (with 5-min wait)
# =========================================================
status "[3/4] Ensuring /root/ezlabs and required keys…"
EZDIR="/root/ezlabs"
mkdir -p "$EZDIR"

WAIT_SECS=300   # 5 minutes
POLL_SECS=5

declare -A FILES
FILES=( ["swarm.pem"]="swarm.pem"
        ["userApiKey.json"]="userApiKey.json"
        ["userData.json"]="userData.json" )

candidates_for(){
  local f="$1"
  case "$f" in
    swarm.pem)
      echo "$EZDIR/swarm.pem" \
           "$ORIG_HOME/rl-swarm/swarm.pem" \
           "$SCRIPT_DIR/swarm.pem" \
           "$ORIG_HOME/ezlabs/swarm.pem" \
           "$PWD/swarm.pem"
      ;;
    userApiKey.json)
      echo "$EZDIR/userApiKey.json" \
           "$ORIG_HOME/rl-swarm/modal-login/temp-data/userApiKey.json" \
           "$SCRIPT_DIR/userApiKey.json" \
           "$ORIG_HOME/ezlabs/userApiKey.json" \
           "$PWD/userApiKey.json"
      ;;
    userData.json)
      echo "$EZDIR/userData.json" \
           "$ORIG_HOME/rl-swarm/modal-login/temp-data/userData.json" \
           "$SCRIPT_DIR/userData.json" \
           "$ORIG_HOME/ezlabs/userData.json" \
           "$PWD/userData.json"
      ;;
  esac
}

copy_if_found(){
  local dest="$EZDIR/$1"; shift
  for src in "$@"; do
    if [[ "$src" == "$dest" && -f "$dest" ]]; then return 0; fi
    if [ -f "$src" ]; then
      cp -f "$src" "$dest"
      ok "Copied $(basename "$dest") from: $src"
      return 0
    fi
  done
  return 1
}

list_missing(){
  missing=()
  for key in "${!FILES[@]}"; do
    local dest="$EZDIR/${FILES[$key]}"
    [ -f "$dest" ] || missing+=("$dest")
  done
}

attempt_autofill(){
  for key in "${!FILES[@]}"; do
    local base="${FILES[$key]}"
    local dest="$EZDIR/$base"
    [ -f "$dest" ] && continue
    mapfile -t CANDS < <(candidates_for "$base")
    copy_if_found "$base" "${CANDS[@]}" || true
  done
}

# Initial attempt to auto-copy (silent except success lines)
attempt_autofill
list_missing

if ((${#missing[@]})); then
  echo -e "\n${YELLOW}Waiting up to 5 minutes for copy the following files${NC}"
  echo -e "${RED}Please Copy  ${missing[*]//"$EZDIR/"/}  into ${EZDIR}${NC}"

  deadline=$(( $(date +%s) + WAIT_SECS ))
  while :; do
    attempt_autofill
    list_missing
    if ((${#missing[@]} == 0)); then
      echo -e "${GREEN}All required files detected in ${EZDIR}. Proceeding to Step 4…${NC}"
      break
    fi

    now=$(date +%s); remaining=$((deadline - now))
    if (( remaining <= 0 )); then
      echo -e "\n${RED}Timeout waiting for files.${NC}"
      echo -e "${RED}Please Copy  ${missing[*]//"$EZDIR/"/}  into ${EZDIR}${NC}"
      echo -e "\nAfter copying, re-run: ${GREEN}./$(basename "$0")${NC}\n"
      exit 1
    fi

    echo -e "\r${YELLOW}Waiting... ${remaining}s left. ${RED}Please Copy  ${missing[*]//"$EZDIR/"/}  into ${EZDIR}${NC}   "
    sleep "$POLL_SECS"
  done
else
  echo -e "${GREEN}All required files already in ${EZDIR}. Proceeding to Step 4…${NC}"
fi

# =========================================================
# STEP 4 — RUN GENSYN NODE (systemd launcher)
# =========================================================
status "[4/4] Starting Gensyn node via systemd.sh…"
bash -lc 'cd && rm -rf officialauto.zip systemd.sh && wget -O systemd.sh https://raw.githubusercontent.com/ezlabsnodes/gensyn/main/systemd.sh && chmod +x systemd.sh && ./systemd.sh'

ok "Gensyn systemd unit deployed."

echo
echo -e "${BLUE}Follow live logs:${NC}   journalctl -u rl-swarm -f -o cat"
echo -e "${BLUE}All logs:${NC}         cat ~/rl-swarm/logs/swarm_launcher.log"
