"""Client utilities used by experiments to talk to the Digital Twin."""

from __future__ import annotations

import time
import uuid
from dataclasses import asdict
from typing import Any, Dict, Optional, Union

import requests

from dt.actuator import Actuator
from dt.jobs import parse_job_spec
from dt.predict import PredictiveSimulator
from dt.policy.cvar import RiskAwareCvarPolicy
from dt.policy.greedy import GreedyLatencyPolicy
from dt.policy.resilient import ResilientPolicy
from dt.seed import seed_state
from dt.state import DTState, Plan

try:
    from dt.cluster_manager import ClusterManager
except Exception:  # pragma: no cover - optional dependency during tests
    ClusterManager = None  # type: ignore


class DTClient:
    """Simple wrapper that prefers HTTP but falls back to in-process planning."""

    def __init__(
        self,
        endpoint: Optional[str] = "http://127.0.0.1:8080",
        *,
        state: Optional[DTState] = None,
        cluster_manager: Optional[ClusterManager] = None,
    ) -> None:
        self._endpoint = endpoint.rstrip("/") if endpoint else None
        self._session: Optional[requests.Session] = None
        self._state = state
        self._cluster_manager = cluster_manager
        self._simulator: Optional[PredictiveSimulator] = None
        self._actuator: Optional[Actuator] = None
        self._plans: Dict[str, Plan] = {}

        if self._endpoint:
            self._session = requests.Session()
            if not self._probe_endpoint():
                self._session.close()
                self._session = None
                self._endpoint = None

        if self._endpoint is None:
            self._state = state or DTState()
            try:
                if not self._state.list_nodes():
                    seed_state(self._state)
            except Exception as exc:
                raise RuntimeError(
                    "Offline DTClient fallback could not seed the DTState; "
                    "install the optional dependencies or pass a pre-populated state."
                ) from exc
            self._simulator = PredictiveSimulator(self._state)
            if self._cluster_manager is not None:
                self._actuator = Actuator(cluster_manager=self._cluster_manager)
            else:
                self._actuator = None

    # ------------------------------------------------------------------
    # Private helpers
    # ------------------------------------------------------------------
    def _probe_endpoint(self) -> bool:
        assert self._session is not None
        try:
            resp = self._session.get(f"{self._endpoint}/snapshot", timeout=2)
            resp.raise_for_status()
            return True
        except Exception:
            return False

    def _select_policy(self, name: str):
        assert self._state is not None and self._simulator is not None
        strategy = (name or "greedy").lower()
        if strategy == "resilient":
            return ResilientPolicy(self._state, self._simulator, cluster_manager=self._cluster_manager)
        if strategy == "cvar":
            return RiskAwareCvarPolicy(self._state, self._simulator, cluster_manager=self._cluster_manager)
        return GreedyLatencyPolicy(self._state, self._simulator, cluster_manager=self._cluster_manager)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------
    @property
    def endpoint(self) -> Optional[str]:
        return self._endpoint

    def plan(self, job_spec: Dict[str, Any], *, strategy: str = "greedy", dry_run: bool = False) -> Dict[str, Any]:
        """Request a placement plan for ``job_spec``."""

        if self._endpoint and self._session:
            resp = self._session.post(
                f"{self._endpoint}/plan",
                json={"job": job_spec, "strategy": strategy, "dry_run": dry_run},
                timeout=20,
            )
            resp.raise_for_status()
            return resp.json()

        # Offline fallback
        assert self._state is not None and self._simulator is not None
        job = parse_job_spec(job_spec)
        policy = self._select_policy(strategy)
        placements = policy.place(job)
        if not placements:
            raise RuntimeError("no feasible placements found")

        metrics = self._simulator.score_plan(job, placements)
        plan_id = f"plan-{uuid.uuid4().hex[:8]}"
        response = {
            "plan_id": plan_id,
            "placements": {
                stage_id: {
                    "stage_id": stage_id,
                    "node_name": decision.node_name,
                    "exec_format": decision.exec_format,
                }
                for stage_id, decision in placements.items()
            },
            "predicted_latency_ms": metrics.latency_ms,
            "predicted_energy_kwh": metrics.energy_kwh,
            "risk_score": metrics.risk_score,
            "shadow_plan": {f"{sid}_backup": dec.node_name for sid, dec in placements.items()},
        }

        self._state.add_job(job)
        plan = Plan(
            plan_id=plan_id,
            job_name=job.name,
            placements=placements,
            predicted_latency_ms=metrics.latency_ms,
            predicted_energy_kwh=metrics.energy_kwh,
            risk_score=metrics.risk_score,
            shadow_plan=response["shadow_plan"],
        )
        self._plans[plan_id] = plan

        if not dry_run and self._actuator is not None:
            try:
                self._actuator.submit_plan(job, placements, plan_id=plan_id)
            except Exception:
                # In offline mode the actuator is optional; ignore failures.
                pass

        return response

    def verify(self, plan_id: str) -> Optional[Dict[str, Any]]:
        """Return observed metrics for a plan if available."""

        if self._endpoint and self._session:
            resp = self._session.get(f"{self._endpoint}/plan/{plan_id}/verify", timeout=10)
            if resp.status_code == 404:
                return None
            resp.raise_for_status()
            return resp.json()

        assert self._state is not None
        observed = self._state.get_observed_metrics(plan_id)
        if observed:
            payload = asdict(observed)
            return {"plan_id": plan_id, "observed": payload, "note": "Recorded by DTState"}

        plan = self._plans.get(plan_id)
        if not plan:
            return None

        simulated_observed = {
            "latency_ms": plan.predicted_latency_ms * 0.98,
            "cpu_util": 0.62,
            "mem_peak_gb": 0.45,
            "energy_kwh": plan.predicted_energy_kwh * 1.03,
            "completed_at": int(time.time() * 1000),
        }
        return {
            "plan_id": plan_id,
            "observed": simulated_observed,
            "note": "Simulated verification (offline mode)",
        }

    def snapshot(self) -> Dict[str, Any]:
        if self._endpoint and self._session:
            resp = self._session.get(f"{self._endpoint}/snapshot", timeout=5)
            resp.raise_for_status()
            return resp.json()

        assert self._state is not None
        return {"nodes": [node.name for node in self._state.list_nodes()]}


def ensure_client(client: Optional[Union[DTClient, str]]) -> DTClient:
    """Return a ``DTClient`` instance for the given handle."""

    if isinstance(client, DTClient):
        return client
    return DTClient(client)


__all__ = ["DTClient", "ensure_client"]
