#!/bin/bash

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Update package lists
echo -e "${YELLOW}Updating system packages...${NC}"
sudo apt update -y

# Check Docker
if command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker is already installed.${NC}"
else
    echo -e "${YELLOW}Installing Docker...${NC}"
    sudo apt install -y apt-transport-https ca-certificates curl software-properties-common lsb-release gnupg2
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update -y
    sudo apt install -y docker-ce docker-ce-cli containerd.io
fi

# Function to check port
is_port_in_use() {
  nc -zv 127.0.0.1 "$1" &>/dev/null
  return $?
}

# Function to create container
create_browser_container() {
  # GET PUBLIC IP
  PUBLIC_IP=$(curl -s https://api.ipify.org)

  echo -e "${CYAN}---------------------------------------------${NC}"
  echo -e "${CYAN}   SELECT BROWSER TO INSTALL   ${NC}"
  echo -e "${CYAN}---------------------------------------------${NC}"
  echo "1) Chromium (Standard, Lightweight)"
  echo "2) Brave    (Adblock built-in, Crypto friendly)"
  echo "3) Firefox  (Gecko engine, Good privacy)"
  read -p "Choose browser (1-3): " browser_choice

  case $browser_choice in
    1)
      IMAGE_NAME="lscr.io/linuxserver/chromium:latest"
      APP_NAME="Chromium"
      ;;
    2)
      IMAGE_NAME="lscr.io/linuxserver/brave:latest"
      APP_NAME="Brave"
      ;;
    3)
      IMAGE_NAME="lscr.io/linuxserver/firefox:latest"
      APP_NAME="Firefox"
      ;;
    *)
      echo -e "${RED}Invalid choice. Defaulting to Chromium.${NC}"
      IMAGE_NAME="lscr.io/linuxserver/chromium:latest"
      APP_NAME="Chromium"
      ;;
  esac

  read -p "Enter Name/ID for this $APP_NAME (e.g., 01): " ACno
  CONTAINER_NAME="$APP_NAME$ACno"

  # User Inputs
  read -p "Enter USERNAME for Login: " custom_user
  read -s -p "Enter PASSWORD for Login: " password
  echo ""
  echo -e "${YELLOW}Proxy format: http://user:password@ip:port (Leave empty if none)${NC}"
  read -p "Enter proxy: " proxy
  
  # User Agent logic (Updated to Modern Version)
  read -p "Enter User-Agent (Press Enter for NEWEST default): " user_agent
  if [ -z "$user_agent" ]; then
    if [[ "$APP_NAME" == "Firefox" ]]; then
        # Updated Firefox UA to v125+
        user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0"
    else
        # Updated Chrome/Brave UA to v124+
        user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    fi
    echo -e "${YELLOW}Using Modern User-Agent: $user_agent${NC}"
  fi

  # Auto Port Assignment
  port_found=false
  for ((port=3001; port<=3090; port++)); do
    is_port_in_use $port
    if [ $? -ne 0 ]; then
      port1=$port
      port2=$((port1 + 1))
      
      is_port_in_use $port2
      if [ $? -ne 0 ]; then
          port_found=true
          break
      fi
    fi
  done

  if ! $port_found; then
    echo -e "${RED}No available ports found!${NC}"
    exit 1
  fi

  # Deploy
  echo -e "${YELLOW}Deploying $CONTAINER_NAME using image $IMAGE_NAME...${NC}"
  
  docker run -d \
    --name "$CONTAINER_NAME" \
    --security-opt seccomp=unconfined \
    -e http_proxy="$proxy" \
    -e https_proxy="$proxy" \
    -e TITLE="$CONTAINER_NAME" \
    -e PUID=1000 \
    -e PGID=1000 \
    -e CUSTOM_USER="$custom_user" \
    -e PASSWORD="$password" \
    -e CHROME_USER_AGENT="$user_agent" \
    -v "$HOME/$APP_NAME/config$ACno:/config" \
    -p "$port1:3000" \
    -p "$port2:3001" \
    --shm-size="2gb" \
    --restart unless-stopped \
    "$IMAGE_NAME"

  # Output
  echo -e "${GREEN}-----------------------------------------------------${NC}"
  echo -e "${GREEN}$CONTAINER_NAME is running!${NC}"
  echo -e "Login: $custom_user / $password"
  echo -e "${CYAN}ACCESS LINK (HTTPS): https://$PUBLIC_IP:$port2/${NC}"
  echo -e "${GREEN}-----------------------------------------------------${NC}"
}

# Main Loop
while true; do
  create_browser_container
  read -p "Create another browser? (y/n): " create_another
  if [[ ! "$create_another" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Exiting.${NC}"
    exit 0
  fi
done
