---
type: Guide
title: Scenario matrix harness
description: Generate a bounded, non-live addon compatibility report before disposable-lab qualification.
tags: [testing, addons, safety]
status: draft
stale_after: 2027-01-28
resource: https://github.com/RedHatOfficial/aap-demo
---

# Scenario matrix harness

Do not attempt to install every mathematical addon combination on a shared
machine. With the current public addon set, that is tens of millions of
non-empty combinations and can create clusters, VMs, subscriptions, and
external service state.

Generate a safe planning report instead:

```console
python3 scripts/scenario-harness.py --output /tmp/aap-demo-scenario-matrix.md
```

The report inventories the public addon list, validates the scenario contracts
that exist, closes declared dependencies, and produces singleton and pairwise
cases. It also lists missing contracts as blockers; it does not guess
compatibility or run installers.

To include the isolated non-live regression suite in the report:

```console
python3 scripts/scenario-harness.py --run-unit --output /tmp/aap-demo-scenario-matrix.md
```

Use `--strict` in CI or review tooling when invalid or incomplete contract
coverage must fail the command. The current public addon set is fully
contracted; adding a new public addon without a contract makes strict mode fail.

Live matrix execution is intentionally not available from this harness. It
requires a disposable approved lab, supplied subscriptions and external
services, redacted evidence retention, and an explicit teardown plan limited
to owned resources.
