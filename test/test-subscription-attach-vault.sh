#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Sourcing exposes helpers without running the addon main function.
# shellcheck source=../addons/subscription-attach/deploy.sh
source "$ROOT/addons/subscription-attach/deploy.sh"

aap_demo_vault_get() {
  case "$1" in
    aap_demo.redhat.cdn_username) printf '%s' 'fixture-user' ;;
    aap_demo.redhat.cdn_password) printf '%s' 'fixture-password' ;;
    *) return 1 ;;
  esac
}

REDHAT_SUBSCRIPTION_USERNAME=""
REDHAT_SUBSCRIPTION_PASSWORD=""
QUIET=true
output=$(mktemp)
trap 'rm -f "$output"' EXIT
prompt_redhat_credentials >"$output"
[ "$REDHAT_SUBSCRIPTION_USERNAME" = fixture-user ]
[ "$REDHAT_SUBSCRIPTION_PASSWORD" = fixture-password ]

attach_function=$(sed -n '/^attach_subscription() {/,/^}$/p' "$ROOT/addons/subscription-attach/deploy.sh")
printf '%s\n' "$attach_function" | grep -Fq -- '--data-binary @-'
if printf '%s\n' "$attach_function" | grep -Fq -- '-d "$subscriptions_payload"'; then
  echo 'FAIL: subscription credentials are passed on the curl command line' >&2
  exit 1
fi

if rg -q 'redhat-subscription-credentials|REDHAT_SUBSCRIPTION_CREDENTIALS_FILE' \
  "$ROOT/addons/subscription-attach" --glob '*.sh' --glob '*.md'; then
  echo 'FAIL: subscription attachment retains a plaintext credential-file path' >&2
  exit 1
fi

echo 'PASS: subscription attachment reads encrypted CDN credentials without curl argument exposure'
