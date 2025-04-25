# Dynamic Docker Backup System

A comprehensive backup solution for Docker environments that automatically detects and backs up containers, volumes, and configuration files based on the server's hostname.

## Overview

This backup system provides:

- **Fully dynamic operation** - automatically detects the host-specific configuration directory
- **Docker volume backup** - safely backs up all Docker volumes from running containers
- **SQLite database handling** - safely stops services when backing up SQLite databases
- **Configuration backup** - backs up all Docker Compose files and other configuration files
- **Smart retry logic** - handles files that may be temporarily locked (e.g., TLS certificates)
- **Backup rotation** - maintains the most recent backups while automatically cleaning up old ones

## Structure

The system expects the following directory structure:

```
.
├── common/
│   ├── backup-host.sh        # Main backup script
│   └── [other common files]
├── hosts/
│   ├── host1/                # Host-specific directory matching hostname
│   │   ├── docker-compose.yml
│   │   ├── service1/
│   │   │   └── docker-compose.yml
│   │   ├── service2/
│   │   │   └── docker-compose.yml
│   │   └── backups/          # Created automatically
│   └── host2/
│       └── ...
```

## How It Works

1. **Host Detection**: 
   - Script automatically identifies the current hostname
   - Locates the corresponding host directory under `../hosts/`

2. **Configuration Backup**:
   - Backs up all configuration files in the host directory
   - Preserves the directory structure in the backup

3. **Docker Service Detection**:
   - Discovers all Docker Compose projects by finding docker-compose.yml files
   - Maps running containers to their corresponding services

4. **Volume Backup**:
   - Identifies all mounted volumes for each container
   - For regular volumes, uses direct copying
   - For volumes containing SQLite databases, uses special handling

5. **SQLite Database Handling**:
   - Automatically detects SQLite databases (*.db, *.sqlite, *.sqlite3)
   - Temporarily stops the container for a consistent backup
   - Uses SQLite's backup API if available in the container
   - Restarts the container after backup

6. **Special File Handling**:
   - Uses retry logic for files that may be locked (like TLS certificates)
   - Makes multiple attempts with short timeouts

7. **Backup Verification and Rotation**:
   - Verifies the integrity of the created backup archive
   - Keeps the 12 most recent backups, automatically removing older ones

## Usage

Simply run the script as a user with Docker permissions:

```bash
/path/to/common/backup-host.sh
```

The script will:
1. Create a backup directory at `../hosts/[hostname]/backups/` if it doesn't exist
2. Log all activities to a timestamped log file in the backup directory
3. Create a timestamped backup archive (`docker-compose-backup-YYYY-MM-DD-HHMM.tar.gz`)

## Requirements

- Bash
- Docker
- Docker Compose
- Find utility

## Recommended Setup

1. Set up as a daily cron job for automated backups
2. Monitor the backup logs for any warnings or errors

## Notes

- The backup directory is excluded from the backup to avoid recursive backups
- Hidden files (starting with `.`) are excluded from the backup
- All backup archives and logs are automatically rotated, keeping the 12 most recent copies