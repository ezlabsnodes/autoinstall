#!/bin/bash

# --- Check if running as root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use: sudo $0" >&2
    exit 1
fi

# 1. Prompt for the new root password (for console/su access)
while true; do
    read -s -p "Enter new root password (for console/su): " root_pass
    echo
    read -s -p "Retype new root password: " root_pass_confirm
    echo
    if [ "$root_pass" = "$root_pass_confirm" ]; then
        if [ -z "$root_pass" ]; then
            echo "Password cannot be empty. Please try again."
        else
            break # Password matches and is not empty
        fi
    else
        echo "Passwords do not match. Please try again."
    fi
done

echo -e "\n[1/10] Updating system packages..."
apt update -y > /dev/null 2>&1

echo -e "\n[2/10] Installing nano, openssh-server, and ufw..."
apt install -y nano openssh-server ufw > /dev/null 2>&1

# 3. Set the root password non-interactively
echo -e "\n[3/10] Setting root password..."
echo "root:$root_pass" | chpasswd
if [ $? -eq 0 ]; then
    echo "Root password for console/su has been set."
else
    echo "Failed to set root password."
    exit 1
fi

# 4. Add the original sudo user to the sudo group (from your script)
current_user=${SUDO_USER:-$(who am i | awk '{print $1}')}
if [ -n "$current_user" ] && [ "$current_user" != "root" ]; then
    echo -e "\n[4/10] Adding user '$current_user' to sudo group..."
    usermod -aG sudo "$current_user"
    echo "User $current_user added to sudo group."
else
    echo -e "\n[4/10] Skipping: Could not find non-root user."
fi

# 5. Configure hosts file (from your script)
echo -e "\n[5/10] Configuring /etc/hosts..."
instance_name=$(hostname)
cp /etc/hosts /etc/hosts.backup
if ! grep -q "127.0.0.1 $instance_name" /etc/hosts; then
    echo "Adding $instance_name to /etc/hosts..."
    echo "127.0.0.1 $instance_name" | tee -a /etc/hosts > /dev/null
else
    echo "Entry '$instance_name' already exists in /etc/hosts."
fi

# 6. Configure firewall (UFW)
SSH_PORT="22"
echo -e "\n[6/10] Configuring firewall (UFW)..."
ufw allow "$SSH_PORT"/tcp > /dev/null
ufw --force enable

# 7. Generate SSH Key Pair for root user
echo -e "\n[7/10] Generating SSH key pair for root..."
DEFAULT_EMAIL="root@$(hostname)"

# Create .ssh directory and set permissions
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# Generate keys non-interactively
ssh-keygen -t rsa -b 4096 -C "$DEFAULT_EMAIL" -f /root/.ssh/id_rsa -N ""

# Add the new public key to authorized_keys
cat /root/.ssh/id_rsa.pub > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

echo "Root SSH key pair generated and authorized."

# 8. Configure SSH daemon (sshd_config)
echo -e "\n[8/10] Configuring SSH daemon for key-based root login..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Write new configuration:
# PermitRootLogin yes -> Allows root to log in.
# PasswordAuthentication no -> DISAbLES password login (MUCH SAFER).
bash -c 'cat > /etc/ssh/sshd_config << EOL
Port '$SSH_PORT'
PermitRootLogin yes
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

# 9. Restart SSH service
echo -e "\n[9/10] Restarting SSH service..."
systemctl daemon-reload
systemctl restart sshd

# 10. Display login information
vps_ip=$(curl -s ifconfig.me)
echo -e "\n[10/10] Fetching VPS IP Address..."

echo -e "\n\n=== SETUP COMPLETE ==="
echo "Your server is now configured for root login via SSH Key ONLY."
echo "Password login has been disabled for security."
echo "------------------------------------------------------------------"
echo "IP Address : $vps_ip"
echo "Port       : $SSH_PORT"
echo "User       : root"
echo "------------------------------------------------------------------"
echo -e "\n⬇️ SAVE YOUR PRIVATE KEY (BELOW) ⬇️"
echo "Copy all text between the dashed lines. Save it as a file (e.g., id_rsa) on your computer."
echo "You will use this file in Termius or MobaXterm to log in."
echo "=================================================================="

# Display the private key for the user to copy
cat /root/.ssh/id_rsa

echo "=================================================================="
echo "WARNING: Keep this Private Key secure and do not share it!"
