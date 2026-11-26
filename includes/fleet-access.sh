#!/usr/bin/env bash

if [ -n "${_FLEET_ACCESS_LOADED:-}" ]; then return 0; fi
_FLEET_ACCESS_LOADED=1
FLEET_ACCESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=credential-vault.sh
source "${FLEET_ACCESS_DIR}/credential-vault.sh"
# shellcheck source=fleet-stack.sh
source "${FLEET_ACCESS_DIR}/fleet-stack.sh"
# shellcheck source=ssh-trust.sh
source "${FLEET_ACCESS_DIR}/ssh-trust.sh"

FLEET_SSH_VAULT_KEY="aap_demo.fleet.ssh_private_key"
FLEET_LEGACY_SSH_VAULT_KEY="aap_demo.fleet.legacy_ssh_private_key"

fleet_ssh_key_ensure() (
  local create_if_missing="${1:-false}"
  local root="${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet"
  local legacy="$root/ssh_key" legacy_pub="$root/ssh_key.pub"
  local vault_temp="" generated="" readback="" public_temp="" public_legacy="" archived_legacy="" has_vault=false rc
  local path nodes_exist=false

  mkdir -p "$root" || return 1
  chmod 700 "$root" || return 1
  umask 077
  trap 'for path in "${vault_temp:-}" "${readback:-}" "${public_temp:-}" "${archived_legacy:-}"; do [[ -z "$path" ]] || rm -f -- "$path"; done; if [[ -n "${generated:-}" ]]; then rm -f -- "$generated" "$generated.pub"; fi; if [[ -n "${public_legacy:-}" ]]; then rm -f -- "$public_legacy"; fi' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  vault_temp=$(mktemp "$root/.ssh-key-vault.XXXXXX") || return 1
  readback=$(mktemp "$root/.ssh-key-readback.XXXXXX") || return 1
  public_temp=$(mktemp "$root/.ssh-key-public.XXXXXX") || {
    return 1
  }

  if aap_demo_vault_get "$FLEET_SSH_VAULT_KEY" >"$vault_temp"; then
    has_vault=true
  else
    rc=$?
    if [ "$rc" -ne 1 ]; then
      _err "Unable to read the Fleet SSH identity from the credential Vault"
      return 1
    fi
  fi

  local candidate="" candidate_public=""
  if [ "$has_vault" = true ]; then
    candidate="$vault_temp"
  elif [ -e "$legacy" ] || [ -L "$legacy" ]; then
    [ -f "$legacy" ] && [ -s "$legacy" ] && [ ! -L "$legacy" ] || {
      _err "Legacy Fleet SSH key is unreadable; it was not changed"
      return 1
    }
    candidate="$legacy"
    candidate_public=$(ssh-keygen -y -P '' -f "$candidate" 2>/dev/null) || {
      _err "Existing Fleet SSH identity is not a usable private key; it was not changed"
      return 1
    }
    aap_demo_vault_set_file "$FLEET_SSH_VAULT_KEY" "$candidate" || return 1
  elif [ "$create_if_missing" = true ]; then
    for path in "$root"/node-* "${AAP_DEMO_DIR:-$HOME/.aap-demo}"/nodes/node-*; do
      if [ -e "$path" ]; then
        nodes_exist=true
        break
      fi
    done
    [ "$nodes_exist" = false ] || {
      _err "Fleet nodes exist but their shared SSH key is missing; refusing to generate a replacement"
      return 1
    }
    generated=$(mktemp "$root/.ssh-key-new.XXXXXX") || return 1
    rm -f -- "$generated"
    ssh-keygen -q -t ed25519 -N '' -f "$generated" -C "aap-demo-fleet" || return 1
    candidate="$generated"
    aap_demo_vault_set_file "$FLEET_SSH_VAULT_KEY" "$candidate" || return 1
  else
    _err "Fleet SSH identity is missing from the credential Vault"
    return 1
  fi

  aap_demo_vault_get_file "$FLEET_SSH_VAULT_KEY" "$readback" || {
    _err "Fleet SSH identity could not be read back from the credential Vault"
    return 1
  }
  ssh-keygen -y -P '' -f "$readback" >"$public_temp" 2>/dev/null || {
    _err "Fleet SSH identity in the credential Vault is not a usable private key"
    return 1
  }
  if [ -z "$candidate_public" ]; then
    candidate_public=$(ssh-keygen -y -P '' -f "$candidate" 2>/dev/null) || {
      _err "Existing Fleet SSH identity is not a usable private key; it was not changed"
      return 1
    }
  fi
  if [ "$(awk '{print $1, $2}' <<<"$candidate_public")" \
    != "$(awk '{print $1, $2}' "$public_temp")" ]; then
    _err "Fleet SSH identity does not match the encrypted Vault key; neither copy was changed"
    return 1
  fi

  if [ -e "$legacy" ] || [ -L "$legacy" ]; then
    [ -f "$legacy" ] && [ -s "$legacy" ] && [ ! -L "$legacy" ] || {
      _err "Legacy Fleet SSH key is unreadable; it was not changed"
      return 1
    }
    public_legacy=$(mktemp "$root/.ssh-key-legacy-public.XXXXXX") || return 1
    ssh-keygen -y -P '' -f "$legacy" >"$public_legacy" 2>/dev/null || {
      _err "Legacy Fleet SSH key is unusable; it was not changed"
      return 1
    }
    if [ "$(awk '{print $1, $2}' "$public_legacy")" \
      != "$(awk '{print $1, $2}' "$public_temp")" ]; then
      # A previous version kept this managed secret in the Fleet state
      # directory. Do not overwrite the active key (existing nodes can depend
      # on it), but move the distinct legacy identity into the encrypted Vault
      # before removing its plaintext copy. A second distinct legacy key is
      # suspicious, so preserve it for an explicit operator decision.
      archived_legacy=$(mktemp "$root/.ssh-key-legacy-vault.XXXXXX") || return 1
      if aap_demo_vault_get_file "$FLEET_LEGACY_SSH_VAULT_KEY" "$archived_legacy" 2>/dev/null; then
        if [ "$(ssh-keygen -y -P '' -f "$archived_legacy" 2>/dev/null | awk '{print $1, $2}')" \
          != "$(awk '{print $1, $2}' "$public_legacy")" ]; then
          _err "Legacy Fleet SSH key differs from both managed Vault identities; it was not changed"
          return 1
        fi
      else
        aap_demo_vault_set_file "$FLEET_LEGACY_SSH_VAULT_KEY" "$legacy" || return 1
      fi
      echo "  ✓ Archived the distinct legacy Fleet SSH key in the encrypted Vault"
    fi
    rm -f -- "$legacy" || {
      _err "Could not remove the verified legacy Fleet SSH key"
      return 1
    }
  fi

  chmod 644 "$public_temp" || return 1
  mv -f -- "$public_temp" "$legacy_pub" || return 1
  public_temp=""
)

_fleet_ssh_with_key() {
  local key_file="$1" port=22 option previous="" arg
  shift
  for arg in "$@"; do
    if [ "$previous" = -p ]; then
      port="$arg"
      break
    fi
    case "$arg" in
      -p[0-9]*)
        port="${arg#-p}"
        break
        ;;
    esac
    previous="$arg"
  done
  aap_demo_ssh_prepare_trust "${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet/known_hosts" 127.0.0.1 "$port" || return 1
  ssh -i "$key_file" \
    -o IdentitiesOnly=yes \
    "${AAP_DEMO_SSH_TRUST_OPTS[@]}" \
    -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes "$@"
}

fleet_ssh_key_ready() {
  if [ "${_FLEET_SSH_KEY_READY:-false}" != true ]; then
    fleet_ssh_key_ensure false || return 1
    _FLEET_SSH_KEY_READY=true
  fi
}

fleet_ssh() {
  fleet_ssh_key_ready || return 1
  aap_demo_vault_with_file "$FLEET_SSH_VAULT_KEY" _fleet_ssh_with_key "$@"
}

fleet_admin_password() {
  local index="$1"
  [[ "$index" =~ ^[1-9][0-9]*$ ]] || {
    _err "Invalid Fleet node index"
    return 1
  }
  aap_demo_vault_get "aap_demo.fleet.node_${index}.password"
}

fleet_reconcile_minimum_memory() {
  local index="$1" root="${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet"
  local meta="${root}/node-${index}/meta" current minimum previous_explicit
  [ -f "$meta" ] || return 0
  current=$(sed -n 's/^MEMORY_MB=//p' "$meta" | tail -n 1)
  minimum="${FLEET_MIN_NODE_MEM:-2048}"
  [[ "$current" =~ ^[0-9]+$ ]] && [[ "$minimum" =~ ^[1-9][0-9]*$ ]] || return 0
  [ "$current" -ge "$minimum" ] && return 0

  # Respect an explicit caller choice.  A retained legacy default, however,
  # is upgraded automatically before it can cause intermittent SSH failures.
  if [ -n "${_FLEET_NODE_MEM_EXPLICIT:-}" ]; then
    _err "Fleet node ${index} has ${current} MiB; ${minimum} MiB is required for reliable package management"
    echo "  Restart with: FLEET_NODE_MEM=${minimum} aap-demo fleet node ${index} restart" >&2
    return 1
  fi
  if ! declare -F fleet_node_power >/dev/null; then
    return 0
  fi

  printf '  ⚠ Fleet node %s has %s MiB; restarting it with the %s MiB reliability minimum\n' \
    "$index" "$current" "$minimum"
  previous_explicit="${_FLEET_NODE_MEM_EXPLICIT:-}"
  _FLEET_NODE_MEM_EXPLICIT="$minimum"
  if ! fleet_node_power "$index" restart; then
    _FLEET_NODE_MEM_EXPLICIT="$previous_explicit"
    _err "Fleet node ${index} could not be restarted with ${minimum} MiB"
    return 1
  fi
  _FLEET_NODE_MEM_EXPLICIT="$previous_explicit"
}

_fleet_ssh_public_key_from_file() {
  ssh-keygen -y -f "$1"
}

fleet_recover_key_access_with_sshpass() {
  local index="$1" port="$2" password public_key recovery_rc
  command -v sshpass >/dev/null 2>&1 || {
    echo "  sshpass is unavailable; cannot use password recovery for Fleet node ${index}" >&2
    return 1
  }
  password=$(fleet_admin_password "$index") || return 1
  [ -n "$password" ] || return 1
  public_key=$(aap_demo_vault_with_file "$FLEET_SSH_VAULT_KEY" _fleet_ssh_public_key_from_file) || {
    unset password
    return 1
  }
  [[ "$public_key" == ssh-*' '* && "$public_key" != *$'\n'* ]] || {
    unset password
    return 1
  }

  echo "  Key-based Fleet SSH failed; attempting guarded password recovery for node ${index}..." >&2
  # SSHPASS is deliberately environment-only (never an argument). The first
  # stdin line authenticates sudo; the remaining lines repair ansible's key.
  if {
    printf '%s\n' "$password"
    printf 'set -e\n'
    printf 'public_key=%q\n' "$public_key"
    cat <<'REMOTE'
sudo install -d -m 700 -o ansible -g ansible /home/ansible/.ssh
sudo touch /home/ansible/.ssh/authorized_keys
sudo grep -Fxq -- "$public_key" /home/ansible/.ssh/authorized_keys ||
  printf '%s\n' "$public_key" | sudo tee -a /home/ansible/.ssh/authorized_keys >/dev/null
sudo chown ansible:ansible /home/ansible/.ssh/authorized_keys
sudo chmod 600 /home/ansible/.ssh/authorized_keys
if command -v restorecon >/dev/null; then sudo restorecon -R /home/ansible/.ssh; fi
sudo sshd -t
sudo systemctl reload sshd || sudo systemctl restart sshd
REMOTE
  } | SSHPASS="$password" sshpass -e ssh \
    -o IdentitiesOnly=yes -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no -o KbdInteractiveAuthentication=no \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet/known_hosts" \
    -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=no \
    -p "$port" admin@127.0.0.1 'sudo -S -p "" bash -s'; then
    recovery_rc=0
  else
    recovery_rc=$?
  fi
  unset password
  [ "$recovery_rc" -eq 0 ] || return "$recovery_rc"

  # Do not trust the recovery transport alone: require the normal Vault key
  # path to succeed before resuming automated registration.
  fleet_ssh -p "$port" ansible@127.0.0.1 'true'
}

fleet_reconcile_access() {
  local index="$1" root="${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet"
  [[ "$index" =~ ^[1-9][0-9]*$ ]] || {
    _err "Invalid Fleet node index"
    return 1
  }
  fleet_ssh_key_ready || return 1
  local port password hash rc=0 guest_ip
  port=$(sed -n 's/^PORT=//p' "$root/node-$index/meta")
  [[ "$port" =~ ^[0-9]+$ ]] || {
    _err "Invalid Fleet SSH port"
    return 1
  }
  fleet_reconcile_minimum_memory "$index" || return 1
  _aap_demo_vault_require_tools || return 1
  password=$(fleet_admin_password "$index") || rc=$?
  [ "$rc" -ne 2 ] || return 1
  if [ -z "$password" ]; then
    password=$("$AAP_DEMO_VAULT_PYTHON" -c 'import secrets; print(secrets.token_urlsafe(24))') || return 1
    aap_demo_vault_set "aap_demo.fleet.node_${index}.password" "$password" || return 1
  fi
  hash=$(printf '%s\n' "$password" | openssl passwd -6 -stdin) || return 1
  unset password
  # Only the password hash crosses SSH stdin; no secrets enter child-process arguments.
  if ! {
    printf 'set -e\n'
    printf 'password_hash=%q\n' "$hash"
    cat <<'REMOTE'
id admin >/dev/null 2>&1 || sudo useradd --create-home --shell /bin/bash admin
sudo usermod --shell /bin/bash admin
printf 'admin:%s\n' "$password_hash" | sudo chpasswd -e
sudo install -d -m 700 -o admin -g admin /home/admin/.ssh
sudo touch /home/admin/.ssh/authorized_keys
while IFS= read -r key; do
  sudo grep -Fxq -- "$key" /home/admin/.ssh/authorized_keys ||
    printf '%s\n' "$key" | sudo tee -a /home/admin/.ssh/authorized_keys >/dev/null
done <"$HOME/.ssh/authorized_keys"
sudo chown admin:admin /home/admin/.ssh/authorized_keys
sudo chmod 600 /home/admin/.ssh/authorized_keys
if command -v restorecon >/dev/null; then sudo restorecon -R /home/admin/.ssh; fi
case " $(id -nG admin) " in
  *" wheel "*) sudo gpasswd -d admin wheel >/dev/null ;;
esac
sudo_file=$(mktemp)
printf 'admin     ALL=(ALL)       ALL\n' >"$sudo_file"
sudo visudo -cf "$sudo_file" >/dev/null
sudo install -m 440 -o root -g root "$sudo_file" /etc/sudoers.d/aap-demo-admin
rm -f "$sudo_file"
sudo visudo -c >/dev/null
if ! sudo test -f /home/admin/.ssh/id_ed25519; then
  sudo -u admin ssh-keygen -q -t ed25519 -N '' -f /home/admin/.ssh/id_ed25519 -C "admin@$(hostname)"
fi
if ! sudo test -f /home/admin/.ssh/id_ed25519.pub; then
  sudo -u admin sh -c 'ssh-keygen -y -f "$HOME/.ssh/id_ed25519" >"$HOME/.ssh/id_ed25519.pub"'
fi
sudo chown admin:admin /home/admin/.ssh/id_ed25519 /home/admin/.ssh/id_ed25519.pub
sudo chmod 600 /home/admin/.ssh/id_ed25519
sudo chmod 644 /home/admin/.ssh/id_ed25519.pub
if command -v restorecon >/dev/null; then sudo restorecon -R /home/admin/.ssh; fi
# A Match block permits password login for admin without enabling it for every account.
ssh_config=$(mktemp)
printf 'Match User admin\n    PasswordAuthentication yes\nMatch all\n' >"$ssh_config"
if ! sudo cmp -s "$ssh_config" /etc/ssh/sshd_config.d/00-aap-demo-admin.conf; then
  sudo install -m 644 -o root -g root "$ssh_config" /etc/ssh/sshd_config.d/00-aap-demo-admin.conf
  sudo sshd -t
  sudo systemctl reload sshd
fi
rm -f "$ssh_config"
REMOTE
  } | fleet_ssh -p "$port" ansible@127.0.0.1 'bash -s'; then
    if [ "${FLEET_SSH_PASSWORD_RECOVERY:-true}" = true ] \
      && [ "${_FLEET_SSH_PASSWORD_RECOVERY_ACTIVE:-false}" != true ]; then
      _FLEET_SSH_PASSWORD_RECOVERY_ACTIVE=true
      if fleet_recover_key_access_with_sshpass "$index" "$port" \
        && fleet_reconcile_access "$index"; then
        _FLEET_SSH_PASSWORD_RECOVERY_ACTIVE=false
        return 0
      fi
      _FLEET_SSH_PASSWORD_RECOVERY_ACTIVE=false
    fi
    _err "Could not configure admin SSH access for Fleet node $index after key and password recovery attempts"
    return 1
  fi
  guest_ip=$(fleet_ssh -p "$port" admin@127.0.0.1 \
    "hostname -I | awk '{print \$1}'") || return 1
  printf '%s\n' "$guest_ip" >"$root/node-$index/guest_ip"
  printf '  ✓ Fleet node %s: admin SSH ready at 127.0.0.1:%s (guest %s)\n' "$index" "$port" "$guest_ip"
}

fleet_reconcile_running_access() {
  local root="${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet" meta index pid
  for meta in "$root"/node-*/meta; do
    [ -f "$meta" ] || continue
    index=$(sed -n 's/^INDEX=//p' "$meta")
    pid=$(sed -n 's/^PID=//p' "$meta")
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      fleet_reconcile_access "$index" || return 1
    fi
  done
}

fleet_access_inventory() {
  local mode="${1:-omit}" root="${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet"
  local result='[]' meta index port hostname pid state guest_ip password rc
  for meta in "$root"/node-*/meta; do
    [ -f "$meta" ] || continue
    index=$(sed -n 's/^INDEX=//p' "$meta")
    port=$(sed -n 's/^PORT=//p' "$meta")
    hostname=$(sed -n 's/^HOSTNAME=//p' "$meta")
    pid=$(sed -n 's/^PID=//p' "$meta")
    [[ "$index" =~ ^[1-9][0-9]*$ ]] && [[ "$port" =~ ^[0-9]+$ ]] || {
      _err "Invalid Fleet metadata: $meta"
      return 1
    }
    state=stopped
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then state=running; fi
    guest_ip=""
    [ ! -f "$root/node-$index/guest_ip" ] || guest_ip=$(cat "$root/node-$index/guest_ip")
    password=""
    case "$mode" in
      include)
        rc=0
        password=$(fleet_admin_password "$index") || rc=$?
        [ "$rc" -ne 2 ] || return 1
        ;;
      redact) password='******' ;;
      omit) ;;
      *)
        _err "Invalid Fleet secret mode"
        return 1
        ;;
    esac
    result=$(jq -c --argjson index "$index" --argjson port "$port" \
      --arg hostname "$hostname" --arg state "$state" --arg guest_ip "$guest_ip" \
      --arg password "$password" \
      '. + [{index:$index, hostname:$hostname, state:$state, ssh_host:"127.0.0.1",
        ssh_port:$port, guest_ip:(if $guest_ip == "" then null else $guest_ip end),
        username:"admin", password:(if $password == "" then null else $password end),
        terminal_url:("/terminal?node=" + ($index|tostring))}]' <<<"$result") || return 1
  done
  printf '%s\n' "$result"
}

fleet_reconcile_existing_inventory() {
  local nodes
  nodes=$(fleet_access_inventory omit) || return 1
  if jq -e 'any(.[]; .state == "running")' <<<"$nodes" >/dev/null; then
    bash "${FLEET_ACCESS_DIR}/../aap-demo.sh" fleet register
  elif [ "$nodes" != '[]' ]; then
    printf 'Fleet nodes are stopped; start them before reconciling the AAP inventory.\n'
  fi
}
