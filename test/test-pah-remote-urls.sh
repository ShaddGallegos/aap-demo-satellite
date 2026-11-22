#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
REQUEST_LOG="$TEST_DIR/requests"

_err() { printf 'ERROR: %s\n' "$*" >&2; }
# shellcheck source=../includes/galaxy-auth.sh
source "$REPO_ROOT/includes/galaxy-auth.sh"

NAMESPACE=test-aap
PAH_REFRESH_CALLS=0

detect_galaxy_credentials() {
  GALAXY_TOKEN=redacted-test-token
  PAH_URL=""
  PAH_TOKEN=""
}

refresh_galaxy_credentials_after_remote_failure() {
  PAH_REFRESH_CALLS=$((PAH_REFRESH_CALLS + 1))
  return 0
}

kubectl() {
  case "$*" in
    *"get route aap"*) printf 'aap.example.test' ;;
    *"get secret aap-admin-password"*) printf 'c2VjcmV0' ;;
    *) return 1 ;;
  esac
}

# Keep the bounded wait test instant while still exercising its status output.
sleep() { :; }

curl() {
  local url="${!#}" request="$*"
  printf '%s\n' "$url" >>"$REQUEST_LOG"
  case "$url" in
    *'/remotes/ansible/collection/?name=rh-certified')
      printf '%s\n' '{"results":[{"pulp_href":"/api/galaxy/pulp/api/v3/remotes/ansible/collection/certified/"}]}'
      ;;
    *'/remotes/ansible/collection/?name=rh-validated')
      printf '%s\n' '{"results":[{"pulp_href":"/api/galaxy/pulp/api/v3/remotes/ansible/collection/validated/"}]}'
      ;;
    *'/repositories/ansible/ansible/?name=rh-certified')
      printf '%s\n' '{"results":[{"pulp_href":"/api/galaxy/pulp/api/v3/repositories/ansible/ansible/certified/"}]}'
      ;;
    *'/repositories/ansible/ansible/?name=validated')
      printf '%s\n' '{"results":[{"pulp_href":"/api/galaxy/pulp/api/v3/repositories/ansible/ansible/validated/"}]}'
      ;;
    *'/tasks/validated/'*)
      if [ "${PAH_TEST_VALIDATED_DENIED:-false}" = true ]; then
        printf '%s\n' "{\"state\":\"failed\",\"error\":{\"description\":\"401, message='Unauthorized'\"}}"
      else
        printf '%s\n' '{"state":"completed"}'
      fi
      ;;
    *'/tasks/update/'*) printf '%s\n' '{"state":"completed"}' ;;
    *'/tasks/'*)
      if [ "${PAH_TEST_PENDING_ONCE:-false}" = true ] && [ ! -e "$TEST_DIR/first-task-pending" ]; then
        : >"$TEST_DIR/first-task-pending"
        printf '%s\n' '{"state":"running"}'
      else
        printf '%s\n' '{"state":"completed"}'
      fi
      ;;
    *'/repositories/ansible/ansible/validated/sync/') printf '%s\n' '{"task":"/api/galaxy/pulp/api/v3/tasks/validated/"}' ;;
    *'/sync/') printf '%s\n' '{"task":"/api/galaxy/pulp/api/v3/tasks/test/"}' ;;
    *)
      if [[ "$request" == *' -X PATCH '* ]]; then
        if [ "${PAH_TEST_ASYNC_UPDATE:-false}" = true ]; then
          printf '%s\n' '{"task":"/api/galaxy/pulp/api/v3/tasks/update/"}'
        else
          printf '%s\n' '{"pulp_href":"/api/galaxy/pulp/api/v3/updated/"}'
        fi
      else
        printf '%s\n' '{"pulp_href":"/api/galaxy/pulp/api/v3/created/"}'
      fi
      ;;
  esac
}

PAH_TEST_PENDING_ONCE=true PAH_TEST_VALIDATED_DENIED=true PAH_TEST_ASYNC_UPDATE=true PAH_SYNC_TIMEOUT_SECONDS=60 PAH_SYNC_POLL_SECONDS=30 \
  configure_pah_remotes >"$TEST_DIR/output" 2>&1

if grep -Fq '/api/galaxy/pulp/api/v3/api/galaxy/pulp/api/v3/' "$REQUEST_LOG"; then
  echo "FAIL: a Pulp resource URL duplicated the API base path" >&2
  exit 1
fi

for resource in remotes/ansible/collection/certified repositories/ansible/ansible/certified remotes/ansible/collection/validated repositories/ansible/ansible/validated; do
  grep -Fq "https://aap.example.test/api/galaxy/pulp/api/v3/${resource}/" "$REQUEST_LOG"
done
grep -Fq 'rh-certified sync still running (0m00s; waiting up to 1m; task:' "$TEST_DIR/output"
grep -Fq 'Applying rh-certified remote token update...' "$TEST_DIR/output"
grep -Fq 'Validated Content is unavailable to this Automation Hub token; continuing with Certified Content only.' "$TEST_DIR/output"
[ "$PAH_REFRESH_CALLS" -eq 1 ]

echo "PASS: existing PAH resources use their Pulp hrefs exactly once"
