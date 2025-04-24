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
1p && $SCRIPT_DIR/hosts/$HOSTNAME/base.sh && cd $SCRIPT_DIR/hosts/$HOSTNAME/docker-compose && sudo docker-compose --env-file /etc/secrets/.docker up
