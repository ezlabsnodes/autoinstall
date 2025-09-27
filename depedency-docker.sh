#!/usr/bin/env bash
# Docker Engine + Compose (Ubuntu) — hardened, idempotent, CRLF/self-shell self-heal

# ========= Ensure we are using bash & LF =========
# If the file has CRLF, convert to LF and re-exec
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
  if grep -q $'\r' "${BASH_SOURCE[0]}"; then
    printf '[WARN] CRLF detected — converting to LF and re-running…\n' >&2
    _tmp="$(mktemp)"; tr -d '\r' < "${BASH_SOURCE[0]}" > "$_tmp"; chmod +x "$_tmp"
    exec "$_tmp" "$@"
  fi
fi

# If not running under bash, re-exec with bash
if [ -z "${BASH_VERSION:-}" ]; then
  printf '[INFO] Re-running with bash…\n' >&2
  exec bash "$0" "$@"
fi

# ========= Safe bash options (portable pipefail) =========
set -Eeuo # no 'pipefail' yet
# Enable pipefail only if supported (some shells/sh don’t have it)
if (set -o 2>/dev/null | grep -q '^pipefail'); then
  set -o pipefail
fi

# ========= UI helpers =========
GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
status(){ echo -e "\n${BLUE}>>> $*${NC}"; }
trap 'error "Failed at line $LINENO"' ERR

# ========= Elevate to root =========
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  info "Elevating to root with sudo…"
  exec sudo -E bash "$0" "$@"
fi
export DEBIAN_FRONTEND=noninteractive

# ========= Facts =========
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
if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]]; then
  warn "Non-standard arch detected ($ARCH). Binaries may differ."
fi

# ========= Helpers =========
command_exists(){ command -v "$1" >/dev/null 2>&1; }

# ========= System Update & base tools =========
status "Update system packages"
apt-get update -y
apt-get upgrade -y
apt-get autoremove -y || true

apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release software-properties-common

# Optional but handy:
apt-get install -y --no-install-recommends \
  git build-essential wget jq tar

# ========= Docker Installation =========
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

  # Enable/restart service when available (skip on WSL)
  if [[ "$WSL" != "yes" ]]; then
    systemctl enable docker || warn "systemctl enable docker failed (OK on WSL/containers)."
    systemctl restart docker || warn "systemctl restart docker failed (OK on WSL/containers)."
  fi

  # Add user to docker group
  if ! id -nG "$USERNAME" | grep -qw docker; then
    info "Adding user '$USERNAME' to 'docker' group…"
    usermod -aG docker "$USERNAME" || warn "Failed to add '$USERNAME' to docker group."
  fi
else
  info "Docker already installed: $(docker --version)"
fi

# Ensure Compose plugin
if docker compose version >/dev/null 2>&1; then
  info "Docker Compose plugin: $(docker compose version | head -n1)"
else
  warn "Compose plugin missing — attempting install…"
  apt-get install -y docker-compose-plugin || warn "Failed to install docker-compose-plugin."
fi

# ========= Final Report =========
status "Installed versions"
info "Docker:  $(docker --version 2>/dev/null || echo 'Not installed')"
info "Compose: $(docker compose version 2>/dev/null | head -n1 || echo 'Not installed')"

status "Next steps"
info "Open a NEW shell or run: newgrp docker"
info "On WSL, manage Docker service via Docker Desktop or suitable init."

# ========= Notes =========
# Jika melihat error: $'\r': command not found
# -> file masih CRLF. Script ini sudah auto-perbaiki di awal.
# Alternatif manual:
#   sed -i 's/\r$//' install-docker.sh
#   # atau:
#   apt-get install -y dos2unix && dos2unix install-docker.sh
