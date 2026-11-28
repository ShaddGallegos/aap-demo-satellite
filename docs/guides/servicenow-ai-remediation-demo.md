---
type: Guide
title: ServiceNow-approved AI remediation demo
description: Build a bounded HTTP-service outage demo with EDA, AO, ServiceNow, Gitea, and Fleet.
tags: [servicenow, eda, automation-orchestrator, ai, remediation]
---

# ServiceNow-approved AI remediation demo

The optional `servicenow-ai-remediation` scenario is a controlled proof of
concept for an HTTP-service outage on a disposable Fleet node. It connects
Event-Driven Ansible, Automation Orchestrator, a selected LLM, ServiceNow, AAP,
and a private Gitea repository—but approval and a small remediation allow-list
remain authoritative.

Enable the scenario package only after reviewing its complete runbook:

```bash
SERVICENOW_AI_DEMO_PREPARE=true aap-demo enable servicenow-ai-remediation
```

That action prepares and validates local assets only; it does not contact
ServiceNow or a model, start EDA, create a ticket, or change a host. The package
documents the execution environment, decision environment, credentials, Gitea
review path, EDA rulebook, and AO workflow required for a live disposable-lab
trial. See the [scenario runbook](../../addons/servicenow-ai-remediation/README.md).

AAP documents that an EDA trigger in Automation Orchestrator uses a POST webhook
and requires an authorized service-account bearer token; the EDA activation must
send the normalized event to that generated endpoint. [Red Hat’s AO EDA trigger
guide](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/develop-add_an_event_driven_ansible_trigger)
describes that binding. Rulebooks and event payloads must match exactly; an
event-source mismatch does not establish a working remediation path. [See the
EDA troubleshooting guidance](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.5/html/using_automation_decisions/eda-rulebook-troubleshooting).

Do not use this pattern as an autonomous production repair loop. The demo limits
actions to starting `httpd` or `nginx`, requires ServiceNow approval, verifies
the result, records evidence, and stops after a small attempt limit. Any new
playbook stays a Gitea proposal subject to human review and does not run merely
because an LLM suggested it.
