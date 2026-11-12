# Satellite 6 Fast Demo Lab on a Single KVM/libvirt Host

Everything in this folder is ready to run. The fully automatic path is
`aap-demo create --full-demo --satellite` (or `sudo satellite-lab/build-and-configure.sh`
for just the lab), which downloads the RHEL ISO, provisions the VM, installs
Satellite, and configures content with no manual steps when the host is
registered with RHSM. Adjust the variables at the top of each script
(passwords, RHSM credentials, manifest path, versions) only if you run the
stages individually.

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

**Reaching the Satellite from AAP (the reverse direction):** the cluster's
CoreDNS maps `satellite.demo.lab` to the VM's real IP (`192.168.122.20`) via a
`hosts` block, applied by `configure_coredns` whenever the Satellite VM is
running. This is what lets the AAP controller pods run the Satellite demo
content. The `apps.127.0.0.1.nip.io` wildcard cannot be used for the Satellite
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
- **Satellite 6.17+ recommended**: RHEL 10 content support and the image-mode
  (`bootc`) host plugin land there. The Satellite *server* itself still
  installs on RHEL 9 — RHEL 10 is in scope for managed content/hosts only.
  Adjust `SAT_VER` / repo names in the scripts if you run a different z-stream.

## Run order

**Fully automated (recommended):** `aap-demo create --full-demo --satellite`
runs the whole build via `build-and-configure.sh` (network → manifest →
provision → installer → content → provisioning → integrations), then installs
the Satellite Demo content in AAP. Use the manual steps below to run stages
individually or to understand what the orchestrator does.

| Step | Where | Script |
|------|-------|--------|
| 0 | KVM host (root) | `00-network-setup.sh` |
| 0b | KVM host (root) | `00b-host-nfs-storage.sh` (host NFS export for `/var/lib/pulp`) |
| 1 | KVM host (root) | `01-provision-satellite-vm.sh` (renders `satellite-vm.ks`; runs 0b automatically) |
| 2 | Satellite VM (root) | `02-satellite-installer.sh` |
| 3 | Satellite VM (root) | `03-content-hammer.sh /root/manifest.zip` **or** `03-content-ansible.yml` |
| 4 | Satellite VM (root) | `04-provisioning-kickstart.sh` |
| 5 | Satellite VM + build host | `05-bootc-image-mode.sh` (+ `Containerfile.bootc`, `bootc-register.service`) |
| 6 | Satellite VM (root) | `06-integrations.sh` (libvirt compute resource, rhc/Insights) |
| 6b | Satellite VM (root) | `07-fleet-activation-key.sh` (fleet activation key; run by `fleet satellite-register`) |
| 7 | AAP controller | `aap/` (dynamic inventory + Lightspeed notes) |

`build-and-configure.sh` orchestrates steps 0–6 from the host and is
idempotent — each stage is skipped when already complete. It also trusts the
Satellite's Katello CA on the host (`_stage_ca_trust`, sourcing
`includes/satellite-ca-trust.sh`) so the UI and CLI tools stop warning about
the self-signed cert; skip with `AAP_DEMO_TRUST_CA=false`.

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

### Existing installations and maintenance

The builder checks the installed Satellite RPM over SSH, not just VM existence
or whether Foreman is running. It starts services on an installed server and
never reapplies initial organization, administrator, or network settings there.
A VM without the Satellite RPM continues through installation. An incomplete
installation with the RPM already present stops with repair guidance.

Existing and newly installed servers receive package-update checks. Changes use
`satellite-maintain update check/run`, not an unrestricted Satellite package
upgrade. Entitled adjacent minor releases are discovered from Red Hat's
repository list. The corresponding maintenance tool is staged, its target is
verified, and `satellite-maintain upgrade check/run` performs each supported
minor upgrade in sequence. Unavailable paths and failed checks stop the build;
there are no skipped checks or automatic OS-major migrations.

Before each changing maintenance step, a full offline backup, including Pulp
content, is stored under `/var/backup/satellite/pre-<release>.*`. Override the
parent with `SATELLITE_BACKUP_DIR`, preferably pointing at a separate mounted
backup volume with enough capacity. Failed backups prevent package changes.
Backups are retained for manual restoration; failed upgrades do not trigger
an automatic rollback.

Maintenance can stop services and reboot the Satellite VM. The builder waits
for a changed boot ID, reconnects, and reruns reconciliation. Run the full demo
only when this downtime is acceptable. A current server performs discovery and
health checks without taking another backup or rerunning the initial installer.
`--manifest-only` never runs maintenance.

### Shared lab SSH access

Fleet creation/start and `aap-demo wire` reconcile the existing Fleet private
key onto managed running nodes as `~/.ssh/aap-demo-shared-key`. RHEL Fleet and
Satellite accounts `admin` and `root` share this identity; CRC uses its supported
`core` account with `sudo`, without enabling root SSH or adding CoreOS users.
Existing private identities and unmanaged authorized keys are preserved.

The generated lab aliases select forwarded Fleet ports and use
`StrictHostKeyChecking no` with a disposable known-host store. CRC SSH traverses
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
  `--auto-attach true` on activation keys is kept for compatibility.
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
