# Resource Optimization Guide for k3d Clusters

This guide helps you allocate maximum resources to k3d clusters while keeping some for browsing/multitasking.

## System Specs
- **CPU**: AMD Ryzen 9 9900X (12 cores, 24 threads, max 5.66 GHz)
- **RAM**: 59 GB total
- **GPU**: RTX 5060 Ti 16GB
- **Current Swap**: 8 GB

## Quick Start

### 1. Run System Optimization
```bash
sudo ./deploy/optimize-system.sh
```

### 2. Increase Swap (Recommended)
```bash
sudo ./deploy/increase-swap.sh
```
This increases swap from 8GB to 16GB to prevent OOM during cluster creation.

### 3. Restart Docker
```bash
sudo systemctl restart docker
```

### 4. Run Cluster Setup
```bash
./deploy/multi-cluster-setup.sh
```

## Manual Optimizations

### CPU Governor (Already Set)
Your CPU governor is already set to `performance` mode, which is optimal.

### Increase Swap Manually
If the script doesn't work, manually:
```bash
sudo fallocate -l 8G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo sysctl vm.swappiness=10
echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf
```

### Docker Resource Allocation
Docker can use all available resources by default. To limit (optional):
1. Edit `/etc/docker/daemon.json`:
```json
{
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  }
}
```
2. Restart Docker: `sudo systemctl restart docker`

### Update Existing Container Resources
After clusters are created, you can update resource limits:
```bash
./deploy/docker-resource-limits.sh
```

Or manually for specific containers:
```bash
# Server nodes: 2 CPUs, 4GB RAM
docker update --cpus="2.0" --memory="4g" k3d-<cluster>-server-0

# Agent nodes: 1.5 CPUs, 3GB RAM  
docker update --cpus="1.5" --memory="3g" k3d-<cluster>-agent-0
```

## Resource Allocation Strategy

### Recommended Allocation
- **k3d Clusters**: ~40-45 GB RAM, 18-20 CPUs
- **System/Browsing**: ~14-19 GB RAM, 4 CPUs
- **Swap**: 16 GB total

### Per Cluster Resources
With 7 clusters and ~24 total nodes:
- **Servers** (7 nodes): 2 CPUs, 4GB RAM each = 14 CPUs, 28GB RAM
- **Agents** (24 nodes): 1.5 CPUs, 3GB RAM each = 36 CPUs, 72GB RAM
- **Total**: 50 CPUs (overcommitted), 100GB RAM (overcommitted)

**Note**: Docker allows CPU overcommitment, and RAM is shared. Actual usage will be lower.

## Troubleshooting

### Timeout Issues
1. Check system resources: `htop` or `docker stats`
2. Increase timeout in `multi-cluster-setup.sh` (already set to 600s)
3. Create clusters one at a time if needed

### OOM (Out of Memory) Issues
1. Increase swap: `sudo ./deploy/increase-swap.sh`
2. Reduce number of concurrent cluster creations
3. Check memory usage: `free -h` and `docker stats`

### Slow Node Startup
1. Ensure CPU governor is `performance`: `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`
2. Check Docker daemon is running: `sudo systemctl status docker`
3. Monitor during creation: `watch docker stats`

## Monitoring

### Check Resource Usage
```bash
# System resources
htop
free -h
docker stats

# k3d cluster status
k3d cluster list
kubectl get nodes -o wide
```

### Check Container Resources
```bash
docker inspect <container-name> | grep -A 10 "Resources"
```

## Performance Tips

1. **Create clusters sequentially** (already done in script)
2. **Pre-create networks** (already done in script)
3. **Use performance CPU governor** (already set)
4. **Increase swap** to prevent OOM
5. **Monitor during creation** to catch issues early

