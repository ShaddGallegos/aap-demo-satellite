---
type: Reference
title: Security policy and local trust controls
description: Report vulnerabilities and use the local lab's credential, TLS, and SSH trust safeguards.
tags: [security, trust, credentials]
---

# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, please report security issues by emailing [secalert@redhat.com](mailto:secalert@redhat.com). You should
receive a response within 48 hours. If for some reason you donot, please follow up to ensure we received your
original message.

Please include the following information in your report:

- Description of the vulnerability
- Steps to reproduce the issue
- Potential impact
- Suggested fix (if any)

## Supported Versions

Security updates are applied to the latest release on the `main` branch.

## Local-lab trust controls

The demo stores SSH host keys in its own state directories instead of changing
the user's global `known_hosts`. The default first-use mode is appropriate for
a private, disposable local lab. Higher-security deployments can require
fingerprint verification before first connection:

```bash
export AAP_DEMO_SSH_TRUST_MODE=verify
export AAP_DEMO_SSH_FINGERPRINTS='192.168.122.20:22=SHA256:<satellite-fingerprint>'
```

Use one comma-separated `host:port=SHA256:<fingerprint>` entry for every
managed SSH peer. `AAP_DEMO_SSH_TRUST_MODE=strict` instead requires an
already-enrolled managed host key. Never copy a fingerprint from the same
untrusted network path that is being verified.

Run `bash scripts/security-audit.sh` for a read-only review of repository
guardrails. It does not read credential Vault values. The optional `--strict`
mode makes unresolved findings fail the command.

## Disclosure Policy

Once a fix has been developed and tested, we will coordinate disclosure with the reporter. We aim to release
patches as quickly as possible depending on the complexity of the fix.
