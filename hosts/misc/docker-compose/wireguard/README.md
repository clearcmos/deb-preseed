# WireGuard Docker Setup

This directory contains the WireGuard VPN server configuration for docker-compose.

## Configuration

The WireGuard service is configured using environment variables defined in the `.env` file. 
For production, these variables should be moved to `/etc/secrets/.docker`.

Required variables to add to `/etc/secrets/.docker`:

```
# WireGuard Configuration
WIREGUARD_SUBDOMAIN=vpn
WIREGUARD_PORT=51820
WIREGUARD_PEERS=1
WIREGUARD_PEERDNS=auto
WIREGUARD_INTERNAL_SUBNET=10.13.13.0
WIREGUARD_ALLOWEDIPS=0.0.0.0/0
WIREGUARD_LOG_CONFS=true
WIREGUARD_PUID=1000
WIREGUARD_PGID=1000
```

## DNS Setup

You'll need to set up a DNS record for your subdomain (vpn.yourdomain.com) to point to your server's IP address. 
This allows WireGuard clients to connect using a domain name rather than an IP address.

## Client Configuration

After starting the container, client configuration files will be available in the `./config/peer_*` directories.
Each peer's QR code can be found in the `./config/peer_*/qrcode.png` file.

## Port Forwarding

Make sure that UDP port 51820 (or whatever port you specify) is forwarded to your server on your router/firewall.