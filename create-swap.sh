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
# 2. Input Ukuran Swap Custom
# ==========================================
message "Masukkan ukuran swapfile yang diinginkan"
echo "Contoh format: 4G, 8G, 16G, 4096M, 8192M"
read -p "Ukuran swapfile: " SWAP_SIZE

# Validasi input
if [[ ! "$SWAP_SIZE" =~ ^[0-9]+[GgMm]$ ]]; then
    error "Format tidak valid. Gunakan format seperti: 4G, 8G, 4096M"
fi

# ==========================================
# 3. Konfigurasi Swapfile
# ==========================================
SWAPFILE="/swapfile"

message "\nInformasi sistem:"
TOTAL_RAM_GB=$(free -g | awk '/Mem:/ {print $2}')
if [ "$TOTAL_RAM_GB" -eq 0 ]; then
    TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
    TOTAL_RAM_GB=$(( (TOTAL_RAM_MB + 1023) / 1024 ))
fi

echo " - Total RAM: ${TOTAL_RAM_GB}GB"
echo " - Ukuran swapfile yang akan dibuat: $SWAP_SIZE"

# Periksa ruang disk
AVAILABLE_SPACE_KB=$(df / | awk 'NR==2 {print $4}')
NUMERIC_SIZE=$(echo "$SWAP_SIZE" | sed 's/[GgMm]$//')
UNIT=$(echo "$SWAP_SIZE" | grep -o '[GgMm]$' | tr '[:upper:]' '[:lower:]')

# Konversi ke KB
if [ "$UNIT" == "g" ]; then
    SWAP_SIZE_KB=$((NUMERIC_SIZE * 1024 * 1024))
else
    SWAP_SIZE_KB=$((NUMERIC_SIZE * 1024))
fi

# Periksa apakah ruang cukup
if [ "$AVAILABLE_SPACE_KB" -lt "$SWAP_SIZE_KB" ]; then
    AVAILABLE_SPACE_MB=$((AVAILABLE_SPACE_KB / 1024))
    warning "Ruang disk tidak cukup di root partition!"
    echo "Tersedia: ${AVAILABLE_SPACE_MB}M, Dibutuhkan: ${SWAP_SIZE}"
    
    read -p "Gunakan lokasi alternatif? (y/N): " USE_ALT_LOCATION
    if [[ "$USE_ALT_LOCATION" =~ ^[Yy]$ ]]; then
        message "Partisi yang tersedia:"
        df -h | grep -E "^(/dev/|Filesystem)" | head -6
        read -p "Masukkan path mount point alternatif (contoh: /home): " ALTERNATIVE_PATH
        
        if [ ! -d "$ALTERNATIVE_PATH" ]; then
            error "Path $ALTERNATIVE_PATH tidak valid"
        fi
        
        SWAPFILE="${ALTERNATIVE_PATH}/swapfile"
        message "Menggunakan lokasi alternatif: $SWAPFILE"
    else
        error "Ruang disk tidak cukup. Batalkan operasi."
    fi
fi

# ==========================================
# 4. Setup Swapfile
# ==========================================

# Nonaktifkan swap yang ada
message "\nMenonaktifkan swap yang aktif..."
if swapon --show | grep -q "swap"; then
    swapoff -a || warning "Gagal menonaktifkan beberapa swap aktif."
    message "Semua swap aktif telah dinonaktifkan."
else
    warning "Tidak ada swap aktif yang terdeteksi."
fi

# Hapus swapfile lama jika ada
if [[ -f "$SWAPFILE" ]]; then
    message "Menghapus swapfile lama: $SWAPFILE..."
    rm -f "$SWAPFILE" || error "Gagal menghapus swapfile lama."
fi

# Buat swapfile baru
message "Membuat swapfile baru ($SWAP_SIZE) di $SWAPFILE..."
if ! fallocate -l "$SWAP_SIZE" "$SWAPFILE"; then
    warning "fallocate gagal, mencoba menggunakan dd. Ini mungkin memakan waktu lebih lama..."
    
    BLOCK_SIZE="1M"
    if [ "$UNIT" == "g" ]; then
        COUNT=$((NUMERIC_SIZE * 1024))
    else
        COUNT=$NUMERIC_SIZE
    fi

    dd if=/dev/zero of="$SWAPFILE" bs=$BLOCK_SIZE count=$COUNT status=progress ||
        error "Gagal membuat swapfile dengan dd."
fi

# Set permission
chmod 600 "$SWAPFILE" || error "Gagal mengatur permission swapfile."
message "Permission ${SWAPFILE} diatur ke 600."

# Format sebagai swap
mkswap "$SWAPFILE" || error "Gagal memformat swapfile."
message "Swapfile diformat sebagai swap."

# Aktifkan swap
swapon "$SWAPFILE" || error "Gagal mengaktifkan swapfile."
message "Swapfile diaktifkan."

# ==========================================
# 5. Konfigurasi Permanen
# ==========================================

# Backup fstab
message "\nMembackup /etc/fstab..."
cp /etc/fstab "/etc/fstab.backup_$(date +%Y%m%d_%H%M%S)" || error "Gagal membackup /etc/fstab."

# Update fstab
if ! grep -q "^${SWAPFILE}" /etc/fstab; then
    echo "${SWAPFILE} none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null
    message "Swapfile ditambahkan ke /etc/fstab."
else
    if ! grep -q "^${SWAPFILE} none swap sw 0 0$" /etc/fstab; then
        sudo sed -i "s|^\(${SWAPFILE}\s\+.*\)|${SWAPFILE} none swap sw 0 0|" /etc/fstab || error "Gagal memperbarui entri swapfile di /etc/fstab."
        message "Entri swapfile di /etc/fstab diperbarui."
    else
        message "Swapfile sudah terdaftar dengan benar di /etc/fstab."
    fi
fi

# ==========================================
# 6. Verifikasi
# ==========================================
message "\nVerifikasi hasil:"

message "1. Status swap:"
swapon --show || error "Swap tidak aktif setelah konfigurasi."

message "\n2. Penggunaan memori:"
free -h

message "\n3. Detail swapfile:"
ls -lh "$SWAPFILE"

# ==========================================
# 7. Selesai
# ==========================================
cat <<EOF

==========================================
KONFIGURASI SWAPFILE CUSTOM SELESAI

Detail:
- Lokasi: $SWAPFILE
- Ukuran: $SWAP_SIZE
- RAM: ${TOTAL_RAM_GB}GB

Untuk verifikasi:
free -h
swapon --show

==========================================
EOF

message "Script swapfile custom selesai dijalankan."
