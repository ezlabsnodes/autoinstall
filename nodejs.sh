#!/bin/bash

# ... [keep all your existing color definitions and banner code] ...

# Define show function (missing from original script)
show() {
    local message=$1
    local type=${2:-"info"}
    
    case $type in
        "progress")
            echo -e "${BLUE}[*]${NC} ${message}"
            ;;
        "error")
            echo -e "${RED}[!]${NC} ${message}"
            ;;
        "success")
            echo -e "${GREEN}[✓]${NC} ${message}"
            ;;
        *)
            echo -e "${INFO}[i]${NC} ${message}"
            ;;
    esac
}

# ... [keep all your existing package installation code until Node.js section] ...

# Improved Node.js installation section
install_nodejs() {
    # Remove existing Node.js installations
    show "Removing existing Node.js installations..." "progress"
    sudo apt purge -y nodejs libnode-dev npm
    sudo apt autoremove -y
    sudo rm -rf /usr/local/lib/node* /usr/local/include/node* ~/.npm
    
    # Install Node.js LTS (recommended for stability)
    show "Installing Node.js LTS version..." "progress"
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
    
    # Verify installation
    if command -v node &> /dev/null && command -v npm &> /dev/null; then
        show "Node.js $(node -v) and npm $(npm -v) installed successfully!" "success"
    else
        show "Failed to install Node.js and npm" "error"
        exit 1
    fi
}

# Call the Node.js installation function
install_nodejs
