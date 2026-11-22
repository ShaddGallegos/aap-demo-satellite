#!/usr/bin/env bash
# Regression test for merging legacy credentials into the shared user Vault.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

mkdir -p "${TEST_HOME}/.ansible/conf"
printf 'vault-password\n' >"${TEST_HOME}/.ansible/conf/.vaultpass_microshift.txt"
chmod 600 "${TEST_HOME}/.ansible/conf/.vaultpass_microshift.txt"
printf 'shared-password\n' >"${TEST_HOME}/.ansible/conf/.vaultpass.txt"
chmod 600 "${TEST_HOME}/.ansible/conf/.vaultpass.txt"
cat >"${TEST_HOME}/shared.yml" <<'EOF'
existing_setting: keep-me
aap_demo:
  existing_secret: keep-this-too
EOF
ansible-vault encrypt \
  --vault-password-file "${TEST_HOME}/.ansible/conf/.vaultpass.txt" \
  --output "${TEST_HOME}/.ansible/conf/env.yml" \
  "${TEST_HOME}/shared.yml"
cat >"${TEST_HOME}/legacy.yml" <<'EOF'
aap_demo:
  existing_secret: do-not-overwrite
  redhat:
    offline_token: legacy-token
EOF
ansible-vault encrypt \
  --vault-password-file "${TEST_HOME}/.ansible/conf/.vaultpass_microshift.txt" \
  --output "${TEST_HOME}/.ansible/conf/env_microshift.yml" \
  "${TEST_HOME}/legacy.yml"

HOME="$TEST_HOME" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -euo pipefail
_err() { printf 'ERROR: %s\n' "$*" >&2; }
source "${REPO_ROOT}/includes/credential-vault.sh"
value=$(aap_demo_vault_get "aap_demo.redhat.offline_token")
[ "$value" = "legacy-token" ]
[ "$(aap_demo_vault_get "aap_demo.existing_secret")" = "keep-this-too" ]
[ -f "$HOME/.ansible/conf/env.yml" ]
[ -f "$HOME/.ansible/conf/.vaultpass.txt" ]
[ ! -e "$HOME/.ansible/conf/env_microshift.yml" ]
[ ! -e "$HOME/.ansible/conf/.vaultpass_microshift.txt" ]
ansible-vault view --vault-password-file "$HOME/.ansible/conf/.vaultpass.txt" \
  "$HOME/.ansible/conf/env.yml" |
  python3 -c 'import sys,yaml; assert (yaml.safe_load(sys.stdin) or {}).get("existing_setting") == "keep-me"'
EOF

mkdir -p "${TEST_HOME}/venv/bin"
cat >"${TEST_HOME}/venv/bin/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-c" ] && [ "${2:-}" = "import yaml" ]; then
  exit 1
fi
exit 97
EOF
chmod +x "${TEST_HOME}/venv/bin/python3"
cat >"${TEST_HOME}/venv/bin/ansible-vault" <<'EOF'
#!/usr/bin/env bash
exit 98
EOF
chmod +x "${TEST_HOME}/venv/bin/ansible-vault"
HOME="$TEST_HOME" PATH="${TEST_HOME}/venv/bin:${PATH}" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -euo pipefail
_err() { printf 'ERROR: %s\n' "$*" >&2; }
source "${REPO_ROOT}/includes/credential-vault.sh"
[ "$(aap_demo_vault_get "aap_demo.redhat.offline_token")" = "legacy-token" ]
[ "$AAP_DEMO_VAULT_PYTHON" != "$HOME/venv/bin/python3" ]
[ "$AAP_DEMO_ANSIBLE_VAULT" != "$HOME/venv/bin/ansible-vault" ]
EOF

HOME="$TEST_HOME" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -euo pipefail
_err() { printf 'ERROR: %s\n' "$*" >&2; }
source "${REPO_ROOT}/includes/credential-vault.sh"
aap_demo_vault_remove_managed
[ -f "$HOME/.ansible/conf/env.yml" ]
[ -f "$HOME/.ansible/conf/.vaultpass.txt" ]
ansible-vault view --vault-password-file "$HOME/.ansible/conf/.vaultpass.txt" \
  "$HOME/.ansible/conf/env.yml" |
  python3 -c '
import sys
import yaml
data = yaml.safe_load(sys.stdin) or {}
assert data.get("existing_setting") == "keep-me"
assert "aap_demo" not in data
'
EOF

ONLY_HOME=$(mktemp -d)
HOME="$ONLY_HOME" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -euo pipefail
_err() { printf 'ERROR: %s\n' "$*" >&2; }
source "${REPO_ROOT}/includes/credential-vault.sh"
aap_demo_vault_set "aap_demo.redhat.offline_token" "managed-only"
cp "$AAP_DEMO_VAULT_PASSWORD_FILE" "$HOME/password-before"
aap_demo_vault_set "aap_demo.redhat.offline_token" "updated"
cmp "$AAP_DEMO_VAULT_PASSWORD_FILE" "$HOME/password-before"
aap_demo_vault_remove_managed
# The shared Vault file is preserved even when no aap-demo data remains.
[ -f "$HOME/.ansible/conf/env.yml" ]
ansible-vault view --vault-password-file "$HOME/.ansible/conf/.vaultpass.txt" \
  "$HOME/.ansible/conf/env.yml" |
  python3 -c '
import sys
import yaml
data = yaml.safe_load(sys.stdin) or {}
assert "aap_demo" not in data
assert "ah_offline_token" not in data
'
cmp "$AAP_DEMO_VAULT_PASSWORD_FILE" "$HOME/password-before"
# An orphaned shared password file is left alone and reused by the next set.
rm -f "$HOME/.ansible/conf/env.yml"
printf 'orphaned-password\n' >"$HOME/.ansible/conf/.vaultpass.txt"
aap_demo_vault_remove_managed
[ "$(cat "$AAP_DEMO_VAULT_PASSWORD_FILE")" = orphaned-password ]
aap_demo_vault_set "aap_demo.redhat.offline_token" "new-vault"
[ "$(cat "$AAP_DEMO_VAULT_PASSWORD_FILE")" = orphaned-password ]
[ "$(aap_demo_vault_get "aap_demo.redhat.offline_token")" = new-vault ]
aap_demo_vault_remove_managed
[ -f "$AAP_DEMO_VAULT_FILE" ]
: >"$AAP_DEMO_VAULT_PASSWORD_FILE"
if aap_demo_vault_set "aap_demo.redhat.offline_token" "must-not-save"; then
  echo "FAIL: an existing empty shared password file was accepted" >&2
  exit 1
fi
[ -e "$AAP_DEMO_VAULT_PASSWORD_FILE" ]
[ ! -s "$AAP_DEMO_VAULT_PASSWORD_FILE" ]
[ -f "$AAP_DEMO_VAULT_FILE" ]
EOF
rm -rf -- "$ONLY_HOME"

mkdir -p "$TEST_HOME/transaction-home"
HOME="$TEST_HOME/transaction-home" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -euo pipefail
_err() { printf 'ERROR: %s\n' "$*" >&2; }
source "${REPO_ROOT}/includes/credential-vault.sh"
aap_demo_vault_set "aap_demo.transaction.secret" "original"
cp "$AAP_DEMO_VAULT_FILE" "$HOME/vault-before-failures"

mv() {
  if [ "${2:-}" = "$AAP_DEMO_VAULT_FILE" ]; then
    printf '%s\n' "$1" >"$HOME/failed-mv-source"
    return 73
  fi
  command mv "$@"
}

if aap_demo_vault_set "aap_demo.transaction.secret" "replacement"; then
  echo "FAIL: Vault set ignored a failed install" >&2
  exit 1
fi
cmp "$HOME/vault-before-failures" "$AAP_DEMO_VAULT_FILE"
[ "$(aap_demo_vault_get "aap_demo.transaction.secret")" = original ]
[ ! -e "$(cat "$HOME/failed-mv-source")" ]
if compgen -G "$HOME/.ansible/conf/.env-aap-demo.vault.*" >/dev/null \
  || compgen -G "$HOME/.ansible/conf/.env-aap-demo.plain.*" >/dev/null; then
  echo "FAIL: failed Vault set left a temporary file" >&2
  exit 1
fi

if aap_demo_vault_delete "aap_demo.transaction.secret"; then
  echo "FAIL: Vault delete ignored a failed install" >&2
  exit 1
fi
cmp "$HOME/vault-before-failures" "$AAP_DEMO_VAULT_FILE"
[ "$(aap_demo_vault_get "aap_demo.transaction.secret")" = original ]
[ ! -e "$(cat "$HOME/failed-mv-source")" ]
if compgen -G "$HOME/.ansible/conf/.env-aap-demo.vault.*" >/dev/null \
  || compgen -G "$HOME/.ansible/conf/.env-aap-demo.plain.*" >/dev/null; then
  echo "FAIL: failed Vault delete left a temporary file" >&2
  exit 1
fi
EOF

echo "PASS: merges and removes managed credentials without changing unrelated Vault data"
