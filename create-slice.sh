#!/bin/bash
set -e

SLICE_FILE="/etc/systemd/system/rl-swarm.slice"
RAM_REDUCTION_GB=3

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ Error: Skrip ini harus dijalankan dengan sudo atau sebagai user root."
  exit 1
fi

# Auto-detect jumlah CPU core
cpu_cores=$(nproc)
echo "CPU cores terdeteksi: ${cpu_cores}"

# Hitung limit CPU: (total core - 1) * 100%
cpu_limit_percentage=$(( (cpu_cores - 1) * 100 ))

# Pastikan tidak minus (minimal 100% jika hanya 1 core)
if [ "$cpu_limit_percentage" -lt 100 ]; then
    cpu_limit_percentage=100
fi

total_gb=$(free -g | awk '/^Mem:/ {print $2}')
echo "RAM terdeteksi: ${total_gb}G"

if [ "$total_gb" -le "$RAM_REDUCTION_GB" ]; then
  echo "❌ Error: Total RAM (${total_gb}G) terlalu kecil untuk dikurangi ${RAM_REDUCTION_GB}G."
  exit 1
fi

limit_gb=$((total_gb - RAM_REDUCTION_GB))
echo "Batas RAM akan diatur ke: ${limit_gb}G"
echo "Batas CPU akan diatur ke: ${cpu_limit_percentage}% (${cpu_cores} core - 1 core)"

slice_content="[Slice]
Description=Slice for RL Swarm (auto-detected: ${limit_gb}G RAM, ${cpu_limit_percentage}% CPU from ${cpu_cores} cores)
MemoryMax=${limit_gb}G
CPUQuota=${cpu_limit_percentage}%
"

echo -e "$slice_content" | sudo tee "$SLICE_FILE" > /dev/null

echo "✅ File slice berhasil dibuat di $SLICE_FILE"
