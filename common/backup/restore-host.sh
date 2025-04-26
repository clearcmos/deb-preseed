#!/bin/bash
set -e

# Dynamic Docker Volume Restore Script
# Restores docker volumes and configuration from backups created by backup-host.sh

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

# Source the preseed file which contains USERNAME variable
if [ -f /etc/secrets/.preseed ]; then
  source /etc/secrets/.preseed
fi

# Check if BACKUP_MOUNT is defined
if [ -z "$BACKUP_MOUNT" ]; then
  echo "ERROR: BACKUP_MOUNT environment variable is not defined."
  echo "This variable should be defined in /etc/secrets/.nas which is sourced in /etc/profile."
  echo "Please make sure the file exists and the variable is properly set."
  exit 1
fi

# Check if USERNAME is defined
if [ -z "$USERNAME" ]; then
  echo "ERROR: USERNAME environment variable is not defined."
  echo "This variable should be defined in /etc/secrets/.preseed which is sourced in /etc/profile."
  echo "Please make sure the file exists and the variable is properly set."
  exit 1
fi

# Check if BACKUP_PW is defined
if [ -z "$BACKUP_PW" ]; then
  echo "ERROR: BACKUP_PW environment variable is not defined."
  echo "This variable should be defined in /etc/secrets/.nas for backup decryption."
  echo "Please make sure the file exists and the variable is properly set."
  exit 1
fi

# Get hostname for dynamic restore
HOST=$(hostname)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(realpath "$SCRIPT_DIR/../..")"
HOST_DIR="$REPO_ROOT/hosts/$HOST"

# Configuration
BACKUP_DIR="$BACKUP_MOUNT"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Function to list available backups
list_backups() {
  echo "Available backups:"
  local backups=()
  mapfile -t backups < <(find "$BACKUP_DIR" -name "docker-compose-backup-*.tar.gz" -type f | sort -r)
  
  if [ ${#backups[@]} -eq 0 ]; then
    echo "No backups found in $BACKUP_DIR"
    exit 1
  fi
  
  for i in "${!backups[@]}"; do
    local backup="${backups[$i]}"
    local timestamp=$(basename "$backup" | sed 's/docker-compose-backup-\(.*\)\.tar\.gz/\1/')
    local size=$(du -h "$backup" | cut -f1)
    echo "[$i] $(date -d "${timestamp:0:10} ${timestamp:11:2}:${timestamp:13:2}" "+%Y-%m-%d %H:%M") ($size)"
  done
  
  echo
  read -p "Select backup to restore [0-$((${#backups[@]}-1))]: " selection
  
  if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -ge "${#backups[@]}" ]; then
    echo "Invalid selection. Exiting."
    exit 1
  fi
  
  echo "Selected backup: ${backups[$selection]}"
  BACKUP_FILE="${backups[$selection]}"
}

# Function to stop all running docker containers
stop_containers() {
  echo "Checking for running Docker containers..."
  local running_containers=$(docker ps -q)
  
  if [ -n "$running_containers" ]; then
    echo "Stopping all running Docker containers..."
    
    # Try to stop using docker-compose first
    echo "Looking for docker-compose projects..."
    local compose_files=$(find "$HOST_DIR" -name "docker-compose.yml" -o -name "docker-compose.yaml" 2>/dev/null || echo "")
    
    for compose_file in $compose_files; do
      local compose_dir=$(dirname "$compose_file")
      echo "Stopping services in $(basename "$compose_dir")..."
      (cd "$compose_dir" && docker-compose down) || true
    done
    
    # Check if there are still containers running
    running_containers=$(docker ps -q)
    if [ -n "$running_containers" ]; then
      echo "Some containers still running, stopping with docker stop..."
      docker stop $(docker ps -q)
    fi
    
    echo "All containers stopped."
  else
    echo "No containers are currently running."
  fi
}

# Function to extract and restore backup
restore_backup() {
  echo "Extracting and decrypting backup to temporary directory..."
  mkdir -p "$TEMP_DIR"
  
  # Decrypt backup with openssl and extract with tar in one operation
  openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 100000 -in "$BACKUP_FILE" -pass "pass:$BACKUP_PW" | tar -xzp -C "$TEMP_DIR"
  
  # Check if extraction was successful
  if [ $? -ne 0 ]; then
    echo "Error: Failed to decrypt and extract backup. Check if the password is correct."
    exit 1
  fi
  
  echo "Restoring configuration files..."
  # First, restore configuration files
  find "$TEMP_DIR" -type f -not -path "*/volumes/*" | while read -r file; do
    # Get relative path
    rel_path="${file#$TEMP_DIR/}"
    # Create target directory
    target_dir="$HOST_DIR/$(dirname "$rel_path")"
    mkdir -p "$target_dir"
    
    # Set target file path without creating backups
    target_file="$HOST_DIR/$rel_path"
    
    # Copy file preserving attributes
    cp -p "$file" "$target_file"
    echo "Restored: $rel_path"
  done
  
  echo "Restoring docker volumes..."
  # Now restore volumes
  if [ -d "$TEMP_DIR/volumes" ]; then
    for container_dir in "$TEMP_DIR/volumes"/*; do
      [ -d "$container_dir" ] || continue
      
      container_name=$(basename "$container_dir")
      echo "Processing backed up data for container: $container_name"
      
      # Loop through volumes in this container's backup
      for volume_dir in "$container_dir"/*; do
        [ -d "$volume_dir" ] || continue
        
        volume_name=$(basename "$volume_dir")
        echo "Restoring volume: $volume_name"
        
        # Check if this is SQLite database backup (has a different structure)
        if find "$volume_dir" -type f -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" > /dev/null 2>&1; then
          echo "Found SQLite database files, using direct path restore"
          
          # Restore SQLite DB files directly to their paths
          find "$volume_dir" -type f | while read -r db_file; do
            # Get relative path from volume directory
            db_rel_path="${db_file#$volume_dir/}"
            # Extract directory of the db file
            db_dir=$(dirname "$db_rel_path")
            
            echo "Restoring database file: $db_rel_path"
            
            # Create directory structure if needed
            project=$(echo "$container_name" | cut -d '_' -f 1 2>/dev/null || echo "unknown")
            service=$(echo "$container_name" | cut -d '_' -f 2 2>/dev/null || echo "unknown")
            
            # Try to determine the target volume path
            target_dir=""
            # Look for docker-compose files to find the service's volume configuration
            compose_files=$(find "$HOST_DIR" -name "docker-compose.yml" -o -name "docker-compose.yaml")
            for compose_file in $compose_files; do
              if grep -q "$volume_name" "$compose_file"; then
                project_dir=$(dirname "$compose_file")
                # Try to extract volume path from compose file
                volume_path=$(grep -A10 "$service:" "$compose_file" | grep -A10 "volumes:" | grep -o "/[^:]*" | head -1 2>/dev/null || echo "")
                if [ -n "$volume_path" ]; then
                  target_dir="$volume_path/$db_dir"
                  break
                fi
              fi
            done
            
            # If we couldn't find the target path, use a default path
            if [ -z "$target_dir" ]; then
              echo "Warning: Could not determine exact target path for $db_rel_path"
              # Use a reasonable default based on common docker volume mounts
              target_dir="/var/lib/docker/volumes/$volume_name/_data/$db_dir"
            fi
            
            # Create target directory and restore file
            mkdir -p "$target_dir"
            
            # Set target file path without creating backups
            target_file="$target_dir/$(basename "$db_rel_path")"
            
            cp -p "$db_file" "$target_file"
            echo "Restored database to $target_file"
          done
        else
          # For regular volumes, restore to docker volume path
          echo "Restoring regular volume data"
          
          # Try to find the docker volume path
          volume_path="/var/lib/docker/volumes/$volume_name/_data"
          if [ -d "$volume_path" ]; then
            echo "Found existing volume at $volume_path"
            
            # Skip backup of existing data
            
            # Clear existing data
            echo "Clearing existing data..."
            rm -rf "$volume_path"/* 2>/dev/null || true
            
            # Copy backup data
            echo "Copying backup data..."
            cp -rp "$volume_dir"/* "$volume_path/" 2>/dev/null || true
            echo "Restored volume data to $volume_path"
          else
            echo "Warning: Volume path $volume_path not found"
            
            # Try to create the volume if it doesn't exist
            echo "Creating volume $volume_name"
            docker volume create "$volume_name" >/dev/null 2>&1 || true
            
            # Retry after creating the volume
            volume_path="/var/lib/docker/volumes/$volume_name/_data"
            if [ -d "$volume_path" ]; then
              cp -rp "$volume_dir"/* "$volume_path/" 2>/dev/null || true
              echo "Restored volume data to $volume_path"
            else
              echo "Error: Could not restore volume $volume_name - path not found"
              echo "You may need to create the volume manually and then restore from $volume_dir"
            fi
          fi
        fi
      done
    done
  else
    echo "No volume data found in backup"
  fi
}

# Main execution
echo "Starting restore process at $(date)"
echo "Host: $HOST"
echo "Host directory: $HOST_DIR"

# Check if host directory exists
if [ ! -d "$HOST_DIR" ]; then
  echo "WARNING: Host directory $HOST_DIR does not exist!"
  echo "Creating host directory..."
  mkdir -p "$HOST_DIR"
fi

# List backups and let user select one
list_backups

echo
echo "WARNING: This restore process will OVERWRITE existing files and volumes!"
echo "All data in target locations will be replaced with backup data."
read -p "Are you sure you want to continue? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Restore cancelled."
  exit 0
fi

# Stop all running containers
stop_containers

# Restore from selected backup
restore_backup

echo "Restore completed successfully at $(date)"
echo "Restored from: $BACKUP_FILE"
echo ""
echo "NOTE: Docker containers were not restarted after restore."
echo "You may need to manually start services using docker-compose up -d in the respective directories."