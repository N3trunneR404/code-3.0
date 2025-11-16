#!/bin/bash
# Increase swap to 16GB to prevent OOM during cluster creation
# Run with: sudo ./deploy/increase-swap.sh

set -euo pipefail

if [ "$EUID" -ne 0 ]; then 
    echo "This script must be run as root (use sudo)"
    exit 1
fi

SWAPFILE="/swapfile"
SWAP_SIZE="8G"  # Add 8GB to existing 8GB = 16GB total
CURRENT_SWAP=$(free -g | grep Swap | awk '{print $2}')

echo "=== Increasing Swap ==="
echo "Current swap: ${CURRENT_SWAP}GB"
echo "Adding ${SWAP_SIZE} swap file..."
echo ""

# Check if swapfile already exists
if [ -f "$SWAPFILE" ]; then
    echo "⚠ Swap file $SWAPFILE already exists"
    read -p "Remove and recreate? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        swapoff "$SWAPFILE" 2>/dev/null || true
        rm -f "$SWAPFILE"
    else
        echo "Aborted"
        exit 1
    fi
fi

# Create swap file
echo "Creating ${SWAP_SIZE} swap file..."
fallocate -l "$SWAP_SIZE" "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1M count=8192
chmod 600 "$SWAPFILE"

# Format as swap
echo "Formatting as swap..."
mkswap "$SWAPFILE"

# Enable swap
echo "Enabling swap..."
swapon "$SWAPFILE"

# Make permanent
if ! grep -q "$SWAPFILE" /etc/fstab; then
    echo "Adding to /etc/fstab..."
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
fi

# Set swappiness (how aggressively to use swap)
# 10 = use swap only when necessary, 60 = default, 100 = aggressive
echo "Setting swappiness to 10 (conservative)..."
sysctl vm.swappiness=10
if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
    echo "vm.swappiness=10" >> /etc/sysctl.conf
fi

echo ""
echo "✓ Swap increased successfully!"
echo "New swap total: $(free -g | grep Swap | awk '{print $2}')GB"
echo ""

