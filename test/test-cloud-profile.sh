#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

_err() { printf 'ERROR: %s\n' "$*" >&2; }
# shellcheck source=../includes/cloud-profile.sh
source "$REPO_ROOT/includes/cloud-profile.sh"

for provider in aws azure gcp vmware; do
  profile="$TEST_DIR/$provider.json"
  cmd_cloud profile init "$provider" "$profile"
  test "$(stat -c '%a' "$profile")" = 600
  if cmd_cloud profile validate "$profile" >/dev/null 2>&1; then
    echo "FAIL: incomplete $provider profile was accepted" >&2
    exit 1
  fi
  if cmd_cloud plan "$profile" >/dev/null 2>&1; then
    echo "FAIL: an incomplete $provider profile produced a plan" >&2
    exit 1
  fi
  jq '
    .name = "customer-lab" |
    .ownership = {customer_id:"123",operator:"operator@example.test",approval_contact:"owner@example.test",cost_center:"demo"} |
    .location = {region:"region-1",zone_or_cluster:"zone-1"} |
    .network = {private_dns_zone:"demo.internal",management_cidrs:["10.0.0.0/24"],aap_subnet:"aap",fleet_subnet:"fleet",satellite_subnet:"satellite"} |
    .identity_refs = {operator:"external:operator",workload:"external:workload",redhat:"aap_demo.redhat.account_number"} |
    .approvals = {network_reviewed:true,chargeable_resources_approved:true,data_retention_reviewed:true} |
    .provider_config |= with_entries(.value = (if (.value | type) == "array" then ["configured"] else "configured" end))
  ' "$profile" >"$TEST_DIR/$provider-ready.json"
  cmd_cloud profile validate "$TEST_DIR/$provider-ready.json" >/dev/null
done

if jq '.password = "not-allowed"' "$TEST_DIR/aws-ready.json" >"$TEST_DIR/unsafe.json" \
  && cmd_cloud profile validate "$TEST_DIR/unsafe.json" >/dev/null 2>&1; then
  echo "FAIL: plaintext secret-like profile field was accepted" >&2
  exit 1
fi

echo "PASS: cloud profiles validate required non-secret provider planning inputs"
