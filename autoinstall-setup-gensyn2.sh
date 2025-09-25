cat > /usr/local/bin/create-swap-100g.sh <<'SWAP_SCRIPT'
#!/bin/bash
set -euo pipefail

# ==========================================
# Utility functions
# ==========================================
message(){ echo -e "\033[0;32m[INFO] $1\033[0m"; }
warning(){ echo -e "\033[0;33m[WARN] $1\033[0m"; }
error(){ echo -e "\033[0;31m[ERROR] $1\033[0m" >&2; exit 1; }

# ==========================================
# 1) Environment checks
# ==========================================
message "Starting custom swapfile configuration"

if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root"
fi

SWAPFILE="/swapfile"

# ==========================================
# 2) Manual size (prompt) with default 100G
# ==========================================
DEFAULT_SIZE="100G"
read -rp "Enter desired swap size (e.g. 16G or 4096M) [default: ${DEFAULT_SIZE}]: " INPUT_SIZE
SWAP_SIZE="${INPUT_SIZE:-$DEFAULT_SIZE}"

# Normalize and validate input (must end with G or M, positive integer)
if ! [[ "$SWAP_SIZE" =~ ^([1-9][0-9]*)[GgMm]$ ]]; then
  error "Invalid size. Use formats like 16G or 4096M."
fi

SIZE_NUM="${BASH_REMATCH[1]}"
SIZE_UNIT="${SWAP_SIZE: -1}"
[[ "$SIZE_UNIT" =~ [Gg] ]] && SIZE_UNIT_UP="G" || SIZE_UNIT_UP="M"

message "Swapfile size set to $SIZE_NUM$SIZE_UNIT_UP"

# ==========================================
# 3) System info
# ==========================================
message "\nSystem information:"
TOTAL_RAM_GB=$(free -g | awk '/Mem:/ {print $2}')
if [ "$TOTAL_RAM_GB" -eq 0 ]; then
  TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
  TOTAL_RAM_GB=$(( (TOTAL_RAM_MB + 1023) / 1024 ))
fi
echo " - Total RAM: ${TOTAL_RAM_GB}GB"
echo " - Swapfile to create: $SIZE_NUM$SIZE_UNIT_UP at $SWAPFILE"

# ==========================================
# 4) Setup swapfile
# ==========================================
message "\nDisabling any active swap..."
if swapon --show | grep -q "swap"; then
  swapoff -a || warning "Failed to disable some active swap entries."
  message "All active swap disabled."
else
  warning "No active swap detected."
fi

if [[ -f "$SWAPFILE" ]]; then
  message "Removing old swapfile: $SWAPFILE..."
  rm -f "$SWAPFILE" || error "Failed to remove old swapfile."
fi

message "Creating swapfile ($SIZE_NUM$SIZE_UNIT_UP) at $SWAPFILE..."
if ! fallocate -l "$SIZE_NUM$SIZE_UNIT_UP" "$SWAPFILE" 2>/dev/null; then
  warning "fallocate failed, falling back to dd..."
  if [[ "$SIZE_UNIT_UP" == "G" ]]; then
    dd if=/dev/zero of="$SWAPFILE" bs=1G count="$SIZE_NUM" status=progress || error "dd creation failed."
  else
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SIZE_NUM" status=progress || error "dd creation failed."
  fi
fi

chmod 600 "$SWAPFILE" || error "Failed to set permissions."
mkswap "$SWAPFILE"     || error "Failed to format swapfile."
swapon "$SWAPFILE"     || error "Failed to enable swapfile."
message "Swapfile is active."

# ==========================================
# 5) Persist in /etc/fstab
# ==========================================
message "\nBacking up /etc/fstab..."
cp /etc/fstab "/etc/fstab.backup_$(date +%Y%m%d_%H%M%S)" || error "Backup failed."

if ! grep -q "^${SWAPFILE}" /etc/fstab; then
  echo "${SWAPFILE} none swap sw 0 0" | tee -a /etc/fstab >/dev/null
  message "Swapfile entry added to /etc/fstab."
else
  sed -i "s|^${SWAPFILE}.*|${SWAPFILE} none swap sw 0 0|" /etc/fstab || error "fstab update failed."
  message "Swapfile entry updated in /etc/fstab."
fi

# ==========================================
# 6) Verify
# ==========================================
message "\nVerification:"
swapon --show
free -h
ls -lh "$SWAPFILE"

cat <<EOF

==========================================
SWAPFILE CONFIGURATION COMPLETE

Details:
- Location: $SWAPFILE
- Size: $SIZE_NUM$SIZE_UNIT_UP
- RAM: ${TOTAL_RAM_GB}GB

Manual verification:
  free -h
  swapon --show
==========================================
EOF

message "Done."
SWAP_SCRIPT
chmod +x /usr/local/bin/create-swap-100g.sh
