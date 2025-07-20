#!/bin/bash
set -euo pipefail  # Strict error handling

# ==========================================
# Configuration Variables
# ==========================================
USERNAME=$(whoami)
CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"

# ==========================================
# Utility Functions
# ==========================================
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
    sudo apt-get install -y --no-install-recommends "$@" || {
        error "Failed to install packages: $*"
    }
}

function add_to_path() {
    local path_to_add="$1"
    local shell_rc="$HOME/.bashrc"
    
    if ! grep -q "$path_to_add" "$shell_rc"; then
        echo "export PATH=\"$path_to_add:\$PATH\"" >> "$shell_rc"
        info "Added $path_to_add to PATH in $shell_rc"
    fi
}

# ==========================================
# System Update
# ==========================================
info "Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get autoremove -y

# ==========================================
# Install Essential Packages
# ==========================================
info "Installing essential build tools..."
install_packages \
    git clang cmake build-essential openssl pkg-config libssl-dev \
    wget htop tmux jq make gcc tar ncdu protobuf-compiler \
    default-jdk aptitude squid apache2-utils file lsof zip unzip \
    iptables iptables-persistent openssh-server sed lz4 aria2 pv \
    python3 python3-venv python3-pip python3-dev screen snapd flatpak \
    nano automake autoconf nvme-cli libgbm-dev libleveldb-dev bsdmainutils \
    ca-certificates curl gnupg lsb-release software-properties-common \
    libclang-dev llvm-dev libpq-dev libsqlite3-dev

# ==========================================
# Rust Installation
# ==========================================
info "Checking Rust installation..."

if command -v rustc &>/dev/null; then
    info "Rust already installed: $(rustc --version)"
else
    info "Installing Rust..."
    
    # Ensure curl is available
    if ! command -v curl &>/dev/null; then
        install_packages curl
    fi

    # Install Rust non-interactively
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --no-modify-path --profile default --default-toolchain stable
    
    # Configure environment
    add_to_path "$CARGO_HOME/bin"
    export PATH="$CARGO_HOME/bin:$PATH"
    
    # Verify installation
    if ! command -v rustc &>/dev/null; then
        error "Rust installation failed - rustc not found"
    fi
    
    info "Rust installed successfully: $(rustc --version)"
fi

# Install common Rust tools
info "Installing common Rust tools..."
"$CARGO_HOME/bin/cargo" install --locked \
    cargo-edit \
    cargo-watch \
    cargo-audit \
    cargo-update \
    cargo-tree \
    cargo-outdated \
    cargo-expand \
    cargo-udeps

# ==========================================
# System Configuration
# ==========================================
info "Configuring system settings..."

# Enable services
sudo systemctl enable --now netfilter-persistent
sudo systemctl enable --now ssh

# Configure ulimits
if ! grep -q "Increased limits" /etc/security/limits.conf; then
    sudo tee -a /etc/security/limits.conf >/dev/null <<EOF
# Increased limits
* soft nofile 65536
* hard nofile 65536
* soft nproc 65536
* hard nproc 65536
EOF
    info "Increased system limits"
fi

# ==========================================
# Cleanup
# ==========================================
info "Cleaning up..."
sudo apt-get autoremove -y
sudo apt-get clean

# ==========================================
# Completion Message
# ==========================================
cat <<EOF

================================================
INSTALLATION COMPLETE!

What's installed:
- System tools: git, tmux, htop, etc.
- Build tools: clang, cmake, make, etc.
- Rust toolchain: $(rustc --version || echo "Not detected")
- Cargo tools: cargo-edit, cargo-watch, etc.

Next steps:
1. Source your bashrc: source ~/.bashrc
2. Verify Rust: rustc --version
3. Check cargo: cargo --version

EOF
