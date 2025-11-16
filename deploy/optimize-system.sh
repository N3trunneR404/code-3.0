#!/bin/bash
# System optimization script for k3d cluster creation
# Allocates maximum resources while leaving some for browsing/multitasking

set -euo pipefail

echo "=== System Optimization for k3d Clusters ==="
echo ""

# Check if running as root for system-level changes
if [ "$EUID" -ne 0 ]; then 
    echo "⚠ Some operations require root. Run with sudo for full optimization."
    echo ""
fi

# 1. Configure Docker daemon with resource limits
echo "1. Configuring Docker daemon..."
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
DOCKER_DAEMON_BACKUP="/etc/docker/daemon.json.backup.$(date +%Y%m%d_%H%M%S)"

if [ -f "$DOCKER_DAEMON_JSON" ]; then
    echo "  Backing up existing daemon.json..."
    sudo cp "$DOCKER_DAEMON_JSON" "$DOCKER_DAEMON_BACKUP"
fi

# Allocate 20 CPUs (leave 4 for system/browsing) and 48GB RAM (leave ~11GB for system)
sudo tee "$DOCKER_DAEMON_JSON" > /dev/null <<EOF
{
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  },
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 5
}
EOF

echo "  ✓ Docker daemon configured"
echo "  Note: CPU/Memory limits are set per-container, not globally in Docker"
echo ""

# 2. Check and increase swap if needed
echo "2. Checking swap configuration..."
CURRENT_SWAP=$(free -g | grep Swap | awk '{print $2}')
DESIRED_SWAP=16  # 16GB swap

if [ "$CURRENT_SWAP" -lt "$DESIRED_SWAP" ]; then
    echo "  Current swap: ${CURRENT_SWAP}GB, desired: ${DESIRED_SWAP}GB"
    echo "  ⚠ To increase swap, you'll need to:"
    echo "    1. Create a swap file: sudo fallocate -l 8G /swapfile"
    echo "    2. Set permissions: sudo chmod 600 /swapfile"
    echo "    3. Format as swap: sudo mkswap /swapfile"
    echo "    4. Enable: sudo swapon /swapfile"
    echo "    5. Make permanent: echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab"
    echo ""
else
    echo "  ✓ Swap is sufficient: ${CURRENT_SWAP}GB"
    echo ""
fi

# 3. Set CPU governor to performance (if not already)
echo "3. Checking CPU governor..."
if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    CURRENT_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
    if [ "$CURRENT_GOV" != "performance" ]; then
        echo "  Current governor: $CURRENT_GOV"
        echo "  ⚠ To set to performance mode:"
        echo "    sudo cpupower frequency-set -g performance"
        echo "    Or: echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
        echo ""
    else
        echo "  ✓ CPU governor already set to performance"
        echo ""
    fi
else
    echo "  ⚠ Cannot check CPU governor (may not be available)"
    echo ""
fi

# 4. Set system limits
echo "4. Setting system resource limits..."
if [ "$EUID" -eq 0 ]; then
    # Increase file descriptor limits
    cat >> /etc/security/limits.conf <<EOF
* soft nofile 65536
* hard nofile 65536
* soft nproc 32768
* hard nproc 32768
EOF
    echo "  ✓ System limits updated"
else
    echo "  ⚠ Run with sudo to update system limits"
fi
echo ""

# 5. Restart Docker if daemon.json was modified
if [ -f "$DOCKER_DAEMON_JSON" ] && [ -f "$DOCKER_DAEMON_BACKUP" ]; then
    echo "5. Docker daemon configuration updated."
    echo "  ⚠ You may need to restart Docker:"
    echo "    sudo systemctl restart docker"
    echo ""
fi

echo "=== Optimization Complete ==="
echo ""
echo "Summary:"
echo "  - Docker: Configured for better performance"
echo "  - CPU: Performance governor (check above)"
echo "  - Swap: ${CURRENT_SWAP}GB (consider increasing to ${DESIRED_SWAP}GB if needed)"
echo "  - System limits: Updated (if run with sudo)"
echo ""
echo "Next steps:"
echo "  1. Restart Docker: sudo systemctl restart docker"
echo "  2. Increase swap if needed (see instructions above)"
echo "  3. Run cluster setup: ./deploy/multi-cluster-setup.sh"

