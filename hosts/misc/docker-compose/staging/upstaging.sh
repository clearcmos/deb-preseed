#!/bin/bash
cd "$(dirname "$0")"

# Source Cloudflare credentials
source /etc/secrets/.misc

# Launch staging environment with DNS setup
sudo -E docker-compose -f docker-compose.staging.yml --env-file /etc/secrets/.docker up "$@"