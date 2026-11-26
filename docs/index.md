---
type: Guide
title: AAP Demo documentation
description: Where to start, and the list of guides, references, and examples.
tags: [overview, okf]
status: draft
stale_after: 2027-01-28
resource: https://github.com/RedHatOfficial/aap-demo
---

# AAP Demo documentation

The [project home page](../README.md) is the short start. These pages are the rest.

## Guides

- [Install](guides/install.md) - Put the `aap-demo` command on your computer and update it later.
- [First deploy](guides/first-deploy.md) - Create the local cluster and install Ansible Automation Platform.
- [Choose a version](guides/choose-a-version.md) - Deploy AAP 2.7 or try 2.6.
- [Subscription](guides/subscription.md) - Get a manifest and apply it, or sign in through AAP.
- [Daily use](guides/daily-use.md) - Start, stop, pause, and check the cluster.
- [Add-ons](guides/addons.md) - Practice machines, product demos, and extras that still use the older command.
- [Addon scenario contracts](addon-scenario-contracts.md) - Lifecycle, dependency,
  ownership, readiness, and security boundaries for complex addons.
- [OpenShift delivery proof of concept](openshift-delivery.md) - Opt-in GitOps and
  Pipelines operators without creating customer workloads.
- [The older command](guides/older-command.md) - Keep using the bash command for work that has not moved over.
- [Pause and resume the full lab](guides/older-command.md#pause-for-travel-without-deleting-data) -
  Shut down Fleet, CRC, and Satellite without deleting data.
- [Assistant skills](guides/assistant-skills.md) - Task-focused validation, recovery, and publication workflows.
- [Local AI integrations](guides/ai-integrations.md) - MCP, Ollama, and supported product integration paths.
- [Operations steward](operations-steward.md) - Local, redacted, read-only issue tracking and safe future-agent boundaries.
- [Weekly health reports](weekly-reports.md) - Styled local HTML reports and captured email, without an SMTP relay.
- [Collection authentication](collection-authentication.md) - Keep the separate
  Automation Hub token in the encrypted Vault and diagnose Pulp sync failures.
- [Credential Vault](credential-vault.md) - Managed secret locations, ownership,
  and safe configuration paths.
- [Lightwell CI/CD simulation](../addons/lightwell/README.md) -
  Prepared-service integration, human approvals, and dashboard links.
- [Local Gitea VM](../addons/gitea/README.md) -
  Fedora 45 outside CRC, host-backed NFS, trusted Git access and dashboard controls.
- [Satellite lab](../satellite-lab/README.md) -
  Local Satellite lifecycle, image-based general VM provisioning, and Virt-Manager visibility.

## Concepts

- [What aap-demo is](concepts/what-aap-demo-is.md) - A local demo tool, and what the 2.0.0 release candidate is.
- [Two ways to run it](concepts/two-ways-to-run.md) - The new command and the older one, and why both still matter.

## Reference

- [Commands](reference/commands.md) - What each command does.
- [Settings](reference/settings.md) - Memory, disk, channels, and file locations.
- [Security policy and local trust controls](SECURITY.md) - Report issues and pin
  first-use SSH trust when the default local-lab model is not appropriate.
- [Roadmap and agent prompt](ROADMAP.md) - Selectable tasks, priorities, safeguards, and acceptance criteria.

## Examples

- [First cluster](examples/first-cluster.md) - From an empty machine to a page you can open.
- [AAP 2.6](examples/aap-2-6.md) - One deploy that asks for the 2.6 channel.
