#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

_err() { printf 'ERROR: %s\n' "$*" >&2; }
# shellcheck source=../includes/cloud-profile.sh
source "$REPO_ROOT/includes/cloud-profile.sh"

mkdir -p "$TEST_DIR/bin"
export TEST_AZ_CALLS="$TEST_DIR/az-calls"
cat >"$TEST_DIR/bin/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_AZ_CALLS"
case " $* " in
  *' account show '*) printf '%s\n' '{"id":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222","state":"Enabled"}' ;;
  *' group show '*' customer-rg '*) printf '%s\n' '{"name":"customer-rg"}' ;;
  *' network vnet show '*' customer-vnet '*) printf '%s\n' '{"name":"customer-vnet","location":"eastus"}' ;;
  *' network nsg show '*' customer-nsg '*)
    if [ "${TEST_AZ_PUBLIC_INGRESS:-false}" = true ]; then
      printf '%s\n' '{"id":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/customer-rg/providers/Microsoft.Network/networkSecurityGroups/customer-nsg","securityRules":[{"direction":"Inbound","access":"Allow","sourceAddressPrefix":"Internet"}]}'
    else
      printf '%s\n' '{"id":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/customer-rg/providers/Microsoft.Network/networkSecurityGroups/customer-nsg","securityRules":[{"direction":"Inbound","access":"Allow","sourceAddressPrefix":"10.0.0.0/24"}]}'
    fi
    ;;
  *' network vnet subnet show '*' aap-subnet '*) printf '%s\n' '{"name":"aap-subnet","networkSecurityGroup":{"id":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/customer-rg/providers/Microsoft.Network/networkSecurityGroups/customer-nsg"}}' ;;
  *' network vnet subnet show '*' fleet-subnet '*) printf '%s\n' '{"name":"fleet-subnet","networkSecurityGroup":{"id":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/customer-rg/providers/Microsoft.Network/networkSecurityGroups/customer-nsg"}}' ;;
  *' network vnet subnet show '*' satellite-subnet '*) printf '%s\n' '{"name":"satellite-subnet","networkSecurityGroup":{"id":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/customer-rg/providers/Microsoft.Network/networkSecurityGroups/customer-nsg"}}' ;;
  *' network private-dns zone show '*' demo.internal '*) printf '%s\n' '{"name":"demo.internal"}' ;;
  *' network private-dns link vnet list '*) printf '%s\n' '[{"virtualNetwork":{"id":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/customer-rg/providers/Microsoft.Network/virtualNetworks/customer-vnet"}}]' ;;
  *' identity show '*' customer-identity '*) printf '%s\n' '{"name":"customer-identity","type":"UserAssigned","principalId":"33333333-3333-3333-3333-333333333333"}' ;;
  *) echo "unexpected az command: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TEST_DIR/bin/az"
export PATH="$TEST_DIR/bin:$PATH"

profile="$TEST_DIR/azure.json"
jq -n '
  {
    schema_version: 1, provider: "azure", name: "customer-lab",
    ownership: {customer_id:"123",operator:"operator@example.test",approval_contact:"owner@example.test",cost_center:"demo"},
    location: {region:"eastus",zone_or_cluster:"zone-1"},
    network: {private_dns_zone:"demo.internal",management_cidrs:["10.0.0.0/24"],aap_subnet:"aap-subnet",fleet_subnet:"fleet-subnet",satellite_subnet:"satellite-subnet"},
    nodes: {aap:{count:1},fleet:{count:3},satellite:{enabled:false,count:0}},
    identity_refs: {operator:"external:az-login",workload:"external:managed-identity",redhat:"aap_demo.redhat.account_number"},
    approvals: {network_reviewed:true,chargeable_resources_approved:true,data_retention_reviewed:true},
    provider_config: {subscription_id:"11111111-1111-1111-1111-111111111111",tenant_id:"22222222-2222-2222-2222-222222222222",resource_group:"customer-rg",vnet_name:"customer-vnet",subnet_names:["aap-subnet","fleet-subnet","satellite-subnet"],network_security_group:"customer-nsg",managed_identity:"customer-identity"}
  }
' >"$profile"

cmd_cloud preflight "$profile" >"$TEST_DIR/output"
grep -Fq 'PASS: Azure read-only preflight completed' "$TEST_DIR/output"
for operation in 'account show' 'group show' 'network vnet show' 'network nsg show' \
  'network vnet subnet show' 'network private-dns zone show' 'network private-dns link vnet list' 'identity show'; do
  grep -Fq -- "$operation" "$TEST_AZ_CALLS"
done
if grep -Eqi '( create| delete| update| set| assign| remove)' "$TEST_AZ_CALLS"; then
  echo "FAIL: Azure preflight attempted a mutating Azure CLI operation" >&2
  exit 1
fi

if TEST_AZ_PUBLIC_INGRESS=true cmd_cloud preflight "$profile" >/dev/null 2>&1; then
  echo "FAIL: Azure preflight accepted public NSG ingress" >&2
  exit 1
fi

echo "PASS: Azure cloud preflight uses only read-only discovery and blocks public ingress"
