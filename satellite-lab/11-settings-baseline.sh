#!/usr/bin/env bash
# Reconcile the narrow Satellite settings baseline required by this local lab.
# Run on the Satellite VM as root. Settings that define organization policy
# (mail, authentication, root passwords, discovery auto-provisioning, and data
# minimization) remain explicitly under the administrator's control.
set -euo pipefail

ORG="${SAT_ORG:-Default Organization}"
LOC="${SATELLITE_LOCATION:-Lab}"

set_setting() { # <name> <value> <description>
  local name="$1" value="$2" description="$3" current
  current=$(hammer --output json settings list --search "name = $name" \
    | jq -r --arg name "$name" '.[] | select(.Name == $name) | (.Value | tostring)' \
    | head -n1) || return 1
  if [ "$current" = "$value" ]; then
    echo "  ✓ $description already configured"
    return 0
  fi
  hammer settings set --name "$name" --value "$value" >/dev/null || return 1
  current=$(hammer --output json settings list --search "name = $name" \
    | jq -r --arg name "$name" '.[] | select(.Name == $name) | (.Value | tostring)' \
    | head -n1) || return 1
  [ "$current" = "$value" ] || {
    echo "ERROR: Satellite setting '$name' did not retain the requested value" >&2
    return 1
  }
  echo "  ✓ Configured $description"
}

echo "== Satellite operational settings baseline =="
# Facts and Discovery use the lab ownership boundary when a reporting client
# omits explicit context. Discovery remains manual: auto-provisioning could
# create machines in response to unrelated network hardware.
set_setting default_location "$LOC" "default location for reported facts"
set_setting default_organization "$ORG" "default organization for reported facts"
set_setting discovery_location "$LOC" "Discovery location"
set_setting discovery_organization "$ORG" "Discovery organization"

# The satlab DNS Capsule is reconciled separately. Prefer the host's private
# address for Remote Execution so jobs do not depend on a workstation resolver.
set_setting remote_execution_connect_by_ip true "Remote Execution private-IP connection mode"
set_setting remote_execution_prefer_registered_through_proxy true "Remote Execution registered Capsule preference"

# Keep the default, supported synced-content templates explicit so a later UI
# change cannot silently detach newly synchronized RHEL trees from provisioning.
set_setting katello_default_provision 'Kickstart default' "default synchronized-content provisioning template"
set_setting katello_default_finish 'Kickstart default finish' "default synchronized-content finish template"
set_setting katello_default_user_data 'Kickstart default user data' "default synchronized-content user-data template"

# Cloud Connector setup verifies these separately too. Reassert them here so
# a normal Satellite reconciliation repairs a disabled UI setting.
set_setting allow_auto_inventory_upload true "automatic Red Hat Inventory upload"
set_setting allow_auto_insights_sync true "automatic Red Hat Lightspeed recommendation synchronization"

echo "✓ Satellite operational settings baseline reconciled"
