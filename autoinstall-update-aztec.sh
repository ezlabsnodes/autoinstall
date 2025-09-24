#!/usr/bin/env bash
set -Eeuo pipefail

# ========= Pretty logs =========
ok(){ echo -e "\033[1;32m$*\033[0m"; }
warn(){ echo -e "\033[1;33m$*\033[0m"; }
err(){ echo -e "\033[1;31m$*\033[0m" >&2; }

trap 'err "Error on line $LINENO. Exiting."' ERR

# ========= Config =========
# You can override version via: ./aztec-upgrade.sh 1.2.2
AZTEC_VERSION="${1:-2.0.3}"

# Resolve home dir (works with sudo)
USER_NAME=${SUDO_USER:-$(whoami)}
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)

AZTEC_DIR="$HOME_DIR/aztec"
COMPOSE_FILE="$AZTEC_DIR/docker-compose.yml"
DATA_DIR="$HOME_DIR/.aztec/alpha-testnet/data"
AZTEC_UP_BIN="$HOME_DIR/.aztec/bin/aztec-up"

# Pick docker compose command
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  err "Docker Compose not found (plugin or standalone)."
  exit 1
fi

# ========= Sanity checks =========
[ -f "$COMPOSE_FILE" ] || { err "docker-compose.yml not found at $COMPOSE_FILE"; exit 1; }

# ========= Step 1: Stop & remove container =========
ok "[1/5] Stopping aztec-sequencer…"
if docker ps -a --format '{{.Names}}' | grep -q '^aztec-sequencer$'; then
  if [ "$(id -u)" -eq 0 ]; then
    docker stop aztec-sequencer || true
    docker rm -f aztec-sequencer || true
  else
    sudo docker stop aztec-sequencer || true
    sudo docker rm -f aztec-sequencer || true
  fi
else
  warn "Container aztec-sequencer not found (skipping stop/rm)."
fi

# ========= Step 2: Remove old data =========
ok "[2/5] Removing old data at $DATA_DIR …"
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"

# ========= Step 3: aztec-up to desired version =========
ok "[3/5] Running aztec-up -v $AZTEC_VERSION …"
if command -v aztec-up >/dev/null 2>&1; then
  aztec-up -v "$AZTEC_VERSION"
elif [ -x "$AZTEC_UP_BIN" ]; then
  "$AZTEC_UP_BIN" -v "$AZTEC_VERSION"
else
  err "aztec-up not found (checked PATH and $AZTEC_UP_BIN)."
  exit 1
fi

# ========= Step 4: Update image tag in compose =========
ok "[4/5] Updating image tag in $COMPOSE_FILE …"
TS=$(date +%Y%m%d-%H%M%S)
cp -a "$COMPOSE_FILE" "$COMPOSE_FILE.bak.$TS"

# Replace any existing aztecprotocol/aztec:<tag> with the new version
# Works even if current tag isn't 1.2.1.
sed -i -E "s|(image:\s*aztecprotocol/aztec:)[^[:space:]]+|\1${AZTEC_VERSION}|g" "$COMPOSE_FILE"
ok "Backed up previous compose: $COMPOSE_FILE.bak.$TS"

# ========= Step 4b: Ensure --network testnet in compose =========
ok "[4b/5] Forcing --network testnet in compose …"
# Hanya ganti jika masih alpha-testnet
sed -i 's/--network alpha-testnet/--network testnet/g' "$COMPOSE_FILE"

# ========= Step 5: Bring it back up =========
ok "[5/5] Starting Aztec with Docker Compose…"
(
  cd "$AZTEC_DIR"
  if [ "$(id -u)" -eq 0 ]; then
    $COMPOSE_CMD up -d
  else
    sudo $COMPOSE_CMD up -d
  fi
)

ok "Upgrade complete! Now running aztecprotocol/aztec:${AZTEC_VERSION}"

echo
echo "Check status:"
echo "  $COMPOSE_CMD -f \"$COMPOSE_FILE\" ps"
echo "Follow logs (Ctrl+C to exit):"
echo "  docker logs -f aztec-sequencer"
