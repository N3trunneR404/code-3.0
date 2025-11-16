#!/bin/bash
# Set Docker container resource limits for k3d nodes
# This helps prevent timeouts by giving containers more resources

set -euo pipefail

echo "=== Setting Docker Resource Limits ==="
echo ""

# Function to update container resources
update_container_resources() {
    local container_name="$1"
    local cpu_limit="$2"
    local memory_limit="$3"
    
    if docker inspect "$container_name" >/dev/null 2>&1; then
        echo "  Updating $container_name: ${cpu_limit} CPUs, ${memory_limit}GB RAM"
        docker update --cpus="${cpu_limit}" --memory="${memory_limit}g" "$container_name" 2>/dev/null || true
    fi
}

# Update existing k3d containers with more resources
echo "Updating existing k3d containers..."
for container in $(docker ps -a --filter "name=k3d" --format "{{.Names}}"); do
    if [[ "$container" == *"server"* ]]; then
        # Servers get more resources: 2 CPUs, 4GB RAM
        update_container_resources "$container" "2.0" "4"
    elif [[ "$container" == *"agent"* ]]; then
        # Agents get: 1.5 CPUs, 3GB RAM
        update_container_resources "$container" "1.5" "3"
    elif [[ "$container" == *"tools"* ]] || [[ "$container" == *"serverlb"* ]]; then
        # Tools and loadbalancers get: 0.5 CPUs, 1GB RAM
        update_container_resources "$container" "0.5" "1"
    fi
done

echo ""
echo "✓ Resource limits updated for existing containers"
echo ""
echo "Note: New containers created by k3d will need to be updated manually"
echo "or you can use Docker's default resource limits in daemon.json"

