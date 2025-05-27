#!/bin/bash

# Versi Docker Compose
DOCKER_COMPOSE_VERSION="v2.24.5"

# Fungsi untuk menampilkan pesan informasi
info() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

# Fungsi untuk menampilkan peringatan
warn() {
    echo -e "\033[1;33m[WARN]\033[0m $1"
}

# Fungsi untuk menginstal paket
install_packages() {
    sudo apt-get install -y "$@"
}

# ==========================================
# Validasi pengguna root
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo "Silakan jalankan skrip ini sebagai root atau menggunakan sudo."
    exit 1
fi

# ==========================================
# Instalasi Docker
# ==========================================
info "Memulai instalasi Docker..."
install_packages \
    apt-transport-https ca-certificates curl software-properties-common lsb-release gnupg2

# Menambahkan repository Docker
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin

# ==========================================
# Instalasi Docker Compose
# ==========================================
info "Menginstal Docker Compose..."
sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Instal sebagai plugin Docker CLI
DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
mkdir -p $DOCKER_CONFIG/cli-plugins
curl -SL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" -o $DOCKER_CONFIG/cli-plugins/docker-compose
chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose

# ==========================================
# Konfigurasi Pengguna
# ==========================================
info "Konfigurasi grup pengguna..."
sudo groupadd -f docker

# Mendeteksi username yang sedang digunakan
CURRENT_USER=$(logname 2>/dev/null || echo $SUDO_USER)
[ -z "$CURRENT_USER" ] && CURRENT_USER=$(whoami)

if id "$CURRENT_USER" &>/dev/null; then
    sudo usermod -aG docker "$CURRENT_USER"
    info "Pengguna $CURRENT_USER ditambahkan ke grup docker."
else
    warn "Pengguna $CURRENT_USER tidak ditemukan, proses tambah grup dilewati."
fi

info "Instalasi selesai. Silakan logout dan login kembali untuk menerapkan perubahan grup docker."
info "Verifikasi instalasi dengan perintah: docker run hello-world"
