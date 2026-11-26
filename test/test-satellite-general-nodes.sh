#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/satellite-lab/08-provision-general-nodes.sh"

output=$(SATELLITE_GENERAL_NODE_COUNT=0 bash "$SCRIPT")
grep -Fq 'disabled (count=0)' <<<"$output"

if SATELLITE_GENERAL_NODE_COUNT=3 bash "$SCRIPT" >/tmp/aap-demo-general-node-test.out 2>&1; then
  echo "FAIL: image-based provisioning accepted no Satellite image" >&2
  exit 1
fi
grep -Fq 'SATELLITE_GENERAL_NODE_IMAGE' /tmp/aap-demo-general-node-test.out
rm -f /tmp/aap-demo-general-node-test.out

grep -Fq 'cpus=2,memory=4294967296' "$SCRIPT"
grep -Fq 'capacity=15G' "$SCRIPT"
grep -Fq 'SATELLITE_GENERAL_NODE_IMAGE' "$ROOT/satellite-lab/build-and-configure.sh"
echo "PASS: Satellite general nodes are opt-in, image-based, and sized for Virt-Manager"
