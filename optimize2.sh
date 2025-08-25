#!/usr/bin/env bash
set -euo pipefail
# ================================================================
# Swap-Heavy Tuning + RAM Cap with optional early-swap (Option 3)
# Default target slice: rl-swarm.slice  (you can switch to user/system slices)
# ================================================================

# -----------------------------
# Color helpers
# -----------------------------
RED='[0;31m'
GREEN='[0;32m'
YELLOW='[1;33m'
BLUE='[0;34m'
NC='[0m'
status() { echo -e "
${BLUE}>>> $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warning() { echo -e "${YELLOW}⚠ $*${NC}"; }
error() { echo -e "${RED}✗ $*${NC}"; exit 1; }

# -----------------------------
# Configurable / CLI flags
# -----------------------------
# Example:
#   sudo SWAP_SIZE_GB=64 bash script.sh --swap-early        # Option 3: dorong swap lebih awal
#   sudo bash script.sh --use-default-slices                 # pakai user.slice & system.slice
#   sudo bash script.sh --slices rl-swarm.slice,custom.slice # set slice kustom
#   sudo bash script.sh --swap-size-gb 32                    # tentukan swap tanpa prompt

SERVICES_TO_DISABLE=(avahi-daemon cups bluetooth ModemManager)

EARLY_SWAP=0                 # --swap-early atau -3 → MemoryHigh < MemoryMax
USE_DEFAULT_SLICES=0         # --use-default-slices → target user.slice + system.slice
TARGET_SLICES=("rl-swarm.slice") # default diminta user: rl-swarm.slice
SWAP_SIZE_GB=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --swap-early|-3) EARLY_SWAP=1 ;;
    --use-default-slices) USE_DEFAULT_SLICES=1 ;;
    --slice) shift; TARGET_SLICES=("${1:-rl-swarm.slice}") ;;
    --slices) shift; IFS=',' read -r -a TARGET_SLICES <<< "${1:-rl-swarm.slice}" ;;
    --swap-size-gb) shift; SWAP_SIZE_GB="${1:-}" ;;
    *) warning "Unknown arg: $1 (diabaikan)" ;;
  esac
  shift || true
done

[ "$(id -u)" -eq 0 ] || error "Run as root (sudo)."

# Detect systemd + cgroup mode
if ! pidof systemd >/dev/null 2>&1; then
  warning "System tidak tampak memakai systemd. RAM cap parts akan diskip."
fi

CGROUP_V2=0
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  CGROUP_V2=1
  success "cgroup v2 detected."
else
  warning "cgroup v2 not detected. Aktifkan unified cgroup untuk RAM cap yang rapi."
fi

if [[ $USE_DEFAULT_SLICES -eq 1 ]]; then
  TARGET_SLICES=("user.slice" "system.slice")
fi

status "Target slices: ${TARGET_SLICES[*]}"
[[ $EARLY_SWAP -eq 1 ]] && success "Option 3 aktif: Dorong swap lebih awal (MemoryHigh < MemoryMax)"

# -----------------------------
# Helpers
# -----------------------------
write_slice_limits() {
  # $1 = slice name, $2 = MemoryHigh string, $3 = MemoryMax string
  local slice="$1"; local high="$2"; local max="$3"
  if [[ "$slice" == "user.slice" || "$slice" == "system.slice" ]]; then
    mkdir -p "/etc/systemd/system/${slice}.d"
    cat > "/etc/systemd/system/${slice}.d/memory.conf" <<EOF
[Slice]
MemoryAccounting=yes
MemoryHigh=${high}
MemoryMax=${max}
MemorySwapMax=infinity
EOF
  else
    # Slice custom: pastikan unit slice ada
    cat > "/etc/systemd/system/${slice}" <<EOF
[Unit]
Description=RL Swarm Global Cap Slice (${slice})

[Slice]
MemoryAccounting=yes
MemoryHigh=${high}
MemoryMax=${max}
MemorySwapMax=infinity
EOF
  fi
  success "Applied MemoryHigh=${high} MemoryMax=${max} to ${slice}"
}

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

# --- Auto swap size: fixed 100GB (override with --swap-size-gb or SWAP_SIZE_GB)
DEFAULT_SWAP_GB=100
if [ -z "${SWAP_SIZE_GB}" ]; then
  SWAP_SIZE_GB=${DEFAULT_SWAP_GB}
fi
if ! [[ "${SWAP_SIZE_GB}" =~ ^[0-9]+$ ]]; then
  warning "Invalid --swap-size-gb value; fallback to ${DEFAULT_SWAP_GB}GB"
  SWAP_SIZE_GB=${DEFAULT_SWAP_GB}
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
# 5) RAM cap (reserve 2GB) + Option 3 (early swap)
# -----------------------------
status "Configuring RAM cap (reserve 2GB) on target slices..."
MEMTOTAL_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
RESERVE_KB=$((2 * 1024 * 1024)) # 2GB
if [ "$MEMTOTAL_KB" -le "$RESERVE_KB" ]; then
  warning "Total RAM <= 2GB; skipping RAM cap."
else
  LIMIT_KB=$((MEMTOTAL_KB - RESERVE_KB))
  LIMIT_MB=$((LIMIT_KB / 1024))
  LIMIT_STR="${LIMIT_MB}M"

  # Early-swap (Option 3): turunkan MemoryHigh jadi 85% dari MemoryMax,
  # supaya reclaim dimulai lebih dini dan swap terasa lebih cepat dipakai.
  if [[ $EARLY_SWAP -eq 1 ]]; then
    HIGH_MB=$(( LIMIT_MB * 85 / 100 ))
  else
    HIGH_MB=$LIMIT_MB
  fi
  HIGH_STR="${HIGH_MB}M"

  mkdir -p /etc/systemd/system.conf.d
  cat <<'EOF' > /etc/systemd/system.conf.d/memory-accounting.conf
[Manager]
DefaultMemoryAccounting=yes
EOF

  if [ "$CGROUP_V2" -eq 1 ]; then
    for slice in "${TARGET_SLICES[@]}"; do
      write_slice_limits "$slice" "$HIGH_STR" "$LIMIT_STR"
    done
    warning "Catatan: Limit berlaku per-slice. Gabungan beberapa slice masih bisa melebihi ${LIMIT_STR}."
  else
    warning "cgroup v2 tidak aktif — tidak bisa enforce MemoryMax secara bersih."
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
  systemctl show -p MemoryCurrent -p MemoryHigh -p MemoryMax "${TARGET_SLICES[@]}" 2>/dev/null || true
  echo -e "
Paths for manual check:"
  for s in "${TARGET_SLICES[@]}"; do
    echo "${s}: /sys/fs/cgroup/${s}/memory.{current,high,max}"
  done
fi

# -----------------------------
# Done
# -----------------------------
elsecat() {
  echo -e "
${GREEN}✔ Optimization complete!${NC}"
  echo -e "${YELLOW}Reboot recommended${NC} untuk mengunci limit di semua service/sesi."
  echo -e "Setelah reboot, verifikasi:"
  echo -e "  * free -h"
  if [ "$CGROUP_V2" -eq 1 ]; then
    echo -e "  * systemctl show -p MemoryCurrent -p MemoryHigh -p MemoryMax ${TARGET_SLICES[*]}"
  fi
  echo -e "  * vmstat 1 (pantau swap activity)"
}
elsecat
