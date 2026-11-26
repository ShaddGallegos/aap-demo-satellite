---
type: Guide
title: Add-ons
description: Fleet machines and product demos in the new command, and where the other extras still live.
tags: [addons, fleet]
status: draft
stale_after: 2027-01-28
resource: https://github.com/RedHatOfficial/aap-demo
---

# Add-ons

Add-ons are optional extras on top of AAP: a self-service portal, demo job templates, a local model, and practice machines.

## Practice machines (Fleet)

The new command can add small Linux machines that show up as hosts in AAP. They run inside the same local cluster.

```bash
aap-demo enable fleet
aap-demo fleet list
aap-demo fleet add --os ubi9
aap-demo fleet remove fleet-ubi9
aap-demo disable fleet
aap-demo fleet destroy
```

`enable fleet` creates two machines by default, `fleet-ubi9` and `fleet-ubi10`, and registers them in AAP.
Registering needs a [subscription](subscription.md) in AAP. Without one, use `aap-demo enable fleet --no-import`.
Add `--no-import` if you want the machines without that registration.

`disable fleet` turns the machines off and leaves the registration in place. `fleet destroy` removes both.

### Reboots and services

Each machine runs systemd, so `sudo reboot`, `systemctl`, and the `service` and `systemd_service` modules work.
A reboot restarts the machine's container, usually within two minutes. Installed packages, `/etc`, and enabled
services are still there afterward.

`ansible.builtin.reboot` needs one extra option. The machines share the cluster's kernel, so the boot ID the module
checks by default never changes, and the module waits until it times out:

```yaml
- name: Reboot a Fleet machine
  ansible.builtin.reboot:
    boot_time_command: cut -d' ' -f22 /proc/1/stat
```

Packages that set file capabilities, such as `httpd`, do not install on these machines.

## Product demos

`aap-demo enable product-demos` installs the Ansible product demos into the AAP you already deployed.
The command needs `bash`, `curl`, and `jq`. On a Mac, `brew install jq` supplies jq when it is missing.

The install clones the demo repository, syncs a project in AAP, and launches one job per domain:
Linux, Windows, network, cloud, and OpenShift. That can take a while. Satellite stays out of this set
until you ask for it:

```bash
aap-demo enable product-demo-satellite
```

A smaller set:

```bash
PRODUCT_DEMOS_DOMAINS="linux cloud" aap-demo enable product-demos
```

One domain uses the same installer under its own name, for example `aap-demo enable product-demo-linux`.

The default upstream revision is pinned to a tested immutable APD commit. To use a
different revision deliberately, set `PRODUCT_DEMOS_REF`; the older
`PRODUCT_DEMOS_BRANCH` spelling remains a compatible alias:

```bash
PRODUCT_DEMOS_REF=<commit-or-tag> aap-demo enable product-demos
```

Infrastructure demos are intentionally separate from the normal demo set:

```bash
aap-demo enable product-demo-infrastructure
```

This creates the upstream Infrastructure setup template in AAP. It does not
launch it, so any cloud, broker, or managed-host resources remain under your
control. The Event-Driven Ansible (EDA) service is enabled automatically for
Automation Orchestrator and Lightwell profiles; enabling it alone also does not
create event sources or activate rulebooks:

```bash
aap-demo enable eda
```

The APD EDA scenario is additionally guarded because its upstream workflow
expects external event-source prerequisites. Review and supply those
prerequisites first, then explicitly opt in:

```bash
PRODUCT_DEMOS_ENABLE_EDA=true aap-demo enable product-demo-eda
```

That command imports the required Infrastructure scenario. It does not create
Kafka, cloud resources, credentials, event sources, or a rulebook activation.

`aap-demo disable product-demos` drops the addon from this computer's settings. The job templates stay
in AAP until you delete them in the UI.

The cluster still wants about 8 processors and 24 GB of memory. Demo jobs add work on top of AAP.

## OpenShift delivery proof of concept

The optional delivery scenario installs Red Hat OpenShift GitOps and OpenShift
Pipelines operator subscriptions. It does not create a repository, application,
pipeline execution, credential, or workload:

```bash
aap-demo enable openshift-delivery
```

See [OpenShift delivery proof of concept](../openshift-delivery.md) for its
catalog prerequisites, ownership boundary, and safe removal behavior.

## Automation Hub content synchronization

`aap-demo enable setup-pah` reads the separate Automation Hub offline token from
the encrypted `ah_offline_token` value in `~/.ansible/conf/env.yml`. It validates
the token, configures both supported collection remotes, and waits for their
Pulp synchronization tasks to finish. A failed Pulp task stops setup with its
error instead of leaving a later APD job to fail during collection resolution.

The Automation Hub token is not the Customer Portal/CDN username, password, or
offline token. Use the interactive `setup-pah` flow to save the Automation Hub
token in the Vault; never put it in a command line or repository file.

## Satellite subscriptions in the full demo

When using the [older command](older-command.md), `aap-demo create --satellite`
also prepares and imports the Satellite subscription manifest. There is no separate
`fleet auth` or `enable satellite-manifest` step for an interactive full-demo run:
it checks Red Hat credentials first and prompts securely if they need configuration.
With `QUIET=true`, configure credentials before starting.

The manifest addon reuses the `aap-demo-satellite` allocation and its existing
subscriptions. For each missing category, Satellite Infrastructure and RHEL server,
it attaches one entitlement only if there is exactly one eligible pool. The exact
`Red Hat Developer Subscription for Individuals` pool is recognized as the RHEL
content source for a personal lab; other developer or employee SKUs are not selected.
It never
buys subscriptions. Missing or ambiguous choices stop the command with guidance
to select subscriptions in Red Hat Console, rather than importing an empty manifest.
This minimum enables content setup; it does not determine your host licensing requirements.

Rerunning full-demo detects the installed Satellite RPM rather than assuming
that a VM is already configured. It preserves existing installer settings,
applies package updates and supported adjacent minor upgrades through
`satellite-maintain`, then refreshes/imports the manifest without rebuilding
the VM or synchronizing repositories. Each changing step requires a successful
libvirt checkpoint and maintenance checks. Allow for Satellite downtime and
automatic reboots; checkpoint or check failures stop the run.
See the [lab maintenance guide](../../satellite-lab/README.md#existing-installations-and-maintenance)
for checkpoint and failure recovery.
See the [manifest addon guide](../../addons/satellite-manifest/README.md)
for supported subscription names, permissions, and a manifest-only command.

The Satellite demo also detects the organization that actually owns the published
RHEL9/RHEL10 views, rather than assuming upstream's RHEL7/RHEL8 repositories exist.
It uses the lab's DEV → TEST → PROD path, wires credentials and workflow targets,
and synchronizes Satellite inventory with Fleet's forwarded SSH addresses.
If multiple organizations match, set `SAT_ORG` explicitly.

Enabling this local-lab profile also registers running RHEL9 Fleet nodes through
Satellite, migrating any direct Red Hat registration only after checking the
Satellite connection and consumer package. A custom APD SSH credential or a
registration in a different Satellite organization stops reconciliation rather
than being silently replaced.

After a successful enable, `aap-demo wire` repeats this reconciliation. Wiring
itself never runs patching or reboot jobs. It also distributes the shared Fleet
SSH identity to `admin` and `root` on running Fleet/Satellite nodes, and to
`core` on CRC (using `sudo` for root operations). Managed lab SSH aliases disable
host-key checking; host-wide SSH defaults and host accounts are unchanged.
This shared-key policy is only for local disposable labs; see the
[SSH details](../../satellite-lab/README.md#shared-lab-ssh-access).
OpenSCAP still needs version-appropriate policy
content; the local profile does not import the upstream RHEL7/RHEL8 tailoring files.
See the [Satellite demo guide](../../addons/product-demo-satellite/README.md)
for local versus external Satellite behavior.

### Optional image-provisioned general nodes

For a local Satellite lab, a deliberate opt-in can provision three minimal
general-purpose VMs from a Satellite image. On the local KVM compute resource,
they are persistent libvirt domains and are visible in Virt-Manager. Each uses
two vCPUs, 4096 MiB RAM, and a 15 GiB qcow2 disk. The command never guesses an
image or falls back to PXE:

```bash
SATELLITE_GENERAL_NODE_COUNT=3 \
SATELLITE_GENERAL_NODE_IMAGE=<Satellite-image-name> \
aap-demo create --satellite
```

Use `SATELLITE_COMPUTE_RESOURCE` and the provider-specific
`SATELLITE_GENERAL_NODE_COMPUTE_ATTRIBUTES`,
`SATELLITE_GENERAL_NODE_VOLUME`, and
`SATELLITE_GENERAL_NODE_INTERFACE` variables for a selected external
compute platform. See the [Satellite lab guide](../../satellite-lab/README.md#general-satellite-provisioned-vms)
for safety checks and the full variable list.

The same reconciliation creates or reuses the daily `aap-demo-all-content`
Satellite sync plan and attaches it to every managed content product. It also
mirrors the Red Hat Flatpak remote and creates a Satellite Ansible Collections
repository backed by `console.redhat.com`. Collections require the separate
Vault-backed `ah_offline_token`; they appear under **Content → Ansible
Collections** after the initial synchronization completes.

Satellite reconciliation also creates owned RHEL 9.5 and RHEL 10.0 installation
media entries using the local published Kickstart trees. It enables the OpenSCAP
proxy and uploads Satellite's default SCAP content, but leaves policy/profile
assignment explicit because the policy must match the target RHEL minor version.
It also reconciles the local `KVM-Host` compute resource and its
`aap-demo-general-small` profile (2 vCPU, 4096 MiB, 15 GiB), assigns the local
Capsule to DNS, DHCP, and Remote Execution where appropriate, imports available
Satellite Ansible roles, and applies a limited provisioning/facts/Remote
Execution/Red Hat Lightspeed settings baseline. Organization-wide authentication,
mail, and privacy policy remain unchanged.

Red Hat Inventory upload needs a direct RHSM identity on the Satellite VM. The
installer reads the existing encrypted CDN credential pair from the Vault; it
does not treat host entitlement certificates as a Cloud Connector identity.

## Everything else

Portal, Automation Orchestrator, a local cache of container images, and the MCP server are not in the
new command yet. Asking the new command for one of them stops with a short error, and your cluster is
left as it was.

Use [the older command](older-command.md) for those. For example, after you have renamed it:

```bash
aap-demo-v1 enable portal
```

Each of those extras will move to the new command on its own. Until a page says otherwise, the older command
is the way to install them. Nothing you already run with the older command is being removed in this release candidate.
