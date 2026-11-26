---
type: Guide
title: OpenShift Quay proof of concept
description: Install an owned Red Hat Quay Operator prerequisite without creating a registry.
tags: [openshift, quay, registry, addon]
status: draft
stale_after: 2027-11-26
---

# OpenShift Quay proof of concept

`openshift-quay` is an optional, deliberately narrow proof of concept. It
installs the Red Hat Quay Operator from a configured Red Hat Operator catalog,
then waits for its installed CSV.

It does **not** create a `QuayRegistry`, object storage, persistent volumes,
routes, certificates, identity providers, users, robot accounts, repository
mirroring, Clair scanning, registry credentials, or image content. The legacy
development registry add-on is separate; this scenario neither changes nor
depends on it.

## Before enabling

- Use an OpenShift cluster with OLM and a reachable Red Hat Operator
  `CatalogSource`.
- Reserve at least 2 GiB of memory and 4 GiB of VM storage in addition to the
  rest of the lab.
- Confirm entitlement, storage, backup, identity, route, TLS, and retention
  requirements with the customer before creating a registry instance.

The default values are the `redhat-operators` CatalogSource in
`openshift-marketplace` and an aap-demo-owned `aap-demo-quay-operator`
namespace. You can override catalog or namespace values without changing files:

```bash
QUAY_CATALOG_SOURCE=redhat-operators \
QUAY_CATALOG_NAMESPACE=openshift-marketplace \
aap-demo enable openshift-quay
```

`QUAY_WAIT_SECONDS` controls the readiness wait and defaults to 900 seconds.

## Ownership and removal

Every object has `aap-demo/openshift-quay: managed`. The add-on refuses to
modify an existing namespace, OperatorGroup, or Subscription unless that label
is present. Disabling removes only the owned Quay operator namespace:

```bash
aap-demo disable openshift-quay
```

It never removes unrelated Quay instances, registry data, or shared catalog
resources.

## Next deliberate step

Red Hat Quay registry deployments are defined by a `QuayRegistry` custom
resource, including managed versus external components and storage choices.
Review Red Hat's [Quay deployment guidance](https://docs.redhat.com/en/documentation/red_hat_quay/3/html/deploying_the_red_hat_quay_operator_on_openshift_container_platform/deploying-quay-registry)
before creating one.
