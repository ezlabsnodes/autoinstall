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
