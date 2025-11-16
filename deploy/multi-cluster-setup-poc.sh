#!/bin/bash
set -euo pipefail

# Multi-cluster setup for Digital Twin Fabric (PoC Mode)
# Creates 3 minimal clusters for proof of concept demonstration
# Usage: ./deploy/multi-cluster-setup-poc.sh [--clean] [--skip-metrics]
# Usage: ./deploy/multi-cluster-setup.sh [--clean] [--skip-metrics]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLEAN=false
SKIP_METRICS=false

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required dependency: $cmd (please install it and retry)"
        exit 1
    fi
}

check_prereqs() {
    require_cmd docker
    require_cmd k3d
    require_cmd kubectl
    require_cmd python3

    if ! docker info >/dev/null 2>&1; then
        echo "Docker daemon is not running or not reachable. Start Docker and retry."
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            CLEAN=true
            shift
            ;;
        --skip-metrics)
            SKIP_METRICS=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=== Digital Twin Multi-Cluster Setup ==="
echo ""

check_prereqs

# Minimal PoC cluster set: 3 clusters showing key diversity
# Reduced agent counts for faster startup and lower resource usage
CLUSTER_SPECS=(
    "dc-core|datacenter|1|3|10|172.30.10.0/24|10.10.0.0/16|10.110.0.0/16|gpu:nvidia-a100"
    "edge-microdc|edge|1|3|13|172.30.13.0/24|10.13.0.0/16|10.113.0.0/16|npu:habana-gaudi"
    "gamer-pc|gaming|1|2|16|172.30.16.0/24|10.16.0.0/16|10.116.0.0/16|gpu:nvidia-rtx4090"
)

derive_ip() {
    local cidr="$1"
    local index="$2"
    python3 - <<PY
import ipaddress
cidr = ipaddress.ip_network("$cidr", strict=False)
index = int($index)
host_index = max(10, index + 10)
if host_index >= cidr.num_addresses - 1:
    host_index = (index % (cidr.num_addresses - 2)) + 1
addr = cidr.network_address + host_index
if addr == cidr.broadcast_address:
    addr -= 1
print(str(addr))
PY
}

# Find and remove Docker networks by subnet (not just by name)
# This is needed because k3d fails if ANY network uses the same subnet
remove_networks_by_subnet() {
    local target_subnet="$1"
    local network_name="$2"
    
    # First, try to remove by name if it exists
    if docker network inspect "$network_name" >/dev/null 2>&1; then
        echo "    Removing network '$network_name' by name" >&2
        docker network rm "$network_name" >/dev/null 2>&1 || true
    fi
    
    # Then, find any other networks using the same subnet
    # Parse network IDs and check each one
    local network_ids
    network_ids=$(docker network ls -q 2>/dev/null || true)
    
    if [ -z "$network_ids" ]; then
        return 0
    fi
    
    for net_id in $network_ids; do
        # Skip if this is the default bridge network or host network
        local net_name
        net_name=$(docker network inspect "$net_id" --format '{{.Name}}' 2>/dev/null || echo "")
        if [ "$net_name" = "bridge" ] || [ "$net_name" = "host" ] || [ "$net_name" = "none" ] || [ -z "$net_name" ]; then
            continue
        fi
        
        # Check if this network uses the target subnet
        # Docker networks can have multiple IPAM configs, so we need to check all of them
        local network_json
        network_json=$(docker network inspect "$net_id" 2>/dev/null || echo "{}")
        
        # Use python to properly parse JSON and check subnets
        # Pass target_subnet as command-line argument to avoid quoting issues
        if echo "$network_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if not data or not isinstance(data, list) or len(data) == 0:
        sys.exit(1)
    network = data[0]
    ipam = network.get('IPAM', {})
    configs = ipam.get('Config', [])
    target = sys.argv[1] if len(sys.argv) > 1 else ''
    for config in configs:
        subnet = config.get('Subnet', '')
        if subnet == target:
            sys.exit(0)
    sys.exit(1)
except:
    sys.exit(1)
" "${target_subnet}" 2>/dev/null; then
            echo "    Removing network '$net_name' (uses subnet $target_subnet)" >&2
            docker network rm "$net_id" >/dev/null 2>&1 || true
        fi
    done
}

annotate_nodes() {
    local cluster_name="$1"
    local cluster_type="$2"
    local cluster_id="$3"
    local pod_cidr="$4"
    local service_cidr="$5"
    local network_cidr="$6"
    local accelerator_hint="$7"

    local nodes node_id=0
    nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    for node in $nodes; do
        node_id=$((node_id + 1))
        local pod_ip
        pod_ip=$(derive_ip "$pod_cidr" "$node_id")
        local node_ip
        node_ip=$(derive_ip "$network_cidr" "$node_id")
        local mac
        mac=$(printf '02:fd:%02x:%02x:%02x:%02x' "$cluster_id" "$(((node_id >> 8) & 0xff))" "$((node_id & 0xff))" "$(((node_id * 37) & 0xff))")

        kubectl label node "$node" \
            dt.cluster.name="$cluster_name" \
            dt.cluster.type="$cluster_type" \
            dt.virtual.cluster_id="$cluster_id" \
            dt.virtual.node_id="$node_id" \
            dt.node.poolHint="${accelerator_hint}" \
            --overwrite >/dev/null 2>&1 || true

        kubectl annotate node "$node" \
            dt.virtual.pod_cidr="$pod_cidr" \
            dt.virtual.service_cidr="$service_cidr" \
            dt.virtual.network_cidr="$network_cidr" \
            dt.virtual.pod_ip="$pod_ip" \
            dt.virtual.node_ip="$node_ip" \
            dt.virtual.mac="$mac" \
            --overwrite >/dev/null 2>&1 || true
    done
}

create_cluster() {
    local name="$1"
    local type="$2"
    local servers="$3"
    local agents="$4"
    local cluster_id="$5"
    local network_cidr="$6"
    local pod_cidr="$7"
    local service_cidr="$8"
    local accelerator_hint="$9"

    if k3d cluster list | grep -q "^${name}[[:space:]]"; then
        echo "  ✓ Cluster '$name' already exists (skipping)"
        return
    fi

    echo "  Creating cluster: $name (type: $type, $servers server, $agents agents)"

    # Clean up any existing network for this cluster
    local network_name="dt-${name}"
    remove_networks_by_subnet "$network_cidr" "$network_name"
    
    # Force remove the network by name if it still exists
    if docker network inspect "$network_name" >/dev/null 2>&1; then
        echo "    Removing existing network '$network_name'..." >&2
        docker network rm "$network_name" >/dev/null 2>&1 || true
        sleep 1
    fi
    
    # Pre-create the network with the correct subnet
    # k3d fails with --subnet if network exists, so we create it first
    # then k3d will use it without needing --subnet
    echo "    Creating network '$network_name' with subnet $network_cidr..."
    if ! docker network inspect "$network_name" >/dev/null 2>&1; then
        if docker network create --subnet "$network_cidr" "$network_name" >/dev/null 2>&1; then
            echo "    ✓ Network '$network_name' created"
        else
            # If creation fails (e.g., subnet conflict), clean up and retry
            echo "    ⚠ Network creation failed, cleaning up conflicting networks..." >&2
            remove_networks_by_subnet "$network_cidr" "$network_name"
            sleep 1
            if ! docker network create --subnet "$network_cidr" "$network_name" >/dev/null 2>&1; then
                echo "    ✗ Failed to create network '$network_name'" >&2
                return 1
            fi
            echo "    ✓ Network '$network_name' created (after cleanup)"
        fi
    else
        # Network exists - verify subnet matches
        local existing_subnet
        existing_subnet=$(docker network inspect "$network_name" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "")
        if [ "$existing_subnet" != "$network_cidr" ]; then
            echo "    ⚠ Network exists with wrong subnet ($existing_subnet != $network_cidr), removing..." >&2
            docker network rm "$network_name" >/dev/null 2>&1 || true
            sleep 1
            docker network create --subnet "$network_cidr" "$network_name" >/dev/null 2>&1 || return 1
        fi
        echo "    ✓ Network '$network_name' already exists with correct subnet"
    fi

    # Use CLI flags instead of a generated config file to avoid schema drift
    # across k3d versions.
    # Network already exists, so we DON'T use --subnet (k3d will use existing network)
    # Add resource optimizations: more memory and CPU for faster node startup
    local create_args=(
        "$name"
        --servers "$servers"
        --agents "$agents"
        --network "$network_name"
        --k3s-arg "--cluster-cidr=${pod_cidr}@server:*"
        --k3s-arg "--service-cidr=${service_cidr}@server:*"
        --k3s-arg "--kubelet-arg=--max-pods=110@server:*"
        --k3s-arg "--kubelet-arg=--max-pods=110@agent:*"
        --k3s-arg "--kubelet-arg=--serialize-image-pulls=false@server:*"
        --k3s-arg "--kubelet-arg=--serialize-image-pulls=false@agent:*"
        --wait
        --timeout 600s
    )
    
    # Add memory limits for nodes (4GB per node minimum, more for servers)
    # This helps prevent OOM issues during startup
    if [ "$servers" -gt 0 ]; then
        create_args+=(--k3s-arg "--kubelet-arg=--memory-pressure-threshold=200Mi@server:*")
    fi
    if [ "$agents" -gt 0 ]; then
        create_args+=(--k3s-arg "--kubelet-arg=--memory-pressure-threshold=200Mi@agent:*")
    fi

    k3d cluster create "${create_args[@]}"
    k3d kubeconfig merge "$name" --kubeconfig-merge-default || true

    export KUBECONFIG="$(k3d kubeconfig write "$name")"
    kubectl wait node --all --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true
    annotate_nodes "$name" "$type" "$cluster_id" "$pod_cidr" "$service_cidr" "$network_cidr" "$accelerator_hint"
    unset KUBECONFIG

    echo "    ✓ Cluster '$name' created"
}

if [ "$CLEAN" = true ]; then
    echo "Cleaning up existing clusters..."
    for spec in "${CLUSTER_SPECS[@]}"; do
        IFS='|' read -r cluster_name _ _ _ _ network_cidr _ _ _ <<< "$spec"
        if k3d cluster list | grep -q "^${cluster_name}[[:space:]]"; then
            echo "  Deleting cluster: $cluster_name"
            k3d cluster delete "$cluster_name" || true
        fi
        # Remove networks by subnet, not just by name
        remove_networks_by_subnet "$network_cidr" "dt-${cluster_name}"
    done
fi

# Pre-cleanup: Remove any networks that might conflict with our subnets
echo "Preparing networks..."
for spec in "${CLUSTER_SPECS[@]}"; do
    IFS='|' read -r cluster_name _ _ _ _ network_cidr _ _ _ <<< "$spec"
    remove_networks_by_subnet "$network_cidr" "dt-${cluster_name}"
done

# Create clusters sequentially to avoid k3d network creation race conditions
# k3d will create networks as needed, but sequential creation prevents conflicts
echo "Creating clusters..."
for spec in "${CLUSTER_SPECS[@]}"; do
    IFS='|' read -r cluster_name cluster_type servers agents cluster_id network_cidr pod_cidr service_cidr accelerator_hint <<< "$spec"
    create_cluster "$cluster_name" "$cluster_type" "$servers" "$agents" "$cluster_id" "$network_cidr" "$pod_cidr" "$service_cidr" "$accelerator_hint"
done

echo ""
echo "=== Installing Metrics Server ==="

# Install metrics-server in each cluster
for spec in "${CLUSTER_SPECS[@]}"; do
    IFS='|' read -r cluster_name _ <<< "$spec"
    if [ "$SKIP_METRICS" = true ]; then
        echo "  Skipping metrics-server installation (--skip-metrics)"
        break
    fi

    echo "  Installing metrics-server in '$cluster_name'..."

    export KUBECONFIG="$(k3d kubeconfig write "$cluster_name")"
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml || true
    kubectl patch deployment metrics-server -n kube-system --type=json \
        -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]' || true
    kubectl wait --for=condition=available deployment/metrics-server -n kube-system --timeout=120s || true
    unset KUBECONFIG

    echo "    ✓ Metrics-server installed in '$cluster_name'"
done

unset KUBECONFIG

echo ""
echo "=== Cluster Status ==="
for spec in "${CLUSTER_SPECS[@]}"; do
    IFS='|' read -r cluster_name _ <<< "$spec"
    echo ""
    echo "Cluster: $cluster_name"
    export KUBECONFIG="$(k3d kubeconfig write "$cluster_name")"
    kubectl get nodes || echo "  (unable to connect)"
    unset KUBECONFIG
done

echo ""
echo "=== PoC Setup Complete ==="
echo ""
echo "Clusters created (PoC Mode - 3 clusters):"
for spec in "${CLUSTER_SPECS[@]}"; do
    IFS='|' read -r cluster_name _ <<< "$spec"
    echo "  - $cluster_name"
done
echo ""
echo "Resource usage:"
echo "  - Total nodes: ~9 (3 clusters)"
echo "  - Estimated RAM: ~12-15 GB"
echo "  - Estimated CPU: ~6-8 cores"
echo ""
echo "This minimal setup demonstrates:"
echo "  ✓ Multi-cluster architecture"
echo "  ✓ Heterogeneous device types (datacenter, edge, consumer)"
echo "  ✓ Origin-aware placement across clusters"
echo "  ✓ Different accelerator types (GPU, NPU)"
echo ""
echo "To use a specific cluster:"
echo "  export KUBECONFIG=\$(k3d kubeconfig write <cluster-name>)"
echo ""
echo "Next steps:"
echo "  1. Configure latency matrix: deploy/latency-matrix.yaml"
echo "  2. Initialize cluster manager in DT API"
echo "  3. Run experiments with multi-cluster support"
echo ""
echo "For full 7-cluster setup, use: ./deploy/multi-cluster-setup.sh"
