#!/usr/bin/env bash
# Provision small general-purpose VMs through Satellite's compute resource.
# The Libvirt defaults create persistent domains, visible in virt-manager.
set -euo pipefail

COUNT="${SATELLITE_GENERAL_NODE_COUNT:-0}"
PREFIX="${SATELLITE_GENERAL_NODE_PREFIX:-aap-demo-general-node}"
HOSTGROUP="${SATELLITE_GENERAL_NODE_HOSTGROUP:-hg-rhel9-prod}"
RESOURCE="${SATELLITE_COMPUTE_RESOURCE:-KVM-Host}"
PROFILE="${SATELLITE_GENERAL_NODE_COMPUTE_PROFILE:-aap-demo-general-small}"
IMAGE="${SATELLITE_GENERAL_NODE_IMAGE:-}"
ORG="${SATELLITE_GENERAL_NODE_ORGANIZATION:-Default Organization}"
LOC="${SATELLITE_GENERAL_NODE_LOCATION:-Lab}"

[[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -le 20 ] || {
  echo "ERROR: SATELLITE_GENERAL_NODE_COUNT must be an integer from 0 through 20" >&2
  exit 2
}
[[ "$PREFIX" =~ ^[a-z][a-z0-9-]{0,40}$ ]] || {
  echo "ERROR: SATELLITE_GENERAL_NODE_PREFIX must be a safe DNS-label prefix" >&2
  exit 2
}
[ "$COUNT" -gt 0 ] || { echo "General Satellite nodes disabled (count=0)"; exit 0; }
[ -n "$IMAGE" ] || {
  echo "ERROR: SATELLITE_GENERAL_NODE_IMAGE must name an image registered on '$RESOURCE'." >&2
  echo "  Image-based provisioning is deliberately not replaced with a PXE/kickstart fallback." >&2
  exit 2
}

hammer compute-resource info --name "$RESOURCE" >/dev/null || {
  echo "ERROR: Satellite compute resource '$RESOURCE' does not exist." >&2
  echo "  Set SATELLITE_COMPUTE_RESOURCE to the Satellite resource for the selected provider." >&2
  exit 1
}
hammer compute-profile info --name "$PROFILE" >/dev/null || {
  echo "ERROR: Satellite compute profile '$PROFILE' does not exist for '$RESOURCE'." >&2
  echo "  Re-run the Satellite integration stage or set SATELLITE_GENERAL_NODE_COMPUTE_PROFILE." >&2
  exit 1
}
hammer hostgroup info --name "$HOSTGROUP" >/dev/null || {
  echo "ERROR: Satellite host group '$HOSTGROUP' does not exist." >&2
  exit 1
}

provider=$(hammer compute-resource info --name "$RESOURCE" 2>/dev/null | awk -F: '/^[[:space:]]*Provider[[:space:]]*:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
attrs="${SATELLITE_GENERAL_NODE_COMPUTE_ATTRIBUTES:-}"
volume="${SATELLITE_GENERAL_NODE_VOLUME:-}"
interface="${SATELLITE_GENERAL_NODE_INTERFACE:-}"
if [ -z "$attrs" ] && [ "$provider" = Libvirt ]; then
  attrs='cpus=2,memory=4294967296'
  volume='pool_name=default,capacity=15G,format_type=qcow2'
  interface='managed=true,primary=true,provision=true,compute_type=network,compute_network=satlab,compute_model=virtio'
fi
if [ -z "$attrs" ] || [ -z "$volume" ] || [ -z "$interface" ]; then
  echo "ERROR: Provider '$provider' needs its Satellite-specific sizing attributes." >&2
  echo "  Set SATELLITE_GENERAL_NODE_COMPUTE_ATTRIBUTES, _VOLUME, and _INTERFACE." >&2
  echo "  They must describe 2 vCPU, 4096 MiB RAM, and a 15 GiB disk for that provider." >&2
  exit 2
fi

echo "Provisioning ${COUNT} general VM(s) through Satellite resource '$RESOURCE' (${provider:-unknown})..."
for raw_index in $(seq 1 "$COUNT"); do
  printf -v index '%02d' "$raw_index"
  name="${PREFIX}-${index}"
  if hammer host info --name "$name" >/dev/null 2>&1; then
    echo "  ✓ ${name} already exists"
    continue
  fi
  hammer host create --name "$name" --hostgroup "$HOSTGROUP" \
    --organization "$ORG" --location "$LOC" --compute-resource "$RESOURCE" \
    --compute-profile "$PROFILE" --image "$IMAGE" --compute-attributes "$attrs" \
    --interface "$interface" --volume "$volume" --build true
  echo "  ✓ ${name} submitted for image-based provisioning"
done
echo "✓ General VM provisioning requests submitted"
