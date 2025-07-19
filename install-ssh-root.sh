#!/bin/bash

echo "Starting automated OpenSSH installation and configuration..."

# Set default values
DEFAULT_EMAIL="email@example.com"
AUTO_COPY_KEY="y"
REMOTE_USER="root"
SSH_PORT="22"

# Update system and install OpenSSH
echo -e "\n[1/7] Updating packages and installing OpenSSH..."
sudo apt update
sudo apt install -y openssh-server ufw

# Configure firewall
echo -e "\n[2/7] Configuring firewall..."
sudo ufw allow "$SSH_PORT"/tcp
sudo ufw --force enable

# Generate SSH Key Pair with default email
echo -e "\n[3/7] Generating SSH key pair..."
echo "Using default email: $DEFAULT_EMAIL"
ssh-keygen -t rsa -b 4096 -C "$DEFAULT_EMAIL" -f ~/.ssh/id_rsa -N ""

# Setup authorized_keys
echo -e "\n[4/7] Setting up authorized_keys..."
mkdir -p ~/.ssh
touch ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys

# Get VPS IP
vps_ip=$(curl -s ifconfig.me)
echo -e "\n[5/7] Your VPS IP is: $vps_ip"

# Auto-copy public key with automatic host verification
echo -e "\n[5.1/7] Automatically copying public key to root@$vps_ip"
ssh-keyscan -H "$vps_ip" >> ~/.ssh/known_hosts 2>/dev/null
sshpass -p "your_remote_password" ssh-copy-id -i ~/.ssh/id_rsa.pub -p "$SSH_PORT" "$REMOTE_USER@$vps_ip" 2>/dev/null

# Alternative method if sshpass is not available
# echo -e "yes\n" | ssh-copy-id -i ~/.ssh/id_rsa.pub -p "$SSH_PORT" "$REMOTE_USER@$vps_ip"

# Configure SSH daemon
echo -e "\n[6/7] Configuring SSH daemon..."
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
sudo bash -c 'cat > /etc/ssh/sshd_config << EOL
Port $SSH_PORT
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOL'

# Restart SSH service
echo -e "\n[7/7] Restarting SSH service..."
sudo systemctl daemon-reload
sudo systemctl restart sshd

# Display private key
echo -e "\n=== SSH Auto-Setup Complete ==="
echo -e "\nYour private key (save this for client access):"
echo "----------------------------------------"
cat ~/.ssh/id_rsa
echo "----------------------------------------"

echo -e "\nAuto-configured values:"
echo "1. SSH Key Email: $DEFAULT_EMAIL"
echo "2. VPS IP: $vps_ip"
echo "3. SSH Port: $SSH_PORT"

echo -e "\nWARNING: Keep your private key secure and don't share it with anyone!"
