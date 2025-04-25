#!/bin/bash

source /etc/profile

# Setup logging
LOG_FILE="ssh-server.log"
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

# Configure SSH server
configure_ssh() {
  log_info "Configuring SSH server..."
  log_debug "Starting SSH server configuration process"
  
  # Backup original config if not already backed up
  if [[ ! -f "/etc/ssh/sshd_config.bak" ]]; then
    if cp "/etc/ssh/sshd_config" "/etc/ssh/sshd_config.bak"; then
      log_info "Original sshd_config backed up to /etc/ssh/sshd_config.bak"
      log_debug "Backup created successfully at $(date "+%Y-%m-%d %H:%M:%S")"
    else
      log_error "Failed to create backup of sshd_config: $?"
      log_debug "Backup error details: $?"
    fi
  else
    log_debug "Backup file already exists, skipping backup creation"
  fi
  
  # Write standard SSH configuration
  log_info "Writing SSH configuration..."
  cat > "/etc/ssh/sshd_config" << EOF
Include /etc/ssh/sshd_config.d/*.conf
Port 22
Protocol 2
PermitRootLogin yes
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $CURRENT_NON_ROOT_USER root

# Restrict SSH access to LAN IPs
Match Address 192.168.1.0/24
  PermitRootLogin yes
  PubkeyAuthentication yes

Match Address *,!192.168.1.0/24
  DenyUsers *
EOF
  
  log_info "SSH configuration updated."
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
    log_info "$(blue "SSH has been configured with the following settings:")" "color"
    
    log_info "- SSH access is restricted to user: $(cyan "$CURRENT_NON_ROOT_USER and root")" "color"
    log_info "- Access is restricted to LAN IPs (192.168.1.0/24 network)"
    log_info "- Root login is enabled"
    log_info "- Password authentication is disabled"
    
    log_info "You can now connect to this server using: $(green "ssh ${CURRENT_NON_ROOT_USER}@hostname")" "color" 
    log_info "Or connect as root: $(green "ssh root@hostname")" "color"
    
    exit 0
  fi
}

# Main execution function
main() {
  # These messages still go to the log file with timestamps, but on console they are simplified
  log_info "Starting SSH server configuration script at $(date "+%Y-%m-%d %H:%M:%S")"
  log_info "$(blue "Setting up SSH server...")" "color"
  
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

  # Configure SSH server
  configure_ssh
  
  # Finish up
  finalize_script
}

# Get the current non-root user
CURRENT_NON_ROOT_USER=$(detect_non_root_user)

# Run the script
main
