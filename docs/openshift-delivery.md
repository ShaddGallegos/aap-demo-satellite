---
type: Guide
title: OpenShift delivery proof of concept
description: Opt-in Red Hat OpenShift GitOps and Pipelines operators for an aap-demo delivery scenario.
tags: [openshift, gitops, pipelines, addons]
---

# OpenShift delivery proof of concept

The optional `openshift-delivery` addon installs two Red Hat operator
subscriptions: OpenShift GitOps and OpenShift Pipelines. It gives a demo
environment the platform capabilities needed to show a delivery path from
versioned source to a reviewed deployment.

It deliberately does **not** create a Git repository, repository credential,
Argo CD `Application`, Tekton `PipelineRun`, webhook, route, or workload. Those
actions need a customer-owned target and an explicit demo design.

## Prerequisites

- A running cluster with OLM installed.
- The configured Red Hat operator `CatalogSource` available in
  `openshift-marketplace`.
- At least 4 GiB of available cluster memory and 14 GiB of VM storage headroom.

The addon reads each package's default channel from the catalog instead of
hard-coding a release channel. This keeps it aligned with the catalog that the
cluster administrator has chosen.

## Enable and inspect

```bash
aap-demo enable openshift-delivery
kubectl get subscription,csv -n openshift-gitops-operator
kubectl get subscription,csv -n openshift-operators
```

The Dashboard **Add-ons** view shows the optional scenario and its running
controller health. It never starts an operator installation without the
dashboard user's explicit **Enable** action.

To use a non-default catalog location or to allow more rollout time, provide
only non-secret environment settings for the one invocation:

```bash
OPENSHIFT_DELIVERY_CATALOG_SOURCE=redhat-operators \
OPENSHIFT_DELIVERY_CATALOG_NAMESPACE=openshift-marketplace \
OPENSHIFT_DELIVERY_WAIT_SECONDS=1200 \
aap-demo enable openshift-delivery
```

## Disable

```bash
aap-demo disable openshift-delivery
```

Disable removes only the two subscriptions owned by aap-demo and the dedicated
GitOps operator namespace when it carries the aap-demo ownership label. It does
not delete the shared `openshift-operators` namespace, a pre-existing operator,
or customer resources.

## Next demonstration step

After the operators are ready, add a separate, reviewed scenario that connects
a local Gitea repository to a namespace-scoped Argo CD application and Tekton
pipeline. Keep repository credentials in the encrypted Vault and require an
explicit approval before a PipelineRun or production-like deployment is
created.
