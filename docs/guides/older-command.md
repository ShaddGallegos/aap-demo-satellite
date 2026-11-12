---
type: Guide
title: The older command
description: How to keep the bash aap-demo command for features the new one does not have yet.
tags: [bash, install, compatibility]
status: draft
stale_after: 2027-01-28
resource: https://github.com/RedHatOfficial/aap-demo
sources:
  - id: v2-to-main
    resource: https://github.com/RedHatOfficial/aap-demo/blob/main/docs/v2-to-main.md
    title: v2 to main
    author: human:aknochow
    last_modified: 2026-10-28T00:00:00Z
---

# The older command

Some jobs still belong to the original bash command: the self-service portal, Automation Orchestrator,
and a handful of others. That command keeps working. Use it for those jobs, and use the new command for
create, deploy, day-to-day cluster care, and product demos (`aap-demo enable product-demos`).

## Install it from a checkout

```bash
git clone https://github.com/RedHatOfficial/aap-demo.git
cd aap-demo
./install.sh
```

`./install.sh` links `~/.local/bin/aap-demo` to `aap-demo.sh`.

The pull secret for this command goes here:

```bash
mkdir -p ~/.aap-demo
cp ~/Downloads/pull-secret.txt ~/.aap-demo/pull-secret.txt
```

Its kubeconfig is `~/.aap-demo/kubeconfig.microshift`. Unlike the new command, that file is not copied into
`~/.kube/config`. Updating this command is `git pull` and `./install.sh` again.

## Use both commands

Rename the bash command so the new one can have the `aap-demo` name:

```bash
mv ~/.local/bin/aap-demo ~/.local/bin/aap-demo-v1
pipx install aap-demo
```

Then:

```bash
aap-demo deploy
aap-demo-v1 enable portal
```

If you would rather call the script directly, `./aap-demo.sh` in a checkout is the same program.

## Find examples in the terminal

```bash
aap-demo-v1 --help
```

The **Examples** section groups commands by task: a first deployment, an
all-in-one demo, optional addons, Fleet machines, Satellite integration, daily
use, diagnostics, and rebuilding. Each example explains what the command does.
Choose the group you need rather than pasting the whole section into a terminal.
Destructive examples have a warning before them.

If you have not renamed the bash command, use `aap-demo --help`. From a checkout,
`./aap-demo.sh --help` shows the same examples.

## Fleet on the older command

`aap-demo-v1 enable fleet` still builds virtual machines with QEMU. The new command's Fleet is different:
those machines are pods inside the cluster. Pass `--backend kube-native` on the bash command only when you
mean the new kind.

## Uninstall the local environment

Preview the removal list before making changes:

```bash
aap-demo-v1 maintenance uninstall
```

To proceed, run the following command and type `UNINSTALL` when prompted:

```bash
aap-demo-v1 maintenance uninstall --apply
```

**This deletes the local deployment and its managed VM data.** It also stops
and removes the managed Satellite lab VM, disables its autostart, and deletes
its OS disk, even if an earlier uninstall already removed CRC and local settings.
A VM named `satellite` must match the lab provisioner's disk and network
interfaces before it can be removed. Failed VM cleanup stops the uninstall
rather than claiming success.

External Satellite servers, additional attached disks, host-side NFS/Pulp
content and backups, ISO files, and shared libvirt networks are preserved.
The encrypted credential Vault is kept for rebuilds unless you also request
`--reconfigure`, which removes only its `aap_demo` entries.
The source checkout and shared OS tools are not removed.

If the earlier uninstall removed the command's symlink, run the equivalent
`./aap-demo.sh maintenance uninstall --apply` from your checkout.

## What we are not doing

We are not turning the older command off, and we are not listing features as deprecated. When a feature
moves, its own page will say the new way to run it.
