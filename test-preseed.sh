#!/usr/bin/env bash
set -euo pipefail

# Parse arguments
BOOT_FROM_DISK=false

for arg in "$@"; do
  case $arg in
    --disk)
      BOOT_FROM_DISK=true
      shift
      echo "Boot mode: Starting from hard disk (skipping ISO)"
      ;;
    *)
      # Unknown option
      ;;
  esac
done

# If not booting from disk, look for a suitable ISO
if [[ "$BOOT_FROM_DISK" == false ]]; then
  # Look for DHCP ISO first (preferred for testing), then fall back to normal ISO
  ISO_FILE=$(find . -maxdepth 1 -name "debian-*-automated-*-dhcp.iso" | sort -r | head -n 1)
  if [[ -n "$ISO_FILE" ]]; then
      echo "Found DHCP-enabled ISO: $ISO_FILE"
      echo "This ISO is configured for automated testing with DHCP networking."
      echo "After installation, the system will automatically boot from disk."
      USE_DHCP=true
  else
      ISO_FILE=$(find . -maxdepth 1 -name "debian-*-automated-*.iso" | sort -r | head -n 1)
      if [[ -z "$ISO_FILE" ]]; then
          echo "No Debian automated ISO found. Please run build-iso.sh first."
          echo "For better connectivity in WSL2/VM environment, run: ./build-iso.sh --test"
          exit 1
      fi
      echo "WARNING: Using standard ISO with static IP. This may cause network issues in WSL2."
      echo "For better connectivity in testing, run: ./build-iso.sh --test"
      USE_DHCP=false
  fi
else
  # No ISO needed if booting from disk
  ISO_FILE=""
  USE_DHCP=true  # Assume DHCP when booting from disk for simplicity
fi

VM_NAME="debian-test"
MEMORY=8192 # Increased RAM
CPU_CORES=4
DISK_SIZE=20G
DISK_PATH="${VM_NAME}.qcow2"
SSH_PORT=2222

# Check for KVM support (for acceleration)
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    USE_KVM=true
    echo "KVM acceleration available, using it for better performance."
else
    USE_KVM=false
    echo "WARNING: KVM acceleration not available. VM will be much slower."
    echo "To enable KVM in WSL2, you need to:"
    echo "  1. Ensure virtualization is enabled in BIOS"
    echo "  2. Add 'nestedVirtualization=true' to .wslconfig file in Windows"
    echo "  3. Restart WSL with: wsl --shutdown"
    
    # Optimize for non-KVM environment
    echo "Optimizing for non-KVM environment..."
    CPU_CORES=2 # Reduce core count for better emulation performance
fi

echo "Using ISO: $ISO_FILE"

# Create disk if it doesn't exist or check if we should boot from disk
if [[ ! -f "$DISK_PATH" ]]; then
    echo "Creating disk image: $DISK_PATH"
    qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE"
    BOOT_FROM_DISK=false
else
    # Check if disk is larger than 500MB (indicating it has an OS installed)
    DISK_SIZE_BYTES=$(stat -c%s "$DISK_PATH")
    DISK_SIZE_MB=$((DISK_SIZE_BYTES / 1024 / 1024))
    echo "Existing disk detected: $DISK_PATH ($DISK_SIZE_MB MB)"
    
    if [[ $DISK_SIZE_MB -gt 500 ]]; then
        echo "Disk appears to have an OS installed (>500MB). Booting from disk."
        BOOT_FROM_DISK=true
    else
        echo "Disk appears to be empty (<500MB). Will boot from ISO."
        BOOT_FROM_DISK=false
    fi
fi

# Run QEMU with user networking (easier in WSL2)
echo "Starting VM with $MEMORY MB memory, $CPU_CORES cores, and user networking..."
echo "The VM will be accessible via port forward on localhost:$SSH_PORT"
echo "Once installed, you can SSH to the VM using: ssh -p $SSH_PORT <username>@localhost"
# Define QEMU acceleration based on KVM availability
ACCEL_OPTS=""
if [ "$USE_KVM" = true ]; then
    ACCEL_OPTS="-cpu host -accel kvm"
    SMP_OPTS="-smp cores=$CPU_CORES,threads=2"
else
    # Without KVM, optimize for TCG performance
    ACCEL_OPTS="-cpu qemu64"
    SMP_OPTS="-smp $CPU_CORES"
fi

echo "Starting VM with TCG acceleration optimizations..."

# DHCP network setup message
if [[ "$USE_DHCP" == true ]]; then
    echo "Using DHCP networking configuration for better compatibility with WSL2"
else
    echo "Using standard networking. If you experience networking issues, try using a DHCP ISO."
fi

# Configure boot options based on mode
if [[ "$BOOT_FROM_DISK" == true ]]; then
    # Boot from existing hard disk (skipping ISO)
    ISO_OPTS=""
    BOOT_OPTS="-boot c"  # Boot from first hard disk
    echo "=========================================================="
    echo "BOOTING FROM EXISTING INSTALLATION"
    echo "--------------------------------------------------------"
    echo "Starting VM from the installed system on the disk"
    echo "=========================================================="
else
    # Boot from ISO for installation
    ISO_OPTS="-cdrom \"$ISO_FILE\""
    BOOT_OPTS="-boot d"  # Boot from CD-ROM first
    echo "=========================================================="
    echo "INSTALLATION MODE: Booting from ISO"
    echo "--------------------------------------------------------"
    echo "The VM will install Debian to the disk."
    echo "After installation, the machine will power off automatically."
    echo "Then run this script again to boot from the disk."
    echo "=========================================================="
fi

# Launch QEMU with appropriate options
eval qemu-system-x86_64 \
    -m "$MEMORY" \
    $SMP_OPTS \
    $ACCEL_OPTS \
    -drive file="$DISK_PATH",format=qcow2,cache=writeback \
    $ISO_OPTS \
    $BOOT_OPTS \
    -device e1000,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22,net=192.168.1.0/24,dhcpstart=192.168.1.100 \
    -display gtk \
    -name "$VM_NAME" \
    -no-hpet

echo "VM has been shut down."