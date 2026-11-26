---
type: Guide
title: Weekly health reports
description: Generate polished local health reports and captured email without operating an SMTP relay.
tags: [reports, operations, security]
---

# Weekly health reports

The optional reporting command turns the sanitized operations-steward state into
a polished HTML report, a plain-text alternative, and a local RFC 5322 `.eml`
capture. It does not install a mail server, create an open relay, or send data
to the network.

```bash
aap-demo reports generate
aap-demo reports send
```

`generate` creates the HTML and text files under `~/.aap-demo/reports/` with
private permissions. Open the HTML file in a browser to print it to PDF.
`send` creates the same report and puts an email-ready `.eml` message in the
private local capture mailbox at `~/.aap-demo/reports/outbox/`. This makes the
content reviewable before any future external delivery is considered. If the
dashboard owner declined local capture during first-run setup, `send` refuses
to create a message until the environment is reconfigured or zero-reset.

The localhost dashboard has a **Local mail** view that lists and opens the
plain-text part of these captured messages. On its first use, it asks whether
to enable the local capture mailbox. The choice is private local state and is
not asked again. Run `aap-demo reports --reconfigure` to clear only this
choice and be prompted once again; it preserves captured reports. A full
maintenance `--zero` reset also clears it. The dashboard never displays
rendered email HTML or raw message headers, so captured content cannot execute
in the browser.

## Contents and limits

The report includes current steward findings, enabled add-ons, known optional
capabilities that are not enabled, and clear advisory/CVE limits. It never
claims CVE coverage without an approved advisory source, and it never copies
raw logs, Vault values, credentials, customer IDs, or support attachments.

Generating a report runs the same read-only health checks as
[`aap-demo steward scan`](operations-steward.md). It does not launch jobs,
restart services, patch hosts, invoke an LLM or MCP tool, or contact a vendor.

## External email and scheduling

External delivery requires a customer-approved, authenticated SMTP relay,
named recipients, retention rules, and a review of the sanitized content.
Those details are intentionally not guessed or configured by this initial
feature. Do not run a local SMTP relay for this purpose: an incorrectly
configured relay can expose the host to abuse.

When delivery is added, SMTP credentials must live only in the encrypted
[credential Vault](credential-vault.md), and enabling a weekly schedule must
be a separate explicit action. The schedule must never send a report until a
user approves the recipient list and performs a test delivery.
