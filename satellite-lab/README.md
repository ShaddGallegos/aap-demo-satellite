# Satellite 6 Fast Demo Lab on a Single KVM/libvirt Host

Everything in this folder is ready to run. The fully automatic path is
`aap-demo create --full-demo --satellite` (or `sudo satellite-lab/build-and-configure.sh`
for just the lab), which downloads the RHEL ISO, provisions the VM, installs
Satellite, and configures content with no manual steps when the host is
registered with RHSM. Adjust non-sensitive settings such as the manifest path
or versions only if you run stages individually; credentials belong in the
encrypted Vault.

All retained Satellite credentials are generated or read through the encrypted
`aap_demo` namespace in `~/.ansible/conf/env.yml`; do not add passwords to the
scripts. The builder passes only the required values at runtime and reuses the
same Vault values on a retry.

## Architecture

> **Adapted for CRC user-mode networking.** CRC with either the OpenShift or
> MicroShift preset uses QEMU user-mode networking + vsock — there is no
> bridged `crc` libvirt network. The Satellite VM's first NIC therefore
> attaches to the libvirt `default` network (NAT to the host and upstream), and
> reaches AAP/CRC through the host's forwarded ports. The `satlab` network
> stays isolated for Satellite-owned DHCP/PXE/PXE provisioning of fleet nodes.

```
                 KVM/libvirt host  (IP forwarding enabled by 00-network-setup.sh)
   ┌──────────────────────────────┴───────────────────────────────────┐
   │  default network (existing)        satlab network (new)          │
   │  192.168.122.0/24  bridge: virbr0  192.168.150.0/24              │
   │  libvirt dnsmasq @ .122.1          bridge: virbr-satlab          │
   │  (NAT to host + upstream)          NAT out via host,             │
   │                                    NO libvirt DHCP here          │
   │                                                                 │
   │  CRC VM: user-mode networking + vsock (no libvirt bridge).       │
   │  AAP routes (apps.127.0.0.1.nip.io) resolve to 127.0.0.1 and     │
   │  are reached from VMs via the host's forwarded ports.            │
   │                                                                 │
   │                eth0   ┌────────────────────┐                     │
   │       .122.20 ───────►│  Satellite VM      │                     │
   │      (default net)    │  satellite.demo.lab│                     │
   │                       │              eth1  │ .150.10             │
   │                       │  DNS/DHCP/TFTP/    │                     │
   │                       │  Pulp/REX/registry │                     │
   │                       └─────────┬──────────┘                     │
   │                                 │ PXE + DHCP + HTTP              │
   │                       ┌─────────┴──────────┐                     │
   │                       │ fleet nodes        │ .150.100-200        │
   │                       │ (RHEL 9/10, bootc) │ (Satellite DHCP)   │
   │                       └────────────────────┘                     │
   └─────────────────────────────────────────────────────────────────┘
```

**Why two NICs?** The `satlab` segment is isolated so Satellite is the only
authoritative DHCP/TFTP/PXE server there — required for clean provisioning.
NIC1 on `default` gives the Satellite VM outbound NAT to the host and the
internet (for CDN sync and reaching AAP). Fleet nodes provisioned on `satlab`
reach the host (and AAP's forwarded ports) through host NAT/forwarding.

**Reaching AAP from the Satellite VM:** AAP routes use
`apps.127.0.0.1.nip.io`, which public DNS resolves to `127.0.0.1`. From inside
the Satellite VM that loopback is the *host's* forwarded AAP port, reached via
the `default` gateway (`192.168.122.1`). No extra DNS wiring is needed.

**Reaching the Satellite from AAP (the reverse direction):** on MicroShift,
`configure_coredns` maps `satellite.demo.lab` to the VM's real IP
(`192.168.122.20`) through a CoreDNS `hosts` block when the VM is running.
Full OpenShift retains its operator-managed DNS configuration; provide DNS
resolution for the Satellite hostname without modifying its Corefile.
The `apps.127.0.0.1.nip.io` wildcard cannot be used for the Satellite
— it resolves to `127.0.0.1`, which from inside a pod is the pod itself. On the
host, `satellite.demo.lab` is added to `/etc/hosts` so the UI is reachable at
`https://satellite.demo.lab`.

**Organization:** new installations use `Default Organization`. Existing
installations keep their organization and published content. The local AAP
demo profile discovers the organization owning the RHEL9/RHEL10 content views;
set `SAT_ORG` if more than one organization matches.

## Prerequisites

- KVM host: RHEL 9/Fedora with `libvirt`, `virt-install`, `qemu-kvm`; ~200 GB
  free in `/var/lib/libvirt/images`; the libvirt `default` network active
  (`sudo virsh -c qemu:///system net-list`). CRC may be running, but is not
  required for the Satellite lab itself.
- RHEL 9.x install media — **downloaded automatically** from the Red Hat CDN
  using the host's RHSM entitlement cert (`00a-fetch-rhel-iso.sh`), so no portal
  login or manual download is needed when the host is registered
  (`subscription-manager identity`). The default is the **DVD ISO**
  (`rhel-9.5-x86_64-dvd.iso`, ~10 GB), which carries the full BaseOS + AppStream
  package tree for a fully offline install. A CDN/network install is not used:
  the boot ISO carries no packages and the CDN does not publish a
  `.treeinfo`-bearing install tree, so Anaconda cannot set up a network software
  source. If the host is not registered, place the DVD ISO at
  `/var/lib/libvirt/images/rhel-9.5-x86_64-dvd.iso` and it will be used directly.
- Red Hat content access for the Satellite VM itself. The build registers the
  VM **post-boot over SSH** (`_stage_register` in `build-and-configure.sh`),
  not in the kickstart `%post` — a bad credential there hangs the install
  silently with no TTY to debug it. Registration tries, in order:
  1. an existing registration or working entitlement certs on the VM,
  2. `RHSM_ORG_ID` + `RHSM_ACTIVATION_KEY` from the aap-demo Vault,
  3. `RHSM_USERNAME` + `RHSM_PASSWORD` from the Vault,
  4. the **host's entitlement cert** copied to the VM (the same CDN cert-auth
     pattern `00a-fetch-rhel-iso.sh` uses), so a registered host is enough —
     no separate VM credentials are required.
  To store Vault credentials: `aap-demo fleet auth configure`.
- **Satellite Infrastructure + RHEL server subscriptions** in your Red Hat account.
  The build runs `aap-demo enable satellite-manifest` automatically: it creates/reuses
  an allocation, attaches one entitlement per missing category when each has a
  unique eligible pool, downloads `~/.aap-demo/satellite/manifest.zip`, and uploads
  it to Satellite. Existing attachments are reused. Missing or ambiguous pools
  stop the build with manual-selection guidance instead of exporting an empty
  manifest. An explicit `MANIFEST=/path/to/manifest.zip` bypasses generation and
  imports your supplied file. The addon requires the account's "View/Renew
  Subscription Information" permission; see
  [../addons/satellite-manifest/README.md](../addons/satellite-manifest/README.md).
- The Discovery boot image is cached after its first download at
  `/var/lib/libvirt/images/aap-demo-fdi-image-latest.tar`. On a recreated
  Satellite VM, the builder validates and seeds that copy before
  `satellite-installer` runs, avoiding another Internet download. A managed
  uninstall preserves this reusable installation-media cache, just as it
  preserves the RHEL ISO; unrelated libvirt images are also preserved.
- **Satellite 6.17+ recommended**: RHEL 10 content support and the image-mode
  (`bootc`) host plugin land there. The Satellite *server* itself still
  installs on RHEL 9 — RHEL 10 is in scope for managed content/hosts only.
  Adjust `SAT_VER` / repo names in the scripts if you run a different z-stream.

## Run order

**Fully automated (recommended):** `aap-demo create --full-demo --satellite`
runs the whole build via `build-and-configure.sh` (network → manifest →
provision → installer → content → sync plan → provisioning → integrations), then installs
the Satellite Demo content in AAP. Use the manual steps below to run stages
individually or to understand what the orchestrator does.

### General Satellite-provisioned VMs

Fleet remains the three QEMU demo nodes. A separate, opt-in set of general VMs
can be created through a Satellite compute resource. Set the node count to `3`
and provide an image already registered with the selected Satellite compute
resource:

```bash
SATELLITE_GENERAL_NODE_COUNT=3 \
SATELLITE_GENERAL_NODE_IMAGE=<satellite-image-name> \
aap-demo create --satellite
```

The local `KVM-Host` resource defaults to 2 vCPU, 4096 MiB RAM, and a 15 GiB
qcow2 disk on `satlab`; it creates persistent libvirt domains named
`aap-demo-general-node-01` through `-03`, which are visible in Virt-Manager.
For a cloud compute resource, set `SATELLITE_COMPUTE_RESOURCE` plus its
provider-specific `SATELLITE_GENERAL_NODE_COMPUTE_ATTRIBUTES`,
`SATELLITE_GENERAL_NODE_VOLUME`, and
`SATELLITE_GENERAL_NODE_INTERFACE` values. Those values must select the same
2 vCPU, 4096 MiB, and 15 GiB shape. The command refuses to substitute a
kickstart/PXE build when an image name is absent.

| Step | Where | Script |
|------|-------|--------|
| 0 | KVM host (root) | `00-network-setup.sh` |
| 0b | KVM host (root) | `00b-host-nfs-storage.sh` (host NFS export for `/var/lib/pulp`) |
| 1 | KVM host (root) | `01-provision-satellite-vm.sh` (renders `satellite-vm.ks`; runs 0b automatically) |
| 2 | Satellite VM (root) | `02-satellite-installer.sh` |
| 3 | Satellite VM (root) | `03-content-hammer.sh /root/manifest.zip` **or** `03-content-ansible.yml` |
| 3b | Satellite VM (root) | `09-content-sync-plan.sh` (sync plan, Flatpak, and Ansible collections) |
| 4 | Satellite VM (root) | `04-provisioning-kickstart.sh` |
| 5 | Satellite VM + build host | `05-bootc-image-mode.sh` (+ `Containerfile.bootc`, `bootc-register.service`) |
| 6 | Satellite VM (root) | `06-integrations.sh` (libvirt compute resource/profile, Capsule wiring, Ansible roles, rhc/Insights) |
| 6c | Satellite VM (root) | `11-settings-baseline.sh` (safe provisioning, facts, Remote Execution, and Lightspeed settings) |
| 6b | Satellite VM (root) | `07-fleet-activation-key.sh` (fleet activation key; run by `fleet satellite-register`) |
| 7 | AAP controller | `aap/` (dynamic inventory + Lightspeed notes) |

`build-and-configure.sh` orchestrates steps 0–6 from the host and is
idempotent — each stage is reconciled when already complete. It also trusts the
Satellite's Katello CA on the host (`_stage_ca_trust`, sourcing
`includes/satellite-ca-trust.sh`) so the UI and CLI tools stop warning about
the self-signed cert; skip with `AAP_DEMO_TRUST_CA=false`.

### Content synchronization plan and extra content

Every normal Satellite reconciliation creates or reuses the daily
`aap-demo-all-content` sync plan and attaches it to every content product in
the selected organization. Satellite sync plans are product-scoped, so this
covers every repository in each managed product. Existing plans retain their
scheduled time on a repeat run. Set `SATELLITE_SYNC_PLAN_NAME` or
`SATELLITE_SYNC_PLAN_INTERVAL` (`daily`, `weekly`, or `monthly`) before first
creation to choose a different retained plan.

### Capsule, compute, Ansible, and settings reconciliation

Each normal reconciliation owns the local `KVM-Host` compute resource and the
`aap-demo-general-small` compute profile. The profile specifies two vCPUs,
4096 MiB of RAM, a 15 GiB qcow2 disk in the `default` pool, and a virtio
interface on `satlab`. Satellite's `demo.lab` domain and `satlab` subnet are
also reconciled with the integrated `satellite.demo.lab` DNS, DHCP, TFTP, and
HTTPBoot Capsule. The same Capsule is added to the subnet's **Remote
Execution** Capsule selection without removing any other existing selections.

Satellite's built-in Ansible and Remote Execution proxy plugins are enabled,
and roles from Satellite's configured Ansible paths are synchronized into the
UI. The settings baseline keeps fact and discovery defaults in `Lab` / `Default
Organization`, uses private host addresses for Remote Execution, retains the
supported synchronized-content Kickstart templates, and enables automatic Red
Hat Inventory upload and Lightspeed recommendation synchronization. It does
not change authentication, email, root passwords, host ownership, automatic
discovery provisioning, or data-minimization policy.

Automatic Red Hat Inventory upload additionally requires the Satellite VM to
have a valid direct RHSM identity. The reconciliation uses the encrypted
`aap_demo.redhat.cdn_username` and `aap_demo.redhat.cdn_password` Vault values
first (then legacy RHSM values when present); certificate-only CDN access can
maintain packages but cannot enable Cloud Connector. Invalid credentials stop
the connector stage with an authentication error rather than silently claiming
that inventory reports are uploading.

The local compute resource/profile is the only automatic provider profile.
Cloud and VMware resources require a separate, explicitly configured provider
profile and preflight; aap-demo does not infer credentials or create billable
resources from platform detection.

The same stage creates a `RHEL_Flatpak` remote for
`https://flatpaks.redhat.io/rhel/`, scans it, mirrors every discovered remote
repository into the dedicated `aap-demo-flatpak` product, and synchronizes it.
It also creates the `Red Hat Ansible Collections` repository in the
`aap-demo-ansible-collections` product and syncs all collections from
`console.redhat.com`. Satellite needs the Automation Hub offline token for the
collection remote; aap-demo transfers the Vault-backed `ah_offline_token` only
to configure the guest and removes the temporary guest file immediately.
Its first collection catalog import is serialized by default
(`SATELLITE_COLLECTIONS_DOWNLOAD_CONCURRENCY=1`) to avoid concurrent
offline-token exchanges starving a Pulp worker. Increase it only after a
successful initial sync; Satellite accepts values from `1` through `19`.
Red Hat Flatpak mirroring first reuses the Vault-backed CDN/Customer Portal
pair (`aap_demo.redhat.cdn_username` and `aap_demo.redhat.cdn_password`) that
the installer already collects. If Red Hat rejects that pair for the Flatpak
registry scope, the full Satellite profile securely collects a separately
Vault-backed Registry Service Account pair
(`aap_demo.redhat.registry_username` and `aap_demo.redhat.registry_token`) and
transfers it only in the temporary guest file. Create that fallback pair from the
[Registry Service Accounts page](https://access.redhat.com/RegistryAuthentication#creating-registry-service-accounts-6),
then provide the displayed service-account username and token/password when
the installer asks.
Set `SATELLITE_FLATPAK_ENABLED=false` or `SATELLITE_COLLECTIONS_ENABLED=false`
only when deliberately excluding those content types.

The installer also creates two owned Installation Media entries from the local
published Kickstart trees: `aap-demo RHEL 9.5 Kickstart` and `aap-demo RHEL
10.0 Kickstart`. They use the Satellite Pulp URLs, never a CDN or generic
Internet mirror, and are reconciled on every run.

### OpenSCAP baseline

The installer enables the OpenSCAP proxy plugin and loads Satellite's default
SCAP Security Guide content. That makes **Hosts → Compliance → SCAP Content**
useful immediately. It deliberately does not assign a compliance policy or
enforce a profile on hosts: the Satellite-provided default content matches the
Satellite server's RHEL minor version, while a policy needs a profile verified
for the target host version. Fleet registration refreshes package and enabled
repository facts so Errata reporting can populate after the Satellite receives
the update.

The manifest is an exception to stage skipping: unless you supply `MANIFEST`,
it is refreshed and imported even when a cached file or configured content
already exists. For an installed server, `aap-demo create --full-demo --satellite`
preserves its installer settings, maintains Satellite, and refreshes/imports the
manifest without rebuilding the VM or syncing repositories. Manifest import
selects the sole organization with repositories, or the sole organization on
a new server. Set `SAT_ORG` when multiple content organizations exist.
To do just that step independently:

```bash
bash satellite-lab/build-and-configure.sh --manifest-only
```

### SSH identity after an approved rebuild

Rebuilding the VM changes its SSH host keys. The builder rejects changed keys
and stops with trust-verification guidance rather than waiting for the installation
timeout or modifying saved trust. Verify the replacement VM's fingerprint through
an independent channel, preserve the existing known-hosts file, and explicitly
update only the verified VM's entry before retrying. Do not disable host-key
checking or remove unrelated entries.

### Existing installations and maintenance

The builder checks the installed Satellite RPM over SSH, not just VM existence
or whether Foreman is running. It starts services on an installed server and
never reapplies initial organization, administrator, or network settings there.
A VM without the Satellite RPM continues through installation. An incomplete
installation with the RPM already present stops with repair guidance.

Existing and newly installed servers receive package-update checks. Changes use
`satellite-maintain update check/run`, not an unrestricted Satellite package
upgrade. Entitled adjacent minor releases are discovered from Red Hat's
repository list. Only the maintenance wrapper and its Ruby gem are staged with
the Foreman package protector disabled so both packages can advance together.
The wrapper's target is
verified, and `satellite-maintain upgrade check/run` performs each supported
minor upgrade in sequence. Unavailable paths and failed checks stop the build;
there are no skipped checks or automatic OS-major migrations.

On an unregistered guest using entitlement certificates, native RHSM can report
that several repositories were enabled while retaining only the last one. If a
native upgrade fails with only its target maintenance repository enabled, the
wrapper reports this condition, enables BaseOS, AppStream, Satellite, and
maintenance repositories one at a time, verifies their actual enabled state, and
repeats native checks before one resume attempt. Registered guests and other
repository states do not take this recovery path. Repair or retry failures stop
the build; no vendor files, upgrade journal entries, or package checks are changed.
Host-entitlement fallback keeps copied private keys root-readable only (mode
`0600`); it does not make private keys world-readable alongside public certificates.

Satellite's native upgrade checks require the latest supported RHEL minor
release and may reject an RHSM minor-release pin. The builder does not change
an existing pin; resolve a rejected pin and any repository dependency conflicts
before retrying. Do not bypass the native checks or skip broken packages.

Before changing maintenance, the builder creates one managed libvirt
checkpoint of the `satellite` VM. This avoids a second in-guest Pulp archive,
which can consume several GiB and fill a local lab disk. The checkpoint covers
the entire maintenance run, including supported adjacent upgrades. It is
removed after a successful run and retained on failure for a deliberate manual
rollback. A subsequent retry replaces only the prior aap-demo checkpoint; it
never changes administrator-created libvirt snapshots.

The native `satellite-maintain` checks remain the authority for safe package
changes. aap-demo does not wait on every Foreman task itself: Satellite keeps
long-lived scheduler tasks, such as Red Hat Lightspeed's scheduled sync, in a
running state indefinitely. Failed upgrades do not trigger an automatic
rollback.

After rebuilding the OS disk, do not mount a previous installation's retained
Pulp content over the new database. Use separate per-installation NFS exports.
The managed `aap-demo create --satellite` flow reserves a new
`/var/lib/satlab/instances/satellite-<install-id>/pulp` export before creating
a missing VM. It refuses an existing export while the managed domain is absent;
retain and inspect that data rather than pointing a new database at it.
For an approved storage migration, stop native services, copy only the current
installation's content and backups while preserving ownership, and verify
checksums before changing mounts. Keep the original data and mount configuration
until native health and HTTPS checks pass. Persist mounts in `fstab`; native
Pulp units already use `RequiresMountsFor=/var/lib/pulp`. An NFS mount must retain
Pulp's SELinux context; separate mounts with different contexts need
`nosharecache`. Do not disable SELinux to make a migration succeed.

Maintenance can stop services and reboot the Satellite VM. The builder waits
for a changed boot ID, reconnects, and reruns reconciliation. Run the full demo
only when this downtime is acceptable. A current server performs discovery and
health checks without taking another backup or rerunning the initial installer.
`--manifest-only` never runs maintenance.

The dashboard and `aap-demo status` list a running Satellite VM under Routes even
when a supplied manifest means the `satellite-manifest` addon is disabled.
This is an external VM link, not an OpenShift Route resource. HTTP errors leave
the link pending rather than reporting the application as ready.

### Hosted Red Hat Lightspeed and RHC

Red Hat Lightspeed, formerly Insights, provides hosted inventory and system
recommendations. It is separate from the Ansible Lightspeed chatbot. Register
Satellite itself directly with Red Hat; register Fleet nodes through Satellite
using the correct organization and content activation key.

**Verified handoff, 2026-11-17:** Satellite 6.18.11 has a valid Red Hat RHSM
identity. The owner-verified manifest was imported into `Default Organization`
and three subscriptions are listed. Both Pulp and backup paths are mounted
over NFS. No content repositories or activation keys have been prepared.
The three Fleet nodes remain unregistered.

**Connector repair:** Invocation 1 failed because the native remote-execution
proxy could not SSH to Satellite itself. After preserving authorized keys and
authorizing only the native proxy public key, invocation 2 and its native task
succeeded. `rhcd` is enabled and active, its worker configuration exists, and
the native connector identity is populated. Hosted inventory acceptance,
recommendation synchronization, and Fleet reporting remain unverified.

Use the scoped reconciliation without repeating maintenance:

```bash
bash satellite-lab/build-and-configure.sh --cloud-connector-only
```

It reuses a healthy connector without rotating the service token; otherwise it
waits for the exact native task and fails on unsuccessful completion or missing
postconditions. Inspect native job output privately. The stored Vault
organization ID also needs review; registration
succeeded using the sole organization returned by authenticated discovery, not
the incorrect stored value. Keep account identifiers and credentials private.

Resume with [RM-04D](../docs/ROADMAP.md#rm-04d-hosted-satellite-lightspeed-and-rhc).
Verify supported Satellite-proxied reporting before invoking `rhc connect` on
managed nodes. Do not delete Insights registration markers or ignore client
failures to obtain a successful-looking registration result.

For travel, use the [shutdown and resume guide](../docs/guides/older-command.md#pause-for-travel-without-deleting-data).
Preserve the current per-installation NFS data, pre-registration RHSM snapshot,
and maintenance backups. Do not mount retained content from another installation
over the current database.

### Shared lab SSH access

Fleet creation/start and `aap-demo wire` reconcile the existing Fleet private
key onto managed running nodes as `~/.ssh/aap-demo-shared-key`. RHEL Fleet and
Satellite accounts `admin` and `root` share this identity; CRC uses its supported
`core` account with `sudo`, without enabling root SSH or adding CoreOS users.
Existing private identities and unmanaged authorized keys are preserved.

The generated lab aliases select forwarded Fleet ports and use trust on first
use with a persistent known-host store; unexpected host-key changes are rejected.
CRC SSH traverses
a running Fleet QEMU node to reach the host's loopback-only CRC forward.
CoreOS uses a separate `authorized_keys.d/aap-demo` file when its SSH key helper
is present, leaving the MCO-owned Ignition key file untouched.

This is deliberately insecure **local-demo-only** access: compromise of one
shared key grants access across the lab. Private copies have mode 600 and cross
SSH stdin, never process arguments. The controlling host's accounts, authorized
keys, and global SSH policy are not changed by this reconciliation. Stopped
Fleet/Satellite nodes are reconciled after they are started.

On firewalld hosts, reconciliation permits the Satellite VM's source address
to reach only the running Fleet SSH forwards on the host gateway. These
source/destination/port-specific rules are applied to the Satellite-facing zone,
both persistently and at runtime, without reloading the host firewall.

## Registering Fleet nodes

With the lab built, register running Fleet nodes to the Satellite so they pull
content from the local Pulp and appear in the Satellite inventory:

```bash
aap-demo fleet satellite-register
```

This runs `07-fleet-activation-key.sh` on the Satellite (creating a
`fleet-rhel9` activation key bound to the content view that has repositories),
then per node trusts the CA, registers with the activation key, and registers
Insights. See [../addons/fleet/README.md](../addons/fleet/README.md).

## Notes & caveats

- **Minimal VM disk + host NFS for Pulp.** The Satellite VM uses a small 40 GB
  OS disk; the bulky Pulp content (`/var/lib/pulp`) is mounted from the host
  over NFS (`00b-host-nfs-storage.sh` configures the export, firewalld when
  active, and the SELinux `virt_use_nfs`/`nfs_export_all_rw` booleans when
  Enforcing). Skip the NFS mount with `SATLAB_SKIP_NFS=1` to keep Pulp local
  (then give the VM a larger disk).
- **`on_demand` policy** is set globally *before* any repo is enabled
  (`default_redhat_download_policy`), so no multi-hour full syncs. First client
  fetch of a package is proxied and cached by Pulp (small first-hit latency).
  Kickstart trees and container images always sync in full — that is expected
  and is why we only pull BaseOS+AppStream kickstart trees for 9.5/10.0.
- **Simple Content Access** is assumed (default for current manifests);
  activation keys bind the content view and lifecycle environment without
  `--auto-attach`, which newer Hammer versions no longer accept. Key preparation
  emits only the key name on standard output, and failures stop registration.
- Repo-set names occasionally change between CDN releases. If an enable fails,
  find the exact string: `hammer repository-set list --search "RHEL 10"`.
- Firewall: `02-satellite-installer.sh` opens the demo-required ports
  (53, 67/69 udp, 80, 443, 8000, 8140, 9090). Tighten as needed.

## Teardown

```bash
sudo virsh -c qemu:///system destroy satellite 2>/dev/null
sudo virsh -c qemu:///system undefine satellite --remove-all-storage
sudo virsh -c qemu:///system net-destroy satlab 2>/dev/null
sudo virsh -c qemu:///system net-undefine satlab
sudo rm -f /etc/sysctl.d/99-satlab-forward.conf
```
