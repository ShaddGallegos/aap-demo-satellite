#!/usr/bin/env bash
# Regression tests for the private local support-bundle collector.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

# shellcheck source=../includes/support-bundle.sh
source "$ROOT/includes/support-bundle.sh"
aap_demo_version_short() { printf 'test-version'; }
aap_demo_generate_system_info() {
  local _mode="$1" format="$2" output="$3"
  case "$format" in
    markdown) printf '# Redacted report\npassword: ******\n' >"$output" ;;
    json) printf '{"secret_mode":"redact","password":"******"}\n' >"$output" ;;
  esac
}

preview=$(aap_demo_support_bundle_preview)
grep -Fq 'Excluded:  Vault files' <<<"$preview"
grep -Fq 'all external uploads' <<<"$preview"

bundle="$TEST_DIR/support-bundle"
aap_demo_support_bundle_create "$bundle" >/dev/null
test -d "$bundle"
test "$(stat -c '%a' "$bundle")" = 700
test "$(stat -c '%a' "$bundle/manifest.json")" = 600
jq -e '.schema_version == 1 and .redacted and .local_only and (.files | length == 3)' \
  "$bundle/manifest.json" >/dev/null
if grep -ERq -- 'private-key|password:[[:space:]]+[^*[:space:]]' "$bundle"; then
  echo 'FAIL: support bundle retained unsafe evidence' >&2
  exit 1
fi
if aap_demo_support_bundle_create "$bundle" >/dev/null 2>&1; then
  echo 'FAIL: support bundle replaced an existing destination' >&2
  exit 1
fi

aap_demo_generate_system_info() {
  printf 'token: leaked-value\n' >"$3"
}
unsafe="$TEST_DIR/unsafe"
if aap_demo_support_bundle_create "$unsafe" >/dev/null 2>&1; then
  echo 'FAIL: support bundle accepted secret-shaped evidence' >&2
  exit 1
fi
test ! -e "$unsafe"

echo 'PASS: support bundles are previewable, private, redacted, offline-scanned, and never overwritten'
