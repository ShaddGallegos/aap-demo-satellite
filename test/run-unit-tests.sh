#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0
TOTAL=0

run_test() {
  local runner="$1"
  local test_file="$2"
  local test_root

  TOTAL=$((TOTAL + 1))
  printf '\n==> %s\n' "$(basename "$test_file")"
  test_root=$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-unit.XXXXXX") || {
    echo "  FAILED: could not create an isolated test directory" >&2
    FAILED=$((FAILED + 1))
    return
  }
  mkdir -p "$test_root/home" "$test_root/config" "$test_root/cache" "$test_root/state"
  local socket_supported=true
  if ! python3 -c 'import socket; socket.socket().close()' >/dev/null 2>&1; then
    socket_supported=false
  fi
  # Per-test timeout so a single hanging test cannot stall the whole suite.
  # AAP_DEMO_TEST_TIMEOUT overrides the default (seconds).
  # Never let a non-live test inherit the user's Vault, kubeconfig, aap-demo
  # state, or XDG state.  Unset the aap-demo path overrides so code defaults
  # beneath this test's HOME; fixtures that exercise custom locations set their
  # own overrides explicitly.
  if ! env -u AAP_DEMO_DIR -u AAP_DEMO_CONFIG \
    HOME="$test_root/home" \
    XDG_CONFIG_HOME="$test_root/config" \
    XDG_CACHE_HOME="$test_root/cache" \
    XDG_STATE_HOME="$test_root/state" \
    KUBECONFIG="$test_root/kubeconfig" \
    AAP_DEMO_ALLOW_REMOTE_KUBECONFIG=false \
    AAP_DEMO_TEST_SOCKET_SUPPORTED="$socket_supported" \
    timeout "${AAP_DEMO_TEST_TIMEOUT:-120}" "$runner" "$test_file"; then
    FAILED=$((FAILED + 1))
    echo "  FAILED or timed out: $(basename "$test_file")" >&2
  fi
  rm -rf -- "$test_root"
}

for test_file in "$TEST_DIR"/test-*.sh; do
  case "$(basename "$test_file")" in
    # Live tests require a running cluster with the addon deployed.
    test-live-idempotency.sh | test-keycloak-live.sh | test-ai-integrations-live.sh) continue ;;
  esac
  run_test bash "$test_file"
done

for test_file in "$TEST_DIR"/test-*.py; do
  case "$(basename "$test_file")" in
    test-ao-live-smoke.py) continue ;;
  esac
  run_test python3 "$test_file"
done

echo ""
echo "Unit test files: $((TOTAL - FAILED)) passed, $FAILED failed, $TOTAL total"
[ "$FAILED" -eq 0 ]
