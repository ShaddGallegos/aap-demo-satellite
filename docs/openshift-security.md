---
type: Guide
title: OpenShift security proof of concept
description: Install an owned RHACS Operator prerequisite without configuring security monitoring.
tags: [openshift, security, rhacs, addon]
status: draft
stale_after: 2027-11-26
---

# OpenShift security proof of concept

`openshift-security` is an optional, deliberately narrow proof of concept. It
installs the Red Hat Advanced Cluster Security for Kubernetes (RHACS) Operator
from a configured Red Hat Operator catalog, then waits for its installed CSV.

It does **not** create RHACS Central, a `SecuredCluster`, an init bundle,
policies, vulnerability scans, integrations, credentials, or customer
workloads. Those steps need an explicit design and approval because they can
connect clusters, collect security telemetry, and change security posture.

## Before enabling

- Use an OpenShift cluster with OLM and a reachable Red Hat Operator
  `CatalogSource`.
- Reserve at least 2 GiB of memory and 4 GiB of VM storage in addition to the
  rest of the lab.
- Confirm entitlement and product suitability with the customer's Red Hat
  account team.

The default values are the `redhat-operators` CatalogSource in
`openshift-marketplace` and an aap-demo-owned `rhacs-operator` namespace. You
can override the catalog or namespace without modifying files:

```bash
RHACS_CATALOG_SOURCE=redhat-operators \
RHACS_CATALOG_NAMESPACE=openshift-marketplace \
aap-demo enable openshift-security
```

`RHACS_WAIT_SECONDS` controls the readiness wait and defaults to 900 seconds.

## Ownership and removal

Every object has `aap-demo/openshift-security: managed`. The add-on refuses to
modify an existing namespace, OperatorGroup, or Subscription unless that label
is present. Disabling removes only the owned RHACS operator namespace:

```bash
aap-demo disable openshift-security
```

It never removes unrelated RHACS instances or shared catalog resources.

## Next deliberate step

RHACS requires a Central custom resource before a SecuredCluster can be
configured. Plan Central storage, data retention, identity, certificates,
network reachability, and the handling of init bundles before creating either
resource. Red Hat's [RHACS OpenShift installation guidance](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.8/html/installing/installing-rhacs-on-red-hat-openshift)
documents these placement and dependency requirements.
