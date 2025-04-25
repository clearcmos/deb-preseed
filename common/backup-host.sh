#!/bin/bash
set -e

# Dynamic Docker Volume Backup Script
# Automatically backs up docker volumes and configuration based on the host

# Ensure script is run with sudo
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run with sudo. Restarting with sudo..."
    exec sudo "$0" "$@"
    exit $?
fi

# Source NAS secrets file which contains BACKUP_MOUNT variable
if [ -f /etc/secrets/.nas ]; then
  source /etc/secrets/.nas
fi

# Check if BACKUP_MOUNT is defined
if [ -z "$BACKUP_MOUNT" ]; then
  echo "ERROR: BACKUP_MOUNT environment variable is not defined."
  echo "This variable should be defined in /etc/secrets/.nas which is sourced in /etc/profile."
  echo "Please make sure the file exists and the variable is properly set."
  exit 1
fi

# Get hostname for dynamic backup
HOST=$(hostname)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_DIR="$(realpath "$SCRIPT_DIR/../hosts/$HOST")"

# Configuration
BACKUP_DIR="$BACKUP_MOUNT"
DATE=$(date +%Y-%m-%d-%H%M)
BACKUP_FILE="$BACKUP_DIR/docker-compose-backup-$DATE.tar.gz"
LOG_FILE="$BACKUP_DIR/backup-$DATE.log"
DOCKER_COMPOSE_DIR="$HOST_DIR"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Start logging
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Starting backup at $(date)"
echo "Host: $HOST"
echo "Host directory: $HOST_DIR"

# Check if host directory exists
if [ ! -d "$HOST_DIR" ]; then
  echo "ERROR: Host directory $HOST_DIR does not exist!"
  exit 1
fi

# Function to detect SQLite databases in a container
detect_sqlite_dbs() {
  local container=$1
  local volume_path=$2
  local db_list
  
  echo "Detecting SQLite databases in $container..."
  db_list=$(docker exec $container find $volume_path -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" 2>/dev/null || echo "")
  
  echo "$db_list"
}

# Function to safely backup SQLite database
backup_sqlite() {
  local container=$1
  local db_path=$2
  local backup_path=$3
  local container_dir=$(dirname "$db_path")
  
  echo "Creating consistent backup of SQLite database $db_path in $container..."
  docker exec $container bash -c "
    if command -v sqlite3 &> /dev/null; then
      echo 'Using sqlite3 for consistent backup'
      sqlite3 $db_path '.backup $db_path.bak'
      cp $db_path.bak $db_path.backup
      rm $db_path.bak
    else
      echo 'sqlite3 not available, using file copy'
      cp $db_path $db_path.backup
    fi"
  
  # Make sure target directory exists in temp dir
  mkdir -p "$backup_path/$(dirname "$db_path")"
  
  # Copy the backup file from container to host
  docker cp $container:$db_path.backup "$backup_path/$db_path"
  
  # Clean up backup file in container
  docker exec $container bash -c "rm $db_path.backup"
}

# Create temporary directory for the backup
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# First, backup all configuration files from the host directory
echo "Backing up all configuration files from $HOST_DIR..."
# Find all non-hidden files excluding backups directory
find "$HOST_DIR" -type f -not -path "$BACKUP_DIR/*" -not -path "*/\.*" | while read -r file; do
  # Get relative path from host dir
  rel_path="${file#$HOST_DIR/}"
  # Create directory structure in temp dir
  mkdir -p "$TEMP_DIR/$(dirname "$rel_path")"
  # Copy file preserving path structure and permissions
  cp -p "$file" "$TEMP_DIR/$rel_path"
  echo "Backed up: $rel_path"
done

# Get list of all running containers
echo "Discovering running containers..."
containers=$(docker ps --format '{{.Names}}')

# Create a map of container names to their associated docker-compose service
declare -A container_services
echo "Identifying docker-compose services..."
# Try to find projects by looking for docker-compose files
compose_files=$(find "$HOST_DIR" -name "docker-compose.yml" -o -name "docker-compose.yaml")

# Process each docker-compose file
for compose_file in $compose_files; do
  compose_dir=$(dirname "$compose_file")
  rel_dir="${compose_dir#$HOST_DIR/}"
  
  # Get the project name from the directory
  project=$(basename "$compose_dir")
  echo "Found docker-compose project: $project in $rel_dir"
  
  # Get services for this compose project
  services=$(cd "$compose_dir" && docker-compose config --services 2>/dev/null || echo "")
  
  # Map container names to services
  for service in $services; do
    container_name="${project}_${service}_1"
    container_services["$container_name"]="$service"
    echo "Mapped container $container_name to service $service in project $project"
  done
done

# For each container, back up its volumes
for container in $containers; do
  # Check if we have info on this container
  service=${container_services[$container]:-unknown}
  
  echo "Processing container: $container (service: $service)"
  
  # Get volume info for this container
  volumes=$(docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}:{{.Destination}}{{println}}{{end}}{{end}}' "$container")
  
  if [ -z "$volumes" ]; then
    echo "No volumes found for container $container, skipping volume backup"
    continue
  fi
  
  # Check if this container has SQLite databases in its volumes
  for volume_info in $volumes; do
    volume_name="${volume_info%%:*}"
    volume_path="${volume_info#*:}"
    
    echo "Found volume: $volume_name mounted at $volume_path"
    
    # Check for SQLite databases in this volume
    sqlite_dbs=$(detect_sqlite_dbs "$container" "$volume_path")
    
    if [ -n "$sqlite_dbs" ]; then
      echo "Found SQLite databases in $container at $volume_path"
      echo "Stopping container $container for safe database backup"
      
      # Stop the container for consistent backup
      if [[ $service != "unknown" ]]; then
        # Use docker-compose to stop the service
        project=$(echo "$container" | cut -d '_' -f 1)
        service_dir=$(find "$HOST_DIR" -name "docker-compose.yml" -exec dirname {} \; | grep "/$project$" | head -1)
        
        if [ -n "$service_dir" ]; then
          echo "Stopping service $service with docker-compose in $service_dir"
          (cd "$service_dir" && docker-compose stop "$service")
        else
          echo "No docker-compose directory found for $project, using docker stop"
          docker stop "$container"
        fi
      else
        # Direct docker stop
        docker stop "$container"
      fi
      
      # Create volume backup dirs
      mkdir -p "$TEMP_DIR/volumes/$container"
      
      # Backup each discovered SQLite database
      for db in $sqlite_dbs; do
        backup_sqlite "$container" "$db" "$TEMP_DIR/volumes/$container"
      done
      
      # Restart the container
      if [[ $service != "unknown" ]]; then
        # Use docker-compose to restart the service
        if [ -n "$service_dir" ]; then
          echo "Starting service $service with docker-compose in $service_dir"
          (cd "$service_dir" && docker-compose start "$service")
        else
          echo "No docker-compose directory found for $project, using docker start"
          docker start "$container"
        fi
      else
        # Direct docker start
        docker start "$container"
      fi
      
      echo "Container $container restarted"
    else
      echo "No SQLite databases found in volume $volume_name, continuing with normal backup"
      
      # For volumes without SQLite DBs, backup directly using docker cp
      # Create directories in temp backup
      mkdir -p "$TEMP_DIR/volumes/$container/$volume_name"
      
      # Copy volume data
      echo "Copying volume data from $container:$volume_path to backup"
      # Docker cp doesn't preserve permissions by default, so we'll fix permissions after copying
      docker cp "$container:$volume_path/." "$TEMP_DIR/volumes/$container/$volume_name/"
      # Get and apply original permissions
      echo "Preserving original permissions for volume data"
      docker exec $container find $volume_path -type f -exec stat -c "%a" {} \; | while read -r perm; do
        find "$TEMP_DIR/volumes/$container/$volume_name" -type f -exec chmod $perm {} \;
      done
    fi
  done
done

# Special handling for files that might be locked (like acme.json)
echo "Checking for special files that might need retry logic..."
special_files=$(find "$HOST_DIR" -name "acme.json")

for special_file in $special_files; do
  rel_path="${special_file#$HOST_DIR/}"
  backup_path="$TEMP_DIR/$rel_path"
  
  echo "Using retry logic for special file: $rel_path"
  
  # Create directory for the file
  mkdir -p "$(dirname "$backup_path")"
  
  # Use retry mechanism with a short timeout
  MAX_RETRIES=5
  RETRY_COUNT=0
  BACKUP_SUCCESS=0
  
  while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ $BACKUP_SUCCESS -eq 0 ]; do
    if cp -p "$special_file" "$backup_path" 2>/dev/null; then
      BACKUP_SUCCESS=1
      echo "Successfully backed up $rel_path"
    else
      RETRY_COUNT=$((RETRY_COUNT+1))
      echo "Failed to backup $rel_path, attempt $RETRY_COUNT/$MAX_RETRIES"
      sleep 2
    fi
  done
  
  if [ $BACKUP_SUCCESS -eq 0 ]; then
    echo "WARNING: Could not backup $rel_path after $MAX_RETRIES attempts"
  fi
done

# Create archive with all backed up data - preserving permissions
echo "Creating backup archive..."
tar -czpf "$BACKUP_FILE" -C "$TEMP_DIR" .

# Set ownership to root:secrets
echo "Setting archive ownership to root:secrets..."
chown root:secrets "$BACKUP_FILE"
chmod 640 "$BACKUP_FILE"

# Verify the backup
echo "Verifying backup integrity..."
if tar -tzf "$BACKUP_FILE" > /dev/null; then
  echo "Backup verification successful"
else
  echo "ERROR: Backup verification failed"
  exit 1
fi

# Calculate backup size
BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)

# Cleanup old backups (keep last 12 backups)
echo "Cleaning up old backups..."
ls -t "$BACKUP_DIR"/docker-compose-backup-*.tar.gz 2>/dev/null | tail -n +13 | xargs -r rm
ls -t "$BACKUP_DIR"/backup-*.log 2>/dev/null | tail -n +13 | xargs -r rm

# Make sure old backups also have correct ownership
echo "Ensuring correct ownership of all backup files..."
find "$BACKUP_DIR" -name "docker-compose-backup-*.tar.gz" -exec chown root:secrets {} \; -exec chmod 640 {} \;

echo "Backup completed successfully at $(date)"
echo "Backup location: $BACKUP_FILE"
echo "Backup size: $BACKUP_SIZE"
