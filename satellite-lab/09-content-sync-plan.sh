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

case "$INTERVAL" in
  daily | weekly | monthly) ;;
  *)
    echo "ERROR: SATELLITE_SYNC_PLAN_INTERVAL must be daily, weekly, or monthly" >&2
    exit 2
    ;;
esac

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

  local remotes remote_id products product_id create_args repo_ids repos mirrored output repo_id
  remotes=$(hammer --output json flatpak-remote list --organization "$ORG") || return 1
  remote_id=$(jq -er --arg name "$FLATPAK_NAME" \
    '.[] | select((.Name // .name) == $name) | (.Id // .id)' <<<"$remotes" | head -n1) || true
  if [ -z "$remote_id" ]; then
    echo "▸ Creating Flatpak remote: ${FLATPAK_NAME}"
    create_args=(flatpak-remote create --name "$FLATPAK_NAME" --organization "$ORG" --url "$FLATPAK_URL")
    [ -z "${SATELLITE_FLATPAK_USERNAME:-}" ] || create_args+=(--username "$SATELLITE_FLATPAK_USERNAME")
    [ -z "${SATELLITE_FLATPAK_TOKEN:-}" ] || create_args+=(--token "$SATELLITE_FLATPAK_TOKEN")
    hammer "${create_args[@]}" || return 1
    remotes=$(hammer --output json flatpak-remote list --organization "$ORG") || return 1
    remote_id=$(jq -er --arg name "$FLATPAK_NAME" \
      '.[] | select((.Name // .name) == $name) | (.Id // .id)' <<<"$remotes" | head -n1) || return 1
  else
    echo "✓ Reusing Flatpak remote: ${FLATPAK_NAME}"
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
  repos=$(hammer --output json flatpak-remote remote-repository list --remote-id "$remote_id") || return 1
  mapfile -t repo_ids < <(jq -r '.[] | (.Id // .id // empty)' <<<"$repos" | sort -u)
  [ "${#repo_ids[@]}" -gt 0 ] || {
    echo "ERROR: Flatpak remote ${FLATPAK_NAME} returned no repositories after scanning" >&2
    return 1
  }
  for repo_id in "${repo_ids[@]}"; do
    if ! output=$(hammer flatpak-remote remote-repository mirror --id "$repo_id" --product-id "$product_id" 2>&1); then
      case "$output" in
        *already*mirrored* | *already*exists*) echo "  ✓ Flatpak repository ${repo_id} already mirrored" ;;
        *) printf '%s\n' "$output" >&2; return 1 ;;
      esac
    fi
  done
  repos=$(hammer --output json repository list --product-id "$product_id") || return 1
  mapfile -t repo_ids < <(jq -r '.[] | (.Id // .id // empty)' <<<"$repos" | sort -u)
  [ "${#repo_ids[@]}" -gt 0 ] || {
    echo "ERROR: No Satellite repositories were created for Flatpak product ${FLATPAK_PRODUCT}" >&2
    return 1
  }
  for repo_id in "${repo_ids[@]}"; do
    hammer repository synchronize --id "$repo_id" || return 1
  done
  echo "✓ Flatpak remote ${FLATPAK_NAME} mirrored and synchronized (${#repo_ids[@]} repository/repositories)"
}

reconcile_flatpak_remote

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
    create_args=(repository create --organization "$ORG" --product "$COLLECTIONS_PRODUCT" \
      --name "$COLLECTIONS_REPOSITORY" --content-type ansible_collection --url "$COLLECTIONS_URL" \
      --ansible-collection-auth-token "$SATELLITE_COLLECTIONS_AUTH_TOKEN" \
      --ansible-collection-auth-url "$COLLECTIONS_AUTH_URL")
    hammer "${create_args[@]}" || return 1
    repositories=$(hammer --output json repository list --product-id "$product_id") || return 1
    repository_id=$(jq -er --arg name "$COLLECTIONS_REPOSITORY" \
      '.[] | select((.Name // .name) == $name) | (.Id // .id)' <<<"$repositories" | head -n1) || return 1
  else
    # Rotate the upstream token without deleting content or changing the repo.
    hammer repository update --id "$repository_id" --url "$COLLECTIONS_URL" \
      --ansible-collection-auth-token "$SATELLITE_COLLECTIONS_AUTH_TOKEN" \
      --ansible-collection-auth-url "$COLLECTIONS_AUTH_URL" || return 1
  fi
  hammer repository synchronize --id "$repository_id" || return 1
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
