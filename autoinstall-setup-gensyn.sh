#!/usr/bin/env bash
set -Eeuo pipefail

# ===== UI helpers =====
GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; BLUE='\033[0;34m'; NC='\033[0m'
ok(){ echo -e "${GREEN}[OK] $*${NC}"; }
warn(){ echo -e "${YELLOW}[WARN] $*${NC}"; }
err(){ echo -e "${RED}[ERR] $*${NC}" >&2; }
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
# STEP 1 — CREATE SWAP (AUTO 50G) + OPTIMIZE SYSTEM
# =========================================================
status "[1/4] Creating swap (auto 50G) and optimizing system…"

# (1a) Create swap (AUTO 50G, no prompt; can override with SWAP_SIZE or argv)
cat > /usr/local/bin/create-swap-100g.sh <<'SWAP_SCRIPT'
#!/bin/bash
set -euo pipefail

# ===== Helpers (kept) =====
message(){ echo -e "\033[0;32m[INFO] $1\033[0m"; }
warning(){ echo -e "\033[0;33m[WARN] $1\033[0m"; }
error(){ echo -e "\033[0;31m[ERROR] $1\033[0m" >&2; exit 1; }

# Require root
[[ $EUID -eq 0 ]] || error "This script must be run as root"

SWAPFILE="/swapfile"
# Default 50G; allow override via env SWAP_SIZE or argv $1 (e.g., SWAP_SIZE=64G ./create-swap-100g.sh or ./create-swap-100g.sh 64G)
SWAP_SIZE="${SWAP_SIZE:-${1:-50G}}"
[[ "$SWAP_SIZE" =~ ^[0-9]+[GgMm]$ ]] || error "Invalid SWAP_SIZE: use e.g. 50G or 5120M"

message "Swapfile target: $SWAPFILE  |  Size: $SWAP_SIZE (auto mode)"

# System info
TOTAL_RAM_GB=$(free -g | awk '/Mem:/ {print $2}')
if [ "${TOTAL_RAM_GB:-0}" -eq 0 ]; then
  TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
  TOTAL_RAM_GB=$(( (TOTAL_RAM_MB + 1023) / 1024 ))
fi
message "RAM detected: ${TOTAL_RAM_GB}GB"

# Space check
ROOT_AVAIL_BYTES=$(df --output=avail -B1 / | tail -1)
case "$SWAP_SIZE" in
  *[Gg]) REQ_BYTES=$(( ${SWAP_SIZE%[Gg]} * 1024 * 1024 * 1024 ));;
  *[Mm]) REQ_BYTES=$(( ${SWAP_SIZE%[Mm]} * 1024 * 1024 ));;
esac
if (( ROOT_AVAIL_BYTES <= REQ_BYTES )); then
  warning "Free disk space may be insufficient for $SWAP_SIZE; continuing anyway."
fi

# Disable old swap & remove old file
message "Disabling active swap (if any)…"
swapoff -a || true
[ -f "$SWAPFILE" ] && { message "Removing old $SWAPFILE"; rm -f "$SWAPFILE"; }

# Create swapfile
message "Creating $SWAP_SIZE at $SWAPFILE…"
if ! fallocate -l "$SWAP_SIZE" "$SWAPFILE"; then
  warning "fallocate failed, fallback to dd"
  if [[ "$SWAP_SIZE" =~ ^([0-9]+)[Gg]$ ]]; then
    dd if=/dev/zero of="$SWAPFILE" bs=1G count="${BASH_REMATCH[1]}" status=progress
  else
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="${SWAP_SIZE%[Mm]}" status=progress
  fi
fi

chmod 600 "$SWAPFILE"
mkswap "$SWAPFILE"
swapon "$SWAPFILE"
message "Swapfile enabled."

# Persist
cp /etc/fstab "/etc/fstab.backup_$(date +%Y%m%d_%H%M%S)" || true
if ! grep -q "^${SWAPFILE} " /etc/fstab; then
  echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
else
  sed -i "s|^${SWAPFILE}.*|${SWAPFILE} none swap sw 0 0|" /etc/fstab
fi

# Verify
message "Verification:"
swapon --show || true
free -h || true
ls -lh "$SWAPFILE" || true

message "Done."
SWAP_SCRIPT
chmod +x /usr/local/bin/create-swap-100g.sh
/usr/local/bin/create-swap-100g.sh   # <- auto 50G, no prompt

# (1b) Optimize system (unchanged)
cat > /usr/local/bin/optimize-system.sh <<'OPT_SCRIPT'
#!/bin/bash
set -e

# ==============================================
# 1. FIRST DEFINE ALL FUNCTIONS AND VARIABLES
# ==============================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
status() { echo -e "\n${BLUE}>>> $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warning() { echo -e "${YELLOW}⚠ $*${NC}"; }
error() { echo -e "${RED}✗ $*${NC}"; exit 1; }

SERVICES_TO_DISABLE=( avahi-daemon cups bluetooth ModemManager )

# ==============================================
# 2. MAIN SCRIPT LOGIC
# ==============================================
[ "$(id -u)" -eq 0 ] || error "Script must be run as root. Use sudo or switch to root user."

# 1. System Limits Optimization
status "Optimizing system limits…"

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

ulimit -n 1048576 >/dev/null 2>&1 || warning "Couldn't increase current session limits (reboot required)"
success "Attempted to set immediate file descriptor limit"

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

# 2. Kernel Parameters Optimization
status "Optimizing kernel parameters…"
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

# IPC
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
status "Disabling unnecessary services…"
for service in "${SERVICES_TO_DISABLE[@]}"; do
  if systemctl is-enabled "$service" 2>/dev/null | grep -q "enabled"; then
    systemctl disable --now "$service" >/dev/null 2>&1 && success "Disabled $service" || warning "Failed to disable $service"
  else
    success "$service already disabled (skipped)"
  fi
done

# 4. Final System Updates
status "Performing final updates…"
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
status "Applying all changes…"
systemctl daemon-reload >/dev/null 2>&1 && success "Systemd daemon reloaded" || warning "Failed to reload systemd daemon"

# Verification
status "Current limits verification:"
echo -e "${BLUE}Session limits:${NC}"
ulimit -a | grep -E 'open files|processes|locked memory' || true
echo -e "\n${BLUE}System-wide limits:${NC}"
cat /proc/sys/fs/file-max /proc/sys/fs/nr_open 2>/dev/null || true

echo -e "\n${GREEN}✔ Optimization complete!${NC}"
echo -e "${YELLOW}Some changes require a reboot to take full effect.${NC}"
echo -e "Run this command to reboot: ${GREEN}reboot${NC}"

echo -e "\n${BLUE}Verification after reboot:${NC}"
echo "1) ulimit -n   (expect 1048576)"
echo "2) sysctl -a | grep -e file_max -e swappiness"
echo "3) systemctl list-unit-files | grep -E 'avahi|cups|bluetooth|ModemManager'"
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
install_packages(){ info "Installing packages: $*"; apt-get install -y "$@" || error "Failed to install: $*"; }
command_exists(){ command -v "$1" &>/dev/null; }

ARCH=$(uname -m)
info "Checking architecture: $ARCH"
apt-get update -y && apt-get upgrade -y
apt-get autoremove -y

info "Installing essential build tools…"
install_packages git clang cmake build-essential openssl pkg-config libssl-dev \
  wget htop tmux jq make gcc tar ncdu protobuf-compiler default-jdk aptitude \
  squid apache2-utils file lsof zip unzip openssh-server sed lz4 aria2 pv \
  python3 python3-venv python3-pip python3-dev screen snapd flatpak nano \
  automake autoconf nvme-cli libgbm-dev libleveldb-dev bsdmainutils ca-certificates \
  curl gnupg lsb-release software-properties-common

info "Checking Node.js…"
if command_exists node; then
  info "Node: $(node --version) | npm: $(npm --version)"
else
  info "Adding NodeSource (LTS)…"
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - || error "Nodesource setup failed"
  install_packages nodejs
  command_exists node || error "Node.js failed to install"
  info "Updating npm to latest…"; npm i -g npm@latest || warn "npm update failed"
  info "Node: $(node --version) | npm: $(npm --version)"
fi

info "Checking Yarn…"
if ! command_exists yarn; then
  # Prefer apt repo for Ubuntu
  curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor >/usr/share/keyrings/yarn-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/yarn-archive-keyring.gpg] https://dl.yarnpkg.com/debian/ stable main" > /etc/apt/sources.list.d/yarn.list
  apt-get update && apt-get install -y yarn || { info "Fallback to npm"; npm i -g yarn; }
fi
info "Yarn: $(yarn --version 2>/dev/null || echo 'Not installed')"

info "Checking Docker…"
if ! command_exists docker; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  usermod -aG docker "${SUDO_USER:-$USER}" || true
fi
info "$(docker --version 2>/dev/null || echo 'Docker not installed')"

info "Checking Docker Compose (standalone)…"
if ! command_exists docker-compose; then
  DCV="v2.26.1"
  curl -L "https://github.com/docker/compose/releases/download/${DCV}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi
info "$(docker-compose --version 2>/dev/null || echo 'docker-compose not installed')"

info "=== Installed Versions ==="
info "Node.js: $(node --version 2>/dev/null || echo 'N/A')"
info "npm: $(npm --version 2>/dev/null || echo 'N/A')"
info "Yarn: $(yarn --version 2>/dev/null || echo 'N/A')"
info "Docker: $(docker --version 2>/dev/null || echo 'N/A')"
info "Docker Compose: $(docker-compose --version 2>/dev/null || echo 'N/A')"
EODEPS
chmod +x /usr/local/bin/ez-deps.sh
/usr/local/bin/ez-deps.sh

# Ensure extras for gensyn
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y expect unzip >/dev/null 2>&1 || true

# =========================================================
# STEP 3 — PREP & FETCH RL-SWARM PACKAGE (SAFE, IDEMPOTENT)
# =========================================================
status "[3/4] Preparing runtime and packaging…"

# helper for safe copy using top-level ok/warn
safe_cp() {
  # safe_cp <src> <dst_dir>
  local src="$1"; local dst="$2"
  if [ -f "$src" ]; then
    mkdir -p "$dst"
    cp -f "$src" "$dst"/
    ok "Copied $(basename "$src") -> $dst/"
  else
    warn "Missing $src (skipped)"
  fi
}

# Stop systemd service if exists
status "Stopping rl-swarm.service if present…"
systemctl stop rl-swarm.service 2>/dev/null || true
systemctl daemon-reload || true

# Preserve temp data/keys if any
mkdir -p "$HOME/ezlabs"
safe_cp "$HOME/rl-swarm/modal-login/temp-data/userApiKey.json" "$HOME/ezlabs"
safe_cp "$HOME/rl-swarm/modal-login/temp-data/userData.json" "$HOME/ezlabs"
safe_cp "$HOME/rl-swarm/swarm.pem" "$HOME/ezlabs"

# Close existing screen session safely
if screen -S gensyn -Q select . >/dev/null 2>&1; then
  screen -S gensyn -X quit || true
  ok "Closed existing 'gensyn' screen"
fi

# Cleanup old repo and archives
status "Cleaning old rl-swarm & archives…"
cd "$HOME"
rm -rf rl-swarm \
       officialauto.zip nonofficialauto.zip original.zip original2.zip \
       ezlabs.zip ezlabs2.zip ezlabs3.zip ezlabs4.zip ezlabs5.zip ezlabs6.zip \
       ezlabs7.zip ezlabs8.zip qwen2-official.zip

# Fetch fresh package
status "Fetching rl-swarm package…"
wget -q https://github.com/ezlabsnodes/gensyn/raw/refs/heads/main/qwen2-official.zip -O qwen2-official.zip
unzip -o qwen2-official.zip >/dev/null
[ -d "$HOME/rl-swarm" ] || { err "Unzip did not produce ~/rl-swarm"; exit 1; }

# Restore preserved files (if any)
safe_cp "$HOME/ezlabs/swarm.pem" "$HOME/rl-swarm"
safe_cp "$HOME/ezlabs/userApiKey.json" "$HOME/rl-swarm/modal-login/temp-data"
safe_cp "$HOME/ezlabs/userData.json" "$HOME/rl-swarm/modal-login/temp-data"

# =========================================================
# STEP 4 — LAUNCH RL-SWARM IN SCREEN
# =========================================================
status "[4/4] Launching rl-swarm in screen…"
cd "$HOME/rl-swarm"

# Ensure venv + permissions
python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
chmod +x run_rl_swarm.sh

# Run inside a fresh screen (CPU-only toggle preserved)
screen -S gensyn -dm bash -lc 'source .venv/bin/activate && CPU_ONLY=true ./run_rl_swarm.sh'

ok "Launch request sent to screen session 'gensyn'."

echo -e "\nLog tails you may want:"
echo "  tail -f \"$HOME/rl-swarm/logs/swarm_launcher.log\""
echo "  screen -r gensyn          # attach"
echo "  screen -S gensyn -X quit  # stop session"
