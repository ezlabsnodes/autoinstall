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
# 2. MAIN SCRIPT LOGIC - OPTIMIZED FOR AGGRESSIVE SWAP
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

# 2. Kernel Parameters Optimization - REVISED FOR BETTER SWAP USAGE
status "Optimizing kernel parameters for aggressive swap..."

if [ ! -f /etc/sysctl.d/99-kuzco.conf ]; then
    cat <<EOF > /etc/sysctl.d/99-kuzco.conf
# Network
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.ip_local_port_range=1024 65535

# Memory - REVISED AGGRESSIVE SWAP SETTINGS
vm.swappiness=100              # More aggressive swapping (default 60)
vm.vfs_cache_pressure=50       # Keep more filesystem cache in RAM
vm.dirty_ratio=10              # Lower value to flush dirty pages earlier
vm.dirty_background_ratio=5    # More frequent background flushes
vm.overcommit_memory=1         # Allow memory overcommit
vm.overcommit_ratio=80         # Overcommit up to 80% of swap+RAM
vm.page-cluster=0              # Swap pages individually for better performance
vm.watermark_scale_factor=200  # More aggressive memory reclaim

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
    success "Kernel parameters optimized for aggressive swap"
else
    warning "Kernel config already exists. Manual edit required:"
    echo -e "Edit ${YELLOW}/etc/sysctl.d/99-kuzco.conf${NC} and set:"
    echo -e "vm.swappiness=100\nvm.overcommit_memory=1\nvm.overcommit_ratio=80"
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

# 4. Swap File Configuration (Improved Implementation)
status "Checking swap configuration..."

CURRENT_SWAP=$(free -m | awk '/Swap/{print $2}')
RAM_SIZE=$(free -m | awk '/Mem/{print $2}')
RECOMMENDED_SWAP=$((RAM_SIZE * 2))  # 2x RAM (200%)

if [ "$CURRENT_SWAP" -lt "$RECOMMENDED_SWAP" ]; then
    status "Current swap: ${CURRENT_SWAP}MB | Recommended (2x RAM): ${RECOMMENDED_SWAP}MB"
    read -p "Enter swap size in GB (e.g. 30 for 30GB) or press Enter for recommended size (2x RAM): " SWAP_SIZE_GB
    
    if [[ -n "$SWAP_SIZE_GB" && "$SWAP_SIZE_GB" =~ ^[0-9]+$ ]]; then
        # User entered a number - use that for GB
        SWAP_SIZE_MB=$((SWAP_SIZE_GB * 1024))
        status "Creating ${SWAP_SIZE_GB}GB swapfile as requested..."
    else
        # Use recommended size (2x RAM)
        SWAP_SIZE_MB=$RECOMMENDED_SWAP
        SWAP_SIZE_GB=$((SWAP_SIZE_MB / 1024))
        status "Creating recommended ${SWAP_SIZE_GB}GB (2x RAM) swapfile..."
    fi
    
    # Check if swapfile already exists
    if [ -f "/swapfile_${SWAP_SIZE_GB}GB" ]; then
        warning "Swapfile already exists, removing old version..."
        swapoff "/swapfile_${SWAP_SIZE_GB}GB" 2>/dev/null || true
        rm -f "/swapfile_${SWAP_SIZE_GB}GB"
    fi
    
    # Create new swapfile with improved settings
    SWAPFILE="/swapfile_${SWAP_SIZE_GB}GB"
    status "Creating swapfile with optimal settings..."
    
    # Use dd instead of fallocate for better compatibility
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_SIZE_MB" status=progress
    chmod 600 "$SWAPFILE"
    mkswap -f "$SWAPFILE"
    swapon --discard "$SWAPFILE"  # Enable discard for SSDs
    
    # Add to fstab with optimal parameters
    if ! grep -q "$SWAPFILE" /etc/fstab; then
        echo "$SWAPFILE none swap sw,discard=once,pri=100 0 0" >> /etc/fstab
    else
        sed -i "s|^$SWAPFILE.*|$SWAPFILE none swap sw,discard=once,pri=100 0 0|" /etc/fstab
    fi
    
    # Enable zswap for better performance
    if [ -d /sys/module/zswap ]; then
        echo 1 > /sys/module/zswap/parameters/enabled
        echo zstd > /sys/module/zswap/parameters/compressor
        echo 20 > /sys/module/zswap/parameters/max_pool_percent
    fi
    
    success "Created optimized ${SWAP_SIZE_GB}GB swapfile at $SWAPFILE"
else
    success "Swap size adequate (${CURRENT_SWAP}MB)"
    
    # Enable zswap even if swap is adequate
    if [ -d /sys/module/zswap ]; then
        echo 1 > /sys/module/zswap/parameters/enabled
        echo zstd > /sys/module/zswap/parameters/compressor
        echo 20 > /sys/module/zswap/parameters/max_pool_percent
        success "Enabled zswap compression for existing swap"
    fi
fi

# 5. Final System Updates
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
    dnf clean all >/dev/null 2>&1
fi

# 6. Apply All Changes and Verify
status "Applying all changes and verifying settings..."
systemctl daemon-reload >/dev/null 2>&1 && \
    success "Systemd daemon reloaded" || \
    warning "Failed to reload systemd daemon"

# Clear caches to encourage swap usage
sync && echo 3 > /proc/sys/vm/drop_caches

# Verification
status "Current settings verification:"
echo -e "${BLUE}Memory/Swap:${NC}"
free -h
echo -e "\n${BLUE}Swap Settings:${NC}"
swapon --show
echo -e "\n${BLUE}Kernel Parameters:${NC}"
echo "swappiness: $(cat /proc/sys/vm/swappiness)"
echo "vfs_cache_pressure: $(cat /proc/sys/vm/vfs_cache_pressure)"
echo "overcommit_memory: $(cat /proc/sys/vm/overcommit_memory)"
echo "overcommit_ratio: $(cat /proc/sys/vm/overcommit_ratio)"
echo -e "\n${BLUE}Zswap Status:${NC}"
if [ -d /sys/module/zswap ]; then
    echo "enabled: $(cat /sys/module/zswap/parameters/enabled)"
    echo "compressor: $(cat /sys/module/zswap/parameters/compressor)"
    echo "max_pool_percent: $(cat /sys/module/zswap/parameters/max_pool_percent)"
else
    echo "Zswap not available in this kernel"
fi

# Final message
echo -e "\n${GREEN}✔ Optimization complete!${NC}"
echo -e "${YELLOW}Some changes require a reboot to take full effect.${NC}"
echo -e "Run: ${GREEN}reboot${NC} then verify with:"
echo -e "1. Check swap usage: ${GREEN}free -h${NC}"
echo -e "2. Check current settings: ${GREEN}cat /proc/sys/vm/{swappiness,vfs_cache_pressure}${NC}"
echo -e "3. Monitor swap activity: ${GREEN}vmstat 1${NC} or ${GREEN}cat /proc/vmstat | grep swap${NC}"
