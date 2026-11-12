#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/addons/product-demo-satellite/lib.sh"

AAP_USERNAME="admin"
AAP_PASSWORD=unused
AAP_API=https://example.invalid/api/controller/v2
SATELLITE_URL=https://external.example.test
RETRY_RESULT=0
TEMPLATE_RESPONSE='{"count":2}'
CURL_RESULT=0
RETRIES=0

apd_rerun_satellite_setup() {
  RETRIES=$((RETRIES + 1))
  return "$RETRY_RESULT"
}

curl() {
  [ "$CURL_RESULT" -eq 0 ] || return "$CURL_RESULT"
  printf '%s\n' "$TEMPLATE_RESPONSE"
}

apd_complete_satellite_install 0 >/dev/null
[ "$RETRIES" -eq 0 ] || { echo "FAIL: successful install was retried" >&2; exit 1; }

RETRY_RESULT=1
if apd_complete_satellite_install 1 >/dev/null 2>&1; then
  echo "FAIL: failed Satellite setup retry was reported as success" >&2
  exit 1
fi

RETRY_RESULT=0
apd_complete_satellite_install 1 >/dev/null
for TEMPLATE_RESPONSE in '{"count":0}' '{"count":"2"}' invalid; do
  if apd_complete_satellite_install 1 >/dev/null 2>&1; then
    echo "FAIL: missing or invalid Satellite template count was accepted" >&2
    exit 1
  fi
done

TEMPLATE_RESPONSE='{"count":2}'
CURL_RESULT=22
if apd_complete_satellite_install 1 >/dev/null 2>&1; then
  echo "FAIL: Satellite template API failure was reported as success" >&2
  exit 1
fi
echo "PASS: Satellite install retry and template verification propagate failures"

unset SATELLITE_URL
apd_satellite_is_lab
PROFILE_RESPONSE='{"subtotal":2,"results":[
  {"name":"RHEL9","repository_ids":[1,2],"version_count":1,"latest_version":"1.0","organization_id":1,
    "organization":{"id":1,"name":"Demo Org","label":"Demo_Org"}},
  {"name":"RHEL10","repository_ids":[3,4],"version_count":1,"latest_version":"2.0","organization_id":1,
    "organization":{"id":1,"name":"Demo Org","label":"Demo_Org"}}]}'
apd_satellite_api() { printf '%s' "$PROFILE_RESPONSE"; }
apd_discover_satellite_lab
jq -e '.organization.name == "Demo Org" and .environments == ["DEV","TEST","PROD"]
  and [.content_views[].name] == ["RHEL9","RHEL10"]' <<<"$APD_SATELLITE_LAB" >/dev/null
PROFILE_RESPONSE=$(jq '.results += [.results[0] | .organization_id = 3
  | .organization = {id:3,name:"Default Organization",label:"Default_Organization"}]
  | .subtotal = 3' <<<"$PROFILE_RESPONSE")
if apd_discover_satellite_lab >/dev/null 2>&1; then
  echo "FAIL: ambiguous content organizations accepted" >&2
  exit 1
fi
SAT_ORG="Demo Org" apd_discover_satellite_lab
PROFILE_RESPONSE='{"subtotal":1,"results":[{"name":"RHEL7","repository_ids":[1],"version_count":1}]}'
if apd_discover_satellite_lab >/dev/null 2>&1; then
  echo "FAIL: legacy-only content accepted for the local RHEL9 Fleet" >&2
  exit 1
fi
PROFILE_RESPONSE='{"subtotal":2,"results":[{"name":"RHEL9","repository_ids":[1],"version_count":1}]}'
if apd_discover_satellite_lab >/dev/null 2>&1; then
  echo "FAIL: incomplete content discovery accepted" >&2
  exit 1
fi

CONFIGURED=0
REGISTERED=0
SYNCED=0
apd_configure_satellite_lab_templates() { CONFIGURED=$((CONFIGURED + 1)); }
apd_register_satellite_lab_fleet() { REGISTERED=$((REGISTERED + 1)); }
apd_sync_satellite_lab_inventory() { SYNCED=$((SYNCED + 1)); }
CURL_RESULT=0
RETRY_RESULT=0
apd_complete_satellite_install 0 >/dev/null
[ "$CONFIGURED" -eq 1 ] && [ "$REGISTERED" -eq 1 ] && [ "$SYNCED" -eq 1 ]
RETRY_RESULT=1
if apd_complete_satellite_install 0 >/dev/null 2>&1; then
  echo "FAIL: local setup failure accepted" >&2
  exit 1
fi
[ "$REGISTERED" -eq 1 ] && [ "$SYNCED" -eq 1 ]
if apd_complete_satellite_install 1 >/dev/null 2>&1; then
  echo "FAIL: local installer failure accepted" >&2
  exit 1
fi
echo "PASS: lab discovery is unambiguous and setup gates Fleet registration and inventory synchronization"

source "$REPO_ROOT/addons/product-demo-satellite/lib.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
DEFAULT_ORG_ID=1
apd_apd_org_id() { printf '2'; }
curl() {
  local url="" payload="" previous="" argument
  for argument in "$@"; do
    [ "$previous" != -d ] || payload="$argument"
    case "$argument" in
      https://*) url="$argument" ;;
    esac
    previous="$argument"
  done
  case "$url" in
    *'/inventory_sources/?'*)
      printf '%s' '{"count":1,"results":[{"id":129,"inventory":3,"source_vars":"{}"}]}' ;;
    *'/inventories/?'*) printf '%s' '{"count":1,"results":[{"id":2}]}' ;;
    *'/inventories/2/hosts/?'*)
      printf '%s' '{"count":1,"results":[{"id":9,"name":"aap-fleet-node-1"}]}' ;;
    *'/hosts/9/variable_data/'*)
      printf '%s' '{"ansible_host":"192.0.2.1","ansible_port":2201,"ansible_password":"must-not-copy"}' ;;
    *'/inventory_sources/129/update/'*) printf '%s' '{"id":79}' ;;
    *'/inventory_sources/129/'*) printf '%s' "$payload" >"$TEST_DIR/source.json"; printf '{}' ;;
    *'/inventory_updates/79/'*) printf '%s' '{"status":"successful"}' ;;
    *'/workflow_job_templates/?'*) printf '%s' '{"count":1,"results":[{"id":135}]}' ;;
    *'/workflow_job_templates/135/workflow_nodes/?'*)
      printf '%s' '{"count":2,"results":[{"id":68,"extra_data":{"_hosts":"env_RHEL8_Dev"}},
        {"id":67,"extra_data":{"content_view":"RHEL8"}}]}' ;;
    *'/workflow_job_template_nodes/68/'*) printf '%s' "$payload" >"$TEST_DIR/hosts.json"; printf '{}' ;;
    *'/workflow_job_template_nodes/67/'*) printf '%s' "$payload" >"$TEST_DIR/view.json"; printf '{}' ;;
    *) echo "Unexpected API call: $url" >&2; return 1 ;;
  esac
}
apd_sync_satellite_lab_inventory >/dev/null
jq -e '.update_on_launch == true and
  (.source_vars | fromjson | .compose.ansible_host | contains("192.0.2.1")) and
  (.source_vars | fromjson | .compose.ansible_port | contains("2201"))' "$TEST_DIR/source.json" >/dev/null
if grep -q 'must-not-copy\|ansible_password' "$TEST_DIR/source.json"; then
  echo "FAIL: host secrets copied to inventory source composition" >&2
  exit 1
fi
jq -e '.extra_data._hosts == "env_DEV"' "$TEST_DIR/hosts.json" >/dev/null
jq -e '.extra_data.content_view == "RHEL9"' "$TEST_DIR/view.json" >/dev/null
if command -v ansible-inventory >/dev/null 2>&1; then
  printf '%s' '{"all":{"hosts":{"aap-fleet-node-1":{"foreman_ipv4":"10.0.2.15"}}}}' >"$TEST_DIR/hosts.yml"
  jq '.source_vars | fromjson | {plugin:"ansible.builtin.constructed",strict:true,compose}' \
    "$TEST_DIR/source.json" >"$TEST_DIR/compose.yml"
  ansible-inventory -i "$TEST_DIR/hosts.yml" -i "$TEST_DIR/compose.yml" --list \
    >"$TEST_DIR/inventory.json"
  if ! jq -e 'def plain: if type == "object" and has("__ansible_unsafe")
      then .__ansible_unsafe else . end;
    ._meta.hostvars["aap-fleet-node-1"]
    | (.ansible_host | plain) == "192.0.2.1" and .ansible_port == 2201
      and (.ansible_user | plain) == "ansible"' \
    "$TEST_DIR/inventory.json" >/dev/null; then
    echo "FAIL: Constructed inventory did not retain the QEMU SSH forwarding targets" >&2
    cat "$TEST_DIR/inventory.json" >&2
    exit 1
  fi
else
  echo "SKIP: Ansible inventory composition runtime check (ansible-inventory is not installed)"
fi
echo "PASS: Satellite inventory preserves QEMU SSH forwarding without copying secrets and updates workflow targets"
