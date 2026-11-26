---
name: aap-security-guardrails
description: Review aap-demo changes for secret exposure, destructive-operation safety, trust boundaries, and missing verification controls. Use for security reviews, new credentials, external integrations, or privileged automation changes.
---

# AAP security guardrails

Use this skill when a change handles credentials, reaches an external service,
uses elevated privileges, changes trust, or adds a destructive action. It is a
review workflow; do not change a live environment, rotate credentials, commit,
or publish without explicit authorization.

## Review the relevant boundary

- Store sensitive values through `includes/credential-vault.sh`; never add
  values to examples, help, dashboard responses, command arguments, or tests.
- Prefer stdin, a protected temporary file, or a platform credential object
  over command-line passwords and tokens. Remove temporary material promptly.
- Keep remote cluster protection and operation locking intact. Destructive
  paths require scoped target discovery and explicit confirmation.
- Treat first-use host trust as a decision point. Existing managed host keys
  must not be silently replaced.
- Do not broaden `curl -k`, unbounded retries, cluster-admin access, or root
  SSH. Document any unavoidable local-lab exception at its use site.

## Verify

Run `bash scripts/security-audit.sh` and relevant focused tests. The audit is
report-only by default; use `--strict` only when a caller needs findings to
block a handoff. Review findings rather than suppressing them mechanically.

For a release or PR, also use `aap-release-validation`. For a user-visible
security setting, use `aap-feature-surface` to align help, documentation,
dashboard behavior, and tests.
