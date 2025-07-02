#!/bin/bash

# ==============================================
# AUTO REMOVE SWAP LAMA (TANPA KONFIRMASI)
# ==============================================

# Cek swap aktif
SWAP_FILE=$(swapon --show=NAME --noheadings | head -n1)

if [ -z "$SWAP_FILE" ]; then
    echo "❌ Error: Tidak ada swap yang aktif!"
    exit 1
fi

echo "🗑️ Menghapus swap file: $SWAP_FILE"

# 1. Matikan swap
sudo swapoff -v "$SWAP_FILE" 2>/dev/null && \
echo "✔ Swap dimatikan" || echo "❌ Gagal mematikan swap"

# 2. Hapus file fisik
sudo rm -f "$SWAP_FILE" && \
echo "✔ File swap dihapus" || echo "❌ Gagal menghapus file"

# 3. Bersihkan /etc/fstab
sudo sed -i "\|^$SWAP_FILE|d" /etc/fstab && \
echo "✔ Config /etc/fstab dibersihkan" || echo "❌ Gagal membersihkan fstab"

# Hasil akhir
echo -e "\n🔍 Status terakhir:"
swapon --show || echo "Tidak ada swap aktif"
free -h
