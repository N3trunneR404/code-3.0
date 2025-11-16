#!/usr/bin/env bash
# Quick validation of local environment before running the digital twin PoC.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

missing=0
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
ok() { echo -e "${GREEN}✓${NC} $1"; }
err() { echo -e "${RED}✗${NC} $1"; missing=$((missing + 1)); }

check_cmd() {
    local cmd="$1"
    local help="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd present ($("$cmd" --version 2>&1 | head -n1))"
    else
        err "$cmd missing (install: $help)"
    fi
}

check_cmd docker "https://docs.docker.com/get-docker/"
check_cmd k3d "https://k3d.io/#installation"
check_cmd kubectl "https://kubernetes.io/docs/tasks/tools/"
check_cmd python3 "https://www.python.org/downloads/"
check_cmd pip3 "https://pip.pypa.io/en/stable/installation/"

# Basic resource sanity checks
echo ""
echo "Hardware sanity checks"
if [[ "${OSTYPE:-linux}" == "darwin" ]]; then
    total_ram_gb=$(($(sysctl -n hw.memsize)/1024/1024/1024))
    cores=$(sysctl -n hw.ncpu)
else
    total_ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
fi
disk_gb=$(df -BG "$ROOT_DIR" | awk 'NR==2 {print int($4)}')

if (( total_ram_gb >= 16 )); then
    ok "RAM: ${total_ram_gb}GiB available"
else
    warn "RAM: ${total_ram_gb}GiB available (16GiB recommended for 6-7 clusters)"
fi
if (( disk_gb >= 20 )); then
    ok "Disk: ${disk_gb}GiB free at $ROOT_DIR"
else
    err "Disk: ${disk_gb}GiB free (20GiB+ recommended)"
fi
if (( cores >= 4 )); then
    ok "CPU cores: ${cores}"
else
    warn "CPU cores: ${cores} (>=4 recommended)"
fi

# Docker daemon
if docker info >/dev/null 2>&1; then
    ok "Docker daemon reachable"
else
    warn "Docker daemon not reachable; start Docker before provisioning clusters"
fi

echo ""
if (( missing == 0 )); then
    echo -e "${GREEN}Environment looks good. Proceed with ./scripts/01_deploy_clusters.sh${NC}"
else
    echo -e "${RED}Resolve ${missing} blocking issue(s) above before provisioning clusters.${NC}"
    exit 1
fi
