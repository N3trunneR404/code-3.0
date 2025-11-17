"""Conditional Value at Risk (CVaR) scheduling policy."""

from __future__ import annotations

import logging
from typing import Dict, List, Optional

import numpy as np

from dt.cluster_manager import ClusterManager
from dt.failures.resiliency_scorer import ResiliencyScorer
from dt.policy.base import Policy
from dt.predict import PredictiveSimulator
from dt.state import DTState, Job, JobStage, PlacementDecision, Node

logger = logging.getLogger(__name__)


class RiskAwareCvarPolicy(Policy):
    """Risk-averse scheduler using CVaR to hedge tail latency."""

    def __init__(
        self,
        state: DTState,
        simulator: PredictiveSimulator,
        *,
        alpha: float = 0.95,
        risk_weight: float = 0.6,
        cluster_manager: Optional[ClusterManager] = None,
    ) -> None:
        super().__init__(state, simulator)
        self.alpha = alpha
        self.risk_weight = risk_weight
        self.cluster_manager = cluster_manager
        self.resiliency_scorer = ResiliencyScorer(state)

    def _candidate_nodes(self, stage: JobStage) -> List[Node]:
        return [n for n in self.state.list_nodes() if n.available]

    def _compute_origin_latency(self, job: Job, candidate_node: Node) -> float:
        if not job.origin or not self.cluster_manager:
            return 0.0
        candidate_cluster = self.state.get_cluster(candidate_node.name)
        if not candidate_cluster:
            return 0.0
        return self.cluster_manager.get_latency_between(
            job.origin.cluster,
            candidate_cluster,
            job.origin.node,
            candidate_node.name,
        )

    def _sample_cost(
        self, job: Job, placements: Dict[str, PlacementDecision], runs: int = 16
    ) -> float:
        samples: List[float] = []
        for _ in range(runs):
            noise = np.random.lognormal(mean=0.0, sigma=0.15)
            res = self.sim.score_plan(job, placements)

            origin_lat = 0.0
            if job.origin and job.stages:
                first_stage = job.stages[0]
                decision = placements.get(first_stage.id)
                if decision:
                    node = self.state.get_node(decision.node_name)
                    if node:
                        origin_lat = self._compute_origin_latency(job, node)

            samples.append((res.latency_ms + origin_lat) * noise)

        q = np.quantile(samples, self.alpha)
        tail = [s for s in samples if s >= q]
        return float(np.mean(tail)) if tail else float(q)

    def place(self, job: Job) -> Dict[str, PlacementDecision]:
        placements: Dict[str, PlacementDecision] = {}

        for stage in job.stages:
            best_dec: Optional[PlacementDecision] = None
            best_cvar = float("inf")

            for node in self._candidate_nodes(stage):
                if stage.compute.gpu_vram_gb > 0 and node.hardware.gpu_vram_gb < stage.compute.gpu_vram_gb:
                    continue

                exec_format = self.sim.choose_exec_format(stage, node)
                candidate_plan = dict(placements)
                candidate_plan[stage.id] = PlacementDecision(
                    stage_id=stage.id,
                    node_name=node.name,
                    exec_format=exec_format,
                )

                cvar = self._sample_cost(job, candidate_plan)

                # Penalize low resiliency
                resiliency = self.resiliency_scorer.compute_node_score(node.name)
                risk_penalty = self.risk_weight * (1.0 - resiliency)
                adjusted_cvar = cvar * (1.0 + risk_penalty)

                if adjusted_cvar < best_cvar:
                    best_cvar = adjusted_cvar
                    best_dec = candidate_plan[stage.id]

            if best_dec:
                placements[stage.id] = best_dec
            else:
                logger.warning("No CVaR candidate for stage %s", stage.id)

        return placements





