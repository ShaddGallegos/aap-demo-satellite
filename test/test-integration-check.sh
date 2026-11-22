#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
AAP_DEMO_CONFIG="$TEST_DIR/config"
touch "$AAP_DEMO_CONFIG"
source "$SCRIPT_DIR/includes/integration-check.sh"
_AAP_DEMO_SECURE_CURL_LOADED=1
_AAP_DEMO_ADDON_WIRE_LOADED=1
if grep -Eq '(^|[[:space:]])(--insecure|-[[:alnum:]]*k)' "$SCRIPT_DIR/includes/integration-check.sh"; then
  echo 'FAIL: integration inspection must not disable TLS verification' >&2
  exit 1
fi
if ! sed -n '/^  check-integrations)/,/^    ;;/p' "$SCRIPT_DIR/aap-demo.sh" \
  | grep -Fxq '    setup_kubeconfig_read_only'; then
  echo 'FAIL: integration inspection must use read-only kubeconfig setup' >&2
  exit 1
fi
readonly_setup=$(sed -n '/^setup_kubeconfig_read_only()/,/^}$/p' "$SCRIPT_DIR/aap-demo.sh")
touch "$TEST_DIR/existing-kubeconfig"
(
  check_kubectl() { :; }
  aap_demo_resolve_kubeconfig() { printf '%s' "$TEST_DIR/existing-kubeconfig"; }
  aap_demo_reject_remote_kubeconfig() { :; }
  cp() { echo 'FAIL: read-only setup tried to copy a kubeconfig' >&2; return 1; }
  COMMAND=check-integrations
  AAP_DEMO_DIR="$TEST_DIR/missing-state"
  KUBECTL_KUBECONFIG=""
  eval "$readonly_setup"
  setup_kubeconfig_read_only
  [ "$KUBECONFIG" = "$TEST_DIR/existing-kubeconfig" ]
  [ ! -e "$AAP_DEMO_DIR" ]
)
WIRE_AAP_INTEGRATION_NAME='aap-demo AAP'
WIRE_MCP_INTEGRATION_NAME='aap-demo MCP Server'
_addons_list() {
  if [ "$SCENARIO" = disabled ]; then echo ""; else echo 'ao mcp-server ollama fleet product-demo-satellite'; fi
}
wire_ao_api_base() { echo https://example.invalid/api/v1; }
_integration_ao_login_token() { [ "$SCENARIO" != auth_failure ] && printf 'private-token'; }
wire_aap_route_host() { echo example.invalid; }
wire_aap_admin_password() { printf 'private-password'; }
_integration_ao_get() {
  case "$1" in
    '/integrations?limit=100')
      local next=null
      local credential='"aap-credential"'
      [ "$SCENARIO" != paginated ] || next='"next-page"'
      [ "$SCENARIO" != missing_credential ] || credential=null
      printf '{"next":%s,"total":null,"resources":[
        {"name":"aap-demo AAP","id":"aap-integration","management_credential_id":%s,"integration_type":"ansible_automation_platform","enabled":true,"validation_status":"available"},
        {"name":"aap-demo MCP Server","integration_type":"mcp_server","enabled":true,"validation_status":"available","enabled_tool_count":3},
        {"name":"aap-demo Ollama","integration_type":"llm_provider","enabled":true,"validation_status":"available","id":"123"}
      ]}\n' "$next" "$credential"
      ;;
    '/proxies/aap/inventories?integration_id=aap-integration&credential_id=aap-credential')
      [ "$SCENARIO" != proxy_failure ] || return 1
      echo '{"results":[]}'
      ;;
    '/integrations/123/models?limit=100')
      echo '{"next":null,"total":1,"resources":[{"enabled":true,"is_default":true}]}'
      ;;
    *) return 1 ;;
  esac
}
_integration_aap_get() {
  case "$1" in
    'inventory_sources/?name=Satellite%20Inventory')
      if [ "$SCENARIO" = sync_failure ]; then
        echo '{"count":1,"results":[{"status":"failed","last_job_run":"2026-01-01"}]}'
      else
        echo '{"count":1,"results":[{"status":"successful","last_job_run":"2026-01-01"}]}'
      fi
      ;;
    'inventories/?name=Fleet') echo '{"count":1,"results":[{"id":2}]}' ;;
    'ad_hoc_commands/?inventory=2&module_name=ping&order_by=-id&page_size=1')
      echo '{"results":[{"status":"successful","finished":"2026-01-01"}]}'
      ;;
    *) return 1 ;;
  esac
}
for SCENARIO in ready disabled auth_failure paginated proxy_failure missing_credential sync_failure; do
  rc=0
  cmd_check_integrations >"$TEST_DIR/output" 2>"$TEST_DIR/error" || rc=$?
  ! grep -qE 'private-token|private-password' "$TEST_DIR/output" "$TEST_DIR/error"
  case "$SCENARIO" in
    ready)
      [ "$rc" -eq 0 ]
      grep -Eq '^PASS +AO-to-AAP' "$TEST_DIR/output"
      grep -Eq '^PASS +AO-to-MCP' "$TEST_DIR/output"
      grep -Eq '^PASS +AO-to-Ollama' "$TEST_DIR/output"
      grep -Eq '^PASS +Satellite-sync' "$TEST_DIR/output"
      grep -Eq '^PASS +Fleet-ping' "$TEST_DIR/output"
      ;;
    disabled)
      [ "$rc" -eq 0 ]
      grep -Eq '^DISABLED +AO' "$TEST_DIR/output"
      ;;
    auth_failure)
      [ "$rc" -ne 0 ]
      grep -Eq '^FAIL +AO +trusted HTTPS authentication failed$' "$TEST_DIR/output"
      ;;
    paginated)
      [ "$rc" -ne 0 ]
      grep -Eq '^FAIL +AO +integration list is incomplete or malformed$' "$TEST_DIR/output"
      ;;
    proxy_failure | missing_credential)
      [ "$rc" -ne 0 ]
      grep -Eq '^FAIL +AO-to-AAP' "$TEST_DIR/output"
      ;;
    sync_failure)
      [ "$rc" -ne 0 ]
      grep -Eq '^FAIL +Satellite-sync' "$TEST_DIR/output"
      ;;
  esac
done
echo "PASS: integration inspection reports enabled, disabled, failed, and incomplete evidence"
