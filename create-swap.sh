#!/bin/bash
set -euo pipefail # Menghentikan skrip jika ada perintah yang gagal dan jika variabel tidak diatur

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
message "Memulai konfigurasi swapfile otomatis (2x RAM)"

# Cek root
if [[ $EUID -ne 0 ]]; then
    error "Script harus dijalankan sebagai root"
fi

# Skip if already optimized by optimize_fixed.sh
if [ -f /etc/sysctl.d/99-kuzco.conf ]; then
    message "Deteksi sistem sudah dioptimasi oleh optimize_fixed.sh"
    message "Script ini hanya akan mengatur swapfile saja"
fi

# ==========================================
# 2. Konfigurasi Swapfile - Ukuran Otomatis (2x RAM)
# ==========================================
SWAPFILE="/swapfile"

# Hitung RAM yang tersedia dalam GB (dibundel ke bawah)
TOTAL_RAM_GB=$(free -g | awk '/Mem:/ {print $2}')
# Jika free -g memberikan output 0GB untuk RAM kecil, gunakan MB dan konversi
if [ "$TOTAL_RAM_GB" -eq 0 ]; then
    TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
    TOTAL_RAM_GB=$(( (TOTAL_RAM_MB + 1023) / 1024 )) # Bulatkan ke atas jika ada MB, konversi ke GB
fi


# Ukuran swap yang diinginkan: 2x RAM dalam GB
SWAP_SIZE="${TOTAL_RAM_GB}G"

# Jika RAM sangat kecil (misal < 1GB), kita bisa asumsikan 2GB swap sebagai minimum
if (( TOTAL_RAM_GB < 1 )); then
    SWAP_SIZE="2G" # Contoh: Minimum 2GB swap
    warning "Total RAM sangat kecil (${TOTAL_RAM_GB}GB), menggunakan swapfile minimum 2GB."
else
    # Untuk RAM 1GB atau lebih, gunakan 2x RAM
    SWAP_SIZE="$((TOTAL_RAM_GB * 2))G"
fi


message "\nInformasi sistem:"
echo " - Total RAM: ${TOTAL_RAM_GB}GB"
echo " - Ukuran swapfile yang akan dibuat: $SWAP_SIZE"

# ==========================================
# 3. Setup Swapfile
# ==========================================

# Nonaktifkan swap yang ada
message "\nMenonaktifkan swap yang aktif..."
# Menggunakan `grep -q` untuk memeriksa apakah ada baris "swap" di `swapon --show`
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
    # Ekstrak angka dan unit dari SWAP_SIZE
    NUMERIC_SIZE=$(echo "$SWAP_SIZE" | sed 's/[GgMm]$//')
    UNIT=$(echo "$SWAP_SIZE" | grep -o '[GgMm]$' | tr '[:upper:]' '[:lower:]')

    # Konversi ke byte count untuk dd
    BLOCK_SIZE="1M" # Default block size for dd
    COUNT=$NUMERIC_SIZE

    if [ "$UNIT" == "g" ]; then
        COUNT=$((NUMERIC_SIZE * 1024)) # Konversi GB ke MB
    fi
    # Jika unit adalah 'm', count sudah dalam MB

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
# 4. Konfigurasi Permanen
# ==========================================

# Backup fstab
message "\nMembackup /etc/fstab..."
cp /etc/fstab "/etc/fstab.backup_$(date +%Y%m%d_%H%M%S)" || error "Gagal membackup /etc/fstab."
message "Backup /etc/fstab dibuat: /etc/fstab.backup_$(date +%Y%m%d_%H%M%S)"

# Update fstab
if ! grep -q "^${SWAPFILE}" /etc/fstab; then
    echo "${SWAPFILE} none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null
    message "Swapfile ditambahkan ke /etc/fstab."
else
    # Jika sudah ada, pastikan barisnya benar
    if ! grep -q "^${SWAPFILE} none swap sw 0 0$" /etc/fstab; then
        # Jika ada tapi formatnya salah, update
        sudo sed -i "s|^\(${SWAPFILE}\s\+.*\)|${SWAPFILE} none swap sw 0 0|" /etc/fstab || error "Gagal memperbarui entri swapfile di /etc/fstab."
        message "Entri swapfile di /etc/fstab diperbarui."
    else
        message "Swapfile sudah terdaftar dengan benar di /etc/fstab."
    fi
fi

# ==========================================
# 5. Verifikasi
# ==========================================
message "\nVerifikasi hasil:"

message "1. Status swap:"
swapon --show || error "Swap tidak aktif setelah konfigurasi."

message "\n2. Penggunaan memori:"
free -h

message "\n3. Detail swapfile:"
ls -lh "$SWAPFILE"

# ==========================================
# 6. Selesai
# ==========================================
cat <<EOF

==========================================
KONFIGURASI SWAPFILE SELESAI

Detail:
- Lokasi: $SWAPFILE
- Ukuran: $SWAP_SIZE
- RAM: ${TOTAL_RAM_GB}GB

Untuk verifikasi:
free -h
swapon --show

==========================================
EOF

message "Script swapfile selesai dijalankan."
