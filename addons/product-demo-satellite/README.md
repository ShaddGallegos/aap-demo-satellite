# Product Demo - Satellite

Red Hat Satellite integration demonstrations from the
[Ansible Product Demos](https://github.com/ansible/product-demos) collection.

## What it Creates

Job templates for Satellite automation scenarios:

- **SATELLITE | Publish Content View Version** — publish content views
- **SATELLITE | Promote Content View Version** — promote through lifecycle environments
- **LINUX | Register with Satellite** — register systems to Satellite
- **LINUX | Compliance Scan with Satellite** — OpenSCAP compliance scanning
- **SETUP | Satellite** — bootstrap content views, lifecycle environments, and activation keys
- **Patch Dev** — workflow tying inventory sync, publishing, and patching together

The local Satellite lab is wired automatically. An external Satellite retains the
upstream setup behavior and requires its own compatible content.

## Usage

```bash
# Install Satellite demos (also installs base if needed)
aap-demo enable product-demo-satellite

# Remove Satellite demos
aap-demo disable product-demo-satellite
```

When installing all domains at once, Satellite is excluded by default. Add it when you have a server:

```bash
PRODUCT_DEMOS_DOMAINS="linux windows network cloud openshift satellite" aap-demo enable product-demos
```

Or install Satellite separately:

```bash
aap-demo enable product-demo-satellite
```

## Automatic local-lab integration

For `https://satellite.demo.lab` (or `SATELLITE_LAB_HOST`), enable and full-demo:

1. Discover the unique organization containing published RHEL9/RHEL10 content.
   `SAT_ORG` selects an organization explicitly when more than one matches.
2. Install APD resources without launching upstream's hardcoded RHEL7/RHEL8 setup
   or its legacy tailoring-file import.
3. Configure **SETUP | Satellite** to promote the existing published versions
   through DEV → TEST → PROD and create matching activation keys. It does not
   create legacy repositories, resynchronize content, or publish new versions.
4. Wire both Satellite credentials from the Vault, update content-view and
   lifecycle surveys, and adapt **Patch Dev** to RHEL9 / `env_DEV`.
5. Configure the empty APD machine credential with the Fleet SSH key. An existing
   custom key is not overwritten; configure that credential explicitly if needed.
6. Register running RHEL9 Fleet nodes in the selected organization and DEV.
   **This migrates a direct Red Hat registration to Satellite** after verifying
   the Satellite CA and downloading its consumer package. A registration in a
   different Satellite organization is rejected rather than silently moved.
7. Sync Satellite inventory and preserve the host-gateway IP and forwarded SSH
   port for each QEMU node, rather than trying to reach its private NAT address.

The local registration template supports RHEL9/RHEL10 with the lab activation
keys. The upstream OpenSCAP demo is not certified for these versions; this
profile does not install RHEL7/RHEL8 tailoring files or claim compliance readiness.

After enable succeeds, `aap-demo wire` reconciles the credentials, playbook
overlays, Fleet registration, inventory, and workflow targets again. The local
overlays are reapplied when enabling or wiring; rerun either after a manual SCM
project sync removes an overlay. Patching, approvals, and reboots are never
launched by wiring.

Details and the integration boundaries are also in the
[add-ons guide](../../docs/guides/addons.md#satellite-subscriptions-in-the-full-demo).

## Prerequisites

- AAP deployed via `aap-demo deploy`
- Product demos base addon (installed automatically)
- A reachable **Red Hat Satellite** (or Foreman) server with API access
- Subscription manifest imported on Satellite (required for `SETUP | Satellite`)

Don't have a Satellite server? The [satellite-lab](../../satellite-lab/README.md)
folder builds one on this KVM host, and the
[satellite-manifest](../satellite-manifest/README.md) addon
(`aap-demo enable satellite-manifest`) generates the required subscription
manifest programmatically.

## Updating Satellite credentials

For an external Satellite, update **both** credentials in the **Ansible Product Demos (APD)** organization.
They start with upstream placeholders and must match your environment before setup or demo jobs
will run.

### AAP UI

1. Log into AAP and open **Ansible Product Demos (APD)** → **Credentials**.
2. Edit **Satellite Credential** (type **Satellite Collection**):
   - **Satellite Hostname** — base URL, e.g. `https://satellite.example.com`
   - **Satellite Username** — API user (often `admin` or a dedicated service account)
   - **Satellite Password** — password or API token for that user
3. Edit **Satellite Inventory** (type **Red Hat Satellite 6**):
   - **Host** — same Satellite URL as above
   - **Username** / **Password** — same API credentials (used for dynamic inventory sync)
4. Save both credentials.

The **Satellite Collection** credential type injects `SATELLITE_SERVER`, `SATELLITE_USERNAME`,
and `SATELLITE_PASSWORD` into job pods. Demo playbooks use those environment variables to call
the Satellite API.

### Controller API (optional)

Look up credential IDs, then patch inputs:

```bash
NAMESPACE=aap-operator
AAP_ROUTE=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}')
AAP_PASSWORD=$(kubectl get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
AAP_API="https://${AAP_ROUTE}/api/controller/v2"

# Find Satellite Credential in the APD org
CRED_ID=$(curl -sk -u "admin:${AAP_PASSWORD}" \
  "${AAP_API}/credentials/?name=Satellite+Credential&organization=2" \
  | jq -r '.results[0].id')

curl -sk -u "admin:${AAP_PASSWORD}" \
  -X PATCH \
  -H "Content-Type: application/json" \
  -d '{
    "inputs": {
      "host": "https://satellite.example.com",
      "username": "admin",
      "password": "REPLACEME"  # pragma: allowlist secret
    }
  }' \
  "${AAP_API}/credentials/${CRED_ID}/"
```

Repeat for **Satellite Inventory** (same `inputs` shape; type is **Red Hat Satellite 6**).

## Re-run Satellite setup

For an external Satellite, domain install (`setup_demo.yml` with `demo=satellite`) creates job templates and then launches
**SETUP | Satellite** automatically. That job fails until credentials point at a real server —
the demo templates are still created.

After updating credentials:

1. **Templates** → **SETUP | Satellite** → **Launch**.
2. Wait for the job to finish. It creates RHEL7/RHEL8 content views, lifecycle environments
   (Dev/QA/Prod), activation keys, and SCAP tailoring files on Satellite.
3. **Inventories** → **Ansible Product Demos Inventory** → **Sources** → **Satellite Inventory**
   → **Sync** (or run the **Satellite Inventory** job template for the Patch Dev workflow).

Then run demo templates such as **SATELLITE | Publish Content View Version** or
**LINUX | Register with Satellite**.

### Re-run only the Satellite domain install

If Satellite failed during bulk install, re-launch **APD | Install Satellite Demos** from
**Templates** in the **Default** organization (after updating credentials).

Prefer launching **SETUP | Satellite** directly if demo templates already exist.

## Troubleshooting

| Symptom | Likely cause | Fix |
| -------- | ------------- | ----- |
| `Failed to connect to Foreman server` / `satellite.example.com` | Placeholder credentials not updated | Update **Satellite Credential** and **Satellite Inventory**, then re-run **SETUP \| Satellite** |
| `SETUP \| Satellite` failed but `SATELLITE \| *` templates exist | Expected without a real Satellite during bulk install | Update credentials and run **SETUP \| Satellite** manually |
| Inventory sync empty or errors | **Satellite Inventory** credential wrong or Satellite unreachable from job pods | Verify URL, credentials, and network from the cluster to Satellite |
| Manifest / subscription errors during setup | No manifest on Satellite | Import a subscription manifest in Satellite before running setup |
| Local setup searches for RHEL7/RHEL8 repositories | Legacy upstream setup template is still configured | Re-enable the addon to apply the local RHEL9/RHEL10 profile |
| Multiple organizations contain published lab views | Content discovery is ambiguous | Set `SAT_ORG` to the intended organization |
| Fleet is registered but missing from DEV inventory groups | Registered to RHSM or another lifecycle environment | Check the actual RHSM server, organization and lifecycle; rerun `aap-demo wire` after correcting the selection |

## Resources

- [Product Demos — Satellite (upstream setup.yml)](https://github.com/ansible/product-demos/blob/main/satellite/setup.yml)
- [Product Demos Repository](https://github.com/ansible/product-demos)
