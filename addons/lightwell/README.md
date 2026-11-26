---
type: Guide
title: Lightwell CI/CD simulation
description: Bind a pinned upstream CI/CD demonstration to prepared local lab services.
---

# Lightwell CI/CD simulation

This optional Bash CLI addon configures seven AAP job templates and an
Automation Orchestrator workflow from the upstream
[CI/CD demonstration](https://github.com/ansible-tmm/aap-orchestrator-demos/tree/3e2b24e6c3d5519cb380298ce45727412f17e20d/cicd-pipeline).
It simulates a Lightwell patch; it does not install a real Lightwell service.
Upstream files are referenced by pinned SCM revision and downloaded temporarily,
not bundled in this repository. No upstream license declaration was found at
the inspected revision; review usage rights before redistributing its content.

## Prerequisites

- AAP 2.7+, Automation Orchestrator, Event-Driven Ansible (EDA), and their
  existing AAP/model bindings. The Lightwell profile enables EDA automatically;
  it does not create event sources or rulebook activations.
- System-trusted HTTPS for AAP, AO, Gitea, and OpenFlake. No global TLS bypass.
- For managed preparation, the independent [Fedora Gitea VM](../gitea/README.md)
  and a deliberately selected Fleet application VM with at least 4 GiB RAM.
  The application VM needs entitled repositories before the native setup job.
- Alternatively, prepared external Gitea/runner, an `inventory-service`
  demonstration repository, and OpenFlake's compatible change-request API.
- A dedicated AAP inventory named `Lightwell CI/CD`, containing exactly one
  prepared application VM. Never target Satellite, CRC, or unrelated workloads.
- A Machine credential named `Fleet SSH Key` with access to that application VM.
- An AAP credential named `Lightwell OpenFlake` injecting `SN_PASSWORD` and,
  when not using `admin`, `SN_USERNAME`; equivalent `openflake_password` and
  `openflake_username` extra variables are supported.
- An AAP credential named `Lightwell Gitea` injecting the secret extra variable
  `gitea_token_override`. Do not put tokens in URLs or job launch variables.
- All selected AAP resources must belong to `Default`.

The application host must be prepared deliberately using the native setup job
or equivalent reviewed steps. The setup job changes packages, services, ports
80/8080, and application directories. Enabling this addon never launches it.
Review upstream playbooks before use.

## Prepare managed local services

```bash
aap-demo create --lightwell
# Equivalent explicit form:
aap-demo create --full-demo --lightwell

# Or prepare a manually selected application host after AAP/AO already exist:
aap-demo enable gitea
FLEET_NODE_MEM=4096 aap-demo fleet add 1 --image rhel9

# Replace 4 with the index of the dedicated node just created.
LIGHTWELL_APP_NODE=4 aap-demo enable lightwell --prepare
```

Preparation runs pinned OpenFlake/PostgreSQL containers and a repository-scoped
Gitea runner on the independent Gitea VM, outside CRC. The runner is an
unprivileged, no-login user with no sudo access. Only that VM can use the added
host-firewall rule for HTTPS ingress. Its AO route resolves to the actual
libvirt host gateway, not CRC's host-only loopback address.

The owned private `aap-demo/inventory-service` repository contains original
metadata-only CI fixtures. Fictional Lightwell dependency metadata is never
installed or presented as real vulnerability remediation. Preparation owns its
CI workflow and notification script; it does not reset application metadata,
branches, or user files. CI checks the exact private commit and exits without
calling AO when `CHANGE_REQUEST` is empty.

The command creates the dedicated inventory, strict SSH host-key credential,
service credentials, seven templates, and rejecting AO workflow. It validates
and activates the reviewed native workflow version using optimistic version
checking; importing a disabled draft alone is not readiness. The supported
AAP CA-bundle setting preserves certificate validation; another owner's bundle
is never overwritten. Repository secrets use native Gitea storage over verified
HTTPS. A dedicated AO service account exchanges its client credentials for a
short-lived token per CI notification. Credentials stay in encrypted Vault or
native credential stores, not source, URLs, or process arguments.

Public configuration is retained under
`${XDG_DATA_HOME:-~/.local/share}/aap-demo/lightwell`, outside disposable CRC
state. Normal enable reuses it; `--prepare` reconciles owned prerequisites
without launching application jobs. Existing service identities are not rotated.
Retain the native AO credential expiry and renew deliberately before expiration.
OpenFlake data currently lives on the retained independent VM disk; take a
consistent off-VM database/attachment backup before removing that VM.

Enroll the selected RHEL host through the supported Satellite workflow or
native RHSM/RHC before running **CI/CD Demo - Setup Demo Host** in AAP.
`fleet rhc-connect` acts on every running Fleet VM; do not use it to target
one node when unrelated nodes are running. Setup is deliberate and changes
only the dedicated host. Preparation itself never launches it.

## Bind manually prepared external services

```bash
export LIGHTWELL_GITEA_URL=https://git.example.test
export LIGHTWELL_OPENFLAKE_URL=https://changes.example.test

# Local configuration validation only; not a live health check.
bash addons/lightwell/deploy.sh --preflight

# Bind existing resources and import the workflow, without launching jobs.
bash ./aap-demo.sh enable lightwell

# `--lightwell` resolves the complete dependency profile: `--ansible`,
# `--satellite`, `--lightspeed`, and `--gitea`. Add only the cluster profile
# that fits the host.
aap-demo create --sno --lightwell
```

The full-demo form without `create` is accepted by the Bash CLI. A retained
configuration is validated before lab mutation; a fresh `--lightwell` profile
creates its managed Gitea/OpenFlake configuration after the Gitea VM starts.
Provisioning subsequently verifies the
selected AAP resources, credential injectors, and AO bindings; configuration
preflight alone is not sufficient justification to uninstall a working lab.
Reinstall also needs retained media, credentials, service configuration, and
a reconstructible dedicated application host. For owned local preparation,
full-demo reuses only a marked application node or creates one new 4 GiB node,
then recreates the AAP/AO resources with `--prepare`. Reconstructing that node
does not establish its entitlement, application setup, or pipeline acceptance.

Optional environment overrides are `LIGHTWELL_INVENTORY`,
`LIGHTWELL_MACHINE_CREDENTIAL`, `LIGHTWELL_ITSM_CREDENTIAL`, and
`LIGHTWELL_GIT_CREDENTIAL`. Defaults are the names listed above. Export these
alongside the two service origins whenever enabling or rebuilding.

The addon creates a pinned AAP project and these templates:

- Deploy and Test Dev
- Drain Load Balancer
- Deploy to Prod
- Rollback to Snapshot
- Close Loop
- Simulate Lightwell PR
- Setup Demo Host

Each name starts with `CI/CD Demo -`. Existing unowned resources are not
adopted. Reruns reconcile owned resources and exact credential associations.
The unsafe upstream reset template and Gitea bootstrap script are not imported.

## Integration and deliberate execution

CI webhook → development deployment/test → explicit human approval →
load-balancer drain → production deployment/smoke → success or rollback.
Approval defaults to rejection. The three AO AI tasks write notes using the
existing model binding with tools disabled; they receive no MCP credentials.
This does not configure or validate Ansible Lightspeed chat.

The native AO webhook requires its authorized service-account token. Managed
preparation configures token exchange; external runners must use the native
AO/Gitea interfaces. Never place secrets in source or the dashboard.
The constrained webhook accepts the fixed
`inventory-service` app, version, commit SHA, HTTPS CI build URL, and change
request number, plus optional CVE/build-number fields.

**The Simulate Lightwell PR job opens a demonstration PR for manual review and
merge** and creates an OpenFlake change. Merging to `main` can trigger CI and
development deployment. Production still requires explicit human approval in
AO. Launch only deliberately against the dedicated demonstration repository.
Enabling the addon launches no deployment/reset/remediation job.

Satellite remains responsible for supported host registration/content and
cloud reporting, not application PR merging. Register and prepare the dedicated
host through the existing [Satellite workflow](../../satellite-lab/README.md).
The addon does not invent a Satellite remediation API or grant AI write tools.

The dashboard separates **Overview**, **Demos**, **Add-ons**, and **Services and
Fleet**. The Demos submenu selects Lightwell CI/CD, Satellite, or Product Demos,
so demo controls and external service links do not crowd the overview.
Buttons configure/remove the selected demo or run the existing read-only
integration check. Removal requires confirmation; configuration and checks
share the dashboard operation lock and retain session/origin protection.

Lightwell links open Gitea, OpenFlake, native AAP templates/jobs, and AO
workflows/approvals after successful provisioning. Opening a native application
does not launch jobs or grant approval. The workspace explains the simulation's
manual-merge effects and distinguishes configuration from runtime health.
The integration check reports all enabled connections, not CI/CD execution.
State contains public service URLs only.

## Remove and troubleshoot

```bash
bash ./aap-demo.sh disable lightwell
```

Removal deletes only marked workflows, templates, and the managed project.
It preserves the application host, Gitea/OpenFlake data, inventory, credentials,
and dedicated AO webhook service account. It is not application-data cleanup.

Missing service URLs fail before authentication. Missing inventory, credentials,
or model bindings fail before resource creation. For TLS failures, repair the
service certificate chain and trust store rather than disabling validation.
Setup retries transient AAP/gateway HTTP 502, 503, and 504 responses while it
reads project state or revokes its temporary token. If token revocation still
fails after those retries, inspect and revoke the temporary `aap-demo lightwell
setup` token in the gateway before retrying.

Live qualification passed authenticated OpenFlake HTTPS, runner-to-AO trusted
HTTPS, native short-lived AO caller authentication, two metadata-only CI runs,
and isolated application setup (AAP job 83). Both development and production
baseline endpoints responded. The app VM's original 1 GiB allocation caused a
verified DNF OOM; 4 GiB survived an ordinary restart and preparation reran
without duplicating service identities.

No application PR was simulated/merged and no production promotion was
approved. End-to-end change delivery and destructive full uninstall/reinstall
remain untested. Recheck Satellite entitlement/content and complete off-VM
recovery prerequisites before requesting teardown approval. Passing baseline
CI, configuration preflight, or mocked reconstruction tests is not a completed
rebuild or a successful end-to-end deployment.
