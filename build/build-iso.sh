#!/usr/bin/env bash
set -euo pipefail

# Check if running as root/sudo
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Restarting with sudo..."
    exec sudo "$0" "$@"
    exit 1  # This line should never execute
fi

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

# Silently check for required packages
required_packages=(wget xorriso isolinux syslinux-common syslinux-utils)
missing_packages=()

# Check invisibly if packages are installed without displaying output
for pkg in "${required_packages[@]}"; do
  if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
    missing_packages+=("$pkg")
  fi
done

# Silently install missing packages if any
if [[ ${#missing_packages[@]} -gt 0 ]]; then
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq "${missing_packages[@]}" >/dev/null 2>&1
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
NETWORK_HOSTNAME=your-hostname
NETWORK_DOMAIN=home.arpa
NETWORK_IP=192.168.1.2
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
info "  IP=$NETWORK_IP"
info "  NETMASK=$NETWORK_NETMASK"
info "  GATEWAY=$NETWORK_GATEWAY"
info "  DNS=$NETWORK_DNS"

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

# Apply template substitutions
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

cp "$TMP_PRESEED" "$WORK/extracted/preseed.cfg"

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
NEW_ISO="debian-${VERSION}-automated-${SELECTED_HOST}.iso"
info "Creating ISO: $NEW_ISO"

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

# ISO is created in the current directory
info "ISO file saved in current directory: $NEW_ISO"

# Cleanup
rm -rf "$WORK"

# Move ISO if ISO_MOVE is defined
if [[ -n "${ISO_MOVE:-}" ]]; then
  info "Moving ISO using configured command..."
  eval "$ISO_MOVE"
  success "ISO moved successfully using custom command"
fi
