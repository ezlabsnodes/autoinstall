#!/bin/bash

# Create directory 'ezlabs'
mkdir -p ezlabs

# Copy files to 'ezlabs'
cp /root/rl-swarm/modal-login/temp-data/userApiKey.json /root/ezlabs/
cp /root/rl-swarm/modal-login/temp-data/userData.json /root/ezlabs/
cp /root/rl-swarm/swarm.pem /root/ezlabs/

# Close Screen and Remove Old Repository
screen -XS genysyn quit && rm -rf ezlabs7.zip && cd ~ && rm -rf rl-swarm

# Install Automation Tools
sudo apt-get update
sudo apt-get install expect -y

# Download and Unzip ezlabs7.zip, then change to rl-swarm directory
sudo apt-get install -y unzip && \
wget https://github.com/ezlabsnodes/gensyn/raw/refs/heads/main/ezlabs7.zip && \
unzip ezlabs7.zip && \
cd rl-swarm

# Copy swarm.pem to /root/rl-swarm/
cp /root/ezlabs/swarm.pem /root/rl-swarm/

# Create Screen and run commands
screen -S genysyn -dm bash -c "python3 -m venv .venv && source .venv/bin/activate && chmod +x run_rl_swarm.sh && chmod +x run_gensyn_auto.exp && ./run_gensyn_auto.exp"

echo "Script completed. The 'gensyn' screen session should be running in the background."
