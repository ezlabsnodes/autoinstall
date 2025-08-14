#!/bin/bash

# Hentikan eksekusi skrip jika terjadi error
set -e

# Menampilkan pesan awal
echo "🚀 Memulai skrip instalasi lingkungan pengembangan..."
echo "----------------------------------------------------"

# 1. Instalasi dependensi
echo "STEP 1: Menginstal dependensi sistem (memerlukan password sudo)..."
sudo apt update
sudo apt install -y build-essential \
  curl \
  wget \
  git \
  unzip \
  pkg-config \
  software-properties-common
echo "✅ Dependensi sistem berhasil diinstal."
echo ""

# 2. Instalasi NVM (Node Version Manager)
echo "STEP 2: Menginstal NVM (Node Version Manager)..."
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
echo "✅ NVM berhasil diinstal."
echo ""

# Muat NVM ke dalam sesi skrip saat ini agar perintah 'nvm' bisa digunakan
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# 3. Instalasi dan konfigurasi Node.js
echo "STEP 3: Menginstal dan mengonfigurasi Node.js v18..."
nvm install 18
nvm use 18
nvm alias default 18
echo "✅ Node.js v18 berhasil diinstal dan ditetapkan sebagai default."
echo ""

# 4. Instalasi dan Otentikasi P0tion Phase2 CLI
echo "STEP 4: Menginstal dan menjalankan otentikasi Phase2 CLI..."
npm install -g @p0tion/phase2cli@latest
echo "✅ @p0tion/phase2cli berhasil diinstal secara global."
echo ""
echo "Sekarang menjalankan proses otentikasi..."
echo "👉 Silakan ikuti instruksi yang muncul di terminal Anda untuk login."
phase2cli auth
echo "✅ Proses otentikasi dimulai."
echo ""

# Menampilkan pesan selesai
echo "----------------------------------------------------"
echo "🎉 Semua instalasi dan otentikasi telah selesai!"
echo ""
echo "Verifikasi Versi:"
echo "   - Node: $(node -v)"
echo "   - NPM:  $(npm -v)"
echo ""
echo "----------------------------------------------------"
