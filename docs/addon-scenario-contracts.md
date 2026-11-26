---
type: Reference
title: Addon scenario contracts
description: Machine-readable lifecycle, dependency, ownership, readiness, and security boundaries for aap-demo addons.
tags: [addons, automation, idempotency, security]
---

# Addon scenario contracts

Every public addon provides `addons/<name>/scenario.json`. This is a public,
non-secret contract for how the scenario is managed. The Bash command validates
it before invoking that addon's `deploy.sh`.

The contract records:

- lifecycle entry points, idempotency promise, and failure boundary;
- addon and service dependencies;
- explicit incompatible addon combinations;
- variable sources, with secret inputs restricted to encrypted Vault paths;
- owned resources, readiness checks, and security constraints.

It must never include a password, token, pull secret, private key, customer
identifier, or live endpoint credential. Describe the source of a secret, not
its value.

Validate one directly while developing:

```bash
python3 scripts/validate-addon-contract.py addons/product-demo-satellite/scenario.json
```

The first migrated scenario is `product-demo-satellite`. Its contract captures
the split between the synchronized upstream APD project and the retained
aap-demo bootstrap project used for local overlays. This prevents a controller
task-volume assumption from becoming a credential-wiring failure.

New complex scenarios should add a contract before adding orchestration code.
Keep the contract aligned with its addon README and regression tests.
