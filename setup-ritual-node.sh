#!/usr/bin/env bash
set -Eeuo pipefail
G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; B='\033[0;34m'; N='\033[0m'
ok(){ echo -e "${G}[OK] $*${N}"; }
info(){ echo -e "${B}[*] $*${N}"; }
warn(){ echo -e "${Y}[!] $*${N}"; }
err(){ echo -e "${R}[X] $*${N}" >&2; }
trap 'err "Error on line $LINENO. Exiting."' ERR

# ===================== Konstanta =====================
REPO_DIR="/root/infernet-container-starter"
REPO_URL="https://github.com/ritual-net/infernet-container-starter"
COMPOSE="deploy/docker-compose.yaml"

# Versi container
NODE_TAG="${NODE_TAG:-1.4.0}"
ANVIL_TAG="${ANVIL_TAG:-1.0.0}"

# Base mainnet
BASE_RPC="${BASE_RPC:-https://mainnet.base.org/}"
REGISTRY_ADDR="0x3B1554f346DFe5c482Bb4BA31b880c1C18412170"

# Mode
DEPLOY=true
case "${1:-}" in --node-only|--no-contracts) DEPLOY=false ;; esac

# ===================== Root & pkg =====================
[[ $EUID -ne 0 ]] && exec sudo -E bash "$0" "$@"
export DEBIAN_FRONTEND=noninteractive

info "Installing packages…"
apt update -y || true
apt -qy install curl git jq lz4 build-essential ca-certificates gnupg perl

# Docker
if ! command -v docker >/dev/null 2>&1; then
  apt -qy install docker.io
  systemctl enable --now docker
fi
# Compose plugin
DOCKER_CONFIG=${DOCKER_CONFIG:-/root/.docker}
mkdir -p "$DOCKER_CONFIG/cli-plugins"
if ! docker compose version >/dev/null 2>&1; then
  curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
    -o "$DOCKER_CONFIG/cli-plugins/docker-compose"
  chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"
fi
ok "Docker & Compose ready."

# ===================== Clone repo =====================
if [[ ! -d "$REPO_DIR" ]]; then
  info "Cloning starter repo…"
  git clone "$REPO_URL" "$REPO_DIR"
else
  info "Updating repo…"
  git -C "$REPO_DIR" pull --rebase --autostash || true
fi
cd "$REPO_DIR"

# ===================== Patch docker-compose =====================
[[ -f "$COMPOSE" ]] || err "Missing $COMPOSE"
info "Patching docker-compose to node:${NODE_TAG} & anvil:${ANVIL_TAG}…"
sed -i 's#ritualnetwork/infernet-node:[^"]\+#ritualnetwork/infernet-node:'"$NODE_TAG"'#g' "$COMPOSE"
sed -i 's#ritualnetwork/infernet-anvil:[^"]\+#ritualnetwork/infernet-anvil:'"$ANVIL_TAG"'#g' "$COMPOSE"
grep -nE 'ritualnetwork/infernet-(node|anvil)' "$COMPOSE" >/dev/null || err "Compose patch gagal."

# ===================== Patch container config.json =====================
CFG="projects/hello-world/container/config.json"
[[ -f "$CFG" ]] || err "File $CFG tidak ditemukan."
info "Patching $CFG (hanya ganti chain.registry_address)…"
# Pastikan JSON valid
jq empty "$CFG" >/dev/null 2>&1 || err "$CFG invalid JSON."
TMP="$(mktemp)"
jq --arg reg "$REGISTRY_ADDR" '.chain.registry_address=$reg' "$CFG" > "$TMP"
mv "$TMP" "$CFG"
ok "Patched $CFG"

# ===================== Restart containers =====================
info "Restarting containers…"
docker compose -f "$COMPOSE" down || true
docker compose -f "$COMPOSE" up -d
ok "Containers are up. (Use: docker logs -f infernet-node)"
docker ps --format '{{.Names}}	{{.Image}}' | grep -E 'infernet-(node|anvil)' || true

# ===================== Foundry =====================
install_foundry () {
  local stopped=false
  if docker ps --format '{{.Names}}' | grep -q '^infernet-anvil$'; then
    docker stop infernet-anvil >/dev/null || true; stopped=true
  fi
  [[ -d /root/.foundry ]] || curl -fsSL https://foundry.paradigm.xyz | bash
  /root/.foundry/bin/foundryup
  export PATH="/root/.foundry/bin:$PATH"
  for b in forge cast anvil chisel; do ln -sf "/root/.foundry/bin/$b" "/usr/local/bin/$b"; done
  $stopped && docker start infernet-anvil >/dev/null || true
  ok "Foundry installed."
}
install_foundry

# ===================== Kontrak: lokasi & libs =====================
CONTRACTS_DIR="$(find "$REPO_DIR/projects/hello-world" -maxdepth 2 -type d -name contracts | head -n1 || true)"
DEPLOY_SOL=""
[[ -n "$CONTRACTS_DIR" ]] && DEPLOY_SOL="$(find "$CONTRACTS_DIR/script" -maxdepth 1 -type f -name 'Deploy.s.sol' | head -n1 || true)"
if [[ -z "${CONTRACTS_DIR:-}" || -z "${DEPLOY_SOL:-}" ]]; then
  warn "Contracts folder tidak ditemukan — lewati fase kontrak."
  DEPLOY=false
fi

install_contract_libs () {
  cd "$CONTRACTS_DIR"
  git config --global --add safe.directory "$REPO_DIR" || true

  info "Installing contract libs (forge)…"
  # Tanpa --no-commit (Forge 1.3.5 tidak support)
  forge install foundry-rs/forge-std || true
  forge install ritual-net/infernet-sdk || true

  # fallback: submodule init / clone manual bila paths tidak ada
  if [[ ! -f lib/forge-std/src/Script.sol ]]; then
    warn "forge-std belum lengkap, init submodule…"
    git submodule update --init --recursive lib/forge-std || true
  fi
  if [[ ! -f lib/infernet-sdk/src/consumer/Callback.sol ]]; then
    warn "infernet-sdk belum lengkap, clone manual…"
    rm -rf lib/infernet-sdk
    mkdir -p lib
    git clone https://github.com/ritual-net/infernet-sdk.git lib/infernet-sdk
    ( cd lib/infernet-sdk && git submodule update --init --recursive )
  fi
  git -C lib/infernet-sdk submodule update --init --recursive || true

  [[ -f lib/forge-std/src/Script.sol ]] || err "forge-std/src/Script.sol masih tidak ada."
  [[ -f lib/infernet-sdk/src/consumer/Callback.sol ]] || err "infernet-sdk/src/consumer/Callback.sol masih tidak ada."
  ok "Contract libs ready."
}

# ===================== Patch Deploy.s.sol (ganti registry saja) =====================
patch_deploy_sol () {
  info "Patching $(realpath --relative-to="$REPO_DIR" "$DEPLOY_SOL") (ganti registry saja)…"
  # Ganti hanya baris "address registry = ..."
  perl -0777 -i -pe 's/address\s+registry\s*=\s*0x[0-9a-fA-F]{40}\s*;/address registry = '"$REGISTRY_ADDR"';/g' "$DEPLOY_SOL"
  ok "Deploy.s.sol patched."
}

# ===================== Prompt PK & tulis Makefile =====================
if $DEPLOY; then
  read -rsp "Enter PRIVATE KEY (hidden): " PRIV; echo
  [[ -z "$PRIV" ]] && err "Private key kosong."
  # envUint mendukung 0x-hex maupun decimal — tidak perlu ubah.
  info "Writing Makefile…"
  cat > "$CONTRACTS_DIR/Makefile" <<'MK'
RPC_URL ?= https://mainnet.base.org/

deploy:
	forge script script/Deploy.s.sol:Deploy --rpc-url $(RPC_URL) --broadcast --skip-simulation --private-key $(PRIVATE_KEY)

# make call ADDR=0x...
call:
	@test -n "$(ADDR)" || (echo "Usage: make call ADDR=0x..."; exit 1)
	cast send $(ADDR) "sayGM()" --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --gas-limit 300000
MK
  printf "PRIVATE_KEY=%s\n" "$PRIV" > "$CONTRACTS_DIR/.env"
  ok "Makefile ready."
fi

# ===================== Jalankan fase kontrak =====================
if $DEPLOY; then
  install_contract_libs
  patch_deploy_sol

  export PATH="/root/.foundry/bin:$PATH"
  DEPLOYER_ADDR="$(cast wallet address --private-key "$PRIV")"
  BAL_WEI="$(cast balance "$DEPLOYER_ADDR" --rpc-url "$BASE_RPC" || echo 0)"
  echo "[*] Deployer: $DEPLOYER_ADDR | Balance (wei): $BAL_WEI"

  if [[ "$BAL_WEI" = "0" ]]; then
    warn "Balance 0 di Base. Isi saldo ke $DEPLOYER_ADDR lalu jalankan deploy manual:"
    echo "  cd $CONTRACTS_DIR && PRIVATE_KEY=$PRIV RPC_URL=$BASE_RPC make deploy"
  else
    info "Deploying SaysGM…"
    ( cd "$CONTRACTS_DIR" && PRIVATE_KEY="$PRIV" RPC_URL="$BASE_RPC" make deploy )

    # Ambil address dari broadcast
    BR_DIR="$CONTRACTS_DIR/broadcast/Deploy.s.sol/8453"
    [[ -d "$BR_DIR" ]] || BR_DIR="$(dirname "$(find "$CONTRACTS_DIR/broadcast" -type f -name 'run-latest.json' | head -n1 2>/dev/null)")"
    BR="$BR_DIR/run-latest.json"
    DEPLOYED_ADDR=""
    if [[ -f "$BR" ]]; then
      DEPLOYED_ADDR="$(jq -r '..|.contractAddress? // empty' "$BR" | grep -E '^0x[0-9a-fA-F]{40}$' | tail -1 || true)"
      [[ -z "$DEPLOYED_ADDR" ]] && DEPLOYED_ADDR="$(grep -Eo '0x[0-9a-fA-F]{40}' "$BR" | tail -1 || true)"
    fi
    [[ -n "$DEPLOYED_ADDR" ]] || err "Tidak bisa baca alamat kontrak dari broadcast."
    ok "Contract: $DEPLOYED_ADDR"

    # Panggil sayGM() sekali (tanpa utak-atik nonce; provider akan atur)
    info "Calling sayGM()…"
    cast send "$DEPLOYED_ADDR" "sayGM()" --rpc-url "$BASE_RPC" --private-key "$PRIV" --gas-limit 300000
    ok "sayGM() broadcasted."
  fi
else
  warn "Contracts phase skipped (--node-only)."
fi

# ===================== Health & Tips =====================
CHAIN_ID="$(cast chain-id --rpc-url "$BASE_RPC" 2>/dev/null || echo '?')"
BLOCK_NO="$(cast block-number --rpc-url "$BASE_RPC" 2>/dev/null || echo '?')"
ok "Base RPC OK — chain-id: $CHAIN_ID | block: $BLOCK_NO"
curl -s localhost:4000/health | jq || true

ok "All done."
echo -e "\nQuick cmds:
  # Logs node:
  docker logs -f infernet-node
"
