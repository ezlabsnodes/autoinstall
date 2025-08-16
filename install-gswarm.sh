#!/bin/bash

echo "======================================"
echo "           GSWARM INSTALLER           "
echo "======================================"

# 1. System cleanup
echo -e "\n[1/7] Cleaning system..."
{
    sudo rm -rf /usr/local/go
    sudo rm -f /usr/local/bin/gswarm
    rm -rf ~/go ~/gswarm go*.tar.gz
    sed -i '/\/usr\/local\/go\/bin/d' ~/.bashrc
    sed -i '/\/root\/go\/bin/d' ~/.bashrc
    sed -i '/GOPATH/d' ~/.bashrc
} &> /dev/null

# 2. Install dependencies
echo -e "\n[2/7] Installing dependencies..."
{
    sudo apt-get update
    sudo apt-get install -y build-essential git wget tar curl
} &> /dev/null

# 3. Install Go
echo -e "\n[3/7] Installing Go..."
ARCH=$(uname -m)
case $ARCH in
    "x86_64") GO_ARCH="amd64" ;;
    "aarch64") GO_ARCH="arm64" ;;
    *) GO_ARCH="amd64" ;;
esac

GO_VERSION="1.24.0"
GO_TAR="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"

{
    cd ~
    wget -q --show-progress "https://go.dev/dl/${GO_TAR}"
    sudo tar -C /usr/local -xzf "$GO_TAR"
    rm "$GO_TAR"
    
    echo "export PATH=\$PATH:/usr/local/go/bin" >> ~/.bashrc
    echo "export GOPATH=\$HOME/go" >> ~/.bashrc
    echo "export PATH=\$PATH:\$GOPATH/bin" >> ~/.bashrc
    source ~/.bashrc
    export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
} &> /dev/null

# 4. Verify Go installation
echo -e "\n[4/7] Verifying Go..."
if ! command -v go &> /dev/null; then
    echo "❌ Go installation failed! Trying alternative..."
    sudo rm -rf /usr/local/go
    wget -q --show-progress "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
    sudo tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
    export PATH=$PATH:/usr/local/go/bin
fi
echo "✓ Go version: $(go version)"

# 5. Install GSwarm from source
echo -e "\n[5/7] Building GSwarm from source..."
{
    cd ~
    git clone https://github.com/Deep-Commit/gswarm.git
    cd gswarm
    make
    sudo mv build/gswarm /usr/local/bin/
    chmod +x /usr/local/bin/gswarm
} &> /dev/null

# 6. Create config if not exists
echo -e "\n[6/7] Setting up default config..."
{
    if [ ! -f ~/.gswarm/config.yaml ]; then
        mkdir -p ~/.gswarm
        echo "telegram:" > ~/.gswarm/config.yaml
        echo "  bot_token: \"YOUR_BOT_TOKEN\"" >> ~/.gswarm/config.yaml
        echo "  chat_id: \"YOUR_CHAT_ID\"" >> ~/.gswarm/config.yaml
    fi
} &> /dev/null

# 7. Run Gswarm
gswarm
