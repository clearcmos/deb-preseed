#!/bin/bash
# Source Cloudflare credentials
if [ -r "/etc/secrets/.$(hostname)" ]; then
    source /etc/secrets/.$(hostname)
else
    echo "Warning: Cannot read /etc/secrets/.$(hostname) - you may need to run 1p function to fix permissions"
    echo "Continuing without Cloudflare credentials..."
fi

# Change to the script's directory to ensure relative paths work correctly
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

# Ensure acme.json exists with proper permissions
if [ ! -f "./traefik/acme.json" ]; then
    echo "Creating empty acme.json file..."
    mkdir -p ./traefik
    touch ./traefik/acme.json
    chmod 600 ./traefik/acme.json
else
    # Ensure permissions are correct even if file exists
    chmod 600 ./traefik/acme.json
fi

# Export the email directly from the file to ensure it's available
if [ -r "/etc/secrets/.docker" ]; then
    export ACME_EMAIL=$(grep -i "ACME_EMAIL" /etc/secrets/.docker | cut -d= -f2)
    echo "Using ACME_EMAIL: $ACME_EMAIL"
    
    # Launch production environment with DNS setup using secrets
    sudo -E docker-compose --env-file /etc/secrets/.docker up "$@"
else
    echo "Warning: Cannot read /etc/secrets/.docker - you may need to run 1p function to fix permissions"
    echo "Continuing without Docker credentials..."
    
    # Launch production environment without secrets
    sudo -E docker-compose up "$@"
fi
