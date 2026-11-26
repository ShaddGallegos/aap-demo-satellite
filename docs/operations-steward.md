---
type: Guide
title: Operations steward
description: Safely collect local read-only health findings and track them without autonomous changes.
tags: [operations, diagnostics, security]
---

# Operations steward

The optional operations steward is a local, read-only issue tracker. It runs
approved health checks, redacts credential-shaped values before retaining their
output, and creates `FIX_TRACKING.md`. It is the first foundation for a future
human-supervised operations assistant; it is not an autonomous repair agent.

Run a scan from the directory where you want the generated report:

```bash
aap-demo steward scan
```

Use a deliberate output path when the report should not be in the current
directory:

```bash
aap-demo steward scan --output "$HOME/aap-demo-reports/FIX_TRACKING.md"
```

`aap-demo steward report` re-renders the existing local state without querying
the cluster. The command refuses to overwrite a file it did not create. The
generated `FIX_TRACKING.md` is ignored by Git because it can identify local
hardware or applications.

## What it inspects

The steward invokes only the existing read-only `preflight`, `diagnose`, and
`check-integrations` handlers. It neither launches jobs nor uses MCP tools.
It records failed checks and warnings as deterministic IDs. Findings seen on a
later scan stay **open**; findings not seen again become **watching**, rather
than being silently treated as fixed.

Private sanitized evidence and state are stored under
`~/.aap-demo/steward/` (or `AAP_DEMO_STEWARD_DIR`) with restrictive modes.
The command does not read, decrypt, copy, or include values from the Ansible
Vault. Do not put customer identifiers, access tokens, support attachments, or
unredacted logs in `FIX_TRACKING.md`.

## Explicitly deferred capabilities

Phase 1 deliberately does not use an LLM, Red Hat Lightspeed, an MCP server,
a scheduler, advisory feeds, remediation playbooks, or vendor APIs. Future
phases must keep these controls:

- LLM analysis receives only a separately reviewed, sanitized summary and has
  no shell, cluster, Vault, or ticketing tool access.
- A repair is a reviewed, idempotent AAP workflow with preflight and human
  approval; the steward never repairs by itself.
- An advisory watcher reports a candidate fix and version match. It never
  patches a host automatically.
- A support-case connector creates a redacted draft first. Submission requires
  a supported vendor integration, explicit account selection, and a deliberate
  confirmation. Store connector credentials only in the encrypted credential
  Vault.

Ansible Lightspeed and Satellite MCP must not become the unattended control
plane merely because they can summarize data. Follow the product support and
Technology Preview boundaries documented in the [AI integration guide](guides/ai-integrations.md).
