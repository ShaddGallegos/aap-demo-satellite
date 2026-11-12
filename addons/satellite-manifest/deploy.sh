#!/usr/bin/env bash
# satellite-manifest — create and download a Red Hat Satellite subscription
# manifest programmatically via the RHSM management API.
#
# Reuses the aap-demo credential Vault's Red Hat offline token (the same
# rhsm-api token the fleet addon uses for image downloads). The manifest is
# written to ~/.aap-demo/satellite/manifest.zip, ready for
# satellite-lab/03-content-hammer.sh.
#
# Usage:
#   aap-demo enable satellite-manifest            # create + download manifest
#   MANIFEST_SAT_VERSION=sat-6.17 aap-demo enable satellite-manifest
#   MANIFEST_NAME=my-lab aap-demo enable satellite-manifest
#
# Requires the Red Hat account to hold the "View/Renew Subscription
# Information" permission (console.redhat.com -> Settings -> User Access).
# Without it the RHSM allocations API returns 401 and this addon stops with
# guidance instead of a cryptic failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../includes/credential-vault.sh
source "${SCRIPT_DIR}/../../includes/credential-vault.sh"
# shellcheck source=../fleet/fleet-auth.sh
source "${SCRIPT_DIR}/../fleet/fleet-auth.sh"

MANIFEST_DIR="${MANIFEST_DIR:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/satellite}"
MANIFEST_NAME="${MANIFEST_NAME:-aap-demo-satellite}"
MANIFEST_SAT_VERSION="${MANIFEST_SAT_VERSION:-sat-6.17}"
RHSM_API_BASE="${RHSM_API_BASE:-https://api.access.redhat.com/management/v1}"

_err() { printf 'ERROR: %s\n' "$*" >&2; }

# Set by _rhsm_api on every call; initialized so `set -u` never trips on it.
RHSM_HTTP_CODE=""
MANIFEST_DOWNLOAD_URL=""

# --- RHSM API helpers -------------------------------------------------------

# _rhsm_api <method> <path> [curl-args...] — authenticated call. Prints the
# HTTP status on the first stdout line, then the response body. Callers split
# them from the captured output (a global would not survive the subshell).
_rhsm_api() {
  local method="$1" path="$2"
  shift 2
  local token
  token=$(fleet_redhat_access_token false) || {
    _err "No valid Red Hat offline token in the Vault. Run: aap-demo fleet auth"
    return 2
  }
  local response
  # Pass the token via a curl config file on stdin so it never appears in the
  # process list or shell tracing (matches the fleet addon's pattern).
  response=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl --config - --silent --show-error \
      --connect-timeout 15 --max-time 60 \
      --write-out '\n%{http_code}' \
      --request "$method" \
      --header "Accept: application/json" \
      "$@" \
      "${RHSM_API_BASE}${path}") || {
      _err "Unable to contact the Red Hat RHSM API"
      return 2
    }
  # First line: HTTP status. Remaining lines: body. (A global would not
  # survive the caller's command-substitution subshell.)
  printf '%s\n' "${response##*$'\n'}"
  printf '%s' "${response%$'\n'*}"
}

# Stop with actionable guidance when the account lacks the manifest permission.
_rhsm_require_permission() {
  case "${RHSM_HTTP_CODE:-}" in
    401 | 403)
      cat >&2 <<'EOF'
ERROR: The Red Hat account cannot use the subscription-manifest API (HTTP 401/403).

The offline token is valid, but the account lacks the
"View/Renew Subscription Information" permission required for manifest
management. Grant it, then re-run:

  1. console.redhat.com -> Settings (gear) -> User Access -> Users
  2. Edit your user -> add the Subscription Management /
     "View/Renew Subscription Information" role
  3. Re-run: aap-demo enable satellite-manifest

If you are the org admin and still see this, the account's subscriptions may
be managed under a different org, or the account needs Satellite entitlements.
EOF
      return 1
      ;;
  esac
  return 0
}

# --- Manifest workflow ------------------------------------------------------

_satellite_manifest_list() {
  local path="$1" limit="$2" offset=0 out body count
  local pages='[]'
  while true; do
    out=$(_rhsm_api GET "${path}?offset=${offset}&limit=${limit}") || return $?
    RHSM_HTTP_CODE="${out%%$'\n'*}"
    body="${out#*$'\n'}"
    _rhsm_require_permission || return 1
    [ "$RHSM_HTTP_CODE" = 200 ] || { _err "Listing ${path} failed (HTTP $RHSM_HTTP_CODE)"; return 1; }
    count=$(printf '%s' "$body" | python3 -c '
import json
import sys
data = json.load(sys.stdin)["body"]
if not isinstance(data, list):
    sys.exit("ERROR: RHSM list response body must be an array")
print(len(data))
') || return 1
    pages=$(printf '%s\n%s' "$pages" "$body" | python3 -c '
import json
import sys
pages = json.loads(sys.stdin.readline())
pages.extend(json.load(sys.stdin)["body"])
print(json.dumps(pages))
') || return 1
    [ "$count" -lt "$limit" ] && break
    offset=$((offset + count))
  done
  printf '%s' "$pages"
}

_satellite_manifest_find_allocation() {
  # Print the UUID of an existing allocation named MANIFEST_NAME, if any.
  local allocations
  allocations=$(_satellite_manifest_list "/allocations" 100) || return 1
  printf '%s' "$allocations" | MANIFEST_NAME="$MANIFEST_NAME" python3 -c '
import json
import os
import sys

name = os.environ["MANIFEST_NAME"]
matches = [alloc for alloc in json.load(sys.stdin) if alloc["name"] == name]
if len(matches) > 1:
    sys.exit("ERROR: Multiple RHSM allocations have the requested name; choose a unique MANIFEST_NAME")
if matches:
    print(matches[0]["uuid"])
'
}

_satellite_manifest_create_allocation() {
  # Progress to stderr: the caller captures this function's stdout as the UUID,
  # so anything printed to stdout would contaminate it.
  echo "▸ Creating subscription allocation '${MANIFEST_NAME}' (${MANIFEST_SAT_VERSION})..." >&2
  local out body
  out=$(_rhsm_api POST "/allocations" --get \
    --data-urlencode "name=${MANIFEST_NAME}" --data-urlencode "version=${MANIFEST_SAT_VERSION}") || return $?
  RHSM_HTTP_CODE="${out%%$'\n'*}"
  body="${out#*$'\n'}"
  _rhsm_require_permission || return 1
  if [ "$RHSM_HTTP_CODE" != 200 ] && [ "$RHSM_HTTP_CODE" != 201 ]; then
    _err "Creating the allocation failed (HTTP $RHSM_HTTP_CODE): ${body:0:200}"
    return 1
  fi
  printf '%s' "$body" | python3 -c '
import json
import sys
data = json.load(sys.stdin)
body = data.get("body", data)
print(body.get("uuid", "") if isinstance(body, dict) else "")
'
}

_satellite_manifest_attachment_plan() {
  python3 -c '
import json
import re
import sys

pools = json.loads(sys.stdin.readline())
attached = json.load(sys.stdin)["body"]["entitlementsAttached"]["value"]
if not isinstance(attached, list):
    sys.exit("ERROR: RHSM entitlementsAttached.value must be an array")

def category(name):
    name = name.casefold()
    if name.startswith("red hat satellite infrastructure subscription"):
        return "Satellite Infrastructure"
    if re.match(
        r"red hat enterprise linux (?:server|for virtual datacenters)"
        r"(?:$|, (?:premium|standard|self-support)(?:$| \())",
        name,
    ):
        return "RHEL server"
    return None

covered = set()
for item in attached:
    quantity = item["entitlementQuantity"]
    if not isinstance(quantity, int) or isinstance(quantity, bool) or quantity < 0:
        sys.exit("ERROR: Invalid attached entitlement quantity")
    if quantity > 0:
        covered.add(category(item["subscriptionName"]))

plan = []
for required in ("Satellite Infrastructure", "RHEL server"):
    if required in covered:
        continue
    matches = {}
    for pool in pools:
        if category(pool["subscriptionName"]) != required:
            continue
        available = pool["entitlementsAvailable"]
        if not isinstance(available, int) or isinstance(available, bool) or available < -1:
            sys.exit("ERROR: Invalid available entitlement quantity")
        if available == -1 or available >= 1:
            pool_id = pool["id"]
            if not isinstance(pool_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", pool_id):
                sys.exit("ERROR: Invalid RHSM pool ID")
            matches[pool_id] = pool["subscriptionName"]
    if len(matches) != 1:
        detail = ", ".join(f"{key} ({value})" for key, value in matches.items()) or "none"
        sys.exit(
            f"ERROR: Expected one eligible {required} pool; found {len(matches)}: {detail}. "
            "Attach the desired subscription manually under Red Hat Console > "
            "Subscriptions > Subscription Allocations, then rerun. "
            "For unrecognized subscription names, supply an exported MANIFEST to the lab builder. "
            "No subscriptions from this plan were attached."
        )
    plan.append(next(iter(matches)))

# Emit only after every missing category has a unique candidate.
print("\n".join(plan))
'
}

_satellite_manifest_entitlements() {
  local uuid="$1" out
  out=$(_rhsm_api GET "/allocations/${uuid}?include=entitlements") || return $?
  RHSM_HTTP_CODE="${out%%$'\n'*}"
  _rhsm_require_permission || return 1
  [ "$RHSM_HTTP_CODE" = 200 ] || { _err "Reading allocation entitlements failed (HTTP $RHSM_HTTP_CODE)"; return 1; }
  printf '%s' "${out#*$'\n'}"
}

_satellite_manifest_attach() {
  local uuid="$1" pools attached plan pool out
  pools=$(_satellite_manifest_list "/allocations/${uuid}/pools" 50) || return 1
  attached=$(_satellite_manifest_entitlements "$uuid") || return 1
  plan=$(printf '%s\n%s' "$pools" "$attached" | _satellite_manifest_attachment_plan) || return 1
  if [ -z "$plan" ]; then
    echo "✓ Required Satellite and RHEL subscriptions are already attached"
    return 0
  fi
  while IFS= read -r pool; do
    echo "▸ Attaching one entitlement from pool ${pool}..."
    out=$(_rhsm_api POST "/allocations/${uuid}/entitlements?pool=${pool}&quantity=1") || return $?
    RHSM_HTTP_CODE="${out%%$'\n'*}"
    _rhsm_require_permission || return 1
    if [ "$RHSM_HTTP_CODE" != 200 ] && [ "$RHSM_HTTP_CODE" != 201 ]; then
      _err "Attaching subscription pool ${pool} failed (HTTP $RHSM_HTTP_CODE)"
      return 1
    fi
  done <<<"$plan"
  # Read back the allocation rather than assuming a successful POST is enough.
  attached=$(_satellite_manifest_entitlements "$uuid") || return 1
  plan=$(printf '%s\n%s' '[]' "$attached" | _satellite_manifest_attachment_plan) || return 1
  echo "✓ Verified Satellite and RHEL subscriptions on the allocation"
}

_satellite_manifest_export() {
  local uuid="$1"
  echo "▸ Triggering manifest export for allocation ${uuid}..."
  local out body job_id
  out=$(_rhsm_api GET "/allocations/${uuid}/export") || return $?
  RHSM_HTTP_CODE="${out%%$'\n'*}"
  body="${out#*$'\n'}"
  _rhsm_require_permission || return 1
  if [ "$RHSM_HTTP_CODE" != 200 ] && [ "$RHSM_HTTP_CODE" != 202 ]; then
    _err "Triggering the export failed (HTTP $RHSM_HTTP_CODE): ${body:0:200}"
    return 1
  fi
  job_id=$(printf '%s' "$body" | python3 -c '
import json
import sys
data = json.load(sys.stdin)
body = data.get("body", data)
print(body.get("exportJobID", "") if isinstance(body, dict) else "")
')
  [ -n "$job_id" ] || { _err "The export response did not include a job ID"; return 1; }

  echo "▸ Waiting for export job ${job_id}..."
  # The exportJob endpoint returns 202 while running and 200 with a download
  # href once the manifest is ready (matching the RHSM API / Manifester flow).
  local attempt href
  for attempt in $(seq 1 60); do
    out=$(_rhsm_api GET "/allocations/${uuid}/exportJob/${job_id}") || return $?
    RHSM_HTTP_CODE="${out%%$'\n'*}"
    body="${out#*$'\n'}"
    case "$RHSM_HTTP_CODE" in
      200)
        href=$(printf '%s' "$body" | python3 -c '
import json
import sys
data = json.load(sys.stdin)
body = data.get("body", data)
print(body.get("href", "") if isinstance(body, dict) else "")
')
        [ -n "$href" ] || { _err "Export completed but no download URL was returned"; return 1; }
        MANIFEST_DOWNLOAD_URL="$href"
        return 0
        ;;
      202)
        sleep 5
        ;;
      *)
        _err "Polling the export job failed (HTTP $RHSM_HTTP_CODE): ${body:0:200}"
        return 1
        ;;
    esac
  done
  _err "Timed out waiting for the manifest export job"
  return 1
}

_satellite_manifest_download() {
  local dest="${MANIFEST_DIR}/manifest.zip"
  mkdir -p "$MANIFEST_DIR"
  local token
  token=$(fleet_redhat_access_token false) || return 2
  echo "▸ Downloading manifest to ${dest}..." >&2
  local code tmp
  tmp=$(mktemp "${MANIFEST_DIR}/manifest.zip.XXXXXX") || return 1
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl --config - --silent --show-error \
      --connect-timeout 15 --max-time 300 \
      --output "$tmp" --write-out '%{http_code}' \
      "$MANIFEST_DOWNLOAD_URL") || { rm -f "$tmp"; _err "Unable to download the manifest"; return 1; }
  if [ "$code" != 200 ]; then
    rm -f "$tmp"
    _err "Manifest download failed (HTTP $code)"
    return 1
  fi
  [ -s "$tmp" ] || { rm -f "$tmp"; _err "Downloaded manifest is empty"; return 1; }
  mv -f "$tmp" "$dest"
  printf '%s' "$dest"
}

main() {
  echo "Building a Satellite subscription manifest via the RHSM API..."
  echo "  Allocation: ${MANIFEST_NAME}  (${MANIFEST_SAT_VERSION})"

  local uuid
  uuid=$(_satellite_manifest_find_allocation) || return 1
  if [ -n "$uuid" ]; then
    echo "✓ Reusing existing allocation ${uuid}"
  else
    uuid=$(_satellite_manifest_create_allocation) || return 1
    [ -n "$uuid" ] || { _err "Allocation creation did not return a UUID"; return 1; }
    echo "✓ Created allocation ${uuid}"
  fi

  _satellite_manifest_attach "$uuid" || return 1
  _satellite_manifest_export "$uuid" || return 1
  local path
  path=$(_satellite_manifest_download) || return 1

  echo ""
  echo "✓ Satellite manifest ready: ${path}"
  echo "  Use it with the Satellite lab:"
  echo "    scp ${path} root@192.168.122.20:/root/manifest.zip"
  echo "    ssh root@192.168.122.20 'cd satellite-lab && ./03-content-hammer.sh /root/manifest.zip'"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
