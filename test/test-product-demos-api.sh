#!/usr/bin/env bash
# Regression tests for product-demos AAP API readiness and subscription checks.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_SH="${REPO_ROOT}/addons/product-demos-base/lib.sh"
DEPLOY_SH="${REPO_ROOT}/addons/product-demos-base/deploy.sh"

unset PRODUCT_DEMOS_EE

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for these tests" >&2
  exit 1
fi

# shellcheck source=addons/product-demos-base/lib.sh
source "$LIB_SH"

if [ "$PRODUCT_DEMOS_EE" = "quay.io/ansible-product-demos/apd-ee-27:latest" ]; then
  echo "✓ product_demos_ee_defaults_to_aap_27"
else
  echo "✗ product_demos_ee_defaults_to_aap_27" >&2
  exit 1
fi

if grep -Fq 'apd-ee-26' "$DEPLOY_SH" "$LIB_SH"; then
  echo "✗ product_demos_aap_27_paths_must_not_default_to_aap_26_ee" >&2
  exit 1
else
  echo "✓ product_demos_aap_27_paths_must_not_default_to_aap_26_ee"
fi

export AAP_USERNAME="admin"
export AAP_PASSWORD=""
export AAP_API="https://aap.example.test/api/controller/v2"
export AAP_UI_URL="https://aap.example.test"
export APD_API_WAIT_ATTEMPTS=2
export APD_API_WAIT_DELAY=0

MOCK_ORGS_BODY=""
MOCK_CONFIG_BODY=""
MOCK_INVENTORIES_BODY=""
MOCK_CREDENTIALS_BODY=""
ORGS_CALLS=0

curl() {
  local url=""
  local arg
  for arg in "$@"; do
    case "$arg" in
      http://* | https://*) url="$arg" ;;
    esac
  done
  case "$url" in
    *"/organizations/"*)
      ORGS_CALLS=$((ORGS_CALLS + 1))
      printf '%s' "$MOCK_ORGS_BODY"
      ;;
    *"/config/"*)
      printf '%s' "$MOCK_CONFIG_BODY"
      ;;
    *"/inventories/"*)
      printf '%s' "$MOCK_INVENTORIES_BODY"
      ;;
    *"/credentials/"*)
      printf '%s' "$MOCK_CREDENTIALS_BODY"
      ;;
    *)
      echo "unexpected curl url: $url" >&2
      return 1
      ;;
  esac
}

PASSED=0
FAILED=0

pass() {
  echo "✓ $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo "✗ $1" >&2
  FAILED=$((FAILED + 1))
}

ORG_JSON='{"count":1,"results":[{"id":1,"name":"Default"}]}'
INVENTORIES_JSON='{"count":2,"results":[{"id":9,"name":"Other","summary_fields":{"organization":{"id":1}}},{"id":7,"name":"Demo Inventory","summary_fields":{"organization":{"id":1}}}]}'
EXECUTION_CREDENTIALS_JSON='{"count":2,"results":[{"id":4,"name":"aap-demo Execution OpenShift","summary_fields":{"organization":{"id":1},"credential_type":{"id":3}}},{"id":8,"name":"aap-demo Execution OpenShift","summary_fields":{"organization":{"id":2},"credential_type":{"id":3}}}]}'
LICENSE_JSON='{"license_info":{"valid_key":true,"license_type":"enterprise"}}'
NO_LICENSE_JSON='{"license_info":{}}'
UNLICENSED_JSON='{"license_info":{"valid_key":false,"license_type":"UNLICENSED"}}'

ORGS_CALLS=0
MOCK_ORGS_BODY="$ORG_JSON"
if output=$(apd_wait_for_controller_api 2>&1) && [[ "$output" == *"AAP controller API is ready"* ]]; then
  pass "wait_succeeds_when_organizations_json_is_valid"
else
  fail "wait_succeeds_when_organizations_json_is_valid"
  echo "$output" >&2
fi

ORGS_CALLS=0
MOCK_ORGS_BODY="OK"
if output=$(apd_wait_for_controller_api 2>&1); then
  fail "wait_fails_when_api_returns_non_json"
  echo "$output" >&2
else
  if [[ "$output" == *"API is not ready"* ]] && [[ "$output" == *"OK"* ]]; then
    pass "wait_fails_when_api_returns_non_json"
  else
    fail "wait_fails_when_api_returns_non_json"
    echo "$output" >&2
  fi
fi

MOCK_ORGS_BODY="OK"
org_id=$(apd_default_org_id)
if [ -z "$org_id" ]; then
  pass "default_org_id_empty_on_non_json"
else
  fail "default_org_id_empty_on_non_json"
  echo "got: $org_id" >&2
fi

MOCK_ORGS_BODY="$ORG_JSON"
org_id=$(apd_default_org_id)
if [ "$org_id" = "1" ]; then
  pass "default_org_id_parses_json"
else
  fail "default_org_id_parses_json"
  echo "got: $org_id" >&2
fi

DEFAULT_ORG_ID=1
MOCK_INVENTORIES_BODY="$INVENTORIES_JSON"
inventory_id=$(apd_default_inventory_id)
if [ "$inventory_id" = "7" ]; then
  pass "default_inventory_id_is_organization_scoped_and_prefers_demo_inventory"
else
  fail "default_inventory_id_is_organization_scoped_and_prefers_demo_inventory"
  echo "got: $inventory_id" >&2
fi

if grep -Fq 'inventory: $inventory_id' "$LIB_SH" \
  && ! grep -Fq 'inventory: 1' "$LIB_SH"; then
  pass "domain_templates_do_not_assume_inventory_id_one"
else
  fail "domain_templates_do_not_assume_inventory_id_one"
fi

MOCK_CREDENTIALS_BODY="$EXECUTION_CREDENTIALS_JSON"
execution_credential_id=$(apd_default_execution_credential_id 1 3)
if [ "$execution_credential_id" = "4" ]; then
  pass "execution_credential_lookup_reuses_matching_owned_identity"
else
  fail "execution_credential_lookup_reuses_matching_owned_identity"
  echo "got: $execution_credential_id" >&2
fi

if grep -Fq 'apd_default_execution_credential_id "$org_id" "$credential_type_id"' "$LIB_SH" \
  && grep -Fq 'Reusing the existing aap-demo execution credential' "$LIB_SH"; then
  pass "execution_credential_reconciliation_reattaches_before_creating"
else
  fail "execution_credential_reconciliation_reattaches_before_creating"
fi

# The base job can report successful just before all of its controller records
# become visible.  The hand-off must wait rather than fail the umbrella addon.
APD_RESOURCE_READY_TIMEOUT_SECONDS=3
APD_RESOURCE_READY_DELAY_SECONDS=1
resolve_calls_file=$(mktemp)
apd_resolve_domain_install_ids() {
  local calls
  calls=$(wc -l <"$resolve_calls_file")
  printf 'x\n' >>"$resolve_calls_file"
  [ "$calls" -ge 1 ]
}
if output=$(apd_wait_for_domain_install_ids "Product Demos EE" 2>&1) \
  && [ "$(wc -l <"$resolve_calls_file")" -eq 2 ] \
  && [[ "$output" == *"Waiting for Product Demos base resources"* ]] \
  && [[ "$output" == *"Product Demos base resources are ready"* ]]; then
  pass "domain_resource_wait_retries_controller_propagation"
else
  fail "domain_resource_wait_retries_controller_propagation"
  echo "$output" >&2
fi
rm -f "$resolve_calls_file"

APD_RESOURCE_READY_TIMEOUT_SECONDS=1
APD_RESOURCE_READY_DELAY_SECONDS=1
apd_resolve_domain_install_ids() { return 1; }
if output=$(apd_wait_for_domain_install_ids "Product Demos EE" 2>&1); then
  fail "domain_resource_wait_reports_missing_resources_after_timeout"
  echo "$output" >&2
else
  if [[ "$output" == *"were not ready after 1s"* ]]; then
    pass "domain_resource_wait_reports_missing_resources_after_timeout"
  else
    fail "domain_resource_wait_reports_missing_resources_after_timeout"
    echo "$output" >&2
  fi
fi

# Restore the real function for the remaining API helper tests.
source "$LIB_SH"

MOCK_CONFIG_BODY="$LICENSE_JSON"
if apd_require_subscription >/dev/null 2>&1; then
  pass "require_subscription_accepts_valid_license"
else
  fail "require_subscription_accepts_valid_license"
fi

MOCK_CONFIG_BODY="$NO_LICENSE_JSON"
if output=$(apd_require_subscription 2>&1); then
  fail "require_subscription_rejects_missing_license"
  echo "$output" >&2
else
  if [[ "$output" == *"does not have a registered subscription"* ]] \
    && [[ "$output" == *"https://aap.example.test"* ]]; then
    pass "require_subscription_rejects_missing_license"
  else
    fail "require_subscription_rejects_missing_license"
    echo "$output" >&2
  fi
fi

MOCK_CONFIG_BODY="$UNLICENSED_JSON"
if output=$(apd_require_subscription 2>&1); then
  fail "require_subscription_rejects_unlicensed_response"
  echo "$output" >&2
else
  if [[ "$output" == *"does not have a registered subscription"* ]]; then
    pass "require_subscription_rejects_unlicensed_response"
  else
    fail "require_subscription_rejects_unlicensed_response"
    echo "$output" >&2
  fi
fi

if grep -q 'apd_wait_for_controller_api || exit 1' "$DEPLOY_SH" \
  && grep -q 'apd_require_subscription || exit 1' "$DEPLOY_SH"; then
  pass "deploy_waits_and_requires_subscription"
else
  fail "deploy_waits_and_requires_subscription"
fi

domain_deploy_scripts=(
  "${REPO_ROOT}/addons/product-demos/deploy.sh"
  "${REPO_ROOT}/addons/product-demo-linux/deploy.sh"
  "${REPO_ROOT}/addons/product-demo-windows/deploy.sh"
  "${REPO_ROOT}/addons/product-demo-network/deploy.sh"
  "${REPO_ROOT}/addons/product-demo-cloud/deploy.sh"
  "${REPO_ROOT}/addons/product-demo-openshift/deploy.sh"
  "${REPO_ROOT}/addons/product-demo-satellite/deploy.sh"
  "${REPO_ROOT}/addons/product-demo-infrastructure/deploy.sh"
)
missing_readiness=$(grep -L -F 'apd_wait_for_domain_install_ids' "${domain_deploy_scripts[@]}" || true)
legacy_resolution=$(grep -l -F 'apd_resolve_domain_install_ids' "${domain_deploy_scripts[@]}" || true)
if [ -z "$missing_readiness" ] && [ -z "$legacy_resolution" ]; then
  pass "all_domain_addons_wait_for_base_resource_propagation"
else
  fail "all_domain_addons_wait_for_base_resource_propagation"
  printf 'Missing readiness gate: %s\nLegacy direct resolution: %s\n' \
    "${missing_readiness:-none}" "${legacy_resolution:-none}" >&2
fi

if grep -q 'apd_wait_for_controller_api || return 1' "$LIB_SH" \
  && grep -q 'apd_require_subscription || return 1' "$LIB_SH"; then
  pass "init_connection_waits_and_requires_subscription"
else
  fail "init_connection_waits_and_requires_subscription"
fi

if grep -Fq 'kind: RoleBinding' "$LIB_SH" \
  && grep -Fq -- '--duration=1h' "$LIB_SH" \
  && ! grep -Fq -- '--clusterrole=cluster-admin' "$LIB_SH" \
  && ! grep -Fq 'kubectl config view --minify --raw' "$LIB_SH" \
  && ! grep -Fq 'oc whoami -t' "$LIB_SH" \
  && grep -Fq 'apd_reconcile_default_execution_credential || return 1' \
    "${REPO_ROOT}/addons/product-demo-satellite/lib.sh"; then
  pass "execution_credential_is_namespaced_short_lived_and_refreshed_before_satellite_job"
else
  fail "execution_credential_is_namespaced_short_lived_and_refreshed_before_satellite_job"
fi

if grep -Fq 'for attempt in $(seq 1 5)' "$LIB_SH" \
  && grep -Fq 'Waiting for controller task pod/project path' "$LIB_SH"; then
  pass "overlay_retries_controller_task_pod_handoff"
else
  fail "overlay_retries_controller_task_pod_handoff"
fi

saved_home="${HOME:-}"
record_home=$(mktemp -d)
export HOME="$record_home"
unset AAP_DEMO_ENABLED_ADDONS
if apd_base_is_recorded; then
  fail "base_is_not_recorded_on_an_empty_home"
else
  pass "base_is_not_recorded_on_an_empty_home"
fi

export AAP_DEMO_ENABLED_ADDONS="product-demo-linux product-demos-base"
if apd_base_is_recorded && apd_addon_enabled product-demo-linux; then
  pass "enabled_addons_env_records_base_and_domain"
else
  fail "enabled_addons_env_records_base_and_domain"
fi
if apd_addon_enabled product-demos; then
  fail "enabled_addons_env_does_not_treat_base_as_the_umbrella"
else
  pass "enabled_addons_env_does_not_treat_base_as_the_umbrella"
fi

unset AAP_DEMO_ENABLED_ADDONS
mkdir -p "$HOME/.aap-demo"
printf 'ADDONS=product-demo-openshift\n' >"$HOME/.aap-demo/config"
if apd_addon_enabled product-demo-openshift; then
  pass "legacy_config_still_records_a_domain"
else
  fail "legacy_config_still_records_a_domain"
fi
if apd_base_is_recorded; then
  fail "legacy_domain_does_not_count_as_base"
else
  pass "legacy_domain_does_not_count_as_base"
fi
rm -rf "$record_home"
if [ -n "$saved_home" ]; then
  export HOME="$saved_home"
fi

domain_vars=$(apd_launch_extra_vars_json windows)
if [ "$(echo "$domain_vars" | jq -r '.aap_configuration_async_retries')" = "50" ] \
  && [ "$(echo "$domain_vars" | jq -r '.gateway_configuration_async_retries')" = "50" ] \
  && [ "$(echo "$domain_vars" | jq -r '.controller_configuration_async_retries')" = "50" ] \
  && ! grep -q 'configuration_async_retries: 0' "$LIB_SH" \
  && ! grep -q 'configuration_async_retries: 0' "$DEPLOY_SH"; then
  pass "configuration_jobs_retry_async_resource_creation"
else
  fail "configuration_jobs_retry_async_resource_creation"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
