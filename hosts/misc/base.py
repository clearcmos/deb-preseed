#!/usr/bin/env python3
"""
Debian System Setup Script

This script automates the setup of a Debian-based system with package installation,
user configuration, SSH setup, and SMB/CIFS share discovery and mounting.
"""

import os
import sys
import re
import subprocess
import getpass
import socket
import datetime
import shutil
import ipaddress
import py_compile
import logging
import curses
from typing import List, Dict, Tuple, Optional, Union, Set

# Setup logging
LOG_FILE = "base.log"

# Custom formatter that doesn't show timestamp and level for console output
class CustomFormatter(logging.Formatter):
    def format(self, record):
        if isinstance(record.args, dict) and record.args.get('color', False):
            # For messages marked with color=True, keep the ANSI color codes
            return record.getMessage()
        return record.getMessage()

# Standard formatter for file logs (with timestamps)
file_formatter = logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")
console_formatter = CustomFormatter()

# Set up handlers
file_handler = logging.FileHandler(LOG_FILE)
file_handler.setFormatter(file_formatter)

console_handler = logging.StreamHandler(sys.stdout)
console_handler.setFormatter(console_formatter)

# Configure logger
logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)  # Change to DEBUG for more detailed logging
file_handler.setLevel(logging.DEBUG)  # Make sure file handler captures all debug messages
console_handler.setLevel(logging.INFO)  # Keep console output at INFO level to avoid overwhelming the user
logger.addHandler(file_handler)
logger.addHandler(console_handler)

# Color formatting helpers
def blue(text):
    return f"\033[1;34m{text}\033[0m"

def green(text):
    return f"\033[1;32m{text}\033[0m"

def red(text):
    return f"\033[1;31m{text}\033[0m"

def yellow(text):
    return f"\033[1;33m{text}\033[0m"

def cyan(text):
    return f"\033[1;36m{text}\033[0m"

def magenta(text):
    return f"\033[1;35m{text}\033[0m"

# Create a filter to deduplicate SMB 'Available shares:' messages
class DuplicateFilter(logging.Filter):
    def __init__(self):
        super().__init__()
        self.last_log = {}

    def filter(self, record):
        # Skip filtering for debug and error messages
        if record.levelno == logging.DEBUG or record.levelno == logging.ERROR:
            return True

        # Check if message contains duplicate strings we want to filter
        msg = record.getMessage()
        if "Available shares:" in msg:
            return False
        return True

# Add the filter to the logger
logger.addFilter(DuplicateFilter())

# Set the logging level for packages and modules that might be overly verbose
logging.getLogger("smbclient").setLevel(logging.WARNING)
logging.getLogger("paramiko").setLevel(logging.WARNING)
logging.getLogger("urllib3").setLevel(logging.WARNING)

class DebianSetup:
    def __init__(self):
        self.error_flag = False
        # Get the non-root user
        self.current_non_root_user = self.detect_non_root_user()
        self.docker_available = False
        self.docker_installed = False
        self.usermod_available = True

    def run(self):
        """Main execution function"""
        try:
            # These messages still go to the log file with timestamps, but on console they are simplified
            logger.info(f"Starting debian-base script at {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
            logger.info(f"{blue('Starting system setup...')}", {'color': True})

            if os.geteuid() != 0:
                # Not running as root
                logger.info(f"{yellow('Not running as root. Will be asking for root credentials once to setup...')}", {'color': True})

                # Check if sudo is available
                ret_code, _, _ = self.run_command("which sudo", shell=True, check=False)

                if (ret_code == 0):  # Sudo is available
                    logger.info(f"{blue('sudo is available, using it to restart with elevated privileges...')}", {'color': True})
                    script_path = os.path.abspath(__file__)
                    logger.info(f"{yellow('Please enter your password when prompted (should only be once)...')}", {'color': True})
                    os.system(f"sudo -E python3 {script_path}")  # -E preserves environment variables
                    sys.exit(0)
                else:  # Sudo not available, need to install it with su
                    logger.info(f"{yellow('sudo is not available. Installing sudo automatically...')}", {'color': True})
                    logger.info(f"{yellow('Prompting for root password to install sudo and essential packages...')}", {'color': True})

                    # Create a single script to handle all root operations at once to minimize password prompts
                    temp_setup_script = "/tmp/debian_setup_root.sh"
                    with open(temp_setup_script, "w") as f:
                        f.write(f"""#!/bin/bash
# Add user to sudoers
echo "Adding user {self.current_non_root_user} to sudoers..."
echo "{self.current_non_root_user} ALL=(ALL) ALL" > /etc/sudoers.d/{self.current_non_root_user}
chmod 0440 /etc/sudoers.d/{self.current_non_root_user}

echo "Setup completed. User {self.current_non_root_user} can now use sudo."
""")
                    os.chmod(temp_setup_script, 0o755)

                    # Run the temporary script with su - do everything at once
                    logger.info(f"{blue('Running su to perform root setup operations (single password prompt)...')}", {'color': True})
                    os.system(f"su -c '{temp_setup_script}' root")

                    # Cleanup temporary script
                    try:
                        os.remove(temp_setup_script)
                    except Exception as e:
                        logger.warning(f"Failed to remove temporary setup script: {str(e)}")

                    # Now that sudo should be available, restart with sudo
                    logger.info(f"{green('Setup complete, restarting with sudo privileges...')}", {'color': True})
                    script_path = os.path.abspath(__file__)
                    os.system(f"sudo -E python3 {script_path}")  # -E preserves environment variables
                    sys.exit(0)

            logger.info(f"Running as root user: {getpass.getuser()}")
            logger.info(f"Detected non-root user: {self.current_non_root_user}")

            # Setup Docker repository
            self.setup_docker_repository()

            # Install selected packages
            self.install_packages()

            # Handle Docker installation fallback if needed
            self.handle_docker_fallback()

            # Configure SSH server
            self.configure_ssh()

            # Discover and mount SMB/CIFS shares
            self.discover_smb_shares()

            # Setup automatic security updates
            self.setup_security_updates()

            # Finish up
            self.finalize_script()

        except Exception as e:
            self.error_flag = True
            logger.error(f"Error in main execution: {str(e)}", exc_info=True)
            sys.exit(1)

    def detect_non_root_user(self) -> str:
        """Detect the correct non-root user"""
        if os.geteuid() == 0:
            # Running as root, determine the actual user
            sudo_user = os.environ.get("SUDO_USER")
            logname = os.environ.get("LOGNAME")

            if sudo_user and sudo_user != "root":
                return sudo_user
            elif logname and logname != "root":
                return logname
            else:
                logger.info("Running as root, please enter the name of the non-root user:")
                user_input = input()

                if not user_input or user_input == "root":
                    logger.info("Invalid username. Defaulting to the first non-system user with a home directory...")
                    # Find first non-system user with a home directory
                    try:
                        with open('/etc/passwd', 'r') as f:
                            for line in f:
                                parts = line.strip().split(':')
                                if len(parts) >= 6:
                                    username, _, _, _, _, home = parts[:6]
                                    if (username not in ["root", "nobody", "systemd"] and
                                       "/home" in home):
                                        logger.info(f"Using detected user '{username}'")
                                        return username
                    except Exception as e:
                        logger.error(f"Error reading /etc/passwd: {str(e)}")

                    # Default if no valid user found
                    logger.info("No valid user found. Using default user 'standard'")
                    return "standard"
                return user_input
        else:
            # Running as non-root
            return getpass.getuser()

    def run_command(self, command: Union[str, List[str]],
                   shell: bool = False,
                   check: bool = True) -> Tuple[int, str, str]:
        """Run a command and return return code, stdout, and stderr"""
        cmd_str = command if isinstance(command, str) else " ".join(command)
        logger.debug(f"Executing command: '{cmd_str}', shell={shell}, check={check}")

        if isinstance(command, str) and not shell:
            command = command.split()
            logger.debug(f"Split command into: {command}")

        try:
            start_time = datetime.datetime.now()
            logger.debug(f"Command execution started at {start_time.strftime('%Y-%m-%d %H:%M:%S.%f')}")

            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                shell=shell
            )
            stdout, stderr = process.communicate()
            returncode = process.returncode

            end_time = datetime.datetime.now()
            execution_time = (end_time - start_time).total_seconds()
            logger.debug(f"Command execution completed in {execution_time:.4f} seconds with return code {returncode}")

            # Log stdout/stderr at debug level (truncated if too long)
            if stdout:
                log_stdout = (stdout[:500] + '... [truncated]') if len(stdout) > 500 else stdout
                logger.debug(f"Command stdout: {log_stdout}")
            if stderr:
                log_stderr = (stderr[:500] + '... [truncated]') if len(stderr) > 500 else stderr
                logger.debug(f"Command stderr: {log_stderr}")

            if check and returncode != 0:
                logger.error(f"Command failed: {cmd_str}")
                logger.error(f"Error: {stderr.strip()}")
                logger.debug(f"Failed command details - return code: {returncode}, execution time: {execution_time:.4f}s")

            return returncode, stdout.strip(), stderr.strip()
        except Exception as e:
            logger.error(f"Exception running command {cmd_str}: {str(e)}")
            logger.debug(f"Command exception details: {type(e).__name__}, {str(e)}")
            logger.debug(f"Exception traceback:", exc_info=True)
            return 1, "", str(e)

    def is_installed(self, package: str) -> bool:
        """Check if a package is installed using dpkg"""
        returncode, stdout, _ = self.run_command(f"dpkg -l {package}", shell=True, check=False)
        # Check if package exists in dpkg database AND has "ii" status (properly installed)
        return returncode == 0 and any(line.strip().startswith("ii") for line in stdout.split("\n"))

    def setup_docker_repository(self):
        """Set up Docker repository"""
        logger.info("Setting up Docker repository...")

        # Setup keyrings directory
        self.run_command("install -m 0755 -d /etc/apt/keyrings", shell=True)

        # Add Docker's GPG key
        if not os.path.exists("/etc/apt/keyrings/docker.gpg"):
            logger.info("Adding Docker's official GPG key...")
            curl_cmd = f"curl -fsSL https://download.docker.com/linux/debian/gpg"
            gpg_cmd = f"gpg --dearmor -o /etc/apt/keyrings/docker.gpg"

            self.run_command(
                f"{curl_cmd} | {gpg_cmd}",
                shell=True
            )
            self.run_command("chmod a+r /etc/apt/keyrings/docker.gpg", shell=True)

        # Add Docker repository
        logger.info("Adding Docker repository to apt sources...")
        codename_cmd = ". /etc/os-release && echo \"$VERSION_CODENAME\""
        _, codename, _ = self.run_command(codename_cmd, shell=True)

        arch_cmd = "dpkg --print-architecture"
        _, arch, _ = self.run_command(arch_cmd, shell=True)

        docker_repo = f"deb [arch={arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian {codename} stable"

        with open("/etc/apt/sources.list.d/docker.list", "w") as f:
            f.write(docker_repo + "\n")

        # Update apt
        self.run_command("apt update", shell=True)

    def display_package_menu(self, packages, docker_pkgs):
        """Display a simple command-line menu for package selection"""
        print("\nPackage Selection Menu")
        print("----------------------")
        print("Available packages:")

        for i, pkg in enumerate(packages, 1):
            print(f"{i}) {pkg}")

        print("\nEnter package numbers to install (comma-separated, e.g., '1,3,5')")
        print("Type 'all' to select all packages or 'none' to select none")

        selection = input("Your selection: ").strip().lower()

        selected_indices = set()
        if selection == 'all':
            selected_indices = set(range(len(packages)))
        elif selection != 'none':
            try:
                for num in selection.split(','):
                    idx = int(num.strip()) - 1
                    if 0 <= idx < len(packages):
                        selected_indices.add(idx)
            except ValueError:
                print("Invalid selection format. Please use numbers separated by commas.")
                return self.display_package_menu(packages, docker_pkgs)

        # Process selections into package dict
        result = {}
        docker_item_index = packages.index("docker") if "docker" in packages and self.docker_available else None
        docker_selected = docker_item_index is not None and docker_item_index in selected_indices

        for i, pkg in enumerate(packages):
            if i in selected_indices:
                if pkg == "docker":
                    # Mark all docker packages as selected
                    for docker_pkg in docker_pkgs:
                        result[docker_pkg] = True
                else:
                    result[pkg] = True

        # Show selected packages for confirmation
        print("\nSelected packages:")
        selected_pkgs = [pkg for pkg, selected in result.items() if selected]
        if selected_pkgs:
            for pkg in selected_pkgs:
                print(f"- {pkg}")
        else:
            print("- None")

        # Proceed immediately without requiring confirmation
        return result

    def install_packages(self):
        """Install selected packages"""
        # Always install these critical packages first
        critical_pkgs = ["sudo", "python3"]
        for pkg in critical_pkgs:
            if not self.is_installed(pkg):
                logger.info(f"Installing critical package {pkg}...")
                self.run_command("apt update", shell=True)
                self.run_command(f"apt install -y {pkg}", shell=True)
            else:
                logger.info(f"Critical package {pkg} is already installed.")

        # Base packages list (excluding critical packages and curl which should already be installed)
        pkgs = [
            "1password-cli",
            "certbot",
            "cmake",
            "fail2ban",
            "fdupes",
            "ffmpeg",
            "nginx",
            "nodejs",
            "npm",
            "nvm",
            "pandoc",
        ]

        # Check if Docker is available and add Docker packages
        docker_pkgs = []
        _, apt_cache_output, _ = self.run_command("apt-cache policy docker-ce", shell=True, check=False)

        if "Candidate:" in apt_cache_output:
            self.docker_available = True
            docker_pkgs = [
                "containerd.io",
                "docker-buildx-plugin",
                "docker-ce",
                "docker-ce-cli",
                "docker-compose-plugin",
            ]
            # If Docker is available, add "docker" to the package list rather than individual packages
            # This will ensure "docker" shows up alphabetically in the list
            pkgs.append("docker")

        # Add Plex as an option regardless of whether it's in repositories
        # (we'll set up the repo only if selected)
        pkgs.append("plex")

        # Sort packages alphabetically
        pkgs.sort()

        # Display interactive menu for package selection
        logger.info("Displaying package selection menu...")
        selected_packages_dict = self.display_package_menu(pkgs, docker_pkgs)

        # Process selection
        if selected_packages_dict is None:
            logger.info("Package selection was cancelled.")
            selected_pkgs = []
        else:
            selected_pkgs = [pkg for pkg, selected in selected_packages_dict.items() if selected]
            logger.info(f"Selected {len(selected_pkgs)} packages for installation.")

        # Install selected packages
        for pkg in selected_pkgs:
            if pkg == "plex":
                # Handle Plex Media Server installation
                if not self.is_installed("plexmediaserver"):
                    logger.info("Installing Plex Media Server...")

                    # Add Plex repository (with minimal output)
                    logger.info("Adding Plex repository...")
                    self.run_command("curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key | gpg --dearmor | tee /usr/share/keyrings/plex.gpg > /dev/null", shell=True, check=False)
                    self.run_command("echo \"deb [signed-by=/usr/share/keyrings/plex.gpg] https://downloads.plex.tv/repo/deb public main\" | tee /etc/apt/sources.list.d/plexmediaserver.list > /dev/null", shell=True, check=False)

                    # Update package list and install Plex
                    self.run_command("apt update > /dev/null", shell=True, check=False)
                    self.run_command("apt install -y plexmediaserver", shell=True, check=False)

                    # Enable and start Plex Media Server
                    self.run_command("systemctl enable plexmediaserver", shell=True, check=False)
                    self.run_command("systemctl start plexmediaserver", shell=True, check=False)
                else:
                    logger.info("Plex Media Server is already installed, skipping.")
            elif pkg == "bitwarden-cli":
                # Handle Bitwarden CLI installation
                logger.info("Installing Bitwarden CLI...")
                # First install build-essential package
                if not self.is_installed("build-essential"):
                    logger.info("Installing build-essential package for Bitwarden CLI...")
                    self.run_command("apt install -y build-essential", shell=True, check=False)

                # Make sure npm is installed
                if not self.is_installed("npm"):
                    logger.info("Installing npm for Bitwarden CLI...")
                    self.run_command("apt install -y npm", shell=True, check=False)

                # Install Bitwarden CLI using npm
                logger.info("Installing Bitwarden CLI using npm...")
                self.run_command("npm install -g @bitwarden/cli", shell=True, check=False)
                logger.info("Bitwarden CLI installation completed.")
            elif pkg == "1password-cli":
                # Handle 1Password CLI installation
                logger.info("Installing 1Password CLI...")

                # Update system packages
                self.run_command("apt update", shell=True, check=False)

                # Install required dependencies
                self.run_command("apt install -y gnupg2 apt-transport-https ca-certificates software-properties-common", shell=True, check=False)

                # Add the GPG key for the 1Password APT repository (with minimal output)
                self.run_command("curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg", shell=True, check=False)

                # Add the 1Password APT repository (with minimal output)
                self.run_command("echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main\" | tee /etc/apt/sources.list.d/1password.list > /dev/null", shell=True, check=False)

                # Add the debsig-verify policy for verifying package signatures (with minimal output)
                self.run_command("mkdir -p /etc/debsig/policies/AC2D62742012EA22/", shell=True, check=False)
                self.run_command("curl -fsSL https://downloads.1password.com/linux/debian/debsig/1password.pol | tee /etc/debsig/policies/AC2D62742012EA22/1password.pol > /dev/null", shell=True, check=False)
                self.run_command("mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22/", shell=True, check=False)
                self.run_command("curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg", shell=True, check=False)

                # Update package list and install 1Password CLI
                self.run_command("apt update > /dev/null && apt install -y 1password-cli", shell=True, check=False)
                logger.info("1Password CLI installation completed.")
            elif pkg == "nvm":
                # Handle NVM installation
                logger.info("Installing NVM (Node Version Manager)...")

                # Install NVM for the current non-root user
                if self.current_non_root_user != "root":
                    # Get user's home directory
                    _, user_home, _ = self.run_command(f"getent passwd {self.current_non_root_user} | cut -d: -f6", shell=True)
                    user_home = user_home.strip()

                    logger.info(f"Installing NVM for {self.current_non_root_user} (home: {user_home})...")

                    # Ensure we explicitly set HOME environment variable for the non-root user
                    nvm_install_cmd_user = f"sudo -H -u {self.current_non_root_user} bash -c 'export HOME=\"{user_home}\" && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash'"
                    self.run_command(nvm_install_cmd_user, shell=True, check=False)

                    # Source NVM for the current non-root user with explicit HOME
                    nvm_source_cmd_user = f"sudo -H -u {self.current_non_root_user} bash -c 'export HOME=\"{user_home}\" && export NVM_DIR=\"{user_home}/.nvm\" && [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\"'"
                    self.run_command(nvm_source_cmd_user, shell=True, check=False)

                    # Update user's bashrc to automatically source NVM
                    bashrc_path = os.path.join(user_home, ".bashrc")
                    if os.path.exists(bashrc_path):
                        with open(bashrc_path, "r") as f:
                            bashrc_content = f.read()

                        nvm_bashrc_snippet = '''
# NVM setup
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
'''

                        if "NVM_DIR" not in bashrc_content:
                            logger.info(f"Adding NVM source commands to {self.current_non_root_user}'s .bashrc...")
                            with open(bashrc_path, "a") as f:
                                f.write(nvm_bashrc_snippet)
                            # Source the updated bashrc
                            self.run_command(f"sudo -H -u {self.current_non_root_user} bash -c 'export HOME=\"{user_home}\" && source {bashrc_path}'", shell=True, check=False)
                        else:
                            logger.info(f"NVM source commands already exist in {self.current_non_root_user}'s .bashrc")
                    else:
                        logger.info(f"Couldn't find .bashrc for {self.current_non_root_user}, skipping automatic sourcing")

                    # Get latest Node.js version and install for the current non-root user with explicit HOME
                    nvm_install_node_cmd_user = f"sudo -H -u {self.current_non_root_user} bash -c 'export HOME=\"{user_home}\" && export NVM_DIR=\"{user_home}/.nvm\" && [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\" && nvm install node && nvm use node'"
                    self.run_command(nvm_install_node_cmd_user, shell=True, check=False)

                    # Export NVM environment for the current script session
                    os.environ["NVM_DIR"] = os.path.join(user_home, ".nvm")
                    self.run_command(f"bash -c 'export HOME=\"{user_home}\" && export NVM_DIR=\"{os.environ['NVM_DIR']}\" && [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\"'", shell=True)

                # Also install NVM for root (regardless of whether the current user is root or not)
                logger.info("Installing NVM for root user...")

                # Ensure root's home directory exists and is accessible
                self.run_command("mkdir -p /root", shell=True)

                # Use logger instead of writing to a hardcoded path
                logger.debug("Starting NVM installation for root user")

                # List the root directory for debugging
                self.run_command("ls -la /root", shell=True, check=False)

                # Clear any existing NVM directory to ensure clean installation
                self.run_command("rm -rf /root/.nvm", shell=True)

                # Explicitly set HOME to /root when installing NVM for root user
                logger.debug("Running NVM install command for root with explicit HOME")

                # Run the NVM installer with HOME explicitly set to /root
                nvm_install_cmd_root = "export HOME=/root && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash"
                ret_code, stdout, stderr = self.run_command(nvm_install_cmd_root, shell=True, check=False)

                # Log the result of the NVM installation
                logger.debug(f"NVM install command for root returned code {ret_code}")
                if stdout:
                    logger.debug(f"NVM stdout: {stdout}")
                if stderr:
                    logger.debug(f"NVM stderr: {stderr}")

                # Check if NVM directory was created in the correct location
                _, nvm_check, _ = self.run_command("ls -la /root/.nvm", shell=True, check=False)
                if nvm_check:
                    logger.debug(f"NVM directory exists in /root/.nvm: {nvm_check}")
                else:
                    logger.debug("NVM directory NOT found in /root/.nvm")

                    # If NVM directory wasn't created in /root/.nvm, check if it was created elsewhere
                    _, alt_nvm_check, _ = self.run_command("find / -name '.nvm' -type d 2>/dev/null", shell=True, check=False)
                    logger.debug(f"Found .nvm directories: {alt_nvm_check}")

                    # Get current user's home directory instead of hardcoded path
                    user_home = os.path.expanduser("~")
                    # If NVM was installed in current user's home instead, copy it to /root/.nvm
                    if os.path.exists(f"{user_home}/.nvm") and not os.path.exists("/root/.nvm"):
                        logger.debug(f"Copying NVM from {user_home}/.nvm to /root/.nvm")
                        self.run_command(f"cp -r {user_home}/.nvm /root/.nvm", shell=True)
                        self.run_command("chown -R root:root /root/.nvm", shell=True)

                # Update root's bashrc to automatically source NVM
                root_bashrc_path = "/root/.bashrc"
                if os.path.exists(root_bashrc_path):
                    with open(root_bashrc_path, "r") as f:
                        root_bashrc_content = f.read()

                    if "NVM_DIR" not in root_bashrc_content:
                        logger.info("Adding NVM source commands to root's .bashrc...")
                        with open(root_bashrc_path, "a") as f:
                            f.write('''
# NVM setup
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
''')
                        # Source the updated bashrc and log the result
                        ret_code, _, _ = self.run_command("export HOME=/root && source /root/.bashrc", shell=True, check=False)
                        logger.debug(f"Sourcing updated .bashrc returned code {ret_code}")
                    else:
                        logger.info("NVM source commands already exist in root's .bashrc")
                        logger.debug("NVM source commands already exist in root's .bashrc")
                else:
                    # Create a .bashrc file for root if it doesn't exist
                    logger.info("Creating .bashrc for root with NVM configuration...")
                    with open(root_bashrc_path, "w") as f:
                        f.write('''# ~/.bashrc: executed by bash(1) for non-login shells.

# NVM setup
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
''')
                    logger.debug("Created new .bashrc for root with NVM configuration")

                # Try to install Node.js using NVM for root with explicit HOME
                logger.debug("Attempting to install Node.js with NVM for root")

                nvm_install_node_cmd_root = "export HOME=/root && export NVM_DIR=\"/root/.nvm\" && [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\" && nvm install node && nvm use node"
                ret_code, stdout, stderr = self.run_command(nvm_install_node_cmd_root, shell=True, check=False)

                logger.debug(f"Node.js install returned code {ret_code}")
                if stdout:
                    logger.debug(f"Node.js stdout: {stdout}")
                if stderr:
                    logger.debug(f"Node.js stderr: {stderr}")

                logger.info("NVM installation completed.")
                logger.info("NVM has been configured to be automatically loaded in future shell sessions.")
            elif not self.is_installed(pkg):
                logger.info(f"Installing {pkg}...")
                self.run_command(f"apt install -y {pkg}", shell=True, check=False)
            else:
                logger.info(f"{pkg} is already installed, skipping.")

            # Check if any Docker packages were installed
            if pkg in docker_pkgs and self.is_installed(pkg):
                self.docker_installed = True

    def handle_docker_fallback(self):
        """Handle fallback to docker.io if needed"""
        if not self.docker_available:
            docker_repo_exists = os.path.exists("/etc/apt/sources.list.d/docker.list")

            if docker_repo_exists:
                logger.info("Docker repository exists but packages not available. Using docker.io as fallback...")
            else:
                logger.info("Docker repository file not found, using docker.io as fallback...")

            docker_fallback_choice = input("Install docker.io and docker-compose-plugin? (Y/n): ")

            if not docker_fallback_choice.lower().startswith('n'):
                logger.info("Installing alternative Docker packages...")
                self.run_command("apt install -y docker.io docker-compose-plugin", shell=True)
                self.docker_installed = True
            else:
                logger.info("Skipping docker.io installation.")
                self.docker_installed = False

    def setup_user(self):
        """Setup user and permissions"""
        # Create user if doesn't exist
        _, exists_output, _ = self.run_command(f"id {self.current_non_root_user}", shell=True, check=False)

        if "no such user" in exists_output.lower():
            logger.info(f"Creating user {self.current_non_root_user}...")
            self.run_command(f"useradd -m -s /bin/bash {self.current_non_root_user}", shell=True)
        else:
            logger.info(f"User {self.current_non_root_user} already exists, skipping.")

        # Add user to sudoers if not already added
        sudoers_file = f"/etc/sudoers.d/{self.current_non_root_user}"
        if not os.path.exists(sudoers_file):
            logger.info(f"Adding {self.current_non_root_user} to sudoers file directly...")
            with open(sudoers_file, "w") as f:
                f.write(f"{self.current_non_root_user} ALL=(ALL) ALL\n")
            os.chmod(sudoers_file, 0o440)
            logger.info(f"{self.current_non_root_user} added to sudoers directly via {sudoers_file}.")
        else:
            logger.info(f"Sudoers file for {self.current_non_root_user} already exists, skipping.")

        # Add user to sudo group
        _, groups_output, _ = self.run_command(f"groups {self.current_non_root_user}", shell=True, check=False)

        if "sudo" not in groups_output:
            logger.info(f"Adding {self.current_non_root_user} to sudo group...")
            if self.usermod_available:
                self.run_command(f"usermod -aG sudo {self.current_non_root_user}", shell=True)
            else:
                logger.info(f"Using alternative method to add {self.current_non_root_user} to sudo group...")
                try:
                    with open("/etc/group", "r") as f:
                        groups_content = f.read()

                    if f"sudo:.*{self.current_non_root_user}" not in groups_content:
                        groups_content = re.sub(r'^(sudo:.*)', f'\\1,{self.current_non_root_user}', groups_content, flags=re.MULTILINE)

                        with open("/etc/group", "w") as f:
                            f.write(groups_content)
                except Exception as e:
                    logger.error(f"Error modifying groups file: {str(e)}")

            logger.info(f"{self.current_non_root_user} added to sudo group.")
        else:
            logger.info(f"{self.current_non_root_user} is already in sudo group, skipping.")

        # Add user to docker group if applicable
        if self.docker_installed:
            _, getent_output, _ = self.run_command("getent group docker", shell=True, check=False)

            if getent_output:  # Docker group exists
                if "docker" not in groups_output:
                    logger.info(f"Adding {self.current_non_root_user} to docker group...")
                    if self.usermod_available:
                        self.run_command(f"usermod -aG docker {self.current_non_root_user}", shell=True)
                    else:
                        logger.info(f"Using alternative method to add {self.current_non_root_user} to docker group...")
                        try:
                            with open("/etc/group", "r") as f:
                                groups_content = f.read()

                            if f"docker:.*{self.current_non_root_user}" not in groups_content:
                                groups_content = re.sub(r'^(docker:.*)', f'\\1,{self.current_non_root_user}', groups_content, flags=re.MULTILINE)

                                with open("/etc/group", "w") as f:
                                    f.write(groups_content)
                        except Exception as e:
                            logger.error(f"Error modifying groups file: {str(e)}")

                    logger.info(f"{self.current_non_root_user} added to docker group.")
                else:
                    logger.info(f"{self.current_non_root_user} is already in docker group, skipping.")

    def configure_ssh(self):
        """Configure SSH server"""
        logger.info("Configuring SSH server...")
        logger.debug("Starting SSH server configuration process")

        # Backup original config if not already backed up
        if not os.path.exists("/etc/ssh/sshd_config.bak"):
            try:
                shutil.copy("/etc/ssh/sshd_config", "/etc/ssh/sshd_config.bak")
                logger.info("Original sshd_config backed up to /etc/ssh/sshd_config.bak")
                logger.debug(f"Backup created successfully at {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
            except Exception as e:
                logger.error(f"Failed to create backup of sshd_config: {str(e)}", exc_info=True)
                logger.debug(f"Backup error details: {type(e).__name__}")
        else:
            logger.debug("Backup file already exists, skipping backup creation")

        # Write standard SSH configuration
        logger.info("Writing SSH configuration...")
        with open("/etc/ssh/sshd_config", "w") as f:
            f.write(f"""Include /etc/ssh/sshd_config.d/*.conf
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
AllowUsers {self.current_non_root_user} root
""")

        logger.info("SSH configuration updated.")

    def discover_smb_shares(self):
        """Configure and mount SMB/CIFS shares from configuration file"""
        logger.info("Setting up SMB/CIFS shares from configuration...")
        logger.debug(f"SMB setup initiated at {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

        # Define the path to the SMB environment file
        script_dir = os.path.dirname(os.path.abspath(__file__))
        root_dir = os.path.dirname(os.path.dirname(script_dir))
        smb_env_path = os.path.join(root_dir, "secrets", ".smb")

        # Check if the SMB env file exists
        if not os.path.exists(smb_env_path):
            logger.info(f"SMB environment file not found at {smb_env_path}, creating template...")
            os.makedirs(os.path.dirname(smb_env_path), exist_ok=True)
            
            # Create a template .smb file using the current format
            with open(smb_env_path, "w") as f:
                f.write("""# SMB/CIFS shares configuration

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
""")
            logger.info(f"Template created. Please edit {smb_env_path} with your share information and re-run the script.")
            return

        # Read the configuration file
        shares_config = []
        env_vars = {}
        hosts = []
        try:
            logger.debug(f"Reading SMB configuration from {smb_env_path}")
            with open(smb_env_path, "r") as f:
                for line in f:
                    line = line.strip()
                    # Skip empty lines and comments
                    if not line or line.startswith("#"):
                        continue
                    
                    # Parse the environment variable format
                    if "=" in line:
                        key, value = line.split("=", 1)
                        key = key.strip()
                        value = value.strip()
                        env_vars[key] = value
                        
                        # Detect host entries
                        if key.startswith("SMB_HOST_") and "_USER" not in key and "_PW" not in key and "_SHARE_" not in key:
                            host_num = key.split("SMB_HOST_")[1]
                            if host_num not in hosts:
                                hosts.append(host_num)
        
            # Process each host and its shares
            for host_num in hosts:
                host = env_vars.get(f"SMB_HOST_{host_num}")
                username = env_vars.get(f"SMB_HOST_{host_num}_USER")
                password = env_vars.get(f"SMB_HOST_{host_num}_PW")
                
                if not host or not username or not password:
                    logger.warning(f"Missing required configuration for SMB_HOST_{host_num}")
                    continue
                
                # Find all shares for this host
                share_count = 1
                while True:
                    share_key = f"SMB_HOST_{host_num}_SHARE_{share_count}"
                    if share_key not in env_vars:
                        break
                    
                    share_name = env_vars[share_key]
                    shares_config.append({
                        "host": host,
                        "host_name": host,  # Using the hostname as the display name
                        "share": share_name,
                        "username": username,
                        "password": password
                    })
                    share_count += 1
                    
        except Exception as e:
            logger.error(f"Error reading SMB configuration: {str(e)}")
            return

        if not shares_config:
            logger.info("No SMB shares configured in the environment file.")
            logger.info(f"Please edit {smb_env_path} with your share information and re-run the script.")
            return

        # Process each configured share
        mount_successful = False
        for config in shares_config:
            host = config["host"]
            host_name = config["host_name"]
            share_name = config["share"]
            username = config["username"]
            password = config["password"]

            logger.info(f"Processing share '{green(share_name)}' on {cyan(host)} ({cyan(host_name)})", {'color': True})

            # Create a credentials file for this host
            creds_file = f"/etc/.smb_{host.replace('.', '_')}"
            logger.info(f"Creating credentials file for {host}...")

            with open(creds_file, "w") as f:
                if username:
                    f.write(f"username={username}\npassword={password}\n")
                else:
                    f.write("username=guest\npassword=\n")

            os.chmod(creds_file, 0o600)
            self.run_command(f"chown root:root {creds_file}", shell=True)
            logger.debug(f"Credentials file created at {creds_file}")

            # Create mount point
            mount_point = f"/mnt/{share_name}"
            if not os.path.exists(mount_point):
                logger.info(f"Creating mount point directory {mount_point}...")
                os.makedirs(mount_point, exist_ok=True)
                self.run_command(f"chown {self.current_non_root_user}:{self.current_non_root_user} {mount_point}", shell=True)
                self.run_command(f"chmod 755 {mount_point}", shell=True)
            else:
                # Check current owner and permissions
                _, current_owner, _ = self.run_command(f"stat -c '%U:%G' {mount_point}", shell=True)
                _, current_perms, _ = self.run_command(f"stat -c '%a' {mount_point}", shell=True)

                if current_owner != f"{self.current_non_root_user}:{self.current_non_root_user}":
                    logger.info("Updating mount point ownership...")
                    self.run_command(f"chown {self.current_non_root_user}:{self.current_non_root_user} {mount_point}", shell=True)

                if current_perms != "755":
                    logger.info("Updating mount point permissions...")
                    self.run_command(f"chmod 755 {mount_point}", shell=True)
                else:
                    logger.info("Mount point already exists with correct ownership and permissions.")

            # Add to fstab
            fstab_entry = f"//{host}/{share_name} {mount_point} cifs credentials={creds_file},x-gvfs-show,uid={self.current_non_root_user},gid={self.current_non_root_user} 0 0"

            # Check if entry already exists
            with open("/etc/fstab", "r") as f:
                fstab_content = f.read()

            if f"//{host}/{share_name} {mount_point}" not in fstab_content:
                logger.info("Adding CIFS mount to fstab...")
                with open("/etc/fstab", "a") as f:
                    f.write(f"{fstab_entry}\n")
                logger.info("CIFS mount entry added to fstab.")
            else:
                if fstab_entry not in fstab_content:
                    logger.info("Updating existing CIFS mount entry in fstab...")
                    new_fstab = re.sub(
                        f"^.*//{host}/{share_name} {mount_point}.*$",
                        fstab_entry,
                        fstab_content,
                        flags=re.MULTILINE
                    )
                    with open("/etc/fstab", "w") as f:
                        f.write(new_fstab)
                else:
                    logger.info("CIFS mount entry already exists in fstab.")

            # Check if already mounted
            _, mount_check, _ = self.run_command(f"mount | grep {mount_point}", shell=True, check=False)
            if mount_point in mount_check:
                logger.info(f"{green('Filesystem is already mounted.')}", {'color': True})
                share_mount_success = True
                mount_successful = True
                continue

            # Try to mount
            share_mount_success = False
            logger.info(f"{blue(f'Attempting to mount {share_name}...')}", {'color': True})

            # Try with explicit SMB versions
            for vers in ["3.0", "2.0", "1.0"]:
                mount_cmd = f"mount -t cifs '//{host}/{share_name}' '{mount_point}' -o 'credentials={creds_file},vers={vers},uid={self.current_non_root_user},gid={self.current_non_root_user}'"
                rc, mount_stdout, mount_stderr = self.run_command(mount_cmd, shell=True, check=False)

                # Add detailed debugging info at debug level
                logger.debug(f"Mount attempt with SMB v{vers}: Return code {rc}")
                if mount_stderr:
                    logger.debug(f"Mount error: {mount_stderr}")
                if mount_stdout:
                    logger.debug(f"Mount output: {mount_stdout}")

                if rc == 0:
                    logger.info(f"{green(f'Mount of {share_name} successful with SMB v{vers}!')}", {'color': True})
                    share_mount_success = True
                    mount_successful = True
                    break

            if not share_mount_success:
                logger.error(f"{red(f'WARNING: Failed to mount {share_name}')}", {'color': True})
                logger.error(f"{yellow('Please check your configuration, network connectivity, and credentials.')}", {'color': True})
                logger.error(f"{yellow(f'You can manually mount the share later using: sudo mount {mount_point}')}", {'color': True})
                logger.error(f"{yellow(f'The share will be automatically mounted at system startup due to the automount service.')}", {'color': True})

        # Report overall status
        if mount_successful:
            logger.info(f"{green('Successfully mounted one or more SMB shares.')}", {'color': True})
        else:
            logger.warning(f"{yellow('Failed to mount any SMB shares. They will be attempted at system startup.')}", {'color': True})

        # Ensure the credentials files and passwords aren't accessible
        self.run_command("find /etc -name '.smb_*' -exec chmod 600 {} \\;", shell=True)
        
        # Clear password from memory
        for config in shares_config:
            config["password"] = ""

    def setup_security_updates(self):
        """Setup automatic security updates"""
        logger.info("Setting up automatic security updates...")

        # Install unattended-upgrades if not already installed
       # if not self.is_installed("unattended-upgrades"):
        #    logger.info("Installing unattended-upgrades package...")
         #   self.run_command("apt update", shell=True)
          #  self.run_command("apt install -y unattended-upgrades apt-listchanges", shell=True)

        # Configure unattended-upgrades
        logger.info("Configuring unattended-upgrades...")

        # Write auto-upgrades configuration
        with open("/etc/apt/apt.conf.d/20auto-upgrades", "w") as f:
            f.write("""APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Download-Upgradeable-Packages "1";
""")

        # Check if 50unattended-upgrades exists and modify it
        if os.path.exists("/etc/apt/apt.conf.d/50unattended-upgrades"):
            with open("/etc/apt/apt.conf.d/50unattended-upgrades", "r") as f:
                config_content = f.read()

            # Enable security updates if not already enabled
            if not re.search(r'^\s*"origin=Debian,codename=\${distro_codename},label=Debian-Security";', config_content, re.MULTILINE):
                logger.info("Enabling automatic security updates...")
                config_content = re.sub(
                    r'//\s*"origin=Debian,codename=\${distro_codename},label=Debian-Security";',
                    '"origin=Debian,codename=${distro_codename},label=Debian-Security";',
                    config_content
                )
            else:
                logger.info("Automatic security updates already enabled.")

            # Configure automatic reboot
            if "Unattended-Upgrade::Automatic-Reboot" not in config_content:
                logger.info("Configuring to prevent automatic reboots after updates...")
                config_content += '\nUnattended-Upgrade::Automatic-Reboot "false";\n'
            else:
                config_content = re.sub(
                    r'Unattended-Upgrade::Automatic-Reboot "true";',
                    'Unattended-Upgrade::Automatic-Reboot "false";',
                    config_content
                )

            # Write modified configuration
            with open("/etc/apt/apt.conf.d/50unattended-upgrades", "w") as f:
                f.write(config_content)
        else:
            # Create full configuration file if it doesn't exist
            logger.info("Creating full unattended-upgrades configuration...")
            with open("/etc/apt/apt.conf.d/50unattended-upgrades", "w") as f:
                f.write("""Unattended-Upgrade::Allowed-Origins {
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
""")

        # Enable and restart service
        logger.info("Enabling unattended-upgrades service...")
        self.run_command("systemctl enable unattended-upgrades", shell=True)
        self.run_command("systemctl restart unattended-upgrades", shell=True)
        logger.info("Automatic updates configuration completed.")

    def setup_ssh_keys(self):
        """Setup SSH keys for user"""
        logger.debug(f"Starting SSH key setup at {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        
        logger.info(f"Setting up SSH keys for {self.current_non_root_user}...")
        logger.debug(f"Will configure SSH keys for user: {self.current_non_root_user}")

        # Get user's home directory
        logger.debug(f"Getting home directory for user {self.current_non_root_user}")
        ret_code, user_home, error = self.run_command(f"getent passwd {self.current_non_root_user} | cut -d: -f6", shell=True)

        if ret_code != 0:
            logger.error(f"Failed to get home directory: {error}")
            logger.debug(f"Home directory command failed with exit code {ret_code}")
            # Use a fallback approach
            logger.debug("Attempting fallback approach to determine home directory")
            user_home = f"/home/{self.current_non_root_user}" if self.current_non_root_user != "root" else "/root"
            logger.debug(f"Using fallback home directory: {user_home}")
        else:
            user_home = user_home.strip()
            logger.debug(f"Found home directory: {user_home}")

        ssh_dir = os.path.join(user_home, ".ssh")
        logger.debug(f"SSH directory path: {ssh_dir}")

        # Create SSH directory if it doesn't exist
        if not os.path.exists(ssh_dir):
            logger.info(f"Creating SSH directory for {self.current_non_root_user}...")
            os.makedirs(ssh_dir, exist_ok=True)
            self.run_command(f"chmod 700 {ssh_dir}", shell=True)
            self.run_command(f"chown {self.current_non_root_user}:{self.current_non_root_user} {ssh_dir}", shell=True)

        # Generate SSH key if it doesn't exist
        if not os.path.exists(os.path.join(ssh_dir, "id_rsa")) and not os.path.exists(os.path.join(ssh_dir, "id_rsa.pub")):
            logger.info(f"Generating SSH key for {self.current_non_root_user}...")
            self.run_command(f"sudo -u {self.current_non_root_user} ssh-keygen -t rsa -N \"\" -f {os.path.join(ssh_dir, 'id_rsa')}", shell=True)
            logger.info("SSH key generated successfully.")
        else:
            logger.info(f"SSH key already exists for {self.current_non_root_user}, skipping generation.")

        # Setup authorized_keys
        authorized_keys = os.path.join(ssh_dir, "authorized_keys")
        if not os.path.exists(authorized_keys):
            logger.info("Creating authorized_keys file...")
            open(authorized_keys, "w").close()  # Create empty file
            self.run_command(f"chmod 600 {authorized_keys}", shell=True)
            self.run_command(f"chown {self.current_non_root_user}:{self.current_non_root_user} {authorized_keys}", shell=True)

            logger.info(f"{green('Please paste your public SSH key to add to authorized_keys (press ENTER when done):')}",
                     {'color': True})
            ssh_key = input()

            if ssh_key:
                with open(authorized_keys, "w") as f:
                    f.write(f"{ssh_key}\n")

                logger.info(f"{green('Public key added to authorized_keys.')}", {'color': True})
        else:
            logger.info(f"{yellow('authorized_keys file already exists, would you like to add a new key? (y/n)')}",
                     {'color': True})
            add_key = input()

            if add_key.lower() == 'y':
                logger.info(f"{green('Please paste your public SSH key to add to authorized_keys (press ENTER when done):')}",
                         {'color': True})
                ssh_key = input()

                if ssh_key:
                    with open(authorized_keys, "a") as f:
                        f.write(f"{ssh_key}\n")
                    logger.info(f"{green('Public key added to authorized_keys.')}", {'color': True})
                else:
                    logger.info("No key provided. You can add a key later with: echo 'YOUR_PUBLIC_KEY' >> ~/.ssh/authorized_keys")
            else:
                logger.info("Skipping adding new key.")

        # Restart SSH service
        logger.info("Restarting SSH service...")
        self.run_command("systemctl restart sshd", shell=True)
        self.run_command("systemctl status sshd --no-pager", shell=True)

    def finalize_script(self):
        """Final steps and summary"""
        logger.info("-" * 40)
        logger.info(f"Script completed at {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

        if self.error_flag:
            logger.error(f"{red('ERROR: There were errors during script execution.')}", {'color': True})
            logger.error(f"Please check the log file at {LOG_FILE} for details.")
            sys.exit(1)
        else:
            logger.info(f"{green('SUCCESS: Script completed without errors.')}", {'color': True})
            logger.info(f"Log file is available at {LOG_FILE}")
            logger.info("")
            logger.info(f"{blue('SSH has been configured with the following settings:')}", {'color': True})

            logger.info(f"- SSH access is restricted to user: {cyan(self.current_non_root_user)}", {'color': True})
            logger.info("- Root login is disabled")
            logger.info("- SSH key authentication is enabled")
            logger.info("- Password authentication is enabled")

            logger.info(f"You can now connect to this server using: {green(f'ssh {self.current_non_root_user}@hostname')}", {'color': True})
            
            logger.info("")

            # Create automount service for network shares
            logger.info("Creating automount service for network shares...")
            automount_service = """[Unit]
Description=Dynamically check network mounts and automount on start
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/bin/sleep 15
ExecStart=/bin/bash -c 'hosts=$(grep -E "^[^#].*cifs|nfs" /etc/fstab | grep -oP "//\\K[^/]+" | sort -u); for host in $hosts; do for i in {1..10}; do ping -c 1 $host && break || (echo "Waiting for $host..." && sleep 3); done; done; mount -a'
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"""

            # Make sure we have appropriate permissions to create the service file
            if os.geteuid() != 0:
                logger.info(f"{yellow('Creating systemd service requires root privileges. Attempting with sudo...')}", {'color': True})
                # Create a temporary file
                with open("/tmp/automount-on-start.service", "w") as f:
                    f.write(automount_service)
                # Use sudo to move it to the right location
                self.run_command("sudo mv /tmp/automount-on-start.service /etc/systemd/system/", shell=True)
                self.run_command("sudo chmod 644 /etc/systemd/system/automount-on-start.service", shell=True)
                # Enable and start the service with sudo
                self.run_command("sudo systemctl enable automount-on-start.service", shell=True)
                self.run_command("sudo systemctl start automount-on-start.service", shell=True)
            else:
                # Running as root, we can create the file directly
                with open("/etc/systemd/system/automount-on-start.service", "w") as f:
                    f.write(automount_service)
                os.chmod("/etc/systemd/system/automount-on-start.service", 0o644)
                # Enable and start the service
                self.run_command("systemctl enable automount-on-start.service", shell=True)
                self.run_command("systemctl start automount-on-start.service", shell=True)
            
            logger.info(f"{green('Automount service created, enabled, and started')}", {'color': True})
            
            # Reload systemd
            self.run_command("systemctl daemon-reload", shell=True)

            sys.exit(0)

if __name__ == "__main__":
    setup = DebianSetup()
    setup.run()
