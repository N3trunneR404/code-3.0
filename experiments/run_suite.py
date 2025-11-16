from __future__ import annotations

import importlib
import pathlib
import sys

from experiments.dt_client import DTClient

EXPERIMENTS = [
    "experiments.v1_controller_vs_baseline",
    "experiments.v2_predictive_ablation",
    "experiments.v3_overhead",
    "experiments.v4_shadow_plans",
    "experiments.v5_scalability_kwok",
    "experiments.v6_drift_robustness",
]


def main() -> None:
    root = pathlib.Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(root))
    client = DTClient("http://127.0.0.1:8080")
    for module_name in EXPERIMENTS:
        print(f"=== Running {module_name} ===")
        module = importlib.import_module(module_name)
        if hasattr(module, "run"):
            module.run(client)
        elif hasattr(module, "main"):
            module.main()
        else:
            print(f"Skipping {module_name}: no run()/main() entrypoint")


if __name__ == "__main__":
	main()

