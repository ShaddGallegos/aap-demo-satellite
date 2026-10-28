# AAP Demo Quick Start

Deploy AAP to a local MicroShift cluster in minutes.

## SECURITY NOTICE — DEVELOPMENT ENVIRONMENT ONLY

**aap-demo is a LOCAL DEVELOPMENT tool and must NEVER be used in production.**

For planned architectural, reliability, testing, platform, and release improvements,
see the [project roadmap](docs/ROADMAP.md).

## Choose your platform

| Host | Installation, configuration, and daily use |
|------|--------------------------------------------|
| RHEL / Fedora | [Linux quickstart](docs/Linux_Quickstart.md) |
| macOS (Intel / Apple Silicon) | [macOS quickstart](docs/MAC_Quickstart.md) |
| Windows / Hyper-V | [Windows quickstart](docs/Windows_Quickstart.md) |
| WSL terminal, Windows-hosted CRC | [WSL quickstart](docs/WSL_Quickstart.md) |

Linux/macOS use the Bash CLI; Windows uses the native PowerShell CLI. WSL
should invoke that Windows CLI instead of creating a second CRC installation.
CLI portability does not make every addon image available for every architecture.

| Capability | Native Linux | macOS | Native Windows / WSL wrapper |
|------------|--------------|-------|-------------------------------|
| CRC + AAP core lifecycle | Bash | Bash | PowerShell |
| Fleet | QEMU/KVM | QEMU/HVF, matching guest architecture | Not native PowerShell |
| Separate persistent image disk | libvirt | Use OCI cache instead | Not supported |
| Shutdown backup + pre-login boot recovery | systemd/libvirt | No | No |
| Explicit checkpoint + login recovery | systemd boot workflow | LaunchAgent, vfkit/raw | Native scheduled task, supported Hyper-V layout |
| Addon integrations | Bash, subject to images/tools | Bash, subject to images/tools | Native subset; other addons require Git Bash/tools |

Native macOS/Windows recovery is a **checkpoint-before-reboot** workflow, not
a guaranteed shutdown backup. It must still be validated with real CRC VMs on
those hosts; hermetic tests and CI checks are not equivalent to live recovery.
See [state recovery](docs/state-service.md) for retention, credentials and rollback
semantics. The Linux bootstrap below is **not** a macOS/Windows/WSL installer.

## Portability and repeat-run contract

- Running the same create, deploy, enable, start, wire, or full-demo workflow
  again converges existing resources instead of intentionally duplicating them.
  Kubernetes namespaces and managed secrets use apply-style updates, and saved
  addon/configuration keys are replaced rather than appended repeatedly.
- Bash state defaults to `~/.aap-demo`, with persistent settings at
  `~/.aap-demo/config`. Set `AAP_DEMO_DIR` and `AAP_DEMO_CONFIG` to relocate
  them; those values are exported to addon processes. Set `NAMESPACE`,
  `KUBECONFIG`, or `AAP_DEMO_KUBECONFIG` to select non-default cluster targets.
- Interactive runs may prompt for credentials and capacity. `QUIET=true` is the
  unattended/CI contract: required missing input fails with setup guidance
  rather than prompting or silently selecting invalid data.
- Linux and macOS use Bash; native Windows uses PowerShell, and WSL uses the
  Windows wrapper. CPU-specific images are selected for `x86_64`/`amd64` and
  `arm64`/`aarch64` where the addon supports both. An addon that lacks an image
  or host implementation for the detected platform fails explicitly.
- CRC-owned files remain under CRC's own `~/.crc` layout. Linux systemd recovery
  deliberately supports only the default state paths because it must run
  outside an interactive shell; custom state paths remain supported for normal
  CLI and addon workflows.
- Idempotency means a completed operation is safe to repeat. Interrupted remote
  API operations can still require another run after connectivity returns; the
  CLI surfaces those failures instead of reporting success.

## Prerequisites

- **CRC (OpenShift Local)** — [Download](https://console.redhat.com/openshift/create/local)
- **16 GB RAM minimum** — default VM allocation is 16 GB (override with
  `CRC_MEMORY=24576 aap-demo create` for 24 GB). On Linux, `aap-demo create`
  prompts for optional temp swap on memory-constrained hosts (see
  [scripts/README.md](scripts/README.md))
- **Pull secret** — download from the
  [Red Hat console](https://console.redhat.com/openshift/install/pull-secret).
  Setup imports it into encrypted `~/.ansible/conf/env.yml`; remove the original
  download after import. If a valid Customer Portal offline token is already in
  the Vault, `aap-demo create` can retrieve a fresh pull secret from Red Hat's
  official API and save it directly to the encrypted Vault. See Red Hat
  Solution [4844461](https://access.redhat.com/solutions/4844461) for the
  supported REST automation workflow.

### Python dependencies (manual virtual-environment setup)

For manual Linux/macOS setup, install the core Python tools in a virtual
environment rather than modifying the system Python. Python 3.11 is the tested
baseline for this setup and CI. Install it with `venv` support if your default
Python is newer than the versions supported by your selected Ansible release.

From the repository root:

```bash
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
python -m pip check
```

[requirements.txt](requirements.txt) declares `ansible-core` (including
`ansible-vault`, `ansible-galaxy`, and `ansible-playbook`), `PyYAML` for credential
storage, and the Kubernetes Python client for `kubernetes.core` modules.
[requirements.yml](requirements.yml) declares Ansible collections, not Python
packages. These are compatibility ranges, not a fully pinned lockfile.
Other Python versions require an Ansible release supporting that interpreter;
successful pip resolution alone does not prove runtime compatibility. Validation
on this host found that stable `ansible-core` 2.21.5 fails on Python 3.15.

Activate `.venv` in each shell before using these tools or `aap-demo`; use
`deactivate` to leave it. The environment is ignored by Git. This setup does not
install system tools such as CRC, `kubectl`, Helm, QEMU, or SSH, and is not a
native Windows Ansible installation workflow.

APME retains its separate [Python requirements](addons/apme-eap/requirements.txt)
and managed addon virtual environment. The dashboard's JavaScript renderer
remains separate (`npm ci --prefix dashboard`); its Python server and the Fleet
RHC helper require no additional pip packages.

## Install

Download your pull secret to `~/Downloads/pull-secret.txt`, then run:

```bash
git clone https://github.com/ShaddGallegos/aap-demo.git
cd aap-demo
./scripts/local-prereq.sh --full
```

On Linux x86_64, `--full` installs CRC when needed, installs `aap-demo`, creates and
deploys the local AAP environment, then enables MCP Server, APME, Product Demos, and
Automation Orchestrator. It automatically imports `~/Downloads/pull-secret.txt`; use
`--pull-secret /path/to/pull-secret.txt` when the download is elsewhere. Optional APME
GitHub integration can be configured later.

For AAP without the addon suite, run `./install.sh`, then start a new shell (or
`source ~/.bashrc` on Bash) and run `aap-demo deploy`. The installer manages
`~/.local/bin` in Bash PATH and installs Bash completion idempotently.

`aap-demo create` provisions the MicroShift VM only. `aap-demo deploy` installs OLM and AAP
(use `deploy` for the typical path; `create` alone is for cluster-only setup).

Cluster credentials live at `~/.aap-demo/kubeconfig.microshift` and are **not** merged into
`~/.kube/config`. If you relied on the old default kubeconfig behavior, run:

```bash
export KUBECONFIG=~/.aap-demo/kubeconfig.microshift
# or: aap-demo kubeconfig   # refresh file and print export command
```

## Status

```bash
aap-demo version       # Tool version, commit, and build timestamp
aap-demo status        # Show routes and health without secret values
aap-demo status --show-secrets  # Reveal credentials in an interactive terminal
```

```text
AAP Demo Status
===============

Infra:       OpenShift Local (CRC)
Cluster:     running (crc-microshift)

Namespaces:
-----------
  aap-operator         27/29 pods   aap

AAP Deployments:
----------------
  https://aap-aap-operator.apps.127.0.0.1.nip.io

Credentials: hidden (run 'aap-demo status --show-secrets' in a terminal to reveal)

Addons:
-------
  mcp-server      disabled
  portal          disabled
  portal-operator disabled (AMD64 only)
  setup-pah       disabled
  ao            disabled
  apme-eap        disabled
  local-cache     disabled
  product-demos       disabled
  product-demo-satellite  disabled
```

## Addons to add additional functionality

```bash
aap-demo enable              # List all addons
aap-demo enable portal       # Installs Automation Portal
aap-demo enable portal-operator # Installs Operator-based Portal (Technology Preview; AMD64 only)
aap-demo enable setup-pah     # Configures Private Automation Hub Credentials
aap-demo enable mcp-server   # MCP server for AI assistants
aap-demo enable ao           # Automation Orchestrator (GA; no aapctl required — see addons/ao/README.md)
aap-demo enable apme-eap     # Early Access Program only for APME
aap-demo enable local-cache  # Caches AAP containers locally so you don't re-download after destroy/create

# Ansible Product Demos - Official demo content from ansible/product-demos
aap-demo enable product-demos        # Five domains at once (includes base; Satellite opt-in)
aap-demo enable product-demo-satellite  # Satellite demos (requires a Satellite server)
aap-demo disable addon_name  # Disables addon
```

When destroying a running cluster, `aap-demo destroy` asks whether to save the
container images locally. Confirming lets the next `aap-demo deploy` reuse the
cached containers instead of downloading them again. Existing cached images are
loaded automatically at the start of the next deploy.

Normal destroy/recreate flow:

```bash
aap-demo destroy   # answer y at the cache prompt
aap-demo create
aap-demo deploy     # automatically loads the saved cache
```

You do not need to run `aap-demo enable local-cache load` for this normal flow.

To manage the cache manually:

```bash
aap-demo enable local-cache load   # one-shot reload into fresh VM
aap-demo enable local-cache        # restore auto-load on future deploys
```

### Common Commands

```bash
# Deployment
aap-demo deploy              # Deploy AAP 2.7
aap-demo create --full-demo  # Create AAP + Ollama/AO + three RHEL 9 Fleet nodes + boot recovery + dashboard

# Cluster management
aap-demo status              # Show cluster status and routes; secrets stay hidden
aap-demo status --show-secrets # Reveal credentials interactively
aap-demo stop                # Stop the cluster
aap-demo start               # Resume the configured demo and wait for readiness
aap-demo ssh                 # SSH into the cluster node
aap-demo watch               # Monitor deployment progress
aap-demo destroy             # Delete entire cluster

# AAP Operator Idle
aap-demo idle true           # Scale down AAP to save resources
aap-demo idle false          # Scale back up
aap-demo idle                # Check current idle state

# Troubleshooting
aap-demo diagnose            # Quick health check (cluster, storage, SCCs, pods)
aap-demo must-gather         # Collect full diagnostics (AAP + cluster)
aap-demo must-gather /tmp/d  # Collect to specific directory
aap-demo repair              # Fix after sleep/wake issues

# Maintenance
aap-demo maintenance         # Preview reclaimable VM runtime data
aap-demo maintenance --apply # Remove exited containers, unused images, and old caches/logs
aap-demo maintenance uninstall         # Preview complete environment removal
aap-demo maintenance uninstall --apply # Remove VMs, caches, trust, CLI, and residual state
aap-demo clean               # Remove AAP deployment (keeps cluster)
aap-demo update              # Pull latest code and reinstall
aap-demo help                # Full command reference
```

`aap-demo create --full-demo` is a fail-fast demo bootstrap.
It creates a cluster sized for the included addons, deploys AAP 2.7, configures
Automation Hub, enables the offline-token keepalive, enables Ollama and
Automation Orchestrator, then enables Fleet, attaches the AAP subscription, and
reconciles three started and registered RHEL 9 nodes. Product Demos is installed
after licensing succeeds. A final strict `aap-demo wire` runs after all
components are present, then automatic boot recovery is installed and the
dashboard launches. Recovery installation and dashboard startup must both succeed
before full-demo reports success. Fleet image download
and AAP subscription attachment require Red Hat credentials. Full-demo checks
them first and starts the secure `fleet auth` prompts when they are missing or
invalid. Runs with `QUIET=true` remain noninteractive and require credentials to
be configured in advance. If the Automation Hub token is not configured,
setup-pah prompts for that distinct token. Customer Portal and Automation Hub
tokens remain separate in encrypted storage. Reruns reuse existing Fleet nodes
instead of creating duplicates. Use `--no-open` to run the dashboard without
opening a browser.

### Dashboard

`aap-demo dashboard` starts the localhost dashboard **in the background** and
returns to your terminal after its HTTP listener is ready. It opens your browser
unless you pass `--no-open`. Running the command again reuses the dashboard for
this checkout rather than starting a duplicate.

The Environment Overview shows the host OS, the CRC guest OS when available,
and the AAP subscription selected during automatic licensing. The small
**Restart dashboard** button reloads the dashboard server and reconnects the
page without restarting CRC, AAP or Fleet. Restart is blocked during an active
dashboard add-on operation.

The default address is `http://127.0.0.1:8765`; set `AAP_DEMO_DASHBOARD_PORT`
to choose another port. Logs go to `~/.aap-demo/dashboard.log` (or
`$AAP_DEMO_DIR/dashboard.log`). It also starts automatically after `aap-demo create`,
`start` and `restart` (set `AAP_DEMO_DASHBOARD_AUTOSTART=false` to disable). On Linux the first run also adds a
desktop login entry (`~/.config/autostart/aap-demo-dashboard.desktop`) so the dashboard opens after reboot. For foreground debugging, run
`python3 dashboard/server.py --no-open`. Background mode does not install a
boot/login service.

### OpenShift web console (single-node OpenShift preset)

MicroShift, the default preset, has no web console. For the full single-node
OpenShift console, create the cluster with the OpenShift preset:

```bash
CRC_PRESET=openshift aap-demo create --full-demo
```

The preset is saved as `CRC_PRESET` in `~/.aap-demo/config`, so later `start`,
`restart` and boot recovery keep using it. `create`, `start`, `restart` and
`create --full-demo` open the console automatically; run `aap-demo console` (add
`--no-open` to only print the URL) at any time. Set
`AAP_DEMO_CONSOLE_AUTOOPEN=false` to disable the automatic open. Routes use
`*.apps-crc.testing` on this preset instead of nip.io. It needs more RAM than
MicroShift (see ADR-020).

To pick the tier automatically from host hardware, use
`scripts/aap-demo-tier-select.sh`. It inspects vCPUs, RAM and root disk space,
then deploys SNO (`CRC_PRESET=openshift`, >= 8 vCPUs / 16 GB RAM / 100 GB disk)
or MicroShift (>= 2 vCPUs / 2 GB RAM / 10 GB disk). When both are supported it
shows an interactive menu; otherwise it falls back to MicroShift or exits with
the missing prerequisites. Use `--tier sno|microshift` to skip the menu,
`--yes` for non-interactive runs, and `--dry-run` to preview.

### Resuming the demo

Run `aap-demo start` after stopping CRC, rebooting the host, or idling AAP. It:

1. Starts CRC and checks its filesystem usage. At **90% or higher**, it grows the
   existing VM disk by **20%**, rounded up to whole GiB, using a brief CRC
   stop/start. CRC expands the guest filesystem while preserving data and the PV
   reservation. Host free space is checked before resizing; no rebuild, forced
   shutdown, or deletion is performed.
2. Waits for the Kubernetes API and node readiness, restores CoreDNS routing, and
   recovers the AAP operator catalog.
3. Waits for installed networking, ingress, storage and OLM workloads; refreshes
   ingress CA trust using the existing local-development trust settings.
4. Resumes idle AAP through its custom resource, waits for workloads and operator
   reconciliation, and checks the gateway API.
5. Waits for enabled addons, starts preserved Fleet VMs, reapplies integrations,
   and checks workloads again before displaying status and the kubeconfig export.

Healthy application pods are not forcibly restarted. Disabled addons are not
enabled, missing deployments are not silently reinstalled, and failures return
nonzero with diagnostic guidance instead of reporting a ready demo.

The readiness timeout is **600 seconds per phase**, adjustable with
`AAP_START_TIMEOUT=900 aap-demo start`. Catalog recovery retains its separate
`AAP_START_CATALOG_TIMEOUT` setting. Disk checks run **during startup**, not in a
background monitoring service; there is no fixed 100 GiB free-space requirement.
They cover CRC's `/var` filesystem, not individual PVCs or a separately attached
persistent image-store disk. Interrupted disk growth retains its target for a
safe retry instead of repeatedly adding 20%.

### Automatic boot recovery

On Linux with CRC/libvirt, `aap-demo create --full-demo` automatically installs
a system service that resumes the latest CRC disks, settings, credentials and
demo configuration in place at boot. It starts AAP, enabled addons/Fleet and the
dashboard HTTP server before login; the browser opens at graphical login.
There is no manual checkpoint step before reboot and no automatic rollback to an
older backup. Recovery installation failures fail the full-demo command.

```bash
aap-demo service install             # Retain only the latest completed state
aap-demo service install --force-stop --stop-timeout 120  # Linux: opt in to crash-consistent CRC fallback
aap-demo service retention 3         # Optionally keep three states instead
aap-demo restart                     # Save and restart the latest persistent demo
```

This uses full cold backups of CRC/Fleet disks, configuration and required
keys/credentials. It briefly stops the demo for each backup and requires host
disk space. While enabled, `start`, `restart` and `stop` route through systemd.
Starting uses the live persistent state and brings the demo fully online; it does
not overwrite newer state with a checkpoint. Install it separately with
`aap-demo service install` for an existing demo. Windows currently has only
login-time checkpoint recovery, not pre-login full-demo parity.
See [shutdown backups and boot recovery](docs/state-service.md)
for retention, security, recovery and disabling instructions.

`maintenance --apply` keeps running containers, images used by workloads,
namespaces, PVCs, and the optional local image cache. It also vacuums system
journals older than seven days and reports the VM disk space reclaimed.

`maintenance uninstall --apply` requires typing `UNINSTALL` and removes the CRC
cluster, Fleet VMs and images, CRC downloads, generated credentials and caches,
temporary swap, ingress trust entries, MCP/shell integration, CLI symlink, and
completions. It also stops the dashboard, removes recovery services and backups,
deletes `~/.aap-demo`, and removes the `aap_demo` namespace from the encrypted
credential Vault. If no unrelated Vault data remains, it removes the Vault
file, but always preserves the shared Vault password file. The source
repository, shared command-line tools/packages,
unrelated Vault keys, and libvirt group membership are preserved. For noninteractive
use, also set `AAP_DEMO_UNINSTALL_CONFIRM=UNINSTALL`.

## Credential storage

### Fleet inventory and node access

Fleet nodes are reconciled into the **Fleet** inventory in AAP's **Default**
organization, with the **Fleet SSH Key** machine credential using the bootstrap
`ansible` account for unattended privilege escalation. Interactive and browser
SSH use `admin`; its sudo access requires its own password.
Registration updates existing host addresses/ports and the credential, rather
than skipping previously registered nodes. Enabling Product Demos and
`aap-demo wire` also reconcile existing Fleet nodes; they do not create VMs.
Create nodes first if none exist.

```bash
aap-demo fleet register                 # Reconcile existing nodes and verify AAP ping
aap-demo fleet ssh 1                    # SSH as admin using the managed key
aap-demo status --show-secrets          # Interactive only: per-node admin passwords and IPs
ssh -p 2201 admin@127.0.0.1              # Password login to node 1
```

Each node has its own generated admin password, retained in the shared encrypted
Vault under `aap_demo.fleet.node_<index>.password`. Registration reuses the
password and configures existing nodes without rebuilding them. Admin's validated
`/etc/sudoers.d/aap-demo-admin` contains exactly:

```sudoers
admin     ALL=(ALL)       ALL
```

Admin is removed from `wheel` to avoid inheriting passwordless group rules.
The existing `ansible` automation account retains its bootstrap sudo access.

Fleet guests have isolated QEMU user-mode networks and may all report the same
guest IP, such as `10.0.2.15`. From the host use **127.0.0.1** and each node's
forwarded SSH port (normally **2201**, **2202**, **2203**). AAP uses the host
gateway address and these ports, not the isolated guest IP.

#### Red Hat system enrollment (manual opt-in)

Run this explicitly to enroll all **running Fleet VMs** using the retained CDN
username/password from the shared Ansible Vault:

```bash
aap-demo fleet rhc-connect
```

This authorizes `rhc connect`: RHSM registration, Red Hat Insights inventory and
report uploads, and activation of the Remote Host Configuration daemon (remote
management). Systems appear under the credential owner's Red Hat account; this
does **not** identify each person who uses the demo. Review Red Hat's data
collection policies before enrolling. This command makes no claim that
registration alone produces demo-usage analytics.

Credentials are supplied through encrypted SSH stdin and RHC's interactive PTY
prompts, never CLI arguments, persistent plaintext credential files, or printed
tool output. Existing complete connections are reused. Partial Insights
enrollment is completed with `insights-client --register`, and all three RHC
components must verify as connected before success is reported. Errors and
timeouts fail explicitly; raw authentication output is withheld. Run
`sudo rhc status` on a VM for local diagnostics.

There is no automatic enrollment on node creation/start or dashboard access.
Run the command again after adding/starting nodes; stopped nodes are skipped.
If credentials are missing, configure them with `aap-demo fleet auth configure`.
Destroying a VM does not automatically remove its record from Red Hat's console;
disconnect it explicitly before deletion if needed.

**CRC limitation:** the current OSTree MicroShift appliance has no `rhc` or
`insights-client`. It is not enrolled by this command. Installing or layering
those packages and restarting the cluster requires a separate supported plan;
the command does not mutate the cluster appliance or development host.

#### Node-to-node SSH and managed hosts

Every Fleet admin gets its own Ed25519 key. Only public keys are exchanged;
private keys remain on their originating VM. Existing keys are reused.
From any Fleet VM, use either name:

```bash
ssh aap-fleet-node-2
ssh aap-fleet-node-2.fleet.aap-demo.test
sudo -v                              # Enter this node's admin password
```

Managed SSH aliases select the host gateway and forwarded port automatically.
Host keys are collected over the verified bootstrap connection and pinned with
strict checking. Files are in admin's `.ssh` directory: `aap-demo-config` and
`aap-demo-known_hosts`; the user's main SSH config includes the managed config.
Authorized-key updates preserve unmanaged keys and remove stale managed keys.

Each Fleet VM gets a managed block in `/etc/hosts`, with **IPv4 FQDN shortname**
entries for all defined Fleet nodes, the development host (`aap-demo-host`),
cluster machines, and exposed application routes. Localhost, IPv6, and other
unmanaged entries are preserved. Conflicting unmanaged aliases, duplicate names,
malformed markers, and failed cluster discovery cause explicit failures rather
than overwriting local configuration or installing incomplete discovery results.
Kubernetes pods and services continue to use cluster DNS.

Fleet aliases intentionally share the host gateway IP: `/etc/hosts` cannot encode
ports and does not give isolated VMs unique IPs. Only the SSH aliases select the
right VM; arbitrary protocols still require their own forwarding. Application
routes map to the host ingress listener instead of guest loopback. Cluster
machine entries retain their discovered internal IPs; this does not add routing
to otherwise unreachable cluster networks.

Reconciliation runs on Fleet add/start/remove, `fleet register`, Product Demos
installation, and `aap-demo wire`. Stopped nodes retain hosts entries, but their
SSH aliases and public keys are included only while running; starting them
reconciles again. Rerun `aap-demo fleet register` after host address or route
changes. No background hosts watcher is installed. Only Fleet VMs are modified;
the development host and cluster VM are discovery sources, not configuration
targets. The default suffix is `fleet.aap-demo.test`; override consistently with
`FLEET_DOMAIN` if needed.

The dashboard's **Application Access / Routes** panel lists every Fleet node.
Click its **SSH terminal** link to open an interactive browser terminal that
automatically connects as `admin`, using the managed SSH key on the server.
Passwords and private keys are never sent to the browser. For a fresh checkout,
install the pinned local terminal renderer once:

```bash
npm ci --prefix dashboard
aap-demo dashboard
```

No CDN or external terminal service is used. Browser terminals are restricted
to the localhost dashboard and known Fleet nodes, require its session token
and same-origin requests, and verify stored SSH host keys. Up to four sessions
can run concurrently. Disconnect or close the tab when finished; abandoned
sessions expire after five minutes without requests. Restarting the dashboard
closes terminal sessions, not the VMs. Fleet browser SSH is supported on Linux
and macOS hosts.

### Shared Vault

aap-demo stores retained passwords and tokens under the `aap_demo` namespace
and the `ah_offline_token` key in Ansible Vault-encrypted
`~/.ansible/conf/env.yml`. The Vault password file is
`~/.ansible/conf/.vaultpass.txt`. Unrelated YAML keys are preserved, and older
aap-demo Vault files are merged automatically. A password file is generated
automatically for a new Vault only. The directory is mode
`0700` and both files are mode `0600`. Existing password contents are never
replaced, and uninstall preserves the shared password for other products.

Status, watch, deploy, and generated system-information output hide secrets by
default. Use `aap-demo status --show-secrets` only in an interactive terminal.
This prints available AAP and addon login passwords without writing them to a
file; redirected use is rejected.
Keeping the encrypted Vault and its password in the same user-only directory
prevents accidental Git disclosure, but it does not protect against compromise
of the user account.

The Customer Portal offline token from
`https://access.redhat.com/management/api` is stored as
`aap_demo.redhat.offline_token` and is used for entitlements, Fleet downloads,
and AAP licensing. The distinct Automation Hub token from
`https://console.redhat.com/ansible/automation-hub/token` is stored as
`ah_offline_token` and is used for collection synchronization (the older
`aap_demo.galaxy.offline_token` key remains readable).
The tokens are validated and maintained separately.

### Offline-token keepalive

Red Hat offline tokens can expire after 30 days without use. Enable the optional
daily keepalive after configuring Fleet or Automation Hub credentials:

```bash
aap-demo credentials keepalive enable
aap-demo credentials keepalive setup    # Validate/store Hub token and install four-day cron
aap-demo credentials keepalive status
aap-demo credentials keepalive run      # one-shot validation
aap-demo credentials keepalive disable
```

The keepalive reads tokens directly from encrypted `env.yml`, exchanges each
configured token for a short-lived access token, and immediately discards the
result. It never stores or logs token values. Linux uses a persistent systemd
user timer; macOS uses a LaunchAgent. A rejected token can trigger a desktop
notification, while temporary network failures are logged for the next retry.
The `setup` action is an alternative Hub-only cron workflow using `0 0 */4 * *`.
It reuses a valid stored token and securely re-prompts for missing or rejected
tokens. See [collection authentication](docs/collection-authentication.md)
for Vault-password configuration and cron timing details.

## Architecture

Architecture decisions are documented in [docs/adr/](docs/adr/README.md) (14 ADRs covering CLI
design, storage, OLM, addons, and cross-platform support).

### macOS / Linux / Windows

- **Networking:** SSH (2222), API (6443), HTTP/HTTPS (443) — all on localhost
- **Routes:** `*.apps.127.0.0.1.nip.io` (nip.io DNS, no /etc/hosts needed)
- **TLS:** MicroShift's ingress CA auto-trusted on macOS keychain / Linux ca-trust;
  on Windows, run `aap-demo deploy` from an elevated PowerShell (see
  [powershell/README.md](powershell/README.md#ingress-ca-and-browser-tls))

## Environment Variables

```bash
CRC_CPUS=8                   # VM CPU count (default: 8)
CRC_MEMORY=16384             # VM memory in MiB (default: 16384)
CRC_DISK=180                 # VM disk; minimum leaves 100 GiB for root/container images
CRC_PV_SIZE=70               # LVMS PV override; otherwise derived below CRC_DISK
NAMESPACE=aap-operator       # Target namespace
QUIET=true                   # Suppress disclaimer
```

## Troubleshooting

```bash
aap-demo diagnose      # Quick health check — finds common issues
aap-demo diagnose --ai # AI-powered analysis (requires claude CLI)
aap-demo must-gather   # Collect full diagnostics for support
```

On MicroShift 4.22+, `aap-demo deploy` relaxes container signature verification for
`registry.redhat.io` inside the CRC VM so operator index images can pull. This is a
**demo-only** workaround and must not be used as a production pattern.

## Clean Up

```bash
aap-demo clean         # Remove AAP (keep cluster)
aap-demo destroy       # Delete everything
./install.sh --uninstall  # Remove aap-demo CLI
```

## Documentation

- **[Full README](docs/FULL-README.md)** — Complete documentation, architecture, troubleshooting
- **[Changelog](CHANGELOG.md)** — Successful changes since the original 1.0.48 baseline
- **[Roadmap](ROADMAP.md)** — Prioritized project evolution and measurable milestones
- **[Architecture Decision Records](docs/adr/)** — Design decisions and rationale
- **[Contributing](docs/CONTRIBUTING.md)** — Development guidelines
- **[Linting](docs/LINTING.md)** — Ansible linting setup

### Versioning

Feature PRs do not need to change [`VERSION`](VERSION). Update it deliberately when preparing
a release; CI only verifies that the checked-in value is valid semver. Development builds are
also identified by the commit SHA and build timestamp shown by `aap-demo version`.

```bash
aap-demo version              # show current version + git build info
cz bump --increment PATCH     # after ./scripts/setup-linting.sh (optional)
```
