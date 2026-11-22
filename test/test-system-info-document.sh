#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export SCRIPT_DIR="$REPO_ROOT"
export NAMESPACE="aap-operator"
export KUBECONFIG="$TEST_DIR/kubeconfig"
export AAP_DEMO_SYSTEM_INFO_FILE="$TEST_DIR/docs/aap-demo-system-info.md"
export AAP_DEMO_DIR="$TEST_DIR/state"
export AO_LLM_PROVIDER=external
export AO_LLM_BASE_URL=https://llm.example.test/v1
export AO_LLM_MODEL=test-model
export CRC_DISK=160
export AAP_DEMO_GIT_DATE=2026-01-01T00:00:00Z
export AAP_DEMO_REPO_ROOT="$REPO_ROOT"
export AAP_DEMO_GIT_BRANCH=test
export AAP_DEMO_GIT_REMOTE=https://example.test/aap-demo.git
export HOME="$TEST_DIR/home"

mkdir -p "$AAP_DEMO_DIR/ao" "$HOME/.crc/machines/crc"
printf 'kubeadmin-fixture' >"$HOME/.crc/machines/crc/kubeadmin-password"
printf 'llm-key-fixture' >"$AAP_DEMO_DIR/ao/llm-api-key"
chmod 600 "$AAP_DEMO_DIR/ao/llm-api-key"

aap_demo_version_short() {
  printf 'test-version'
}

infra_get_name() {
  printf 'test-cluster'
}

infra_get_state() {
  printf 'running'
}

crc() {
  [ "$*" = ip ] || return 1
  printf '192.168.127.2\n'
}

_detect_crc_ssh_key() {
  printf '/fixture/id_ed25519\n'
}

_addons_list() {
  printf 'mcp-server ao'
}

infra_exec_cmd() {
  printf 'Test RHEL\t%s\t8\t4Gi\t16Gi\t12Gi\t0.1 0.2 0.3\t10G/50G (20%% used)\t50\t10\t40\n' "${MOCK_VM_VERSION-4.22.1}"
}

aap_demo_resolve_kubeconfig() {
  printf '%s' "$KUBECONFIG"
}

getent() {
  printf '127.0.0.1 STREAM fixture\n'
}

virsh() {
  [ "$*" = "-c qemu:///system domstate satellite" ] || return 1
  [ -n "${MOCK_SATELLITE_STATE:-}" ] || return 1
  printf '%s\n' "$MOCK_SATELLITE_STATE"
}

curl() {
  [ "${MOCK_SATELLITE_HTTPS:-true}" = true ]
}

_mock_inventory_kubectl() {
  case "$*" in
    "cluster-info")
      return 0
      ;;
    "config current-context")
      printf 'aap-demo\n'
      ;;
    "version -o json")
      printf '{"serverVersion":{"gitVersion":"v1.33.1"}}\n'
      ;;
    "get route -A -o json")
      jq --argjson openshift "${MOCK_OPENSHIFT:-true}" \
        '.items |= map(select($openshift or (.metadata.namespace != "openshift-authentication" and .metadata.namespace != "openshift-console")))' <<'EOF'
{"items":[
  {"metadata":{"namespace":"aap-operator","name":"aap"},"spec":{"host":"aap.example.test","to":{"name":"aap"},"port":{"targetPort":"http"},"tls":{"termination":"edge"}}},
  {"metadata":{"namespace":"automation-orchestrator","name":"automation-orchestrator"},"spec":{"host":"ao.example.test","to":{"name":"automation-orchestrator-ui"},"port":{"targetPort":"http"},"tls":{"termination":"edge"}}},
  {"metadata":{"namespace":"openshift-authentication","name":"oauth-openshift"},"spec":{"host":"oauth-openshift.apps-crc.testing","to":{"name":"oauth-openshift"},"port":{"targetPort":"https"},"tls":{"termination":"passthrough"}}},
  {"metadata":{"namespace":"openshift-console","name":"console"},"spec":{"host":"console-openshift-console.apps-crc.testing","to":{"name":"console"},"port":{"targetPort":"https"},"tls":{"termination":"reencrypt"}}},
  {"metadata":{"namespace":"openshift-monitoring","name":"prometheus"},"spec":{"host":"prometheus.example.test","to":{"name":"prometheus"}}}
]}
EOF
      ;;
    "get route oauth-openshift -n openshift-authentication --ignore-not-found --request-timeout=5s -o name")
      [ "${MOCK_OAUTH_FAILURE:-false}" != true ] || return 1
      [ "${MOCK_OPENSHIFT:-true}" != true ] || printf 'route.route.openshift.io/oauth-openshift\n'
      return 0
      ;;
    "get namespace -o json")
      printf '{"items":[{"metadata":{"name":"aap-operator"}},{"metadata":{"name":"automation-orchestrator"}}]}\n'
      ;;
    "get namespace automation-orchestrator")
      return 0
      ;;
    "get service -A -o json")
      printf '{"items":[{"metadata":{"namespace":"aap-operator","name":"aap"},"spec":{"type":"ClusterIP","clusterIP":"10.43.1.2","ports":[{"port":80,"protocol":"TCP","targetPort":8000}]}},{"metadata":{"namespace":"automation-orchestrator","name":"automation-orchestrator-ui"},"spec":{"type":"ClusterIP","clusterIP":"10.43.1.3","ports":[{"port":80,"protocol":"TCP","targetPort":8080}]}}]}\n'
      ;;
    "get pods -A -o json")
      printf '{"items":[{"metadata":{"namespace":"aap-operator","name":"aap-gateway"},"status":{"phase":"Running","podIP":"10.42.0.2","containerStatuses":[{"ready":true,"restartCount":0}]},"spec":{"nodeName":"test-node"}},{"metadata":{"namespace":"automation-orchestrator","name":"automation-orchestrator-ui"},"status":{"phase":"Running","podIP":"10.42.0.3","containerStatuses":[{"ready":true,"restartCount":1}]},"spec":{"nodeName":"test-node"}}]}\n'
      ;;
    "get aap -A -o json")
      printf '{"items":[{"metadata":{"namespace":"aap-operator","name":"aap"},"status":{"adminPasswordSecret":"aap-admin-password"}}]}\n'
      ;;
    "get secret aap-admin-password -n aap-operator -o jsonpath={.data.password}")
      printf 'YWFwLXBhc3N3b3Jk'
      ;;
    "get secret automation-orchestrator-initial-admin-password -n automation-orchestrator -o jsonpath={.data.password}")
      printf 'YW8tcGFzc3dvcmQ='
      ;;
    "get service router-default -n openshift-ingress -o json")
      printf '{"metadata":{"name":"router-default"},"spec":{"clusterIP":"10.43.1.4","externalIPs":["192.168.1.2"],"ports":[{"port":80,"protocol":"TCP","nodePort":30080},{"port":443,"protocol":"TCP","nodePort":30443}]},"status":{"loadBalancer":{"ingress":[{"ip":"10.42.0.2"}]}}}\n'
      ;;
    "get endpoints router-default -n openshift-ingress -o json")
      printf '{"subsets":[{"addresses":[{"ip":"10.42.0.4"}],"ports":[{"port":80,"protocol":"TCP"},{"port":443,"protocol":"TCP"}]}]}\n'
      ;;
    *)
      echo "Unexpected kubectl invocation: $*" >&2
      return 1
      ;;
  esac
}

kubectl() {
  _mock_inventory_kubectl "$@"
}

# shellcheck source=../includes/ao-llm.sh
source "$REPO_ROOT/includes/ao-llm.sh"
# shellcheck source=../includes/system-inventory.sh
source "$REPO_ROOT/includes/system-inventory.sh"
# shellcheck source=../includes/system-info-document.sh
source "$REPO_ROOT/includes/system-info-document.sh"

include_inventory=$(aap_demo_collect_system_inventory include)
redacted_inventory=$(aap_demo_collect_system_inventory redact)
omitted_inventory=$(aap_demo_collect_system_inventory omit)

[ "$(jq -r '.credentials[] | select(.component == "AAP") | .password' <<<"$include_inventory")" = "aap-password" ]
[ "$(jq -r '.credentials[] | select(.component == "AAP") | .password' <<<"$redacted_inventory")" = "******" ]
[ "$(jq -r '.credentials[] | select(.component == "AAP") | .password' <<<"$omitted_inventory")" = "null" ]
[ "$(jq -r '.credentials[] | select(.component == "OpenShift") | .password' <<<"$include_inventory")" = "kubeadmin-fixture" ]
[ "$(jq -r '.credentials[] | select(.component == "OpenShift") | .password' <<<"$redacted_inventory")" = "******" ]
[ "$(jq -r '.credentials[] | select(.component == "OpenShift") | .password' <<<"$omitted_inventory")" = "null" ]
jq -e '.routes | any(.name == "oauth-openshift" and .url == "https://oauth-openshift.apps-crc.testing")' <<<"$omitted_inventory" >/dev/null
jq -e '.routes | any(.namespace == "openshift-console" and .name == "console" and .url == "https://console-openshift-console.apps-crc.testing")' <<<"$omitted_inventory" >/dev/null
jq -e '.routes | all(.namespace != "openshift-monitoring")' <<<"$omitted_inventory" >/dev/null

MOCK_OPENSHIFT=false
[ "$(_aap_demo_inventory_openshift_credential include)" = null ]
jq -e 'all(.component != "OpenShift")' <<<"$(_aap_demo_inventory_credentials include)" >/dev/null
jq -e 'all(.name != "oauth-openshift")' <<<"$(_aap_demo_inventory_routes)" >/dev/null
jq -e 'all(.namespace != "openshift-console")' <<<"$(_aap_demo_inventory_routes)" >/dev/null
unset MOCK_OPENSHIFT

MOCK_SATELLITE_STATE=running
jq -e 'any(.name == "satellite" and .url == "https://satellite.demo.lab" and .admitted and .external)' \
  <<<"$(_aap_demo_inventory_routes "mcp-server ao")" >/dev/null
jq -e '.name == "satellite-lab" and .ready and .external' \
  <<<"$(_aap_demo_inventory_external_namespaces "")" >/dev/null
MOCK_SATELLITE_HTTPS=false
jq -e '.name == "satellite" and (.admitted | not)' \
  <<<"$(_aap_demo_inventory_external_routes "")" >/dev/null
MOCK_SATELLITE_STATE="shut off"
[ -z "$(_aap_demo_inventory_external_routes "")" ]
jq -e '.name == "satellite-lab" and (.ready | not)' \
  <<<"$(_aap_demo_inventory_external_namespaces "")" >/dev/null
unset MOCK_SATELLITE_STATE MOCK_SATELLITE_HTTPS
[ -z "$(_aap_demo_inventory_external_routes "satellite-manifest")" ]
[ -z "$(_aap_demo_inventory_external_namespaces "satellite-manifest")" ]

mv "$HOME/.crc/machines/crc/kubeadmin-password" "$TEST_DIR/saved-password"
missing_credential=$(_aap_demo_inventory_openshift_credential include 2>"$TEST_DIR/password-warning")
jq -e '.username == "kubeadmin" and .password == null' <<<"$missing_credential" >/dev/null
grep -q 'kubeadmin password unavailable' "$TEST_DIR/password-warning"
mv "$TEST_DIR/saved-password" "$HOME/.crc/machines/crc/kubeadmin-password"

if MOCK_OAUTH_FAILURE=true _aap_demo_inventory_credentials include >"$TEST_DIR/failed-credentials" 2>"$TEST_DIR/oauth-error"; then
  echo "OAuth discovery failure was not propagated" >&2
  exit 1
fi
[ ! -s "$TEST_DIR/failed-credentials" ]
grep -q 'Unable to discover the OpenShift OAuth route' "$TEST_DIR/oauth-error"

(
  # shellcheck source=../includes/cmd-status.sh
  source "$REPO_ROOT/includes/cmd-status.sh"
  setup_kubeconfig() { :; }
  get_ingress_ca_cert_path() { printf '%s/missing-ca' "$TEST_DIR"; }
  ingress_ca_trust_status() { :; }
  persistent_crio_store_status() { :; }
  kubectl() {
    case "$*" in
      "get ns --no-headers -o custom-columns=:metadata.name") printf 'aap-operator\n' ;;
      "get pods -n aap-operator --no-headers") printf 'aap-pod 1/1 Running\n' ;;
      "get aap -n aap-operator --no-headers" | "get secret -n automation-orchestrator -o name") return 0 ;;
      "get aap -A --no-headers") printf 'aap-operator aap\n' ;;
      "get aap -n aap-operator -o jsonpath={.items[0].status.adminPasswordSecret}") printf 'aap-admin-password' ;;
      "get secret -n aap-operator aap-admin-password -o jsonpath={.data.password}")
        _mock_inventory_kubectl get secret aap-admin-password -n aap-operator -o 'jsonpath={.data.password}'
        ;;
      "--request-timeout=5s get pods -A "*) return 0 ;;
      *) _mock_inventory_kubectl "$@" ;;
    esac
  }
  AVAILABLE_ADDONS=""
  SHOW_SECRETS=true
  revealed=$(cmd_status) || exit 1
  grep -q '^Routes:$' <<<"$revealed"
  grep -q '^  https://oauth-openshift.apps-crc.testing$' <<<"$revealed"
  grep -q '^  https://console-openshift-console.apps-crc.testing$' <<<"$revealed"
  awk '/^Credentials:$/ {credentials=1; next} credentials && /openshift: +kubeadmin \/ kubeadmin-fixture/ {found=1} END {exit !found}' <<<"$revealed"
  grep -q 'admin / aap-password' <<<"$revealed"
  SHOW_SECRETS=false
  hidden=$(cmd_status) || exit 1
  grep -q '^Credentials: hidden' <<<"$hidden"
  if grep -q 'kubeadmin-fixture\|aap-password' <<<"$hidden"; then
    echo "Normal status exposed credentials" >&2
    exit 1
  fi
) || {
  echo "OpenShift status route or credential output failed" >&2
  exit 1
}

[ "$(jq -r '.cluster.crc_ip' <<<"$include_inventory")" = "192.168.127.2" ]
[ "$(jq -r '.cluster.ssh.ssh_key' <<<"$include_inventory")" = /fixture/id_ed25519 ]
[ "$(jq -r '.cluster.ssh.ssh_port' <<<"$include_inventory")" = 2222 ]
[ "$(jq -r '.addons | join(",")' <<<"$include_inventory")" = "mcp-server,ao" ]
[ "$(jq -r '.namespaces[] | select(.name == "aap-operator") | .ready' <<<"$include_inventory")" = "true" ]
[ "$(jq -r '.storage.capacity_planning.actual_vm_disk_gib' <<<"$include_inventory")" = 50 ]
[ "$(jq -r '.storage.capacity_planning.actual_vm_used_gib' <<<"$include_inventory")" = 10 ]
[ "$(jq -r '.storage.capacity_planning.actual_vm_free_gib' <<<"$include_inventory")" = 40 ]
[ "$(jq -r '.storage.capacity_planning.configured_crc_disk_gib' <<<"$include_inventory")" = 160 ]
[ "$(jq -r '.storage.capacity_planning.recommended_vm_disk_gib' <<<"$include_inventory")" = 210 ]
[ "$(jq -r '.storage.capacity_planning.needs_rebuild' <<<"$include_inventory")" = true ]
[ "$(jq -r '.storage.capacity_planning.configured_not_applied' <<<"$include_inventory")" = true ]
[ "$(jq -r '.storage.capacity_planning.projected_vm_disk_gib.ollama' <<<"$include_inventory")" = 220 ]

MOCK_VM_VERSION=""
crc() {
  [ "$*" = version ] || return 1
  printf 'CRC version: 2.61.0\nOpenShift version: 4.22.14\n'
}
sno_vm=$(_aap_demo_inventory_vm)
jq -e '
  .openshift_version == "4.22.14"
  and .cpus == "8"
  and .memory == {used: "4Gi", total: "16Gi", available: "12Gi"}
  and .load == "0.1 0.2 0.3"
  and .disk == "10G/50G (20% used)"
  and .disk_gib == {size: 50, used: 10, free: 40}
' <<<"$sno_vm" >/dev/null
sno_storage=$(_aap_demo_inventory_storage "mcp-server ao" "$sno_vm")
[ "$(jq -r '.actual_vm_free_gib' <<<"$sno_storage")" = 40 ]
unset MOCK_VM_VERSION

unset CRC_DISK VM_DISK_SIZE
export INFRA_TYPE=crc
crc() {
  [ "$*" = "config get disk-size" ] || return 1
  printf 'disk-size : 120\n'
}
crc_storage=$(_aap_demo_inventory_storage "" '{"disk_gib":{}}')
[ "$(jq -r '.configured_crc_disk_gib' <<<"$crc_storage")" = 120 ]

crc() {
  printf 'disk-size : 120\n'
  return 1
}
crc_error_storage=$(_aap_demo_inventory_storage "" '{"disk_gib":{}}')
[ "$(jq -r '.configured_crc_disk_gib' <<<"$crc_error_storage")" = null ]
unavailable_access=$(_aap_demo_inventory_crc_access 2>"$TEST_DIR/crc-warning")
[ "$(jq -r '.crc_ip' <<<"$unavailable_access")" = null ]
grep -q 'CRC IP unavailable' "$TEST_DIR/crc-warning"

crc() {
  case "$*" in
    ip) printf '192.168.127.2\n' ;;
    "config get disk-size") printf 'disk-size : 120\n' ;;
    *) return 1 ;;
  esac
}

aap_demo_generate_system_info include markdown "$AAP_DEMO_SYSTEM_INFO_FILE" >/dev/null

report="$AAP_DEMO_SYSTEM_INFO_FILE"
[ -f "$report" ]
[ "$(stat -c '%a' "$report")" = "600" ]
grep -q 'aap.example.test' "$report"
grep -q 'ao.example.test' "$report"
grep -q 'aap-password' "$report"
grep -q 'ao-password' "$report"
grep -q 'oauth-openshift.apps-crc.testing' "$report"
grep -q 'kubeadmin-fixture' "$report"
grep -q 'llm-key-fixture' "$report"
grep -q 'crc_ip: `192.168.127.2`' "$report"
grep -q 'aap-demo ssh' "$report"
grep -q '/fixture/id_ed25519' "$report"
grep -q '10.43.1.2' "$report"
grep -q '10.42.0.3' "$report"
grep -q '80/TCP -> 8000' "$report"
grep -q 'AAP MCP OAuth token: Generated for client configuration but not persisted' "$report"

redacted_report=$(aap_demo_generate_system_info redact markdown -)
grep -q '\*\*\*\*\*\*' <<<"$redacted_report"
if grep -q 'aap-password\|ao-password\|kubeadmin-fixture\|llm-key-fixture' <<<"$redacted_report"; then
  echo "Redacted report exposed a secret" >&2
  exit 1
fi

aap_demo_generate_system_info >/dev/null
if grep -q 'aap-password\|ao-password\|kubeadmin-fixture\|llm-key-fixture' "$AAP_DEMO_SYSTEM_INFO_FILE"; then
  echo "Default system-information report exposed a secret" >&2
  exit 1
fi

json_report="$TEST_DIR/docs/aap-demo-system-info.json"
aap_demo_generate_system_info redact json "$json_report" >/dev/null
jq -e '.schema_version == 1 and .secret_mode == "redact"' "$json_report" >/dev/null
[ "$(stat -c '%a' "$json_report")" = "600" ]

deploy_function=$(sed -n '/^cmd_deploy()/,/^}$/p' "$REPO_ROOT/aap-demo.sh")
redeploy_function=$(sed -n '/^cmd_redeploy()/,/^}$/p' "$REPO_ROOT/aap-demo.sh")
redeploy_all_function=$(sed -n '/^cmd_redeploy-all()/,/^}$/p' "$REPO_ROOT/aap-demo.sh")
grep -q 'aap_demo_generate_system_info' <<<"$deploy_function"
grep -q 'aap_demo_generate_system_info redact' <<<"$deploy_function"
grep -q 'aap_demo_generate_system_info redact' <<<"$redeploy_function"
grep -q 'aap_demo_generate_system_info redact' <<<"$redeploy_all_function"
grep -q 'workflow_phase system-info aap_demo_generate_system_info redact' "$REPO_ROOT/aap-demo.sh"
grep -q '^/docs/aap-demo-system-info\.md$' "$REPO_ROOT/.gitignore"
grep -q '^/docs/aap-demo-system-info\.json$' "$REPO_ROOT/.gitignore"

echo "✓ system_info_document_contains_expected_details"
