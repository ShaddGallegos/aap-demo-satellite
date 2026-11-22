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

## Complete demo profiles

The Bash command has composable create profiles. State the capability you want;
required components are included automatically:

```bash
aap-demo create --ansible              # AAP, product demos, Ollama, EDA, AO, Fleet
aap-demo create --satellite --sno      # --ansible plus the Satellite lab and demo
aap-demo create --lightspeed           # --ansible plus local-model Lightspeed
aap-demo create --lightwell --microshift # Satellite, Lightspeed, Gitea, and Lightwell
aap-demo --gitea                       # Start only the retained Gitea VM outside CRC
```

`--full-demo` remains a compatibility alias for `--ansible`; it is not needed
alongside the newer profile flags. Interactive Satellite profiles ask whether
to import the optional, externally sourced GPL-3.0 RHIS report templates. For
unattended runs, set both `SATELLITE_IMPORT_RHIS_TEMPLATES=true` and
`SATELLITE_RHIS_TEMPLATE_LICENSE_ACCEPTED=true` only after accepting that
upstream license. See the [Satellite lab guide](../../satellite-lab/README.md#optional-rhis-report-templates).

On a Linux MicroShift host with an isolated NVIDIA device, inspect availability
with `aap-demo gpu status`. `aap-demo gpu enable --apply` changes PCI passthrough
and restarts CRC, so use it only after approving that host change.

For an independent Fedora 45 Git server with host NFS storage, use
`aap-demo --gittea` (also `--gitea` or `enable gitea`), or the dashboard's
**Local Gitea VM** install button. It does not need CRC running. See the
[Gitea guide](../../addons/gitea/README.md) for credentials, safe stop, storage
retention, and AAP CA requirements.

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

## Dashboard demo menus

Start the local dashboard with `aap-demo-v1 dashboard`. From the implementation
checkout, `bash ./aap-demo.sh dashboard` uses that checkout's dashboard.

- **Overview** shows cluster, workload, and capacity summaries.
- **Demos** has separate Lightwell CI/CD, Satellite, and Product Demos submenus.
  Configure/remove buttons use the existing addon workflow; removal asks for
  confirmation. **Check integrations (read-only)** uses the existing inspection
  command and does not launch jobs, execute MCP tools, or call the model.
  **Enable guarded EDA demo** additionally asks you to confirm that external
  event-source prerequisites are ready. The confirmation applies only to that
  operation and does not create an event source or rulebook activation.
- **Add-ons** retains category-filtered feature management.
- **Services and Fleet** contains route links, Fleet terminals/power controls,
  and namespace health.

Demo buttons open AAP's native jobs/templates or AO's workflows/approvals.
Review inventory, credentials, inputs, and production approval there. Merely
opening a demo does not run it. The
[Lightwell guide](../../addons/lightwell/README.md) lists its prepared-service
requirements and the effects of deliberately running its PR simulation.

## Pause for travel without deleting data

Finish or record active installation and maintenance jobs before shutting down.
Stop only project-owned resources; do not power off a shared host or use
uninstall, clean, destroy, or forced VM termination for a travel pause.

For each running Fleet node, open `aap-demo-v1 fleet ssh <index>` and run:

```bash
sudo systemctl poweroff
```

Wait until every Fleet QEMU process has exited. The current Fleet stop helper
can terminate a running QEMU process; it does not guarantee a graceful guest
shutdown. Only after the guests have stopped, stop CRC:

```bash
aap-demo-v1 stop
```

Satellite is a separate VM and is not stopped by that command. For the managed
Linux libvirt lab, request and verify its graceful shutdown separately:

```bash
virsh -c qemu:///system shutdown satellite
virsh -c qemu:///system domstate satellite
```

Wait for `shut off`; a successful shutdown request alone is not confirmation.
Keep the host and its NFS exports available until Satellite is fully off.
Suspend any installed project watchdog before shutdown so it cannot attempt
recovery during the pause. Do not stop unrelated host services.

After travel, start the preserved Satellite VM, then resume the demo:

```bash
virsh -c qemu:///system start satellite
aap-demo-v1 start
aap-demo-v1 status
aap-demo-v1 diagnose
aap-demo-v1 check-integrations
```

From the implementation checkout, use `bash ./aap-demo.sh` instead of
`aap-demo-v1`. Starting reconciles enabled integrations; it is not read-only.
Recheck Satellite health, both NFS mounts, Fleet access, and current integration
results before continuing an interrupted setup. Do not rerun full-demo merely
to resume stopped VMs: it can run Satellite maintenance.

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

## Restart and check a full OpenShift lab

```bash
aap-demo-v1 start
aap-demo-v1 status
aap-demo-v1 diagnose
```

`start` resumes preserved Fleet nodes and reconciles enabled addon connections.
`diagnose` checks pod readiness, not just whether pods are running. When CPU
autoscalers exist, it also reports an unavailable metrics API or unknown CPU
samples; it does not enable cluster monitoring.
Full OpenShift owns its DNS Corefile and node container-signature policy through
operators; the MicroShift-specific direct-file workarounds are not applied there.
Addon wiring supplies route host aliases for AO where needed. A missing
MicroShift rewrite alone is therefore not a DNS failure on full OpenShift.
Test actual in-pod resolution and API connectivity when investigating an
integration problem.

Run `aap-demo-v1 check-integrations` for a repeatable inspection. It logs in to
AO for a short-lived access token and reads AO, AAP, and historical job data;
it does not rewire services or launch jobs. It reports disabled addons, failed
checks, and checks that were not performed. AO's recorded validation and
historical Satellite sync and Fleet ping results are not proof that the
connections work now. The command does not execute MCP tools, query the LLM,
or verify current Fleet registrations. A failed check exits nonzero.

### Recovering a full-demo or Satellite build

The Bash full-demo and Satellite builder write a private progress file under
`~/.aap-demo/workflow-journals/` (or `$AAP_DEMO_DIR/workflow-journals/`).
Each attempt has its own file, and the command prints its path. It records
fixed phase names, timestamps, and outcomes, not arguments, command output,
credentials, or detailed errors. Files are retained until you remove them.
Full-demo credential setup occurs before journaling.

A `running` result may mean the process is still active or was interrupted.
For a failed or interrupted phase, inspect the command output and current
cluster, VM, Satellite, and backup state before deciding whether to rerun.
The journal never resumes or skips a phase automatically; a normal rerun uses
the existing state checks, and some external operations can still have effects.

## What we are not doing

We are not turning the older command off, and we are not listing features as deprecated. When a feature
moves, its own page will say the new way to run it.
