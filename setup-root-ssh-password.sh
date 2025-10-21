#!/bin/bash

# 1. Ensure the script is run as root (for example, with sudo)
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Try: sudo $0" >&2
    exit 1
fi

# 2. Ask for the new root password once with confirmation
while true; do
    read -s -p "Enter new root password: " root_pass
    echo
    read -s -p "Re-enter new root password: " root_pass_confirm
    echo
    if [ "$root_pass" = "$root_pass_confirm" ]; then
        if [ -z "$root_pass" ]; then
            echo "Password must not be empty. Please try again."
        else
            break # Passwords match and are not empty
        fi
    else
        echo "Passwords do not match. Please try again."
    fi
done

echo -e "\n[1/7] Updating system packages..."
apt update -y > /dev/null 2>&1

# 3. Set root password non-interactively
echo -e "\n[2/7] Setting root password..."
# Use chpasswd to set the password non-interactively
echo "root:$root_pass" | chpasswd
if [ $? -eq 0 ]; then
    echo "Root password set successfully."
else
    echo "Failed to set root password."
    exit 1
fi

# 4. Add the sudo user (the user who invoked sudo) to the 'sudo' group
# $SUDO_USER stores the original user name
current_user=${SUDO_USER:-$(who am i | awk '{print $1}')}
if [ -n "$current_user" ] && [ "$current_user" != "root" ]; then
    echo -e "\n[3/7] Adding user '$current_user' to sudo group..."
    usermod -aG sudo "$current_user"
    echo "User $current_user added to sudo group."
else
    echo -e "\n[3/7] Skipped: Could not find a non-root user (you may be logged in as root)."
fi

# 5. Configure /etc/hosts
echo -e "\n[4/7] Configuring /etc/hosts..."
instance_name=$(hostname)
cp /etc/hosts /etc/hosts.backup
if ! grep -q "127.0.0.1 $instance_name" /etc/hosts; then
    echo "Adding $instance_name to /etc/hosts..."
    # Use 'tee -a' to append to the file as root
    echo "127.0.0.1 $instance_name" | tee -a /etc/hosts > /dev/null
else
    echo "Entry '$instance_name' already exists in /etc/hosts."
fi

# 6. Install OpenSSH Server
echo -e "\n[5/7] Installing OpenSSH server..."
apt install -y openssh-server > /dev/null 2>&1

# 7. Configure SSH daemon to allow root login with password
echo -e "\n[6/7] Configuring SSH for root login with password..."
SSH_PORT="22"
# Backup original configuration
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Write new configuration, same as your original script
cat > /etc/ssh/sshd_config << EOL
Port $SSH_PORT
PermitRootLogin yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOL

# 8. Restart SSH service
echo -e "\n[7/7] Restarting SSH service..."
systemctl restart ssh

# Get VPS IP (using ifconfig.me)
vps_ip=$(curl -s ifconfig.me)

echo -e "\n=== Setup Complete ==="
echo "Automatic SSH configuration finished."
echo "----------------------------------------"
echo "ipv4     : $vps_ip"
echo "user     : root"
echo "password : $root_pass"
echo "----------------------------------------"
