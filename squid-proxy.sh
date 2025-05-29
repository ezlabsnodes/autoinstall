#!/bin/bash

# Define color codes
RED='\033[0;31m'
RESET='\033[0m' # Reset color

# Prompt for username and password
read -p "Enter proxy username: " PROXY_USER
read -s -p "Enter proxy password: " PROXY_PASS
echo ""

# Disable interactive restart prompts (needrestart workaround)
export NEEDRESTART_MODE=a

# Update and upgrade system
sudo DEBIAN_FRONTEND=noninteractive apt update
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y

# Install Squid and Apache2-utils for authentication
sudo apt install -y squid apache2-utils

# Enable Squid
sudo systemctl enable squid

# Configure Squid
sudo bash -c 'cat > /etc/squid/squid.conf <<EOF
http_port 12323
forwarded_for off
request_header_access X-Forwarded-For deny all
request_header_access Via deny all
reply_header_access Via deny all
via off
header_replace Via ""
dns_nameservers 8.8.8.8 8.8.4.4
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwords
auth_param basic realm proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
http_access allow all
cache_dir ufs /var/spool/squid 100 16 256
cache_mem 256 MB
maximum_object_size 256 MB
access_log /var/log/squid/access.log
cache_log /var/log/squid/cache.log
EOF'

# Create password file
echo "$PROXY_PASS" | sudo htpasswd -c -i /etc/squid/passwords "$PROXY_USER"

# Secure the password file
sudo chmod 644 /etc/squid/passwords
sudo chown proxy:proxy /etc/squid/passwords

# Initialize Squid cache
sudo systemctl stop squid
sudo rm -f /run/squid.pid
sudo squid -z

# Get public IP
IP_PUBLIC=$(curl -s ipinfo.io/ip)

# Add IP-specific config
sudo bash -c "cat > /etc/squid/conf.d/ip1.conf <<EOF
http_port $IP_PUBLIC:12323
EOF"

# Open firewall port
sudo ufw allow 12323/tcp
sudo ufw reload

# Test and restart Squid
sudo squid -k parse
sudo systemctl restart squid

# Output success
echo -e "${RED}/////////////////////////////////////////////////////////////////////////////${RESET}"
echo -e "${RED}Squid has been successfully configured${RESET}"
echo -e "${RED}Access Proxy via:${RESET}"
echo -e "${RED}${IP_PUBLIC}:12323${RESET}"
echo -e "${RED}Username: $PROXY_USER${RESET}"
echo -e "${RED}Password: [you entered it manually]${RESET}"
echo -e "${RED}/////////////////////////////////////////////////////////////////////////////${RESET}"
