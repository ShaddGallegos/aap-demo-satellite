#!/usr/bin/env bash
# =============================================================================
# galaxy-auth.sh — Galaxy / PAH credential detection and remote configuration
# =============================================================================
# Source this file; do not execute it directly.
# Requires: _RED, _GREEN, _YELLOW, _NC colour vars and _err() from caller.

if [ -n "${_GALAXY_AUTH_LOADED:-}" ]; then return 0; fi
_GALAXY_AUTH_LOADED=1

# Fallbacks when sourced outside aap-demo.sh (e.g. addon subprocesses)
if ! declare -f _err >/dev/null 2>&1; then
  _err() { printf 'ERROR: %s\n' "$*" >&2; }
fi
_YELLOW="${_YELLOW:-}"
_NC="${_NC:-}"
GALAXY_AUTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=credential-vault.sh
source "${GALAXY_AUTH_DIR}/credential-vault.sh"
# shellcheck source=secure-curl.sh
source "${GALAXY_AUTH_DIR}/secure-curl.sh"

galaxy_offline_token_status() {
  local token="$1" client_id="${2:-cloud-services}" response http_code
  [ -n "$token" ] || return 1
  _aap_demo_vault_require_tools || return 2

  response=$(printf '%s' "$token" | curl --silent --show-error \
    --connect-timeout 15 --max-time 45 \
    --write-out '\n%{http_code}' \
    --request POST \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "client_id=${client_id}" \
    --data-urlencode "refresh_token@-" \
    "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token" \
    2>/dev/null) || {
    unset token
    return 2
  }
  unset token
  http_code="${response##*$'\n'}"
  case "$http_code" in
    200)
      "$AAP_DEMO_VAULT_PYTHON" -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except (ValueError, TypeError):
    raise SystemExit(2)
token = data.get("access_token") if isinstance(data, dict) else None
raise SystemExit(0 if isinstance(token, str) and token.strip() else 2)
' <<<"${response%$'\n'*}"
      ;;
    400 | 401 | 403) return 1 ;;
    *) return 2 ;;
  esac
}

prepare_galaxy_credentials() {
  local rc
  detect_galaxy_credentials || return $?

  if [ -z "${GALAXY_TOKEN:-}" ]; then
    return 1
  fi
  if galaxy_offline_token_status "$GALAXY_TOKEN"; then
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 2 ]; then
    _err "Unable to validate the Automation Hub token: Red Hat SSO is unavailable or returned an invalid response; credentials were preserved"
    return 2
  fi
  printf "  ⚠ Stored Automation Hub token is invalid; removing it from encrypted storage\n" >&2
  aap_demo_vault_delete "ah_offline_token" || return 2
  GALAXY_TOKEN=""
  export GALAXY_TOKEN
  return 1
}

prompt_galaxy_credentials() {
  local rc
  printf 'Generate an Automation Hub offline token at:\n  https://console.redhat.com/ansible/automation-hub/token\n'
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "https://console.redhat.com/ansible/automation-hub/token" >/dev/null 2>&1 \
      || printf 'WARNING: Could not open a browser; visit the URL above.\n' >&2
  elif command -v open >/dev/null 2>&1; then
    open "https://console.redhat.com/ansible/automation-hub/token" >/dev/null 2>&1 \
      || printf 'WARNING: Could not open a browser; visit the URL above.\n' >&2
  fi
  if ! { exec 9<"$AAP_DEMO_SECRET_PROMPT_DEVICE"; } 2>/dev/null; then
    _err "An interactive terminal is required to enter the Automation Hub token"
    return 1
  fi
  while true; do
    printf "Automation Hub offline token (hidden): " >>"$AAP_DEMO_SECRET_PROMPT_OUTPUT"
    if ! IFS= read -r -s GALAXY_TOKEN <&9; then
      exec 9<&-
      unset GALAXY_TOKEN
      _err "Token input was cancelled; no new token was saved"
      return 1
    fi
    printf '\n' >>"$AAP_DEMO_SECRET_PROMPT_OUTPUT"
    if [ -z "$GALAXY_TOKEN" ]; then
      _err "Token must not be empty; please try again"
      continue
    fi
    if galaxy_offline_token_status "$GALAXY_TOKEN"; then
      exec 9<&-
      aap_demo_vault_set "ah_offline_token" "$GALAXY_TOKEN" || return 2
      export GALAXY_TOKEN
      return 0
    else
      rc=$?
    fi
    unset GALAXY_TOKEN
    # Retry rejected credentials, not network/server errors that could reject a good token.
    if [ "$rc" -eq 2 ]; then
      exec 9<&-
      _err "Red Hat SSO is unavailable or returned an invalid response; no new token was saved"
      return 2
    fi
    _err "Red Hat SSO rejected the Automation Hub offline token (expired or revoked); please try again"
  done
}

ensure_galaxy_credentials() {
  local rc
  if prepare_galaxy_credentials; then
    return 0
  else
    rc=$?
  fi
  [ "$rc" -ne 2 ] || return 2
  if [ "${QUIET:-false}" = true ]; then
    _err "Automation Hub offline token is missing or invalid; run 'aap-demo enable setup-pah' interactively to configure it"
    return 1
  fi
  prompt_galaxy_credentials
}

refresh_galaxy_credentials_after_remote_failure() {
  local label="$1" rc
  # A 401/403 returned by a Pulp remote is not itself proof that the Vault
  # token is bad. It can also mean the account lacks that content entitlement.
  # Revalidate first so a valid saved token is never needlessly prompted for or
  # replaced behind a setup spinner.
  if galaxy_offline_token_status "$GALAXY_TOKEN"; then
    printf '  ⚠ Automation Hub token is valid at Red Hat SSO, but %s denied content access; not prompting for a replacement. Verify the account entitlement.\n' "$label" >&2
    return 4
  else
    rc=$?
  fi
  if [ "$rc" -eq 2 ]; then
    _err "Could not revalidate the Automation Hub token after ${label} denied access; credentials were preserved"
    return 2
  fi
  if [ "${QUIET:-false}" = true ]; then
    _err "Automation Hub token was rejected by Red Hat SSO while accessing ${label}; the non-interactive workflow will not prompt again. Run 'aap-demo enable setup-pah' interactively to replace it before retrying."
    return 1
  fi
  printf '  ⚠ Automation Hub token was rejected by Red Hat SSO while accessing %s. Enter a replacement token to retry once.\n' "$label" >&2
  # Do not delete the stored token first. A cancelled prompt, rejected
  # replacement, or SSO outage must leave the encrypted Vault unchanged.
  prompt_galaxy_credentials
}

protect_galaxy_credential_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    return 0
  fi
  if ! chmod 600 "$path" 2>/dev/null; then
    _err "Cannot restrict permissions on credential file: $path"
    return 1
  fi
}

detect_galaxy_credentials() {
  local token_status=0
  GALAXY_TOKEN_FILE="${GALAXY_TOKEN_FILE:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/galaxy-token}"
  PAH_CONFIG_FILE="${PAH_CONFIG_FILE:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/pah-config.yml}"

  GALAXY_TOKEN=$(aap_demo_vault_get "ah_offline_token") || token_status=$?
  [ "$token_status" -ne 2 ] || return 2
  # Detect console.redhat.com offline token
  if [ -z "$GALAXY_TOKEN" ] && [ -s "$GALAXY_TOKEN_FILE" ]; then
    protect_galaxy_credential_file "$GALAXY_TOKEN_FILE" || return 1
    GALAXY_TOKEN=$(cat "$GALAXY_TOKEN_FILE")
    if galaxy_offline_token_status "$GALAXY_TOKEN"; then
      if aap_demo_vault_set "ah_offline_token" "$GALAXY_TOKEN"; then
        rm -f "$GALAXY_TOKEN_FILE"
      else
        _err "Unable to migrate $GALAXY_TOKEN_FILE into encrypted credential storage"
        return 2
      fi
    else
      token_status=$?
      GALAXY_TOKEN=""
      _err "Unable to validate the legacy Automation Hub token; it was not saved"
      return "$token_status"
    fi
  fi
  export GALAXY_TOKEN

  # Detect PAH configuration
  if [ -f "$PAH_CONFIG_FILE" ]; then
    protect_galaxy_credential_file "$PAH_CONFIG_FILE" || return 1
    # Parse YAML for URL and authentication
    if command -v yq >/dev/null 2>&1; then
      PAH_URL=$(yq eval '.url' "$PAH_CONFIG_FILE" 2>/dev/null)
      PAH_TOKEN=$(yq eval '.token' "$PAH_CONFIG_FILE" 2>/dev/null)
      PAH_USER=$(yq eval '.username' "$PAH_CONFIG_FILE" 2>/dev/null)
      PAH_PASS=$(yq eval '.password' "$PAH_CONFIG_FILE" 2>/dev/null)
    else
      # Fallback: basic grep parsing
      PAH_URL=$(grep -E '^\s*url:' "$PAH_CONFIG_FILE" | sed 's/^[^:]*: *//' | tr -d '"' | tr -d "'")
      PAH_TOKEN=$(grep -E '^\s*token:' "$PAH_CONFIG_FILE" | sed 's/^[^:]*: *//' | tr -d '"' | tr -d "'")
      PAH_USER=$(grep -E '^\s*username:' "$PAH_CONFIG_FILE" | sed 's/^[^:]*: *//' | tr -d '"' | tr -d "'")
      PAH_PASS=$(grep -E '^\s*password:' "$PAH_CONFIG_FILE" | sed 's/^[^:]*: *//' | tr -d '"' | tr -d "'")
    fi

    local migrated=false
    if [ -n "${PAH_TOKEN:-}" ] && [ "$PAH_TOKEN" != "null" ]; then
      aap_demo_vault_set "aap_demo.pah.token" "$PAH_TOKEN" || return 1
      migrated=true
    fi
    if [ -n "${PAH_USER:-}" ] && [ "$PAH_USER" != "null" ]; then
      aap_demo_vault_set "aap_demo.pah.username" "$PAH_USER" || return 1
      migrated=true
    fi
    if [ -n "${PAH_PASS:-}" ] && [ "$PAH_PASS" != "null" ]; then
      aap_demo_vault_set "aap_demo.pah.password" "$PAH_PASS" || return 1
      migrated=true
    fi
    if [ "$migrated" = true ]; then
      python3 - "$PAH_CONFIG_FILE" <<'PY'
import os
import sys
import tempfile
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    data = yaml.safe_load(stream) or {}
for key in ("token", "username", "password"):
    data.pop(key, None)
directory = os.path.dirname(path) or "."
fd, temporary = tempfile.mkstemp(prefix=".pah-config.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        yaml.safe_dump(data, stream, default_flow_style=False, sort_keys=True)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
    fi
  fi
  PAH_TOKEN=$(aap_demo_vault_get "aap_demo.pah.token" 2>/dev/null || true)
  PAH_USER=$(aap_demo_vault_get "aap_demo.pah.username" 2>/dev/null || true)
  PAH_PASS=$(aap_demo_vault_get "aap_demo.pah.password" 2>/dev/null || true)
  export PAH_URL PAH_TOKEN PAH_USER PAH_PASS
}

configure_pah_remotes() {
  local auth_retry_attempt="${1:-0}"
  case "$auth_retry_attempt" in
    0 | 1) ;;
    *)
      _err "Invalid PAH remote authorization retry state"
      return 1
      ;;
  esac
  echo "Configuring Private Automation Hub remotes..."
  # Requires AAP 2.7+ (uses Pulp v3 API)

  if ! command -v jq >/dev/null 2>&1; then
    _err "jq is required for PAH remote configuration"
    echo "  Install: brew install jq (macOS) or sudo dnf install jq (RHEL/Fedora)"
    return 1
  fi

  # Detect credentials
  detect_galaxy_credentials || return 1

  # Get AAP route and admin password
  local aap_route
  aap_route=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
  if [ -z "$aap_route" ]; then
    _err "AAP route not found"
    return 1
  fi

  local admin_pass
  admin_pass=$(kubectl get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  if [ -z "$admin_pass" ]; then
    _err "Admin password not found"
    return 1
  fi

  local api_base="https://${aap_route}/api/galaxy/pulp/api/v3"
  local aap_base="https://${aap_route}"
  # Build Basic auth header to avoid curl misparse when password contains ':'
  local auth_header
  auth_header="Authorization: Basic $(printf 'admin:%s' "${admin_pass}" | base64)"

  # Pulp returns resource references as absolute paths rooted at the AAP
  # route (for example, /api/galaxy/pulp/api/v3/remotes/...).  Do not append
  # those references to api_base: doing so duplicates the Pulp path and makes
  # every idempotent update fail with a 404 after the first successful run.
  pah_resource_url() {
    local resource_href="$1"
    case "$resource_href" in
      /api/galaxy/pulp/api/v3/*)
        printf '%s%s' "$aap_base" "$resource_href"
        ;;
      "${aap_base}"/api/galaxy/pulp/api/v3/*)
        printf '%s' "$resource_href"
        ;;
      *)
        _err "AAP returned an unexpected Pulp resource reference"
        return 1
        ;;
    esac
  }

  # Pulp accepts a sync request asynchronously.  Do not report setup as
  # complete until the task finishes: a stale remote token otherwise fails
  # later in the UI with an opaque SSO 400 response.
  pah_wait_sync_task() {
    local task_href="$1" label="$2" task state error attempt elapsed
    local timeout_seconds="${PAH_SYNC_TIMEOUT_SECONDS:-1800}"
    local poll_seconds="${PAH_SYNC_POLL_SECONDS:-5}"
    local max_attempts next_report=0
    case "$timeout_seconds" in
      '' | *[!0-9]*)
        _err "PAH_SYNC_TIMEOUT_SECONDS must be a positive number of seconds"
        return 1
        ;;
    esac
    case "$poll_seconds" in
      '' | *[!0-9]*)
        _err "PAH_SYNC_POLL_SECONDS must be a positive number of seconds"
        return 1
        ;;
    esac
    if [ "$timeout_seconds" -lt 60 ] || [ "$poll_seconds" -lt 1 ] || [ "$poll_seconds" -gt 30 ]; then
      _err "PAH sync timeout must be at least 60 seconds and its poll interval must be 1-30 seconds"
      return 1
    fi
    max_attempts=$(((timeout_seconds + poll_seconds - 1) / poll_seconds))
    case "$task_href" in
      /api/galaxy/*) task_href="${aap_base}${task_href}" ;;
      https://* | http://*) ;;
      *)
        _err "${label} sync did not return a usable Pulp task URL"
        return 1
        ;;
    esac
    for attempt in $(seq 1 "$max_attempts"); do
      task=$(curl -sk --fail --connect-timeout 10 --max-time 30 -H "${auth_header}" "$task_href" 2>/dev/null) || {
        _err "Could not read ${label} sync task status"
        return 1
      }
      state=$(jq -r '.state // empty' <<<"$task" 2>/dev/null)
      case "$state" in
        completed)
          echo "✓"
          return 0
          ;;
        failed | canceled)
          error=$(jq -r '.error.description // .error.traceback // "Pulp reported no error detail"' <<<"$task" 2>/dev/null | head -c 400)
          # Pulp occasionally receives a transient NXDOMAIN/SERVFAIL while
          # downloading an S3 redirect target. It can also mark a task failed
          # when its worker restarts while cleaning a completed task directory.
          # Neither condition invalidates the remote or its token; signal the
          # caller to start one fresh sync task after a short delay.
          if printf '%s' "$error" | grep -Eqi 'domain name not found|temporary failure in name resolution|name or service not known|dns.*(fail|error)|could not resolve host|worker has gone missing|worker.*(restart|lost|missing)'; then
            printf '  %s⚠ %s sync %s due to a transient DNS or Pulp-worker failure; retrying is safe.%s\n' \
              "${_YELLOW}" "$label" "$state" "${_NC}" >&2
            return 4
          fi
          # A valid Hub token can still lack the optional Validated Content
          # entitlement.  Let the caller distinguish that authorization case
          # from a broken Pulp task or network failure.
          if printf '%s' "$error" | grep -Eqi '(^|[^0-9])(401|403)([^0-9]|$)|unauthorized|forbidden'; then
            if [ "$label" != "rh-validated" ]; then
              _err "${label} sync ${state}: ${error}"
            fi
            return 3
          fi
          _err "${label} sync ${state}: ${error}"
          return 1
          ;;
      esac
      elapsed=$(((attempt - 1) * poll_seconds))
      if [ "$elapsed" -ge "$next_report" ]; then
        printf '  %s sync still running (%dm%02ds; waiting up to %dm; task: %s)\n' \
          "$label" "$((elapsed / 60))" "$((elapsed % 60))" "$((timeout_seconds / 60))" "$task_href"
        next_report=$((elapsed + 30))
      fi
      sleep "$poll_seconds"
    done
    _err "Timed out waiting for ${label} sync after $((timeout_seconds / 60)) minutes; the Pulp task may still be running"
    return 1
  }

  pah_transient_retry_delay() {
    local retry_delay_seconds="${PAH_DNS_RETRY_DELAY_SECONDS:-15}"
    case "$retry_delay_seconds" in
      '' | *[!0-9]*)
        _err "PAH_DNS_RETRY_DELAY_SECONDS must be a positive number of seconds"
        return 1
        ;;
    esac
    if [ "$retry_delay_seconds" -lt 1 ] || [ "$retry_delay_seconds" -gt 60 ]; then
      _err "PAH_DNS_RETRY_DELAY_SECONDS must be between 1 and 60 seconds"
      return 1
    fi
    printf '%s' "$retry_delay_seconds"
  }

  pah_sync_repository() {
    local repo_href="$1" label="$2" response task_href repo_url sync_attempt sync_rc retry_delay_seconds
    retry_delay_seconds=$(pah_transient_retry_delay) || return 1
    repo_url=$(pah_resource_url "$repo_href") || return 1
    for sync_attempt in 1 2; do
      response=$(curl -sk --fail --connect-timeout 10 --max-time 30 -H "${auth_header}" \
        -X POST -H "Content-Type: application/json" -d '{"mirror": false}' \
        "${repo_url}sync/" 2>/dev/null) || {
        _err "Could not start ${label} sync"
        return 1
      }
      task_href=$(jq -r '.task // .pulp_href // empty' <<<"$response" 2>/dev/null)
      [ -n "$task_href" ] || {
        _err "${label} sync did not return a Pulp task"
        return 1
      }
      if pah_wait_sync_task "$task_href" "$label"; then
        return 0
      else
        sync_rc=$?
      fi
      if [ "$sync_rc" -eq 4 ] && [ "$sync_attempt" -eq 1 ]; then
        printf '  %s⚠ %s sync will retry once in %ss after the transient failure.%s\n' \
          "${_YELLOW}" "$label" "$retry_delay_seconds" "${_NC}" >&2
        sleep "$retry_delay_seconds"
        continue
      fi
      return "$sync_rc"
    done
  }

  pah_update_remote_token() {
    local remote_url="$1" label="$2" response task_href detail update_attempt update_rc retry_delay_seconds
    retry_delay_seconds=$(pah_transient_retry_delay) || return 1
    for update_attempt in 1 2; do
      response=$(curl -sk --fail --connect-timeout 10 --max-time 30 -H "${auth_header}" \
        -X PATCH \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg token "${GALAXY_TOKEN}" '{token: $token}')" \
        "${remote_url}" 2>/dev/null) || {
        _err "Could not update the ${label} remote token"
        return 1
      }

      # Pulp can return the updated remote directly, a task for an asynchronous
      # update, or a successful empty response depending on the component
      # version and whether the token value actually changed.
      [ -z "$response" ] && return 0
      if jq -e '.pulp_href' >/dev/null 2>&1 <<<"$response"; then
        return 0
      fi
      task_href=$(jq -r '.task // empty' <<<"$response" 2>/dev/null)
      if [ -n "$task_href" ]; then
        printf '  Applying %s remote token update... ' "$label"
        if pah_wait_sync_task "$task_href" "${label} remote update"; then
          return 0
        else
          update_rc=$?
        fi
        if [ "$update_rc" -eq 4 ] && [ "$update_attempt" -eq 1 ]; then
          printf '  %s⚠ %s remote update will retry once in %ss after the transient failure.%s\n' \
            "${_YELLOW}" "$label" "$retry_delay_seconds" "${_NC}" >&2
          sleep "$retry_delay_seconds"
          continue
        fi
        return "$update_rc"
      fi
      detail=$(jq -r '.detail // .errors[0].detail // "no Pulp resource or task was returned"' <<<"$response" 2>/dev/null | head -c 400)
      _err "${label} remote update returned an invalid response: ${detail}"
      return 1
    done
  }

  # Configure console.redhat.com remotes if token present
  if [ -n "$GALAXY_TOKEN" ]; then
    # Configure rh-certified remote
    printf "  Configuring rh-certified remote... "

    local remote_href
    remote_href=$(curl -sk --max-time 10 -H "${auth_header}" \
      "${api_base}/remotes/ansible/collection/?name=rh-certified" 2>/dev/null \
      | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)

    if [ -n "$remote_href" ]; then
      # Update existing token
      local remote_url
      remote_url=$(pah_resource_url "$remote_href") || return 1
      pah_update_remote_token "$remote_url" "rh-certified" || return 1
      echo "✓"
    else
      # Create rh-certified remote
      local create_result
      create_result=$(curl -sk --max-time 10 -H "${auth_header}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg token "${GALAXY_TOKEN}" '{name:"rh-certified", url:"https://console.redhat.com/api/automation-hub/content/published/", token:$token, tls_validation:true}')" \
        "${api_base}/remotes/ansible/collection/" 2>/dev/null)

      remote_href=$(echo "$create_result" | python3 -c "import sys, json; print(json.loads(sys.stdin.read() or '{}').get('pulp_href', ''))" 2>/dev/null)

      if [ -n "$remote_href" ]; then
        echo "✓"

        # Link to rh-certified repository
        local repo_href
        repo_href=$(curl -sk --max-time 10 -H "${auth_header}" \
          "${api_base}/repositories/ansible/ansible/?name=rh-certified" 2>/dev/null \
          | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)

        [ -n "$repo_href" ] || {
          _err "rh-certified repository was not found"
          return 1
        }
        local repo_url
        repo_url=$(pah_resource_url "$repo_href") || return 1
        curl -sk --fail --connect-timeout 10 --max-time 30 -H "${auth_header}" \
          -X PATCH \
          -H "Content-Type: application/json" \
          -d "{\"remote\": \"${remote_href}\"}" \
          "${repo_url}" >/dev/null || {
          _err "Could not link the rh-certified remote to its repository"
          return 1
        }
      fi
    fi

    # Trigger sync
    printf "  Syncing rh-certified... "
    local repo_href
    repo_href=$(curl -sk --max-time 10 -H "${auth_header}" \
      "${api_base}/repositories/ansible/ansible/?name=rh-certified" 2>/dev/null \
      | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)

    [ -n "$repo_href" ] || {
      _err "rh-certified repository was not found"
      return 1
    }
    local certified_sync_rc=0
    if pah_sync_repository "$repo_href" "rh-certified"; then
      :
    else
      certified_sync_rc=$?
      if [ "$certified_sync_rc" -eq 3 ] && [ "$auth_retry_attempt" -eq 0 ]; then
        if refresh_galaxy_credentials_after_remote_failure "Certified Content"; then
          printf '  Retrying Automation Hub remote configuration with the replacement token...\n'
          configure_pah_remotes 1
          return $?
        fi
      fi
      return "$certified_sync_rc"
    fi

    # Configure rh-validated remote
    printf "  Configuring rh-validated remote... "

    local validated_remote
    validated_remote=$(curl -sk --max-time 10 -H "${auth_header}" \
      "${api_base}/remotes/ansible/collection/?name=rh-validated" 2>/dev/null \
      | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)

    if [ -z "$validated_remote" ]; then
      local create_result
      create_result=$(curl -sk --max-time 10 -H "${auth_header}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg token "${GALAXY_TOKEN}" '{name:"rh-validated", url:"https://console.redhat.com/api/automation-hub/content/validated/", token:$token, tls_validation:true}')" \
        "${api_base}/remotes/ansible/collection/" 2>/dev/null)

      validated_remote=$(echo "$create_result" | python3 -c "import sys, json; print(json.loads(sys.stdin.read() or '{}').get('pulp_href', ''))" 2>/dev/null)
    else
      local validated_remote_url
      validated_remote_url=$(pah_resource_url "$validated_remote") || return 1
      pah_update_remote_token "$validated_remote_url" "rh-validated" || return 1
    fi

    [ -n "$validated_remote" ] || {
      _err "Could not create the rh-validated remote"
      return 1
    }
    echo "✓"

    printf "  Linking validated remote to repository... "
    local validated_repo
    validated_repo=$(curl -sk --max-time 10 -H "${auth_header}" \
      "${api_base}/repositories/ansible/ansible/?name=validated" 2>/dev/null \
      | python3 -c "import sys, json; data=json.loads(sys.stdin.read() or '{}'); print(data['results'][0]['pulp_href'] if data.get('results') else '')" 2>/dev/null)
    [ -n "$validated_repo" ] || {
      _err "rh-validated repository was not found"
      return 1
    }
    local validated_repo_url
    validated_repo_url=$(pah_resource_url "$validated_repo") || return 1
    curl -sk --fail --connect-timeout 10 --max-time 30 -H "${auth_header}" \
      -X PATCH \
      -H "Content-Type: application/json" \
      -d "{\"remote\": \"${validated_remote}\"}" \
      "${validated_repo_url}" >/dev/null || {
      _err "Could not link the rh-validated remote to its repository"
      return 1
    }
    echo "✓"

    printf "  Syncing validated... "
    local validated_sync_rc=0 refresh_rc=0
    if pah_sync_repository "$validated_repo" "rh-validated"; then
      :
    else
      validated_sync_rc=$?
      if [ "$validated_sync_rc" -eq 3 ] && [ "$auth_retry_attempt" -eq 0 ]; then
        if refresh_galaxy_credentials_after_remote_failure "Validated Content"; then
          printf '  Retrying Automation Hub remote configuration with the replacement token...\n'
          configure_pah_remotes 1
          return $?
        fi
        refresh_rc=$?
        if [ "$refresh_rc" -eq 4 ]; then
          printf '  %s⚠ Validated Content is not entitled for the saved Automation Hub token; continuing with Certified Content only.%s\n' \
            "${_YELLOW}" "${_NC}" >&2
        else
          printf '  %s⚠ Validated Content token replacement was not completed; continuing with Certified Content only.%s\n' \
            "${_YELLOW}" "${_NC}" >&2
        fi
      elif [ "$validated_sync_rc" -eq 3 ]; then
        printf '  %s⚠ Validated Content is unavailable to this Automation Hub token; continuing with Certified Content only.%s\n' \
          "${_YELLOW}" "${_NC}" >&2
      else
        return "$validated_sync_rc"
      fi
    fi
  else
    printf "  %s▸%s No galaxy token found, skipping console.redhat.com remotes\n" "${_YELLOW}" "${_NC}"
  fi

  # Configure PAH remote if configured
  if [ -n "$PAH_URL" ] && [ -n "$PAH_TOKEN" ]; then
    printf "  Configuring Private Automation Hub remote... "

    local create_result
    create_result=$(curl -sk --max-time 10 -H "${auth_header}" \
      -X POST \
      -H "Content-Type: application/json" \
      -d "{
        \"name\": \"external-pah\",
        \"url\": \"${PAH_URL}\",
        \"token\": \"${PAH_TOKEN}\",
        \"tls_validation\": true
      }" \
      "${api_base}/remotes/ansible/collection/" 2>&1)

    if echo "$create_result" | grep -q '"pulp_href"'; then
      echo "✓"
    else
      echo "⚠ (may already exist or invalid config)"
    fi
  fi

  echo "  ✓ PAH configuration complete"
}
