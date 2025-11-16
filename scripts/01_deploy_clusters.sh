#!/usr/bin/env bash
# Wrapper for provisioning the full multi-cluster digital twin substrate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_SCRIPT="$ROOT_DIR/deploy/multi-cluster-setup.sh"

if [[ ! -x "$DEPLOY_SCRIPT" ]]; then
    echo "Deployment script not found at $DEPLOY_SCRIPT" >&2
    exit 1
fi

if [[ "${SKIP_PREREQ_CHECK:-false}" != "true" ]]; then
    "$SCRIPT_DIR/00_prerequisites_check.sh"
fi

echo "=== Provisioning multi-cluster fabric ==="
"$DEPLOY_SCRIPT" "$@"

echo ""
echo "Clusters created. To add traffic shaping latency, run ./scripts/02_configure_network.sh"
echo "To rerun telemetry/experiments, start the API with: python app.py"
