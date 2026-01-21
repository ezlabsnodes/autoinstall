#!/bin/bash

# Color codes for different messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Update package lists and upgrade installed packages
echo -e "${YELLOW}Updating and upgrading system packages...${NC}"
sudo apt update -y

# Check if Docker is already installed (only once)
if command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker is already installed, skipping Docker installation.${NC}"
else
    # Install Docker if it's not installed (only if the user hasn't already installed it)
    echo -e "${YELLOW}Docker is not installed. Installing Docker...${NC}"
    sudo apt install -y \
      apt-transport-https \
      ca-certificates \
      curl \
      software-properties-common \
      lsb-release \
      gnupg2

    echo -e "${YELLOW}Adding Docker's official GPG key...${NC}"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

    echo -e "${YELLOW}Adding Docker repository...${NC}"
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt update -y
    sudo apt install -y docker-ce docker-ce-cli containerd.io

    echo -e "${YELLOW}Docker has been installed!${NC}"
fi

# Function to check if a port is in use
is_port_in_use() {
  nc -zv 127.0.0.1 "$1" &>/dev/null
  return $?
}

# Function to create a Chromium container
create_chromium_container() {
  #FETCH IP
  PUBLIC_IP=$(curl -s https://api.ipify.org)

  # Prompt the user for inputs
  read -p "Enter your chromium Name: " ACno

  # Prompt for a username, password, and proxy
  read -p "Enter CUSTOM_USER (username): " custom_user
  read -s -p "Enter PASSWORD: " password
  echo ""
  echo -e "${YELLOW} proxy format : http://user:password@ip:port${NC}"
  read -p "Enter proxy: " proxy

  # Prompt for User-Agent (optional)
  read -p "Enter User-Agent for Chromium (press Enter to use default): " user_agent
  if [ -z "$user_agent" ]; then
    user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
    echo -e "${YELLOW}Using default User-Agent: $user_agent${NC}"
  fi
  echo

  # Automatically assign port1 in the range of 3001 to 3050
  port_found=false
  for ((port=3001; port<=3050; port++)); do
    is_port_in_use $port
    if [ $? -ne 0 ]; then
      port1=$port
      port2=$((port1 + 1))  # Calculate port2 automatically
      
      # Double check port2 availability
      is_port_in_use $port2
      if [ $? -ne 0 ]; then
          port_found=true
          break
      fi
    fi
  done

  # If no available port is found, display an error and exit
  if ! $port_found; then
    echo -e "${RED}No available ports found in the range 3001-3050.${NC}"
    exit 1
  fi

   # Create Docker container
   # ADDED: --security-opt seccomp=unconfined (Fixes blank screen/crash)
   # UPDATED: --shm-size to 2gb (Better stability)
    docker run -d \
        --name "Chromium$ACno" \
        --security-opt seccomp=unconfined \
        -e http_proxy="$proxy" \
        -e https_proxy="$proxy" \
        -e TITLE="Chromium$ACno" \
        -e PUID=1000 \
        -e PGID=1000 \
        -e CUSTOM_USER="$custom_user" \
        -e PASSWORD="$password" \
        -e CHROME_USER_AGENT="$user_agent" \
        -v "$HOME/chromium/config$ACno:/config" \
        -p "$port1:3000" \
        -p "$port2:3001" \
        --shm-size="2gb" \
        --restart unless-stopped \
        lscr.io/linuxserver/chromium:latest

  # Print confirmation message
  echo -e "${GREEN}-----------------------------------------------------${NC}"
  echo -e "${GREEN}Chromium$ACno is started successfully!${NC}"
  echo -e "${YELLOW}Username: $custom_user${NC}"
  echo -e "${YELLOW}Password: $password${NC}"
  echo -e "${YELLOW}User-Agent: $user_agent${NC}"
  echo -e "${GREEN}-----------------------------------------------------${NC}"
  echo -e "ACCESS LINKS:"
  echo -e "HTTP  (Standard): http://$PUBLIC_IP:$port1/"
  echo -e "HTTPS (Secure)  : https://$PUBLIC_IP:$port2/  <-- ${CYAN}RECOMMENDED (Use this to fix error)${NC}"
  echo -e "${GREEN}-----------------------------------------------------${NC}"
  echo -e "${CYAN}Note: If using HTTPS, accept the security warning in your browser.${NC}"
}

# Main script loop
while true; do
  # Call the function to create a Chromium container
  create_chromium_container

  # Ask if the user wants to create another Chromium container
  read -p "Do you want to create another Chromium container? (y/n): " create_another
  if [[ ! "$create_another" =~ ^[Yy]$ ]]; then
    
    echo -e "${YELLOW}Exiting the script.${NC}"
    exit 0
  fi
done
