---
name: openshift-safe-recovery
description: >
  Investigate local CRC restart failures, degraded MachineConfig pools,
  operator-owned DNS, and container-policy drift. Use for OpenShift recovery
  while preserving operator ownership and unrelated host workloads.
---

# OpenShift-safe recovery

## Establish ownership before repair

Read [restart guidance](../../../docs/guides/older-command.md) and
[full OpenShift architecture](../../../docs/adr/020-full-openshift-support.md).
Start with `aap-demo status` and `aap-demo diagnose`. Confirm the kubeconfig
targets the intended local cluster. A shared host is not disposable.

Discover the preset through CRC configuration and cluster API resources.
Failure to contact the API is not evidence that the cluster is MicroShift.
Full OpenShift and MicroShift have different ownership and recovery paths.

## Read-only investigation

1. Compare CRC state with API reachability, node readiness, and the supported
   SSH forward. "Running" does not guarantee a responsive guest.
2. On full OpenShift inspect cluster operators, master MachineConfigPool,
   node current/desired MachineConfig annotations, relevant daemon logs,
   and events. Treat MCO degradation as a real failure, not cosmetic.
3. Inspect the active container policy and exact rendered configuration
   before attributing drift. Keep any necessary snapshots private.
4. For DNS, inspect the operator's state and actual resolution from affected
   workloads. Check AO route host aliases through
   [existing wiring](../../../includes/addon-wire.sh). Do not prescribe a
   MicroShift Corefile rewrite on full OpenShift.
5. Separate expected CRC footprint overrides from newly degraded operators.
   Do not remove all ClusterVersion overrides as a generic recovery action.

## Repair boundaries

- Explain the evidence and obtain approval before stop/start, pod deletion,
  service restart, host reboot, policy restoration, or other disruption.
- Prefer `aap-demo start` and existing recovery helpers. They reconcile the
  configured demo; do not manually rebuild every component.
- Never directly rewrite MCO-owned policy or operator-owned CoreDNS as a
  workaround. Do not use blanket force-validation or disable operators.
- A targeted restoration of known drift requires exact rendered bytes,
  matching current/desired configuration, proof of the specific drift,
  a private backup, and explicit approval. If any condition is missing,
  stop and present evidence instead of guessing at the expected file.
- Use supported CRC `core` access with sudo. Do not add CoreOS users or
  enable root SSH. Never kill processes by name or alter unrelated VMs.
- If distinct repair attempts fail, collect bounded diagnostics with
  `aap-demo must-gather`; inspect/redact before sharing.

## Verify

Check API readiness, node Ready, pool Updated and not Degraded, relevant
operators Available and not Degraded, application readiness, and actual
integration access. Distinguish a missing metric from broken networking.
Report the exact repairs and remaining failures; do not claim a reboot
recovery test unless one was actually approved and performed.
