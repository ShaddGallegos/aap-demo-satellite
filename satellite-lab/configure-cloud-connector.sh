#!/usr/bin/env bash
# Run on the managed Satellite VM; native tooling owns connector configuration.
set -euo pipefail

satellite_cloud_error() { printf 'ERROR: %s\n' "$*" >&2; }

satellite_cloud_prepare_ssh() {
  local key=/var/lib/foreman-proxy/ssh/id_rsa_foreman_proxy.pub
  local authorized=/root/.ssh/authorized_keys
  if [ ! -s "$key" ] || ! ssh-keygen -lf "$key" >/dev/null; then
    satellite_cloud_error "Native remote-execution public key is missing or invalid"
    return 1
  fi
  install -d -m 0700 /root/.ssh || return 1
  if [ ! -f "$authorized" ]; then
    install -m 0600 /dev/null "$authorized" || return 1
  fi
  if ! grep -Fxq "$(cat "$key")" "$authorized"; then
    local backup
    backup=$(mktemp /root/.ssh/authorized_keys.before-cloud.XXXXXX) || return 1
    cp -p "$authorized" "$backup" || return 1
    printf '\n%s\n' "$(cat "$key")" >>"$authorized" || return 1
  fi
  restorecon -RF /root/.ssh
}

satellite_cloud_ready() {
  systemctl is-active --quiet rhcd.service \
    && systemctl is-enabled --quiet rhcd.service \
    && test -s /etc/rhc/workers/foreman_rh_cloud.toml \
    && hammer --output json settings list --search 'name = rhc_instance_id' \
      | jq -e 'any(.[]; .Name == "rhc_instance_id" and (.Value | type == "string" and length > 0))' >/dev/null
}

satellite_cloud_inventory_upload_ready() {
  hammer --output json settings list --search 'name = allow_auto_inventory_upload' \
    | jq -e 'any(.[]; .Name == "allow_auto_inventory_upload" and (.Value | tostring | ascii_downcase) == "true")' >/dev/null
}

satellite_cloud_reconcile_inventory_upload() {
  if satellite_cloud_inventory_upload_ready; then
    printf '✓ Automatic Red Hat Inventory upload is enabled\n'
    return 0
  fi
  # This is the Satellite-wide setting behind Administer > Settings > Red Hat
  # Inventory > Automatic inventory upload. It does not register or modify any
  # hosts; it only enables the daily report after the native connector is ready.
  hammer settings set --name allow_auto_inventory_upload --value true >/dev/null || {
    satellite_cloud_error "Could not enable automatic Red Hat Inventory upload"
    return 1
  }
  satellite_cloud_inventory_upload_ready || {
    satellite_cloud_error "Automatic Red Hat Inventory upload did not remain enabled"
    return 1
  }
  printf '✓ Enabled automatic Red Hat Inventory upload\n'
}

satellite_cloud_main() {
  if [ "$#" -ne 0 ]; then
    satellite_cloud_error "Usage: configure-cloud-connector.sh"
    return 2
  fi
  local timeout="${SATELLITE_CLOUD_TIMEOUT:-600}" org="${SAT_ORG:-Default Organization}"
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || {
    satellite_cloud_error "SATELLITE_CLOUD_TIMEOUT must be positive seconds"
    return 2
  }
  subscription-manager identity >/dev/null 2>&1 || {
    satellite_cloud_error "Register Satellite itself directly with Red Hat before enabling its cloud connector"
    return 1
  }
  if satellite_cloud_ready; then
    satellite_cloud_reconcile_inventory_upload || return 1
    printf 'Native Satellite cloud connector is configured and rhcd is active\n'
    return 0
  fi
  satellite_cloud_prepare_ssh || return 1
  local response task_id task state result deadline
  # Never echo native responses: connector job inputs contain a service token.
  response=$(hammer insights cloud-connector enable --organization "$org") || {
    satellite_cloud_error "Native cloud connector enable failed"
    return 1
  }
  task_id=$(sed -n 's/^Task id: \([0-9a-f-]\{36\}\)$/\1/p' <<<"$response")
  [[ "$task_id" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] || {
    satellite_cloud_error "Native enable did not return one valid task ID; inspect existing jobs before retrying"
    return 1
  }
  printf 'Waiting for native cloud connector task %s\n' "$task_id"
  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    task=$(hammer --output json task info --id "$task_id") || return 1
    state=$(jq -er '.State' <<<"$task") || return 1
    result=$(jq -er '.Result' <<<"$task") || return 1
    case "$state" in
      stopped)
        if [ "$result" != success ]; then
          satellite_cloud_error "Native cloud connector task $task_id ended with $result; inspect its job privately"
          return 1
        fi
        satellite_cloud_ready || {
          satellite_cloud_error "Native task succeeded but rhcd, worker configuration, or connector identity is not ready"
          return 1
        }
        satellite_cloud_reconcile_inventory_upload || return 1
        printf 'Verified: native cloud connector configured and rhcd active\n'
        return 0
        ;;
      paused)
        satellite_cloud_error "Native cloud connector task $task_id is paused; inspect it before retrying"
        return 1
        ;;
    esac
    sleep 5
  done
  satellite_cloud_error "Timed out waiting for task $task_id; inspect it before rotating connector credentials again"
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  satellite_cloud_main "$@"
fi
