#!/bin/sh
set -e

echo "Starting Authelia entrypoint script..."

# Check if required environment variables are set
if [ -z "$DOMAIN" ]; then echo "ERROR: DOMAIN not set"; exit 1; fi
if [ -z "$AUTHELIA_JWT_SECRET" ]; then echo "ERROR: AUTHELIA_JWT_SECRET not set"; exit 1; fi
if [ -z "$AUTHELIA_SESSION_SECRET" ]; then echo "ERROR: AUTHELIA_SESSION_SECRET not set"; exit 1; fi
if [ -z "$AUTHELIA_STORAGE_ENCRYPTION_KEY" ]; then echo "ERROR: AUTHELIA_STORAGE_ENCRYPTION_KEY not set"; exit 1; fi
if [ -z "$AUTHELIA_USER_PASSWORD_HASH" ]; then echo "ERROR: AUTHELIA_USER_PASSWORD_HASH not set"; exit 1; fi
if [ -z "$AUTHELIA_USER_EMAIL" ]; then echo "ERROR: AUTHELIA_USER_EMAIL not set"; exit 1; fi

echo "Processing configuration.yml..."
# Create a temporary configuration file with environment variables processed
cat /config/configuration.yml | \
  sed "s|\${DOMAIN}|$DOMAIN|g" | \
  sed "s|\${AUTHELIA_JWT_SECRET}|$AUTHELIA_JWT_SECRET|g" | \
  sed "s|\${AUTHELIA_SESSION_SECRET}|$AUTHELIA_SESSION_SECRET|g" | \
  sed "s|\${AUTHELIA_STORAGE_ENCRYPTION_KEY}|$AUTHELIA_STORAGE_ENCRYPTION_KEY|g" \
  > /tmp/configuration.yml

echo "Processing users_database.yml..."
# Create a temporary users database with environment variables processed
cat /config/users_database.yml | \
  sed "s|\${AUTHELIA_USER_PASSWORD_HASH}|$AUTHELIA_USER_PASSWORD_HASH|g" | \
  sed "s|\${AUTHELIA_USER_EMAIL}|$AUTHELIA_USER_EMAIL|g" \
  > /tmp/users_database.yml

# Copy the processed users_database back to the config directory
cp /tmp/users_database.yml /config/users_database.yml.runtime

echo "Checking processed configuration files:"
echo "==========================================="
echo "DOMAIN: $DOMAIN"
echo "Users database path: /config/users_database.yml.runtime"
echo "User email format check: $AUTHELIA_USER_EMAIL"
echo "Password hash length: ${#AUTHELIA_USER_PASSWORD_HASH} characters"
echo "==========================================="

echo "Starting Authelia..."
# Start Authelia with the processed configuration
exec authelia --config /tmp/configuration.yml