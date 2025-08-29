#!/usr/bin/env bash
set -Eeuo pipefail

ok(){ echo -e "\033[1;32m$*\033[0m"; }
warn(){ echo -e "\033[1;33m$*\033[0m"; }
err(){ echo -e "\033[1;31m$*\033[0m" >&2; }
trap 'err "Error on line $LINENO. Exiting."' ERR

# Re-exec as root (we’ll run user-space steps as the original user)
if [ "$EUID" -ne 0 ]; then
  echo "[INFO] Elevating to root…"
  exec sudo -E bash "$0" "$@"
fi
export DEBIAN_FRONTEND=noninteractive

# Resolve original user/home so $HOME in user steps is correct
ORIG_USER=${SUDO_USER:-$(logname 2>/dev/null || whoami)}
ORIG_HOME=$(getent passwd "$ORIG_USER" | cut -d: -f6)

# =========================================================
# STEP 1 — Swap 100GB + optimize (REPLACED WITH YOUR SCRIPT)
# =========================================================
ok "[1/3] Writing swap/optimize script (100G)…"
cat > /usr/local/bin/kuzco-swap-100g.sh <<'SWAP100'
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
SWAP100
chmod +x /usr/local/bin/kuzco-swap-100g.sh
/usr/local/bin/kuzco-swap-100g.sh

# ======================================================
# STEP 2 — Dependencies (Node.js + Yarn) — KEEP FUNCTIONS
# ======================================================
ok "[2/3] Installing Node.js/Yarn & build tools…"
cat > /usr/local/bin/depedency-nodejs.sh <<'DEPS'
#!/bin/bash
set -euo pipefail

USERNAME=$(whoami)
ARCH=$(uname -m)

function info() {
    echo -e "\033[1;32m[INFO] $1\033[0m"
}

function warn() {
    echo -e "\033[1;33m[WARN] $1\033[0m"
}

function error() {
    echo -e "\033[1;31m[ERROR] $1\033[0m" >&2
    exit 1
}

function install_packages() {
    info "Installing packages: $*"
    sudo apt-get install -y "$@" || {
        error "Failed to install packages: $*"
    }
}

function command_exists() {
    command -v "$1" &> /dev/null
}

info "Checking system architecture..."
if [ "$ARCH" != "x86_64" ]; then
    warn "Non-x86_64 architecture detected ($ARCH), some packages might need adjustment"
fi

if ! sudo -v; then
    error "This script requires sudo privileges"
fi

info "Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get autoremove -y

info "Installing essential build tools..."
install_packages \
    git clang cmake build-essential openssl pkg-config libssl-dev \
    wget htop tmux jq make gcc tar ncdu protobuf-compiler \
    default-jdk aptitude squid apache2-utils file lsof zip unzip \
    iptables iptables-persistent openssh-server sed lz4 aria2 pv \
    python3 python3-venv python3-pip python3-dev screen snapd flatpak \
    nano automake autoconf nvme-cli libgbm-dev libleveldb-dev bsdmainutils unzip \
    ca-certificates curl gnupg lsb-release software-properties-common

info "Checking Node.js installation..."

if command_exists node; then
    CURRENT_NODE=$(node --version)
    CURRENT_NPM=$(npm --version)
    info "Node.js already installed: $CURRENT_NODE"
    info "npm already installed: $CURRENT_NPM"
    
    info "Checking for Node.js updates..."
    LATEST_NODE_VERSION=$(curl -fsSL https://nodejs.org/dist/latest-v18.x/SHASUMS256.txt | grep -oP 'node-v\K\d+\.\d+\.\d+-linux-x64' | head -1 | cut -d'-' -f1)
    if [ "$(node --version | cut -d'v' -f2)" != "$LATEST_NODE_VERSION" ]; then
        warn "Newer Node.js version available ($LATEST_NODE_VERSION)"
        info "Consider updating using:"
        info "  sudo npm install -g n"
        info "  sudo n lts"
    fi
else
    info "Adding NodeSource repository..."
    if ! curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -; then
        error "Failed to set up NodeSource repository"
    fi
    
    install_packages nodejs

    if ! command_exists node; then
        error "Node.js installation failed"
    fi
    
    info "Updating npm to latest version..."
    if ! sudo npm install -g npm@latest; then
        warn "Failed to update npm to latest version"
    fi
    
    info "Node.js installed: $(node --version)"
    info "npm installed: $(npm --version)"
fi

if ! command_exists yarn; then
    if grep -qi "ubuntu" /etc/os-release 2> /dev/null || uname -r | grep -qi "microsoft"; then
        info "Detected Ubuntu or WSL Ubuntu. Installing Yarn via apt..."
        curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
        echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
        sudo apt update && sudo apt install -y yarn
    else
        info "Yarn not found. Installing Yarn globally with npm..."
        npm install -g --silent yarn
    fi
    
    if ! command_exists yarn; then
        warn "Yarn installation might have failed"
    else
        info "Yarn installed: $(yarn --version)"
    fi
else
    info "Yarn already installed: $(yarn --version)"
fi

info "Verifying installations..."

info "=== Installed Versions ==="
info "Node.js: $(node --version 2>/dev/null || echo 'Not installed')"
info "npm: $(npm --version 2>/dev/null || echo 'Not installed')"
info "Yarn: $(yarn --version 2>/dev/null || echo 'Not installed')"

info "Installation completed successfully!"
info "You may need to restart your shell or run 'source ~/.bashrc' for changes to take effect."
DEPS
chmod +x /usr/local/bin/depedency-nodejs.sh
/usr/local/bin/depedency-nodejs.sh

# Ensure extras for gensyn
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y expect unzip >/dev/null 2>&1 || true

# =================================================
# STEP 3 — Run gensyn node (KEEP functions/behavior)
# =================================================
ok "[3/3] Preparing & launching gensyn (screen: gensyn)…"
sudo -u "$ORIG_USER" bash -lc '
set -Eeuo pipefail

# Remove Old files
rm -f officialauto.zip nonofficialauto.zip
rm -f original.zip original2.zip ezlabs.zip ezlabs2.zip ezlabs3.zip ezlabs4.zip ezlabs5.zip ezlabs6.zip ezlabs7.zip ezlabs8.zip

# Create directory "ezlabs"
mkdir -p "$HOME/ezlabs"

# Copy files to "ezlabs" if they exist
[ -f "$HOME/rl-swarm/modal-login/temp-data/userApiKey.json" ] && cp "$HOME/rl-swarm/modal-login/temp-data/userApiKey.json" "$HOME/ezlabs/" || true
[ -f "$HOME/rl-swarm/modal-login/temp-data/userData.json" ] && cp "$HOME/rl-swarm/modal-login/temp-data/userData.json" "$HOME/ezlabs/" || true
[ -f "$HOME/rl-swarm/swarm.pem" ] && cp "$HOME/rl-swarm/swarm.pem" "$HOME/ezlabs/" || true

# Close Screen and Remove Old Repository
screen -XS gensyn quit || true
cd "$HOME"
rm -rf rl-swarm

# Download and Unzip officialauto.zip, then change to rl-swarm directory
wget -q https://github.com/ezlabsnodes/gensyn/raw/refs/heads/main/officialauto.zip -O "$HOME/officialauto.zip" && \
unzip -o "$HOME/officialauto.zip" -d "$HOME" >/dev/null && \
cd "$HOME/rl-swarm"

# Copy swarm.pem to $HOME/rl-swarm/
[ -f "$HOME/ezlabs/swarm.pem" ] && cp "$HOME/ezlabs/swarm.pem" "$HOME/rl-swarm/" || true

# Create Screen and run commands
python3 -m venv .venv
source .venv/bin/activate
chmod +x run_rl_swarm.sh
screen -S gensyn -dm bash -c "source .venv/bin/activate && CPU_ONLY=true ./run_rl_swarm.sh"

echo "Script completed. The '\''gensyn'\'' screen session should be running in the background."
echo "Check logs : tail -f $HOME/rl-swarm/logs/swarm_launcher.log"
'

ok "gensyn launched in background (screen session: gensyn)."

echo
echo "Follow logs:"
echo "  sudo -u $ORIG_USER tail -f \"$ORIG_HOME/rl-swarm/logs/swarm_launcher.log\""
echo "Attach to screen:"
echo "  sudo -u $ORIG_USER screen -r gensyn"
echo "Detach from screen:  Ctrl+A, then D"
