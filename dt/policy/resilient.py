"""
Resilient scheduling policy.

Prioritizes reliability and headroom while still accounting for latency
between stage dependencies and the job origin.
"""

from __future__ import annotations

import logging
import math
from typing import Dict, List, Optional

from dt.cluster_manager import ClusterManager
from dt.failures.resiliency_scorer import ResiliencyScorer
from dt.policy.base import Policy
from dt.predict import PredictiveSimulator
from dt.state import DTState, Job, JobStage, PlacementDecision, Node

logger = logging.getLogger(__name__)


class ResilientPolicy(Policy):
    """Reliability-first placement policy."""

    def __init__(
        self,
        state: DTState,
        simulator: PredictiveSimulator,
        *,
        cluster_manager: Optional[ClusterManager] = None,
        capacity_weight: float = 0.3,
        resiliency_weight: float = 0.5,
        utilization_weight: float = 0.2,
    ) -> None:
        super().__init__(state, simulator)
        self.cluster_manager = cluster_manager
        total = capacity_weight + resiliency_weight + utilization_weight
        if not math.isclose(total, 1.0):
            logger.warning("ResilientPolicy weights do not sum to 1.0, normalizing")
            capacity_weight /= total
            resiliency_weight /= total
            utilization_weight /= total
        self.capacity_weight = capacity_weight
        self.resiliency_weight = resiliency_weight
        self.utilization_weight = utilization_weight
        self.resiliency_scorer = ResiliencyScorer(state)

    def _candidate_nodes(self, stage: JobStage) -> List[Node]:
        """Return nodes that satisfy basic resource constraints."""
        nodes: List[Node] = []
        for node in self.state.list_nodes():
            if not node.available:
                continue
            if stage.compute.gpu_vram_gb > 0 and node.hardware.gpu_vram_gb < stage.compute.gpu_vram_gb:
                continue
            if node.k8s.allocatable_cpu < stage.compute.cpu:
                continue
            if node.k8s.allocatable_mem_gb < stage.compute.mem_gb:
                continue
            nodes.append(node)
        return nodes

    def _compute_origin_latency(self, job: Job, candidate_node: Node) -> float:
        """Compute latency from job origin to candidate node."""
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

    def _score_capacity_fit(self, stage: JobStage, node: Node) -> float:
        """Score how well the stage fits on the node (0..1)."""
        if node.k8s.allocatable_cpu <= 0 or node.k8s.allocatable_mem_gb <= 0:
            return 0.0
        cpu_fit = 1.0 - (stage.compute.cpu / node.k8s.allocatable_cpu)
        mem_fit = 1.0 - (stage.compute.mem_gb / node.k8s.allocatable_mem_gb)
        return max(0.0, min(cpu_fit, mem_fit))

    def _utilization_score(self, node: Node) -> float:
        """Inverse utilization; prefers headroom."""
        util = max(node.tel.cpu_util, node.tel.mem_util) / 100.0 if node.tel else 0.0
        return max(0.0, 1.0 - util)

    def place(self, job: Job) -> Dict[str, PlacementDecision]:
        placements: Dict[str, PlacementDecision] = {}
        prev_node_for: Dict[str, Node] = {}

        for stage in job.stages:
            best_node: Optional[Node] = None
            best_score = -math.inf
            best_format = "native"

            for node in self._candidate_nodes(stage):
                exec_format = self.sim.choose_exec_format(stage, node)
                latency_ms = self.sim.compute_stage_latency_ms(stage, node, exec_format)

                if stage.predecessor and stage.predecessor in prev_node_for:
                    latency_ms += self.sim.compute_network_delay_ms(
                        prev_node_for[stage.predecessor], node
                    )

                if not stage.predecessor and job.origin:
                    latency_ms += self._compute_origin_latency(job, node)

                capacity_score = self._score_capacity_fit(stage, node)
                resiliency_score = self.resiliency_scorer.compute_node_score(node.name)
                utilization_score = self._utilization_score(node)

                composite = (
                    self.capacity_weight * capacity_score
                    + self.resiliency_weight * resiliency_score
                    + self.utilization_weight * utilization_score
                    - 0.001 * latency_ms
                )

                if composite > best_score:
                    best_score = composite
                    best_node = node
                    best_format = exec_format

            if best_node is None:
                logger.warning("No feasible node found for stage %s", stage.id)
                continue

            placements[stage.id] = PlacementDecision(
                stage_id=stage.id,
                node_name=best_node.name,
                exec_format=best_format,
            )
            prev_node_for[stage.id] = best_node

        return placements
