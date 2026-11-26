---
type: Guide
title: Private support bundles
description: Create redacted local evidence for troubleshooting without uploading credentials.
tags: [support, security, diagnostics]
status: draft
stale_after: 2027-01-28
resource: https://github.com/RedHatOfficial/aap-demo
---

# Private support bundles

Use a support bundle when a redacted system report is not enough for local
troubleshooting or a reviewed support case. It is not an automatic support-case
submission feature.

First inspect exactly what can be retained:

```console
aap-demo support-bundle preview
```

Create a new directory only after choosing an approved local destination:

```console
aap-demo support-bundle create --output /safe/local/aap-demo-support-2026-11-26
```

The collector creates owner-only files and directory permissions, gathers
redacted Markdown and JSON system inventory, writes a SHA-256 manifest, and
scans the generated evidence offline before retaining it. It never overwrites
an existing directory, contacts a vendor, sends email, or uploads anything.

Vault files and passwords, kubeconfig, pull secrets, private keys, raw logs,
and `must-gather` archives are deliberately excluded. If the scan finds a
secret-shaped value, the temporary collection is discarded and the command
fails. Review every retained file and its manifest before sharing it.

Run `aap-demo must-gather` separately only when its scope, retention location,
and transfer method have been approved. Its output can include sensitive
environment evidence and is not folded into this bundle automatically.
