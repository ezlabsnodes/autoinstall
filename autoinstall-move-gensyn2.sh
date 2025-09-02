#!/usr/bin/env bash
set -Eeuo pipefail

# ============ Pretty logs ============
ok(){ echo -e "\033[1;32m$*\033[0m"; }
warn(){ echo -e "\033[1;33m$*\033[0m"; }
err(){ echo -e "\033[1;31m$*\033[0m" >&2; }
trap 'err "Error on line $LINENO. Exiting."' ERR

# Re-exec as root (we’ll still run user-specific steps as the original user)
if [ "$EUID" -ne 0 ]; then
  echo "[INFO] Elevating to root…"
  exec sudo -E bash "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive

# Resolve original user/home (so user files aren’t moved to /root)
ORIG_USER=${SUDO_USER:-$(logname 2>/dev/null || whoami)}
ORIG_HOME=$(getent passwd "$ORIG_USER" | cut -d: -f6)

# ============ Step 1: Swap 100GB + optimization (write exact content then run) ============
ok "[1/3] Writing swap/optimize script…"
cat > /usr/local/bin/kuzco-swap-heavy-and-ram-cap.sh <<'SWAPOPT'
#!/usr/bin/env bash
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
status(){ echo -e "\n${BLUE}>>> $*${NC}"; }
success(){ echo -e "${GREEN}✓ $*${NC}"; }
warning(){ echo -e "${YELLOW}⚠ $*${NC}"; }
error(){ echo -e "${RED}✗ $*${NC}"; exit 1; }
SERVICES_TO_DISABLE=(avahi-daemon cups bluetooth ModemManager)
[ "$(id -u)" -eq 0 ] || error "Run as root (sudo)."

if ! pidof systemd >/dev/null 2>&1; then warning "No systemd detected. RAM cap parts will be skipped."; fi
CGROUP_V2=0
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then CGROUP_V2=1; success "cgroup v2 detected."; else warning "cgroup v2 not detected."; fi

status "Optimizing system limits..."
if ! grep -q "# Kuzco Optimization" /etc/security/limits.conf 2>/dev/null; then
  cat <<'EOF' >> /etc/security/limits.conf

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
ulimit -n 1048576 >/dev/null 2>&1 || warning "Couldn't increase current session limits (reboot may be required)."
mkdir -p /etc/systemd/system.conf.d/
cat <<'EOF' > /etc/systemd/system.conf.d/limits.conf
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
DefaultLimitMEMLOCK=infinity
EOF
success "Configured systemd limits"
if [ -f /etc/pam.d/common-session ] && ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
  echo "session required pam_limits.so" >> /etc/pam.d/common-session
  success "Added PAM limits configuration"
else
  success "PAM limits already configured or not applicable (skipped)"
fi

status "Optimizing kernel parameters for swap-heavy behavior..."
if [ ! -f /etc/sysctl.d/99-kuzco.conf ]; then
  cat <<'EOF' > /etc/sysctl.d/99-kuzco.conf
# Network
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.ip_local_port_range=1024 65535

# Memory — Aggressive swap + stable caches
vm.swappiness=100
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.overcommit_memory=1
vm.overcommit_ratio=80
vm.page-cluster=0
vm.watermark_scale_factor=200

# File handles
fs.file-max=1048576
fs.nr_open=1048576

# IPC
kernel.msgmax=65536
kernel.msgmnb=65536
kernel.shmall=4294967296
kernel.shmmax=17179869184

# Process / VM maps
kernel.pid_max=4194304
kernel.threads-max=4194304
vm.max_map_count=262144
EOF
  sysctl -p /etc/sysctl.d/99-kuzco.conf >/dev/null 2>&1 || warning "sysctl apply returned non-zero."
  success "Kernel parameters applied"
else
  warning "Existing /etc/sysctl.d/99-kuzco.conf found. Review vm.* values."
fi

status "Disabling unnecessary services..."
for svc in "${SERVICES_TO_DISABLE[@]}"; do
  if systemctl is-enabled "$svc" 2>/dev/null | grep -q enabled; then
    systemctl disable --now "$svc" >/dev/null 2>&1 && success "Disabled $svc" || warning "Failed to disable $svc"
  else
    success "$svc already disabled (skipped)"
  fi
done

status "Checking swap configuration..."
CURRENT_SWAP_MB=$(free -m | awk '/Swap/ {print $2}')
RECOMMENDED_SWAP_MB=$((100 * 1024))  # 100GB
if [ -z "${SWAP_SIZE_GB:-}" ]; then
  if [ "$CURRENT_SWAP_MB" -lt "$RECOMMENDED_SWAP_MB" ]; then
    SWAP_SIZE_GB=$((RECOMMENDED_SWAP_MB/1024))
  else
    SWAP_SIZE_GB=$((CURRENT_SWAP_MB/1024))
  fi
fi
if ! [[ "${SWAP_SIZE_GB:-}" =~ ^[0-9]+$ ]]; then SWAP_SIZE_GB=$((RECOMMENDED_SWAP_MB/1024)); fi
SWAP_SIZE_MB=$((SWAP_SIZE_GB * 1024))
SWAPFILE="/swapfile_${SWAP_SIZE_GB}GB"

if [ "$CURRENT_SWAP_MB" -lt "$SWAP_SIZE_MB" ]; then
  status "Creating ${SWAP_SIZE_GB}GB swapfile at ${SWAPFILE}..."
  [ -f "$SWAPFILE" ] && (swapoff "$SWAPFILE" 2>/dev/null || true; rm -f "$SWAPFILE")
  dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_SIZE_MB" status=progress
  chmod 600 "$SWAPFILE"
  mkswap -f "$SWAPFILE"
  swapon --discard "$SWAPFILE"
  if ! grep -q "^$SWAPFILE" /etc/fstab; then
    echo "$SWAPFILE none swap sw,discard=once,pri=100 0 0" >> /etc/fstab
  else
    sed -i "s|^$SWAPFILE.*|$SWAPFILE none swap sw,discard=once,pri=100 0 0|" /etc/fstab
  fi
  success "Swapfile created and enabled"
else
  success "Existing swap (${CURRENT_SWAP_MB}MB) >= desired (${SWAP_SIZE_MB}MB) — keeping."
fi

if [ -d /sys/module/zswap ]; then
  status "Configuring zswap..."
  echo Y > /sys/module/zswap/parameters/enabled || true
  echo zstd > /sys/module/zswap/parameters/compressor || true
  echo 20 > /sys/module/zswap/parameters/max_pool_percent || true
  success "zswap configured (if supported)"
fi

status "Rebalancing page cache / swap..."
sync || true
echo 3 > /proc/sys/vm/drop_caches || true
swapoff -a || true
swapon -a || true
success "Cache dropped and swap cycled"

status "Configuring a global-ish RAM cap (reserve 2GB)…"
MEMTOTAL_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
RESERVE_KB=$((2 * 1024 * 1024))
if [ -f /sys/fs/cgroup/cgroup.controllers ] && [ "$MEMTOTAL_KB" -gt "$RESERVE_KB" ]; then
  LIMIT_KB=$((MEMTOTAL_KB - RESERVE_KB)); LIMIT_MB=$((LIMIT_KB / 1024)); LIMIT_STR="${LIMIT_MB}M"
  mkdir -p /etc/systemd/system.conf.d /etc/systemd/system/user.slice.d /etc/systemd/system/system.slice.d
  cat <<'EOF' > /etc/systemd/system.conf.d/memory-accounting.conf
[Manager]
DefaultMemoryAccounting=yes
EOF
  cat > /etc/systemd/system/user.slice.d/memory.conf <<EOF
[Slice]
MemoryAccounting=yes
MemoryHigh=${LIMIT_STR}
MemoryMax=${LIMIT_STR}
MemorySwapMax=infinity
EOF
  cat > /etc/systemd/system/system.slice.d/memory.conf <<EOF
[Slice]
MemoryAccounting=yes
MemoryHigh=${LIMIT_STR}
MemoryMax=${LIMIT_STR}
MemorySwapMax=infinity
EOF
  success "Applied MemoryHigh/MemoryMax=${LIMIT_STR} to user.slice & system.slice"
else
  warning "cgroup v2 not active or RAM <= 2GB — skipping RAM cap."
fi

status "Performing final updates..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get -y upgrade >/dev/null 2>&1 || true
  apt-get -y autoremove >/dev/null 2>&1 || true
  apt-get clean >/dev/null 2>&1 || true
fi

status "Applying changes & verifying..."
systemctl daemon-reload >/dev/null 2>&1 || true
status "Current memory & swap:"; free -h || true
status "Swap devices:"; swapon --show || true
status "Kernel VM params:"; for p in swappiness vfs_cache_pressure overcommit_memory overcommit_ratio; do echo "$p: $(cat /proc/sys/vm/$p 2>/dev/null || echo n/a)"; done
status "zswap status:"; if [ -d /sys/module/zswap ]; then
  echo "enabled: $(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo n/a)"
  echo "compressor: $(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo n/a)"
  echo "max_pool_percent: $(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo n/a)"
else echo "zswap not available"; fi

echo -e "\n${GREEN}✔ Optimization complete!${NC}"
echo -e "${YELLOW}Reboot recommended${NC} to fully apply memory limits."
SWAPOPT
chmod +x /usr/local/bin/kuzco-swap-heavy-and-ram-cap.sh

ok "Creating 100GB swap & optimizing… (this may take a while)"
SWAP_SIZE_GB=100 /usr/local/bin/kuzco-swap-heavy-and-ram-cap.sh

# ============ Step 2: Dependencies (Node.js/Yarn + tools) ============
ok "[2/3] Installing Node.js/Yarn & build tools…"
cat > /usr/local/bin/depedency-nodejs.sh <<'DEPS'
#!/bin/bash
set -euo pipefail
USERNAME=$(whoami)
ARCH=$(uname -m)
info(){ echo -e "\033[1;32m[INFO] $1\033[0m"; }
warn(){ echo -e "\033[1;33m[WARN] $1\033[0m"; }
error(){ echo -e "\033[1;31m[ERROR] $1\033[0m" >&2; exit 1; }
install_packages(){ info "Installing packages: $*"; sudo apt-get install -y "$@" || error "Failed to install: $*"; }
command_exists(){ command -v "$1" &>/dev/null; }

info "Checking system architecture..."
[ "$ARCH" = "x86_64" ] || warn "Non-x86_64 detected ($ARCH)"

sudo -v || error "Sudo privileges required"

info "Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get autoremove -y

info "Installing essential build tools..."
install_packages \
  git clang cmake build-essential openssl pkg-config libssl-dev \
  wget htop tmux jq make gcc tar ncdu protobuf-compiler \
  default-jdk aptitude squid apache2-utils file lsof zip unzip \
  iptables iptables-persistent openssh-server sed lz4 aria2 pv \
  python3 python3-venv python3-pip python3-dev screen snapd flatpak \
  nano automake autoconf nvme-cli libgbm-dev libleveldb-dev bsdmainutils unzip \
  ca-certificates curl gnupg lsb-release software-properties-common

info "Checking Node.js installation..."
if command_exists node; then
  info "Node.js: $(node --version)"
  info "npm: $(npm --version)"
  LATEST_NODE_VERSION=$(curl -fsSL https://nodejs.org/dist/latest-v18.x/SHASUMS256.txt | grep -oP 'node-v\K[0-9]+\.[0-9]+\.[0-9]+-linux-x64' | head -1 | cut -d'-' -f1 || true)
  if [ -n "$LATEST_NODE_VERSION" ] && [ "$(node --version | cut -dv -f2)" != "$LATEST_NODE_VERSION" ]; then
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

info "=== Installed Versions ==="
info "Node.js: $(node --version 2>/dev/null || echo 'Not installed')"
info "npm: $(npm --version 2>/dev/null || echo 'Not installed')"
info "Yarn: $(yarn --version 2>/dev/null || echo 'Not installed')"
DEPS
chmod +x /usr/local/bin/depedency-nodejs.sh
/usr/local/bin/depedency-nodejs.sh

# Ensure extras needed by gensyn
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y expect unzip >/dev/null 2>&1 || true

# ============ Step 3: Run gensyn node (as the original user) ============
ok "[3/3] Preparing & launching gensyn (screen: gensyn)…"

# All user-space operations run as the original user to keep paths consistent
sudo -u "$ORIG_USER" bash -lc "
set -Eeuo pipefail

# Clean old zip bundles
cd \"$ORIG_HOME\"
rm -f officialauto.zip nonofficialauto.zip original.zip original2.zip \
      ezlabs.zip ezlabs2.zip ezlabs3.zip ezlabs4.zip ezlabs5.zip ezlabs6.zip ezlabs7.zip ezlabs8.zip || true

# Create ezlabs stash dir
mkdir -p \"$ORIG_HOME/ezlabs\"

# Stash existing creds before wiping rl-swarm
if [ -f \"$ORIG_HOME/rl-swarm/modal-login/temp-data/userApiKey.json\" ]; then
  cp \"$ORIG_HOME/rl-swarm/modal-login/temp-data/userApiKey.json\" \"$ORIG_HOME/ezlabs/\" || true
fi
if [ -f \"$ORIG_HOME/rl-swarm/modal-login/temp-data/userData.json\" ]; then
  cp \"$ORIG_HOME/rl-swarm/modal-login/temp-data/userData.json\" \"$ORIG_HOME/ezlabs/\" || true
fi
if [ -f \"$ORIG_HOME/rl-swarm/swarm.pem\" ]; then
  cp \"$ORIG_HOME/rl-swarm/swarm.pem\" \"$ORIG_HOME/ezlabs/\" || true
fi

# Stop old screen and remove old repo
screen -XS gensyn quit || true
rm -rf \"$ORIG_HOME/rl-swarm\"

# Download latest pack and unpack
wget -q https://github.com/ezlabsnodes/gensyn/raw/refs/heads/main/officialauto.zip -O \"$ORIG_HOME/officialauto.zip\"
unzip -o \"$ORIG_HOME/officialauto.zip\" -d \"$ORIG_HOME\" >/dev/null

# Restore pem if present
if [ -f \"$ORIG_HOME/ezlabs/swarm.pem\" ]; then
  cp \"$ORIG_HOME/ezlabs/swarm.pem\" \"$ORIG_HOME/rl-swarm/\" || true
fi

# Start screen session running the launcher
cd \"$ORIG_HOME/rl-swarm\"
python3 -m venv .venv
source .venv/bin/activate
chmod +x run_rl_swarm.sh

# Detach to screen
screen -S gensyn -dm bash -lc 'source .venv/bin/activate && CPU_ONLY=true ./run_rl_swarm.sh'
"

ok "gensyn launched in background (screen session: gensyn)."

echo
echo "Attach to screen & login:"
echo "screen -r gensyn"
echo "Detach from screen:  Ctrl+A, then D"
