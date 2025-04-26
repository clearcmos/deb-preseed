#!/bin/bash

# Get script directory and hostname
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
HOSTNAME=$(hostname -s)

# Check if the host directory exists
if [ ! -d "$SCRIPT_DIR/hosts/$HOSTNAME" ]; then
    echo "Error: Host directory 'hosts/$HOSTNAME' not found."
    exit 1
fi

source /etc/profile

# Run the initial setup commands
sudo mkdir -p /usr/local/lib/shared-npm && \
sudo chown -R $USER:$USER /usr/local/lib/shared-npm && \
npm config set prefix '/usr/local/lib/shared-npm' && \
npm install -g @anthropic-ai/claude-code && \
echo 'export PATH=/usr/local/lib/shared-npm/bin:$PATH' | sudo tee /etc/profile.d/shared-npm.sh && \
sudo chmod +x /etc/profile.d/shared-npm.sh && \
echo 'export PATH=/usr/local/lib/shared-npm/bin:$PATH' >> ~/.profile && \

source ~/.profile && \

# Run 1p and auto-respond "y" to the prompt
yes y | 1p

$SCRIPT_DIR/common/config/configure-auto-updates.sh && \
$SCRIPT_DIR/common/config/configure-smb-shares.sh && \
$SCRIPT_DIR/common/config/configure-ssh-server.sh

# Ask if user wants to restore from backup
read -p "Do you want to restore from a system backup? (y/n): " restore_choice
if [[ "$restore_choice" =~ ^[Yy]$ ]]; then
    echo "Running restore script..."
    $SCRIPT_DIR/common/backup/restore-host.sh
    # After restore, ask if user wants to start containers
    read -p "Do you want to start the containers now? (y/n): " start_choice
    if [[ "$start_choice" =~ ^[Yy]$ ]]; then
        echo "Starting containers..."
        $SCRIPT_DIR/hosts/$HOSTNAME/docker-compose/up.sh
    else
        echo "Containers not started. You can start them later with: $SCRIPT_DIR/hosts/$HOSTNAME/docker-compose/up.sh"
    fi
else

    # If no restore, continue with normal startup
    echo "Starting containers..."
    $SCRIPT_DIR/hosts/$HOSTNAME/docker-compose/up.sh
fi
