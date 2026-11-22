---
type: Guide
title: Repository assistant skills and optional agents
description: Task-focused skills and opt-in agents for validating and maintaining the local AAP demo.
---

# Repository assistant skills and optional agents

The repository includes assistant instructions under
[`.claude/skills/`](../../.claude/skills/). Each skill has a `SKILL.md` with a
name, activation description, workflow, and safety boundaries. Skills guide an
assistant; they do not install services, add CLI commands, or run automatically
as background health checks.

## Available operational workflows

| Skill | Use it for | Example request |
|-------|------------|-----------------|
| [aap-integration-validation](../../.claude/skills/aap-integration-validation/SKILL.md) | Checking actual integration access | "Verify AO, AAP, MCP, Ollama, and Satellite wiring." |
| [satellite-lifecycle](../../.claude/skills/satellite-lifecycle/SKILL.md) | Manifests, maintenance, registration, and removal | "Check the existing Satellite before planning an upgrade." |
| [openshift-safe-recovery](../../.claude/skills/openshift-safe-recovery/SKILL.md) | CRC recovery without fighting operators | "Investigate the degraded master MachineConfigPool." |
| [aap-idempotency-testing](../../.claude/skills/aap-idempotency-testing/SKILL.md) | Repeated operations and resource reuse | "Test whether enabling Satellite twice changes unintended state." |
| [aap-release-validation](../../.claude/skills/aap-release-validation/SKILL.md) | Validation before publishing | "Check these changes before I push and open a PR." |
| [aap-resource-diagnostics](../../.claude/skills/aap-resource-diagnostics/SKILL.md) | HPA metrics, memory, scheduling, and storage | "Explain why the HPA reports unknown CPU utilization." |
| [aap-feature-surface](../../.claude/skills/aap-feature-surface/SKILL.md) | Keeping a feature discoverable and consistent across CLI help, docs, dashboard, and tests | "Add this feature and update every user-facing surface." |

These complement the existing environment-management, addon-development,
architecture-decision, and issue-authoring skills.

## Using a skill

Open the repository in a skill-aware assistant and describe the task, or
explicitly request the skill by name. Discovery and slash-command support
depend on the assistant. If a new skill is not listed, refresh the session
or ask the assistant to read its linked `SKILL.md`; no cluster restart is
needed. These files are not guaranteed to appear in every editor integration.

For example:

```text
Use aap-integration-validation to check this local demo without changing it.
Use aap-resource-diagnostics to investigate the HPA error; do not enable monitoring.
Use aap-release-validation to run checks only; do not commit or push.
```

## Optional agents

Three focused agents are available in [`.github/agents/`](../../.github/agents/)
for compatible Copilot clients:

| Agent | Assignment | Reused skill |
|-------|------------|--------------|
| [aap-integration-validator](../../.github/agents/aap-integration-validator.agent.md) | Inspect live wiring without repairing services | `aap-integration-validation` |
| [aap-regression-tester](../../.github/agents/aap-regression-tester.agent.md) | Run focused isolated tests; report failures without editing code | `aap-idempotency-testing` |
| [aap-release-reviewer](../../.github/agents/aap-release-reviewer.agent.md) | Review publication readiness without committing or publishing | `aap-release-validation` |

These are optional assistant roles, not cluster addons, daemons, CLI
dependencies, or mandatory steps. Normal `aap-demo` usage is unchanged.
They have no scheduled hooks, automatic handoffs, or nested delegation.
Each definition sets `user-invocable: true` and
`disable-model-invocation: true` so users can select it without automatic
model-selected delegation in supporting clients. No model is pinned.

In VS Code, open this repository and use **Chat: Open Customizations** to
inspect the agents, then select the desired agent from the chat agent picker.
Switch back to the general-purpose agent when finished. If discovery has
not refreshed, start a new chat or reload the editor window. Other clients
may differ; these are Copilot-format agents, not Claude-format agent files.

Example requests after selecting the corresponding agent:

```text
Check the enabled local integrations; report evidence and do not repair anything.
Run the isolated tests relevant to this diff; do not run live tests or edit files.
Review this branch for publication; do not commit, push, or open a PR.
```

The agents load the linked skills, with direct file reads as a fallback.
Their tool lists include reading, searching, and terminal execution for
diagnostic probes and test commands, but not editing or agent delegation.
Terminal execution is powerful: a read-only role instruction is not an OS
sandbox or command-level permission boundary. Review terminal approvals and
tool activity. Client support and enforcement can vary; see the official
[custom agent reference](https://code.visualstudio.com/docs/agents/reference/custom-agent-file-reference).
No live agent behavior is implied merely by a valid definition.

The specialist skills for Satellite lifecycle, safe recovery, and resource
diagnostics remain usable without additional agents. Disruptive repairs and
publication belong in separate, explicitly approved tasks, not automatic
follow-up actions by these reviewers.

## Scope and approvals

The workflows reuse existing CLI commands, helpers, and tests rather than
maintaining a second implementation. They distinguish the Python command
from the older Bash command; see [the older command guide](older-command.md).
They discover configured hosts and namespaces instead of encoding one
maintainer's environment.

Inspection starts read-only. Rewiring, live repeated-operation tests, upgrades,
restarts, and destructive operations need the appropriate user approval.
Secrets must not enter chat, logs, process arguments, or committed artifacts.
Reports distinguish verified behavior from disabled, failed, and untested
integrations. None of these workflows certify production readiness.

Contribution and release requirements remain in
[CONTRIBUTING](../../CONTRIBUTING.md). These skills are not a replacement for
that policy or the indexed project documentation.
