#!/bin/bash
# Source Cloudflare credentials
source /etc/secrets/.$(hostname)

# Change to the script's directory
cd "$(dirname "$0")"

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
export ACME_EMAIL=$(grep -i "ACME_EMAIL" /etc/secrets/.docker | cut -d= -f2)
echo "Using ACME_EMAIL: $ACME_EMAIL"

# Launch production environment with DNS setup
sudo -E docker-compose --env-file /etc/secrets/.docker up "$@"