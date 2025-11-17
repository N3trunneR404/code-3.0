"""Adaptive meta-policy selector."""

from __future__ import annotations

import time
from collections import defaultdict
from typing import Dict, Optional

from dt.policy.cvar import RiskAwareCvarPolicy
from dt.policy.greedy import GreedyLatencyPolicy
from dt.policy.resilient import ResilientPolicy
from dt.state import DTState, Job


class PolicySelector:
    """Choose a scheduling policy based on context."""

    def __init__(self, state: DTState, simulator, cluster_manager=None) -> None:
        self.policies = {
            "greedy": GreedyLatencyPolicy(state, simulator, cluster_manager=cluster_manager),
            "resilient": ResilientPolicy(state, simulator, cluster_manager=cluster_manager),
            "cvar": RiskAwareCvarPolicy(state, simulator, cluster_manager=cluster_manager),
        }
        self.recent_failures = []
        self.failure_window_seconds = 300.0
        self.policy_performance: Dict[str, list] = defaultdict(list)
        self.state = state

    def select_policy_for_job(self, job: Job, states: Optional[Dict] = None, force_policy: Optional[str] = None):
        if force_policy and force_policy in self.policies:
            return self.policies[force_policy]

        if self._has_recent_failures():
            return self.policies["resilient"]

        if job.deadline_ms < 5000 or job.origin:
            return self.policies["resilient"]

        avg_util = self._average_utilization()
        if avg_util > 0.75:
            return self.policies["cvar"]

        return self.policies["greedy"]

    def record_failure(self, node_name: str) -> None:
        self.recent_failures.append({"node": node_name, "timestamp": time.time()})
        self._prune_old_failures()

    def record_policy_performance(self, policy_name: str, success: bool, completion_time_ms: float) -> None:
        self.policy_performance[policy_name].append({
            "success": success,
            "completion_time_ms": completion_time_ms,
        })
        if len(self.policy_performance[policy_name]) > 100:
            self.policy_performance[policy_name] = self.policy_performance[policy_name][-100:]

    def get_policy_stats(self) -> Dict:
        stats: Dict[str, Dict] = {}
        for name, records in self.policy_performance.items():
            if not records:
                stats[name] = {"total_jobs": 0, "success_rate": 0.0, "avg_completion_ms": 0.0}
                continue
            successes = sum(1 for r in records if r["success"])
            times = [r["completion_time_ms"] for r in records if r["success"]]
            stats[name] = {
                "total_jobs": len(records),
                "success_rate": successes / len(records),
                "avg_completion_ms": sum(times) / len(times) if times else 0.0,
            }
        return stats

    def _has_recent_failures(self) -> bool:
        self._prune_old_failures()
        return bool(self.recent_failures)

    def _prune_old_failures(self) -> None:
        cutoff = time.time() - self.failure_window_seconds
        self.recent_failures = [f for f in self.recent_failures if f["timestamp"] > cutoff]

    def _average_utilization(self) -> float:
        nodes = self.state.list_nodes()
        if not nodes:
            return 0.0
        utilizations = [max(n.tel.cpu_util, n.tel.mem_util) / 100.0 if n.tel else 0.0 for n in nodes]
        return sum(utilizations) / len(utilizations)
