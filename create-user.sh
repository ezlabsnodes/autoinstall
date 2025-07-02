#!/bin/bash
set -e # Menghentikan skrip jika ada perintah yang gagal

# Fungsi untuk logging
log_info() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $1"
}

log_error() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $1" >&2
    exit 1
}

# Cek hak akses root
if [ "$EUID" -ne 0 ]; then
    log_error "Skrip ini harus dijalankan dengan hak akses root. Gunakan 'sudo'."
fi

# --- Input untuk Pengguna ---
read -p "Masukkan nama pengguna baru: " USER_NAME
read -s -p "Masukkan kata sandi untuk $USER_NAME: " USER_PASS
echo # Baris baru setelah input sandi
read -s -p "Konfirmasi kata sandi untuk $USER_NAME: " USER_PASS_CONFIRM
echo # Baris baru setelah input sandi

if [ "$USER_PASS" != "$USER_PASS_CONFIRM" ]; then
    log_error "Kata sandi tidak cocok. Silakan coba lagi."
fi

log_info "Membuat pengguna $USER_NAME..."
sudo adduser "$USER_NAME" --gecos "" --disabled-password || log_error "Gagal membuat pengguna $USER_NAME."
echo "${USER_NAME}:${USER_PASS}" | sudo chpasswd || log_error "Gagal mengatur kata sandi untuk $USER_NAME."
log_info "Pengguna $USER_NAME berhasil dibuat dan kata sandi diatur."

log_info "Memberikan akses root (sudo) ke $USER_NAME..."
sudo usermod -aG sudo "$USER_NAME" || log_error "Gagal memberikan akses sudo ke $USER_NAME."
log_info "Akses sudo diberikan kepada $USER_NAME."

log_info "Proses pembuatan pengguna selesai."
