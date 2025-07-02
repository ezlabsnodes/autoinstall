#!/bin/bash

# --- FUNGSI LOGGING ---
log_info() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $1"
}

log_error() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $1" >&2
    exit 1
}

# --- CEK HAK AKSES ROOT ---
if [ "$EUID" -ne 0 ]; then
    log_error "Skrip ini harus dijalankan dengan hak akses root. Gunakan 'sudo'."
fi

# --- DEFINISI VARIABEL ---
DEVICE="/dev/vdb"
PARTITION="${DEVICE}1"
MOUNT_POINT="/home"
FSTAB_ENTRY="" # Akan diisi nanti setelah mendapatkan UUID

log_info "Memulai proses format dan mount ${PARTITION} ke ${MOUNT_POINT} secara otomatis."
log_info "PERINGATAN: Semua data di ${PARTITION} akan dihapus tanpa konfirmasi."

# --- 1. UNMOUNT PARTISI JIKA TER-MOUNT ---
log_info "Mencoba unmount ${PARTITION} jika ter-mount..."
if mountpoint -q "$PARTITION"; then
    sudo umount "$PARTITION" || log_error "Gagal meng-unmount ${PARTITION}."
    log_info "${PARTITION} berhasil di-unmount."
else
    log_info "${PARTITION} tidak ter-mount."
fi

# --- 2. HAPUS DAN BUAT ULANG PARTISI ---
log_info "Menghapus dan membuat ulang partisi di ${DEVICE} dengan label GPT dan partisi tunggal ext4..."
# Menggunakan parted untuk membuat partisi GPT dan partisi tunggal
echo "label: gpt
mkpart primary ext4 0% 100%" | sudo parted -s "$DEVICE" mklabel gpt mkpart primary ext4 0% 100% || log_error "Gagal membuat partisi baru di ${DEVICE}."
log_info "Partisi ${PARTITION} berhasil dibuat ulang."
sleep 2 # Beri sedikit waktu agar kernel mengenali partisi baru

# --- 3. FORMAT PARTISI ---
log_info "Memformat ${PARTITION} dengan sistem file ext4..."
sudo mkfs.ext4 -F "$PARTITION" || log_error "Gagal memformat ${PARTITION}."
log_info "Partisi ${PARTITION} berhasil diformat."

# --- 4. TANGANI DIREKTORI /HOME YANG ADA ---
log_info "Menangani direktori ${MOUNT_POINT} yang ada..."
if [ -d "$MOUNT_POINT" ] && [ "$(ls -A $MOUNT_POINT)" ]; then
    log_info "Direktori ${MOUNT_POINT} tidak kosong. Membackupnya ke ${MOUNT_POINT}_old."
    sudo mv "$MOUNT_POINT" "${MOUNT_POINT}_old" || log_error "Gagal membackup ${MOUNT_POINT}."
elif [ -d "$MOUNT_POINT" ]; then
    log_info "Direktori ${MOUNT_POINT} kosong atau tidak berisi data yang perlu dipindahkan. Melanjutkan."
fi

# Buat ulang direktori mount point
if [ ! -d "$MOUNT_POINT" ]; then
    log_info "Membuat direktori mount point ${MOUNT_POINT}..."
    sudo mkdir -p "$MOUNT_POINT" || log_error "Gagal membuat direktori ${MOUNT_POINT}."
fi

# --- 5. MOUNT PARTISI ---
log_info "Me-mount ${PARTITION} ke ${MOUNT_POINT}..."
sudo mount "$PARTITION" "$MOUNT_POINT" || log_error "Gagal me-mount ${PARTITION} ke ${MOUNT_POINT}."
log_info "Partisi ${PARTITION} berhasil di-mount ke ${MOUNT_POINT}."

# --- 6. PERBARUI /ETC/FSTAB ---
log_info "Mendapatkan UUID untuk ${PARTITION}..."
UUID=$(sudo blkid -s UUID -o value "$PARTITION")
if [ -z "$UUID" ]; then
    log_error "Gagal mendapatkan UUID untuk ${PARTITION}."
fi
log_info "UUID ${PARTITION}: ${UUID}"

FSTAB_ENTRY="UUID=${UUID} ${MOUNT_POINT} ext4 defaults 0 2"

log_info "Menambahkan entri ke /etc/fstab..."
# Cek apakah entri sudah ada
if grep -q "$MOUNT_POINT" /etc/fstab; then
    log_info "Entri untuk ${MOUNT_POINT} sudah ada di /etc/fstab. Memperbarui entri yang ada."
    sudo sed -i "s|.* ${MOUNT_POINT} .*|${FSTAB_ENTRY}|" /etc/fstab || log_error "Gagal memperbarui /etc/fstab."
else
    log_info "Menambahkan entri baru ke /etc/fstab."
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab > /dev/null || log_error "Gagal menambahkan entri ke /etc/fstab."
fi
log_info "/etc/fstab berhasil diperbarui."

# --- 7. VERIFIKASI ---
log_info "Verifikasi hasil..."
sleep 2 # Beri sedikit waktu agar sistem merespons
sudo lsblk "$DEVICE"
echo ""
sudo df -h "$MOUNT_POINT"

log_info "Proses selesai. ${PARTITION} sekarang sudah diformat, di-mount ke ${MOUNT_POINT}, dan diatur untuk mount otomatis saat boot."
log_info "Jika ada data di ${MOUNT_POINT}_old, Anda dapat memindahkannya secara manual ke ${MOUNT_POINT} sekarang."
