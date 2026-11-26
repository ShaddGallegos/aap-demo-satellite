#!/usr/bin/env bash
# 09-content-sync-plan.sh — run ON the Satellite VM as root.
#
# Create one retained, recurring sync plan and attach it to every content
# product in the selected organization. A Satellite sync plan is associated
# with products, so this covers every repository in each managed product.
set -euo pipefail

ORG="${SAT_ORG:-Default Organization}"
PLAN_NAME="${SATELLITE_SYNC_PLAN_NAME:-aap-demo-all-content}"
INTERVAL="${SATELLITE_SYNC_PLAN_INTERVAL:-daily}"
SYNC_DATE="${SATELLITE_SYNC_PLAN_SYNC_DATE:-}"
FLATPAK_ENABLED="${SATELLITE_FLATPAK_ENABLED:-true}"
FLATPAK_NAME="${SATELLITE_FLATPAK_REMOTE_NAME:-RHEL_Flatpak}"
FLATPAK_URL="${SATELLITE_FLATPAK_REMOTE_URL:-https://flatpaks.redhat.io/rhel/}"
FLATPAK_PRODUCT="${SATELLITE_FLATPAK_PRODUCT:-aap-demo-flatpak}"
COLLECTIONS_ENABLED="${SATELLITE_COLLECTIONS_ENABLED:-true}"
COLLECTIONS_PRODUCT="${SATELLITE_COLLECTIONS_PRODUCT:-aap-demo-ansible-collections}"
COLLECTIONS_REPOSITORY="${SATELLITE_COLLECTIONS_REPOSITORY:-Red Hat Ansible Collections}"
COLLECTIONS_URL="${SATELLITE_COLLECTIONS_URL:-https://console.redhat.com/api/automation-hub/}"
COLLECTIONS_AUTH_URL="${SATELLITE_COLLECTIONS_AUTH_URL:-https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token}"
CONTENT_SYNC_TIMEOUT_SECONDS="${SATELLITE_CONTENT_SYNC_TIMEOUT_SECONDS:-5400}"
# The Automation Hub offline-token exchange is reliable when the first catalog
# import is serialized.  Higher Pulp concurrency can stampede the exchange and
# leave a Satellite worker refreshing bearer tokens without transferring data.
COLLECTIONS_DOWNLOAD_CONCURRENCY="${SATELLITE_COLLECTIONS_DOWNLOAD_CONCURRENCY:-1}"

case "$INTERVAL" in
  daily | weekly | monthly) ;;
  *)
    echo "ERROR: SATELLITE_SYNC_PLAN_INTERVAL must be daily, weekly, or monthly" >&2
    exit 2
    ;;
esac

case "$CONTENT_SYNC_TIMEOUT_SECONDS" in
  '' | *[!0-9]*)
    echo "ERROR: SATELLITE_CONTENT_SYNC_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
    ;;
esac
[ "$CONTENT_SYNC_TIMEOUT_SECONDS" -gt 0 ] || {
  echo "ERROR: SATELLITE_CONTENT_SYNC_TIMEOUT_SECONDS must be greater than zero" >&2
  exit 2
}

case "$COLLECTIONS_DOWNLOAD_CONCURRENCY" in
  '' | *[!0-9]*)
    echo "ERROR: SATELLITE_COLLECTIONS_DOWNLOAD_CONCURRENCY must be an integer from 1 to 19" >&2
    exit 2
    ;;
esac
[ "$COLLECTIONS_DOWNLOAD_CONCURRENCY" -ge 1 ] && [ "$COLLECTIONS_DOWNLOAD_CONCURRENCY" -lt 20 ] || {
  echo "ERROR: SATELLITE_COLLECTIONS_DOWNLOAD_CONCURRENCY must be an integer from 1 to 19" >&2
  exit 2
}

if [ -z "$SYNC_DATE" ]; then
  # Only used when creating the plan. Existing plans retain their established
  # schedule on repeat runs.
  SYNC_DATE=$(date -d '+15 minutes' '+%Y-%m-%d %H:%M:%S')
fi

if hammer sync-plan info --organization "$ORG" --name "$PLAN_NAME" >/dev/null 2>&1; then
  echo "✓ Reusing sync plan: ${PLAN_NAME}"
else
  echo "▸ Creating ${INTERVAL} sync plan: ${PLAN_NAME}"
  hammer sync-plan create --organization "$ORG" --name "$PLAN_NAME" \
    --interval "$INTERVAL" --sync-date "$SYNC_DATE" --enabled true
fi

reconcile_flatpak_remote() {
  [ "$FLATPAK_ENABLED" = true ] || {
    echo "▸ Flatpak remote disabled by SATELLITE_FLATPAK_ENABLED=false"
    return 0
  }
  hammer flatpak-remote --help >/dev/null 2>&1 || {
    echo "ERROR: This Satellite installation does not provide the Flatpak remote Hammer commands" >&2
    return 1
  }

  local remotes remote_id products product_id create_args repo_ids repos remote_repos
  local target_repos output repo_id repo_name
  remotes=$(hammer --output json flatpak-remote list --organization "$ORG") || return 1
  remote_id=$(jq -er --arg name "$FLATPAK_NAME" \
    '.[] | select((.Name // .name) == $name) | (.ID // .Id // .id)' <<<"$remotes" | head -n1) || true
  if [ -z "$remote_id" ]; then
    echo "▸ Creating Flatpak remote: ${FLATPAK_NAME}"
    create_args=(flatpak-remote create --name "$FLATPAK_NAME" --organization "$ORG" --url "$FLATPAK_URL")
    [ -z "${SATELLITE_FLATPAK_USERNAME:-}" ] || create_args+=(--username "$SATELLITE_FLATPAK_USERNAME")
    [ -z "${SATELLITE_FLATPAK_TOKEN:-}" ] || create_args+=(--token "$SATELLITE_FLATPAK_TOKEN")
    hammer "${create_args[@]}" || return 1
    remotes=$(hammer --output json flatpak-remote list --organization "$ORG") || return 1
    remote_id=$(jq -er --arg name "$FLATPAK_NAME" \
      '.[] | select((.Name // .name) == $name) | (.ID // .Id // .id)' <<<"$remotes" | head -n1) || return 1
  else
    echo "✓ Reusing Flatpak remote: ${FLATPAK_NAME}"
  fi
  if [ -n "${SATELLITE_FLATPAK_USERNAME:-}" ] && [ -n "${SATELLITE_FLATPAK_TOKEN:-}" ]; then
    # Remote credentials are held by Satellite, not printed by Hammer. Update
    # them on every reconciliation so an imported pull-secret rotation is used
    # without deleting the remote or its mirrored content.
    hammer flatpak-remote update --id "$remote_id" \
      --username "$SATELLITE_FLATPAK_USERNAME" --token "$SATELLITE_FLATPAK_TOKEN" || return 1
  else
    echo "ERROR: Flatpak mirroring requires registry.redhat.io credentials" >&2
    echo "  Configure the Vault-backed CDN credentials, or a Registry Service Account if Red Hat rejects their registry scope, then retry." >&2
    return 1
  fi

  products=$(hammer --output json product list --organization "$ORG") || return 1
  product_id=$(jq -er --arg name "$FLATPAK_PRODUCT" \
    '.[] | select((.Name // .name) == $name) | (.Id // .id)' <<<"$products" | head -n1) || true
  if [ -z "$product_id" ]; then
    echo "▸ Creating Flatpak product: ${FLATPAK_PRODUCT}"
    hammer product create --organization "$ORG" --name "$FLATPAK_PRODUCT" || return 1
    products=$(hammer --output json product list --organization "$ORG") || return 1
    product_id=$(jq -er --arg name "$FLATPAK_PRODUCT" \
      '.[] | select((.Name // .name) == $name) | (.Id // .id)' <<<"$products" | head -n1) || return 1
  fi

  hammer flatpak-remote scan --id "$remote_id" || return 1
  remote_repos=$(hammer --output json flatpak-remote remote-repository list \
    --flatpak-remote-id "$remote_id") || return 1
  mapfile -t repo_ids < <(jq -r '.[] | (.ID // .Id // .id // empty)' <<<"$remote_repos" | sort -u)
  [ "${#repo_ids[@]}" -gt 0 ] || {
    echo "ERROR: Flatpak remote ${FLATPAK_NAME} returned no repositories after scanning" >&2
    return 1
  }
  target_repos=$(hammer --output json repository list --product-id "$product_id") || return 1
  while IFS=$'\t' read -r repo_id repo_name; do
    [ -n "$repo_id" ] || continue
    if jq -e --arg name "$repo_name" \
      'any(.[]; (.Name // .name) == $name)' <<<"$target_repos" >/dev/null; then
      echo "  ✓ Flatpak repository ${repo_name} already mirrored"
      continue
    fi
    if ! output=$(hammer flatpak-remote remote-repository mirror --id "$repo_id" \
      --flatpak-remote-id "$remote_id" --product-id "$product_id" 2>&1); then
      case "$output" in
        *already*mirrored* | *already*exists*) echo "  ✓ Flatpak repository ${repo_id} already mirrored" ;;
        *)
          printf '%s\n' "$output" >&2
          return 1
          ;;
      esac
    fi
  done < <(jq -r '.[] | [(.ID // .Id // .id // empty), (.Name // .name // empty)] | @tsv' \
    <<<"$remote_repos")
  repos=$(hammer --output json repository list --product-id "$product_id") || return 1
  mapfile -t repo_ids < <(jq -r '.[] | (.ID // .Id // .id // empty)' <<<"$repos" | sort -u)
  [ "${#repo_ids[@]}" -gt 0 ] || {
    echo "ERROR: No Satellite repositories were created for Flatpak product ${FLATPAK_PRODUCT}" >&2
    return 1
  }
  for repo_id in "${repo_ids[@]}"; do
    # Mirroring creates a Pulp remote for each repository. Updating only the
    # parent Flatpak remote leaves an existing child remote with its previous
    # credentials, so rotate the per-repository upstream authentication too.
    hammer repository update --id "$repo_id" \
      --upstream-username "$SATELLITE_FLATPAK_USERNAME" \
      --upstream-password "$SATELLITE_FLATPAK_TOKEN" || return 1
    if ! hammer repository synchronize --id "$repo_id"; then
      echo "ERROR: Flatpak repository synchronization failed." >&2
      echo "  Verify the Vault-backed CDN credentials are authorized for the Red Hat Flatpak registry." >&2
      echo "  If Red Hat rejects that scope, rerun interactively to replace them with a Registry Service Account." >&2
      return 1
    fi
  done
  echo "✓ Flatpak remote ${FLATPAK_NAME} mirrored and synchronized (${#repo_ids[@]} repository/repositories)"
}

reconcile_flatpak_remote

recover_stalled_collection_worker() {
  local unit refreshes
  # Pulp can leave a task running when an Automation Hub bearer-token refresh
  # loops. Restart only the worker that is demonstrably emitting that loop;
  # this makes Pulp mark the abandoned task stopped so a later reconciliation
  # can start a fresh, serialized sync.
  for unit in pulpcore-worker@1 pulpcore-worker@2 pulpcore-worker@3 pulpcore-worker@4; do
    refreshes=$(journalctl -u "$unit" --since '5 minutes ago' --no-pager 2>/dev/null \
      | grep -Fc 'Updating bearer token' || true)
    if [ "$refreshes" -ge 20 ]; then
      echo "WARNING: restarting $unit after ${refreshes} repeated Automation Hub token refreshes" >&2
      systemctl restart "$unit" || return 1
      return 0
    fi
  done
  echo "WARNING: collection sync timed out, but no token-refreshing Pulp worker was identified; leaving services unchanged" >&2
  return 0
}

wait_for_existing_repository_sync() {
  local repository_name="$1" active_tasks task_id
  active_tasks=$(hammer --output json task list --search 'state = running' --per-page 100) || return 1
  task_id=$(jq -r --arg repository "$repository_name" '
    .[]
    | select(((.Action // .action // "") | contains("Synchronize repository '\''" + $repository + "'\''")))
    | (.ID // .Id // .id // empty)
  ' <<<"$active_tasks" | head -n1) || return 1
  # Distinguish “none is running” from a running task that later fails: the
  # caller may launch a new sync only in the former case.
  [ -n "$task_id" ] || return 3

  echo "▸ Reusing active synchronization for ${repository_name} (task: ${task_id})"
  echo "  Waiting up to $((CONTENT_SYNC_TIMEOUT_SECONDS / 60)) minutes; progress is reported by Satellite."
  if ! timeout "$CONTENT_SYNC_TIMEOUT_SECONDS" hammer task progress --id "$task_id"; then
    recover_stalled_collection_worker || true
    echo "ERROR: Existing synchronization for ${repository_name} did not complete successfully." >&2
    return 1
  fi
  return 0
}

reconcile_ansible_collections() {
  [ "$COLLECTIONS_ENABLED" = true ] || {
    echo "▸ Ansible collection mirror disabled by SATELLITE_COLLECTIONS_ENABLED=false"
    return 0
  }
  [ -n "${SATELLITE_COLLECTIONS_AUTH_TOKEN:-}" ] || {
    echo "ERROR: The Automation Hub offline token is required to synchronize Ansible collections into Satellite" >&2
    echo "  Store it as ah_offline_token in ~/.ansible/conf/env.yml, then retry." >&2
    return 1
  }

  local products product_id repositories repository_id create_args
  products=$(hammer --output json product list --organization "$ORG") || return 1
  product_id=$(jq -er --arg name "$COLLECTIONS_PRODUCT" \
    '.[] | select((.Name // .name) == $name) | (.Id // .id)' <<<"$products" | head -n1) || true
  if [ -z "$product_id" ]; then
    echo "▸ Creating Ansible collections product: ${COLLECTIONS_PRODUCT}"
    hammer product create --organization "$ORG" --name "$COLLECTIONS_PRODUCT" || return 1
    products=$(hammer --output json product list --organization "$ORG") || return 1
    product_id=$(jq -er --arg name "$COLLECTIONS_PRODUCT" \
      '.[] | select((.Name // .name) == $name) | (.Id // .id)' <<<"$products" | head -n1) || return 1
  fi

  repositories=$(hammer --output json repository list --product-id "$product_id") || return 1
  repository_id=$(jq -er --arg name "$COLLECTIONS_REPOSITORY" \
    '.[] | select((.Name // .name) == $name) | (.Id // .id)' <<<"$repositories" | head -n1) || true
  if [ -z "$repository_id" ]; then
    echo "▸ Creating Ansible collections repository: ${COLLECTIONS_REPOSITORY}"
    create_args=(repository create --organization "$ORG" --product "$COLLECTIONS_PRODUCT"
      --name "$COLLECTIONS_REPOSITORY" --content-type ansible_collection --url "$COLLECTIONS_URL"
      --ansible-collection-auth-token "$SATELLITE_COLLECTIONS_AUTH_TOKEN"
      --ansible-collection-auth-url "$COLLECTIONS_AUTH_URL"
      --download-concurrency "$COLLECTIONS_DOWNLOAD_CONCURRENCY")
    hammer "${create_args[@]}" || return 1
    repositories=$(hammer --output json repository list --product-id "$product_id") || return 1
    repository_id=$(jq -er --arg name "$COLLECTIONS_REPOSITORY" \
      '.[] | select((.Name // .name) == $name) | (.Id // .id)' <<<"$repositories" | head -n1) || return 1
  else
    # Rotate the upstream token without deleting content or changing the repo.
    hammer repository update --id "$repository_id" --url "$COLLECTIONS_URL" \
      --ansible-collection-auth-token "$SATELLITE_COLLECTIONS_AUTH_TOKEN" \
      --ansible-collection-auth-url "$COLLECTIONS_AUTH_URL" \
      --download-concurrency "$COLLECTIONS_DOWNLOAD_CONCURRENCY" || return 1
  fi
  # A prior full-demo run can still be transferring the initial collection
  # catalog. Reuse that authoritative Pulp task rather than launching a
  # duplicate (which Satellite rejects) and incorrectly failing this stage.
  if wait_for_existing_repository_sync "$COLLECTIONS_REPOSITORY"; then
    :
  else
    local wait_rc=$?
    if [ "$wait_rc" -eq 3 ]; then
      if ! timeout "$CONTENT_SYNC_TIMEOUT_SECONDS" hammer repository synchronize --id "$repository_id"; then
        recover_stalled_collection_worker || true
        echo "ERROR: Ansible collection synchronization did not complete before the timeout." >&2
        return 1
      fi
    else
      return "$wait_rc"
    fi
  fi
  unset SATELLITE_COLLECTIONS_AUTH_TOKEN
  echo "✓ Ansible collection repository synchronized: ${COLLECTIONS_REPOSITORY}"
}

reconcile_ansible_collections

products=$(hammer --output json product list --organization "$ORG")
mapfile -t product_names < <(jq -r '.[] | (.Name // .name // empty)' <<<"$products" | sort -u)
[ "${#product_names[@]}" -gt 0 ] || {
  echo "ERROR: No content products found in organization: ${ORG}" >&2
  exit 1
}

for product in "${product_names[@]}"; do
  # Applying the same plan again is idempotent. Do not filter to a hard-coded
  # product list: the plan must keep covering all content added to this lab.
  hammer product set-sync-plan --organization "$ORG" --name "$product" \
    --sync-plan "$PLAN_NAME"
done

echo "✓ Sync plan '${PLAN_NAME}' is attached to ${#product_names[@]} product(s) in ${ORG}"
