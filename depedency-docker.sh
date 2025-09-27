#!/usr/bin/env bash
# shellcheck shell=bash

# Pisah 'pipefail' agar tak error di shell yang tidak mendukung
set -Eeuo

# Aktifkan pipefail hanya jika tersedia
if (set -o 2>/dev/null | grep -q '^pipefail'); then
  set -o pipefail
fi

# ========== UI helpers ==========
GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
status(){ echo -e "\n${BLUE}>>> $*${NC}"; }
trap 'error "Failed at line $LINENO"' ERR

# ========== Self-heal CRLF ==========
# Jika file ini masih berakhiran CRLF (Windows), konversi lalu re-exec
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
  if grep -q $'\r' "${BASH_SOURCE[0]}"; then
    warn "Detected CRLF line endings — converting to LF and re-running…"
    tmp="$(mktemp)"
    tr -d '\r' < "${BASH_SOURCE[0]}" > "$tmp"
    chmod +x "$tmp"
    exec "$tmp" "$@"
  fi
fi

# ========== Elevate to root ==========
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  info "Elevating to root with sudo…"
  exec sudo -E bash "$0" "$@"
fi
export DEBIAN_FRONTEND=noninteractive

# ========== Facts ==========
USERNAME=${SUDO_USER:-$(whoami)}
ARCH=$(uname -m || echo unknown)
OSREL="/etc/os-release"
DISTRO=$(grep -E '^ID=' "$OSREL" 2>/dev/null | cut -d= -f2 | tr -d '"')
CODENAME=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}" || true)
CODENAME=${CODENAME:-$(lsb_release -cs 2>/dev/null || echo "")}
WSL=$([[ "$(uname -r || true)" =~ microsoft ]] && echo "yes" || echo "no")

status "Environment"
info "User:     $USERNAME"
info "Arch:     $ARCH"
info "Distro:   ${DISTRO:-unknown}"
info "Codename: ${CODENAME:-unknown}"
info "WSL:      $WSL"

if [[ -z "$CODENAME" ]]; then
  error "Cannot determine Ubuntu codename (VERSION_CODENAME)."
fi

# ========== Helpers ==========
command_exists(){ command -v "$1" >/dev/null 2>&1; }

# ========== System Update ==========
status "Update system packages"
apt-get update -y
apt-get upgrade -y
apt-get autoremove -y || true

# Dependencies needed before adding repos/keys
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release software-properties-common

# (Optional but useful base toolset)
apt-get install -y --no-install-recommends \
  git build-essential wget jq tar

# ========== Docker Installation ==========
status "Docker installation"

if ! command_exists docker; then
  info "Setting up Docker APT repository…"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y

  info "Installing Docker Engine + CLI + containerd + Buildx + Compose plugin…"
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Enable and start (on non-WSL)
  if [[ "$WSL" != "yes" ]]; then
    systemctl enable docker || warn "systemctl enable docker failed (ok on WSL/containers)."
    systemctl restart docker || warn "systemctl restart docker failed (ok on WSL/containers)."
  fi

  # Add user to docker group (if not already)
  if ! id -nG "$USERNAME" | grep -qw docker; then
    info "Adding user '$USERNAME' to 'docker' group…"
    usermod -aG docker "$USERNAME" || warn "Failed to add '$USERNAME' to docker group."
  fi
else
  info "Docker already installed: $(docker --version)"
fi

# Compose plugin check
if docker compose version >/dev/null 2>&1; then
  info "Docker Compose plugin present: $(docker compose version | head -n1)"
else
  warn "Docker Compose plugin not detected. Trying to install the plugin package…"
  apt-get install -y docker-compose-plugin || warn "Failed to install docker-compose-plugin."
fi

# ========== Final Report ==========
status "Installed versions"
info "Docker: $(docker --version 2>/dev/null || echo 'Not installed')"
info "Compose: $(docker compose version 2>/dev/null | head -n1 || echo 'Not installed')"

status "Next steps"
info "If this is your first Docker install for '$USERNAME':"
info " - Open a NEW shell session or run: newgrp docker"
info " - On WSL, ensure Docker service is managed by Docker Desktop or a suitable init."

# ========== Notes ==========
# Jika Anda masih melihat error seperti: $'\r': command not found
# Pastikan file ini sudah LF. Alternatif manual:
#   sed -i 's/\r$//' install-docker.sh
#   # atau
#   apt-get install -y dos2unix && dos2unix install-docker.sh

