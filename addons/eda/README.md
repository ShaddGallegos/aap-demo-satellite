---
type: Guide
title: Event-Driven Ansible add-on
description: Enable the AAP-managed Event-Driven Ansible service without creating event automations.
---

# Event-Driven Ansible add-on

Enable the AAP-managed Event-Driven Ansible (EDA) service:

```bash
aap-demo enable eda
```

This reconciles the local AAP custom resource so EDA can run. It does not add
an event stream, credentials, rulebook activation, Kafka broker, or any
automation that changes infrastructure. Automation Orchestrator and the
Lightwell profile enable EDA as a dependency.

The APD EDA scenario is separate because it has external event-source
requirements. Opt in only after preparing those requirements:

```bash
PRODUCT_DEMOS_ENABLE_EDA=true aap-demo enable product-demo-eda
```

See the [add-ons guide](../../docs/guides/addons.md#product-demos) and
[ADR-041](../../docs/adr/041-guarded-eda-and-pinned-apd.md) for its guardrails.
