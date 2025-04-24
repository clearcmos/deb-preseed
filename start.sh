#!/bin/bash

# Get the hostname without domain
HOSTNAME=$(hostname -s)

# Check if the host directory exists
if [ ! -d "hosts/$HOSTNAME" ]; then
    echo "Error: Host directory 'hosts/$HOSTNAME' not found."
    exit 1
fi

source /etc/profile

# Run the commands
1p && ./hosts/$HOSTNAME/base.sh && cd hosts/$HOSTNAME/docker-compose && sudo docker-compose --env-file /etc/secrets/.docker up && cd ~
