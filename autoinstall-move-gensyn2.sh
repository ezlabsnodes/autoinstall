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
# 2. Ukuran Swap (INPUT MANUAL)
# ==========================================
SWAPFILE="/swapfile"

while :; do
    read -rp "Masukkan ukuran swapfile (contoh: 4G atau 8192M): " SWAP_SIZE
    # valid: angka + G/g atau M/m
    if [[ "$SWAP_SIZE" =~ ^[0-9]+[GgMm]$ ]]; then
        break
    fi
    warning "Format tidak valid. Gunakan angka diikuti G atau M (misal 8G atau 4096M)."
done

message "Swapfile akan dibuat dengan ukuran: $SWAP_SIZE"

# ==========================================
# 3. Informasi Sistem
# ==========================================
message "\nInformasi sistem:"
TOTAL_RAM_GB=$(free -g | awk '/Mem:/ {print $2}')
if [ "${TOTAL_RAM_GB:-0}" -eq 0 ]; then
    TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
    TOTAL_RAM_GB=$(( (TOTAL_RAM_MB + 1023) / 1024 ))
fi

echo " - Total RAM: ${TOTAL_RAM_GB}GB"
echo " - Ukuran swapfile yang akan dibuat: $SWAP_SIZE"

# (opsional) cek ruang kosong di root mount
ROOT_AVAIL_BYTES=$(df --output=avail -B1 / | tail -1)
# konversi input ke byte untuk cek kasar
case "$SWAP_SIZE" in
  *[Gg]) REQ_BYTES=$(( ${SWAP_SIZE%[Gg]} * 1024 * 1024 * 1024 ));;
  *[Mm]) REQ_BYTES=$(( ${SWAP_SIZE%[Mm]} * 1024 * 1024 ));;
esac
if (( ROOT_AVAIL_BYTES <= REQ_BYTES )); then
    warning "Ruang kosong mungkin tidak cukup untuk membuat swap sebesar $SWAP_SIZE."
    read -rp "Lanjutkan tetap? [y/N]: " yn
    [[ "${yn,,}" == "y" ]] || error "Dibatalkan oleh pengguna."
fi

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
    # fallback dd dengan satuan sesuai input
    if [[ "$SWAP_SIZE" =~ ^([0-9]+)[Gg]$ ]]; then
        COUNT="${BASH_REMATCH[1]}"
        dd if=/dev/zero of="$SWAPFILE" bs=1G count="$COUNT" status=progress || \
            error "Gagal membuat swapfile dengan dd (GiB)."
    elif [[ "$SWAP_SIZE" =~ ^([0-9]+)[Mm]$ ]]; then
        COUNT="${BASH_REMATCH[1]}"
        dd if=/dev/zero of="$SWAPFILE" bs=1M count="$COUNT" status=progress || \
            error "Gagal membuat swapfile dengan dd (MiB)."
    else
        error "Ukuran tidak dikenali saat fallback dd."
    fi
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
