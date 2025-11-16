#!/usr/bin/env bash
# Apply basic inter-cluster latency shaping and emit a latency matrix config.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DELAY_MS=${NETEM_DELAY_MS:-15}
LOSS_PCT=${NETEM_LOSS_PCT:-0.1}

if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl is required to configure network shaping" >&2
    exit 1
fi

MANIFEST="$ROOT_DIR/sim/network/netem-daemonset.yaml"
if [[ ! -f "$MANIFEST" ]]; then
    echo "netem manifest not found at $MANIFEST" >&2
    exit 1
fi

echo "Applying netem DaemonSet with ${DELAY_MS}ms delay and ${LOSS_PCT}% loss"
kubectl apply -f "$MANIFEST" >/dev/null
kubectl -n kube-system set env daemonset/netem-shaper NETEM_DELAY_MS="$DELAY_MS" NETEM_LOSS_PCT="$LOSS_PCT" --overwrite >/dev/null
kubectl -n kube-system rollout status daemonset/netem-shaper --timeout=120s

echo "Writing latency matrix to configs/latency-matrix.yaml"
mkdir -p "$ROOT_DIR/configs"
cat > "$ROOT_DIR/configs/latency-matrix.yaml" <<'YAML'
# Synthetic inter-cluster latency (ms) used by origin-aware policies
origin_cluster: edge-microdc
latency:
  dc-core:
    dc-core: 5
    prosumer-mining: 8
    campus-lab: 12
    edge-microdc: 25
    phone-pan-1: 32
    phone-pan-2: 36
    gamer-pc: 45
  prosumer-mining:
    dc-core: 8
    prosumer-mining: 5
    campus-lab: 10
    edge-microdc: 28
    phone-pan-1: 35
    phone-pan-2: 38
    gamer-pc: 48
  campus-lab:
    dc-core: 12
    prosumer-mining: 10
    campus-lab: 5
    edge-microdc: 18
    phone-pan-1: 24
    phone-pan-2: 26
    gamer-pc: 34
  edge-microdc:
    dc-core: 25
    prosumer-mining: 28
    campus-lab: 18
    edge-microdc: 5
    phone-pan-1: 12
    phone-pan-2: 15
    gamer-pc: 22
  phone-pan-1:
    dc-core: 32
    prosumer-mining: 35
    campus-lab: 24
    edge-microdc: 12
    phone-pan-1: 5
    phone-pan-2: 8
    gamer-pc: 18
  phone-pan-2:
    dc-core: 36
    prosumer-mining: 38
    campus-lab: 26
    edge-microdc: 15
    phone-pan-1: 8
    phone-pan-2: 5
    gamer-pc: 18
  gamer-pc:
    dc-core: 45
    prosumer-mining: 48
    campus-lab: 34
    edge-microdc: 22
    phone-pan-1: 18
    phone-pan-2: 18
    gamer-pc: 5
YAML

echo "Netem configured. For deterministic runs, persist kubectl context to kubeconfig for each k3d cluster."
