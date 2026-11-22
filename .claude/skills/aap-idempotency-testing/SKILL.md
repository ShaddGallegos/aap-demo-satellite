---
name: aap-idempotency-testing
description: >
  Test repeated aap-demo create, enable, start, wiring, and registration
  operations for unintended changes or duplicate resources. Use for
  idempotency regressions and resource-reuse verification.
---

# AAP idempotency testing

## Define the expected invariant

Read the relevant command/addon documentation and
[testing guidance](../../../CONTRIBUTING.md). Identify the exact operation,
backend, CLI variant, existing state, and resources it owns.

Idempotency means the requested desired state is preserved without unintended
changes. Not every operation is strictly read-only on a second invocation:
documented manifest refresh, token rotation, maintenance discovery, or
reconciliation may be intentional. Do not normalize these differences away
without explaining and verifying their contract.

## Start with isolated tests

Choose the existing test covering the changed behavior:

- Startup: `bash test/test-start.sh`.
- Satellite lifecycle: `bash test/test-satellite-maintenance.sh`.
- Fleet registration: `bash test/test-fleet-satellite.sh`.
- Satellite addon: `bash test/test-product-demo-satellite.sh`.
- Full-demo sequencing: `bash test/test-full-demo.sh`.
- Removal safeguards: `bash test/test-maintenance.sh` (mocked, not live removal).

Read the chosen test first to verify isolation. Add only focused cases for
the behavior being fixed: already present, partially configured, failed
dependency, and retry where relevant. Assert no duplicate resources,
unnecessary installer execution, hidden failures, or loss of user settings.

## Optional live comparison

Run status and diagnosis first. Obtain explicit approval for the exact command
and its repetition: the live helper runs the supplied command twice.
Never use destructive operations, uninstall, or unrestricted shell input as
an idempotency probe.

From the repository root, an approved Bash wiring check can use:

```bash
AAP_DEMO_LIVE_IDEMPOTENCY=1 bash test/test-live-idempotency.sh -- bash ./aap-demo.sh wire
```

Inspect [the live helper](../../../test/test-live-idempotency.sh) before use.
It compares selected Kubernetes desired-state specs, not every resource or
external system. It skips optional APIs only when discovery shows they are
absent; failed discovery or reads, invalid or empty snapshots, and changes to
the discovered resource set fail the check. Check coverage separately: a
successful comparison is not proof of idempotency outside the selected resources.

Compare external VM identity, disks, registrations, content, and retained
backups separately when relevant. Do not print Secret values or private keys.

## Result

Report the tested operation, initial state, repetitions, expected changes,
unexpected differences, and coverage limits. Require both stable intended
state and functional postconditions; a zero exit code alone is insufficient.
