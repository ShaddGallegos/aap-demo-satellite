#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export HOME="$TEST_DIR/home" AAP_DEMO_DIR="$TEST_DIR/state"
mkdir -p "$HOME" "$AAP_DEMO_DIR/fleet"
source "$REPO_ROOT/includes/fleet-access.sh"

ssh-keygen -q -t ed25519 -N '' -f "$AAP_DEMO_DIR/fleet/ssh_key"
cp "$AAP_DEMO_DIR/fleet/ssh_key" "$TEST_DIR/expected-key"
chmod 600 "$TEST_DIR/expected-key"
fleet_ssh_key_ensure false
[[ ! -e "$AAP_DEMO_DIR/fleet/ssh_key" ]]
[[ -s "$AAP_DEMO_DIR/fleet/ssh_key.pub" ]]
cmp "$TEST_DIR/expected-key" <(aap_demo_vault_get_file \
  "$FLEET_SSH_VAULT_KEY" "$TEST_DIR/readback" >/dev/null && cat "$TEST_DIR/readback")
# shellcheck disable=SC2016
grep -q '^\$ANSIBLE_VAULT;' "$AAP_DEMO_VAULT_FILE"
if grep -q 'BEGIN OPENSSH PRIVATE KEY' "$AAP_DEMO_VAULT_FILE"; then
  echo "FAIL: plaintext private key was written to the Vault file" >&2
  exit 1
fi

_check_materialized_key() {
  local path="$1"
  [[ "$(stat -c %a "$path")" == 600 ]]
  cmp "$TEST_DIR/expected-key" "$path"
  printf ready
}
[[ "$(aap_demo_vault_with_file "$FLEET_SSH_VAULT_KEY" _check_materialized_key)" == ready ]]
_fail_after_materialize() { return 42; }
if aap_demo_vault_with_file "$FLEET_SSH_VAULT_KEY" _fail_after_materialize; then
  echo "FAIL: key callback failure was ignored" >&2
  exit 1
fi
_interrupt_after_materialize() { kill -TERM "$BASHPID"; }
if aap_demo_vault_with_file "$FLEET_SSH_VAULT_KEY" _interrupt_after_materialize; then
  echo "FAIL: key callback interruption was ignored" >&2
  exit 1
fi
if compgen -G "$HOME/.ansible/conf/.aap-demo-secret.*" >/dev/null; then
  echo "FAIL: materialized key file was not cleaned up" >&2
  exit 1
fi

ssh() {
  local key_file="" arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    shift
    if [ "$arg" = -i ]; then
      key_file="$1"
      shift
    fi
  done
  [[ -s "$key_file" ]]
  cmp "$TEST_DIR/expected-key" "$key_file"
  printf '%s\n' "$key_file" >"$TEST_DIR/ssh-key-path"
}
cp "$TEST_DIR/expected-key" "$AAP_DEMO_DIR/fleet/ssh_key"
fleet_stack_ssh 2201 'true'
[[ ! -e "$AAP_DEMO_DIR/fleet/ssh_key" ]]
[[ ! -e "$(cat "$TEST_DIR/ssh-key-path")" ]]
unset -f ssh

mkdir -p "$TEST_DIR/invalid-home" "$TEST_DIR/invalid-state/fleet"
HOME="$TEST_DIR/invalid-home" AAP_DEMO_DIR="$TEST_DIR/invalid-state" \
  REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -euo pipefail
source "$REPO_ROOT/includes/fleet-access.sh"
printf 'not an OpenSSH private key\n' >"$AAP_DEMO_DIR/fleet/ssh_key"
cp "$AAP_DEMO_DIR/fleet/ssh_key" "$HOME/legacy-key"
if fleet_ssh_key_ensure false; then
  echo "FAIL: invalid legacy key was accepted" >&2
  exit 1
fi
cmp "$HOME/legacy-key" "$AAP_DEMO_DIR/fleet/ssh_key"
[[ ! -e "$AAP_DEMO_VAULT_FILE" ]]
EOF

cat >"$TEST_DIR/ansible-vault-interrupt" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) exit 0 ;;
  view) exec /usr/bin/ansible-vault "$@" ;;
  encrypt) kill -TERM "$PPID"; exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod 700 "$TEST_DIR/ansible-vault-interrupt"
if AAP_DEMO_ANSIBLE_VAULT="$TEST_DIR/ansible-vault-interrupt" \
  aap_demo_vault_set_file "$FLEET_SSH_VAULT_KEY" "$TEST_DIR/expected-key" \
  >/dev/null 2>&1; then
  echo "FAIL: interrupted Vault encryption was reported as success" >&2
  exit 1
fi
if compgen -G "$HOME/.ansible/conf/.env-aap-demo.plain.*" >/dev/null \
  || compgen -G "$HOME/.ansible/conf/.env-aap-demo.vault.*" >/dev/null; then
  echo "FAIL: interrupted Vault update left a plaintext or partial temp file" >&2
  exit 1
fi

ssh-keygen -q -t ed25519 -N '' -f "$AAP_DEMO_DIR/fleet/ssh_key"
cp "$AAP_DEMO_DIR/fleet/ssh_key" "$TEST_DIR/mismatched-key"
if fleet_ssh_key_ensure false; then
  echo "FAIL: a mismatched legacy identity was accepted" >&2
  exit 1
fi
cmp "$TEST_DIR/mismatched-key" "$AAP_DEMO_DIR/fleet/ssh_key"
cmp "$TEST_DIR/expected-key" <(aap_demo_vault_get_file \
  "$FLEET_SSH_VAULT_KEY" "$TEST_DIR/readback" >/dev/null && cat "$TEST_DIR/readback")

printf 'unreadable-vault-password\n' >"$AAP_DEMO_VAULT_PASSWORD_FILE"
chmod 600 "$AAP_DEMO_VAULT_PASSWORD_FILE"
if fleet_ssh_key_ensure true; then
  echo "FAIL: unreadable Vault was treated as a missing identity" >&2
  exit 1
fi
cmp "$TEST_DIR/mismatched-key" "$AAP_DEMO_DIR/fleet/ssh_key"

(
  export HOME="$TEST_DIR/nodes-home" AAP_DEMO_DIR="$TEST_DIR/nodes-state"
  mkdir -p "$HOME" "$AAP_DEMO_DIR/fleet/node-1"
  unset _AAP_DEMO_CREDENTIAL_VAULT_LOADED AAP_DEMO_VAULT_FILE AAP_DEMO_VAULT_PASSWORD_FILE
  source "$REPO_ROOT/includes/credential-vault.sh"
  if fleet_ssh_key_ensure true; then
    echo "FAIL: missing key was regenerated while Fleet nodes existed" >&2
    exit 1
  fi
  [[ ! -e "$AAP_DEMO_DIR/fleet/ssh_key" ]]
  [[ ! -e "$AAP_DEMO_DIR/fleet/ssh_key.pub" ]]
  [[ ! -s "$AAP_DEMO_VAULT_FILE" ]]
)

echo "PASS: Fleet SSH identity migration, Vault readback, failure handling, and temporary cleanup"
