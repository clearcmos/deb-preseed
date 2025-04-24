#!/bin/bash
cd "$(dirname "$0")"

# Source Cloudflare credentials
source /etc/secrets/.misc

# Launch simplified staging environment with HTTP only (no HTTPS)
sudo -E docker-compose -f docker-compose.simple.yml --env-file /etc/secrets/.docker up "$@"