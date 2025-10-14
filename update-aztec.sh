#!/bin/bash

# --- Konfigurasi ---
AZTEC_DIR="/root/aztec"
ENV_FILE="$AZTEC_DIR/.env"
COMPOSE_FILE="$AZTEC_DIR/docker-compose.yml"
COMPOSE_CMD="docker-compose" # Ganti ke "docker compose" jika Anda menggunakan versi baru
CONTAINER_NAME="aztec-sequencer"
NEW_GOVERNANCE_PAYLOAD="0x9D8869D17Af6B899AFf1d93F23f863FF41ddc4fa"

echo "### Memulai skrip pembaruan Aztec Node ###"

# --- 1. Memperbarui file .env ---
echo "-> Memperbarui file $ENV_FILE..."
# Mengubah nilai GOVERNANCE_PAYLOAD
sed -i "s/^GOVERNANCE_PAYLOAD=.*/GOVERNANCE_PAYLOAD=$NEW_GOVERNANCE_PAYLOAD/" "$ENV_FILE"
# Menambahkan AZTEC_ADMIN_PORT jika belum ada
if ! grep -q "AZTEC_ADMIN_PORT=" "$ENV_FILE"; then
    echo "AZTEC_ADMIN_PORT=8880" >> "$ENV_FILE"
    echo "   + Menambahkan AZTEC_ADMIN_PORT=8880"
fi
echo "-> File .env berhasil diperbarui."
echo ""

# --- 2. Memperbarui file docker-compose.yml ---
echo "-> Memperbarui file $COMPOSE_FILE..."
# Menambahkan GOVERNANCE_PAYLOAD ke environment
if ! grep -q "GOVERNANCE_PAYLOAD: \${GOVERNANCE_PAYLOAD}" "$COMPOSE_FILE"; then
    sed -i '/LOG_LEVEL: info/a \      GOVERNANCE_PAYLOAD: ${GOVERNANCE_PAYLOAD}' "$COMPOSE_FILE"
    echo "   + Menambahkan GOVERNANCE_PAYLOAD di bawah environment"
fi
# Menambahkan port admin
if ! grep -q -- "- 8880:8880" "$COMPOSE_FILE"; then
    sed -i '/- 8080:8080/a \      - 8880:8880' "$COMPOSE_FILE"
    echo "   + Menambahkan port 8880:8880"
fi
echo "-> File docker-compose.yml berhasil diperbarui."
echo ""

# --- 3. Menghentikan dan Menghapus Kontainer Lama ---
echo "-> Menghentikan dan menghapus kontainer '$CONTAINER_NAME' yang ada..."
sudo docker stop $CONTAINER_NAME
sudo docker rm -f $CONTAINER_NAME
echo "-> Kontainer lama berhasil dihapus."
echo ""

# --- 4. Menjalankan Ulang Kontainer dengan Konfigurasi Baru ---
echo "-> Menjalankan ulang kontainer dengan konfigurasi baru..."
cd "$AZTEC_DIR" || exit
$COMPOSE_CMD up -d
echo "-> Kontainer berhasil dijalankan."
echo "-> Menunggu 15 detik agar node siap..."
sleep 15
echo ""

# --- 5. Mengirim Konfigurasi Baru melalui RPC ---
echo "-> Mengirim pembaruan konfigurasi governance payload melalui cURL..."
curl -X POST http://localhost:8880 \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc":"2.0",
    "method":"nodeAdmin_setConfig",
    "params":[{"governanceProposerPayload":"'"$NEW_GOVERNANCE_PAYLOAD"'"}],
    "id":1
  }'

echo -e "\n\n### Skrip Selesai ###"
echo "Node Aztec Anda telah diperbarui dan dikonfigurasi ulang."
