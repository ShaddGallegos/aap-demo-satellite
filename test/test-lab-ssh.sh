#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export AAP_DEMO_DIR="$TEST_DIR/state"
export HOME="$TEST_DIR/home"
mkdir -p "$AAP_DEMO_DIR/fleet"
ssh-keygen -q -t ed25519 -N '' -f "$AAP_DEMO_DIR/fleet/ssh_key"
source "$REPO_ROOT/includes/lab-ssh.sh"
_err() { printf 'ERROR: %s\n' "$*" >&2; }
(
  systemctl() { return 0; }
  ip() { printf '192.168.122.20 dev virbr0 src 192.168.122.1\n'; }
  sudo() { "$@"; }
  firewall-cmd() {
    local arg mode=runtime rule=""
    for arg in "$@"; do
      case "$arg" in
        --get-zone-of-interface=*) printf libvirt; return 0 ;;
        --permanent) mode=permanent ;;
        --query-rich-rule=*) rule="${arg#*=}"; grep -Fxq "$mode $rule" "$TEST_DIR/firewall"; return $? ;;
        --add-rich-rule=*) rule="${arg#*=}"; printf '%s %s\n' "$mode" "$rule" >>"$TEST_DIR/firewall"; return 0 ;;
      esac
    done
    return 1
  }
  : >"$TEST_DIR/firewall"
  peers='[{"kind":"satellite","port":22},{"kind":"fleet","port":2201}]'
  lab_ssh_open_satellite_forwards 192.0.2.10 "$peers"
  lab_ssh_open_satellite_forwards 192.0.2.10 "$peers"
  [[ "$(wc -l <"$TEST_DIR/firewall")" == 2 ]]
  grep -Fq 'source address="192.168.122.20/32" destination address="192.0.2.10/32" port port="2201"' "$TEST_DIR/firewall"
)
lab_ssh_open_satellite_forwards() { :; }
lab_ssh_inventory() {
  printf '[{"kind":"fleet","name":"aap-fleet-node-1","port":2201},
    {"kind":"satellite","name":"satellite","port":22},
    {"kind":"crc","name":"aap-demo-crc","port":2222}]'
}
lab_ssh_connect() {
  if [ "$1" = crc ]; then
    declare -F _crc_exec >/dev/null || return 1
  fi
  cat >"$TEST_DIR/payload-$1"
  bash -n "$TEST_DIR/payload-$1"
}
INFRA=crc lab_reconcile_ssh 192.0.2.10 >"$TEST_DIR/output"
! grep -q 'PRIVATE KEY' "$TEST_DIR/output"
# Decode only the generated assignments; never execute guest account changes here.
for peer in fleet satellite crc; do
  eval "$(head -n 5 "$TEST_DIR/payload-$peer" | tail -n 4)"
  [[ "$lab_kind" == "$peer" ]]
  cmp <(printf '%s\n' "$lab_private_key") "$AAP_DEMO_DIR/fleet/ssh_key"
  [[ "$lab_public_key" == "$(ssh-keygen -y -f "$AAP_DEMO_DIR/fleet/ssh_key")" ]]
  grep -q 'StrictHostKeyChecking no' <<<"$lab_config"
  grep -q 'User core' <<<"$lab_config"
  grep -q 'ProxyJump admin@aap-fleet-node-1' <<<"$lab_config"
  printf '%s' "$lab_config" >"$TEST_DIR/ssh-config"
  ssh -G -T -F "$TEST_DIR/ssh-config" crc >"$TEST_DIR/expanded-config"
  grep -q '^proxyjump admin@aap-fleet-node-1$' "$TEST_DIR/expanded-config"
done
cp "$TEST_DIR/payload-crc" "$TEST_DIR/before"
lab_reconcile_ssh 192.0.2.10 >"$TEST_DIR/output"
cmp "$TEST_DIR/before" "$TEST_DIR/payload-crc"
lab_ssh_connect() { cat >/dev/null; return 1; }
if lab_reconcile_ssh 192.0.2.10 >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: failed SSH reconciliation was ignored" >&2; exit 1
fi

# Execute account reconciliation in a fake filesystem with no privileged operations.
source "$REPO_ROOT/includes/lab-ssh-remote.sh"
mkdir -p "$TEST_DIR/accounts"/{admin,root,core}/.ssh
getent() { printf '%s:x:1000:1000::%s/accounts/%s:/bin/bash\n' "$2" "$TEST_DIR" "$2"; }
id() { if [ "${1:-}" = -gn ]; then printf users; fi; }
chown() { :; }
restorecon() { :; }
install() {
  if [ "${1:-}" = -d ]; then mkdir -p "${@: -1}"; else return 1; fi
}
sshd() { printf 'authorizedkeyscommand /usr/libexec/ssh-key-dir %%u\n'; }
lab_kind=crc
printf 'original ignition key\n' >"$TEST_DIR/accounts/core/.ssh/authorized_keys"
printf 'Host personal\n    HostName personal.example\n' >"$TEST_DIR/accounts/core/.ssh/config"
lab_ssh_apply
lab_ssh_apply
[[ "$(cat "$TEST_DIR/accounts/core/.ssh/authorized_keys")" == 'original ignition key' ]]
[[ "$(stat -c %a "$TEST_DIR/accounts/core/.ssh/aap-demo-shared-key")" == 600 ]]
[[ "$(grep -c '^Include ~/.ssh/aap-demo-lab-config$' "$TEST_DIR/accounts/core/.ssh/config")" == 1 ]]
grep -q 'Host personal' "$TEST_DIR/accounts/core/.ssh/config"
[[ "$(grep -c '^# BEGIN AAP-DEMO STACK$' "$TEST_DIR/accounts/core/.ssh/authorized_keys.d/aap-demo")" == 1 ]]
cmp "$TEST_DIR/accounts/core/.ssh/aap-demo-shared-key" "$AAP_DEMO_DIR/fleet/ssh_key"
[[ ! -e "$TEST_DIR/accounts/root/.ssh/aap-demo-shared-key" ]]
lab_ssh_configure_root() { echo root-policy >>"$TEST_DIR/policy-log"; }
lab_kind=satellite
printf 'personal authorized key\n' >"$TEST_DIR/accounts/admin/.ssh/authorized_keys"
printf 'personal private identity\n' >"$TEST_DIR/accounts/admin/.ssh/id_ed25519"
lab_ssh_apply
lab_ssh_apply
for account in admin root; do
  cmp "$TEST_DIR/accounts/$account/.ssh/aap-demo-shared-key" "$AAP_DEMO_DIR/fleet/ssh_key"
  [[ "$(stat -c %a "$TEST_DIR/accounts/$account/.ssh/aap-demo-shared-key")" == 600 ]]
  [[ "$(grep -c '^# BEGIN AAP-DEMO STACK$' "$TEST_DIR/accounts/$account/.ssh/authorized_keys")" == 1 ]]
done
grep -q 'personal authorized key' "$TEST_DIR/accounts/admin/.ssh/authorized_keys"
[[ "$(cat "$TEST_DIR/accounts/admin/.ssh/id_ed25519")" == 'personal private identity' ]]
echo "PASS: managed shared keys are repeatable, private, preserve local config, and use core rather than root on CRC"
