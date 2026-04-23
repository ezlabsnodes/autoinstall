#!/bin/bash

set -e  # Exit on any error

echo "======================================"
echo "  CUDA Toolkit Installation Script"
echo "======================================"

# Step 1: Download CUDA keyring
echo "[1/6] Downloading CUDA keyring..."
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb

# Step 2: Install keyring
echo "[2/6] Installing CUDA keyring..."
sudo dpkg -i cuda-keyring_1.1-1_all.deb

# Step 3: Update package list
echo "[3/6] Updating package list..."
sudo apt update

# Step 4: Install CUDA Toolkit
echo "[4/6] Installing CUDA Toolkit (this may take a while)..."
sudo apt install cuda-toolkit -y

# Step 5: Set environment variables
echo "[5/6] Setting environment variables..."
echo 'export PATH=/usr/local/cuda/bin${PATH:+:${PATH}}' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}' >> ~/.bashrc

# Step 6: Source bashrc
echo "[6/6] Applying environment variables..."
source ~/.bashrc

echo ""
echo "======================================"
echo "  Installation Complete!"
echo "======================================"
echo "CUDA path: /usr/local/cuda"
echo "Run 'nvcc --version' to verify installation."
echo "NOTE: You may need to restart your terminal or run 'source ~/.bashrc'"
