#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

_err() { printf 'ERROR: %s\n' "$*" >&2; }
# shellcheck source=../includes/cloud-profile.sh
source "$REPO_ROOT/includes/cloud-profile.sh"

mkdir -p "$TEST_DIR/bin"
export TEST_GCLOUD_CALLS="$TEST_DIR/gcloud-calls"
cat >"$TEST_DIR/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_GCLOUD_CALLS"
case " $* " in
  *' projects describe customer-project '*) printf '%s\n' '{"projectId":"customer-project","lifecycleState":"ACTIVE"}' ;;
  *' compute networks describe customer-vpc '*) printf '%s\n' '{"name":"customer-vpc","autoCreateSubnetworks":false}' ;;
  *' compute networks subnets describe aap-subnet '*) printf '%s\n' '{"name":"aap-subnet","network":"https://www.googleapis.com/compute/v1/projects/customer-project/global/networks/customer-vpc","privateIpGoogleAccess":true}' ;;
  *' compute networks subnets describe fleet-subnet '*) printf '%s\n' '{"name":"fleet-subnet","network":"https://www.googleapis.com/compute/v1/projects/customer-project/global/networks/customer-vpc","privateIpGoogleAccess":true}' ;;
  *' compute networks subnets describe satellite-subnet '*) printf '%s\n' '{"name":"satellite-subnet","network":"https://www.googleapis.com/compute/v1/projects/customer-project/global/networks/customer-vpc","privateIpGoogleAccess":true}' ;;
  *' compute firewall-rules list '*)
    if [ "${TEST_GCLOUD_PUBLIC_INGRESS:-false}" = true ]; then
      printf '%s\n' '[{"network":"https://www.googleapis.com/compute/v1/projects/customer-project/global/networks/customer-vpc","direction":"INGRESS","disabled":false,"targetServiceAccounts":["workload@customer-project.iam.gserviceaccount.com"],"sourceRanges":["0.0.0.0/0"]}]'
    else
      printf '%s\n' '[{"network":"https://www.googleapis.com/compute/v1/projects/customer-project/global/networks/customer-vpc","direction":"INGRESS","disabled":false,"targetServiceAccounts":["workload@customer-project.iam.gserviceaccount.com"],"sourceRanges":["10.0.0.0/24"]}]'
    fi
    ;;
  *' iam service-accounts describe workload@customer-project.iam.gserviceaccount.com '*) printf '%s\n' '{"email":"workload@customer-project.iam.gserviceaccount.com","disabled":false}' ;;
  *) echo "unexpected gcloud command: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TEST_DIR/bin/gcloud"
export PATH="$TEST_DIR/bin:$PATH"

profile="$TEST_DIR/gcp.json"
jq -n '
  {
    schema_version: 1, provider: "gcp", name: "customer-lab",
    ownership: {customer_id:"123",operator:"operator@example.test",approval_contact:"owner@example.test",cost_center:"demo"},
    location: {region:"us-central1",zone_or_cluster:"us-central1-a"},
    network: {private_dns_zone:"demo.internal",management_cidrs:["10.0.0.0/24"],aap_subnet:"aap-subnet",fleet_subnet:"fleet-subnet",satellite_subnet:"satellite-subnet"},
    nodes: {aap:{count:1},fleet:{count:3},satellite:{enabled:false,count:0}},
    identity_refs: {operator:"external:gcloud-adc",workload:"external:workload-identity",redhat:"aap_demo.redhat.account_number"},
    approvals: {network_reviewed:true,chargeable_resources_approved:true,data_retention_reviewed:true},
    provider_config: {project_id:"customer-project",network_name:"customer-vpc",subnet_names:["aap-subnet","fleet-subnet","satellite-subnet"],firewall_policy_ref:"reviewed-firewall-policy",service_account:"workload@customer-project.iam.gserviceaccount.com"}
  }
' >"$profile"

cmd_cloud preflight "$profile" --gcloud-configuration customer-sso >"$TEST_DIR/output"
grep -Fq 'PASS: GCP read-only preflight completed' "$TEST_DIR/output"
grep -Fq -- '--configuration customer-sso projects describe customer-project' "$TEST_GCLOUD_CALLS"
for operation in 'compute networks describe' 'compute networks subnets describe' \
  'compute firewall-rules list' 'iam service-accounts describe'; do
  grep -Fq -- "$operation" "$TEST_GCLOUD_CALLS"
done
if grep -Eqi '( create| delete| update| set-iam-policy| add-iam| remove-iam)' "$TEST_GCLOUD_CALLS"; then
  echo "FAIL: GCP preflight attempted a mutating gcloud operation" >&2
  exit 1
fi

if TEST_GCLOUD_PUBLIC_INGRESS=true cmd_cloud preflight "$profile" --gcloud-configuration customer-sso >/dev/null 2>&1; then
  echo "FAIL: GCP preflight accepted public firewall ingress" >&2
  exit 1
fi

echo "PASS: GCP cloud preflight uses only read-only discovery and blocks public ingress"
