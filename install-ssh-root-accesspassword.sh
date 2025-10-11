#!/bin/bash

echo "Starting SSH Password Login Configuration (NO FIREWALL)..."

# Tentukan Port SSH
SSH_PORT="22"

# 1. Update system dan install OpenSSH
echo -e "\n[1/3] Updating packages and installing OpenSSH..."
sudo apt update
sudo apt install -y openssh-server

# 2. Konfigurasi SSH daemon
echo -e "\n[2/3] Configuring SSH daemon for password login..."
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
sudo bash -c 'cat > /etc/ssh/sshd_config << EOL
Port '$SSH_PORT'
PermitRootLogin yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOL'

# 3. Restart service SSH
echo -e "\n[3/3] Restarting SSH service..."
# PERBAIKAN: Menggunakan nama service 'ssh' yang benar
sudo systemctl restart ssh

# Ambil IP VPS
vps_ip=$(curl -s ifconfig.me)

echo -e "\n=== Setup Selesai ==="
echo "SSH Auto-Setup Complete"
echo "----------------------------------------"
echo "Host/Alamat IP: $vps_ip"
echo "Port: $SSH_PORT"
echo "----------------------------------------"
