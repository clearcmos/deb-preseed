> [!NOTE]
> The code in this repo has been created with the help of AI. Use at your own risk.

# Debian Preseed and Docker Infrastructure

This repository provides an end-to-end solution for automating Debian installations and deploying a containerized infrastructure stack. It combines a customized Debian installer with Docker Compose services for web hosting, authentication, monitoring, VPN, and media services.

## Table of Contents

- [Overview](#overview)
- [Installation](#installation)
  - [Creating a Custom Debian ISO](#creating-a-custom-debian-iso)
  - [Environment Configuration](#environment-configuration)
- [Infrastructure Components](#infrastructure-components)
  - [Authentication (Authelia)](#authentication-authelia)
  - [Reverse Proxy (Traefik)](#reverse-proxy-traefik)
  - [DNS Management](#dns-management)
  - [Monitoring (Glances)](#monitoring-glances)
  - [Media Server (Jellyfin)](#media-server-jellyfin)
  - [VPN (WireGuard)](#vpn-wireguard)
- [Security](#security)
  - [Traffic Analysis](#traffic-analysis)
  - [Security Scanning](#security-scanning)
  - [Hardening](#hardening)
- [Backup and Restore](#backup-and-restore)
- [Documentation](#documentation)
- [Getting Started](#getting-started)
  - [First-time Setup](#first-time-setup)
  - [Authentication Setup](#authentication-setup)
  - [Adding New Services](#adding-new-services)
- [Post-Installation](#post-installation)
- [Troubleshooting](#troubleshooting)

## Overview

This project provides two main components:

1. **Automated Debian Installer**: Creates a custom Debian installation ISO with preconfigured settings for unattended installation.
2. **Docker Infrastructure**: Sets up a complete containerized environment with authentication, reverse proxy, VPN, and various services.

The system is designed to be modular, allowing you to easily add or remove services as needed, while maintaining security through a centralized authentication system.

## Installation

### Creating a Custom Debian ISO

To create a custom Debian installation ISO:

1. Clone this repository:
   ```bash
   git clone https://github.com/clearcmos/deb-preseed.git
   cd deb-preseed
   ```

2. Run the build script:
   ```bash
   sudo ./build/build-iso.sh
   ```

3. The script will:
   - Install required dependencies automatically
   - Prompt you to select a host configuration
   - Create necessary environment files if they don't exist
   - Modify the Debian installer to use your configuration
   - Build a custom ISO file with automated installation

### Environment Configuration

Two configuration files need to be set up:

1. **Global Preseed Settings** (`/etc/secrets/.preseed`):
   ```
   ROOT_PASSWORD=your_root_password
   USER_FULLNAME="Your Name"
   USERNAME=your_username
   USER_PASSWORD=your_user_password
   SSH_AUTHORIZED_KEY=your_ssh_public_key
   ISO_MOVE=optional_command_to_move_iso
   ```

2. **Host-Specific Settings** (`/etc/secrets/.hostname`):
   ```
   NETWORK_HOSTNAME=hostname
   NETWORK_DOMAIN=your.domain
   NETWORK_IP=192.168.1.x
   NETWORK_GATEWAY=192.168.1.1
   NETWORK_DNS=192.168.1.1
   NETWORK_NETMASK=255.255.255.0
   PACKAGES="apt-listchanges ca-certificates curl git openssh-server sudo ..."
   ```

The script will create these files with templates if they don't exist and guide you through the setup process.

## Infrastructure Components

### Authentication (Authelia)

Authelia provides a centralized authentication system for all web services:

- **Features**:
  - Two-factor authentication (TOTP and WebAuthn/security keys)
  - Secure password storage with Argon2id hashing
  - Session management
  - Access control policies per domain

- **Configuration**: Located in `hosts/misc/docker-compose/authelia/config/configuration.yml`

- **User Database**: Located in `hosts/misc/docker-compose/authelia/config/users_database.yml`

- **Access URL**: https://auth.yourdomain.com

### Reverse Proxy (Traefik)

Traefik routes traffic to the appropriate services and handles HTTPS:

- **Features**:
  - Automatic HTTPS with Let's Encrypt certificates
  - Integration with Docker for service discovery
  - Middleware support for authentication

- **Configuration**: Located in `hosts/misc/docker-compose/traefik/traefik.yml`

### DNS Management

The DNS management system automatically configures Cloudflare DNS records:

- **Features**:
  - Automatic CNAME record creation for each service
  - Verification of DNS propagation
  - Non-proxied DNS records for optimal Let's Encrypt operation

- **Implementation**: Python script in `hosts/misc/docker-compose/dns-setup/dns-setup.py`

- **Requirements**:
  - Cloudflare API token
  - Cloudflare Zone ID
  - Valid domain name

### Monitoring (Glances)

Glances provides system monitoring for the host:

- **Features**:
  - CPU, memory, disk, and network monitoring
  - Process monitoring
  - Docker container statistics

- **Access URL**: https://glances.yourdomain.com (requires authentication)

### Media Server (Jellyfin)

Jellyfin provides media streaming capabilities:

- **Features**:
  - Media organization and transcoding
  - User management
  - Streaming to various devices

- **Access URL**: https://jellyfin.yourdomain.com

### VPN (WireGuard)

WireGuard provides secure remote access to your network:

- **Features**:
  - Modern, secure VPN protocol
  - Easy peer configuration
  - Web-based configuration and QR codes for mobile devices

- **Configuration**: Located in `hosts/misc/docker-compose/wireguard/config/`

## Security

### Traffic Analysis

The repository includes a web traffic analysis tool that helps identify and analyze suspicious traffic to your services:

- **Script**: `common/analyze_web_traffic.py`

- **Features**:
  - Analyzes Traefik logs to detect suspicious activity
  - Identifies potential attacks including SQL injection attempts, path traversal, etc.
  - Provides geographic information about connecting IPs
  - Generates detailed reports of connection attempts

- **Usage**:
  ```bash
  cd ~/deb-preseed
  python3 common/analyze_web_traffic.py
  ```

- **Requirements**:
  - Docker (to access Traefik logs)
  - geoip-bin package (for geolocation features)
  - Python 3.x

The analysis tool looks for various suspicious patterns including:
- WordPress admin access attempts
- Git repository access attempts
- Environment file access
- Admin panel access
- SQL injection attempts
- PHP code injection
- XSS attempts

### Security Scanning

A utility script is provided to scan for sensitive information that might accidentally be committed to the repository:

- **Script**: `utils/scan-sensitive-patterns.sh`

- **Features**:
  - Scans for sensitive patterns defined in `/etc/secrets/.ignore`
  - Respects `.gitignore` exclusions
  - Detailed output of matching files and lines

- **Usage**:
  ```bash
  cd ~/deb-preseed
  ./utils/scan-sensitive-patterns.sh [directory]
  ```

- **Configuration**:
  Create a pattern file at `/etc/secrets/.ignore` containing regex patterns to search for:
  ```
  password=
  api_key=
  secret=
  ```

### Hardening

The repository includes several scripts to harden your server:

- **SSH Server Hardening** (`common/config/configure-ssh-server.sh`):
  - Disables password authentication
  - Enables key-based authentication only
  - Disables root login
  - Configures secure ciphers and algorithms

- **Automatic Updates** (`common/config/configure-auto-updates.sh`):
  - Configures unattended-upgrades for security updates
  - Sets up email notifications for updates

- **Environment Profiles**:
  - Secure shell environments with `common/env/profile`
  - Custom aliases and functions for secure operations

## Backup and Restore

The repository includes comprehensive backup and restore functionality:

- **Backup Script** (`common/backup/backup-host.sh`):
  - Creates full system backups
  - Includes Docker volumes and configurations
  - Encrypts backups for security
  - Configurable retention policy

- **Restore Script** (`common/backup/restore-host.sh`):
  - Restores from previously created backups
  - Verifies backup integrity
  - Handles Docker volumes and configurations

- **Documentation**: Detailed backup and restore instructions are available in `docs/backup-host.md`

- **Usage**:
  ```bash
  # Create a backup
  sudo ~/deb-preseed/common/backup/backup-host.sh
  
  # Restore from backup
  sudo ~/deb-preseed/common/backup/restore-host.sh /path/to/backup.tar.gz
  ```

## Documentation

The repository includes detailed documentation:

- **Backup Instructions** (`docs/backup-host.md`):
  - Detailed guide for backup and restore procedures
  - Recovery scenarios
  - Best practices for backup storage

- **Command Cheatsheet** (`docs/cheatsheet.md`):
  - Quick reference for common commands
  - Troubleshooting steps
  - Service management shortcuts

## Getting Started

### First-time Setup

1. **Install Debian using the custom ISO**:
   - Boot from the custom ISO
   - The installation will proceed automatically
   - The system will reboot when complete

2. **Initial Configuration**:
   - Log in with the credentials you configured
   - The repository will be cloned to your home directory
   - Claude Code will be automatically installed (through rc.local)

3. **Start Docker Services**:
   ```bash
   cd ~/deb-preseed
   ./start.sh
   ```

### Authentication Setup

Before accessing protected services, set up authentication:

1. **Configure Authelia users**:
   Edit the users database file:
   ```bash
   nano hosts/misc/docker-compose/authelia/config/users_database.yml
   ```

2. **Add a user**:
   ```yaml
   users:
     username:
       displayname: "Your Full Name"
       password: "$argon2id$v=19$m=65536,t=1,p=8$..."  # Generated password hash
       email: your.email@example.com
       groups:
         - admins
   ```

3. **Generate a password hash**:
   ```bash
   docker run authelia/authelia:latest authelia crypto hash generate argon2 --password 'your_secure_password'
   ```

### Adding New Services

To add a new service to the infrastructure:

1. **Create a Docker Compose file**:
   ```bash
   mkdir -p hosts/misc/docker-compose/your-service
   nano hosts/misc/docker-compose/your-service/docker-compose.yml
   ```

2. **Configure the service with Traefik labels**:
   ```yaml
   version: '3.8'
   services:
     your-service:
       image: your-service-image
       labels:
         - "traefik.enable=true"
         - "traefik.http.routers.your-service.rule=Host(`your-service.${DOMAIN}`)"
         - "traefik.http.routers.your-service.entrypoints=websecure"
         - "traefik.http.routers.your-service.tls=true"
         - "traefik.http.routers.your-service.tls.certresolver=le"
         # For Authelia authentication:
         - "traefik.http.routers.your-service.middlewares=authelia@docker"
   ```

3. **Add the service to the main docker-compose.yml**:
   ```yaml
   your-service:
     extends:
       file: ./your-service/docker-compose.yml
       service: your-service
     depends_on:
       - traefik
       - authelia
   ```

4. **Update services**:
   ```bash
   cd ~/deb-preseed/hosts/misc/docker-compose
   ./upprod.sh
   ```

## Post-Installation

After installation, you should:

1. **Change default passwords**: Even though you've set initial passwords, change them after installation.

2. **Update SSH configuration**: Review and harden SSH settings using the provided script:
   ```bash
   sudo ~/deb-preseed/common/config/configure-ssh-server.sh
   ```

3. **Configure automatic updates**: Enable automatic security updates:
   ```bash
   sudo ~/deb-preseed/common/config/configure-auto-updates.sh
   ```

4. **Set up backups**: Configure regular backups using the provided scripts:
   ```bash
   sudo ~/deb-preseed/common/backup/backup-host.sh
   ```

5. **Run security scans**: Check for sensitive information:
   ```bash
   ./utils/scan-sensitive-patterns.sh
   ```

6. **Analyze web traffic**: Monitor for suspicious activity:
   ```bash
   python3 common/analyze_web_traffic.py
   ```

## Troubleshooting

### DNS Issues

If services are not accessible:

1. Check DNS records in Cloudflare:
   ```bash
   curl -X GET "https://api.cloudflare.com/client/v4/zones/YOUR_ZONE_ID/dns_records" \
     -H "Authorization: Bearer YOUR_API_TOKEN" \
     -H "Content-Type: application/json"
   ```

2. Manually run the DNS setup:
   ```bash
   cd ~/deb-preseed/hosts/misc/docker-compose/dns-setup
   docker-compose up
   ```

### Authentication Issues

If you cannot log in:

1. Check Authelia logs:
   ```bash
   docker logs authelia
   ```

2. Reset a user's password:
   ```bash
   # Generate new password hash
   docker run authelia/authelia:latest authelia crypto hash generate argon2 --password 'new_password'
   
   # Update the users_database.yml file with the new hash
   nano ~/deb-preseed/hosts/misc/docker-compose/authelia/config/users_database.yml
   
   # Restart Authelia
   docker restart authelia
   ```

### Certificate Issues

If Let's Encrypt certificates aren't being issued:

1. Check Traefik logs:
   ```bash
   docker logs traefik
   ```

2. Ensure ports 80 and 443 are open:
   ```bash
   sudo ufw status
   ```

3. Check the acme.json file:
   ```bash
   cat ~/deb-preseed/hosts/misc/docker-compose/traefik/acme.json
   ```

### WireGuard VPN Issues

If you're having trouble with WireGuard:

1. Check WireGuard container logs:
   ```bash
   docker logs wireguard
   ```

2. Verify the configuration:
   ```bash
   cat ~/deb-preseed/hosts/misc/docker-compose/wireguard/config/wg_confs/wg0.conf
   ```

3. Generate a new peer configuration:
   ```bash
   docker exec -it wireguard /app/show-peer 2
   ```
