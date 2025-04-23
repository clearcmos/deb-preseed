# Authelia Setup with Traefik

This setup provides a lightweight 2FA solution for services behind Traefik using Authelia with WebAuthn/passkey support.

## Setup Instructions

1. Copy the example environment file and set your secrets:
   ```bash
   cp .env.example .env
   ```

2. Edit the `.env` file with your domain and generate secure random strings for the secrets:
   ```bash
   # Generate random strings
   openssl rand -hex 64  # For JWT_SECRET
   openssl rand -hex 64  # For SESSION_SECRET
   openssl rand -hex 32  # For STORAGE_ENCRYPTION_KEY

   # Generate a password hash
   docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password 'your_secure_password'
   ```

3. Start the Authelia service:
   ```bash
   docker-compose up -d
   ```

4. Configure your other services to use the Authelia middleware by adding this label:
   ```yaml
   - "traefik.http.routers.yourservice.middlewares=authelia@docker"
   ```

## Register WebAuthn/Passkeys

1. Log in to Authelia at `https://auth.yourdomain.com` using your username and password
2. Go to the settings page
3. Register your Android device as a WebAuthn device/passkey

## Troubleshooting

- Check Authelia logs: `docker logs authelia`
- Ensure your domain is correctly set in all configuration files
- Make sure your Traefik instance can reach the Authelia container