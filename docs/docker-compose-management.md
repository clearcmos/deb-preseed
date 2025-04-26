# Docker Compose Services Management Guide

This guide explains how to manage the Docker Compose services in this project (start, stop, and maintain them).

## Basic Commands

### Starting Services

To start all services defined in the docker-compose configuration:

```bash
cd /home/$USER/deb-preseed/hosts/misc/docker-compose
./up.sh
```

This will:
1. Create the necessary networks
2. Create and start all containers
3. Display logs in the foreground

For background operation (detached mode):

```bash
./up.sh -d
```

### Stopping Services

To gracefully stop all services:

```bash
cd /home/$USER/deb-preseed/hosts/misc/docker-compose
./stop.sh
```

This will:
1. Stop all running containers
2. Remove containers and networks created by docker-compose
3. Preserve all volumes and data

## Special Operations

### Viewing Logs

When running in detached mode, you can view logs:

```bash
cd /home/$USER/deb-preseed/hosts/misc/docker-compose
sudo docker-compose --env-file /etc/secrets/.docker logs -f [service_name]
```

Omit `[service_name]` to see logs from all services.

### Restarting Specific Services

To restart a specific service:

```bash
cd /home/$USER/deb-preseed/hosts/misc/docker-compose
sudo docker-compose --env-file /etc/secrets/.docker restart [service_name]
```

### Reset Operations (Use With Caution)

#### Removing Volumes (Data Reset)

⚠️ **WARNING**: This will delete all persistent data including:
- Authelia user database and authentication state
- Traefik SSL certificates
- Other service configurations

```bash
./stop.sh -v
```

#### Removing Orphaned Containers

Use this when you've removed services from your docker-compose files but their containers still exist:

```bash
./stop.sh --remove-orphans
```

#### Complete Cleanup

For a complete cleanup (rarely needed):

```bash
./stop.sh -v --remove-orphans
```

After this operation, your next `./up.sh` will:
- Create fresh containers
- Generate new SSL certificates
- Reset to initial configuration

## Common Issues and Solutions

### Permission Errors

If you see permission errors:

```bash
sudo chown -R 1000:1000 ./config  # Adjust user/group as needed
```

### Certificate Issues

If SSL certificates aren't being generated correctly:

1. Check DNS configuration
2. Ensure proper permissions on `traefik/acme.json`:
   ```bash
   chmod 600 ./traefik/acme.json
   ```

### Configuration Changes

After modifying docker-compose files or configuration files:

```bash
./stop.sh
./up.sh -d
```

## Service Endpoints

- Authelia: https://id.yourdomain.com
- Dashboard: https://done.yourdomain.com
- Glances: https://metrix.yourdomain.com
- Jellyfin: https://jelly.yourdomain.com

## Checking Service Status

```bash
cd /home/$USER/deb-preseed/hosts/misc/docker-compose
sudo docker-compose --env-file /etc/secrets/.docker ps
```
