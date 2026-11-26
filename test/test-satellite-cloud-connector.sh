#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/satellite-lab/configure-cloud-connector.sh"
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT

subscription-manager() { [ "${REGISTERED:-true}" = true ]; }
satellite_cloud_prepare_ssh() { echo ssh >>"$temp/calls"; }
satellite_cloud_ready() { [ "${READY:-false}" = true ] || [ -f "$temp/ready" ]; }
hammer() {
  echo "$*" >>"$temp/calls"
  case "$*" in
    *'settings list'*'allow_auto_inventory_upload'*)
      jq -cn --arg value "${INVENTORY_UPLOAD:-true}" \
        '[{Name: "allow_auto_inventory_upload", Value: $value}]'
      ;;
    'settings set --name allow_auto_inventory_upload --value true')
      [ "${INVENTORY_UPLOAD_SET_FAIL:-false}" != true ] || return 1
      INVENTORY_UPLOAD=true
      ;;
    'insights cloud-connector enable '*)
      [ "${ENABLE_FAIL:-false}" != true ] || return 1
      printf 'Task id: %s\n' "${TASK_ID:-492bfb45-0a70-4288-9620-8031a276d4e1}"
      ;;
    '--output json task info '*)
      if [ "${RESULT:-success}" = success ] && [ "${INCOMPLETE:-false}" != true ]; then
        touch "$temp/ready"
      fi
      jq -cn --arg result "${RESULT:-success}" --arg state "${STATE:-stopped}" \
        '{State:$state,Result:$result}'
      ;;
    *) return 1 ;;
  esac
}
reset_case() {
  : >"$temp/calls"
  rm -f "$temp/ready"
  INVENTORY_UPLOAD=true
}
reset_case
READY=true satellite_cloud_main >"$temp/out"
grep -q 'settings list.*allow_auto_inventory_upload' "$temp/calls"
if grep -q '^settings set ' "$temp/calls"; then
  echo 'FAIL: an already-enabled inventory upload setting was changed' >&2
  exit 1
fi
reset_case
INVENTORY_UPLOAD=false
satellite_cloud_main >"$temp/out"
grep -q '^ssh$' "$temp/calls"
grep -q '^insights cloud-connector enable --organization Default Organization$' "$temp/calls"
grep -q '^settings set --name allow_auto_inventory_upload --value true$' "$temp/calls"
grep -q 'Verified:' "$temp/out"
for failure in registration enable malformed failed paused incomplete; do
  reset_case
  (
    case "$failure" in
      registration) export REGISTERED=false ;;
      enable) export ENABLE_FAIL=true ;;
      malformed) export TASK_ID='not-a-task' ;;
      failed) export RESULT=error ;;
      paused) export STATE=paused RESULT=pending ;;
      incomplete) export INCOMPLETE=true ;;
    esac
    if satellite_cloud_main >"$temp/out" 2>&1; then
      echo "FAIL: cloud connector accepted $failure" >&2
      exit 1
    fi
    grep -q '^ERROR:' "$temp/out"
    if [ "$failure" = registration ]; then [ ! -s "$temp/calls" ]; fi
  )
done
echo 'PASS: connector reuse, native task verification and failure propagation'
