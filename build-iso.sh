#!/usr/bin/env bash
set -euo pipefail

# Set default values
USE_DHCP=false

# Parse command line arguments
for arg in "$@"; do
  case $arg in
    --test)
      USE_DHCP=true
      shift
      ;;
  esac
done

# Debug
if [[ "$USE_DHCP" == true ]]; then
  echo "TEST MODE ENABLED: Will create ISO with DHCP instead of static IP"
fi

# Check if running as root/sudo
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Restarting with sudo..."
    if [[ "$USE_DHCP" == true ]]; then
        echo "DEBUG: Preserving USE_DHCP=true flag during sudo restart"
        exec sudo "$0" --test
    else
        exec sudo "$0" "$@"
    fi
    exit 1  # This line should never execute
fi

# Extra debug - check if --test argument was passed correctly
echo "DEBUG: After sudo check, USE_DHCP=$USE_DHCP (Command line args: $*)"

# Capture the original user that started the script (even if through sudo)
if [[ -n "${SUDO_USER:-}" ]]; then
    ORIGINAL_USER="$SUDO_USER"
    ORIGINAL_UID=$(id -u "$ORIGINAL_USER")
    ORIGINAL_GID=$(id -g "$ORIGINAL_USER")
else
    ORIGINAL_USER=$(whoami)
    ORIGINAL_UID=$(id -u)
    ORIGINAL_GID=$(id -g)
fi

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

# Check for required packages
required_packages=(wget xorriso isolinux)
missing_packages=()

# Check invisibly if packages are installed
for pkg in "${required_packages[@]}"; do
  if ! dpkg -l | grep -q "ii  $pkg "; then
    missing_packages+=("$pkg")
  fi
done

# Install missing packages if any
if [[ ${#missing_packages[@]} -gt 0 ]]; then
  info "Installing required packages: ${missing_packages[*]}"
  apt-get update
  apt-get install -y "${missing_packages[@]}"
  success "Required packages installed successfully"
fi

# Check if preseed.cfg exists in the root directory
PRESEED_PATH="common/preseed.cfg"
if [[ ! -f "$PRESEED_PATH" ]]; then
  error "preseed.cfg not found in the common directory"
fi

info "Using preseed template: $PRESEED_PATH"

# List available hosts and select one
HOST_DIR="hosts"
if [[ ! -d "$HOST_DIR" ]]; then
  error "Host directory not found: $HOST_DIR"
fi

# Get list of host directories
mapfile -t HOSTS < <(find "$HOST_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  error "No host configurations found in $HOST_DIR directory"
fi

# Display host selection menu
echo "Available hosts:"
for i in "${!HOSTS[@]}"; do
  echo "  $((i+1)). ${HOSTS[$i]}"
done

# Get user selection
read -rp "Select host to build (1-${#HOSTS[@]}): " SELECTION
if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || ((SELECTION < 1 || SELECTION > ${#HOSTS[@]})); then
  error "Invalid selection: $SELECTION"
fi

# Get the selected host name
SELECTED_HOST="${HOSTS[$((SELECTION-1))]}"
info "Selected host: $SELECTED_HOST"

# Load host-specific network settings
HOST_ENV_FILE="/etc/secrets/.$SELECTED_HOST"
if [[ ! -f "$HOST_ENV_FILE" ]]; then
  mkdir -p "$(dirname "$HOST_ENV_FILE")"
  cat > "$HOST_ENV_FILE" <<'EOF'
# Network settings for this host
NETWORK_HOSTNAME=msi
NETWORK_DOMAIN=home.arpa
NETWORK_IP=192.168.1.3
NETWORK_GATEWAY=192.168.1.1
NETWORK_DNS=192.168.1.1
NETWORK_NETMASK=255.255.255.0

# Packages to install (space-separated list)
PACKAGES="apt-listchanges ca-certificates cifs-utils cockpit curl dos2unix fzf git gnupg htop ipcalc jq ncdu nmap openssh-server pkg-config python3 rclone rsync samba-common-bin smbclient sudo timeshift wget"
EOF
  chown "$ORIGINAL_USER:$ORIGINAL_USER" "$HOST_ENV_FILE"
  warn "Created $HOST_ENV_FILE. Please fill it in and re-run."
  exit 0
fi
set -a && source "$HOST_ENV_FILE" && set +a

# Validate network settings
for var in NETWORK_HOSTNAME NETWORK_DOMAIN NETWORK_IP NETWORK_GATEWAY NETWORK_DNS NETWORK_NETMASK PACKAGES; do
  [[ -z "${!var}" ]] && error "$var is not set in $HOST_ENV_FILE"
done

info "Packages to install: $PACKAGES"

info "Network settings loaded for $SELECTED_HOST:"
info "  HOSTNAME=$NETWORK_HOSTNAME"
info "  DOMAIN=$NETWORK_DOMAIN"
if [[ "$USE_DHCP" == true ]]; then
  info "  NETWORK: DHCP (test mode)"
else
  info "  IP=$NETWORK_IP"
  info "  NETMASK=$NETWORK_NETMASK"
  info "  GATEWAY=$NETWORK_GATEWAY"
  info "  DNS=$NETWORK_DNS"
fi

# Load general preseed settings
ENV_FILE="/etc/secrets/.preseed"
if [[ ! -f "$ENV_FILE" ]]; then
  mkdir -p "$(dirname "$ENV_FILE")"
  cat > "$ENV_FILE" <<'EOF'
# Edit these:
ROOT_PASSWORD=
USER_FULLNAME="Debian User"
USERNAME=
USER_PASSWORD=
SSH_AUTHORIZED_KEY=
ISO_MOVE=
EOF
  chown "$ORIGINAL_USER:$ORIGINAL_USER" "$ENV_FILE"
  warn "Created $ENV_FILE. Please fill it in and re-run."
  exit 0
fi
set -a && source "$ENV_FILE" && set +a

for var in ROOT_PASSWORD USERNAME USER_PASSWORD; do
  [[ -z "${!var}" ]] && error "$var is not set in $ENV_FILE"
done

info "Environment loaded:"
info "  USERNAME=$USERNAME"
info "  USER_FULLNAME=$USER_FULLNAME"
info "  SSH_KEY: $( [[ -n "$SSH_AUTHORIZED_KEY" ]] && echo "present" || echo "none" )"

# One more debug check before downloading
echo "DEBUG: Before ISO download, USE_DHCP=$USE_DHCP"

# Download Debian ISO if needed
ISO_ORIG="debian-12.10.0-amd64-netinst.iso"
ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$ISO_ORIG"
[[ -f "$ISO_ORIG" ]] || { info "Downloading $ISO_ORIG..."; wget "$ISO_URL"; }

# Prepare work dirs
WORK="debian-remaster"
rm -rf "$WORK"
mkdir -p "$WORK"/{iso,extracted}

# Mount and extract
info "Mounting ISO..."
mount -o loop "$ISO_ORIG" "$WORK/iso"
info "Copying files..."
cp -rT "$WORK/iso" "$WORK/extracted"
umount "$WORK/iso"

# Substitute secrets and network settings into preseed
info "Injecting configuration into preseed.cfg..."
TMP_PRESEED=$(mktemp)

if [[ "$USE_DHCP" == true ]]; then
  # Create a completely new preseed file for DHCP instead of modifying the existing one
  info "Creating DHCP-enabled preseed.cfg for testing"
  # Create a marker file to confirm DHCP mode was enabled
  echo "TEST_MODE=true" > .test_mode
  echo "USE_DHCP=true" >> .test_mode
  echo "Created $(date)" >> .test_mode
  
  # First, create a copy of the original preseed file
  cp "$PRESEED_PATH" "$TMP_PRESEED.orig"
  
  # Add extra eject and VM detection settings to ALL ISOs (not just DHCP ones)
  info "Adding enhanced auto-eject functionality to preseed"
  
  # Create a completely new network section with DHCP settings
  cat > "$TMP_PRESEED.network" << EOF
### Networking (DHCP Configuration - Test Mode)
d-i netcfg/enable                 boolean true
d-i netcfg/choose_interface       select  auto
d-i netcfg/use_dhcp               boolean true
d-i netcfg/disable_dhcp           boolean false
d-i netcfg/disable_autoconfig     boolean false
d-i netcfg/get_hostname           string  ${NETWORK_HOSTNAME}
d-i netcfg/get_domain             string  ${NETWORK_DOMAIN}
d-i netcfg/hostname               string  ${NETWORK_HOSTNAME}
# The following lines are explicitly omitted for DHCP mode:
# d-i netcfg/get_ipaddress
# d-i netcfg/get_netmask
# d-i netcfg/get_gateway
# d-i netcfg/get_nameservers
# d-i netcfg/confirm_static
EOF

  # Create a special QEMU CD ejection section for test mode only
  cat > "$TMP_PRESEED.eject" << 'EOF'

### Additional settings for QEMU test environment (DHCP version only)
# Add a stronger CD ejection mechanism for QEMU test mode
d-i preseed/late_command string \
  echo '#!/bin/sh' > /target/etc/rc.local && \
  echo '# Enhanced CD ejection for VM environments' >> /target/etc/rc.local && \
  echo 'if [ ! -f /var/lib/firstboot_done ]; then' >> /target/etc/rc.local && \
  echo '  echo "Attempting to eject installation media and disable boot device..."' >> /target/etc/rc.local && \
  echo '  eject -v /dev/sr0 2>/dev/null || true' >> /target/etc/rc.local && \
  echo '  eject -v /dev/cdrom 2>/dev/null || true' >> /target/etc/rc.local && \
  echo '  eject -v -s 2>/dev/null || true' >> /target/etc/rc.local && \
  echo '  # For QEMU/KVM specifically' >> /target/etc/rc.local && \
  echo '  if [ -d /sys/class/dmi/id ] && grep -q "QEMU" /sys/class/dmi/id/product_name 2>/dev/null; then' >> /target/etc/rc.local && \
  echo '    [ -x /usr/bin/qemu-ga ] && { echo "QEMU guest agent detected, using it to eject"; /usr/bin/qemu-ga eject; }' >> /target/etc/rc.local && \
  echo '  fi' >> /target/etc/rc.local && \
  echo '  # For VMware' >> /target/etc/rc.local && \
  echo '  if [ -d /sys/class/dmi/id ] && grep -q "VMware" /sys/class/dmi/id/product_name 2>/dev/null; then' >> /target/etc/rc.local && \
  echo '    [ -x /usr/bin/vmware-toolbox-cmd ] && { echo "VMware tools detected, using them to eject"; /usr/bin/vmware-toolbox-cmd cdrom eject; }' >> /target/etc/rc.local && \
  echo '  fi' >> /target/etc/rc.local && \
  echo '  # For VirtualBox' >> /target/etc/rc.local && \
  echo '  if [ -d /sys/class/dmi/id ] && grep -q "VirtualBox" /sys/class/dmi/id/product_name 2>/dev/null; then' >> /target/etc/rc.local && \
  echo '    [ -x /usr/bin/VBoxControl ] && { echo "VirtualBox tools detected, using them to eject"; /usr/bin/VBoxControl eject; }' >> /target/etc/rc.local && \
  echo '  fi' >> /target/etc/rc.local && \
  echo '  touch /var/lib/firstboot_done' >> /target/etc/rc.local && \
  echo 'fi' >> /target/etc/rc.local && \
  echo 'exit 0' >> /target/etc/rc.local && \
  chmod +x /target/etc/rc.local

# Skip the final installation prompt - eject and power off
d-i cdrom-detect/eject            boolean true
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/halt    boolean false
d-i debian-installer/exit/poweroff boolean true
d-i debian-installer/exit/reboot  boolean false
EOF

  # Extract everything before the network config section
  sed -n '1,/^### Networking/p' "$TMP_PRESEED.orig" | head -n -1 > "$TMP_PRESEED.part1"
  
  # Extract everything after the network config section, but before the finish section
  sed -n '/^### Mirror settings/,/^### Finish up/p' "$TMP_PRESEED.orig" > "$TMP_PRESEED.part2"
  
  # Extract the finish section (we'll replace parts of it)
  sed -n '/^### Finish up/,$p' "$TMP_PRESEED.orig" > "$TMP_PRESEED.part3"
  
  # Combine all parts with our new network section and eject section
  cat "$TMP_PRESEED.part1" "$TMP_PRESEED.network" "$TMP_PRESEED.part2" "$TMP_PRESEED.eject" > "$TMP_PRESEED.combined"
  
  # Apply template substitutions to the combined file
  sed \
    -e "s|\${rootpassword}|$(printf '%s' "$ROOT_PASSWORD" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${userfullname}|$(printf '%s' "$USER_FULLNAME" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${username}|$(printf '%s' "$USERNAME" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${userpassword}|$(printf '%s' "$USER_PASSWORD" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${ssh_authorized_key}|$(printf '%s' "$SSH_AUTHORIZED_KEY" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${packages}|$(printf '%s' "$PACKAGES" | sed 's|[&]|\\&|g')|g" \
    "$TMP_PRESEED.combined" > "$TMP_PRESEED"
  
  # Clean up temp files
  rm "$TMP_PRESEED.orig" "$TMP_PRESEED.network" "$TMP_PRESEED.part1" "$TMP_PRESEED.part2" "$TMP_PRESEED.combined"
  
  info "Using DHCP configuration for testing"
else
  # Use original static IP configuration
  sed \
    -e "s|\${rootpassword}|$(printf '%s' "$ROOT_PASSWORD" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${userfullname}|$(printf '%s' "$USER_FULLNAME" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${username}|$(printf '%s' "$USERNAME" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${userpassword}|$(printf '%s' "$USER_PASSWORD" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${ssh_authorized_key}|$(printf '%s' "$SSH_AUTHORIZED_KEY" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${network_hostname}|$(printf '%s' "$NETWORK_HOSTNAME" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${network_domain}|$(printf '%s' "$NETWORK_DOMAIN" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${network_ip}|$(printf '%s' "$NETWORK_IP" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${network_netmask}|$(printf '%s' "$NETWORK_NETMASK" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${network_gateway}|$(printf '%s' "$NETWORK_GATEWAY" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${network_dns}|$(printf '%s' "$NETWORK_DNS" | sed 's|[&]|\\&|g')|g" \
    -e "s|\${packages}|$(printf '%s' "$PACKAGES" | sed 's|[&]|\\&|g')|g" \
    "$PRESEED_PATH" > "$TMP_PRESEED"
fi
cp "$TMP_PRESEED" "$WORK/extracted/preseed.cfg"

# For verification only, check the preseed file
if [[ "$USE_DHCP" == true ]]; then
  # Temporarily save a copy for checking (will be cleaned up later)
  TEMP_PRESEED="/tmp/preseed-dhcp-check.cfg"
  cp "$TMP_PRESEED" "$TEMP_PRESEED"
  
  # Explicitly show the network configuration section
  echo "======= NETWORK CONFIGURATION IN PRESEED FILE ======="
  grep -A 10 "Networking" "$TMP_PRESEED"
  echo "===================================================="
  
  # Verify DHCP settings are applied with multiple checks
  if grep -q "netcfg/disable_dhcp.*boolean false" "$TMP_PRESEED" && 
     grep -q "netcfg/use_dhcp.*boolean true" "$TMP_PRESEED" && 
     ! grep -q "netcfg/confirm_static.*boolean true" "$TMP_PRESEED"; then
    info "Verified: DHCP is correctly enabled in preseed.cfg"
  else
    warn "WARNING: DHCP settings verification failed!"
    # Only in case of error, save a copy to the repo directory for troubleshooting
    cat "$TMP_PRESEED" > "preseed-dhcp-failed.cfg"
    warn "Saved problematic preseed file to preseed-dhcp-failed.cfg"
    warn "Continuing anyway, but the ISO may not work correctly."
  fi
  
  # Remove the temporary file
  rm -f "$TEMP_PRESEED"
fi

rm "$TMP_PRESEED"

# Update bootloader for fully automated boot
info "Configuring isolinux..."
ISOLINUX_CFG="$WORK/extracted/isolinux/isolinux.cfg"
sed -i 's/^timeout .*/timeout 0/; s/^prompt .*/prompt 0/; s/^default .*/default auto/' "$ISOLINUX_CFG"
cat > "$WORK/extracted/isolinux/txt.cfg" << 'EOF'
default auto
label auto
  menu default
  kernel /install.amd/vmlinuz
  append auto=true priority=critical noprompt preseed/file=/cdrom/preseed.cfg vga=788 initrd=/install.amd/initrd.gz quiet ---
EOF

info "Configuring GRUB..."
GRUB_CFG="$WORK/extracted/boot/grub/grub.cfg"
sed -i 's/set timeout=.*/set timeout=0/; s/set timeout_style=.*/set timeout_style=hidden/' "$GRUB_CFG"
cat > "${GRUB_CFG}.new" << 'EOF'
set default=0
set timeout=0
menuentry "Automated Install" {
  linux /install.amd/vmlinuz auto=true priority=critical noprompt preseed/file=/cdrom/preseed.cfg vga=788 quiet ---
  initrd /install.amd/initrd.gz
}
EOF
mv "${GRUB_CFG}.new" "$GRUB_CFG"

# Build new ISO
info "Building custom ISO..."
VERSION=$(echo "$ISO_ORIG" | grep -oP 'debian-\K[0-9.]+')
# Create ISO name
echo "DEBUG: Setting ISO name, USE_DHCP=$USE_DHCP"
if [[ "$USE_DHCP" == true ]]; then
  NEW_ISO="debian-${VERSION}-automated-${SELECTED_HOST}-dhcp.iso"
  info "Creating ISO with DHCP networking for testing: $NEW_ISO"
else
  NEW_ISO="debian-${VERSION}-automated-${SELECTED_HOST}.iso"
  info "Creating standard ISO with static networking: $NEW_ISO"
fi
# Confirm ISO name again right before creating it
if [[ "$USE_DHCP" == true ]]; then
  info "Confirming DHCP ISO name: $NEW_ISO"
  # Force the name to include -dhcp in case something went wrong
  if [[ "$NEW_ISO" != *"-dhcp.iso" ]]; then
    NEW_ISO="${NEW_ISO%.iso}-dhcp.iso"
    info "Fixed ISO name to ensure DHCP suffix: $NEW_ISO"
  fi
else
  info "Confirming standard ISO name: $NEW_ISO"
fi

xorriso -as mkisofs -r -J -joliet-long -l \
  -iso-level 3 \
  -partition_offset 16 \
  -V "DEBIAN AUTOINSTALL" \
  -b isolinux/isolinux.bin \
  -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -output "$NEW_ISO" \
  "$WORK/extracted"

# Set correct ownership of the ISO to the original user
chown "$ORIGINAL_UID:$ORIGINAL_GID" "$NEW_ISO"
success "ISO created: $NEW_ISO"
if [[ "$USE_DHCP" == true ]]; then
  info "This ISO is configured to use DHCP networking for testing environments"
fi

# ISO is created in the current directory
info "ISO file saved in current directory: $NEW_ISO"

# Cleanup
rm -rf "$WORK"