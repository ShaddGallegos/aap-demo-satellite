# Satellite Manifest Addon

Attaches eligible subscriptions, then creates and downloads a Red Hat Satellite subscription manifest programmatically
via the RHSM management API, so the [satellite-lab](../../satellite-lab/README.md)
content stage (`03-content-hammer.sh`) does not need a manual portal download.

## Usage

```bash
# Create/reuse the allocation, attach subscriptions, and download the manifest
aap-demo enable satellite-manifest

# Override the allocation name or Satellite version
MANIFEST_NAME=my-lab MANIFEST_SAT_VERSION=sat-6.17 aap-demo enable satellite-manifest
```

The manifest is written to `~/.aap-demo/satellite/manifest.zip` (mode 600).

## How it works

The addon reuses the credential Vault's Red Hat offline token (the same
`rhsm-api` exchange the fleet addon uses for image downloads) and drives the
RHSM management API:

1. **Find-or-create** the subscription allocation (`aap-demo-satellite` by
   default) at the requested Satellite version.
2. **Check attached subscriptions** and list available pools for the allocation.
3. **Attach one entitlement per missing content category**, only when each
   missing category has exactly one eligible pool, then verify the attachments.
4. **Trigger an export job** for the allocation.
5. **Poll** the export job until the manifest is ready.
6. **Download** the signed `manifest.zip`, replacing the previous file only
   after a successful download.

Selection is deliberately conservative: it recognizes subscription names beginning
with `Red Hat Satellite Infrastructure Subscription`, `Red Hat Enterprise Linux Server`,
or `Red Hat Enterprise Linux for Virtual Datacenters`. RHEL names must be the base
name or use the `Premium`, `Standard`, or `Self-support` tier, optionally followed
by parenthesized details; extensions such as Extended Life Cycle Support are not selected.
Pools must have at least
one available entitlement, or unlimited availability (`-1`). Existing positive
attachments for these categories are retained without adding more.

If a missing category has no eligible pool or multiple candidates, the addon
stops before attaching anything from that plan or exporting a manifest. Select
the desired subscriptions manually under Red Hat Console → Subscriptions →
Subscription Allocations → `<allocation-name>` → Add subscriptions, then rerun.
For unrecognized subscription names, export a suitable manifest manually and
supply it to the builder with `MANIFEST=/path/to/manifest.zip`. If an API request
fails after an earlier attachment succeeds, that attachment remains and is reused
on the next run; no existing subscriptions are removed.

One entitlement per category is the content-bootstrap minimum, not a determination
of the subscriptions or quantities required to license your hosts.

## Prerequisites

- A Red Hat offline token in the credential Vault (`aap-demo fleet auth` sets
  this up; the same token is reused).
- Existing Satellite Infrastructure and RHEL server subscriptions with available
  quantity, or matching subscriptions already attached to the allocation.
  The addon does not purchase subscriptions or create entitlements.
- The Red Hat account must hold the **"View/Renew Subscription Information"**
  permission. Without it the RHSM allocations API returns `401`/`403` and the
  addon stops with guidance. Grant it under console.redhat.com → Settings →
  User Access → Users → your user → Subscription Management role.

## Use with the Satellite lab

`aap-demo create --full-demo --satellite` already checks Fleet credentials and
starts secure credential setup when needed in an interactive terminal. It then
runs this addon, copies the refreshed manifest to the Satellite VM, and imports
it into `Default Organization`. If the VM already exists, full-demo still
refreshes and imports its manifest, without rerunning the lab's repository
setup or synchronization. `QUIET=true` requires credentials to be configured
beforehand.

To refresh and import only the manifest for an existing lab:

```bash
bash satellite-lab/build-and-configure.sh --manifest-only
```

An explicit `MANIFEST=/path/to/manifest.zip` uses that file instead of generating
one. Without `MANIFEST`, an existing cached file is always refreshed.

For manual content setup:

```bash
scp ~/.aap-demo/satellite/manifest.zip root@192.168.122.20:/root/manifest.zip
ssh root@192.168.122.20 'cd satellite-lab && ./03-content-hammer.sh /root/manifest.zip'
```

## Notes

- Re-running the addon reuses an existing allocation with the same name and
  re-exports the manifest, so it is safe to run repeatedly.
- The manifest contains subscription credentials; the file is created with
  mode 600 and should be treated as sensitive.
