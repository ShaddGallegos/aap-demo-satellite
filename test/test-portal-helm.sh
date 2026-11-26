#!/usr/bin/env bash
# Regression tests for the Portal addon's Helm detection and auto-install path.
# shellcheck disable=SC2218  # helm helpers are loaded from the deployment script.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_SCRIPT="${REPO_ROOT}/addons/portal/deploy.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

MOCK_BIN="${TEST_DIR}/home/.local/bin"
mkdir -p "${MOCK_BIN}" "${TEST_DIR}/home"
export HOME="${TEST_DIR}/home"
export PATH="${MOCK_BIN}:/usr/bin:/bin"

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

write_mock_helm() {
  local version="$1"
  cat >"${MOCK_BIN}/helm" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = version ]; then
  printf '%s\\n' "${version}"
else
  exit 0
fi
EOF
  chmod +x "${MOCK_BIN}/helm"
}

rm -f "${MOCK_BIN}/helm"

# shellcheck source=/dev/null
source "${DEPLOY_SCRIPT}"

printf '%s\n' 'test ingress CA' >"${TEST_DIR}/ingress-ca.crt"
AAP_API_CA_FILE="${TEST_DIR}/ingress-ca.crt"
curl() { printf '%s\n' "$*" >"${TEST_DIR}/aap-api-curl.args"; }
if configure_aap_api_tls \
  && aap_api_curl --fail --silent https://aap.example.test/api/gateway/v1/ping/ \
  && grep -Fq -- "--cacert ${AAP_API_CA_FILE}" "${TEST_DIR}/aap-api-curl.args"; then
  pass "uses_trusted_ca_for_aap_api_requests"
else
  fail "uses_trusted_ca_for_aap_api_requests"
fi
unset -f curl

if rg -q 'curl -k' "${DEPLOY_SCRIPT}"; then
  fail "does_not_disable_aap_api_tls_verification"
else
  pass "does_not_disable_aap_api_tls_verification"
fi

write_mock_helm 'v3.10.0+g123456'
if helm_version_ok; then
  pass "accepts_minimum_supported_helm"
else
  fail "accepts_minimum_supported_helm"
fi

write_mock_helm 'v3.9.9+g123456'
if ! helm_version_ok; then
  pass "rejects_old_helm"
else
  fail "rejects_old_helm"
fi

write_mock_helm 'v4.0.0+g123456'
if helm_version_ok; then
  pass "accepts_newer_helm"
else
  fail "accepts_newer_helm"
fi

rm -f "${MOCK_BIN}/helm"
INSTALL_CALLED=false
HELM_CHECKS=0
helm_version_ok() {
  HELM_CHECKS=$((HELM_CHECKS + 1))
  [ "${HELM_CHECKS}" -gt 1 ]
}
install_helm_binary() {
  INSTALL_CALLED=true
  write_mock_helm 'v3.21.4+gabcdef'
}

if ensure_helm >/dev/null 2>&1 \
  && [ "${INSTALL_CALLED}" = true ] \
  && [ "${HELM_CHECKS}" -eq 2 ]; then
  pass "auto_installs_when_helm_is_missing"
else
  fail "auto_installs_when_helm_is_missing"
fi

rm -f "${MOCK_BIN}/helm"
if (
  source "${DEPLOY_SCRIPT}"
  brew() {
    if [ "${1:-}" = list ]; then
      return 1
    fi
    if [ "${1:-}" = install ] && [ "${2:-}" = helm ]; then
      write_mock_helm 'v4.0.0+g123456'
      return 0
    fi
    return 1
  }
  uname() { printf '%s\n' Darwin; }
  install_helm_binary >/dev/null 2>&1 && helm_version_ok
); then
  pass "installs_missing_helm_with_homebrew_on_macos"
else
  fail "installs_missing_helm_with_homebrew_on_macos"
fi

uname() {
  printf '%s\n' riscv64
}
if detect_arch >/dev/null 2>&1; then
  fail "rejects_unknown_local_architecture"
else
  pass "rejects_unknown_local_architecture"
fi
unset -f uname

kubectl() {
  printf '%s' s390x
}
if resolve_portal_profile >/dev/null 2>&1; then
  fail "rejects_unknown_cluster_architecture"
else
  pass "rejects_unknown_cluster_architecture"
fi
unset -f kubectl

PORTAL_DIR="${TEST_DIR}/portal"
mkdir -p "$PORTAL_DIR"
CLUSTER_BASE_URL="apps.example.test"
IS_ARM_CLUSTER=false
PORTAL_LIGHTSPEED=false
create_helm_values >/dev/null
if ! grep -q 'aap-demo-portal-lightspeed' "$PORTAL_DIR/values.yaml"; then
  pass "keeps_portal_ai_opt_in"
else
  fail "keeps_portal_ai_opt_in"
fi

PORTAL_LIGHTSPEED=true
kubectl() {
  case "$*" in
    "get svc ollama "*) return 0 ;;
    "apply -f -") cat >"${TEST_DIR}/lightspeed-secret.json" ;;
    *) echo "Unexpected kubectl: $*" >&2; return 91 ;;
  esac
}
if validate_portal_lightspeed && configure_portal_lightspeed; then
  create_helm_values >/dev/null
  if jq -e '.stringData.ENABLE_OLLAMA == "true" and
    .stringData.OLLAMA_URL == "http://ollama.aap-demo-ollama.svc.cluster.local:11434/v1"
    ' "${TEST_DIR}/lightspeed-secret.json" >/dev/null \
    && grep -q '^  lightspeed:$' "$PORTAL_DIR/values.yaml" \
    && grep -q '^      name: aap-demo-portal-lightspeed$' "$PORTAL_DIR/values.yaml"; then
    pass "configures_native_portal_lightspeed_with_local_ollama"
  else
    fail "configures_native_portal_lightspeed_with_local_ollama"
  fi
else
  fail "configures_native_portal_lightspeed_with_local_ollama"
fi
IS_ARM_CLUSTER=true
if validate_portal_lightspeed >/dev/null 2>&1; then
  fail "rejects_unvalidated_arm_ai_profile"
else
  pass "rejects_unvalidated_arm_ai_profile"
fi
IS_ARM_CLUSTER=false
kubectl() { return 1; }
if validate_portal_lightspeed >/dev/null 2>&1; then
  fail "requires_local_ollama_for_portal_ai"
else
  pass "requires_local_ollama_for_portal_ai"
fi
if configure_portal_lightspeed >/dev/null 2>&1; then
  fail "propagates_portal_ai_secret_apply_failure"
else
  pass "propagates_portal_ai_secret_apply_failure"
fi
PORTAL_LIGHTSPEED=invalid
if validate_portal_lightspeed >/dev/null 2>&1; then
  fail "rejects_invalid_portal_ai_selection"
else
  pass "rejects_invalid_portal_ai_selection"
fi
unset -f kubectl

echo "Passed: ${PASSED}  Failed: ${FAILED}"
[ "${FAILED}" -eq 0 ]
