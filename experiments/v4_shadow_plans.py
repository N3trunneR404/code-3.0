"""V4: Shadow plan validation experiment."""

from __future__ import annotations

import json
from typing import Any, Dict, Optional

from experiments.dt_client import DTClient, ensure_client

# Resource scaling: default 1:100 (1 simulated CPU = 0.01 real cores)
RESOURCE_SCALE = 0.01


def job(
    deadline_ms: int,
    origin_cluster: str = "edge-microdc",
    origin_node: Optional[str] = None,
) -> Dict[str, Any]:
    """Create a job with origin context."""
    return {
        "apiVersion": "fabric.dt/v1",
        "kind": "Job",
        "metadata": {
            "name": "shadow-test",
            "deadline_ms": deadline_ms,
            "origin": {
                "cluster": origin_cluster,
                "node": origin_node,
            },
        },
        "spec": {
            "stages": [
                {
                    "id": "s1",
                    "compute": {"cpu": 1, "mem_gb": 1, "duration_ms": deadline_ms // 2},
                    "constraints": {"arch": ["amd64"], "formats": ["native"]},
                }
            ]
        },
    }


def collect_verification(client: DTClient, plan_id: str) -> Optional[Dict[str, Any]]:
    """Collect verification results for a plan."""
    try:
        return client.verify(plan_id)
    except Exception:
        return None


def run(dt: DTClient | str | None = None) -> None:
    """Run experiment with origin context, scaling, and verification."""
    client = ensure_client(dt)
    print("=== V4 Shadow Plans ===")
    print(f"Resource scale: {RESOURCE_SCALE} (1:{int(1.0/RESOURCE_SCALE)})")
    print()

    job_spec = job(2000, origin_cluster="edge-microdc")
    result = client.plan(job_spec, strategy="resilient", dry_run=False)

    plan_id = result.get("plan_id")
    result["origin_cluster"] = "edge-microdc"
    result["resource_scale"] = RESOURCE_SCALE

    if plan_id:
        verify_data = collect_verification(client, plan_id)
        if verify_data:
            result["verification"] = verify_data

    print(json.dumps(result))


if __name__ == "__main__":
    run()
