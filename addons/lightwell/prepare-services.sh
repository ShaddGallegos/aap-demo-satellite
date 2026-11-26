#!/usr/bin/env bash
# Explicit preparation of independent, retained Lightwell infrastructure.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../includes/fleet-access.sh"
ACTION="${1:-services}"
case "$ACTION" in
  services) ;;
  runner)
    source "$HERE/../../includes/addon-wire.sh"
    LIGHTWELL_AO_ROUTE=$(wire_ao_route_host)
    export LIGHTWELL_AO_ROUTE
    ;;
  *)
    echo "ERROR: Usage: prepare-services.sh [services|runner]" >&2
    exit 2
    ;;
esac
prepare_with_key() {
  python3 "$HERE/prepare.py" "$ACTION" --ssh-key "$1"
}
fleet_ssh_key_ready
aap_demo_vault_with_file "$FLEET_SSH_VAULT_KEY" prepare_with_key
