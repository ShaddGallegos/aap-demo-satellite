# aap-demo

Local cluster infrastructure for AAP 2.7 deployment, powered by OpenShift Local.
Deploy AAP in minutes on macOS, Linux, or Windows.

## Portability and idempotency

Lifecycle and addon commands are convergence operations: rerunning a successful
create, deploy, enable, start, wire, or full-demo command reuses or updates
managed resources rather than intentionally creating duplicates. Kubernetes
namespaces and managed secrets use apply-style updates, while persistent config
keys are replaced in place.

Bash state defaults to `~/.aap-demo` and its config defaults to
`~/.aap-demo/config`. Override these with `AAP_DEMO_DIR` and
`AAP_DEMO_CONFIG`; child addon processes inherit both. `NAMESPACE`,
`KUBECONFIG`, and `AAP_DEMO_KUBECONFIG` select non-default cluster targets.
`QUIET=true` is the noninteractive contract and fails with guidance if required
credentials or choices are unavailable.

Linux and macOS use Bash. Native Windows uses PowerShell, and WSL uses the
Windows-hosted wrapper. Addons select `amd64`/`x86_64` or `arm64`/`aarch64`
artifacts only where both are supported and fail explicitly otherwise. CRC
keeps its upstream-owned files in `~/.crc`. Linux systemd recovery intentionally
requires default state paths; custom paths are supported by ordinary CLI/addon
operations. A failed or interrupted remote API operation is not treated as
success and can be safely retried after connectivity is restored.

## Quick Start

### Prerequisites

#### System Requirements

A typical MicroShift and AAP 2.7 environment requires 24GB of RAM, 2 cores, and
100 GB of storage. We recommend having a total of 32GB RAM available on your system.
The 24GB default supports AAP plus EAP addons (AO, APME); use `CRC_MEMORY=16384` for 16GB if running AAP alone.

#### MacOS

- [Homebrew](https://brew.sh/) — Install with: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
- [Operator SDK](https://sdk.operatorframework.io/docs/installation/) — Install with: `brew install operator-sdk`

#### Core Python tools (manual Linux/macOS setup)

Use a Python 3.11 virtual environment (the tested setup and CI baseline) from the
repository root to avoid changing system-managed packages:

```bash
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
python -m pip check
```

The root [requirements.txt](../requirements.txt) provides `ansible-core`,
`PyYAML`, and the Kubernetes Python client. Ansible collections remain in
[requirements.yml](../requirements.yml); version ranges are not a lockfile.
Activate the environment in each CLI shell; `deactivate` restores the prior
shell environment. `.venv` is ignored by Git. System tools still require the
platform-specific prerequisites above/below.
Other Python versions require compatible Ansible releases: pip resolution alone
does not guarantee CLI compatibility. Stable `ansible-core` 2.21.5 failed its CLI
startup check on this host's Python 3.15; use the tested interpreter instead.

APME continues to manage its own environment using its addon-specific manifests;
dashboard npm dependencies and system-installed RHC/Insights tools are separate.
See the [manual Python setup](../README.md#python-dependencies-manual-virtual-environment-setup).

#### Windows

- Windows 11 Pro, Enterprise, or Server (Hyper-V is not available on Windows 11 Home)
- [OpenShift Local](https://console.redhat.com/openshift/create/local) — includes `crc`; Hyper-V must be enabled
- [Git for Windows](https://git-scm.com/download/win) — optional for `create`/`deploy`/`status`;
  required for `diagnose`, `test`, `watch`, and other advanced commands

  ```powershell
  winget install --id Git.Git -e --source winget
  ```

- PowerShell 5.1 or later (included with Windows 10/11)

#### OpenShift Local

- OpenShift Local — [Install](https://console.redhat.com/openshift/create/local)
- On Linux: also install `libvirt-daemon`, `libvirt-daemon-driver-storage`, `libvirt-daemon-driver-network`, `qemu-kvm`
- On Windows: Hyper-V enabled (OpenShift Local requirement)
- Obtain a **Pull Secret** from the [Red Hat Console](https://console.redhat.com/openshift/install/pull-secret)

#### Host prep for memory-constrained systems (Linux)

CRC defaults to 16–24 GB of VM RAM. On a 32 GB workstation, image pulls and operator
reconciliation can exhaust host memory.

During interactive `aap-demo create` on **Linux**, you are prompted for temporary swap
before CPU, memory, and disk allocation (default yes on hosts with 36 GB RAM or less). The
script creates a `swapon` file at `/swapfile-aap-demo` by default and handles btrfs
(Fedora), xfs/ext4 (RHEL), and SELinux `swapfile_t`.

```text
Resource allocation for CRC VM:
  Host: 16 CPUs, 30GB RAM (8GB swap)

  Create temp swap for deploy? [Y/n]:
  Temp swap size in GB [16]:
  CPUs [8]:
  Memory in GB [16]:
  Disk size:
    1) 180 GB (minimum; 100 GB for root/container images)
    2) 220 GB
    3) 270 GB
    4) 320 GB
  Choice [1]:
```

Host prep for pull secret, libvirt, and CRC setup:

```bash
./scripts/local-prereq.sh
./scripts/local-prereq.sh --deploy  # prepare and deploy from this checkout
```

Manual swap management (non-interactive or after deploy):

```bash
./scripts/enable-temp-swap.sh                              # 16 GB temp swap file
AAP_ENABLE_TEMP_SWAP=true AAP_SWAP_SIZE_GB=24 aap-demo create   # scripted create
./scripts/enable-temp-swap.sh disable                      # remove after deploy
```

Swap files are not added to `/etc/fstab`. Remove after deploy with
`./scripts/enable-temp-swap.sh disable` or `aap-demo destroy`.
See [scripts/README.md](../scripts/README.md) for Linux-only details.

### macOS / Linux

#### Download your pull secret from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret)

```bash
mkdir -p ~/.aap-demo
cp ~/Downloads/pull-secret.txt ~/.aap-demo/pull-secret.txt
```

The next create/deploy imports this file into encrypted
`~/.ansible/conf/env.yml` and removes the managed plaintext copy. Delete the
original download after successful import. When the pull secret is missing but
the encrypted Vault contains a valid Customer Portal offline token,
`aap-demo create` exchanges that token for short-lived access and retrieves a
fresh pull secret from Red Hat's official API without writing plaintext to disk.
This implements the REST automation documented in Red Hat Solution
[4844461](https://access.redhat.com/solutions/4844461); direct username/password
grants are intentionally not used.

#### Install

```bash
git clone https://github.com/ShaddGallegos/aap-demo.git
cd aap-demo && ./install.sh
```

#### Deploy

```bash
aap-demo deploy        # Deploy AAP 2.7
aap-demo status        # Check deployment status
```

### Windows

See the **[Windows installer guide](powershell/README.md)** for full install and usage
instructions. Summary:

#### Save your pull secret

Download from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret) and save as:

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.aap-demo"
Copy-Item "$env:USERPROFILE\Downloads\pull-secret.txt" "$env:USERPROFILE\.aap-demo\pull-secret.txt"
```

#### Install

```powershell
git clone https://github.com/ShaddGallegos/aap-demo.git
cd aap-demo
.\powershell\install.ps1
```

This registers the repo path, installs the `aap-demo` launcher to
`%USERPROFILE%\.local\bin`, adds that directory to your user PATH, and downloads
`operator-sdk` if needed.

Open a **new** PowerShell window after install so PATH changes take effect.

#### Deploy

```powershell
aap-demo create        # Create the cluster
aap-demo deploy        # Deploy AAP 2.7
aap-demo status        # Check deployment status
```

#### Uninstall

```powershell
.\powershell\install.ps1 -Uninstall
```

This removes the wrapper and PATH entry. It does not delete `%USERPROFILE%\.crc\` or
other cluster data.

#### Windows notes

- Kubeconfig default: `%USERPROFILE%\.crc\machines\crc\kubeconfig`
- Config file: `%USERPROFILE%\.aap-demo\config`
- If `aap-demo` is not recognized, confirm `%USERPROFILE%\.local\bin` is on PATH and
  restart PowerShell
- `create`, `deploy`, and `status` are PowerShell-native; install Git for Windows for
  other commands (`diagnose`, `test`, `watch`, …)
- See [powershell/README.md](powershell/README.md) for full Windows install and usage

Once deployed, `aap-demo status` shows routes and cluster health without
printing credentials. Use `aap-demo status --show-secrets` in an interactive
terminal when credentials must be revealed:

On the Bash CLI, this output also includes `crc_ip`, the detected SSH identity
file in a direct SSH command, and `aap-demo ssh`. Generated `system-info`
reports include the same CRC access information alongside the credentials;
JSON reports expose `cluster.crc_ip` and `cluster.ssh`. CRC's IP can be internal
to user-mode networking, so use `aap-demo ssh` or the forwarded
`core@127.0.0.1` endpoint on port 2222 from the host. SSH private key contents
are never printed or included in the report.

```text
Infra:       crc
Cluster:     running

Namespaces:
-----------
  aap-operator         27/27 pods   aap  https://aap-aap-operator.apps.127.0.0.1.nip.io
  olm                  4/4 pods

Credentials: hidden (run 'aap-demo status --show-secrets' in a terminal to reveal)

Enabled Addons:
---------------
  mcp-server      https://aap-mcp-aap-operator.apps.127.0.0.1.nip.io/mcp
```

On the OpenShift preset (`CRC_PRESET=openshift`), routes use
`*.apps-crc.testing` and the full OpenShift web console is available via
`aap-demo console`.

### Self-Service Portal (AAP 2.7)

Deploy the Ansible Automation Portal (Red Hat Developer Hub + AAP plugins) as a Helm addon:

```bash
aap-demo enable portal       # Auto-detects cluster CPU (amd64 vs arm64)
aap-demo disable portal
aap-demo status portal       # Portal route URL
```

**Requirements:** AAP deployed and `registry.redhat.io` credentials for OCI plugins.
Helm 3.10+ is installed automatically if missing.

**Profiles:** x86 clusters use Red Hat RHDH chart images; arm64 clusters (e.g. CRC on Apple
Silicon) use community multi-arch RHDH overrides. See
[ADR-002](adr/002-portal-helm-deployment.md) and [addons/portal/README.md](../addons/portal/README.md).

## Overview

aap-demo deploys Ansible Automation Platform 2.7 to OpenShift Local (MicroShift) for development, testing, and demonstration.

**Key characteristics:**

- One command setup: `aap-demo deploy`
- Full OpenShift API compatibility (OLM, Routes, CRDs)
- Shared Podman/CRI-O storage — locally built images are immediately available to pods
- In-cluster registry at `registry.apps.127.0.0.1.nip.io`
- Valid TLS certificates (auto-trusted on macOS/Linux)
- Addon system: `aap-demo enable mcp-server`
- Reproducible — destroy and recreate in minutes

## Collection Authentication

aap-demo automatically configures Ansible Galaxy authentication for downloading certified and private collections:

- **Red Hat Certified Collections**: Offline token stored as `ah_offline_token` in `~/.ansible/conf/env.yml`
- **Private Automation Hub**: URL in `~/.aap-demo/pah-config.yml`; credentials in the encrypted Vault
- **Priority-based fallback**: PAH → console.redhat.com → galaxy.ansible.com (community)

Collections are installed automatically during deployment from `config/requirements.yml`. Skip with `SKIP_COLLECTIONS=true`.

**Status**: View configured sources with `aap-demo status`
**Diagnostics**: Validate authentication with `aap-demo diagnose`
**Documentation**: See [docs/collection-authentication.md](docs/collection-authentication.md)

## Deploy MCP Server

```bash
aap-demo enable mcp-server     # MCP server for AI assistants
aap-demo disable mcp-server
```

### Common Commands

```bash
# Deployment
aap-demo deploy              # Deploy AAP 2.7
aap-demo create --full-demo  # Create AAP + Ollama/AO + three RHEL 9 Fleet nodes + dashboard

# Cluster management
aap-demo status              # Show cluster status and routes without secrets
aap-demo status --show-secrets # Reveal credentials interactively
aap-demo stop                # Stop the cluster
aap-demo start               # Start the cluster
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
components are present, then the dashboard launches. Fleet image download
and AAP subscription attachment require Red Hat credentials. Full-demo checks
them first and starts the secure `fleet auth` prompts when they are missing or
invalid. Runs with `QUIET=true` remain noninteractive and require credentials to
be configured in advance. If the Automation Hub token is not configured,
setup-pah prompts for that distinct token. Customer Portal and Automation Hub
tokens remain separate in encrypted storage. Reruns reuse existing Fleet nodes
instead of creating duplicates. Use `--no-open` to run the dashboard without
opening a browser.

`aap-demo dashboard` now starts in the background and returns after its localhost
listener is ready. Repeating it reuses this checkout's running dashboard.
Logs are written to `~/.aap-demo/dashboard.log` (or `$AAP_DEMO_DIR/dashboard.log`).
The Environment Overview shows the host OS, CRC guest OS when available, and
the AAP subscription selected during automatic licensing. Use the small
**Restart dashboard** button to restart only the dashboard and reconnect the
page; it is blocked during dashboard add-on operations and does not restart
CRC, AAP or Fleet. For foreground debugging, use
`python3 dashboard/server.py --no-open` from the repository root.

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

Retained passwords and tokens are stored under the `aap_demo` namespace and
the `ah_offline_token` key in Ansible Vault-encrypted `~/.ansible/conf/env.yml`, using
`~/.ansible/conf/.vaultpass.txt`. Existing unrelated YAML is preserved during
updates and migration. The directory is mode `0700`; both files are mode
`0600`, and the password is generated automatically for a new Vault only.
Existing password contents are never replaced; uninstall preserves the shared
password for other products. Co-locating
the encrypted Vault and password protects against accidental
publication, not compromise of the local user account.

Fleet node access is reconciled by `aap-demo fleet register`, Product Demos
installation (when nodes exist), and `aap-demo wire`. The AAP **Fleet** inventory
in the **Default** organization and **Fleet SSH Key** credential are updated to
use the bootstrap `ansible` account for unattended automation. Interactive admin
sudo requires its Vault-backed password, with the exact rule
`admin     ALL=(ALL)       ALL`. Registration verifies connectivity with an AAP
ad-hoc ping and fails explicitly if verification fails.

Fleet add/start/remove and registration reconcile unique per-node admin Ed25519
keys, public-key exchange, pinned SSH aliases, and managed `/etc/hosts` blocks.
From a Fleet VM, `ssh aap-fleet-node-2` or
`ssh aap-fleet-node-2.fleet.aap-demo.test` uses the proper forwarded port.
Hosts blocks include Fleet, host, cluster machines, and exposed routes, while
preserving unmanaged/localhost/IPv6 entries and Kubernetes DNS. Private keys
are never copied between nodes. The host and cluster are not modified.
Because Fleet uses isolated QEMU networking, its hosts entries share the gateway
IP; this enables named SSH through aliases, not direct IP networking between VMs.
Run `aap-demo fleet register` after route or host-address changes.

Red Hat system enrollment is a separate, explicit opt-in command:
`aap-demo fleet rhc-connect`. It uses Vault-backed CDN credentials to connect
running Fleet VMs to RHSM, Insights reporting, and Remote Host Configuration.
Credentials travel through encrypted SSH stdin and interactive prompts, not
process arguments or logs. Complete connections are reused, partial Insights
registration is completed, and final status must verify all components.
New nodes are not automatically enrolled. This associates machines with the
Red Hat account; it does not identify individual demo users. CRC is deferred:
the OSTree appliance lacks RHC/Insights packages and is left unchanged.
See [manual enrollment](../README.md#red-hat-system-enrollment-manual-opt-in).

Use `aap-demo fleet ssh 1` for key-based SSH, or
`ssh -p 2201 admin@127.0.0.1` for password login to the first node.
`aap-demo status --show-secrets` displays each node's IP, forwarded SSH port,
username, and Vault-backed password only in an interactive terminal. Default
status, JSON inventory, and dashboard status omit passwords.

The dashboard **Application Access / Routes** panel has a browser SSH terminal
link for each node. Install its pinned renderer with `npm ci --prefix dashboard`
after a fresh checkout. SSH authentication remains on the host, never in a URL
or browser response; terminals are localhost-only, same-origin/session-protected,
bounded to four sessions, and expire after five minutes without requests.
See [Fleet inventory and node access](../README.md#fleet-inventory-and-node-access)
for networking and SSH host-key details.

`aap-demo status --show-secrets` reveals available AAP and addon login
passwords only in an interactive terminal; redirected output is rejected. The
Customer Portal token from `https://access.redhat.com/management/api` is stored
as `aap_demo.redhat.offline_token`. The distinct Automation Hub token from
`https://console.redhat.com/ansible/automation-hub/token` is stored as
`ah_offline_token` (the older `aap_demo.galaxy.offline_token` key remains readable).
They are validated and maintained separately.

If Customer Portal authentication fails, run `aap-demo fleet auth configure`
in an interactive terminal and paste the Customer Portal offline token at the
hidden prompt, not into chat or a shell command. `invalid_grant` means SSO
rejected the token; generate a replacement on the Customer Portal API page.
Network failures, server errors, and malformed SSO responses are reported
separately and do not trigger replacement of an existing stored token.

Offline tokens can expire after 30 days without use. The optional keepalive
reads configured Customer Portal and Automation Hub tokens directly from the
encrypted Vault once daily, exchanges them for short-lived access tokens, and
discards the results without logging secrets:

```bash
aap-demo credentials keepalive enable
aap-demo credentials keepalive setup    # Alternative Hub-only four-day cron workflow
aap-demo credentials keepalive status
aap-demo credentials keepalive run
aap-demo credentials keepalive disable
```

Linux uses a persistent systemd user timer so a missed run executes after wake
or boot. macOS uses a LaunchAgent. Invalid tokens can generate desktop
notifications; temporary network failures wait for the next scheduled retry.
The `setup` action securely validates/stores the Hub token and installs an
idempotent `0 0 */4 * *` user cron job. See
[collection authentication](collection-authentication.md) for password-file
configuration, retry behavior, and cron timing details.

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
CRC_MEMORY=24576             # VM memory in MiB (default: 24576, use 16384 for AAP-only)
CRC_DISK=180                 # VM disk; minimum leaves 100 GiB for root/container images
CRC_PV_SIZE=70               # LVMS PV override; otherwise derived below CRC_DISK
NAMESPACE=aap-operator       # Target namespace
QUIET=true                   # Suppress disclaimer
```

## Troubleshooting

```bash
aap-demo diagnose              # Quick health check — identifies common issues
aap-demo diagnose --ai         # Health check + AI-powered analysis (requires claude CLI)
aap-demo must-gather           # Collect full diagnostics for support
aap-demo status                # Check cluster and AAP status
aap-demo ssh                   # SSH into cluster node for debugging
aap-demo repair                # Repair after crash/sleep
aap-demo destroy && aap-demo create && aap-demo deploy   # Full rebuild
```

`aap-demo diagnose` checks cluster connectivity, storage classes, SCCs, namespace
labels, AAP CR status, pod health, PVC binding, and DNS. It provides actionable fix
suggestions for any issues found.

`aap-demo diagnose --ai` runs the same checks, then sends the results plus pod logs
and events to [Claude](https://claude.ai) for AI-powered root cause analysis and fix
suggestions. Requires the `claude` CLI
([Claude Code](https://docs.anthropic.com/en/docs/claude-code)).

`aap-demo must-gather` collects aap-demo config, CRC status, storage/PVC/pod/event
data, and runs the official [AAP must-gather](https://github.com/ansible/aap-must-gather)
image for operator-level diagnostics.

### AI-Assisted Development

This repository includes a `.claude/CLAUDE.md` file that provides Claude Code with
full aap-demo context. When running Claude Code in the aap-demo directory, it
automatically understands the architecture, common issues, and troubleshooting patterns.

## References

- [MicroShift](https://microshift.io/)
- [OpenShift Local](https://console.redhat.com/openshift/create/local)
- [AAP Documentation](https://access.redhat.com/documentation/en-us/red_hat_ansible_automation_platform/)

## Testing

Test suite validates core aap-demo commands without requiring cluster operations:

```bash
./test/test-core-commands.sh
```

Tests verify:

- `status` - execution and output format
- `start` - CRC startup + CoreDNS reconfiguration (fixes DNS after restarts)
- `stop` - CRC shutdown
- `destroy` - warning messages and cleanup logic
- `create` - script delegation and OLM setup

All tests use grep verification or command mocking to avoid destructive operations.

## Contributing

For questions or contributions, open an issue or pull request on GitHub.
