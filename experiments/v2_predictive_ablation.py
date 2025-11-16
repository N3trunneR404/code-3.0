"""V2: Predictive Ablation Experiment

Tests predictive capabilities with different strategies.
Includes origin context and resource scaling documentation.
"""

from __future__ import annotations

import json
import random
from typing import Any, Dict, Optional

from experiments.dt_client import DTClient, ensure_client

# Resource scaling: default 1:100 (1 simulated CPU = 0.01 real cores)
RESOURCE_SCALE = 0.01


def make_job(
    job_id: int,
    origin_cluster: str = "campus-lab",
    origin_node: Optional[str] = None,
) -> Dict[str, Any]:
    """Create a job with origin context."""
    dur = random.randint(800, 1600)
    return {
        "apiVersion": "fabric.dt/v1",
        "kind": "Job",
        "metadata": {
            "name": f"ablate-{job_id}",
            "deadline_ms": dur * 2,
            "origin": {
                "cluster": origin_cluster,
                "node": origin_node,
            },
        },
        "spec": {
            "stages": [
                {
                    "id": "s1",
                    "compute": {"cpu": 1, "mem_gb": 1, "duration_ms": dur},
                    "constraints": {"arch": ["amd64"], "formats": ["native"]},
                }
            ]
        },
    }


def run(dt: DTClient | str | None = None, trials: int = 20) -> None:
    """Run experiment with origin context and scaling."""
    client = ensure_client(dt)
    print("=== V2 Predictive Ablation ===")
    print(f"Resource scale: {RESOURCE_SCALE} (1:{int(1.0/RESOURCE_SCALE)})")
    print(f"Trials: {trials}")
    print()

    strategies = ["greedy", "resilient", "cvar"]
    origin_clusters = ["dc-core", "edge-microdc", "campus-lab", "gamer-pc"]

    for i in range(trials):
        origin = origin_clusters[i % len(origin_clusters)]
        job = make_job(i, origin_cluster=origin)
        strategy = strategies[i % len(strategies)]

        result = client.plan(job, strategy=strategy, dry_run=True)
        result["origin_cluster"] = origin
        result["strategy"] = strategy
        result["resource_scale"] = RESOURCE_SCALE
        print(json.dumps(result))


if __name__ == "__main__":
    run(None, 10)
