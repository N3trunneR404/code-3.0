#!/bin/bash
# Fix Docker daemon.json configuration
# Run with: sudo ./deploy/fix-docker-config.sh

set -euo pipefail

if [ "$EUID" -ne 0 ]; then 
    echo "This script must be run as root (use sudo)"
    exit 1
fi

DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
BACKUP_FILE="/etc/docker/daemon.json.backup.20251116_080220"

echo "=== Fixing Docker Configuration ==="
echo ""

# Check if backup exists
if [ -f "$BACKUP_FILE" ]; then
    echo "1. Restoring from backup..."
    cp "$BACKUP_FILE" "$DOCKER_DAEMON_JSON"
    echo "   ✓ Restored backup"
else
    echo "1. No backup found, creating minimal config..."
    # Create a minimal valid daemon.json
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
    echo "   ✓ Created minimal config"
fi

echo ""

# Validate JSON syntax
echo "2. Validating JSON syntax..."
if python3 -m json.tool "$DOCKER_DAEMON_JSON" > /dev/null 2>&1; then
    echo "   ✓ JSON is valid"
else
    echo "   ✗ JSON is invalid, creating minimal config..."
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
  "storage-driver": "overlay2"
}
EOF
    echo "   ✓ Created minimal valid config"
fi

echo ""

# Try to start Docker
echo "3. Starting Docker..."
if systemctl start docker; then
    echo "   ✓ Docker started successfully"
    sleep 2
    if systemctl is-active --quiet docker; then
        echo "   ✓ Docker is running"
    else
        echo "   ⚠ Docker started but may have issues"
    fi
else
    echo "   ✗ Failed to start Docker"
    echo ""
    echo "Checking Docker logs..."
    journalctl -xeu docker.service --no-pager -n 20
    exit 1
fi

echo ""
echo "=== Docker Configuration Fixed ==="
echo ""
echo "Current daemon.json:"
cat "$DOCKER_DAEMON_JSON"
echo ""
echo ""
echo "Docker status:"
systemctl status docker.service --no-pager -l | head -10

