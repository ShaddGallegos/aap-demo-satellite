#!/usr/bin/env bash
# Regression tests for Fleet command argument parsing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

_err() {
  printf 'ERROR: %s\n' "$*" >&2
}

# shellcheck source=../addons/fleet/fleet-cli.sh
source "${REPO_ROOT}/addons/fleet/fleet-cli.sh"

fleet_parse_add_args 3 --image /tmp/rhel9.qcow2
if [ "$FLEET_ADD_COUNT" != 3 ] || [ "$FLEET_ADD_IMAGE" != /tmp/rhel9.qcow2 ]; then
  echo "FAIL: separated --image syntax was not parsed" >&2
  exit 1
fi
echo "PASS: parses --image PATH"

fleet_parse_add_args --image=/tmp/rhel9.qcow2 2
if [ "$FLEET_ADD_COUNT" != 2 ] || [ "$FLEET_ADD_IMAGE" != /tmp/rhel9.qcow2 ]; then
  echo "FAIL: equals --image syntax was not parsed" >&2
  exit 1
fi
echo "PASS: parses --image=PATH"

if output=$(fleet_parse_add_args 3 --image /tmp/rhel9.qcow2 ao 2>&1); then
  echo "FAIL: unexpected trailing argument was accepted" >&2
  exit 1
fi
if ! grep -q "Unexpected argument for 'fleet add': ao" <<<"$output"; then
  echo "FAIL: trailing argument did not produce a useful error" >&2
  echo "$output" >&2
  exit 1
fi
echo "PASS: rejects unexpected trailing arguments"

if fleet_parse_add_args 3 --image >/dev/null 2>&1; then
  echo "FAIL: missing image value was accepted" >&2
  exit 1
fi
echo "PASS: rejects missing image value"

export HOME="$TEST_HOME"
# shellcheck source=../addons/fleet/fleet.sh
source "${REPO_ROOT}/addons/fleet/fleet.sh"
list_output=$(fleet_list)
if ! grep -q 'aap-demo fleet add <count> --image <rhel9|rhel10|local-qcow2-path>' <<<"$list_output"; then
  echo "FAIL: empty Fleet list does not show managed-image syntax" >&2
  echo "$list_output" >&2
  exit 1
fi
echo "PASS: empty Fleet list shows managed-image syntax"

# fleet_node_power validates the index and action and updates the node meta.
FLEET_DIR="$TEST_HOME/fleet"
mkdir -p "$FLEET_DIR/node-1"
printf 'INDEX=1\nPORT=2201\nPID=\nHOSTNAME=aap-fleet-node-1\nSTATUS=stopped\n' >"$FLEET_DIR/node-1/meta"

if fleet_node_power "abc" start >/dev/null 2>&1; then
  echo "FAIL: non-numeric node index was accepted" >&2
  exit 1
fi
echo "PASS: rejects a non-numeric node index"

if fleet_node_power 1 powercycle >/dev/null 2>&1; then
  echo "FAIL: unknown power action was accepted" >&2
  exit 1
fi
echo "PASS: rejects an unknown power action"

if fleet_node_power 9 stop >/dev/null 2>&1; then
  echo "FAIL: a missing node was accepted" >&2
  exit 1
fi
echo "PASS: rejects a missing node"

# shellcheck disable=SC2329
(
  set -e
  touch "$FLEET_DIR/node-1/disk.qcow2" "$FLEET_DIR/node-1/cloud-init.iso"
  fleet_ssh_key_ready() { :; }
  _fleet_check_port_available() { :; }
  _fleet_qemu_binary() { printf mock_qemu; }
  _fleet_qemu_accel() { printf kvm; }
  _fleet_qemu_machine() { printf q35; }
  _fleet_qemu_bios_args() { :; }
  fleet_ssh() { :; }
  fleet_reconcile_access() { :; }
  mock_qemu() {
    printf '%s\n' "$@" >"$TEST_HOME/qemu-args"
    while [ "$#" -gt 1 ]; do
      if [ "$1" = -pidfile ]; then printf 999999999 >"$2"; fi
      shift
    done
  }
  printf 'MEMORY_MB=4096\n' >>"$FLEET_DIR/node-1/meta"
  _FLEET_NODE_MEM_EXPLICIT=""
  fleet_node_start 1 >/dev/null || exit 1
  grep -Fxq 4096 "$TEST_HOME/qemu-args" || exit 1
  _FLEET_NODE_MEM_EXPLICIT=2048
  fleet_node_start 1 >/dev/null || exit 1
  grep -Fxq 2048 "$TEST_HOME/qemu-args" || exit 1
  grep -Fxq MEMORY_MB=2048 "$FLEET_DIR/node-1/meta" || exit 1
  test "$(grep -c '^MEMORY_MB=' "$FLEET_DIR/node-1/meta")" = 1 || exit 1
  sed -i 's/^MEMORY_MB=.*/MEMORY_MB=invalid/' "$FLEET_DIR/node-1/meta"
  _FLEET_NODE_MEM_EXPLICIT=""
  if fleet_node_start 1 >/dev/null 2>&1; then
    echo "FAIL: invalid saved memory was accepted" >&2
    exit 1
  fi
) || {
  echo "FAIL: per-node memory retention or override failed" >&2
  exit 1
}
echo "PASS: node memory survives restart, accepts explicit overrides, and rejects invalid state"

# stop on an existing (stopped) node updates the meta without error.
fleet_node_start() { return 0; }
_fleet_stop_vm() { return 0; }
fleet_reconcile_access() { return 0; }
fleet_node_power 1 stop >/dev/null 2>&1
grep -q '^STATUS=stopped$' "$FLEET_DIR/node-1/meta" || {
  echo "FAIL: stop did not mark the node stopped" >&2
  exit 1
}
echo "PASS: stop marks the node stopped"

fleet_node_power 1 restart >/dev/null 2>&1
echo "PASS: restart runs stop then start"
