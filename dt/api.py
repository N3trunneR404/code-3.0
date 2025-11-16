from __future__ import annotations

import uuid
from typing import Any, Dict

from flask import Flask, jsonify, request

from typing import Optional

from dt.actuator import Actuator
from dt.predict import PredictiveSimulator
from dt.state import DTState
from dt.jobs import parse_job_spec, JobSpecError
from dt.policy.greedy import GreedyLatencyPolicy
from dt.policy.resilient import ResilientPolicy
from dt.policy.cvar import RiskAwareCvarPolicy
from dt.cluster_manager import ClusterManager
from dt.seed import seed_state


def create_app(state: DTState, cluster_manager: Optional[ClusterManager] = None) -> Flask:
        app = Flask(__name__)
        # Store state in app config so it's accessible in all endpoints
        app.config['dt_state'] = state
        app.config['cluster_manager'] = cluster_manager
        
        sim = PredictiveSimulator(state)
        actuator = Actuator(cluster_manager=cluster_manager)

        def select_policy(name: str):
                name = (name or "greedy").lower()
                if name == "resilient":
                        return ResilientPolicy(state, sim, cluster_manager=cluster_manager)
                if name == "cvar":
                        return RiskAwareCvarPolicy(state, sim, cluster_manager=cluster_manager)
                return GreedyLatencyPolicy(state, sim, cluster_manager=cluster_manager)

        @app.post("/plan")
        def plan() -> Any:
                state = app.config['dt_state']
                # Safety check: ensure state is seeded
                nodes = state.list_nodes()
                if not nodes:
                        try:
                                seed_state(state)
                        except Exception:
                                pass
                
                body: Dict[str, Any] = request.get_json(force=True)
                job_spec = body.get("job")
                if not job_spec:
                        return jsonify({"error": "missing job spec"}), 400
                strategy = body.get("strategy", "greedy")
                dry_run = bool(body.get("dry_run", False))

                try:
                        job = parse_job_spec(job_spec)
                except JobSpecError as exc:
                        return jsonify({"error": str(exc)}), 400
                policy = select_policy(strategy)
                placements = policy.place(job)
                if not placements:
                        return jsonify({"error": "no feasible placements found", "stages": [s.id for s in job.stages]}), 400
                metrics = sim.score_plan(job, placements)
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
                if not dry_run:
                        try:
                                actuator.submit_plan(job, placements, plan_id=plan_id)
                        except Exception as e:
                                # Log error but don't fail the API response
                                # The plan was already computed and returned
                                import logging
                                logging.getLogger(__name__).error(f"Failed to submit plan {plan_id}: {e}")
                return jsonify(response)

        @app.post("/observe")
        def observe() -> Any:
                state = app.config['dt_state']
                body: Dict[str, Any] = request.get_json(force=True) or {}
                etype = body.get("type")
                node = body.get("node")
                
                if not etype or not node:
                        return jsonify({"error": "missing 'type' or 'node' field"}), 400
                
                try:
                        if etype == "node_down":
                                state.mark_node_availability(node, False)
                        elif etype == "node_up":
                                state.mark_node_availability(node, True)
                        else:
                                return jsonify({"error": f"unknown event type: {etype}"}), 400
                        return jsonify({"status": "ok", "node": node, "event": etype})
                except Exception as e:
                        return jsonify({"error": str(e)}), 500

        @app.get("/snapshot")
        def snapshot() -> Any:
                state = app.config['dt_state']
                # Safety check: ensure state is seeded
                nodes = state.list_nodes()
                if not nodes:
                        # Try to seed if not already seeded (for worker isolation)
                        try:
                                seed_state(state)
                                nodes = state.list_nodes()
                        except Exception:
                                pass
                return jsonify({"nodes": [n.name for n in nodes]})

        @app.get("/topology/virtual")
        def virtual_topology() -> Any:
                state = app.config['dt_state']
                try:
                        topology = state.describe_virtual_topology()
                except Exception:
                        topology = {}
                return jsonify({"virtual_topology": topology})

        @app.get("/plan/<plan_id>/verify")
        def verify_plan(plan_id: str) -> Any:
                """Get verification results for a plan."""
                state = app.config['dt_state']
                
                # Get observed metrics
                observed = state.get_observed_metrics(plan_id)
                if not observed:
                        return jsonify({"error": f"No observed metrics found for plan {plan_id}"}), 404
                
                # Return observed metrics
                # Note: In full implementation, predicted metrics would be retrieved from stored plan
                return jsonify({
                        "plan_id": plan_id,
                        "observed": {
                                "latency_ms": observed.latency_ms,
                                "cpu_util": observed.cpu_util,
                                "mem_peak_gb": observed.mem_peak_gb,
                                "energy_kwh": observed.energy_kwh,
                                "completed_at": observed.completed_at,
                        },
                        "note": "Predicted values should be retrieved from stored plan in full implementation"
                })

        return app
