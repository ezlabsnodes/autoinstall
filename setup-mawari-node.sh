#!/usr/bin/env bash
set -Eeuo pipefail

# ===== UI helpers =====
GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; BLUE='\033[0;34m'; NC='\033[0m'
ok(){ echo -e "${GREEN}[OK] $*${NC}"; }
warn(){ echo -e "${YELLOW}[WARN] $*${NC}"; }
err(){ echo -e "${RED}[ERR] $*${NC}" >&2; }
status(){ echo -e "\n${BLUE}>>> $*${NC}"; }
trap 'err "Error on line $LINENO"; exit 1' ERR

# ===== Config =====
APP_DIR="${APP_DIR:-$PWD/mawari}"
ENV_FILE="$APP_DIR/.env"
COMPOSE_FILE="$APP_DIR/docker-compose.yaml"
CACHE_DIR="$APP_DIR/cache"
IMAGE="us-east4-docker.pkg.dev/mawarinetwork-dev/mwr-net-d-car-uses4-public-docker-registry-e62e/mawari-node:latest"
SERVICE="guardian-node"

# ===== Compose wrapper =====
dc() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose -f "$COMPOSE_FILE" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$COMPOSE_FILE" "$@"
  else
    err "Neither 'docker compose' nor 'docker-compose' is available. Install Docker first."
    exit 1
  fi
}

require_docker() {
  command -v docker >/dev/null 2>&1 || { err "Docker not found. Please install Docker."; exit 1; }
}

read_evm() {
  local evm
  read -rp "Enter your EVM address (0x…40 hex): " evm
  if [[ ! $evm =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    err "Invalid EVM address format."
    exit 1
  fi
  echo "$evm"
}

write_env() {
  local evm="$1"
  mkdir -p "$APP_DIR"
  printf "OWNERS_ALLOWLIST=%s\n" "$evm" > "$ENV_FILE"
  ok "Wrote $ENV_FILE"
}

write_compose() {
  mkdir -p "$APP_DIR" "$CACHE_DIR"
  cat > "$COMPOSE_FILE" <<YAML
services:
  guardian-node:
    image: ${IMAGE}
    container_name: ${SERVICE}
    restart: always
    environment:
      - OWNERS_ALLOWLIST=\${OWNERS_ALLOWLIST}
    volumes:
      - ./cache:/app/cache
YAML
  ok "Wrote $COMPOSE_FILE"
}

start_stack() {
  status "Starting ${SERVICE}…"
  dc up -d
  ok "Service started."
}

stop_stack() {
  status "Stopping ${SERVICE}…"
  dc down
  ok "Service stopped."
}

pull_image() {
  status "Pulling latest image…"
  dc pull
  ok "Image updated."
}

show_status() {
  status "Compose ps"
  dc ps || true
}

show_logs() {
  status "Tail logs (Ctrl+C to exit)"
  dc logs -f --tail=200
}

init_and_start() {
  require_docker
  local evm
  if [[ -f "$ENV_FILE" ]]; then
    warn ".env already exists: $ENV_FILE"
    read -rp "Overwrite EVM address in .env? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then
      evm="$(read_evm)"
      write_env "$evm"
    else
      ok "Keeping existing .env"
    fi
  else
    evm="$(read_evm)"
    write_env "$evm"
  fi

  write_compose
  start_stack
  show_status
}

update_address() {
  require_docker
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    warn "Compose file not found; creating it."
    write_compose
  fi
  local evm="$(read_evm)"
  write_env "$evm"
  status "Restarting to apply new EVM…"
  dc up -d
  ok "Updated and restarted."
}

case "${1:-start}" in
  start)         init_and_start ;;
  update)        update_address ;;
  logs)          show_logs ;;
  stop|down)     stop_stack ;;
  pull)          pull_image ;;
  status|ps)     show_status ;;
  *)
    echo "Usage: $(basename "$0") [start|update|logs|stop|pull|status]"
    exit 1
    ;;
esac
