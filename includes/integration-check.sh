#!/usr/bin/env bash

if [ -n "${_AAP_DEMO_INTEGRATION_CHECK_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_INTEGRATION_CHECK_LOADED=1

_integration_result() {
  printf '%-10s %-20s %s\n' "$1" "$2" "$3"
  [ "$1" != FAIL ] || _integration_failed=1
}

_integration_enabled() {
  case " $(_addons_list) " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

_integration_ao_get() {
  curl -fsS --max-time 20 -H "Authorization: Bearer ${_integration_token}" \
    "${_integration_ao_base}$1"
}

_integration_ao_login_token() {
  local api_base="$1" password payload
  password=$(wire_ao_admin_password) || return 1
  [ -n "$password" ] || return 1
  payload=$(jq -n --arg user admin --rawfile password /dev/fd/3 \
    '{username:$user,password:$password}' 3< <(printf '%s' "$password")) || return 1
  curl -fsS --connect-timeout 10 --max-time 20 -H 'Content-Type: application/json' \
    -d "$payload" "${api_base}/auth/login" | jq -er '.access_token'
}

_integration_aap_get() {
  curl -fsS --max-time 20 -u "admin:${_integration_aap_password}" \
    "https://${_integration_aap_route}/api/controller/v2/$1"
}

_integration_item() {
  jq -ce --arg name "$1" --arg type "$2" '
    if (.resources | type) != "array" or (has("next") | not) or .next != null or
      (.total != null and (.total | type != "number")) or
      (.total != null and .total > (.resources | length)) then
      error("incomplete integration list")
    else [.resources[] | select(.name == $name and .integration_type == $type)] |
      if length == 1 then .[0] else error("integration missing or ambiguous") end
    end' <<<"$3"
}

cmd_check_integrations() {
  local _integration_failed=0 _integration_token="" _integration_ao_base=""
  local _integration_aap_password="" _integration_aap_route=""
  local integrations item models id credential_id inventories sources jobs fleet_id

  if [ ! -f "$AAP_DEMO_CONFIG" ]; then
    echo "ERROR: Cannot determine enabled addons: configuration file not found." >&2
    return 1
  fi
  # shellcheck source=secure-curl.sh
  source "${SCRIPT_DIR}/includes/secure-curl.sh"
  # shellcheck source=addon-wire.sh
  source "${SCRIPT_DIR}/includes/addon-wire.sh"
  echo "Integration check (inspection only; no jobs or tools are executed)"

  if ! _integration_enabled ao; then
    _integration_result DISABLED AO "not listed as enabled"
    _integration_result NOT_TESTED AO-to-AAP "AO not enabled"
    _integration_result NOT_TESTED AO-to-MCP "AO not enabled"
    _integration_result NOT_TESTED AO-to-Ollama "AO not enabled"
  else
    if ! _integration_ao_base=$(wire_ao_api_base); then
      _integration_result FAIL AO "route discovery failed"
    elif ! _integration_token=$(_integration_ao_login_token "$_integration_ao_base") \
      || [ -z "$_integration_token" ]; then
      _integration_result FAIL AO "trusted HTTPS authentication failed"
    elif ! integrations=$(_integration_ao_get '/integrations?limit=100'); then
      _integration_result FAIL AO "authenticated integration-list read failed"
    elif ! jq -e '(.resources | type) == "array" and has("next") and .next == null and
      (.total == null or ((.total | type) == "number" and .total <= (.resources | length)))' <<<"$integrations" >/dev/null; then
      _integration_result FAIL AO "integration list is incomplete or malformed"
    else
      _integration_result PASS AO "authenticated integration list read"
    fi
    if [ "${_integration_failed:-0}" -ne 0 ]; then
      _integration_result NOT_TESTED AO-to-AAP "AO inspection failed"
      _integration_result NOT_TESTED AO-to-MCP "AO inspection failed"
      _integration_result NOT_TESTED AO-to-Ollama "AO inspection failed"
    else
      if item=$(_integration_item "$WIRE_AAP_INTEGRATION_NAME" ansible_automation_platform "$integrations" 2>/dev/null) \
        && jq -e '.enabled == true and .validation_status == "available"' <<<"$item" >/dev/null \
        && id=$(jq -er '.id | select(type == "string" and test("^[A-Za-z0-9._-]+$"))' <<<"$item") \
        && credential_id=$(jq -er '.management_credential_id | select(type == "string" and test("^[A-Za-z0-9._-]+$"))' <<<"$item") \
        && inventories=$(_integration_ao_get "/proxies/aap/inventories?integration_id=$id&credential_id=$credential_id") \
        && jq -e '(.results | type) == "array"' <<<"$inventories" >/dev/null; then
        _integration_result PASS AO-to-AAP "enabled and authenticated inventory proxy responds"
      else
        _integration_result FAIL AO-to-AAP "integration or authenticated inventory proxy failed"
      fi

      if ! _integration_enabled mcp-server; then
        _integration_result DISABLED AO-to-MCP "mcp-server not listed as enabled"
      elif item=$(_integration_item "$WIRE_MCP_INTEGRATION_NAME" mcp_server "$integrations" 2>/dev/null) \
        && jq -e '.enabled == true and .validation_status == "available" and
        (.enabled_tool_count | type == "number" and . > 0)' <<<"$item" >/dev/null; then
        _integration_result PASS AO-to-MCP "last validation available; enabled tools recorded"
      else
        _integration_result FAIL AO-to-MCP "integration unavailable or no enabled tools recorded"
      fi

      if ! _integration_enabled ollama; then
        _integration_result DISABLED AO-to-Ollama "ollama not listed as enabled"
      elif item=$(_integration_item "aap-demo Ollama" llm_provider "$integrations" 2>/dev/null) \
        && jq -e '.enabled == true and .validation_status == "available"' <<<"$item" >/dev/null \
        && id=$(jq -er '.id | select(type == "string" and test("^[A-Za-z0-9._-]+$"))' <<<"$item") \
        && models=$(_integration_ao_get "/integrations/$id/models?limit=100") \
        && jq -e '(.resources | type) == "array" and has("next") and .next == null and
        (.total == null or ((.total | type) == "number" and .total <= (.resources | length))) and
        any(.resources[]; .enabled == true and .is_default == true)' <<<"$models" >/dev/null; then
        _integration_result PASS AO-to-Ollama "last validation available; enabled default model recorded"
      else
        _integration_result FAIL AO-to-Ollama "integration unavailable or default model not enabled"
      fi
    fi
  fi

  if _integration_enabled product-demo-satellite || _integration_enabled fleet; then
    _integration_aap_route=$(wire_aap_route_host)
    _integration_aap_password=$(wire_aap_admin_password)
  fi
  if ! _integration_enabled product-demo-satellite; then
    _integration_result DISABLED Satellite-sync "product-demo-satellite not listed as enabled"
  elif [ -z "$_integration_aap_route" ] || [ -z "$_integration_aap_password" ] \
    || ! sources=$(_integration_aap_get 'inventory_sources/?name=Satellite%20Inventory') \
    || ! jq -e '.count == 1 and (.results | length) == 1 and
      .results[0].status == "successful" and .results[0].last_job_run != null' <<<"$sources" >/dev/null; then
    _integration_result FAIL Satellite-sync "latest inventory source sync unavailable or unsuccessful"
  else
    _integration_result PASS Satellite-sync "last inventory sync succeeded at $(jq -r '.results[0].last_job_run' <<<"$sources")"
  fi
  if ! _integration_enabled fleet; then
    _integration_result DISABLED Fleet-ping "fleet not listed as enabled"
  elif [ -z "$_integration_aap_route" ] || [ -z "$_integration_aap_password" ] \
    || ! inventories=$(_integration_aap_get 'inventories/?name=Fleet') \
    || ! fleet_id=$(jq -er 'if .count == 1 and (.results | length) == 1 then
      .results[0].id | select(type == "number") else empty end' <<<"$inventories") \
    || ! jobs=$(_integration_aap_get "ad_hoc_commands/?inventory=$fleet_id&module_name=ping&order_by=-id&page_size=1") \
    || ! jq -e '(.results | type) == "array" and (.results | length) == 1 and
      .results[0].status == "successful" and .results[0].finished != null' <<<"$jobs" >/dev/null; then
    _integration_result FAIL Fleet-ping "latest Fleet ping unavailable or unsuccessful"
  else
    _integration_result PASS Fleet-ping "last ping succeeded at $(jq -r '.results[0].finished' <<<"$jobs")"
  fi
  echo "NOT TESTED: current Fleet registration, tool execution, LLM responses, and external demo integrations."
  echo "Recorded validations and past jobs do not establish current end-to-end health."
  [ "$_integration_failed" -eq 0 ]
}
