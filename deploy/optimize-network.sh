#!/bin/bash
# Network optimization for k3d cluster creation
# Addresses NIC/network-related timeout issues

set -euo pipefail

if [ "$EUID" -ne 0 ]; then 
    echo "This script must be run as root (use sudo)"
    exit 1
fi

echo "=== Network Optimization for k3d Clusters ==="
echo ""

# 1. Increase network buffer sizes
echo "1. Optimizing network buffer sizes..."
cat > /etc/sysctl.d/99-k3d-network.conf <<'EOF'
# Network buffer optimizations for k3d clusters
# Increase socket buffer sizes for better performance with many connections
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216

# Increase backlog for network connections
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 4096

# TCP optimizations
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# Increase connection tracking
net.netfilter.nf_conntrack_max = 262144

# Optimize for many small connections (k3s node registration)
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0

# Increase ARP cache
net.ipv4.neigh.default.gc_thresh1 = 2048
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh3 = 8192
EOF

# Apply settings immediately
sysctl -p /etc/sysctl.d/99-k3d-network.conf

echo "  ✓ Network buffers optimized"
echo ""

# 2. Optimize Docker network settings
echo "2. Optimizing Docker network settings..."
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
DOCKER_DAEMON_BACKUP="/etc/docker/daemon.json.backup.$(date +%Y%m%d_%H%M%S)"

if [ -f "$DOCKER_DAEMON_JSON" ]; then
    cp "$DOCKER_DAEMON_JSON" "$DOCKER_DAEMON_BACKUP"
    echo "  Backed up existing daemon.json"
fi

# Merge with existing config or create new
if [ -f "$DOCKER_DAEMON_JSON" ]; then
    python3 <<PYTHON_EOF
import json
import sys

try:
    with open("$DOCKER_DAEMON_JSON", 'r') as f:
        config = json.load(f)
except:
    config = {}

# Network optimizations
config.setdefault("default-ulimits", {})
config["default-ulimits"].setdefault("nofile", {
    "Name": "nofile",
    "Hard": 64000,
    "Soft": 64000
})

# Bridge network optimizations (removed - not supported in newer Docker)
# Docker handles bridge networks automatically, no manual config needed

# Logging
config.setdefault("log-driver", "json-file")
config.setdefault("log-opts", {})
config["log-opts"]["max-size"] = "10m"
config["log-opts"]["max-file"] = "3"

# Storage
config.setdefault("storage-driver", "overlay2")

# Network performance
config.setdefault("max-concurrent-downloads", 10)
config.setdefault("max-concurrent-uploads", 5)

with open("$DOCKER_DAEMON_JSON", 'w') as f:
    json.dump(config, f, indent=2)

print("✓ Docker daemon.json updated")
PYTHON_EOF
else
    cat > "$DOCKER_DAEMON_JSON" <<'EOF'
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
    echo "  ✓ Created Docker daemon.json"
fi

echo "  ✓ Docker network settings optimized"
echo ""

# 3. Optimize bridge network settings
echo "3. Optimizing bridge network settings..."
# Increase bridge netfilter queue length
modprobe br_netfilter 2>/dev/null || true
sysctl -w net.bridge.bridge-nf-call-iptables=1
sysctl -w net.bridge.bridge-nf-call-ip6tables=1

# Make bridge settings persistent
if ! grep -q "bridge-nf-call" /etc/sysctl.d/99-k3d-network.conf; then
    cat >> /etc/sysctl.d/99-k3d-network.conf <<'EOF'

# Bridge netfilter
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
fi

echo "  ✓ Bridge settings optimized"
echo ""

# 4. Load required kernel modules
echo "4. Loading required kernel modules..."
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
modprobe ip_vs 2>/dev/null || true
modprobe ip_vs_rr 2>/dev/null || true
modprobe ip_vs_wrr 2>/dev/null || true
modprobe ip_vs_sh 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

echo "  ✓ Kernel modules loaded"
echo ""

# 5. Restart Docker
echo "5. Restarting Docker to apply network settings..."
systemctl restart docker
sleep 2

echo "  ✓ Docker restarted"
echo ""

echo "=== Network Optimization Complete ==="
echo ""
echo "Applied optimizations:"
echo "  ✓ Increased network buffer sizes (128MB)"
echo "  ✓ Increased connection backlog (5000)"
echo "  ✓ Optimized TCP settings for many connections"
echo "  ✓ Increased connection tracking (262k)"
echo "  ✓ Optimized Docker network settings"
echo "  ✓ Loaded required kernel modules"
echo ""
echo "These settings will persist across reboots."
echo ""
echo "Next: Run cluster setup with network delays:"
echo "  ./deploy/multi-cluster-setup.sh"

