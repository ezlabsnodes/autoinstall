#!/bin/bash
set -euo pipefail

# ==========================================
# Utility functions (kept as-is)
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
# 1. Environment Verification
# ==========================================
message "Starting custom swapfile configuration"

# Require root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
fi

# ==========================================
# 2. Swap Size (MANUAL INPUT)
# ==========================================
SWAPFILE="/swapfile"

while :; do
    read -rp "Enter swapfile size (e.g., 4G or 8192M): " SWAP_SIZE
    # valid if: number + G/g or M/m
    if [[ "$SWAP_SIZE" =~ ^[0-9]+[GgMm]$ ]]; then
        break
    fi
    warning "Invalid format. Use a number followed by G or M (e.g., 8G or 4096M)."
done

message "Swapfile will be created with size: $SWAP_SIZE"

# ==========================================
# 3. System Info
# ==========================================
message "\nSystem information:"
TOTAL_RAM_GB=$(free -g | awk '/Mem:/ {print $2}')
if [ "${TOTAL_RAM_GB:-0}" -eq 0 ]; then
    TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
    TOTAL_RAM_GB=$(( (TOTAL_RAM_MB + 1023) / 1024 ))
fi

echo " - Total RAM: ${TOTAL_RAM_GB}GB"
echo " - Planned swapfile size: $SWAP_SIZE"

# Optional: check free space on root mount
ROOT_AVAIL_BYTES=$(df --output=avail -B1 / | tail -1)
# Convert input size to bytes for a rough check
case "$SWAP_SIZE" in
  *[Gg]) REQ_BYTES=$(( ${SWAP_SIZE%[Gg]} * 1024 * 1024 * 1024 ));;
  *[Mm]) REQ_BYTES=$(( ${SWAP_SIZE%[Mm]} * 1024 * 1024 ));;
esac
if (( ROOT_AVAIL_BYTES <= REQ_BYTES )); then
    warning "Free disk space may be insufficient for a $SWAP_SIZE swapfile."
    read -rp "Proceed anyway? [y/N]: " yn
    [[ "${yn,,}" == "y" ]] || error "Aborted by user."
fi

# ==========================================
# 4. Swapfile Setup
# ==========================================
message "\nDisabling active swap (if any)..."
if swapon --show | grep -q "swap"; then
    swapoff -a || warning "Failed to disable some active swap."
    message "All active swap has been disabled."
else
    warning "No active swap detected."
fi

if [[ -f "$SWAPFILE" ]]; then
    message "Removing old swapfile: $SWAPFILE..."
    rm -f "$SWAPFILE" || error "Failed to remove old swapfile."
fi

message "Creating new swapfile ($SWAP_SIZE) at $SWAPFILE..."
if ! fallocate -l "$SWAP_SIZE" "$SWAPFILE"; then
    warning "fallocate failed, falling back to dd..."
    # dd fallback using units from input
    if [[ "$SWAP_SIZE" =~ ^([0-9]+)[Gg]$ ]]; then
        COUNT="${BASH_REMATCH[1]}"
        dd if=/dev/zero of="$SWAPFILE" bs=1G count="$COUNT" status=progress || \
            error "Failed to create swapfile with dd (GiB)."
    elif [[ "$SWAP_SIZE" =~ ^([0-9]+)[Mm]$ ]]; then
        COUNT="${BASH_REMATCH[1]}"
        dd if=/dev/zero of="$SWAPFILE" bs=1M count="$COUNT" status=progress || \
            error "Failed to create swapfile with dd (MiB)."
    else
        error "Unrecognized size during dd fallback."
    fi
fi

chmod 600 "$SWAPFILE" || error "Failed to set swapfile permissions."
mkswap "$SWAPFILE" || error "Failed to format swapfile."
swapon "$SWAPFILE" || error "Failed to enable swapfile."
message "Swapfile is now active."

# ==========================================
# 5. Persistence
# ==========================================
message "\nBacking up /etc/fstab..."
cp /etc/fstab "/etc/fstab.backup_$(date +%Y%m%d_%H%M%S)" || error "Backup failed."

if ! grep -q "^${SWAPFILE}" /etc/fstab; then
    echo "${SWAPFILE} none swap sw 0 0" | tee -a /etc/fstab > /dev/null
    message "Swapfile entry appended to /etc/fstab."
else
    sed -i "s|^${SWAPFILE}.*|${SWAPFILE} none swap sw 0 0|" /etc/fstab || error "Failed to update fstab."
    message "Swapfile entry updated in /etc/fstab."
fi

# ==========================================
# 6. Verification
# ==========================================
message "\nVerifying result:"
swapon --show
free -h
ls -lh "$SWAPFILE"

cat <<EOF

==========================================
SWAPFILE CONFIGURATION COMPLETE

Details:
- Location: $SWAPFILE
- Size: $SWAP_SIZE
- RAM: ${TOTAL_RAM_GB}GB

Manual verification:
  free -h
  swapon --show
==========================================
EOF

message "Script finished."
