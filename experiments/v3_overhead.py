"""V3: Execution format overhead study."""

from __future__ import annotations

import json
from typing import Any, Dict, Optional

from experiments.dt_client import DTClient, ensure_client

# Resource scaling: default 1:100 (1 simulated CPU = 0.01 real cores)
RESOURCE_SCALE = 0.01


def mk(
    stage_format: str,
    ms: int,
    origin_cluster: str = "dc-core",
    origin_node: Optional[str] = None,
) -> Dict[str, Any]:
    """Create a job with origin context."""
    return {
        "apiVersion": "fabric.dt/v1",
        "kind": "Job",
        "metadata": {
            "name": f"overhead-{stage_format}",
            "deadline_ms": ms * 3,
            "origin": {
                "cluster": origin_cluster,
                "node": origin_node,
            },
        },
        "spec": {
            "stages": [
                {
                    "id": "s1",
                    "compute": {"cpu": 1, "mem_gb": 1, "duration_ms": ms},
                    "constraints": {"arch": ["amd64"], "formats": ["native", "wasm"]},
                }
            ]
        },
    }


def run(dt: DTClient | str | None = None) -> None:
    """Run experiment with origin context and scaling."""
    client = ensure_client(dt)
    print("=== V3 Overhead ===")
    print(f"Resource scale: {RESOURCE_SCALE} (1:{int(1.0/RESOURCE_SCALE)})")
    print()

    for fmt in ["native", "wasm"]:
        job = mk(fmt, 1500, origin_cluster="dc-core")
        result = client.plan(job, strategy="cvar", dry_run=True)
        result["origin_cluster"] = "dc-core"
        result["resource_scale"] = RESOURCE_SCALE
        print(json.dumps(result))


if __name__ == "__main__":
    run()
