---
name: satellite-lifecycle
description: >
  Manage the local Satellite lab lifecycle: manifests, existing-install
  detection, supported maintenance, backups, Fleet registration, and safe
  uninstall. Use when installing, upgrading, repairing, or removing Satellite.
---

# Satellite lifecycle

## Preparation

Read [the Satellite lab guide](../../../satellite-lab/README.md),
[manifest addon guidance](../../../addons/satellite-manifest/README.md), and
[the older command guide](../../../docs/guides/older-command.md).
Run status and diagnosis using the correct local CLI and kubeconfig.
Discover the configured VM, content organization, release, storage, and
registration state; do not infer installation from a VM name or open port.

Keep tokens, manifests, entitlement data, and private SSH keys out of logs
and source control. Use existing encrypted credential storage and CLI helpers.

## Workflow

1. For a requested build, use the existing
   `aap-demo create --full-demo --satellite` orchestration. Explain that an
   existing server can receive maintenance, service downtime, and reboots.
   Confirm that this scope and downtime are approved before execution.
2. Reuse the builder's installed-RPM checks and incomplete-install safeguards.
   Preserve existing administrator, organization, network, and installer
   settings. Never force a reinstall to bypass a health failure.
3. Use `aap-demo fleet auth` when interactive authentication is needed.
   Use `aap-demo enable satellite-manifest` for allocation and manifest
   processing. Inspect eligibility and existing allocation first; never
   attach arbitrary subscriptions merely to clear an addon status.
4. If only manifest refresh is requested, use
   `bash satellite-lab/build-and-configure.sh --manifest-only`.
   Respect explicit organization selection when discovery is ambiguous.
5. For upgrades, use the builder and
   [maintenance implementation](../../../satellite-lab/maintain-satellite.sh).
   Verify backup destination capacity and mount state before changes.
   Retain full offline backups, native prechecks, and sequential supported
   minor upgrades. Stage only the maintenance wrapper and gem with the
   scoped protector exception; native tooling owns the server upgrade.
6. Do not bypass checks, skip broken packages, force dependency removal,
   automatically change RHSM release pins, or attempt an OS-major migration.
   A failed precheck or backup stops maintenance. There is no automatic
   backup restoration on failure.
7. For requested integration, reuse `aap-demo fleet satellite-register` and
   `aap-demo enable product-demo-satellite`. Simple Content Access does not
   require obsolete Hammer auto-attach options. Activation-key preparation
   must return the exact configured key or fail.

## Removal and verification

Uninstall requires explicit confirmation. Preview with
`aap-demo maintenance uninstall` before any `--apply` operation. Preserve the
CLI's managed-VM ownership checks; never substitute raw libvirt deletion.
Preserve unrelated VMs, networks, external Satellite servers, and backups.

After an approved change, check the installed version, service/native health,
HTTPS, backup mount, exact activation key, registered hosts, and inventory
sync. Use `aap-integration-validation` for end-to-end checks. Report what
changed, which backups exist, and any unverified recovery path.
