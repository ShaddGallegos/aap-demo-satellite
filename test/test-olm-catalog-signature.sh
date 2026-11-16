#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=../includes/olm-catalog-signature.sh
source "$REPO_ROOT/includes/olm-catalog-signature.sh"

PRESET=openshift
kubectl() {
  printf '%s\n' "$*" >>"$TEST_DIR/kubectl.log"
  case "$*" in
    'get ingresses.config/cluster --ignore-not-found --request-timeout=5s -o name')
      case "$PRESET" in
        openshift) printf 'ingress.config.openshift.io/cluster\n' ;;
        microshift) ;;
        unavailable) return 1 ;;
      esac
      ;;
    *) echo "Unexpected kubectl call: $*" >&2; return 1 ;;
  esac
}
needs_signature_policy_relaxation() { return 0; }
_ensure_crc_ssh_ready() { echo ssh >>"$TEST_DIR/actions"; return 1; }

maybe_relax_redhat_registry_signature_policy >"$TEST_DIR/output"
grep -q 'MCO-managed; leaving it unchanged' "$TEST_DIR/output"
[ ! -e "$TEST_DIR/actions" ]
PRESET=unavailable
if maybe_relax_redhat_registry_signature_policy >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: preset detection failure was ignored" >&2
  exit 1
fi
[ ! -e "$TEST_DIR/actions" ]
PRESET=microshift
if maybe_relax_redhat_registry_signature_policy >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: missing MicroShift SSH access was ignored" >&2
  exit 1
fi
[ "$(cat "$TEST_DIR/actions")" = ssh ]

(
  export AAP_DEMO_CONFIGURE_COREDNS_ONLY=1
  _INFRA_API_LOADED=""
  INFRA_TYPE=crc
  source "$REPO_ROOT/includes/crc-create.sh"
  kubectl() {
    printf '%s\n' "$*" >>"$TEST_DIR/coredns.log"
    [ "$*" = "get ingresses.config/cluster --request-timeout=5s" ]
  }
  : >"$TEST_DIR/coredns.log"
  configure_coredns >"$TEST_DIR/coredns-output"
  grep -q 'OpenShift DNS is operator-managed' "$TEST_DIR/coredns-output"
  [ "$(cat "$TEST_DIR/coredns.log")" = 'get ingresses.config/cluster --request-timeout=5s' ]
)

echo "PASS: full OpenShift preserves MCO-owned policy and operator-owned CoreDNS"
