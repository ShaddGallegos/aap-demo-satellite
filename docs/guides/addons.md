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

`aap-demo disable product-demos` drops the addon from this computer's settings. The job templates stay
in AAP until you delete them in the UI.

The cluster still wants about 8 processors and 24 GB of memory. Demo jobs add work on top of AAP.

## Satellite subscriptions in the full demo

When using the [older command](older-command.md), `aap-demo create --full-demo --satellite`
also prepares and imports the Satellite subscription manifest. There is no separate
`fleet auth` or `enable satellite-manifest` step for an interactive full-demo run:
it checks Red Hat credentials first and prompts securely if they need configuration.
With `QUIET=true`, configure credentials before starting.

The manifest addon reuses the `aap-demo-satellite` allocation and its existing
subscriptions. For each missing category, Satellite Infrastructure and RHEL server,
it attaches one entitlement only if there is exactly one eligible pool. It never
buys subscriptions. Missing or ambiguous choices stop the command with guidance
to select subscriptions in Red Hat Console, rather than importing an empty manifest.
This minimum enables content setup; it does not determine your host licensing requirements.

Rerunning full-demo detects the installed Satellite RPM rather than assuming
that a VM is already configured. It preserves existing installer settings,
applies package updates and supported adjacent minor upgrades through
`satellite-maintain`, then refreshes/imports the manifest without rebuilding
the VM or synchronizing repositories. Each changing step requires a successful
full offline backup and maintenance checks. Allow for Satellite downtime and
automatic reboots; backup or check failures stop the run.
See the [lab maintenance guide](../../satellite-lab/README.md#existing-installations-and-maintenance)
for backup storage and failure recovery.
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
