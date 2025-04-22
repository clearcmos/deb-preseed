#!/bin/bash

# Get the hostname without domain
HOSTNAME=$(hostname -s)

# Check if the host directory exists
if [ ! -d "hosts/$HOSTNAME" ]; then
    echo "Error: Host directory 'hosts/$HOSTNAME' not found."
    exit 1
fi

# Source the system files for functions and aliases
source /etc/functions
source /etc/aliases

# Run the commands
1p && cd hosts/$HOSTNAME/docker-compose && up && cd ~