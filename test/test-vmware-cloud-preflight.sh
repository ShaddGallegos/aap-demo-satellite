#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

_err() { printf 'ERROR: %s\n' "$*" >&2; }
# shellcheck source=../includes/cloud-profile.sh
source "$REPO_ROOT/includes/cloud-profile.sh"

mkdir -p "$TEST_DIR/bin"
export TEST_GOVC_CALLS="$TEST_DIR/govc-calls"
cat >"$TEST_DIR/bin/govc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_GOVC_CALLS"
case "${1:-}" in
  about) printf '%s\n' '{"about":{"name":"VMware vCenter Server"}}' ;;
  datacenter.info) printf '%s\n' '{"datacenters":[{"name":"customer-dc"}]}' ;;
  cluster.info) printf '%s\n' '{"clusters":[{"name":"customer-cluster"}]}' ;;
  datastore.info) printf '%s\n' '{"datastores":[{"summary":{"accessible":true}}]}' ;;
  find) printf '%s\n' '{"elements":["/customer-dc/network/customer-portgroup"]}' ;;
  vm.info) printf '%s\n' '{"virtualMachines":[{"config":{"template":true}}]}' ;;
  *) echo "unexpected govc command: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TEST_DIR/bin/govc"

cat >"$TEST_DIR/bin/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  s_client) printf '%s\n' '-----BEGIN CERTIFICATE-----' 'fixture' '-----END CERTIFICATE-----' ;;
  x509)
    cat >/dev/null
    printf '%s\n' 'sha256 Fingerprint=AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA'
    ;;
  *) echo "unexpected openssl command: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TEST_DIR/bin/openssl"
export PATH="$TEST_DIR/bin:$PATH"

profile="$TEST_DIR/vmware.json"
jq -n '
  {
    schema_version: 1, provider: "vmware", name: "customer-lab",
    ownership: {customer_id:"123",operator:"operator@example.test",approval_contact:"owner@example.test",cost_center:"demo"},
    location: {region:"customer-region",zone_or_cluster:"customer-cluster"},
    network: {private_dns_zone:"demo.internal",management_cidrs:["10.0.0.0/24"],aap_subnet:"aap-segment",fleet_subnet:"fleet-segment",satellite_subnet:"satellite-segment"},
    nodes: {aap:{count:1},fleet:{count:3},satellite:{enabled:false,count:0}},
    identity_refs: {operator:"external:govc-login",workload:"external:vmware-role",redhat:"aap_demo.redhat.account_number"},
    approvals: {network_reviewed:true,chargeable_resources_approved:true,data_retention_reviewed:true},
    provider_config: {vcenter_url:"https://vcenter.example.test",datacenter:"customer-dc",cluster:"customer-cluster",datastore:"customer-datastore",port_group:"customer-portgroup",template:"rhel9-template",certificate_sha256:"AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA"}
  }
' >"$profile"

GOVC_URL='https://operator@vcenter.example.test/sdk' cmd_cloud preflight "$profile" >"$TEST_DIR/output"
grep -Fq 'PASS: VMware read-only preflight completed' "$TEST_DIR/output"
for operation in 'about -json' 'datacenter.info -json' 'cluster.info -json' 'datastore.info -json' 'find -json' 'vm.info -json'; do
  grep -Fq -- "$operation" "$TEST_GOVC_CALLS"
done
if grep -Eqi '( clone| create| destroy| power| vm\.change| object\.mv| datastore\.create)' "$TEST_GOVC_CALLS"; then
  echo "FAIL: VMware preflight attempted a mutating govc operation" >&2
  exit 1
fi

if GOVC_URL='https://operator@vcenter.example.test/sdk' GOVC_INSECURE=true cmd_cloud preflight "$profile" >/dev/null 2>&1; then
  echo "FAIL: VMware preflight accepted GOVC_INSECURE=true" >&2
  exit 1
fi

if GOVC_URL='https://operator@other-vcenter.example.test/sdk' cmd_cloud preflight "$profile" >/dev/null 2>&1; then
  echo "FAIL: VMware preflight accepted a GOVC_URL for a different vCenter" >&2
  exit 1
fi

echo "PASS: VMware cloud preflight pins TLS and uses only read-only inventory discovery"
