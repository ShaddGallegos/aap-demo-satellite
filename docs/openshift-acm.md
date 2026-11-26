---
type: Guide
title: OpenShift ACM proof of concept
description: Install an owned ACM Operator prerequisite without creating a management hub.
tags: [openshift, acm, multicluster, addon]
status: draft
stale_after: 2027-11-26
---

# OpenShift ACM proof of concept

`openshift-acm` installs only the owned Red Hat Advanced Cluster Management
(ACM) Operator subscription and waits for its installed CSV. It does **not**
create a `MultiClusterHub`, import or manage any cluster, create policies,
credentials, compliance rules, observability resources, or workloads.

```bash
aap-demo enable openshift-acm
```

The defaults use `redhat-operators` in `openshift-marketplace` and the
aap-demo-owned `open-cluster-management` namespace. `ACM_CATALOG_SOURCE`,
`ACM_CATALOG_NAMESPACE`, `ACM_OPERATOR_NAMESPACE`, and `ACM_WAIT_SECONDS` are
optional environment overrides; the wait defaults to 900 seconds.

Every object has `aap-demo/openshift-acm: managed`; removal refuses unowned
resources and deletes only the owned operator namespace. Before creating a
`MultiClusterHub`, plan its capacity, identity, storage, upgrade strategy,
network reachability, managed-cluster lifecycle, and policy ownership. ACM's
[installation guide](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/install/installing)
details the hub and component implications.
