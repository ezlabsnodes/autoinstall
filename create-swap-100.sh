#!/usr/bin/env bash
set -euo pipefail
# -----------------------------
# Color helpers
# -----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
status() { echo -e "\n${BLUE}>>> $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warning() { echo -e "${YELLOW}⚠ $*${NC}"; }
error() { echo -e "${RED}✗ $*${NC}"; exit 1; }

# -----------------------------
# Configurable
# -----------------------------
# Set SWAP_SIZE_GB via environment to skip prompt, e.g.:
#   sudo SWAP_SIZE_GB=32 bash kuzco-swap-heavy-and-ram-cap.sh
SERVICES_TO_DISABLE=(avahi-daemon cups bluetooth ModemManager)

# -----------------------------
# Pre-checks
# -----------------------------
[ "$(id -u)" -eq 0 ] || error "Run as root (sudo)."

# Detect systemd + cgroup mode
if ! pidof systemd >/dev/null 2>&1; then
  warning "System does not appear to be using systemd. RAM cap parts will be skipped."
fi

CGROUP_V2=0
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  CGROUP_V2=1
  success "cgroup v2 detected."
else
  warning "cgroup v2 not detected. RAM cap will be best-effort only. Consider enabling unified cgroup hierarchy."
fi

# -----------------------------
# 1) System limits (nofile/nproc/memlock)
# -----------------------------
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

# -----------------------------
# 2) sysctl: Swap heavy behavior
# -----------------------------
status "Optimizing kernel parameters for swap-heavy behavior..."
if [ ! -f /etc/sysctl.d/99-kuzco.conf ]; then
  cat <<'EOF' > /etc/sysctl.d/99-kuzco.conf
# --------------- Network (safe defaults)
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.ip_local_port_range=1024 65535

# --------------- Memory — Aggressive swap + stable caches
vm.swappiness=100               # Prefer swapping sooner (0..100)
vm.vfs_cache_pressure=50        # Keep inode/dentry cache longer
vm.dirty_ratio=10               # Flush earlier
vm.dirty_background_ratio=5
vm.overcommit_memory=1          # Permit overcommit
vm.overcommit_ratio=80          # Allow 80% of RAM+swap
vm.page-cluster=0               # Swap page-at-a-time (lower latency)
vm.watermark_scale_factor=200   # More aggressive reclaim when low

# --------------- File handles
fs.file-max=1048576
fs.nr_open=1048576

# --------------- IPC (optional, leave as-is if unsure)
kernel.msgmax=65536
kernel.msgmnb=65536
kernel.shmall=4294967296
kernel.shmmax=17179869184

# --------------- Process / VM maps
kernel.pid_max=4194304
kernel.threads-max=4194304
vm.max_map_count=262144
EOF
  sysctl -p /etc/sysctl.d/99-kuzco.conf >/dev/null 2>&1 || warning "sysctl apply returned non-zero (check values)."
  success "Kernel parameters applied"
else
  warning "Existing /etc/sysctl.d/99-kuzco.conf found. Review that vm.swappiness=100 and related settings are present."
fi

# -----------------------------
# 3) Disable non-essential services
# -----------------------------
status "Disabling unnecessary services..."
for svc in "${SERVICES_TO_DISABLE[@]}"; do
  if systemctl is-enabled "$svc" 2>/dev/null | grep -q enabled; then
    systemctl disable --now "$svc" >/dev/null 2>&1 && success "Disabled $svc" || warning "Failed to disable $svc"
  else
    success "$svc already disabled (skipped)"
  fi
done

# -----------------------------
# 4) Swap: ensure large swapfile + zswap
# -----------------------------
status "Checking swap configuration..."
CURRENT_SWAP_MB=$(free -m | awk '/Swap/ {print $2}')
RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
RECOMMENDED_SWAP_MB=$((100 * 1024))

# Read desired swap size
if [ -z "${SWAP_SIZE_GB:-}" ]; then
  if [ "$CURRENT_SWAP_MB" -lt "$RECOMMENDED_SWAP_MB" ]; then
    echo -n "Enter swap size in GB (default: $((RECOMMENDED_SWAP_MB/1024))): "
    read -r SWAP_SIZE_GB || true
  else
    SWAP_SIZE_GB=$((CURRENT_SWAP_MB/1024))
  fi
fi

# Fallback to recommended if empty or non-numeric
if ! [[ "${SWAP_SIZE_GB:-}" =~ ^[0-9]+$ ]]; then
  SWAP_SIZE_GB=$((RECOMMENDED_SWAP_MB/1024))
fi
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

# zswap (compressed in-RAM swap cache)
if [ -d /sys/module/zswap ]; then
  status "Configuring zswap..."
  # Use safe values; kernel expects Y/N for enabled
  echo Y > /sys/module/zswap/parameters/enabled || warning "Failed to enable zswap (kernel policy)"
  echo zstd > /sys/module/zswap/parameters/compressor || true
  echo 20 > /sys/module/zswap/parameters/max_pool_percent || true
  success "zswap configured (if supported)"
else
  warning "zswap module/feature not present on this kernel"
fi

# Optionally, encourage immediate rebalancing towards swap
status "Rebalancing page cache / swap..."
sync || true
# Drop page cache to free RAM for anon, encouraging swap usage under pressure
echo 3 > /proc/sys/vm/drop_caches || true
# Cycle swap to migrate cold anon pages
swapoff -a || true
swapon -a || true
success "Cache dropped and swap cycled"

# -----------------------------
# 5) Global RAM cap (reserve 2GB for the system)
# -----------------------------
status "Configuring a global-ish RAM cap (reserve 2GB)..."
MEMTOTAL_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
RESERVE_KB=$((2 * 1024 * 1024)) # 2GB
if [ "$MEMTOTAL_KB" -le "$RESERVE_KB" ]; then
  warning "Total RAM <= 2GB; skipping RAM cap."
else
  LIMIT_KB=$((MEMTOTAL_KB - RESERVE_KB))
  LIMIT_MB=$((LIMIT_KB / 1024))
  LIMIT_STR="${LIMIT_MB}M"

  mkdir -p /etc/systemd/system.conf.d
  # Make sure memory accounting is on globally
  cat <<'EOF' > /etc/systemd/system.conf.d/memory-accounting.conf
[Manager]
DefaultMemoryAccounting=yes
EOF

  if [ "$CGROUP_V2" -eq 1 ]; then
    # Apply to user.slice and system.slice so *most* apps are constrained
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
    warning "Note: These are per-slice limits; combined usage can exceed ${LIMIT_STR}. True global cap on the root slice is not supported via systemd."
  else
    warning "cgroup v2 not active — cannot enforce MemoryMax cleanly. Consider enabling unified cgroups to honor the cap."
  fi
fi

# -----------------------------
# 6) Update packages (quiet)
# -----------------------------
status "Performing final updates..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get -y upgrade >/dev/null 2>&1 || warning "apt upgrade failed"
  apt-get -y autoremove >/dev/null 2>&1 || true
  apt-get clean >/dev/null 2>&1 || true
elif command -v dnf >/dev/null 2>&1; then
  dnf -y update >/dev/null 2>&1 || warning "dnf update failed"
  dnf -y autoremove >/dev/null 2>&1 || true
  dnf clean all >/dev/null 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
  yum -y update >/dev/null 2>&1 || warning "yum update failed"
  yum -y autoremove >/dev/null 2>&1 || true
  yum clean all >/dev/null 2>&1 || true
fi

# -----------------------------
# 7) Apply & verify
# -----------------------------
status "Applying changes & verifying..."
systemctl daemon-reload >/dev/null 2>&1 && success "systemd daemon reloaded" || warning "Failed to reload systemd daemon"

status "Current memory & swap:"; free -h || true

status "Swap devices:"; swapon --show || true

status "Kernel VM params (live):"
for p in swappiness vfs_cache_pressure overcommit_memory overcommit_ratio; do
  echo "$p: $(cat /proc/sys/vm/$p 2>/dev/null || echo n/a)"
done

status "zswap status:"
if [ -d /sys/module/zswap ]; then
  echo "enabled: $(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo n/a)"
  echo "compressor: $(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo n/a)"
  echo "max_pool_percent: $(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo n/a)"
else
  echo "zswap not available"
fi

if [ "$CGROUP_V2" -eq 1 ]; then
  status "Slice limits (live):"
  systemctl show -p MemoryCurrent -p MemoryHigh -p MemoryMax user.slice system.slice 2>/dev/null || true
  echo "\nPaths:"
  echo "user.slice:   /sys/fs/cgroup/user.slice/memory.{current,high,max}"
  echo "system.slice: /sys/fs/cgroup/system.slice/memory.{current,high,max}"
fi
# -----------------------------
# 7) Create Systemd Slice
# -----------------------------
SLICE_FILE="/etc/systemd/system/rl-swarm.slice"
RAM_REDUCTION_GB=3

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ Error: Skrip ini harus dijalankan dengan sudo atau sebagai user root."
  exit 1
fi

# Auto-detect jumlah CPU core
cpu_cores=$(nproc)
echo "CPU cores terdeteksi: ${cpu_cores}"

# Hitung limit CPU: (total core - 1) * 100%
cpu_limit_percentage=$(( (cpu_cores - 1) * 100 ))

# Pastikan tidak minus (minimal 100% jika hanya 1 core)
if [ "$cpu_limit_percentage" -lt 100 ]; then
    cpu_limit_percentage=100
fi

total_gb=$(free -g | awk '/^Mem:/ {print $2}')
echo "RAM terdeteksi: ${total_gb}G"

if [ "$total_gb" -le "$RAM_REDUCTION_GB" ]; then
  echo "❌ Error: Total RAM (${total_gb}G) terlalu kecil untuk dikurangi ${RAM_REDUCTION_GB}G."
  exit 1
fi

limit_gb=$((total_gb - RAM_REDUCTION_GB))
echo "Batas RAM akan diatur ke: ${limit_gb}G"
echo "Batas CPU akan diatur ke: ${cpu_limit_percentage}% (${cpu_cores} core - 1 core)"

slice_content="[Slice]
Description=Slice for RL Swarm (auto-detected: ${limit_gb}G RAM, ${cpu_limit_percentage}% CPU from ${cpu_cores} cores)
MemoryMax=${limit_gb}G
CPUQuota=${cpu_limit_percentage}%
"

echo -e "$slice_content" | sudo tee "$SLICE_FILE" > /dev/null

# -----------------------------
# Done
# -----------------------------
echo -e "\n${GREEN}✔ Optimization complete!${NC}"
echo -e "${YELLOW}Reboot recommended${NC} to fully apply all limits (especially slice MemoryMax)."
echo "✅ File slice berhasil dibuat di $SLICE_FILE"
echo -e "After reboot, verify:"
echo -e "  * free -h"
echo -e "  * cat /sys/fs/cgroup/user.slice/memory.{current,high,max}"
echo -e "  * cat /sys/fs/cgroup/system.slice/memory.{current,high,max}"
echo -e "  * vmstat 1 (watch swap activity)"
