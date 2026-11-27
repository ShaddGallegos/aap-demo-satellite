#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

_err() { printf 'ERROR: %s\n' "$*" >&2; }
# shellcheck source=../includes/cloud-profile.sh
source "$REPO_ROOT/includes/cloud-profile.sh"

mkdir -p "$TEST_DIR/bin"
export TEST_AWS_CALLS="$TEST_DIR/aws-calls"
cat >"$TEST_DIR/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_AWS_CALLS"
case " $* " in
  *' sts get-caller-identity '*) printf '%s\n' '{"Account":"123456789012"}' ;;
  *' ec2 describe-vpcs '*) printf '%s\n' '{"Vpcs":[{"VpcId":"vpc-abc","State":"available"}]}' ;;
  *' ec2 describe-vpc-attribute '*' enableDnsSupport '*) printf '%s\n' '{"EnableDnsSupport":{"Value":true}}' ;;
  *' ec2 describe-vpc-attribute '*' enableDnsHostnames '*) printf '%s\n' '{"EnableDnsHostnames":{"Value":true}}' ;;
  *' ec2 describe-subnets '*) printf '%s\n' '{"Subnets":[{"SubnetId":"subnet-aap","VpcId":"vpc-abc","State":"available","MapPublicIpOnLaunch":false},{"SubnetId":"subnet-fleet","VpcId":"vpc-abc","State":"available","MapPublicIpOnLaunch":false},{"SubnetId":"subnet-satellite","VpcId":"vpc-abc","State":"available","MapPublicIpOnLaunch":false}]}' ;;
  *' ec2 describe-security-groups '*)
    if [ "${TEST_AWS_PUBLIC_INGRESS:-false}" = true ]; then
      printf '%s\n' '{"SecurityGroups":[{"GroupId":"sg-private","VpcId":"vpc-abc","IpPermissions":[{"IpRanges":[{"CidrIp":"0.0.0.0/0"}],"Ipv6Ranges":[]}]}]}'
    else
      printf '%s\n' '{"SecurityGroups":[{"GroupId":"sg-private","VpcId":"vpc-abc","IpPermissions":[{"IpRanges":[{"CidrIp":"10.0.0.0/24"}],"Ipv6Ranges":[]}]}]}'
    fi
    ;;
  *' iam get-instance-profile '*) printf '%s\n' '{"InstanceProfile":{"InstanceProfileName":"aap-demo-workload","Roles":[{"RoleName":"aap-demo-workload"}]}}' ;;
  *) echo "unexpected AWS command: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TEST_DIR/bin/aws"
export PATH="$TEST_DIR/bin:$PATH"

profile="$TEST_DIR/aws.json"
jq -n '
  {
    schema_version: 1, provider: "aws", name: "customer-lab",
    ownership: {customer_id:"123",operator:"operator@example.test",approval_contact:"owner@example.test",cost_center:"demo"},
    location: {region:"us-east-1",zone_or_cluster:"us-east-1a"},
    network: {private_dns_zone:"demo.internal",management_cidrs:["10.0.0.0/24"],aap_subnet:"subnet-aap",fleet_subnet:"subnet-fleet",satellite_subnet:"subnet-satellite"},
    nodes: {aap:{count:1},fleet:{count:3},satellite:{enabled:false,count:0}},
    identity_refs: {operator:"external:aws-sso",workload:"external:instance-profile",redhat:"aap_demo.redhat.account_number"},
    approvals: {network_reviewed:true,chargeable_resources_approved:true,data_retention_reviewed:true},
    provider_config: {account_id:"123456789012",vpc_id:"vpc-abc",subnet_ids:["subnet-aap","subnet-fleet","subnet-satellite"],security_group_ids:["sg-private"],instance_profile:"aap-demo-workload"}
  }
' >"$profile"

cmd_cloud preflight "$profile" --aws-profile demo-sso >"$TEST_DIR/output"
grep -Fq 'PASS: AWS read-only preflight completed' "$TEST_DIR/output"
grep -Fq -- '--profile demo-sso sts get-caller-identity' "$TEST_AWS_CALLS"
for operation in 'ec2 describe-vpcs' 'ec2 describe-vpc-attribute' 'ec2 describe-subnets' \
  'ec2 describe-security-groups' 'iam get-instance-profile'; do
  grep -Fq -- "$operation" "$TEST_AWS_CALLS"
done
if grep -Eqi '( create| delete| modify| run-instances| terminate)' "$TEST_AWS_CALLS"; then
  echo "FAIL: AWS preflight attempted a mutating AWS operation" >&2
  exit 1
fi

if TEST_AWS_PUBLIC_INGRESS=true cmd_cloud preflight "$profile" --aws-profile demo-sso >/dev/null 2>&1; then
  echo "FAIL: AWS preflight accepted public security-group ingress" >&2
  exit 1
fi

echo "PASS: AWS cloud preflight uses only read-only discovery and blocks public ingress"
