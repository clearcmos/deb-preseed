#!/bin/bash

source /etc/profile

# Setup logging
LOG_FILE="base.log"
LOG_LEVEL="INFO" # Set to DEBUG for more detailed logging

# Make sure we can log right away
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Color formatting helpers
blue() {
  echo -e "\033[1;34m$1\033[0m"
}

green() {
  echo -e "\033[1;32m$1\033[0m"
}

red() {
  echo -e "\033[1;31m$1\033[0m"
}

yellow() {
  echo -e "\033[1;33m$1\033[0m"
}

cyan() {
  echo -e "\033[1;36m$1\033[0m"
}

magenta() {
  echo -e "\033[1;35m$1\033[0m"
}

# Logging functions
log_debug() {
  # Only write debug logs to file, not to console
  local timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo "$timestamp - DEBUG - $1" >> "$LOG_FILE"
}

log_info() {
  local timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  
  # For colored messages, preserve ANSI codes in console output
  if [[ "$2" == "color" ]]; then
    echo -e "$1"
  else
    echo "$1"
  fi
  
  # Always log full timestamp to file
  echo "$timestamp - INFO - $1" >> "$LOG_FILE"
}

log_warning() {
  local timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  
  if [[ "$2" == "color" ]]; then
    echo -e "$1"
  else
    echo "$1"
  fi
  
  echo "$timestamp - WARNING - $1" >> "$LOG_FILE"
}

log_error() {
  local timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  
  if [[ "$2" == "color" ]]; then
    echo -e "$1"
  else
    echo "$1"
  fi
  
  echo "$timestamp - ERROR - $1" >> "$LOG_FILE"
}

# Global variables
ERROR_FLAG=false
CURRENT_NON_ROOT_USER=""

# Run a command and log the output
run_command() {
  local command="$1"
  local shell="${2:-false}" # default to false
  local check="${3:-true}"  # default to true
  
  log_debug "Executing command: '$command', shell=$shell, check=$check"
  
  # Track execution time
  local start_time
  start_time=$(date +%s.%N)
  
  local exit_code=0
  local stdout
  local stderr
  
  # Execute the command
  if [[ "$shell" == "true" ]]; then
    # Run with shell interpretation
    output_file=$(mktemp)
    error_file=$(mktemp)
    
    bash -c "$command" > "$output_file" 2> "$error_file" || exit_code=$?
    
    stdout=$(cat "$output_file")
    stderr=$(cat "$error_file")
    
    rm -f "$output_file" "$error_file"
  else
    # Run without shell interpretation (convert to array)
    read -ra cmd_array <<< "$command"
    
    output_file=$(mktemp)
    error_file=$(mktemp)
    
    "${cmd_array[@]}" > "$output_file" 2> "$error_file" || exit_code=$?
    
    stdout=$(cat "$output_file")
    stderr=$(cat "$error_file")
    
    rm -f "$output_file" "$error_file"
  fi
  
  # Calculate execution time
  local end_time
  end_time=$(date +%s.%N)
  local execution_time
  execution_time=$(echo "$end_time - $start_time" | bc)
  
  log_debug "Command execution completed in ${execution_time} seconds with return code $exit_code"
  
  # Log stdout/stderr at debug level (truncated if too long)
  if [[ -n "$stdout" ]]; then
    local log_stdout
    if (( ${#stdout} > 500 )); then
      log_stdout="${stdout:0:500}... [truncated]"
    else
      log_stdout="$stdout"
    fi
    log_debug "Command stdout: $log_stdout"
  fi
  
  if [[ -n "$stderr" ]]; then
    local log_stderr
    if (( ${#stderr} > 500 )); then
      log_stderr="${stderr:0:500}... [truncated]"
    else
      log_stderr="$stderr"
    fi
    log_debug "Command stderr: $log_stderr"
  fi
  
  # Handle errors if check is true
  if [[ "$check" == "true" && $exit_code -ne 0 ]]; then
    log_error "Command failed: $command"
    log_error "Error: $stderr"
    log_debug "Failed command details - return code: $exit_code, execution time: $execution_time"
  fi
  
  # Return the results
  echo "$exit_code"
  echo "$stdout"
  echo "$stderr"
}

# Function to parse output from run_command
# Usage: parse_output $(run_command...) - without quotes!
parse_output() {
  # We need to handle the input as separate arguments, not as a single string
  RET_CODE="$1"
  STDOUT="$2"
  STDERR="$3"
}

# Detect the correct non-root user
detect_non_root_user() {
  if [[ $EUID -eq 0 ]]; then
    # Running as root, determine the actual user
    if [[ -n "$SUDO_USER" && "$SUDO_USER" != "root" ]]; then
      echo "$SUDO_USER"
      return
    elif [[ -n "$LOGNAME" && "$LOGNAME" != "root" ]]; then
      echo "$LOGNAME"
      return
    else
      log_info "Running as root, please enter the name of the non-root user:"
      read -r user_input
      
      if [[ -z "$user_input" || "$user_input" == "root" ]]; then
        log_info "Invalid username. Defaulting to the first non-system user with a home directory..."
        # Find first non-system user with a home directory
        while IFS=':' read -r username _ uid _ _ home _; do
          if [[ "$username" != "root" && "$username" != "nobody" && "$username" != "systemd" && "$home" == /home/* ]]; then
            log_info "Using detected user '$username'"
            echo "$username"
            return
          fi
        done < /etc/passwd
        
        # Default if no valid user found
        log_info "No valid user found. Using default user 'standard'"
        echo "standard"
      else
        echo "$user_input"
      fi
    fi
  else
    # Running as non-root
    echo "$USER"
  fi
}


# Configure and mount SMB/CIFS shares
discover_smb_shares() {
  log_info "Setting up SMB/CIFS shares from configuration..."
  log_debug "SMB setup initiated at $(date "+%Y-%m-%d %H:%M:%S")"
  
  # Define the path to the SMB environment file
  local script_dir
  script_dir=$(dirname "$(readlink -f "$0")")
  local root_dir
  root_dir=$(dirname "$(dirname "$script_dir")")
  local smb_env_path="/etc/secrets/.smb"
  
  # Check if the SMB env file exists
  if [[ ! -f "$smb_env_path" ]]; then
    log_info "SMB environment file not found at $smb_env_path, creating template..."
    mkdir -p "$(dirname "$smb_env_path")"
    
    # Create a template .smb file using the current format
    cat > "$smb_env_path" << 'EOF'
# SMB/CIFS shares configuration

# SMB Host 1
SMB_HOST_1=server1.home.arpa
SMB_HOST_1_USER=myuser
SMB_HOST_1_PW=mypassword
SMB_HOST_1_SHARE_1=share1
SMB_HOST_1_SHARE_2=share2

# SMB Host 2
SMB_HOST_2=server2.home.arpa
SMB_HOST_2_USER=otheruser
SMB_HOST_2_PW=otherpassword
SMB_HOST_2_SHARE_1=othershare
EOF
    # Set proper permissions to match other files in /etc/secrets
    chmod 0640 "$smb_env_path"
    
    # Create secrets group if it doesn't exist
    parse_output $(run_command "getent group secrets" "true" "false")
    if [[ $RET_CODE -ne 0 ]]; then
      log_info "Creating 'secrets' group..."
      parse_output $(run_command "groupadd secrets" "true")
    fi
    
    parse_output $(run_command "chown root:secrets $smb_env_path" "true")
    log_info "Template created. Please edit $smb_env_path with your share information and re-run the script."
    return
  fi
  
  # Read the configuration file
  declare -A env_vars
  declare -a hosts
  
  log_debug "Reading SMB configuration from $smb_env_path"
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments
    if [[ -z "$line" || "$line" == \#* ]]; then
      continue
    fi
    
    # Parse the environment variable format
    if [[ "$line" == *"="* ]]; then
      # Remove export keyword if present
      cleaned_line="${line#export }"
      
      key="${cleaned_line%%=*}"
      value="${cleaned_line#*=}"
      key=$(echo "$key" | xargs)  # Trim whitespace
      value=$(echo "$value" | xargs)  # Trim whitespace
      env_vars["$key"]="$value"
      
      # Detect host entries
      if [[ "$key" == SMB_HOST_* && "$key" != *_USER && "$key" != *_PW && "$key" != *_SHARE_* ]]; then
        host_num="${key#SMB_HOST_}"
        if [[ ! " ${hosts[*]} " =~ " ${host_num} " ]]; then
          hosts+=("$host_num")
        fi
      fi
    fi
  done < "$smb_env_path"
  
  # Process each host and its shares
  declare -a shares_config
  
  for host_num in "${hosts[@]}"; do
    local host="${env_vars[SMB_HOST_$host_num]}"
    local username="${env_vars[SMB_HOST_${host_num}_USER]}"
    local password="${env_vars[SMB_HOST_${host_num}_PW]}"
    
    if [[ -z "$host" || -z "$username" || -z "$password" ]]; then
      log_warning "Missing required configuration for SMB_HOST_$host_num"
      continue
    fi
    
    # Find all shares for this host
    local share_count=1
    while true; do
      local share_key="SMB_HOST_${host_num}_SHARE_${share_count}"
      if [[ -z "${env_vars[$share_key]}" ]]; then
        break
      fi
      
      local share_name="${env_vars[$share_key]}"
      shares_config+=("$host|$host|$share_name|$username|$password")
      ((share_count++))
    done
  done
  
  if [[ ${#shares_config[@]} -eq 0 ]]; then
    log_info "No SMB shares configured in the environment file."
    log_info "Please edit $smb_env_path with your share information and re-run the script."
    return
  fi
  
  # Process each configured share
  local mount_successful=false
  
  for config in "${shares_config[@]}"; do
    IFS='|' read -r host host_name share_name username password <<< "$config"
    
    log_info "$(green "Processing share '${share_name}' on ${host} (${host_name})")" "color"
    
    # Create mount point
    local mount_point="/mnt/$share_name"
    if [[ ! -d "$mount_point" ]]; then
      log_info "Creating mount point directory $mount_point..."
      mkdir -p "$mount_point"
      parse_output $(run_command "chown $CURRENT_NON_ROOT_USER:$CURRENT_NON_ROOT_USER $mount_point" "true")
      parse_output $(run_command "chmod 755 $mount_point" "true")
    else
      # Check current owner and permissions
      parse_output $(run_command "stat -c '%U:%G' $mount_point" "true")
      local current_owner="$STDOUT"
      parse_output $(run_command "stat -c '%a' $mount_point" "true")
      local current_perms="$STDOUT"
      
      if [[ "$current_owner" != "$CURRENT_NON_ROOT_USER:$CURRENT_NON_ROOT_USER" ]]; then
        log_info "Updating mount point ownership..."
        parse_output $(run_command "chown $CURRENT_NON_ROOT_USER:$CURRENT_NON_ROOT_USER $mount_point" "true")
      fi
      
      if [[ "$current_perms" != "755" ]]; then
        log_info "Updating mount point permissions..."
        parse_output $(run_command "chmod 755 $mount_point" "true")
      else
        log_info "Mount point already exists with correct ownership and permissions."
      fi
    fi
    
    # Create a per-share credentials file
    local creds_file="/etc/.smb_${host//\./_}"
    log_info "Creating credentials file for ${host}..."
    echo "username=$username" > "$creds_file"
    echo "password=$password" >> "$creds_file"
    chmod 0640 "$creds_file"
    parse_output $(run_command "chown root:secrets $creds_file" "true")
    log_debug "Credentials file created at $creds_file with root:secrets ownership"
    
    # Add to fstab with credentials pointing to the per-share credentials file
    local fstab_entry="//$host/$share_name $mount_point cifs credentials=$creds_file,iocharset=utf8,file_mode=0777,dir_mode=0777,x-gvfs-show,uid=$CURRENT_NON_ROOT_USER,gid=$CURRENT_NON_ROOT_USER 0 0"
    
    # Check if entry already exists
    if grep -q "//$host/$share_name $mount_point" /etc/fstab; then
      # Check if it needs updating
      if ! grep -q "^$fstab_entry$" /etc/fstab; then
        log_info "Updating existing CIFS mount entry in fstab..."
        # Replace the existing line
        sed -i "s|^.*//$host/$share_name $mount_point.*$|$fstab_entry|" /etc/fstab
      else
        log_info "CIFS mount entry already exists in fstab."
      fi
    else
      log_info "Adding CIFS mount to fstab..."
      echo "$fstab_entry" >> /etc/fstab
      log_info "CIFS mount entry added to fstab."
    fi
    
    # Check if already mounted
    parse_output $(run_command "mount | grep $mount_point" "true" "false")
    if [[ "$STDOUT" == *"$mount_point"* ]]; then
      log_info "$(green "Filesystem is already mounted.")" "color"
      share_mount_success=true
      mount_successful=true
      continue
    fi
    
    # Try to mount
    local share_mount_success=false
    log_info "$(blue "Attempting to mount ${share_name}...")" "color"
    
    # Try with explicit SMB versions
    for vers in "3.0" "2.0" "1.0"; do
      local mount_cmd="mount -t cifs '//$host/$share_name' '$mount_point' -o 'credentials=$creds_file,vers=$vers,iocharset=utf8,file_mode=0777,dir_mode=0777,uid=$CURRENT_NON_ROOT_USER,gid=$CURRENT_NON_ROOT_USER'"
      parse_output $(run_command "$mount_cmd" "true" "false")
      
      # Add detailed debugging info at debug level
      log_debug "Mount attempt with SMB v$vers: Return code $RET_CODE"
      if [[ -n "$STDERR" ]]; then
        log_debug "Mount error: $STDERR"
      fi
      if [[ -n "$STDOUT" ]]; then
        log_debug "Mount output: $STDOUT"
      fi
      
      if [[ $RET_CODE -eq 0 ]]; then
        log_info "$(green "Mount of ${share_name} successful with SMB v${vers}!")" "color"
        share_mount_success=true
        mount_successful=true
        break
      fi
    done
    
    if [[ "$share_mount_success" != "true" ]]; then
      log_error "$(red "WARNING: Failed to mount ${share_name}")" "color"
      log_error "$(yellow "Please check your configuration, network connectivity, and credentials.")" "color"
      log_error "$(yellow "You can manually mount the share later using: sudo mount ${mount_point}")" "color"
      log_error "$(yellow "The share will be automatically mounted at system startup due to the automount service.")" "color"
    fi
  done
  
  # Report overall status
  if [[ "$mount_successful" == "true" ]]; then
    log_info "$(green "Successfully mounted one or more SMB shares.")" "color"
  else
    log_warning "$(yellow "Failed to mount any SMB shares. They will be attempted at system startup.")" "color"
  fi
  
  # Ensure the credentials files and passwords have proper permissions
  log_debug "Setting secure permissions on credential files"
  parse_output $(run_command "find /etc -name '.smb_*' -exec chmod 0640 {} \\;" "true" "false")
  parse_output $(run_command "find /etc -name '.smb_*' -exec chown root:secrets {} \\;" "true" "false")
  
  # Note: Function will exit soon, clearing local variables automatically
}

# Final steps and summary
finalize_script() {
  log_info "----------------------------------------"
  log_info "Script completed at $(date "+%Y-%m-%d %H:%M:%S")"
  
  if [[ "$ERROR_FLAG" == "true" ]]; then
    log_error "$(red "ERROR: There were errors during script execution.")" "color"
    log_error "Please check the log file at $LOG_FILE for details."
    exit 1
  else
    log_info "$(green "SUCCESS: Script completed without errors.")" "color"
    log_info "Log file is available at $LOG_FILE"
    log_info ""
    log_info ""
    
    # Create automount service for network shares
    log_info "Creating automount service for network shares..."
    cat > /tmp/automount-on-start.service << 'EOF'
[Unit]
Description=Dynamically check network mounts and automount on start
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/bin/sleep 15
ExecStart=/bin/bash -c 'hosts=$(grep -E "^[^#].*cifs|nfs" /etc/fstab | grep -oP "//\\K[^/]+" | sort -u); for host in $hosts; do for i in {1..10}; do ping -c 1 $host && break || (echo "Waiting for $host..." && sleep 3); done; done; mount -a'
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    
    # Make sure we have appropriate permissions to create the service file
    if [[ $EUID -ne 0 ]]; then
      log_info "$(yellow "Creating systemd service requires root privileges. Attempting with sudo...")" "color"
      # Use sudo to move it to the right location
      parse_output $(run_command "sudo mv /tmp/automount-on-start.service /etc/systemd/system/" "true")
      parse_output $(run_command "sudo chmod 644 /etc/systemd/system/automount-on-start.service" "true")
      # Enable and start the service with sudo
      parse_output $(run_command "sudo systemctl enable automount-on-start.service" "true")
      parse_output $(run_command "sudo systemctl start automount-on-start.service" "true")
    else
      # Running as root, we can create the file directly
      mv /tmp/automount-on-start.service /etc/systemd/system/
      chmod 0644 /etc/systemd/system/automount-on-start.service
      # Enable and start the service
      parse_output $(run_command "systemctl enable automount-on-start.service" "true")
      parse_output $(run_command "systemctl start automount-on-start.service" "true")
    fi
    
    log_info "$(green "Automount service created, enabled, and started")" "color"
    
    # Reload systemd
    parse_output $(run_command "systemctl daemon-reload" "true")
    
    exit 0
  fi
}

# Main execution function
main() {
  # These messages still go to the log file with timestamps, but on console they are simplified
  log_info "Starting debian-base script at $(date "+%Y-%m-%d %H:%M:%S")"
  log_info "$(blue "Starting system setup...")" "color"
  
  if [[ $EUID -ne 0 ]]; then
    # Not running as root
    log_info "$(yellow "Not running as root. Elevated privileges required...")" "color"
    
    # Check if sudo is available
    parse_output $(run_command "which sudo" "true" "false")
    
    if [[ $RET_CODE -eq 0 ]]; then  # Sudo is available
      log_info "$(blue "sudo is available, using it to restart with elevated privileges...")" "color"
      script_path=$(readlink -f "$0")
      log_info "$(yellow "Please enter your password when prompted (should only be once)...")" "color"
      sudo -E bash "$script_path"
      exit 0
    else  # Sudo not available, need root directly
      log_info "$(yellow "sudo is not available. You need to run this script as root.")" "color"
      log_info "$(yellow "Please run 'su -' to become root, then run this script again.")" "color"
      exit 1
    fi
  fi
  
  log_info "Running as root user: $(id -un)"
  log_info "Detected non-root user: $CURRENT_NON_ROOT_USER"

  # Discover and mount SMB/CIFS shares
  discover_smb_shares
  
  # Finish up
  finalize_script
}

# Get the current non-root user
CURRENT_NON_ROOT_USER=$(detect_non_root_user)

# Run the script
main
