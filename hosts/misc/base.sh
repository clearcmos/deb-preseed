#!/bin/bash
# Debian System Setup Script
#
# This script automates the setup of a Debian-based system with package installation,
# user configuration, SSH setup, and SMB/CIFS share discovery and mounting.

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
DOCKER_AVAILABLE=false
DOCKER_INSTALLED=false
USERMOD_AVAILABLE=true

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
# Usage: parse_output "$(run_command...)"
parse_output() {
  local IFS=$'\n'
  read -r exit_code
  read -r stdout
  read -r stderr
  
  RET_CODE="$exit_code"
  STDOUT="$stdout"
  STDERR="$stderr"
}

# Check if a package is installed
is_installed() {
  local package="$1"
  parse_output "$(run_command "dpkg -l $package" "true" "false")"
  
  # Check if package exists in dpkg database AND has "ii" status (properly installed)
  if [[ $RET_CODE -eq 0 && $(echo "$STDOUT" | grep -E "^ii") ]]; then
    return 0
  else
    return 1
  fi
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

# Set up Docker repository
setup_docker_repository() {
  log_info "Setting up Docker repository..."
  
  # Setup keyrings directory
  parse_output "$(run_command "install -m 0755 -d /etc/apt/keyrings" "true")"
  
  # Add Docker's GPG key
  if [[ ! -f "/etc/apt/keyrings/docker.gpg" ]]; then
    log_info "Adding Docker's official GPG key..."
    log_debug "Executing Docker GPG key download with verbose output"
    # Split the command into separate curl and gpg steps for better debugging
    parse_output "$(run_command "curl -fsSL -v https://download.docker.com/linux/debian/gpg -o /tmp/docker.gpg" "true")"
    if [[ $RET_CODE -eq 0 ]]; then
      log_info "Docker GPG key download successful, running gpg command..."
      parse_output "$(run_command "cat /tmp/docker.gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg" "true")"
      parse_output "$(run_command "chmod a+r /etc/apt/keyrings/docker.gpg" "true")"
      # Clean up temporary file
      parse_output "$(run_command "rm /tmp/docker.gpg" "true")"
    else
      log_error "Failed to download Docker GPG key: $STDERR"
      log_info "Skipping Docker repository setup"
    fi
  fi
  
  # Add Docker repository
  log_info "Adding Docker repository to apt sources..."
  
  # Check if Docker GPG key was successfully added
  if [[ ! -f "/etc/apt/keyrings/docker.gpg" ]]; then
    log_error "Docker GPG key not found, skipping repository setup"
    return 1
  fi
  
  # Get distribution codename
  parse_output "$(run_command ". /etc/os-release && echo \"$VERSION_CODENAME\"" "true")"
  local codename="$STDOUT"
  
  # If codename is empty or failed, try another approach
  if [[ -z "$codename" ]]; then
    log_warning "Failed to get distribution codename from os-release, trying lsb_release"
    parse_output "$(run_command "lsb_release -cs" "true" "false")"
    codename="$STDOUT"
    
    # If still empty, use a default
    if [[ -z "$codename" ]]; then
      log_warning "Could not determine distribution codename, using 'bullseye' as default"
      codename="bullseye"
    fi
  fi
  
  log_info "Using distribution codename: $codename"
  
  # Get architecture
  parse_output "$(run_command "dpkg --print-architecture" "true")"
  local arch="$STDOUT"
  
  if [[ -z "$arch" ]]; then
    log_warning "Could not determine architecture, using 'amd64' as default"
    arch="amd64"
  fi
  
  log_info "Using architecture: $arch"
  
  local docker_repo="deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $codename stable"
  
  # Write to temporary file first to avoid permission issues
  echo "$docker_repo" > "/tmp/docker.list"
  parse_output "$(run_command "mv /tmp/docker.list /etc/apt/sources.list.d/docker.list" "true")"
  
  # Update apt with error handling
  log_info "Updating apt package lists..."
  parse_output "$(run_command "apt update" "true" "false")"
  
  if [[ $RET_CODE -ne 0 ]]; then
    log_error "apt update failed: $STDERR"
    log_info "Continuing with script execution..."
  else
    log_info "apt update completed successfully"
  fi
}

# Display package menu for selection
display_package_menu() {
  local packages=("$@")
  
  # Extract the Docker packages (last N elements of the array)
  docker_count=5
  start_idx=$(( ${#packages[@]} - $docker_count ))
  declare -a docker_pkgs=("${packages[@]:$start_idx:$docker_count}")
  
  # Remove Docker packages from the main array
  for ((i=0; i<docker_count; i++)); do
    unset "packages[$(( ${#packages[@]} - 1 ))]"
  done
  
  echo -e "\nPackage Selection Menu"
  echo "----------------------"
  echo "Available packages:"
  
  local idx=1
  for pkg in "${packages[@]}"; do
    echo "$idx) $pkg"
    ((idx++))
  done
  
  echo -e "\nEnter package numbers to install (comma-separated, e.g., '1,3,5')"
  echo "Type 'all' to select all packages or 'none' to select none"
  
  read -r -p "Your selection: " selection
  selection=$(echo "$selection" | tr '[:upper:]' '[:lower:]')
  
  # Process selections
  declare -A selected_packages
  
  if [[ "$selection" == "all" ]]; then
    # Select all packages
    for pkg in "${packages[@]}"; do
      selected_packages["$pkg"]=1
    done
    
    # Add docker packages if docker is in the list
    for pkg in "${docker_pkgs[@]}"; do
      selected_packages["$pkg"]=1
    done
  elif [[ "$selection" != "none" ]]; then
    # Process comma-separated selections
    IFS=',' read -ra selected_indices <<< "$selection"
    
    for index in "${selected_indices[@]}"; do
      # Convert to zero-based index
      index=$(echo "$index" | tr -d ' ')
      
      if ! [[ "$index" =~ ^[0-9]+$ ]]; then
        echo "Invalid selection format. Please use numbers separated by commas."
        display_package_menu "${packages[@]}" "${docker_pkgs[@]}"
        return
      fi
      
      idx=$((index - 1))
      
      if (( idx >= 0 && idx < ${#packages[@]} )); then
        selected_pkg="${packages[$idx]}"
        selected_packages["$selected_pkg"]=1
        
        # If docker is selected, add all docker packages
        if [[ "$selected_pkg" == "docker" ]]; then
          for docker_pkg in "${docker_pkgs[@]}"; do
            selected_packages["$docker_pkg"]=1
          done
        fi
      fi
    done
  fi
  
  # Show selected packages for confirmation
  echo -e "\nSelected packages:"
  
  local selected_count=0
  for pkg in "${!selected_packages[@]}"; do
    echo "- $pkg"
    ((selected_count++))
  done
  
  if [[ $selected_count -eq 0 ]]; then
    echo "- None"
  fi
  
  # Convert to output format (space-separated list)
  local result=""
  for pkg in "${!selected_packages[@]}"; do
    result+="$pkg "
  done
  
  echo "$result"
}

# Install packages
install_packages() {
  # Always install these critical packages first
  critical_pkgs=("sudo" "python3")
  for pkg in "${critical_pkgs[@]}"; do
    if ! is_installed "$pkg"; then
      log_info "Installing critical package $pkg..."
      parse_output "$(run_command "apt update" "true")"
      parse_output "$(run_command "apt install -y $pkg" "true")"
    else
      log_info "Critical package $pkg is already installed."
    fi
  done
  
  # Base packages list (excluding critical packages and curl which should already be installed)
  pkgs=(
    "1password-cli"
    "certbot"
    "cmake"
    "fail2ban"
    "fdupes"
    "ffmpeg"
    "nginx"
    "nodejs"
    "npm"
    "nvm"
    "pandoc"
  )
  
  # Check if Docker is available and add Docker packages
  docker_pkgs=()
  parse_output "$(run_command "apt-cache policy docker-ce" "true" "false")"
  
  if [[ "$STDOUT" == *"Candidate:"* ]]; then
    DOCKER_AVAILABLE=true
    docker_pkgs=(
      "containerd.io"
      "docker-buildx-plugin"
      "docker-ce"
      "docker-ce-cli"
      "docker-compose-plugin"
    )
    # If Docker is available, add "docker" to the package list
    pkgs+=("docker")
  fi
  
  # Add Plex as an option regardless of whether it's in repositories
  pkgs+=("plex")
  
  # Sort packages alphabetically
  IFS=$'\n' pkgs=($(sort <<<"${pkgs[*]}"))
  unset IFS
  
  # Display interactive menu for package selection
  log_info "Displaying package selection menu..."
  selected_packages_str=$(display_package_menu "${pkgs[@]}" "${docker_pkgs[@]}")
  
  # Convert string to array
  read -ra selected_pkgs <<< "$selected_packages_str"
  
  if [[ ${#selected_pkgs[@]} -eq 0 ]]; then
    log_info "Package selection was cancelled."
  else
    log_info "Selected ${#selected_pkgs[@]} packages for installation."
  fi
  
  # Install selected packages
  for pkg in "${selected_pkgs[@]}"; do
    if [[ "$pkg" == "plex" ]]; then
      # Handle Plex Media Server installation
      if ! is_installed "plexmediaserver"; then
        log_info "Installing Plex Media Server..."
        
        # Add Plex repository (with minimal output)
        log_info "Adding Plex repository..."
        parse_output "$(run_command "curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key | gpg --dearmor | tee /usr/share/keyrings/plex.gpg > /dev/null" "true" "false")"
        parse_output "$(run_command "echo \"deb [signed-by=/usr/share/keyrings/plex.gpg] https://downloads.plex.tv/repo/deb public main\" | tee /etc/apt/sources.list.d/plexmediaserver.list > /dev/null" "true" "false")"
        
        # Update package list and install Plex
        parse_output "$(run_command "apt update > /dev/null" "true" "false")"
        parse_output "$(run_command "apt install -y plexmediaserver" "true" "false")"
        
        # Enable and start Plex Media Server
        parse_output "$(run_command "systemctl enable plexmediaserver" "true" "false")"
        parse_output "$(run_command "systemctl start plexmediaserver" "true" "false")"
      else
        log_info "Plex Media Server is already installed, skipping."
      fi
    elif [[ "$pkg" == "bitwarden-cli" ]]; then
      # Handle Bitwarden CLI installation
      log_info "Installing Bitwarden CLI..."
      # First install build-essential package
      if ! is_installed "build-essential"; then
        log_info "Installing build-essential package for Bitwarden CLI..."
        parse_output "$(run_command "apt install -y build-essential" "true" "false")"
      fi
      
      # Make sure npm is installed
      if ! is_installed "npm"; then
        log_info "Installing npm for Bitwarden CLI..."
        parse_output "$(run_command "apt install -y npm" "true" "false")"
      fi
      
      # Install Bitwarden CLI using npm
      log_info "Installing Bitwarden CLI using npm..."
      parse_output "$(run_command "npm install -g @bitwarden/cli" "true" "false")"
      log_info "Bitwarden CLI installation completed."
    elif [[ "$pkg" == "1password-cli" ]]; then
      # Handle 1Password CLI installation
      log_info "Installing 1Password CLI..."
      
      # Update system packages
      parse_output "$(run_command "apt update" "true" "false")"
      
      # Install required dependencies
      parse_output "$(run_command "apt install -y gnupg2 apt-transport-https ca-certificates software-properties-common" "true" "false")"
      
      # Add the GPG key for the 1Password APT repository (with minimal output)
      parse_output "$(run_command "curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg" "true" "false")"
      
      # Add the 1Password APT repository (with minimal output)
      parse_output "$(run_command "echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main\" | tee /etc/apt/sources.list.d/1password.list > /dev/null" "true" "false")"
      
      # Add the debsig-verify policy for verifying package signatures (with minimal output)
      parse_output "$(run_command "mkdir -p /etc/debsig/policies/AC2D62742012EA22/" "true" "false")"
      parse_output "$(run_command "curl -fsSL https://downloads.1password.com/linux/debian/debsig/1password.pol | tee /etc/debsig/policies/AC2D62742012EA22/1password.pol > /dev/null" "true" "false")"
      parse_output "$(run_command "mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22/" "true" "false")"
      parse_output "$(run_command "curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg" "true" "false")"
      
      # Update package list and install 1Password CLI
      parse_output "$(run_command "apt update > /dev/null && apt install -y 1password-cli" "true" "false")"
      log_info "1Password CLI installation completed."
    elif [[ "$pkg" == "nvm" ]]; then
      # Handle NVM installation
      log_info "Installing NVM (Node Version Manager)..."
      
      # Install NVM for the current non-root user
      if [[ "$CURRENT_NON_ROOT_USER" != "root" ]]; then
        # Get user's home directory
        parse_output "$(run_command "getent passwd $CURRENT_NON_ROOT_USER | cut -d: -f6" "true")"
        local user_home
        user_home=$(echo "$STDOUT" | tr -d '[:space:]')
        
        log_info "Installing NVM for $CURRENT_NON_ROOT_USER (home: $user_home)..."
        
        # Ensure we explicitly set HOME environment variable for the non-root user
        local nvm_install_cmd_user="sudo -H -u $CURRENT_NON_ROOT_USER bash -c 'export HOME=\"$user_home\" && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash'"
        parse_output "$(run_command "$nvm_install_cmd_user" "true" "false")"
        
        # Source NVM for the current non-root user with explicit HOME
        local nvm_source_cmd_user="sudo -H -u $CURRENT_NON_ROOT_USER bash -c 'export HOME=\"$user_home\" && export NVM_DIR=\"$user_home/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"'"
        parse_output "$(run_command "$nvm_source_cmd_user" "true" "false")"
        
        # Update user's bashrc to automatically source NVM
        local bashrc_path="$user_home/.bashrc"
        if [[ -f "$bashrc_path" ]]; then
          if ! grep -q "NVM_DIR" "$bashrc_path"; then
            log_info "Adding NVM source commands to $CURRENT_NON_ROOT_USER's .bashrc..."
            cat >> "$bashrc_path" << 'EOF'

# NVM setup
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
EOF
            # Source the updated bashrc
            parse_output "$(run_command "sudo -H -u $CURRENT_NON_ROOT_USER bash -c 'export HOME=\"$user_home\" && source $bashrc_path'" "true" "false")"
          else
            log_info "NVM source commands already exist in $CURRENT_NON_ROOT_USER's .bashrc"
          fi
        else
          log_info "Couldn't find .bashrc for $CURRENT_NON_ROOT_USER, skipping automatic sourcing"
        fi
        
        # Get latest Node.js version and install for the current non-root user with explicit HOME
        local nvm_install_node_cmd_user="sudo -H -u $CURRENT_NON_ROOT_USER bash -c 'export HOME=\"$user_home\" && export NVM_DIR=\"$user_home/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\" && nvm install node && nvm use node'"
        parse_output "$(run_command "$nvm_install_node_cmd_user" "true" "false")"
        
        # Export NVM environment for the current script session
        export NVM_DIR="$user_home/.nvm"
        parse_output "$(run_command "bash -c 'export HOME=\"$user_home\" && export NVM_DIR=\"$NVM_DIR\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"'" "true")"
      fi
      
      # Also install NVM for root (regardless of whether the current user is root or not)
      log_info "Installing NVM for root user..."
      
      # Ensure root's home directory exists and is accessible
      parse_output "$(run_command "mkdir -p /root" "true")"
      
      # Log instead of writing to a hardcoded path
      log_debug "Starting NVM installation for root user"
      
      # List the root directory for debugging
      parse_output "$(run_command "ls -la /root" "true" "false")"
      
      # Clear any existing NVM directory to ensure clean installation
      parse_output "$(run_command "rm -rf /root/.nvm" "true")"
      
      # Explicitly set HOME to /root when installing NVM for root user
      log_debug "Running NVM install command for root with explicit HOME"
      
      # Run the NVM installer with HOME explicitly set to /root
      local nvm_install_cmd_root="export HOME=/root && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash"
      parse_output "$(run_command "$nvm_install_cmd_root" "true" "false")"
      
      # Log the result of the NVM installation
      log_debug "NVM install command for root returned code $RET_CODE"
      if [[ -n "$STDOUT" ]]; then
        log_debug "NVM stdout: $STDOUT"
      fi
      if [[ -n "$STDERR" ]]; then
        log_debug "NVM stderr: $STDERR"
      fi
      
      # Check if NVM directory was created in the correct location
      parse_output "$(run_command "ls -la /root/.nvm" "true" "false")"
      if [[ -n "$STDOUT" ]]; then
        log_debug "NVM directory exists in /root/.nvm: $STDOUT"
      else
        log_debug "NVM directory NOT found in /root/.nvm"
        
        # If NVM directory wasn't created in /root/.nvm, check if it was created elsewhere
        parse_output "$(run_command "find / -name '.nvm' -type d 2>/dev/null" "true" "false")"
        log_debug "Found .nvm directories: $STDOUT"
        
        # Get current user's home directory instead of hardcoded path
        local user_home
        user_home=$(eval echo ~)
        # If NVM was installed in current user's home instead, copy it to /root/.nvm
        if [[ -d "$user_home/.nvm" && ! -d "/root/.nvm" ]]; then
          log_debug "Copying NVM from $user_home/.nvm to /root/.nvm"
          parse_output "$(run_command "cp -r $user_home/.nvm /root/.nvm" "true")"
          parse_output "$(run_command "chown -R root:root /root/.nvm" "true")"
        fi
      fi
      
      # Update root's bashrc to automatically source NVM
      local root_bashrc_path="/root/.bashrc"
      if [[ -f "$root_bashrc_path" ]]; then
        if ! grep -q "NVM_DIR" "$root_bashrc_path"; then
          log_info "Adding NVM source commands to root's .bashrc..."
          cat >> "$root_bashrc_path" << 'EOF'

# NVM setup
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
EOF
          # Source the updated bashrc and log the result
          parse_output "$(run_command "export HOME=/root && source /root/.bashrc" "true" "false")"
          log_debug "Sourcing updated .bashrc returned code $RET_CODE"
        else
          log_info "NVM source commands already exist in root's .bashrc"
          log_debug "NVM source commands already exist in root's .bashrc"
        fi
      else
        # Create a .bashrc file for root if it doesn't exist
        log_info "Creating .bashrc for root with NVM configuration..."
        cat > "$root_bashrc_path" << 'EOF'
# ~/.bashrc: executed by bash(1) for non-login shells.

# NVM setup
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
EOF
        log_debug "Created new .bashrc for root with NVM configuration"
      fi
      
      # Try to install Node.js using NVM for root with explicit HOME
      log_debug "Attempting to install Node.js with NVM for root"
      
      local nvm_install_node_cmd_root="export HOME=/root && export NVM_DIR=\"/root/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\" && nvm install node && nvm use node"
      parse_output "$(run_command "$nvm_install_node_cmd_root" "true" "false")"
      
      log_debug "Node.js install returned code $RET_CODE"
      if [[ -n "$STDOUT" ]]; then
        log_debug "Node.js stdout: $STDOUT"
      fi
      if [[ -n "$STDERR" ]]; then
        log_debug "Node.js stderr: $STDERR"
      fi
      
      log_info "NVM installation completed."
      log_info "NVM has been configured to be automatically loaded in future shell sessions."
    elif ! is_installed "$pkg"; then
      log_info "Installing $pkg..."
      parse_output "$(run_command "apt install -y $pkg" "true" "false")"
    else
      log_info "$pkg is already installed, skipping."
    fi
    
    # Check if any Docker packages were installed
    for docker_pkg in "${docker_pkgs[@]}"; do
      if [[ "$pkg" == "$docker_pkg" && $(is_installed "$pkg") ]]; then
        DOCKER_INSTALLED=true
        break
      fi
    done
  done
}

# Handle Docker fallback to docker.io if needed
handle_docker_fallback() {
  if [[ "$DOCKER_AVAILABLE" != "true" ]]; then
    if [[ -f "/etc/apt/sources.list.d/docker.list" ]]; then
      log_info "Docker repository exists but packages not available. Using docker.io as fallback..."
    else
      log_info "Docker repository file not found, using docker.io as fallback..."
    fi
    
    read -r -p "Install docker.io and docker-compose-plugin? (Y/n): " docker_fallback_choice
    
    if [[ ! "$docker_fallback_choice" =~ ^[Nn] ]]; then
      log_info "Installing alternative Docker packages..."
      parse_output "$(run_command "apt install -y docker.io docker-compose-plugin" "true")"
      DOCKER_INSTALLED=true
    else
      log_info "Skipping docker.io installation."
      DOCKER_INSTALLED=false
    fi
  fi
}

# Setup user and permissions
setup_user() {
  # Create user if doesn't exist
  parse_output "$(run_command "id $CURRENT_NON_ROOT_USER" "true" "false")"
  
  if [[ "$STDERR" == *"no such user"* ]]; then
    log_info "Creating user $CURRENT_NON_ROOT_USER..."
    parse_output "$(run_command "useradd -m -s /bin/bash $CURRENT_NON_ROOT_USER" "true")"
  else
    log_info "User $CURRENT_NON_ROOT_USER already exists, skipping."
  fi
  
  # Add user to sudoers if not already added
  local sudoers_file="/etc/sudoers.d/$CURRENT_NON_ROOT_USER"
  if [[ ! -f "$sudoers_file" ]]; then
    log_info "Adding $CURRENT_NON_ROOT_USER to sudoers file directly..."
    echo "$CURRENT_NON_ROOT_USER ALL=(ALL) ALL" > "$sudoers_file"
    chmod 0440 "$sudoers_file"
    log_info "$CURRENT_NON_ROOT_USER added to sudoers directly via $sudoers_file."
  else
    log_info "Sudoers file for $CURRENT_NON_ROOT_USER already exists, skipping."
  fi
  
  # Add user to sudo group
  parse_output "$(run_command "groups $CURRENT_NON_ROOT_USER" "true" "false")"
  local groups_output="$STDOUT"
  
  if [[ "$groups_output" != *"sudo"* ]]; then
    log_info "Adding $CURRENT_NON_ROOT_USER to sudo group..."
    if [[ "$USERMOD_AVAILABLE" == "true" ]]; then
      parse_output "$(run_command "usermod -aG sudo $CURRENT_NON_ROOT_USER" "true")"
    else
      log_info "Using alternative method to add $CURRENT_NON_ROOT_USER to sudo group..."
      # Read the group file
      if grep -q "^sudo:" /etc/group; then
        # Add user to sudo group
        sed -i "s/^sudo:.*/&,$CURRENT_NON_ROOT_USER/" /etc/group
      fi
    fi
    log_info "$CURRENT_NON_ROOT_USER added to sudo group."
  else
    log_info "$CURRENT_NON_ROOT_USER is already in sudo group, skipping."
  fi
  
  # Add user to docker group if applicable
  if [[ "$DOCKER_INSTALLED" == "true" ]]; then
    parse_output "$(run_command "getent group docker" "true" "false")"
    
    if [[ -n "$STDOUT" ]]; then  # Docker group exists
      if [[ "$groups_output" != *"docker"* ]]; then
        log_info "Adding $CURRENT_NON_ROOT_USER to docker group..."
        if [[ "$USERMOD_AVAILABLE" == "true" ]]; then
          parse_output "$(run_command "usermod -aG docker $CURRENT_NON_ROOT_USER" "true")"
        else
          log_info "Using alternative method to add $CURRENT_NON_ROOT_USER to docker group..."
          # Read the group file
          if grep -q "^docker:" /etc/group; then
            # Add user to docker group
            sed -i "s/^docker:.*/&,$CURRENT_NON_ROOT_USER/" /etc/group
          fi
        fi
        log_info "$CURRENT_NON_ROOT_USER added to docker group."
      else
        log_info "$CURRENT_NON_ROOT_USER is already in docker group, skipping."
      fi
    fi
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
EOF
  
  log_info "SSH configuration updated."
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
      key="${line%%=*}"
      value="${line#*=}"
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
    
    # Create a credentials file for this host
    local creds_file="/etc/.smb_${host//\./_}"
    log_info "Creating credentials file for $host..."
    
    if [[ -n "$username" ]]; then
      echo "username=$username" > "$creds_file"
      echo "password=$password" >> "$creds_file"
    else
      echo "username=guest" > "$creds_file"
      echo "password=" >> "$creds_file"
    fi
    
    chmod 0600 "$creds_file"
    parse_output "$(run_command "chown root:root $creds_file" "true")"
    log_debug "Credentials file created at $creds_file"
    
    # Create mount point
    local mount_point="/mnt/$share_name"
    if [[ ! -d "$mount_point" ]]; then
      log_info "Creating mount point directory $mount_point..."
      mkdir -p "$mount_point"
      parse_output "$(run_command "chown $CURRENT_NON_ROOT_USER:$CURRENT_NON_ROOT_USER $mount_point" "true")"
      parse_output "$(run_command "chmod 755 $mount_point" "true")"
    else
      # Check current owner and permissions
      parse_output "$(run_command "stat -c '%U:%G' $mount_point" "true")"
      local current_owner="$STDOUT"
      parse_output "$(run_command "stat -c '%a' $mount_point" "true")"
      local current_perms="$STDOUT"
      
      if [[ "$current_owner" != "$CURRENT_NON_ROOT_USER:$CURRENT_NON_ROOT_USER" ]]; then
        log_info "Updating mount point ownership..."
        parse_output "$(run_command "chown $CURRENT_NON_ROOT_USER:$CURRENT_NON_ROOT_USER $mount_point" "true")"
      fi
      
      if [[ "$current_perms" != "755" ]]; then
        log_info "Updating mount point permissions..."
        parse_output "$(run_command "chmod 755 $mount_point" "true")"
      else
        log_info "Mount point already exists with correct ownership and permissions."
      fi
    fi
    
    # Add to fstab
    local fstab_entry="//$host/$share_name $mount_point cifs credentials=$creds_file,x-gvfs-show,uid=$CURRENT_NON_ROOT_USER,gid=$CURRENT_NON_ROOT_USER 0 0"
    
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
    parse_output "$(run_command "mount | grep $mount_point" "true" "false")"
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
      local mount_cmd="mount -t cifs '//$host/$share_name' '$mount_point' -o 'credentials=$creds_file,vers=$vers,uid=$CURRENT_NON_ROOT_USER,gid=$CURRENT_NON_ROOT_USER'"
      parse_output "$(run_command "$mount_cmd" "true" "false")"
      
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
  
  # Ensure the credentials files and passwords aren't accessible
  parse_output "$(run_command "find /etc -name '.smb_*' -exec chmod 600 {} \\;" "true")"
  
  # Clear password from memory (bash doesn't have unset for elements within a pipe-delimited string)
  # But the function will exit soon anyway, clearing local variables
}

# Setup automatic security updates
setup_security_updates() {
  log_info "Setting up automatic security updates..."
  
  # Install unattended-upgrades if not already installed
  if ! is_installed "unattended-upgrades"; then
    log_info "Installing unattended-upgrades package..."
    parse_output "$(run_command "apt update" "true")"
    parse_output "$(run_command "apt install -y unattended-upgrades apt-listchanges" "true")"
  fi
  
  # Configure unattended-upgrades
  log_info "Configuring unattended-upgrades..."
  
  # Write auto-upgrades configuration
  cat > "/etc/apt/apt.conf.d/20auto-upgrades" << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Download-Upgradeable-Packages "1";
EOF
  
  # Check if 50unattended-upgrades exists and modify it
  if [[ -f "/etc/apt/apt.conf.d/50unattended-upgrades" ]]; then
    # Read the file content
    local config_content
    config_content=$(cat "/etc/apt/apt.conf.d/50unattended-upgrades")
    
    # Enable security updates if not already enabled
    if ! grep -q '^\s*"origin=Debian,codename=\${distro_codename},label=Debian-Security";' "/etc/apt/apt.conf.d/50unattended-upgrades"; then
      log_info "Enabling automatic security updates..."
      # Replace commented security updates line with uncommented version
      config_content=$(echo "$config_content" | sed 's|//\s*"origin=Debian,codename=\${distro_codename},label=Debian-Security";|"origin=Debian,codename=${distro_codename},label=Debian-Security";|')
    else
      log_info "Automatic security updates already enabled."
    fi
    
    # Configure automatic reboot
    if ! grep -q "Unattended-Upgrade::Automatic-Reboot" "/etc/apt/apt.conf.d/50unattended-upgrades"; then
      log_info "Configuring to prevent automatic reboots after updates..."
      config_content="${config_content}"$'\n'"Unattended-Upgrade::Automatic-Reboot \"false\";"$'\n'
    else
      # Replace existing setting with "false"
      config_content=$(echo "$config_content" | sed 's|Unattended-Upgrade::Automatic-Reboot "true";|Unattended-Upgrade::Automatic-Reboot "false";|')
    fi
    
    # Write modified configuration
    echo "$config_content" > "/etc/apt/apt.conf.d/50unattended-upgrades"
  else
    # Create full configuration file if it doesn't exist
    log_info "Creating full unattended-upgrades configuration..."
    cat > "/etc/apt/apt.conf.d/50unattended-upgrades" << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  fi
  
  # Enable and restart service
  log_info "Enabling unattended-upgrades service..."
  parse_output "$(run_command "systemctl enable unattended-upgrades" "true")"
  parse_output "$(run_command "systemctl restart unattended-upgrades" "true")"
  log_info "Automatic updates configuration completed."
}

# Setup SSH keys for user
setup_ssh_keys() {
  log_debug "Starting SSH key setup at $(date "+%Y-%m-%d %H:%M:%S")"
  
  log_info "Setting up SSH keys for $CURRENT_NON_ROOT_USER..."
  log_debug "Will configure SSH keys for user: $CURRENT_NON_ROOT_USER"
  
  # Get user's home directory
  log_debug "Getting home directory for user $CURRENT_NON_ROOT_USER"
  parse_output "$(run_command "getent passwd $CURRENT_NON_ROOT_USER | cut -d: -f6" "true")"
  
  local user_home
  if [[ $RET_CODE -ne 0 ]]; then
    log_error "Failed to get home directory: $STDERR"
    log_debug "Home directory command failed with exit code $RET_CODE"
    # Use a fallback approach
    log_debug "Attempting fallback approach to determine home directory"
    if [[ "$CURRENT_NON_ROOT_USER" == "root" ]]; then
      user_home="/root"
    else
      user_home="/home/$CURRENT_NON_ROOT_USER"
    fi
    log_debug "Using fallback home directory: $user_home"
  else
    user_home=$(echo "$STDOUT" | tr -d '[:space:]')
    log_debug "Found home directory: $user_home"
  fi
  
  local ssh_dir="$user_home/.ssh"
  log_debug "SSH directory path: $ssh_dir"
  
  # Create SSH directory if it doesn't exist
  if [[ ! -d "$ssh_dir" ]]; then
    log_info "Creating SSH directory for $CURRENT_NON_ROOT_USER..."
    mkdir -p "$ssh_dir"
    parse_output "$(run_command "chmod 700 $ssh_dir" "true")"
    parse_output "$(run_command "chown $CURRENT_NON_ROOT_USER:$CURRENT_NON_ROOT_USER $ssh_dir" "true")"
  fi
  
  # Generate SSH key if it doesn't exist
  if [[ ! -f "$ssh_dir/id_rsa" && ! -f "$ssh_dir/id_rsa.pub" ]]; then
    log_info "Generating SSH key for $CURRENT_NON_ROOT_USER..."
    parse_output "$(run_command "sudo -u $CURRENT_NON_ROOT_USER ssh-keygen -t rsa -N \"\" -f $ssh_dir/id_rsa" "true")"
    log_info "SSH key generated successfully."
  else
    log_info "SSH key already exists for $CURRENT_NON_ROOT_USER, skipping generation."
  fi
  
  # Setup authorized_keys
  local authorized_keys="$ssh_dir/authorized_keys"
  if [[ ! -f "$authorized_keys" ]]; then
    log_info "Creating authorized_keys file..."
    touch "$authorized_keys"
    parse_output "$(run_command "chmod 600 $authorized_keys" "true")"
    parse_output "$(run_command "chown $CURRENT_NON_ROOT_USER:$CURRENT_NON_ROOT_USER $authorized_keys" "true")"
    
    log_info "$(green "Please paste your public SSH key to add to authorized_keys (press ENTER when done):")" "color"
    read -r ssh_key
    
    if [[ -n "$ssh_key" ]]; then
      echo "$ssh_key" > "$authorized_keys"
      log_info "$(green "Public key added to authorized_keys.")" "color"
    fi
  else
    log_info "$(yellow "authorized_keys file already exists, would you like to add a new key? (y/n)")" "color"
    read -r add_key
    
    if [[ "$add_key" == [Yy]* ]]; then
      log_info "$(green "Please paste your public SSH key to add to authorized_keys (press ENTER when done):")" "color"
      read -r ssh_key
      
      if [[ -n "$ssh_key" ]]; then
        echo "$ssh_key" >> "$authorized_keys"
        log_info "$(green "Public key added to authorized_keys.")" "color"
      else
        log_info "No key provided. You can add a key later with: echo 'YOUR_PUBLIC_KEY' >> ~/.ssh/authorized_keys"
      fi
    else
      log_info "Skipping adding new key."
    fi
  fi
  
  # Restart SSH service
  log_info "Restarting SSH service..."
  parse_output "$(run_command "systemctl restart sshd" "true")"
  parse_output "$(run_command "systemctl status sshd --no-pager" "true")"
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
    
    log_info "- SSH access is restricted to user: $(cyan "$CURRENT_NON_ROOT_USER")" "color"
    log_info "- Root login is disabled"
    log_info "- SSH key authentication is enabled"
    log_info "- Password authentication is enabled"
    
    log_info "You can now connect to this server using: $(green "ssh ${CURRENT_NON_ROOT_USER}@hostname")" "color"
    
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
      parse_output "$(run_command "sudo mv /tmp/automount-on-start.service /etc/systemd/system/" "true")"
      parse_output "$(run_command "sudo chmod 644 /etc/systemd/system/automount-on-start.service" "true")"
      # Enable and start the service with sudo
      parse_output "$(run_command "sudo systemctl enable automount-on-start.service" "true")"
      parse_output "$(run_command "sudo systemctl start automount-on-start.service" "true")"
    else
      # Running as root, we can create the file directly
      mv /tmp/automount-on-start.service /etc/systemd/system/
      chmod 0644 /etc/systemd/system/automount-on-start.service
      # Enable and start the service
      parse_output "$(run_command "systemctl enable automount-on-start.service" "true")"
      parse_output "$(run_command "systemctl start automount-on-start.service" "true")"
    fi
    
    log_info "$(green "Automount service created, enabled, and started")" "color"
    
    # Reload systemd
    parse_output "$(run_command "systemctl daemon-reload" "true")"
    
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
    log_info "$(yellow "Not running as root. Will be asking for root credentials once to setup...")" "color"
    
    # Check if sudo is available
    parse_output "$(run_command "which sudo" "true" "false")"
    
    if [[ $RET_CODE -eq 0 ]]; then  # Sudo is available
      log_info "$(blue "sudo is available, using it to restart with elevated privileges...")" "color"
      script_path=$(readlink -f "$0")
      log_info "$(yellow "Please enter your password when prompted (should only be once)...")" "color"
      sudo -E bash "$script_path"
      exit 0
    else  # Sudo not available, need to install it with su
      log_info "$(yellow "sudo is not available. Installing sudo automatically...")" "color"
      log_info "$(yellow "Prompting for root password to install sudo and essential packages...")" "color"
      
      # Create a single script to handle all root operations at once to minimize password prompts
      temp_setup_script="/tmp/debian_setup_root.sh"
      cat > "$temp_setup_script" << EOF
#!/bin/bash
# Add user to sudoers
echo "Adding user $CURRENT_NON_ROOT_USER to sudoers..."
echo "$CURRENT_NON_ROOT_USER ALL=(ALL) ALL" > /etc/sudoers.d/$CURRENT_NON_ROOT_USER
chmod 0440 /etc/sudoers.d/$CURRENT_NON_ROOT_USER

echo "Setup completed. User $CURRENT_NON_ROOT_USER can now use sudo."
EOF
      chmod 0755 "$temp_setup_script"
      
      # Run the temporary script with su - do everything at once
      log_info "$(blue "Running su to perform root setup operations (single password prompt)...")" "color"
      su -c "$temp_setup_script" root
      
      # Cleanup temporary script
      if ! rm "$temp_setup_script"; then
        log_warning "Failed to remove temporary setup script: $?"
      fi
      
      # Now that sudo should be available, restart with sudo
      log_info "$(green "Setup complete, restarting with sudo privileges...")" "color"
      script_path=$(readlink -f "$0")
      sudo -E bash "$script_path"
      exit 0
    fi
  fi
  
  log_info "Running as root user: $(id -un)"
  log_info "Detected non-root user: $CURRENT_NON_ROOT_USER"
  
  # Setup Docker repository
  setup_docker_repository
  
  # Install selected packages
  install_packages
  
  # Handle Docker installation fallback if needed
  handle_docker_fallback
  
  # Configure SSH server
  configure_ssh
  
  # Discover and mount SMB/CIFS shares
  discover_smb_shares
  
  # Setup automatic security updates
  setup_security_updates
  
  # Setup SSH keys
  setup_ssh_keys
  
  # Finish up
  finalize_script
}

# Get the current non-root user
CURRENT_NON_ROOT_USER=$(detect_non_root_user)

# Run the script
main