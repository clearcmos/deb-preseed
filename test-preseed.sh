#!/usr/bin/env bash
set -euo pipefail

# Configuration
ISO_FILE=$(find . -maxdepth 1 -name "debian-*-automated-*.iso" | sort -r | head -n 1)
if [[ -z "$ISO_FILE" ]]; then
    echo "No Debian automated ISO found. Please run build-iso.sh first."
    exit 1
fi

VM_NAME="debian-test"
MEMORY=2048
DISK_SIZE=20G
DISK_PATH="${VM_NAME}.qcow2"
SSH_PORT=2222

echo "Using ISO: $ISO_FILE"

# Create disk if it doesn't exist
if [[ ! -f "$DISK_PATH" ]]; then
    echo "Creating disk image: $DISK_PATH"
    qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE"
fi

# Run QEMU with GUI and port forwarding for SSH
echo "Starting VM with $MEMORY MB memory..."
echo "Once installed, you can SSH to the VM with: ssh -p $SSH_PORT username@localhost"
qemu-system-x86_64 \
    -m "$MEMORY" \
    -drive file="$DISK_PATH",format=qcow2 \
    -cdrom "$ISO_FILE" \
    -boot d \
    -device virtio-net,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
    -name "$VM_NAME"

echo "VM has been shut down."