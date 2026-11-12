#!/usr/bin/env bash

if [ -n "${_LAB_SSH_LOADED:-}" ]; then return 0; fi
_LAB_SSH_LOADED=1
LAB_SSH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fleet-stack-remote.sh
source "$LAB_SSH_DIR/fleet-stack-remote.sh"

lab_ssh_satellite() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10 "root@${SATELLITE_LAB_IP:-192.168.122.20}" "$@"
}

lab_ssh_inventory() {
  local inventory state
  inventory=$(fleet_access_inventory omit) || return 1
  inventory=$(jq -c '[.[] | select(.state == "running") |
    {kind:"fleet", name:.hostname, port:.ssh_port}]' <<<"$inventory") || return 1
  if command -v virsh >/dev/null; then
    state=$(virsh -c qemu:///system domstate satellite 2>/dev/null) || state=absent
    if [ "$state" = running ]; then
      inventory=$(jq -c '. + [{kind:"satellite",name:"satellite",port:22}]' <<<"$inventory") || return 1
    fi
  fi
  if [ "${INFRA:-}" = crc ]; then
    _crc_exec true </dev/null || { _err "CRC SSH is unavailable"; return 1; }
    inventory=$(jq -c '. + [{kind:"crc",name:"aap-demo-crc",port:2222}]' <<<"$inventory") || return 1
  fi
  printf '%s\n' "$inventory"
}

lab_ssh_connect() {
  local kind="$1" port="$2"
  shift 2
  case "$kind" in
    fleet) fleet_stack_ssh "$port" "$@" ;;
    satellite) lab_ssh_satellite "$@" ;;
    crc) _crc_exec "$@" ;;
    *) _err "Unknown managed SSH peer: $kind"; return 1 ;;
  esac
}

lab_ssh_open_satellite_forwards() {
  local gateway="$1" inventory="$2" interface zone port rule permanent rc
  jq -e 'any(.[]; .kind=="satellite")' <<<"$inventory" >/dev/null || return 0
  if ! command -v firewall-cmd >/dev/null || ! systemctl is-active --quiet firewalld; then
    printf '  No active firewalld; leaving host firewall configuration unchanged.\n'
    return 0
  fi
  interface=$(ip -4 route get "${SATELLITE_LAB_IP:-192.168.122.20}" |
    awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}') || return 1
  [ -n "$interface" ] || { _err "Cannot discover the Satellite-facing interface"; return 1; }
  zone=$(sudo firewall-cmd --get-zone-of-interface="$interface") || return 1
  [ -n "$zone" ] || { _err "No firewalld zone for the Satellite-facing interface"; return 1; }
  while IFS= read -r port; do
    rule="rule family=\"ipv4\" source address=\"${SATELLITE_LAB_IP:-192.168.122.20}/32\" destination address=\"$gateway/32\" port port=\"$port\" protocol=\"tcp\" accept"
    for permanent in true false; do
      local options=(--zone="$zone")
      [ "$permanent" != true ] || options+=(--permanent)
      rc=0
      sudo firewall-cmd "${options[@]}" --query-rich-rule="$rule" >/dev/null || rc=$?
      case "$rc" in
        0) ;;
        1) sudo firewall-cmd "${options[@]}" --add-rich-rule="$rule" >/dev/null || return 1 ;;
        *) _err "Cannot query Satellite-to-Fleet firewall access"; return 1 ;;
      esac
    done
  done < <(jq -r '.[] | select(.kind=="fleet") | .port' <<<"$inventory")
}

lab_reconcile_ssh() {
  local gateway="$1" inventory key_path private_key public_key config="" bridge
  local row kind name port target user aliases domain="${FLEET_DOMAIN:-fleet.aap-demo.test}"
  if [ "${INFRA:-}" = crc ]; then
    # Load in the caller, not the discovery subshell: connections reuse these helpers.
    # shellcheck source=infra-crc.sh
    source "$LAB_SSH_DIR/infra-crc.sh"
  fi
  inventory=$(lab_ssh_inventory) || return 1
  [ "$inventory" != '[]' ] || return 0
  key_path="${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet/ssh_key"
  if [ ! -s "$key_path" ]; then
    _err "Shared lab SSH key is missing; create the Fleet nodes first"
    return 1
  fi
  public_key=$(ssh-keygen -y -P '' -f "$key_path") || return 1
  private_key=$(cat "$key_path") || return 1
  bridge=$(jq -r '[.[] | select(.kind=="fleet")][0].name // empty' <<<"$inventory") || return 1
  while IFS= read -r row; do
    kind=$(jq -r '.kind' <<<"$row")
    name=$(jq -r '.name' <<<"$row")
    port=$(jq -r '.port' <<<"$row")
    user="admin"
    aliases="$name"
    case "$kind" in
      fleet) target="$gateway"; aliases+=" $name.$domain" ;;
      satellite) target="${SATELLITE_LAB_IP:-192.168.122.20}"; aliases+=" ${SATELLITE_LAB_HOST:-satellite.demo.lab}" ;;
      crc)
        user=core
        aliases+=" crc"
        if [ -n "$bridge" ]; then
          # QEMU's gateway reaches the host's loopback-only CRC SSH forward.
          target=10.0.2.2
        elif [ "$(jq length <<<"$inventory")" -eq 1 ]; then
          target=127.0.0.1
          port=22
        else
          _err "Cross-guest CRC SSH requires a running Fleet QEMU bridge"
          return 1
        fi
        ;;
    esac
    [[ "$target" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ && "$aliases" != *$'\n'* ]] &&
      [[ "$aliases" =~ ^[a-zA-Z0-9.\ -]+$ && "$port" =~ ^[0-9]+$ ]] || {
      _err "Invalid managed lab SSH endpoint"; return 1;
    }
    config+="Host $aliases"$'\n'
    config+="    HostName $target"$'\n'
    config+="    Port $port"$'\n'
    config+="    User $user"$'\n'
    config+=$'    IdentityFile ~/.ssh/aap-demo-shared-key\n    IdentitiesOnly yes\n'
    config+=$'    StrictHostKeyChecking no\n    UserKnownHostsFile /dev/null\n'
    if [ "$kind" = crc ] && [ -n "$bridge" ]; then
      config+="    ProxyJump admin@$bridge"$'\n'
    fi
  done < <(jq -c '.[]' <<<"$inventory")
  config+=$'Host *\n'
  lab_ssh_open_satellite_forwards "$gateway" "$inventory" || return 1
  while IFS= read -r row; do
    kind=$(jq -r '.kind' <<<"$row")
    port=$(jq -r '.port' <<<"$row")
    if ! {
      printf 'set -euo pipefail\n'
      printf 'lab_kind=%q\nlab_private_key=%q\nlab_public_key=%q\nlab_config=%q\n' \
        "$kind" "$private_key" "$public_key" "$config"
      declare -f fleet_stack_replace_block
      cat "$LAB_SSH_DIR/lab-ssh-remote.sh"
    } | lab_ssh_connect "$kind" "$port" 'sudo bash -s'; then
      unset private_key
      _err "Shared lab SSH reconciliation failed on $(jq -r '.name' <<<"$row")"
      return 1
    fi
  done < <(jq -c '.[]' <<<"$inventory")
  unset private_key
  printf '  ✓ Shared lab SSH key reconciled: admin/root on RHEL; core + sudo on CRC\n'
}
