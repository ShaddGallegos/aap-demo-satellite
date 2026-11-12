#!/usr/bin/env bash

lab_ssh_configure_root() {
  local ssh_config=/etc/ssh/sshd_config.d/00-aap-demo-lab.conf current
  current=$(mktemp) || return 1
  printf 'Match User root\n    PermitRootLogin prohibit-password\nMatch all\n' >"$current"
  if ! cmp -s "$current" "$ssh_config"; then
    install -m 644 "$current" "$ssh_config" || { rm -f "$current"; return 1; }
    rm -f "$current"
    sshd -t && systemctl reload sshd || return 1
  else
    rm -f "$current"
  fi
}

lab_ssh_apply() {
  local accounts="admin root" user home path keys group current key_temp
  if [ "$lab_kind" = crc ]; then
    accounts=core
  elif ! id admin >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash admin || return 1
  fi
  for user in $accounts; do
    home=$(getent passwd "$user" | cut -d: -f6) || return 1
    [ -n "$home" ] && [ "$home" != / ] || {
      echo "ERROR: Invalid home for managed account $user" >&2; return 1;
    }
    group=$(id -gn "$user") || return 1
    path="$home/.ssh"
    install -d -m 700 -o "$user" -g "$group" "$path" || return 1
    keys="$path/authorized_keys"
    if [ "$user" = core ] && sshd -T -C user=core,host=localhost,addr=127.0.0.1 |
      grep '^authorizedkeyscommand /usr/libexec/ssh-key-dir ' >/dev/null; then
      # Do not edit the MCO-owned authorized_keys.d/ignition file.
      install -d -m 700 -o "$user" -g "$group" "$path/authorized_keys.d" || return 1
      keys="$path/authorized_keys.d/aap-demo"
    fi
    touch "$keys" || return 1
    fleet_stack_replace_block "$keys" "$lab_public_key" || return 1
    key_temp=$(mktemp "$path/.aap-demo-key.XXXXXX") || return 1
    if ! {
      printf '%s\n' "$lab_private_key" >"$key_temp" &&
        chmod 600 "$key_temp" &&
        chown "$user:$group" "$key_temp" &&
        mv -f "$key_temp" "$path/aap-demo-shared-key"
    }; then
      rm -f "$key_temp"
      return 1
    fi
    printf '%s\n' "$lab_public_key" >"$path/aap-demo-shared-key.pub" || return 1
    printf '%s\n' "$lab_config" >"$path/aap-demo-lab-config" || return 1
    touch "$path/config" || return 1
    current=$(sed '\|^Include ~/.ssh/aap-demo-lab-config$|d' "$path/config") || return 1
    printf 'Include ~/.ssh/aap-demo-lab-config\n%s\n' "$current" >"$path/config" || return 1
    chown "$user:$group" "$keys" "$path"/{config,aap-demo-shared-key,aap-demo-shared-key.pub,aap-demo-lab-config} || return 1
    chmod 600 "$keys" "$path"/{config,aap-demo-shared-key,aap-demo-shared-key.pub,aap-demo-lab-config} || return 1
    if command -v restorecon >/dev/null; then restorecon -R "$path" || return 1; fi
  done
  if [ "$lab_kind" != crc ]; then
    lab_ssh_configure_root || return 1
  fi
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  lab_ssh_apply
fi
