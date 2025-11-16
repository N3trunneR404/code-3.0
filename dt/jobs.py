"""Shared job parsing utilities for the Digital Twin."""

from __future__ import annotations

from typing import Any, Dict, List

from dt.state import (
    Job,
    JobOrigin,
    JobStage,
    StageCompute,
    StageConstraints,
)


class JobSpecError(ValueError):
    """Raised when an incoming job specification is invalid."""


def _require(key: str, payload: Dict[str, Any]) -> Any:
    if key not in payload or payload[key] in (None, ""):
        raise JobSpecError(f"missing required field: {key}")
    return payload[key]


def parse_job_spec(job_spec: Dict[str, Any]) -> Job:
    """Convert an API-style job dictionary into a :class:`Job` instance."""

    if not isinstance(job_spec, dict):
        raise JobSpecError("job spec must be an object")

    metadata = job_spec.get("metadata") or {}
    spec = job_spec.get("spec") or {}
    stages_spec: List[Dict[str, Any]] = list(spec.get("stages") or [])

    if not stages_spec:
        raise JobSpecError("job spec must include at least one stage")

    name = str(_require("name", metadata))
    deadline_ms = int(metadata.get("deadline_ms", 60_000))

    origin_data = metadata.get("origin") or {}
    origin = None
    if origin_data:
        origin = JobOrigin(
            cluster=str(origin_data.get("cluster", "dc-core")),
            node=origin_data.get("node"),
        )

    stages: List[JobStage] = []
    for stage_spec in stages_spec:
        stage_id = str(_require("id", stage_spec))
        compute_spec = stage_spec.get("compute") or {}
        constraints_spec = stage_spec.get("constraints") or {}

        stage = JobStage(
            id=stage_id,
            compute=StageCompute(
                cpu=int(compute_spec.get("cpu", 0)),
                mem_gb=int(compute_spec.get("mem_gb", 0)),
                duration_ms=int(compute_spec.get("duration_ms", 0)),
                gpu_vram_gb=int(compute_spec.get("gpu_vram_gb", 0)),
                workload_type=str(compute_spec.get("workload_type", "cpu_bound")),
            ),
            constraints=StageConstraints(
                arch=list(constraints_spec.get("arch", ["amd64"])),
                formats=list(constraints_spec.get("formats", ["native"])),
                data_locality=constraints_spec.get("data_locality"),
                max_latency_to_predecessor_ms=constraints_spec.get(
                    "max_latency_to_predecessor_ms"
                ),
            ),
            predecessor=stage_spec.get("predecessor"),
        )
        stages.append(stage)

    return Job(name=name, deadline_ms=deadline_ms, stages=stages, origin=origin)


__all__ = ["parse_job_spec", "JobSpecError"]
