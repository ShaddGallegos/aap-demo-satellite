#!/usr/bin/env bash
# ADDON_REQUIRES_AAP=true
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-deploy}"
case "$ACTION" in
  deploy | --prepare | --delete | --preflight) ;;
  *) echo 'ERROR: Usage: deploy.sh [--prepare|--delete|--preflight]' >&2; exit 2 ;;
esac
if [ "$ACTION" = --prepare ]; then
  bash "$SCRIPT_DIR/prepare-services.sh" services
  bash "$SCRIPT_DIR/prepare-services.sh" runner
fi
if [ "$ACTION" != --delete ]; then
  python3 "$SCRIPT_DIR/provision.py" --preflight
fi
[ "$ACTION" != --preflight ] || exit 0

# shellcheck source=../../includes/secure-curl.sh
source "$REPO_ROOT/includes/secure-curl.sh"
# shellcheck source=../../includes/addon-wire.sh
source "$REPO_ROOT/includes/addon-wire.sh"
export LIGHTWELL_AAP_ROUTE LIGHTWELL_AO_ROUTE
LIGHTWELL_AAP_ROUTE=$(wire_aap_route_host)
LIGHTWELL_AO_ROUTE=$(wire_ao_route_host)
if [ "$ACTION" != --delete ]; then
  configuration="${AAP_DEMO_LIGHTWELL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aap-demo/lightwell}/config.json"
  if [ -z "${LIGHTWELL_GITEA_URL:-}" ]; then
    LIGHTWELL_GITEA_URL=$(jq -er '.gitea' "$configuration")
  fi
  if [ -z "${LIGHTWELL_OPENFLAKE_URL:-}" ]; then
    LIGHTWELL_OPENFLAKE_URL=$(jq -er '.openflake' "$configuration")
  fi
  export LIGHTWELL_GITEA_URL LIGHTWELL_OPENFLAKE_URL
fi
[ -n "$LIGHTWELL_AAP_ROUTE" ] && [ -n "$LIGHTWELL_AO_ROUTE" ] || {
  echo 'ERROR: AAP and Automation Orchestrator routes are required' >&2
  exit 1
}
aap_password=$(wire_aap_admin_password)
ao_password=$(wire_ao_admin_password)
token_response=$(curl -fsS --connect-timeout 10 --max-time 60 -u "admin:$aap_password" \
  -H 'Content-Type: application/json' \
  -d '{"description":"aap-demo lightwell setup","scope":"write"}' \
  "https://$LIGHTWELL_AAP_ROUTE/api/gateway/v1/tokens/")
token_id=$(jq -er '.id | select(type == "number")' <<<"$token_response") || {
  echo 'ERROR: Cannot identify temporary setup token; inspect gateway tokens before retrying' >&2
  exit 1
}
cleanup() {
  if ! curl -fsS --connect-timeout 10 --max-time 60 -X DELETE -u "admin:$aap_password" \
    "https://$LIGHTWELL_AAP_ROUTE/api/gateway/v1/tokens/$token_id/" >/dev/null; then
    echo "ERROR: Could not revoke temporary AAP setup token $token_id" >&2
    return 1
  fi
}
finish() {
  local status=$?
  trap - EXIT
  cleanup || status=1
  exit "$status"
}
trap finish EXIT
aap_token=$(jq -er '.token | select(type == "string" and length > 0)' <<<"$token_response")
ao_payload=$(jq -n --rawfile password /dev/fd/3 \
  '{username:"admin",password:$password}' 3< <(printf '%s' "$ao_password"))
ao_token=$(curl -fsS --connect-timeout 10 --max-time 60 -H 'Content-Type: application/json' -d "$ao_payload" \
  "https://$LIGHTWELL_AO_ROUTE/api/v1/auth/login" | jq -er '.access_token')
AO_ACCESS_TOKEN="$ao_token"
bindings='{}'
if [ "$ACTION" != --delete ]; then
  # Existing binding readers are reused, but this addon requires verified TLS.
  wire_ao_api() {
    if [ "$1" != GET ]; then
      echo 'ERROR: Lightwell binding discovery permits only GET requests' >&2
      return 1
    fi
    curl -fsS --connect-timeout 10 --max-time 60 -H "Authorization: Bearer $AO_ACCESS_TOKEN" \
      "https://$LIGHTWELL_AO_ROUTE/api/v1$2"
  }
  aap_credential=$(wire_ao_find_credential_by_name "$WIRE_AAP_CREDENTIAL_NAME")
  aap_integration=$(wire_ao_find_integration_by_name "$WIRE_AAP_INTEGRATION_NAME")
  agent_credential=$(wire_ao_llm_agent_credential_id)
  agent_integration=$(wire_ao_llm_agent_integration_id)
  agent_model=$(wire_ao_llm_agent_model_id "$agent_integration")
  bindings=$(jq -cn \
    --arg aap_credential_id "$aap_credential" --arg aap_integration_id "$aap_integration" \
    --arg agent_credential_id "$agent_credential" --arg agent_integration_id "$agent_integration" \
    --arg agent_model_id "$agent_model" \
    '$ARGS.named')
fi
access=$(jq -n --rawfile aap_token /dev/fd/3 --rawfile ao_token /dev/fd/4 \
  --argjson bindings "$bindings" '{aap_token:$aap_token,ao_token:$ao_token,bindings:$bindings}' \
  3< <(printf '%s' "$aap_token") 4< <(printf '%s' "$ao_token"))
args=()
if [ "$ACTION" = --delete ]; then args+=(--delete); fi
if [ "$ACTION" = --prepare ]; then args+=(--prepare); fi
python3 "$SCRIPT_DIR/provision.py" "${args[@]}" 3< <(printf '%s' "$access")
state_dir="${AAP_DEMO_DIR:-$HOME/.aap-demo}/lightwell"
if [ "$ACTION" = --delete ]; then
  rm -f -- "$state_dir/services.json"
else
  (
    umask 077
    mkdir -p "$state_dir"
    jq -n --arg gitea "$LIGHTWELL_GITEA_URL" --arg openflake "$LIGHTWELL_OPENFLAKE_URL" \
      --arg aap "https://$LIGHTWELL_AAP_ROUTE" --arg ao "https://$LIGHTWELL_AO_ROUTE" \
      '{status:"configured",runtime_verified:false,services:[
        {name:"Gitea CI and pull requests",url:$gitea},
        {name:"OpenFlake change requests",url:$openflake},
        {name:"AAP CI/CD templates and setup jobs",url:$aap},
        {name:"AO CI/CD approvals and workflow runs",url:$ao}
      ]}' >"$state_dir/services.json"
  )
fi
