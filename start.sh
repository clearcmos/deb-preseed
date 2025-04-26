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

# Run the commands
1p && \
$SCRIPT_DIR/common/config/configure-auto-updates.sh && \
$SCRIPT_DIR/common/config/configure-smb-shares.sh && \
$SCRIPT_DIR/common/config/configure-ssh-server.sh && \
$SCRIPT_DIR/hosts/$HOSTNAME/docker-compose/up.sh
