#!/usr/bin/env bash
# Explicitly opt-in: creates/revokes its own read-only token; never launches jobs.
set -euo pipefail

if [ "${AAP_DEMO_RUN_LIVE_AI_TESTS:-}" != 1 ]; then
  echo "SKIP: set AAP_DEMO_RUN_LIVE_AI_TESTS=1 and an explicit local KUBECONFIG."
  exit 0
fi
if [ -z "${KUBECONFIG:-}" ]; then
  echo "ERROR: live AI checks require an explicit local KUBECONFIG." >&2
  exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../includes/secure-curl.sh
source "$root/includes/secure-curl.sh"
# shellcheck source=../includes/addon-wire.sh
source "$root/includes/addon-wire.sh"
wire_require_tools
wire_cluster_ready

umask 077
tmp="$(mktemp -d)"
token_id="" token="" password="" route=""
cleanup() {
  local status=$? revoked_status
  if [ -n "$token_id" ]; then
    if ! curl -fsSk --max-time 30 -u "admin:$password" -X DELETE \
      "https://$route/api/gateway/v1/tokens/$token_id/" >/dev/null; then
      echo "ERROR: could not revoke this test's temporary read-only token." >&2
      status=1
    elif [ -n "$token" ]; then
      if revoked_status="$(curl -sSk --max-time 30 -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' -d "$initialize" "$url")"; then
        case "$revoked_status" in
          401 | 403) echo "PASS: revoked validation token is rejected" ;;
          *)
            echo "ERROR: revoked token check returned unexpected HTTP $revoked_status." >&2
            status=1
            ;;
        esac
      else
        echo "ERROR: could not verify rejection of the revoked validation token." >&2
        status=1
      fi
    fi
  fi
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

route="$(wire_aap_route_host)"
password="$(wire_aap_admin_password)"
[ -n "$route" ] && [ -n "$password" ] || fail "AAP authentication prerequisites unavailable"
url="$(wire_mcp_url_for_ao)"
[ -n "$url" ] || fail "MCP endpoint not discovered"

initialize='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"aap-demo-read-only-test","version":"1"}}}'
for authorization in "" "Authorization: Bearer invalid-local-validation-token"; do
  headers=()
  [ -z "$authorization" ] || headers=(-H "$authorization")
  status="$(curl -sSk --max-time 30 -o /dev/null -w '%{http_code}' \
    "${headers[@]}" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -d "$initialize" "$url")"
  case "$status" in
    401 | 403) ;;
    *) fail "MCP accepted missing/invalid authentication or returned unexpected HTTP $status" ;;
  esac
done
echo "PASS: MCP rejects missing and invalid credentials"

record="$(curl -fsSk --max-time 30 -u "admin:$password" \
  -H 'Content-Type: application/json' \
  -d '{"description":"aap-demo temporary read-only AI integration test","scope":"read"}' \
  "https://$route/api/gateway/v1/tokens/")"
token_id="$(jq -er '.id | select(type == "number")' <<<"$record")"
jq -e '.scope == "read"' <<<"$record" >/dev/null || fail "temporary token is not read-only"
token="$(jq -er '.token | select(type == "string" and length > 0)' <<<"$record")"
headers=()
mcp_request() {
  curl -fsSk --max-time 60 -D "$tmp/headers" \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' "${headers[@]}" \
    -d "$1" "$url"
}
parse_reply() {
  local reply="$1"
  if [[ "$reply" == data:* || "$reply" == event:* ]]; then
    reply="$(sed -n 's/^data: //p' <<<"$reply")"
  fi
  jq -e 'select(.jsonrpc == "2.0" and .error == null)' <<<"$reply"
}
reply="$(mcp_request "$initialize")"
parse_reply "$reply" | jq -e '.result.protocolVersion | type == "string"' >/dev/null \
  || fail "MCP initialization did not negotiate a protocol"
session="$(sed -n 's/^[Mm][Cc][Pp]-[Ss][Ee][Ss][Ss][Ii][Oo][Nn]-[Ii][Dd]: *//p' "$tmp/headers" | tr -d '\r')"
[ -z "$session" ] || headers=(-H "Mcp-Session-Id: $session")
mcp_request '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
reply="$(mcp_request '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')"
tools="$(parse_reply "$reply")"
tool="$(jq -er '.result.tools[] |
  select(.name == "execution_environments_repositories_get_repositories") |
  select((.inputSchema.required // [] | length) == 0) | .name' <<<"$tools")" \
  || fail "expected no-argument Hub repository tool unavailable; review the installed schema"
payload="$(jq -nc --arg name "$tool" \
  '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:$name,arguments:{}}}')"
reply="$(mcp_request "$payload")"
result="$(parse_reply "$reply")"
jq -e '.result.isError != true' <<<"$result" >/dev/null || fail "Hub MCP tool returned an error"
hub="$(jq -ce '.result.structuredContent //
  (.result.content[] | select(.type == "text") | .text | fromjson)' <<<"$result")" \
  || fail "Hub MCP response was not structured JSON"
if ! jq -e 'type == "array" or
  (type == "object" and ((.data | type) == "array" or (.results | type) == "array"))' \
  <<<"$hub" >/dev/null; then
  jq -c '{response_type:type,
    keys:(if type == "object" then keys else [] end)}' <<<"$hub" >&2
  fail "Hub MCP response did not contain a repository listing"
fi
echo "PASS: authenticated MCP discovery and read-only Hub repository tool"

integration="$(wire_ao_find_integration_by_name "aap-demo Ollama")"
[ -n "$integration" ] || fail "AO local Ollama integration unavailable"
models="$(wire_ao_api GET "/integrations/$integration/models?limit=100")"
model="$(jq -er '[.resources[] | select(.enabled == true and .is_default == true)] |
  if length == 1 then .[0].model_id else error("ambiguous default model") end' <<<"$models")" \
  || fail "AO lacks exactly one enabled default local model"
if ! response="$(kubectl exec -n aap-demo-ollama deploy/ollama -- \
  ollama run "$model" 'Reply with only the word READY. Do not use any tools.' 2>"$tmp/ollama-error")"; then
  fail "local Ollama generation failed"
fi
[[ "$response" =~ ^[[:space:]]*READY[[:space:]]*$ ]] || fail "local model did not return the expected response"
echo "PASS: AO default model exists and local Ollama generates a response"

if [ "${AAP_DEMO_RUN_LIVE_LIGHTSPEED_TESTS:-}" = 1 ]; then
  chat_url="https://$route/api/lightspeed/v1/ai/chat/"
  query='{"query":"Explain what an Ansible playbook is in one short sentence. Do not call any tools.","no_tools":true}'
  for authorization in "" "Authorization: Bearer invalid-local-validation-token"; do
    chat_headers=()
    [ -z "$authorization" ] || chat_headers=(-H "$authorization")
    status="$(curl -sSk --max-time 30 -o /dev/null -w '%{http_code}' \
      "${chat_headers[@]}" -H 'Content-Type: application/json' -d "$query" "$chat_url")"
    case "$status" in
      401 | 403) ;;
      *) fail "Lightspeed accepted missing/invalid authentication or returned unexpected HTTP $status" ;;
    esac
  done
  # Native chat requires read/write scope; keep the MCP token read-only.
  response="$(curl -fsSk --max-time 150 -u "admin:$password" \
    -H 'Content-Type: application/json' -d "$query" "$chat_url")" \
    || fail "native Lightspeed conversation through the AAP gateway failed"
  jq -e '(.conversation_id | type == "string" and length > 0) and
    (.response | type == "string" and length > 0) and
    .tool_calls == [] and .tool_results == []' <<<"$response" >/dev/null \
    || fail "Lightspeed did not return a no-tools conversation response"
  echo "PASS: native Lightspeed rejects invalid authentication and answers through the AAP gateway without tools"
else
  echo "NOT TESTED: Lightspeed chat (set AAP_DEMO_RUN_LIVE_LIGHTSPEED_TESTS=1 to include it)."
fi
echo "NOT TESTED: AO agent workflows, Portal chat, native Lightspeed/Satellite MCP tool execution, mutating tools."
