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
1p

# Additional check to ensure /etc/secrets permissions are correct
if [ -d "/etc/secrets" ]; then
    # Ensure proper ownership and permissions for /etc/secrets directory
    sudo chown root:secrets /etc/secrets
    sudo chmod 750 /etc/secrets
    
    # Fix permissions for all files inside
    echo "Ensuring proper permissions on secret files..."
    sudo chown -R root:secrets /etc/secrets
    sudo find /etc/secrets -type f -exec sudo chmod 640 {} \;
    
    # Make sure the user is in the secrets group and the group is active
    if id -nG | grep -qw secrets; then
        # User is in secrets group, but it might not be active in current session
        if ! touch /etc/secrets/.test 2>/dev/null; then
            echo "Running newgrp to activate secrets group permissions..."
            echo "After this script finishes, you might need to run 'newgrp secrets' to access secrets in new terminal sessions."
        fi
    elif getent group secrets | grep -qw "$USER"; then
        # User is in group but needs to log out and back in
        echo "NOTE: You are in the secrets group, but need to log out and back in for it to take effect."
        echo "Alternatively, you can run 'newgrp secrets' to activate it in this session."
    else
        # User is not in the secrets group
        echo "Adding $USER to secrets group..."
        sudo usermod -a -G secrets "$USER"
        echo "NOTE: You have been added to the secrets group. Please log out and back in, or run 'newgrp secrets'."
    fi
fi

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
