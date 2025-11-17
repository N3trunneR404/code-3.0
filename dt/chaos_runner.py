"""Chaos scenario runner for simulation-side experiments."""

from __future__ import annotations

import copy
import logging
import random
import time
from dataclasses import dataclass
from typing import Dict, List

from dt.predict import PredictiveSimulator
from dt.state import DTState, Job, PlacementDecision

logger = logging.getLogger(__name__)


@dataclass
class ChaosResult:
    success_rate: float
    avg_completion_time_ms: float
    recovery_time_ms: float
    failures_observed: int
    total_trials: int


class ChaosScenarioRunner:
    """Runs fault-injection scenarios against the predictive simulator."""

    def __init__(self, state: DTState, simulator: PredictiveSimulator) -> None:
        self.state = state
        self.simulator = simulator
        self.executed_scenarios: List[Dict] = []

    def run_with_node_failure(
        self,
        job: Job,
        placements: Dict[str, PlacementDecision],
        *,
        failure_probability: float = 0.3,
        num_trials: int = 10,
    ) -> ChaosResult:
        results: List[float] = []
        recovery_times: List[float] = []
        failures_observed = 0

        for _ in range(num_trials):
            failed = random.random() < failure_probability
            sim = PredictiveSimulator(self.state, failure_rate=failure_probability if failed else 0.0)
            metrics = sim.score_plan(job, placements)
            results.append(metrics.latency_ms)

            if failed:
                failures_observed += 1
                recovery_times.append(metrics.latency_ms)

        success_rate = sum(1 for r in results if r > 0) / num_trials
        avg_completion = sum(results) / len(results) if results else 0.0
        avg_recovery = sum(recovery_times) / len(recovery_times) if recovery_times else 0.0

        summary = ChaosResult(
            success_rate=success_rate,
            avg_completion_time_ms=avg_completion,
            recovery_time_ms=avg_recovery,
            failures_observed=failures_observed,
            total_trials=num_trials,
        )

        self.executed_scenarios.append({
            "type": "node_failure",
            "timestamp": time.time(),
            "result": summary,
        })

        return summary

    def run_cpu_saturation(
        self,
        job: Job,
        placements: Dict[str, PlacementDecision],
        *,
        saturation_level: float = 0.9,
    ) -> Dict:
        saturated_state = self._saturate_state(saturation_level)
        sim = PredictiveSimulator(saturated_state, failure_rate=self.simulator.failure_rate)
        saturated_metrics = sim.score_plan(job, placements)
        baseline_metrics = self.simulator.score_plan(job, placements)

        return {
            "baseline_completion_ms": baseline_metrics.latency_ms,
            "saturated_completion_ms": saturated_metrics.latency_ms,
            "degradation_factor": (
                saturated_metrics.latency_ms / baseline_metrics.latency_ms
                if baseline_metrics.latency_ms > 0
                else float("inf")
            ),
            "success": saturated_metrics.sla_violations == 0,
        }

    def _saturate_state(self, saturation_level: float) -> DTState:
        clone = copy.deepcopy(self.state)
        for node in clone.list_nodes():
            node.tel.cpu_util = min(100.0, max(node.tel.cpu_util, saturation_level * 100.0))
        return clone

    def get_scenario_summary(self) -> Dict:
        return {
            "total_scenarios": len(self.executed_scenarios),
            "scenarios": self.executed_scenarios,
        }
