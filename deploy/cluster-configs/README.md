# k3d cluster config presets

This directory holds config files for the multi-cluster lab topology used by `deploy/multi-cluster-setup.sh` and documentation walkthroughs. Each file follows the current `k3d` schema (`kind: Simple`) and mirrors the inline settings from the helper script:

- isolated docker networks per cluster (matching the `dt-<name>` pattern)
- explicit cluster and service CIDRs to avoid defaults changing across releases
- kubeconfig updates disabled by default so automation can manage contexts explicitly

You can create an individual cluster directly with:

```bash
k3d cluster create --config deploy/cluster-configs/<cluster>.yaml
```

The setup script still prefers CLI flags for portability, but the configs allow manual bring-up while keeping schema validation happy on newer k3d versions.
