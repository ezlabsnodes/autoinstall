#!/bin/bash
set -e  # Exit script on any error

echo "=========================================="
echo "  NVIDIA Container Toolkit Installer"
echo "=========================================="

# Function to run commands with sudo
run_sudo() {
    echo "➜ Executing: sudo $*"
    sudo "$@"
}

# Step 1: Remove old configuration
echo -e "\n📋 Step 1: Removing old configuration..."
run_sudo rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
run_sudo rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

# Step 2: Update package list and install dependencies
echo -e "\n📋 Step 2: Updating package list and installing dependencies..."
run_sudo apt-get update
run_sudo apt-get install -y --no-install-recommends curl gnupg2

# Step 3: Download and install GPG key
echo -e "\n📋 Step 3: Downloading GPG key..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | run_sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

# Step 4: Add repository
echo -e "\n📋 Step 4: Adding NVIDIA repository..."
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | run_sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Step 5: Update package list again
echo -e "\n📋 Step 5: Updating package list..."
run_sudo apt-get update

# Step 6: Install NVIDIA Container Toolkit
echo -e "\n📋 Step 6: Installing NVIDIA Container Toolkit..."
run_sudo apt-get install -y nvidia-container-toolkit nvidia-container-toolkit-base \
  libnvidia-container-tools libnvidia-container1

# Step 7: Configure Docker runtime
echo -e "\n📋 Step 7: Configuring Docker runtime..."
run_sudo nvidia-ctk runtime configure --runtime=docker

# Step 8: Restart Docker service
echo -e "\n📋 Step 8: Restarting Docker service..."
run_sudo systemctl restart docker

# Step 9: Test installation
echo -e "\n📋 Step 9: Testing installation with nvidia-smi..."
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi

echo -e "\n=========================================="
echo "✅ NVIDIA Container Toolkit successfully installed"
echo "=========================================="
