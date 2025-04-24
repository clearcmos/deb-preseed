#!/bin/bash
# Source Cloudflare credentials
source /etc/secrets/.misc

# Launch production environment with DNS setup
sudo -E docker-compose --env-file /etc/secrets/.docker up "$@"