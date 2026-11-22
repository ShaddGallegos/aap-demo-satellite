#!/usr/bin/env bash
# 10-openscap.sh — enable Satellite OpenSCAP services and load default content.
# Run on the Satellite VM as root. Policy assignment stays deliberate: selecting
# a profile and deploying a client policy affects managed hosts.
set -euo pipefail

ORG="${SAT_ORG:-Default Organization}"
LOC="${SATELLITE_LOCATION:-Lab}"

echo "▸ Enabling the OpenSCAP proxy plugin"
satellite-installer --enable-foreman-proxy-plugin-openscap

echo "▸ Loading the default SCAP Security Guide content"
hammer scap-content bulk-upload --type default

contents=$(hammer --output json scap-content list --organization "$ORG" --location "$LOC")
jq -e 'length > 0' <<<"$contents" >/dev/null || {
  echo "ERROR: Satellite did not report any SCAP content after the default upload" >&2
  exit 1
}
echo "✓ OpenSCAP proxy and $(jq 'length' <<<"$contents") SCAP content item(s) are ready"
echo "  Create a compliance policy only after selecting a RHEL-version-matched profile."
