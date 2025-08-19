#!/bin/bash
set -e

SLICE_FILE="/etc/systemd/system/rl-swarm.slice"
RAM_REDUCTION_GB=2

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ Error: Skrip ini harus dijalankan dengan sudo atau sebagai user root."
  exit 1
fi

total_gb=$(free -g | awk '/^Mem:/ {print $2}')
echo "RAM terdeteksi: ${total_gb}G"

if [ "$total_gb" -le "$RAM_REDUCTION_GB" ]; then
  echo "❌ Error: Total RAM (${total_gb}G) terlalu kecil untuk dikurangi ${RAM_REDUCTION_GB}G."
  exit 1
fi

limit_gb=$((total_gb - RAM_REDUCTION_GB))
echo "Batas RAM akan diatur ke: ${limit_gb}G"

slice_content="[Slice]
Description=Slice for RL Swarm (auto-detected ${limit_gb}G RAM Limit)
MemoryMax=${limit_gb}G
"

echo -e "$slice_content" | sudo tee "$SLICE_FILE" > /dev/null

echo "✅ File slice berhasil dibuat di $SLICE_FILE"
