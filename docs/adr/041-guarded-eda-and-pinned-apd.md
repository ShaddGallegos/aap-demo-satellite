# ADR-041: Guarded EDA Integration and Pinned APD Revision

**Status**: Accepted

**Date**: 2026-11-20

**Authors**: aap-demo maintainers

## Context

The upstream Ansible Product Demos repository evolves independently of this
project. Using its moving `main` branch makes a previously tested local demo
change without a change in this repository. Its Infrastructure EDA scenario
also needs event-source, Kafka, cloud, and managed-host configuration that is
not safe to guess or provision from a local demo installer.

Automation Orchestrator and Lightwell benefit from the AAP Event-Driven
Ansible service, but merely enabling that AAP service must not create an event
source or run remediation.

## Decision

- APD addons default to the tested immutable revision
  `90dea07d34d9bf5bf59acd7b6927ab576c0cddf4`. `PRODUCT_DEMOS_REF` overrides it;
  `PRODUCT_DEMOS_BRANCH` remains a legacy alias.
- `eda` enables EDA in the local `AnsibleAutomationPlatform` custom resource
  only. It never adds event sources or rulebook activations.
- Automation Orchestrator depends on `eda`; Lightwell depends on Automation
  Orchestrator, and therefore EDA as well.
- Infrastructure remains a separate `product-demo-infrastructure` opt-in.
- `product-demo-eda` requires `PRODUCT_DEMOS_ENABLE_EDA=true`. It imports the
  upstream Infrastructure setup scenario but does not configure or create its
  external prerequisites and does not launch its rulebook activation.

## Consequences

The common AAP/AO and Lightwell profiles have an EDA service without acquiring
external cloud or broker resources. Operators retain a reviewed, explicit path
for the APD Infrastructure and EDA scenarios. Updating APD is a conscious
revision change that can be tested before it is made the default.

## Related

- [ADR-018](018-product-demos-addon.md)
- [ADR-023](023-addon-auto-wiring.md)
- [ADR-032](032-open-issues-remediation-strategy.md)
