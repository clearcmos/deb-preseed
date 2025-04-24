#!/bin/bash
source /etc/secrets/.misc
sudo -E docker-compose -f docker-compose.staging.yml --env-file /etc/secrets/.docker down "$@"
