---
type: Guide
title: Local Gitea VM
description: Run a Fedora 45 Git server outside CRC with repositories on host NFS.
---

# Local Gitea VM

Gitea runs in its own Fedora 45 libvirt VM, not in CRC. Use it as a private
local Git source while rebuilding the OpenShift lab. This addon installs
the Git server, not a CI runner, OpenFlake, or the complete Lightwell pipeline.

## Install or resume

Use the Bash command from this checkout:

```bash
aap-demo --gittea
# Canonical spelling and equivalent addon command:
aap-demo --gitea
aap-demo enable gitea
```

In the dashboard, choose **Add-ons > Infrastructure > Local Gitea VM >
Install / start VM**. After installation, **Services and Fleet > Open Gitea**
opens the server. A configured badge is not a continuous runtime health probe.

To include the VM in a full-demo build:

```bash
aap-demo create --full-demo --sno --satellite --gitea
```

Gitea starts before CRC provisioning. Adding `--lightwell` selects the managed
Lightwell profile: it prepares the owned Gitea/OpenFlake services, dedicated
application host, AAP inventory/credentials, and AO workflow after the core
demo is ready. It still validates ownership, TLS, SSH, and native AAP/AO
bindings; it does not launch jobs. Reconciliation may briefly restart Gitea;
avoid enabling it during active pushes.

## Prerequisites

- Linux x86_64 with working KVM and access to system libvirt.
- `virsh`, `virt-install`, `qemu-img`, `genisoimage`, OpenSSH clients, `curl`,
  Python 3, and noninteractive `sudo` for the scoped host setup.
- The existing `default` libvirt NAT network and host `nfs-server` are active.
  The addon does not replace shared networks, exports, or firewall policy.
- An available encrypted aap-demo Vault. The existing Fleet SSH identity is
  reused; its private key is materialized only for the operation.
- At least 2 GiB spare RAM, two virtual CPUs, OS-disk capacity and space for
  repository growth. The OS disk is a 40 GiB thin-provisioned image.

The Fedora Cloud 45-1.4 image and Gitea 28.4.0 binary have fixed checksums.
Artifacts are downloaded over verified HTTPS. Fedora package signatures remain
enabled, and the guest retains enforcing SELinux.

## Storage, identity and backups

- VM: `aap-demo-gitea`, protected by its recorded UUID, NIC MAC, network,
  description and exact disk path. An unrelated VM with that name is refused.
- OS disk and seed: `/var/lib/libvirt/images/aap-demo-gitea/<UUID>.*`.
- Host NFS export: `/var/lib/aap-demo-gitea/instances/<UUID>`.
  The guest mounts it at `/srv/gitea` with hard NFSv4, `nosuid` and `nodev`.
  Repositories live under `repositories`; application file data under `data`.
- The export permits only the VM's reserved DHCP address, uses `root_squash`,
  and is owned by the guest's unprivileged Git UID/GID. There is no world-writable
  export or root ownership override.
- SQLite stays at `/var/lib/gitea/data/gitea.db` on the VM's OS disk. Do not put
  the live database on NFS. Consistent SQLite snapshots are created locally and
  copied atomically to `/srv/gitea/backups/gitea.db` hourly and on service stop.
  These are database snapshots, not a tested full disaster-recovery procedure.
- Public state, verified SSH host key and CA are retained under
  `~/.local/share/aap-demo/gitea`, outside disposable `~/.aap-demo` state.
  `XDG_DATA_HOME` and `AAP_DEMO_GITEA_DIR` can relocate that directory; keep it
  outside directories removed by lab maintenance.
- Administrator username: `aap-demo`. Its generated password is stored only
  in encrypted Vault at `aap_demo.gitea.admin_password`, never in service-link
  state, process arguments or dashboard output. Interactive
  `aap-demo status --show-secrets` displays it when CRC status is available.

The guest has a dedicated local CA. Its public certificate is retrieved through
host-key-verified SSH and imported into host system/existing browser trust
stores. `AAP_DEMO_TRUST_CA=false` skips host imports; explicitly use the retained
`ca.crt` instead. Do not disable Git, HTTPS or SSH verification.

## Use as a Git source

Create a repository after signing in, then copy its HTTPS clone URL. Supply
credentials interactively or through a scoped credential manager, not in URLs.
The installed example `aap-demo/aap-demo-local-source` is private and contains an
original, harmless `hello.yml` playbook; installation itself does not create it.
It was created during live clone/push qualification.

For AAP, use a Source Control credential and the real clone URL. Trust this
Gitea CA in the appropriate project/execution environment through supported
AAP CA configuration. Do not set `GIT_SSL_NO_VERIFY`. Read-only authenticated
HTTPS and native Git access were verified from the current AAP execution
environment using an explicitly supplied CA; no AAP project or credential was
silently created by the addon.

## Stop safely

```bash
aap-demo disable gitea
# Resume the same VM and repositories:
aap-demo enable gitea
```

The dashboard **Stop VM (retain data)** button does the same thing after
confirmation. Shutdown is graceful, with a timeout that fails rather than
force-stopping. The disk, export, DHCP reservation, CA and credentials remain.
There is deliberately no `--purge-data` operation.

CRC stop/destroy and default managed uninstall leave this independent service
and its data in place. `maintenance uninstall --reconfigure --apply` is refused
while the Gitea VM exists, because stripping shared Vault entries would destroy
its retained administrator and SSH credentials.

If provisioning is interrupted, rerun enable. A changed host key, CA, UID/GID,
unowned VM, conflicting reservation, failed mount or failed native operation
stops reconciliation explicitly. Never overlay retained repositories onto a
fresh database as a substitute for a planned restore.

## Validation

```bash
python3 test/test-gitea.py
python3 test/test-dashboard.py
node test/test-dashboard-routes.js
bash test/test-full-demo.sh
bash test/test-maintenance.sh
```

Live qualification on 2026-11-18 verified Fedora 45, enforcing SELinux, the real
NFSv4 mount, database backup, repeated enable, private Git push/clone, and
dashboard stop/start with unchanged VM, repository commit, CA and credentials.
CRC and Satellite were left running. No CI runner, demo PR merge, production
deployment, full lab uninstall, or GitHub push was performed.
