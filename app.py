from __future__ import annotations

import os
import logging
from pathlib import Path

from dt.api import create_app
from dt.seed import seed_state
from dt.state import DTState
from dt.cluster_manager import ClusterManager

logger = logging.getLogger(__name__)

def build_app():
    """Build the Flask app with seeded state and cluster manager."""
    auto_watchers = os.getenv("DT_AUTO_WATCHERS", "1").lower() not in {"0", "false", "no"}
    state = DTState(auto_start_watchers=auto_watchers)
    seed_state(state)
    
    # Initialize cluster manager with latency matrix
    latency_matrix_path = os.getenv(
        "LATENCY_MATRIX_PATH",
        str(Path(__file__).parent / "deploy" / "latency-matrix.yaml")
    )
    
    cluster_manager = None
    if os.path.exists(latency_matrix_path):
        try:
            cluster_manager = ClusterManager(latency_matrix_path=latency_matrix_path)
            logger.info(f"Initialized cluster manager with latency matrix: {latency_matrix_path}")
        except Exception as e:
            logger.warning(f"Failed to initialize cluster manager: {e}")
            cluster_manager = None
    else:
        logger.info("Latency matrix not found, running in single-cluster mode")
    
    return create_app(state, cluster_manager=cluster_manager)


# Build app at module level (for gunicorn)
app = build_app()

# Ensure state is seeded when module is imported (for worker processes)
# This will be called in each worker after forking
if hasattr(app, 'config'):
    state = app.config.get('dt_state')
    if state:
        # Verify nodes exist, re-seed if needed
        nodes = state.list_nodes()
        if not nodes:
            seed_state(state)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)





