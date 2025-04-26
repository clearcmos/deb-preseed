#!/bin/bash
# Script to gracefully stop all Docker Compose services

# Change to the script's directory to ensure relative paths work correctly
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

# Source environment variables if available
if [ -r "/etc/secrets/.docker" ]; then
    echo "Using environment variables from /etc/secrets/.docker"
    # Stop services with env file
    sudo -E docker-compose --env-file /etc/secrets/.docker down $@
else
    echo "Warning: Cannot read /etc/secrets/.docker"
    # Stop services without env file
    sudo -E docker-compose down $@
fi

echo "All services have been stopped."