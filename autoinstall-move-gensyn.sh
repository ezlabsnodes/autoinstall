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

# Resolve invoking user/home (for copying sources, etc.)
ORIG_USER=${SUDO_USER:-$(logname 2>/dev/null || whoami)}
ORIG_HOME=$(getent passwd "$ORIG_USER" | cut -d: -f6)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# =========================================================
# STEP 1 — OPTIMIZE + CREATE 100GB SWAP
# (swap-heavy sysctl, limits, disable services, zswap, RAM cap)
# =========================================================
status "[1/4] System optimization & 100GB swap"

cat > /usr/local/bin/kuzco-optimize-and-swap.sh <<'EOSWAP'
#!/usr/bin/env bash
set -euo pipefail
# -----------------------------
# Color helpers
# -----------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
status() { echo -e "\n${BLUE}>>> $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warning() { echo -e "${YELLOW}⚠ $*${NC}"; }
error() { echo -e "${RED}✗ $*${NC}"; exit 1; }

SERVICES_TO_DISABLE=(avahi-daemon cups bluetooth ModemManager)

[ "$(id -u)" -eq 0 ] || error "Run as root (sudo)."

if ! pidof systemd >/dev/null 2>&1; then
  warning "System does not appear to be using systemd. RAM cap parts will be skipped."
fi

CGROUP_V2=0
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  CGROUP_V2=1; success "cgroup v2 detected."
else
  warning "cgroup v2 not detected. RAM cap will be best-effort only."
fi

# 1) Limits
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

ulimit -n 1048576 >/dev/null 2>&1 || warning "Couldn't increase current session limits."

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

# 2) sysctl – swap-heavy
status "Optimizing kernel parameters for swap-heavy behavior..."
if [ ! -f /etc/sysctl.d/99-kuzco.conf ]; then
  cat <<'EOF' > /etc/sysctl.d/99-kuzco.conf
# Network
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.ip_local_port_range=1024 65535
# Memory
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
  warning "Existing 99-kuzco.conf detected; ensure swappiness=100 etc."
fi

# 3) Disable services
status "Disabling unnecessary services..."
for svc in "${SERVICES_TO_DISABLE[@]}"; do
  if systemctl is-enabled "$svc" 2>/dev/null | grep -q enabled; then
    systemctl disable --now "$svc" >/dev/null 2>&1 && success "Disabled $svc" || warning "Failed to disable $svc"
  else
    success "$svc already disabled (skipped)"
  fi
done

# 4) Swap ensure (100GB default if SWAP_SIZE_GB unset)
status "Checking swap configuration..."
CURRENT_SWAP_MB=$(free -m | awk '/Swap/ {print $2}')
RECOMMENDED_SWAP_MB=$((100 * 1024))
: "${SWAP_SIZE_GB:=$((RECOMMENDED_SWAP_MB/1024))}"
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

# zswap
if [ -d /sys/module/zswap ]; then
  status "Configuring zswap..."
  echo Y > /sys/module/zswap/parameters/enabled || warning "Failed to enable zswap"
  echo zstd > /sys/module/zswap/parameters/compressor || true
  echo 20  > /sys/module/zswap/parameters/max_pool_percent || true
  success "zswap configured (if supported)"
else
  warning "zswap not available on this kernel"
fi

# Rebalance
status "Rebalancing page cache / swap..."
sync || true
echo 3 > /proc/sys/vm/drop_caches || true
swapoff -a || true
swapon -a || true
success "Cache dropped and swap cycled"

# 5) Global RAM cap (reserve 2GB)
status "Configuring RAM cap (reserve 2GB for system)…"
MEMTOTAL_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
RESERVE_KB=$((2 * 1024 * 1024))
if [ "$MEMTOTAL_KB" -le "$RESERVE_KB" ]; then
  warning "Total RAM <= 2GB; skipping cap."
else
  LIMIT_KB=$((MEMTOTAL_KB - RESERVE_KB))
  LIMIT_MB=$((LIMIT_KB / 1024))
  LIMIT_STR="${LIMIT_MB}M"

  mkdir -p /etc/systemd/system.conf.d
  cat <<'EOF' > /etc/systemd/system.conf.d/memory-accounting.conf
[Manager]
DefaultMemoryAccounting=yes
EOF

  if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    mkdir -p /etc/systemd/system/user.slice.d /etc/systemd/system/system.slice.d
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
    warning "cgroup v2 not active — skip MemoryMax enforcement."
  fi
fi

# 6) Updates
status "Applying updates (quiet)…"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get -y upgrade >/dev/null 2>&1 || warning "apt upgrade failed"
  apt-get -y autoremove >/dev/null 2>&1 || true
  apt-get clean  >/dev/null 2>&1 || true
elif command -v dnf >/dev/null 2>&1; then
  dnf -y update >/dev/null 2>&1 || warning "dnf update failed"
elif command -v yum >/dev/null 2>&1; then
  yum -y update >/dev/null 2>&1 || warning "yum update failed"
fi

# 7) Verify
status "systemd daemon reload"; systemctl daemon-reload >/dev/null 2>&1 || true
status "Current memory & swap:"; free -h || true
status "Swap devices:"; swapon --show || true
status "Kernel VM params (live):"
for p in swappiness vfs_cache_pressure overcommit_memory overcommit_ratio; do
  echo "$p: $(cat /proc/sys/vm/$p 2>/dev/null || echo n/a)"
done
echo -e "\n${GREEN}✔ Optimization complete!${NC}"
warning "Reboot is recommended to fully apply limits."
EOSWAP
chmod +x /usr/local/bin/kuzco-optimize-and-swap.sh
SWAP_SIZE_GB=100 /usr/local/bin/kuzco-optimize-and-swap.sh

# =========================================================
# STEP 2 — INSTALL DEPENDENCIES (Node.js, Yarn, Docker, Compose)
# =========================================================
status "[2/4] Installing dependencies (Node.js, Yarn, Docker, Compose)…"

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

# =========================================================
# STEP 3 — ENSURE /root/ezlabs & REQUIRED FILES (with 5-min wait)
# =========================================================
status "[3/4] Ensuring /root/ezlabs and required keys…"
EZDIR="/root/ezlabs"
mkdir -p "$EZDIR"

WAIT_SECS=300   # 5 minutes total
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
    # if src is already the dest and exists -> done
    if [[ "$src" == "$dest" && -f "$dest" ]]; then return 0; fi
    # if src path exists (and is not dest), copy
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

# Initial auto-copy attempt
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

    # live status line (dynamic list)
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


echo
echo -e "${BLUE}Follow live logs:${NC}   journalctl -u rl-swarm -f -o cat"
echo -e "${BLUE}All logs:${NC}         cat ~/rl-swarm/logs/swarm_launcher.log"
