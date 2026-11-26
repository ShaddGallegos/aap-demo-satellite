#!/usr/bin/env bash
# Unit tests for managed SSH trust policy; no SSH service is required.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=../includes/ssh-trust.sh
source "$ROOT/includes/ssh-trust.sh"

assert() { "$@" || {
  echo "FAIL: $*" >&2
  exit 1
}; }

AAP_DEMO_SSH_TRUST_MODE=tofu
unset AAP_DEMO_SSH_FINGERPRINTS
assert aap_demo_ssh_prepare_trust "$TEST_DIR/tofu/known_hosts" 127.0.0.1 2222
[[ " ${AAP_DEMO_SSH_TRUST_OPTS[*]} " == *' StrictHostKeyChecking=accept-new '* ]]

AAP_DEMO_SSH_TRUST_MODE=strict
if aap_demo_ssh_prepare_trust "$TEST_DIR/strict/known_hosts" 127.0.0.1 2222; then
  echo 'FAIL: strict mode accepted an unknown host' >&2
  exit 1
fi

AAP_DEMO_SSH_TRUST_MODE=verify
unset AAP_DEMO_SSH_FINGERPRINTS
if aap_demo_ssh_prepare_trust "$TEST_DIR/verify/known_hosts" 127.0.0.1 2222; then
  echo 'FAIL: verified mode accepted a missing fingerprint' >&2
  exit 1
fi

echo 'PASS: managed SSH trust defaults to isolated TOFU and supports strict fingerprint verification'
