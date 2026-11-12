#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=../addons/satellite-manifest/deploy.sh
source "$REPO_ROOT/addons/satellite-manifest/deploy.sh"
LOG="$TEST_DIR/calls"
POOLS="$TEST_DIR/pools"
ATTACHED="$TEST_DIR/attached"

fail() { echo "FAIL: $*" >&2; exit 1; }

reset_case() {
  : >"$LOG"
  printf '%s' '{"body":{"entitlementsAttached":{"value":[]}}}' >"$ATTACHED"
  cat >"$POOLS" <<'EOF'
[
  {"id":"sat","subscriptionName":"Red Hat Satellite Infrastructure Subscription","entitlementsAvailable":1},
  {"id":"rhel","subscriptionName":"Red Hat Enterprise Linux Server, Premium","entitlementsAvailable":-1},
  {"id":"other","subscriptionName":"Red Hat Ansible Automation Platform","entitlementsAvailable":100},
  {"id":"els","subscriptionName":"Red Hat Enterprise Linux Server - Extended Life Cycle Support","entitlementsAvailable":1}
]
EOF
  DENIED=false
  ATTACH_FAIL=false
  VERIFY_FAIL=false
  PAGINATE=false
  ALLOCATION_EXISTS=true
}

_rhsm_api() {
  local method="$1" path="$2"
  printf '%s %s\n' "$method" "$path" >>"$LOG"
  if [ "$DENIED" = true ]; then
    printf '403\n{}'
    return
  fi
  case "$method $path" in
    "GET /allocations?offset=0&limit=100")
      if [ "$ALLOCATION_EXISTS" = true ]; then
        printf '200\n{"body":[{"name":"aap-demo-satellite","uuid":"lab"}]}'
      else
        printf '200\n{"body":[]}'
      fi
      ;;
    "POST /allocations")
      printf '201\n{"body":{"uuid":"lab"}}'
      ;;
    "GET /allocations/lab/pools?offset=0&limit=50")
      if [ "$PAGINATE" = true ]; then
        python3 -c 'import json; print("200\n" + json.dumps({"body": [
            {"id": str(i), "subscriptionName": "Unrelated", "entitlementsAvailable": 1}
            for i in range(50)]}))'
      else
        printf '200\n{"body":%s}' "$(cat "$POOLS")"
      fi
      ;;
    "GET /allocations/lab/pools?offset=50&limit=50")
      printf '200\n{"body":%s}' "$(cat "$POOLS")"
      ;;
    "GET /allocations/lab?include=entitlements")
      printf '200\n%s' "$(cat "$ATTACHED")"
      ;;
    "POST /allocations/lab/entitlements?pool="*)
      if [ "$ATTACH_FAIL" = true ]; then
        printf '400\n{}'
        return
      fi
      if [ "$VERIFY_FAIL" != true ]; then
        python3 - "$path" "$POOLS" "$ATTACHED" <<'PY'
import json
import sys
from urllib.parse import parse_qs, urlsplit

pool_id = parse_qs(urlsplit(sys.argv[1]).query)["pool"][0]
with open(sys.argv[2]) as stream:
    pool = next(pool for pool in json.load(stream) if pool["id"] == pool_id)
with open(sys.argv[3]) as stream:
    data = json.load(stream)
data["body"]["entitlementsAttached"]["value"].append(
    {"subscriptionName": pool["subscriptionName"], "entitlementQuantity": 1}
)
with open(sys.argv[3], "w") as stream:
    json.dump(data, stream)
PY
      fi
      printf '200\n{}'
      ;;
    *) fail "unexpected API request: $method $path" ;;
  esac
}

_satellite_manifest_export() { printf 'export\n' >>"$LOG"; }
_satellite_manifest_download() { printf 'download\n' >>"$LOG"; printf '%s' "$TEST_DIR/manifest.zip"; }

reset_case
ALLOCATION_EXISTS=false
main >"$TEST_DIR/output"
grep -Fxq 'POST /allocations' "$LOG"
grep -Fxq 'POST /allocations/lab/entitlements?pool=sat&quantity=1' "$LOG"
grep -Fxq 'POST /allocations/lab/entitlements?pool=rhel&quantity=1' "$LOG"
[ "$(grep -c '/entitlements?pool=' "$LOG")" -eq 2 ]
[ "$(tail -2 "$LOG")" = "$(printf 'export\ndownload')" ]

# Reusing the allocation must not consume any more subscription quantity.
: >"$LOG"
ALLOCATION_EXISTS=true
main >"$TEST_DIR/output"
if grep -q '^POST ' "$LOG"; then fail "rerun attached duplicate entitlements"; fi
grep -Fxq export "$LOG"

reset_case
PAGINATE=true
main >"$TEST_DIR/output"
grep -Fxq 'GET /allocations/lab/pools?offset=50&limit=50' "$LOG"

reset_case
cat >"$POOLS" <<'EOF'
[
  {"id":"sat","subscriptionName":"Red Hat Satellite Infrastructure Subscription","entitlementsAvailable":1},
  {"id":"rhel","subscriptionName":"Red Hat Enterprise Linux Server, Premium","entitlementsAvailable":1},
  {"id":"rhel2","subscriptionName":"Red Hat Enterprise Linux for Virtual Datacenters, Premium","entitlementsAvailable":1}
]
EOF
if main >"$TEST_DIR/output" 2>&1; then fail "ambiguous pools accepted"; fi
grep -Fq 'Expected one eligible RHEL server pool; found 2' "$TEST_DIR/output"
if grep -qE '^POST |^export$' "$LOG"; then fail "ambiguous plan mutated allocation or exported"; fi

reset_case
printf '%s' '[{"id":"sat","subscriptionName":"Red Hat Satellite Infrastructure Subscription","entitlementsAvailable":0}]' >"$POOLS"
if main >"$TEST_DIR/output" 2>&1; then fail "exhausted pools accepted"; fi
if grep -qE '^POST |^export$' "$LOG"; then fail "exhausted plan mutated allocation or exported"; fi

reset_case
DENIED=true
if main >"$TEST_DIR/output" 2>&1; then fail "permission failure accepted"; fi
grep -Fq 'HTTP 401/403' "$TEST_DIR/output"
if grep -qE '^POST |^export$' "$LOG"; then fail "permission failure continued"; fi

reset_case
ATTACH_FAIL=true
if main >"$TEST_DIR/output" 2>&1; then fail "attachment failure accepted"; fi
grep -Fq 'Attaching subscription pool sat failed (HTTP 400)' "$TEST_DIR/output"
if grep -Fxq export "$LOG"; then fail "exported after attachment failed"; fi

reset_case
VERIFY_FAIL=true
if main >"$TEST_DIR/output" 2>&1; then fail "unverified attachments accepted"; fi
if grep -Fxq export "$LOG"; then fail "exported unverified subscriptions"; fi

reset_case
printf '%s' '{}' >"$ATTACHED"
if main >"$TEST_DIR/output" 2>&1; then fail "malformed allocation accepted"; fi
if grep -qE '^POST |^export$' "$LOG"; then fail "malformed response mutated allocation or exported"; fi

# A partial previous run must reuse its successful attachment.
reset_case
printf '%s' '{"body":{"entitlementsAttached":{"value":[{"subscriptionName":"Red Hat Satellite Infrastructure Subscription","entitlementQuantity":3}]}}}' >"$ATTACHED"
main >"$TEST_DIR/output"
[ "$(grep -c '/entitlements?pool=' "$LOG")" -eq 1 ]
grep -Fxq 'POST /allocations/lab/entitlements?pool=rhel&quantity=1' "$LOG"

# Test the builder's manifest-only path without SSH, sudo, Vault or RHSM calls.
# shellcheck source=../satellite-lab/build-and-configure.sh
source "$REPO_ROOT/satellite-lab/build-and-configure.sh"
MANIFEST="$TEST_DIR/manifest.zip"
MANIFEST_DIR="$TEST_DIR"
printf 'stale manifest' >"$MANIFEST"
_MANIFEST_PROVIDED=""
_sat_vm_exists() { fail "manifest-only tried to provision"; }
_stage_network() { fail "manifest-only tried to change networking"; }
bash() {
  printf 'addon %s\n' "$*" >>"$LOG"
  [ "${BUILD_ADDON_FAIL:-false}" != true ] || return 1
  printf 'fresh manifest' >"$MANIFEST"
}
mock_scp() { printf 'scp %s\n' "$*" >>"$LOG"; }
mock_ssh() {
  printf 'ssh %s\n' "$*" >>"$LOG"
  cat >"$TEST_DIR/import-payload"
  [ "${IMPORT_FAIL:-false}" != true ]
}
SAT_SCP=mock_scp
SAT_SSH=mock_ssh
: >"$LOG"
main --manifest-only >"$TEST_DIR/output"
grep -Fq 'enable satellite-manifest' "$LOG"
grep -Fq 'hammer subscription upload --organization "$org"' "$TEST_DIR/import-payload"
bash -n "$TEST_DIR/import-payload"
[ "$(cat "$MANIFEST")" = 'fresh manifest' ]

: >"$LOG"
if BUILD_ADDON_FAIL=true main --manifest-only >"$TEST_DIR/output" 2>&1; then
  fail "builder accepted addon failure"
fi
if grep -q '^scp ' "$LOG"; then fail "builder uploaded stale manifest after addon failure"; fi

if IMPORT_FAIL=true main --manifest-only >"$TEST_DIR/output" 2>&1; then
  fail "builder accepted import failure"
fi

: >"$LOG"
_MANIFEST_PROVIDED=true
main --manifest-only >"$TEST_DIR/output"
if grep -q '^addon ' "$LOG"; then fail "builder regenerated an explicitly supplied manifest"; fi

MANIFEST="$TEST_DIR/missing.zip"
if main --manifest-only >"$TEST_DIR/output" 2>&1; then
  fail "builder accepted a missing supplied manifest"
fi

# Failed refreshes must preserve the previous private manifest.
download_function=$(sed -n '/^_satellite_manifest_download() {/,/^}$/p' \
  "$REPO_ROOT/addons/satellite-manifest/deploy.sh")
eval "$download_function"
fleet_redhat_access_token() { printf 'test-token'; }
curl() {
  local dest=""
  cat >/dev/null
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then
      dest="$2"
      break
    fi
    shift
  done
  [ -n "$dest" ] || fail "download destination missing"
  [ "$(stat -c %a "$dest")" = 600 ] || fail "manifest was not private during download"
  printf 'new manifest' >"$dest"
  printf '%s' "${DOWNLOAD_CODE:-200}"
}
MANIFEST_DIR="$TEST_DIR"
printf 'previous manifest' >"$TEST_DIR/manifest.zip"
if DOWNLOAD_CODE=500 _satellite_manifest_download >"$TEST_DIR/output" 2>&1; then
  fail "HTTP failure accepted during download"
fi
[ "$(cat "$TEST_DIR/manifest.zip")" = 'previous manifest' ]
_satellite_manifest_download >"$TEST_DIR/output"
[ "$(cat "$TEST_DIR/manifest.zip")" = 'new manifest' ]
[ "$(stat -c %a "$TEST_DIR/manifest.zip")" = 600 ]

echo "PASS: Satellite subscriptions attach conservatively and full-demo refreshes/imports the manifest"
