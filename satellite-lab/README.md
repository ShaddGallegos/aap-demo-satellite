# Satellite 6 Fast Demo Lab on a Single KVM/libvirt Host

Everything in this folder is ready to run. Adjust the variables at the top of each
script (passwords, RHSM credentials, manifest path, versions) before executing.

## Architecture

> **Adapted for CRC user-mode networking.** This host runs CRC with the
> MicroShift preset, which uses QEMU user-mode networking + vsock — there is no
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

## Prerequisites

- KVM host: RHEL 9/Fedora with `libvirt`, `virt-install`, `qemu-kvm`; ~200 GB
  free in `/var/lib/libvirt/images`; the libvirt `default` network active
  (`sudo virsh -c qemu:///system net-list`). CRC may be running, but is not
  required for the Satellite lab itself.
- RHEL 9.x DVD ISO at `/var/lib/libvirt/images/rhel-9.5-x86_64-dvd.iso`
  (edit path in `01-provision-satellite-vm.sh`).
- Red Hat account credentials (or an activation key) for the Satellite VM itself.
  This host's aap-demo Vault already holds `RHSM_ORG_ID` + `RHSM_ACTIVATION_KEY`;
  export them before step 1:
  `RHSM_ORG=$(ansible-vault view --vault-password-file ~/.ansible/conf/.vaultpass.txt ~/.ansible/conf/env.yml | awk '/RHSM_ORG_ID:/ {print $2}')`
- A **manifest** with Satellite infrastructure + RHEL entitlements. Generate it
  programmatically with the aap-demo addon (writes `~/.aap-demo/satellite/manifest.zip`):
  `aap-demo enable satellite-manifest` — then `scp` it to the Satellite VM as
  `/root/manifest.zip`. Or download manually from access.redhat.com →
  Subscription Allocations. The addon requires the account's "View/Renew
  Subscription Information" permission; see
  [../addons/satellite-manifest/README.md](../addons/satellite-manifest/README.md).
- **Satellite 6.17+ recommended**: RHEL 10 content support and the image-mode
  (`bootc`) host plugin land there. The Satellite *server* itself still
  installs on RHEL 9 — RHEL 10 is in scope for managed content/hosts only.
  Adjust `SAT_VER` / repo names in the scripts if you run a different z-stream.

## Run order

| Step | Where | Script |
|------|-------|--------|
| 0 | KVM host (root) | `00-network-setup.sh` |
| 1 | KVM host (root) | `01-provision-satellite-vm.sh` (renders `satellite-vm.ks`) |
| 2 | Satellite VM (root) | `02-satellite-installer.sh` |
| 3 | Satellite VM (root) | `03-content-hammer.sh /root/manifest.zip` **or** `03-content-ansible.yml` |
| 4 | Satellite VM (root) | `04-provisioning-kickstart.sh` |
| 5 | Satellite VM + build host | `05-bootc-image-mode.sh` (+ `Containerfile.bootc`, `bootc-register.service`) |
| 6 | Satellite VM (root) | `06-integrations.sh` (libvirt compute resource, rhc/Insights) |
| 7 | AAP controller | `aap/` (dynamic inventory + Lightspeed notes) |

## Notes & caveats

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
