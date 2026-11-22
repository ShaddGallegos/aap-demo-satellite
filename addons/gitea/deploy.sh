#!/usr/bin/env bash
# ADDON_REQUIRES_AAP=false
set -euo pipefail

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../includes/fleet-access.sh
source "$ADDON_DIR/../../includes/fleet-access.sh"

if [ "$#" -gt 1 ]; then
  printf 'ERROR: Unsupported Gitea arguments; data purge is deliberately not supported.\n' >&2
  exit 2
fi

_gitea_run() {
  local key="$1"
  shift
  python3 "$ADDON_DIR/manage.py" --ssh-key "$key" "$@"
}

case "${1:-deploy}" in
  --delete | delete)
    python3 "$ADDON_DIR/manage.py" stop
    ;;
  --preflight)
    python3 "$ADDON_DIR/manage.py" preflight
    ;;
  deploy)
    fleet_ssh_key_ensure true
    aap_demo_vault_with_file "$FLEET_SSH_VAULT_KEY" _gitea_run deploy
    ;;
  *)
    printf 'ERROR: Usage: deploy.sh [--delete|--preflight]\n' >&2
    exit 2
    ;;
esac
