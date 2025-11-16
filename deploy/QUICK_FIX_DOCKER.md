# Quick Fix for Docker Configuration Issue

## Problem
Docker failed to start after network optimization because `daemon.json` contains unsupported `bridge` configuration.

## Solution

Run this command to fix Docker:

```bash
sudo ./deploy/fix-docker-config.sh
```

Or manually:

```bash
# 1. Restore from backup
sudo cp /etc/docker/daemon.json.backup.20251116_080220 /etc/docker/daemon.json

# 2. Remove the problematic bridge section
sudo python3 <<'EOF'
import json
with open('/etc/docker/daemon.json', 'r') as f:
    config = json.load(f)

# Remove bridge section if it exists
if 'bridge' in config:
    del config['bridge']

with open('/etc/docker/daemon.json', 'w') as f:
    json.dump(config, f, indent=2)
EOF

# 3. Start Docker
sudo systemctl start docker
sudo systemctl status docker
```

## What Happened

The `optimize-network.sh` script tried to add bridge network settings that aren't supported in newer Docker versions. The `bridge` section with `fixed-cidr-v6: ""` caused Docker to fail to start.

## After Fixing

Once Docker is running again, you can:
1. Apply network optimizations (without bridge config): The sysctl settings are still applied
2. Run cluster setup: `./deploy/multi-cluster-setup.sh`

The network buffer optimizations (sysctl) are still active and don't require Docker to be running.

