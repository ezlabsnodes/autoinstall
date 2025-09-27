#!/usr/bin/env bash
set -Eeuo pipefail
G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; B='\033[0;34m'; N='\033[0m'
ok(){ echo -e "${G}[OK] $*${N}"; }
info(){ echo -e "${B}[*] $*${N}"; }
warn(){ echo -e "${Y}[!] $*${N}"; }
err(){ echo -e "${R}[X] $*${N}" >&2; }
trap 'err "Error on line $LINENO. Exiting."' ERR

# ---------- Konstanta ----------
REPO_DIR="/root/infernet-container-starter"
REPO_URL="https://github.com/ritual-net/infernet-container-starter"

BASE_RPC="${BASE_RPC:-https://mainnet.base.org/}"
NODE_TAG="${NODE_TAG:-1.4.0}"
ANVIL_TAG="${ANVIL_TAG:-1.0.0}"

# Address resmi (Base mainnet)
COORD_ADDR="0x8D871Ef2826ac9001fB2e33fDD6379b6aaBF449c"
REGISTRY_ADDR="0x3B1554f346DFe5c482Bb4BA31b880c1C18412170"
HELLO_IMG="ritualnetwork/hello-world-infernet:1.0.0"
COMPOSE="deploy/docker-compose.yaml"

# sinkron worker (aman default)
SNAP_SLEEP=3; SNAP_START=160000; SNAP_BATCH=50; SNAP_PERIOD=30; TRAIL=3

DEPLOY=true
case "${1:-}" in --node-only|--no-contracts) DEPLOY=false ;; esac

# ---------- Root ----------
[[ $EUID -ne 0 ]] && exec sudo -E bash "$0" "$@"
export DEBIAN_FRONTEND=noninteractive

# ---------- Private key ----------
if $DEPLOY; then
  read -rsp "Enter PRIVATE KEY (hidden): " PRIV; echo
  [[ -z "$PRIV" ]] && err "Private key kosong."
  [[ "$PRIV" =~ ^[0-9a-fA-F]{64}$ ]] && PRIV="0x$PRIV"
  [[ "$PRIV" =~ ^0x[0-9a-fA-F]{64}$ ]] || err "Private key harus 64 hex (dengan/ tanpa 0x)."
else
  PRIV="0x0000000000000000000000000000000000000000000000000000000000000000"
fi

# ---------- Packages & Docker ----------
info "Installing tools…"
apt update -y || true
apt -qy install curl git jq lz4 build-essential screen ca-certificates gnupg perl

# Docker Engine
if ! command -v docker >/dev/null 2>&1; then
  apt -qy install docker.io
  systemctl enable --now docker
fi

# Docker Compose (plugin)
DOCKER_CONFIG=${DOCKER_CONFIG:-/root/.docker}
mkdir -p "$DOCKER_CONFIG/cli-plugins"
if ! docker compose version >/dev/null 2>&1; then
  curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
    -o "$DOCKER_CONFIG/cli-plugins/docker-compose"
  chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"
fi
ok "Docker & Compose Ready"

# ---------- Clone/Update repo ----------
if [[ ! -d "$REPO_DIR" ]]; then
  info "Cloning starter repo…"; git clone "$REPO_URL" "$REPO_DIR"
else
  info "Updating repo…"; git -C "$REPO_DIR" pull --rebase --autostash || true
fi
cd "$REPO_DIR"

# ---------- Patch JSON helper ----------
patch_json () {
  local f="$1"; jq empty "$f" 2>/dev/null || echo '{}' > "$f"
  local tmp; tmp="$(mktemp)"
  jq --arg coord "$COORD_ADDR" \
     --arg rpc "$BASE_RPC" \
     --arg pk "$PRIV" \
     --arg reg "$REGISTRY_ADDR" \
     --arg image "$HELLO_IMG" \
     --argjson s "$SNAP_SLEEP" --argjson st "$SNAP_START" --argjson b "$SNAP_BATCH" \
     --argjson p "$SNAP_PERIOD" --argjson t "$TRAIL" '
     .coordinator_address=$coord
     | .rpc_url=$rpc
     | .private_key=$pk
     | .registry=$reg
     | .image=$image
     | .snapshot_sync=(.snapshot_sync//{})
     | .snapshot_sync.sleep=$s
     | .snapshot_sync.starting_sub_id=$st
     | .snapshot_sync.batch_size=$b
     | .snapshot_sync.sync_period=$p
     | .trail_head_blocks=$t
  ' "$f" > "$tmp" && mv "$tmp" "$f"
  ok "Patched $f"
}

# ---------- Configs ----------
mkdir -p deploy projects/hello-world/container
[[ -f deploy/config.json ]] || echo '{}' > deploy/config.json
[[ -f projects/hello-world/container/config.json ]] || echo '{}' > projects/hello-world/container/config.json
patch_json deploy/config.json
patch_json projects/hello-world/container/config.json

# ---------- Paksa image tag node/anvil terbaru (tanpa yq) ----------
info "Patching docker-compose to node:${NODE_TAG} & anvil:${ANVIL_TAG}…"
[[ -f "$COMPOSE" ]] || err "Missing $COMPOSE"
sed -i 's#ritualnetwork/infernet-node:[^"]\+#ritualnetwork/infernet-node:'"$NODE_TAG"'#g' "$COMPOSE"
sed -i 's#ritualnetwork/infernet-anvil:[^"]\+#ritualnetwork/infernet-anvil:'"$ANVIL_TAG"'#g' "$COMPOSE"
grep -nE 'ritualnetwork/infernet-(node|anvil)' "$COMPOSE" || err "Compose patch gagal."

# ---------- Restart containers ----------
info "Restarting containers…"
docker compose -f "$COMPOSE" down || true
docker rmi ritualnetwork/infernet-node:1.3.1 2>/dev/null || true
docker compose -f "$COMPOSE" pull infernet-node infernet-anvil || true
docker compose -f "$COMPOSE" up -d
ok "Containers are up. (Use: docker logs -f infernet-node)"

# Verifikasi versi image yang running
docker ps --format '{{.Names}}\t{{.Image}}' | grep -E 'infernet-(node|anvil)' || warn "Kontainer belum tampil?"
docker inspect -f '{{.Name}} -> {{.Config.Image}}' infernet-node | sed 's#^#/ #'

# ---------- Foundry ----------
install_foundry () {
  local stopped=false
  if docker ps --format '{{.Names}}' | grep -q '^infernet-anvil$'; then docker stop infernet-anvil >/dev/null || true; stopped=true; fi
  [[ -d /root/.foundry ]] || curl -fsSL https://foundry.paradigm.xyz | bash
  /root/.foundry/bin/foundryup
  export PATH="/root/.foundry/bin:$PATH"
  for b in forge cast anvil chisel; do ln -sf "/root/.foundry/bin/$b" "/usr/local/bin/$b"; done
  $stopped && docker start infernet-anvil >/dev/null || true
  ok "Foundry installed."
}
install_foundry

# ---------- Lokasi contracts ----------
CONTRACTS_DIR="$(find "$REPO_DIR/projects/hello-world" -maxdepth 2 -type d -name contracts | head -n1 || true)"
DEPLOY_SOL=""; [[ -n "$CONTRACTS_DIR" ]] && DEPLOY_SOL="$(find "$CONTRACTS_DIR/script" -maxdepth 1 -type f -name 'Deploy.s.sol' | head -n1 || true)"
if [[ -z "$CONTRACTS_DIR" || -z "$DEPLOY_SOL" ]]; then
  warn "Contracts not found — skipping contracts phase."
  DEPLOY=false
fi

# ---------- Patch Deploy.s.sol ----------
if $DEPLOY && [[ -n "$DEPLOY_SOL" ]]; then
  info "Patching $(realpath --relative-to="$REPO_DIR" "$DEPLOY_SOL")…"
  git checkout -- "$DEPLOY_SOL" 2>/dev/null || true
  # hapus deklarasi lama
  perl -0777 -i -pe 's/^\s*address\s+coordinator\s*=.*?;\s*\n//gm' "$DEPLOY_SOL"
  perl -0777 -i -pe 's/^\s*address\s+registry\s*=.*?;\s*\n//gm' "$DEPLOY_SOL"
  # sisipkan constant + perbaiki cara baca private key
  perl -0777 -i -pe 's/(pragma\s+solidity[^;]*;\s*)/$1\naddress constant coordinator = '"$COORD_ADDR"';\naddress constant registry = '"$REGISTRY_ADDR"';\n/s' "$DEPLOY_SOL"
  perl -0777 -i -pe 's/uint256\s+deployerPrivateKey\s*=\s*vm\.envUint\("PRIVATE_KEY"\)\s*;/uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));/g' "$DEPLOY_SOL"
  # log alamat deployer bila belum ada
  grep -q 'Loaded deployer:' "$DEPLOY_SOL" || \
    perl -0777 -i -pe 's/(vm\.startBroadcast\(deployerPrivateKey\);\s*)/\1\n          address deployerAddress = vm.addr(deployerPrivateKey);\n          console2.log("Loaded deployer: ", deployerAddress);\n/s' "$DEPLOY_SOL"
  ok "Deploy.s.sol patched."
fi

# ---------- Makefile minimal (deploy & call via cast) ----------
if [[ -n "${CONTRACTS_DIR:-}" ]]; then
  info "Writing Makefile…"
  cat > "$CONTRACTS_DIR/Makefile" <<'MK'
RPC_URL ?= https://mainnet.base.org/

deploy:
	forge script script/Deploy.s.sol:Deploy --rpc-url $(RPC_URL) --broadcast --skip-simulation --private-key $(PRIVATE_KEY)

# make call ADDR=0x... (pakai checksummed address)
call:
	@test -n "$(ADDR)" || (echo "Usage: make call ADDR=0x..."; exit 1)
	cast send $(ADDR) "sayGM()" --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --gas-limit 300000
MK
  printf "PRIVATE_KEY=%s\n" "$PRIV" > "$CONTRACTS_DIR/.env"
  ok "Makefile ready."
fi

# ---------- Deps ----------
if $DEPLOY && [[ -n "$CONTRACTS_DIR" ]]; then
  info "Installing contract deps…"
  cd "$CONTRACTS_DIR"
  git config --global --add safe.directory "$REPO_DIR" || true
  forge install foundry-rs/forge-std || true
  forge install ritual-net/infernet-sdk || true
fi

# ---------- Saldo & deploy ----------
export PATH="/root/.foundry/bin:$PATH"
DEPLOYER_ADDR="$(cast wallet address --private-key "$PRIV")"
BAL_WEI="$(cast balance "$DEPLOYER_ADDR" --rpc-url "$BASE_RPC" || echo 0)"
echo "[*] Deployer: $DEPLOYER_ADDR | Balance (wei): $BAL_WEI"

to_checksum () { cast to-checksum "$1" 2>/dev/null || echo "$1"; }

if $DEPLOY; then
  if [[ "$BAL_WEI" = "0" ]]; then
    warn "Balance 0 di Base. Fund $DEPLOYER_ADDR lalu jalankan deploy manual:"
    echo "  cd $CONTRACTS_DIR && PRIVATE_KEY=$PRIV RPC_URL=$BASE_RPC make deploy"
  else
    info "Deploying SaysGM…"
    cd "$CONTRACTS_DIR"
    PRIVATE_KEY="$PRIV" RPC_URL="$BASE_RPC" make deploy

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
    CS_ADDR="$(to_checksum "$DEPLOYED_ADDR")"
    ok "Contract: $CS_ADDR"

    # Call sayGM() dengan cast + retry nonce (jaga-jaga)
    info "Calling sayGM()…"
    RETRIES=5
    for i in $(seq 1 $RETRIES); do
      NONCE_NOW="$(cast nonce "$DEPLOYER_ADDR" --rpc-url "$BASE_RPC")"
      set +e
      OUT="$(cast send "$CS_ADDR" "sayGM()" --rpc-url "$BASE_RPC" --private-key "$PRIV" --gas-limit 300000 --nonce "$NONCE_NOW" 2>&1)"
      RC=$?
      set -e
      echo "$OUT"
      if [[ $RC -eq 0 ]]; then
        ok "sayGM() broadcasted."
        break
      fi
      if echo "$OUT" | grep -qi "nonce"; then
        warn "Nonce race (attempt $i). Retry 3s…"; sleep 3; continue
      fi
      err "Call gagal: $OUT"
    done
  fi
else
  warn "Contracts phase skipped (--node-only)."
fi

# ---------- Health & tips ----------
CHAIN_ID="$(cast chain-id --rpc-url "$BASE_RPC" 2>/dev/null || echo '?')"
BLOCK_NO="$(cast block-number --rpc-url "$BASE_RPC" 2>/dev/null || echo '?')"
ok "Base RPC OK — chain-id: $CHAIN_ID | block: $BLOCK_NO"
curl -s localhost:4000/health | jq || true

ok "All done."
echo -e "\nQuick cmds:
  # Logs
  docker logs -f infernet-node
"
