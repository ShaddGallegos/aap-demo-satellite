#!/usr/bin/env bash
# The non-live runner must isolate all persistent aap-demo and user state.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/test/run-unit-tests.sh"

grep -Fq 'HOME="$test_root/home"' "$RUNNER"
grep -Fq 'XDG_CONFIG_HOME="$test_root/config"' "$RUNNER"
grep -Fq 'env -u AAP_DEMO_DIR -u AAP_DEMO_CONFIG' "$RUNNER"
grep -Fq 'KUBECONFIG="$test_root/kubeconfig"' "$RUNNER"
grep -Fq 'AAP_DEMO_ALLOW_REMOTE_KUBECONFIG=false' "$RUNNER"
grep -Fq 'AAP_DEMO_TEST_SOCKET_SUPPORTED="$socket_supported"' "$RUNNER"

echo "PASS: non-live unit runner isolates user, aap-demo, and Kubernetes state per test"
