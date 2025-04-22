# Docker Compose Service Stack

This directory contains a Docker Compose stack for running Traefik as a reverse proxy alongside various services.

## Services

### Traefik
Traefik is configured as a reverse proxy with automatic HTTPS certificate management using Let's Encrypt. It routes requests to the appropriate services based on the domain name.

### Glances
Glances provides system monitoring accessible via a web interface at `glances.bedrosn.com`.

## Configuration

### Environment Variables
The configuration uses environment variables stored in `.env` files to avoid hardcoding sensitive or personal information:

- `traefik/.env` - Contains:
  - `DOMAIN`: Domain name for services (e.g., bedrosn.com)
  - `ACME_EMAIL`: Email address for Let's Encrypt certificate notifications

## Usage

### Starting All Services
To start all services together:

```bash
cd docker-compose
docker compose up -d
```

### Starting Individual Services
To start services individually:

```bash
# Start Traefik
cd docker-compose/traefik
docker compose up -d

# Start Glances
cd docker-compose/glances
docker compose up -d
```

### Stopping Services
To stop all services:

```bash
cd docker-compose
docker compose down
```

## Adding New Services

To add a new service:

1. Create a directory for the service under `docker-compose/`
2. Create a `docker-compose.yml` file for the service with appropriate Traefik labels
3. Optionally, add the service to the root `docker-compose.yml` file if you want it to start with everything else

Example Traefik labels for a new service:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.myservice.rule=Host(`myservice.${DOMAIN}`)"
  - "traefik.http.routers.myservice.entrypoints=websecure"
  - "traefik.http.routers.myservice.tls.certresolver=le"
  - "traefik.http.services.myservice.loadbalancer.server.port=8080"
```

## Network
All services share a common network named `proxy` to enable communication between containers.