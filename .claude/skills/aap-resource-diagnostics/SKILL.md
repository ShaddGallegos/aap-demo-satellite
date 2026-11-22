---
name: aap-resource-diagnostics
description: >
  Diagnose local aap-demo CPU metrics, HPA failures, memory pressure,
  scheduling, PVCs, and disk capacity. Use for missing metrics APIs,
  unknown HPA targets, Pending pods, OOM kills, or storage warnings.
---

# AAP resource diagnostics

## Baseline

Read [settings](../../../docs/reference/settings.md),
[full OpenShift guidance](../../../docs/adr/020-full-openshift-support.md),
and [the older command guide](../../../docs/guides/older-command.md).
Run `aap-demo status` and `aap-demo diagnose`; verify local context, preset,
affected namespace, and workload ownership. Inspect before changing anything.

## CPU metrics and HPA

1. Inspect `kubectl get hpa -A`, then describe the affected HPA. Read its
   conditions/events and target workload, not just the warning headline.
2. Check `kubectl get apiservice v1beta1.metrics.k8s.io` and its availability.
   If present, inspect its backing service, endpoints, pods, and logs.
   An absent API, unavailable backend, and unavailable pod samples are
   different failures.
3. If samples are available, inspect target container CPU requests.
   Utilization-based scaling needs appropriate requests; missing requests
   are not fixed by reinstalling a metrics provider.
4. On full OpenShift, inspect monitoring operator state, ClusterVersion
   overrides, and `crc config get enable-cluster-monitoring`.
   CRC can intentionally omit monitoring. Do not install an upstream
   metrics-server over OpenShift-managed components.
5. On MicroShift, inspect the existing metrics-server setup in
   [cluster creation](../../../includes/crc-create.sh); reuse its path only
   after confirming that this is actually MicroShift.

Enabling full CRC monitoring consumes additional resources. Check current
[CRC monitoring documentation](https://crc.dev/docs/administrative-tasks/#_starting_monitoring)
before proposing a change; it documents a recreation requirement to remove
monitoring later. Obtain explicit approval before enabling it or restarting
CRC. If declined, report autoscaling unavailable and observed replica counts,
without claiming HPA fallback behavior is guaranteed.

## Memory, scheduling, and storage

- Inspect node conditions/allocatable resources, workload requests/limits,
  Pending pod events, and previous container termination reasons. Distinguish
  scheduling constraints, OOMKilled, eviction, and application failures.
- If metrics are absent, do not invent utilization from requested resources.
  Use host/guest memory and disk observations as separate evidence.
- Inspect storage classes, PVC binding, provisioner health, and actual free
  capacity. A missing TopoLVM class is not automatically a failure when the
  selected backend uses another RWO provisioner and working NFS.
- Do not delete PVCs, prune images, resize/rebuild VMs, change limits, disable
  HPAs, or scale unrelated workloads as a diagnostic shortcut.

## Result

Report root cause with supporting observations, functional impact, and the
smallest proposed repair. Ask before resource allocation, monitoring changes,
or disruption. Verify real metrics/HPA conditions or scheduling/storage
postconditions after an approved repair; distinguish warnings from blockers.
