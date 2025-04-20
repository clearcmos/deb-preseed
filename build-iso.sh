#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

# Check if preseed.cfg exists in the root directory
PRESEED_PATH="preseed.cfg"
if [[ ! -f "$PRESEED_PATH" ]]; then
  error "preseed.cfg not found in the root directory"
fi

info "Using preseed file: $PRESEED_PATH"

# Load .preseed-env
ENV_FILE="secrets/.preseed-env"
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
sudo mount -o loop "$ISO_ORIG" "$WORK/iso"
info "Copying files..."
sudo cp -rT "$WORK/iso" "$WORK/extracted"
sudo umount "$WORK/iso"

# Substitute secrets into preseed
info "Injecting secrets into preseed.cfg..."
TMP_PRESEED=$(mktemp)
sed \
  -e "s|\${rootpassword}|$(printf '%s' "$ROOT_PASSWORD" | sed 's|[&]|\\&|g')|g" \
  -e "s|\${userfullname}|$(printf '%s' "$USER_FULLNAME" | sed 's|[&]|\\&|g')|g" \
  -e "s|\${username}|$(printf '%s' "$USERNAME" | sed 's|[&]|\\&|g')|g" \
  -e "s|\${userpassword}|$(printf '%s' "$USER_PASSWORD" | sed 's|[&]|\\&|g')|g" \
  -e "s|\${ssh_authorized_key}|$(printf '%s' "$SSH_AUTHORIZED_KEY" | sed 's|[&]|\\&|g')|g" \
  "$PRESEED_PATH" > "$TMP_PRESEED"
sudo cp "$TMP_PRESEED" "$WORK/extracted/preseed.cfg"
rm "$TMP_PRESEED"

# Update bootloader for fully automated boot
info "Configuring isolinux..."
ISOLINUX_CFG="$WORK/extracted/isolinux/isolinux.cfg"
sudo sed -i 's/^timeout .*/timeout 0/; s/^prompt .*/prompt 0/; s/^default .*/default auto/' "$ISOLINUX_CFG"
sudo bash -c "cat > $WORK/extracted/isolinux/txt.cfg << 'EOF'
default auto
label auto
  menu default
  kernel /install.amd/vmlinuz
  append auto=true priority=critical noprompt preseed/file=/cdrom/preseed.cfg vga=788 initrd=/install.amd/initrd.gz quiet ---
EOF"

info "Configuring GRUB..."
GRUB_CFG="$WORK/extracted/boot/grub/grub.cfg"
sudo sed -i 's/set timeout=.*/set timeout=0/; s/set timeout_style=.*/set timeout_style=hidden/' "$GRUB_CFG"
sudo bash -c "cat > ${GRUB_CFG}.new << 'EOF'
set default=0
set timeout=0
menuentry \"Automated Install\" {
  linux /install.amd/vmlinuz auto=true priority=critical noprompt preseed/file=/cdrom/preseed.cfg vga=788 quiet ---
  initrd /install.amd/initrd.gz
}
EOF"
sudo mv "${GRUB_CFG}.new" "$GRUB_CFG"

# Build new ISO
info "Building custom ISO..."
VERSION=$(echo "$ISO_ORIG" | grep -oP 'debian-\K[0-9.]+')
NEW_ISO="debian-${VERSION}-automated-misc.iso"
sudo xorriso -as mkisofs -r -J -joliet-long -l \
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

sudo chown "$(id -u):$(id -g)" "$NEW_ISO"
success "ISO created: $NEW_ISO"

# Optional: move it
if [[ -n "$ISO_MOVE" ]]; then
  info "Moving ISO to destination..."
  if eval "$ISO_MOVE"; then
    success "ISO moved successfully"
  else
    warn "Failed to move ISO to destination"
  fi
fi

# Cleanup
rm -rf "$WORK"
