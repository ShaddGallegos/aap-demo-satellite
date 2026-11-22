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
    'api-resources -o name --request-timeout=5s')
      case "$PRESET" in
        openshift) printf 'nodes\nroutes.route.openshift.io\ningresses.config.openshift.io\n' ;;
        microshift | wrong_guest | ssh_failure) printf 'nodes\nroutes.route.openshift.io\n' ;;
        incomplete) printf 'nodes\n' ;;
        unavailable)
          echo 'API discovery failed' >&2
          return 1
          ;;
      esac
      ;;
    *)
      echo "Unexpected kubectl call: $*" >&2
      return 1
      ;;
  esac
}
needs_signature_policy_relaxation() { return 0; }
CRC_SSH_PORT=2222
CRC_SSH_OPTS=()
_ensure_crc_ssh_ready() { [ "$PRESET" != ssh_failure ]; }
ssh() {
  case "${*: -1}" in
    'systemctl is-active --quiet microshift')
      [ "$PRESET" != wrong_guest ]
      ;;
    *)
      echo policy >>"$TEST_DIR/actions"
      printf 'CHANGED\n'
      ;;
  esac
}
_reload_crio_on_crc_vm() { echo reload >>"$TEST_DIR/actions"; }

maybe_relax_redhat_registry_signature_policy >"$TEST_DIR/output"
grep -q 'MCO-managed; leaving it unchanged' "$TEST_DIR/output"
[ ! -e "$TEST_DIR/actions" ]
PRESET=unavailable
if maybe_relax_redhat_registry_signature_policy >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: preset detection failure was ignored" >&2
  exit 1
fi
[ ! -e "$TEST_DIR/actions" ]
PRESET=incomplete
if maybe_relax_redhat_registry_signature_policy >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: incomplete API discovery was ignored" >&2
  exit 1
fi
[ ! -e "$TEST_DIR/actions" ]
PRESET=wrong_guest
if maybe_relax_redhat_registry_signature_policy >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: non-MicroShift guest was accepted" >&2
  exit 1
fi
[ ! -e "$TEST_DIR/actions" ]
PRESET=ssh_failure
if maybe_relax_redhat_registry_signature_policy >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: missing MicroShift SSH access was ignored" >&2
  exit 1
fi
[ ! -e "$TEST_DIR/actions" ]
PRESET=microshift
maybe_relax_redhat_registry_signature_policy >"$TEST_DIR/output"
[ "$(cat "$TEST_DIR/actions")" = "$(printf 'policy\nreload')" ]
grep -q 'Relaxed container signature policy' "$TEST_DIR/output"

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
