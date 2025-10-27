#!/bin/bash

# --- Configuration ---
AZTEC_DIR="/root/aztec"
ENV_FILE="$AZTEC_DIR/.env"
COMPOSE_FILE="$AZTEC_DIR/docker-compose.yml"
COMPOSE_CMD="docker compose"
CONTAINER_NAME="aztec-sequencer"
NEW_GOVERNANCE_PAYLOAD="0xDCd9DdeAbEF70108cE02576df1eB333c4244C666"

echo "### Starting Aztec Node Update Script ###"

# --- 1. Update .env file ---
echo "-> Updating $ENV_FILE file..."
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE file not found!"
    exit 1
fi
# Update GOVERNANCE_PAYLOAD value
sed -i "s/^GOVERNANCE_PAYLOAD=.*/GOVERNANCE_PAYLOAD=$NEW_GOVERNANCE_PAYLOAD/" "$ENV_FILE"
echo "   - GOVERNANCE_PAYLOAD value updated."
# Add AZTEC_ADMIN_PORT if not exists
if ! grep -q "^AZTEC_ADMIN_PORT=" "$ENV_FILE"; then
    echo "AZTEC_ADMIN_PORT=8880" >> "$ENV_FILE"
    echo "   + Added AZTEC_ADMIN_PORT=8880."
fi
echo "-> .env file successfully updated."
echo ""

# --- 2. Update docker-compose.yml file ---
echo "-> Updating $COMPOSE_FILE file..."
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: $COMPOSE_FILE file not found!"
    exit 1
fi

# Add AZTEC_ADMIN_PORT to environment if not exists
if ! grep -q "AZTEC_ADMIN_PORT: \${AZTEC_ADMIN_PORT}" "$COMPOSE_FILE"; then
    # Add after LOG_LEVEL: info line
    sed -i '/LOG_LEVEL: info/a \      AZTEC_ADMIN_PORT: ${AZTEC_ADMIN_PORT}' "$COMPOSE_FILE"
    echo "   + Added AZTEC_ADMIN_PORT to environment."
else
    echo "   - AZTEC_ADMIN_PORT already exists in environment."
fi

# Add admin port 8880 if not exists
if ! grep -q -- "- 8880:8880" "$COMPOSE_FILE"; then
    sed -i '/- 8080:8080/a \      - 8880:8880' "$COMPOSE_FILE"
    echo "   + Added port 8880:8880."
else
    echo "   - Port 8880:8880 already exists."
fi

echo "-> docker-compose.yml file successfully updated."
echo ""

# --- 3. Stop and Remove Old Container ---
echo "-> Stopping and removing container '$CONTAINER_NAME'..."
if sudo docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    sudo docker stop $CONTAINER_NAME
    sudo docker rm -f $CONTAINER_NAME
    echo "-> Old container successfully removed."
else
    echo "-> Container '$CONTAINER_NAME' not found, continuing..."
fi
echo ""

# --- 4. Update to version 2.0.4 ---
echo "-> Updating to version 2.0.4..."
echo "-> Cleaning up old data directories..."

# Remove testnet data
rm -rf .aztec/testnet/data
echo "   - Removed .aztec/testnet/data"

# Remove temporary world state files
rm -rf /tmp/aztec-world-state-*
echo "   - Removed /tmp/aztec-world-state-* files"

# Update to version 2.0.4
echo "-> Running aztec-up to version 2.0.4..."
aztec-up -v 2.0.4
echo "-> Version update completed."
echo ""

# --- 5. Restart Container ---
echo "-> Restarting container with new configuration..."
cd "$AZTEC_DIR" || { echo "ERROR: Cannot enter directory $AZTEC_DIR"; exit 1; }
$COMPOSE_CMD up -d
echo "-> Container successfully started. Waiting 15 seconds for node to be ready..."
sleep 15
echo ""

# --- 6. Send New Configuration via RPC ---
echo "-> Sending governance payload configuration update via cURL..."
curl -X POST http://localhost:8880 \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc":"2.0",
    "method":"nodeAdmin_setConfig",
    "params":[{"governanceProposerPayload":"'"$NEW_GOVERNANCE_PAYLOAD"'"}],
    "id":1
  }'

echo -e "\n\n### Script Completed ###"
echo "Your Aztec Node has been successfully updated and reconfigured. ✅"
