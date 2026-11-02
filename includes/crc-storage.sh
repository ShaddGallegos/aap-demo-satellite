#!/usr/bin/env bash

_aap_demo_crc_filesystem_size() {
  local values total used available attempt
  # crc start returns once MicroShift is up, but the daemon's vsock SSH forward
  # (port 2222) can lag several seconds behind. Retry the SSH probe before
  # giving up so boot recovery does not fail on the transient gap.
  for attempt in $(seq 1 15); do
    if values=$(infra_exec_cmd df -Pk /var 2>/dev/null); then
      break
    fi
    values=""
    sleep 2
  done
  [ -n "$values" ] || return 1
  read -r total used available <<<"$(awk 'NR == 2 {print $2, $3, $4}' <<<"$values")"
  if ! [[ "$total" =~ ^[1-9][0-9]*$ && "$used" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] \
    || [ "$used" -gt "$total" ] || [ "$available" -gt "$total" ]; then
    echo "ERROR: Could not read CRC filesystem capacity from df." >&2
    return 1
  fi
  printf '%s %s %s\n' "$total" "$used" "$available"
}

aap_demo_start_storage() {
  local values total used available before target actual_bytes host_available config tmp
  local gib=1073741824
  local metadata="${HOME}/.crc/machines/crc/config.json"
  local pending="${AAP_DEMO_DIR:-${HOME}/.aap-demo}/storage-growth.pending"

  if ! values=$(_aap_demo_crc_filesystem_size); then
    _err "Could not check CRC disk usage; check 'aap-demo ssh' before retrying"
    return 1
  fi
  read -r total used available <<<"$values"
  printf 'CRC filesystem: %s%% used; %s GiB available\n' \
    "$((used * 100 / total))" "$((available / 1048576))"
  if [ ! -f "$pending" ] && [ "$((used * 100))" -lt "$((total * 90))" ]; then
    return 0
  fi

  if [ -f "$pending" ]; then
    read -r before target <"$pending" || return 1
    if ! [[ "$before" =~ ^[1-9][0-9]*$ && "$target" =~ ^[1-9][0-9]*$ ]]; then
      _err "Invalid pending CRC storage resize: $pending"
      return 1
    fi
    if [ "$total" -gt "$before" ] && [ "$((used * 100))" -lt "$((total * 90))" ]; then
      rm -f "$pending"
      return 0
    fi
    echo "Retrying the pending CRC disk growth to ${target} GiB..."
  else
    # CRC records the actual disk capacity in bytes, independent of saved preferences.
    actual_bytes=$(jq -er '.Driver.DiskCapacity |
      select(type == "number" and . > 0 and . == floor)' "$metadata") || {
      _err "Cannot determine the existing CRC disk capacity from $metadata"
      return 1
    }
    target=$(((actual_bytes * 120 + 100 * gib - 1) / (100 * gib)))
    host_available=$(df -Pk "$(dirname "$metadata")" | awk 'NR == 2 {print $4}')
    if ! [[ "$host_available" =~ ^[0-9]+$ ]] \
      || [ "$((host_available * 1024))" -lt "$((target * gib - actual_bytes))" ]; then
      _err "Not enough host disk space to grow CRC to ${target} GiB"
      return 1
    fi
    before="$total"
    mkdir -p "$(dirname "$pending")" || return 1
    (umask 077; printf '%s %s\n' "$before" "$target" >"$pending") || return 1
    echo "CRC filesystem is at least 90% full; growing the VM disk by 20% to ${target} GiB."
  fi

  # Persist the target before restarting; a retry must not request the old, smaller disk.
  crc config set disk-size "$target" || return 1
  config="${AAP_DEMO_CONFIG:-${HOME}/.aap-demo/config}"
  mkdir -p "$(dirname "$config")" || return 1
  tmp=$(mktemp "${config}.tmp.XXXXXX") || return 1
  if ! {
    if [ -f "$config" ]; then
      awk '!/^CRC_DISK=/' "$config"
    fi
    printf 'CRC_DISK=%s\n' "$target"
  } >"$tmp" || ! mv "$tmp" "$config"; then
    rm -f "$tmp"
    _err "Could not persist the CRC disk growth target"
    return 1
  fi
  export CRC_DISK="$target"

  echo "Stopping CRC briefly so CRC can grow its disk and root filesystem..."
  if ! crc stop; then
    _err "CRC could not stop gracefully; no forced power-off was attempted. Resolve the shutdown failure and retry 'aap-demo start'"
    return 1
  fi
  _start_crc_cluster || return 1
  setup_kubeconfig
  if ! values=$(_aap_demo_crc_filesystem_size); then
    _err "Could not verify the CRC filesystem after disk growth"
    return 1
  fi
  read -r total used available <<<"$values"
  actual_bytes=$(jq -er '.Driver.DiskCapacity' "$metadata") || return 1
  if [ "$actual_bytes" -lt "$((target * gib))" ] || [ "$total" -le "$before" ] \
    || [ "$((used * 100))" -ge "$((total * 90))" ]; then
    _err "CRC disk/filesystem growth was not completed or usage remains at least 90%; the target is preserved for retry"
    return 1
  fi
  rm -f "$pending"
  printf 'CRC storage grown to %s GiB; filesystem usage is now %s%%\n' \
    "$target" "$((used * 100 / total))"
}
