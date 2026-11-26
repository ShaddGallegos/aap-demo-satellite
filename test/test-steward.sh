#!/usr/bin/env bash
# Regression tests for the read-only operations steward foundation.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export AAP_DEMO_DIR="$TEST_DIR/state"
export AAP_DEMO_STEWARD_TRACKING_FILE="$TEST_DIR/FIX_TRACKING.md"
export SCRIPT_DIR="$ROOT"

# shellcheck source=../includes/steward.sh
source "$ROOT/includes/steward.sh"

cmd_preflight() {
  printf '%s\n' '  ✗ Kubernetes API is not reachable'
  printf '%s\n' 'Authorization: Bearer never-store-this-token'
  return 1
}

cmd_diagnose() {
  printf '%s\n' '  ⚠ Disk usage: 83%'
  printf '%s\n' 'password=never-store-this-password'
  return 0
}

cmd_check_integrations() {
  printf '%s\n' 'FAIL AO-to-MCP integration unavailable'
  printf '%s\n' 'https://user:never-store-this-url-password@example.test/path'
  return 1
}

cmd_steward scan >"$TEST_DIR/scan-output"

tracking="$AAP_DEMO_STEWARD_TRACKING_FILE"
state="$AAP_DEMO_DIR/steward/state.json"
reports="$AAP_DEMO_DIR/steward/reports"

[ -f "$tracking" ] && [ -f "$state" ] && [ -d "$reports" ]
[ "$(stat -c '%a' "$AAP_DEMO_DIR/steward")" = 700 ]
[ "$(stat -c '%a' "$state")" = 600 ]
[ "$(stat -c '%a' "$tracking")" = 600 ]
if find "$reports" -name '*.raw.*' -print -quit | grep -q .; then
  echo 'FAIL: steward left unredacted temporary evidence behind' >&2
  exit 1
fi

for needle in never-store-this-token never-store-this-password never-store-this-url-password; do
  if rg -q -- "$needle" "$tracking" "$state" "$reports"; then
    echo "FAIL: steward retained secret-shaped fixture: $needle" >&2
    exit 1
  fi
done

grep -Fq '<!-- aap-demo-steward: v1 -->' "$tracking"
grep -Fq 'Kubernetes API is not reachable' "$tracking"
grep -Fq 'Disk usage: 83%' "$tracking"
grep -Fq 'AO-to-MCP integration unavailable' "$tracking"
jq -e '[.issues[] | select(.status == "open")] | length == 3' "$state" >/dev/null

# A clean later scan preserves evidence of unfixed work as watch items.
cmd_preflight() { printf '%s\n' '  ✓ Kubernetes API reachable'; }
cmd_diagnose() { printf '%s\n' '  ✓ All AAP pods ready'; }
cmd_check_integrations() { printf '%s\n' 'PASS AO authenticated integration list read'; }

sleep 1
cmd_steward scan >/dev/null
jq -e '[.issues[] | select(.status == "watch")] | length == 3' "$state" >/dev/null
grep -Fq '## Watching' "$tracking"

# Never replace a user-owned file merely because it was selected as output.
printf '%s\n' '# user-owned' >"$TEST_DIR/user-owned.md"
if AAP_DEMO_STEWARD_TRACKING_FILE="$TEST_DIR/user-owned.md" cmd_steward report >/dev/null 2>&1; then
  echo 'FAIL: steward overwrote an unowned tracking file' >&2
  exit 1
fi
grep -Fxq '# user-owned' "$TEST_DIR/user-owned.md"

echo 'PASS: steward retains only redacted evidence and tracks unresolved findings safely'
