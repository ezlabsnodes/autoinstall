#!/bin/bash
set -e

# ==================== KONFIGURASI ====================
MAX_OPEN_FILES=1048576
SWAPINESS=10                     # Lebih rendah untuk minimize swap thrashing
DIRTY_RATIO=30                   # Lebih agresif flush ke disk
TCP_MAX_SYN_BACKLOG=16384
KERNEL_PID_MAX=4194304
OVERCOMMIT_RATIO=100             # Allow overcommit 100% RAM fisik + swap
MIN_SWAP_SIZE=$((20*1024))       # Minimum 20GB swap space (dalam MB)

# ==================== FUNGSI ====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
status() { echo -e "\n${BLUE}>>> $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warning() { echo -e "${YELLOW}⚠ $*${NC}"; }
error() { echo -e "${RED}✗ $*${NC}"; exit 1; }

# ==================== OPTIMASI MEMORY ====================
optimize_memory() {
    status "Konfigurasi memory management khusus 12GB RAM"
    
    # Hitung kebutuhan swap
    local current_swap=$(free -m | awk '/Swap/{print $2}')
    local current_swap_gb=$((current_swap/1024))
    
    if [ "$current_swap" -lt "$MIN_SWAP_SIZE" ]; then
        warning "Swap saat ini ${current_swap_gb}GB (kurang dari minimum 20GB)"
        
        # Buat swap file tambahan
        status "Membuat swap file tambahan..."
        local additional_swap=$((MIN_SWAP_SIZE - current_swap + 1024)) # +1GB buffer
        
        # Cleanup old swapfile if exists
        [[ -f /swapfile ]] && swapoff /swapfile && rm -f /swapfile
        
        # Create new swap
        dd if=/dev/zero of=/swapfile bs=1M count=$additional_swap status=progress
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        
        success "Ditambahkan ${additional_swap}MB swap file (Total sekarang: $((current_swap + additional_swap))MB"
    else
        success "Swap sudah cukup (${current_swap_gb}GB)"
    fi

    # Kernel parameters khusus memory pressure
    cat > /etc/sysctl.d/99-memory.conf <<EOF
# Memory Management Extreme
vm.swappiness=$SWAPINESS
vm.dirty_ratio=$DIRTY_RATIO
vm.dirty_background_ratio=5
vm.overcommit_memory=2
vm.overcommit_ratio=$OVERCOMMIT_RATIO
vm.oom_kill_allocating_task=1
vm.panic_on_oom=0
vm.extfrag_threshold=500
vm.min_free_kbytes=65536

# Cache Pressure
vm.vfs_cache_pressure=50
EOF

    sysctl -p /etc/sysctl.d/99-memory.conf
    success "Memory optimization applied for 12GB/20GB workload"
}

# ==================== OPTIMASI KHUSUS HIGH MEMORY LOAD ====================
optimize_highmem() {
    status "Tuning khusus high-memory workload"
    
    # Adjust OOM killer
    echo 'vm.oom_kill_allocating_task = 1' >> /etc/sysctl.conf
    
    # Prioritize current process
    echo 'kernel.sched_autogroup_enabled = 1' >> /etc/sysctl.conf
    
    # ZRAM configuration (jika tersedia)
    if modprobe zram; then
        echo "zstd" > /sys/block/zram0/comp_algorithm
        echo "2" > /sys/block/zram0/max_comp_streams
        MEM=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') * 1024 ))
        echo $((MEM / 2)) > /sys/block/zram0/disksize
        mkswap /dev/zram0
        swapon /dev/zram0 -p 100
        success "ZRAM configured for compression"
    fi
    
    # CGroup memory protection
    if [ -d /sys/fs/cgroup/memory ]; then
        echo "memory.limit_in_bytes=20G" > /sys/fs/cgroup/memory/memory.limit_in_bytes
        success "CGroup memory protection configured"
    fi
}

# ==================== MAIN EXECUTION ====================
main() {
    [[ $(id -u) -ne 0 ]] && error "Harus run sebagai root"
    
    optimize_memory
    optimize_highmem
    
    # Verifikasi akhir
    status "Memory Configuration Summary:"
    echo -e "${GREEN}Physical RAM: $(free -h | awk '/Mem/{print $2}')${NC}"
    echo -e "${GREEN}Total Swap: $(free -h | awk '/Swap/{print $2}')${NC}"
    echo -e "${GREEN}Swappiness: $(cat /proc/sys/vm/swappiness)${NC}"
    echo -e "${GREEN}Overcommit: $(cat /proc/sys/vm/overcommit_memory) (ratio: $(cat /proc/sys/vm/overcommit_ratio))${NC}"
    
    echo -e "\n${YELLOW}⚠ PERINGATAN UNTUK KASUS 12GB/20GB:${NC}"
    echo "1. Sistem akan menggunakan swap secara ekstensif"
    echo "2. Monitor memory pressure dengan: ${GREEN}vmstat 1${NC}"
    echo "3. Pertimbangkan upgrade RAM jika sering terjadi OOM"
    
    echo -e "\n${GREEN}✔ OPTIMASI SELESAI!${NC}"
    echo -e "Reboot system: ${GREEN}reboot now${NC}"
}

main "$@"
