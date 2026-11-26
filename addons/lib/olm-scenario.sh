#!/usr/bin/env bash
# Shared OLM safety primitives for optional aap-demo operator scenarios.
# Callers retain product-specific namespaces, manifests, preflight, and messages.

if [ -n "${_AAP_DEMO_OLM_SCENARIO_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_OLM_SCENARIO_LOADED=1

aap_demo_olm_valid_dns_label() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

aap_demo_olm_valid_channel() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]
}

# A missing object is safe to create. An existing object must carry the exact
# scenario ownership label; blank/malformed metadata is never treated as absent.
aap_demo_olm_resource_owned_or_absent() {
  local label="$1" resource="$2" name="$3" namespace="${4:-}" manifest owner
  if [ -n "$namespace" ]; then
    if ! manifest=$(kubectl get "$resource" "$name" -n "$namespace" -o json 2>/dev/null); then
      return 0
    fi
  else
    if ! manifest=$(kubectl get "$resource" "$name" -o json 2>/dev/null); then
      return 0
    fi
  fi
  owner=$(jq -r --arg label "$label" '.metadata.labels[$label] // ""' <<<"$manifest") || return 1
  [ "$owner" = managed ]
}

# A PackageManifest name alone is ambiguous when multiple catalogs are present.
aap_demo_olm_package_channel() {
  local package="$1" catalog_namespace="$2" catalog_source="$3" manifest catalog channel
  manifest=$(kubectl get packagemanifest "$package" -n "$catalog_namespace" -o json 2>/dev/null) || return 1
  catalog=$(jq -r '.metadata.labels.catalog // ""' <<<"$manifest") || return 1
  [ "$catalog" = "$catalog_source" ] || return 1
  channel=$(jq -r '.status.defaultChannel // ""' <<<"$manifest") || return 1
  [ -n "$channel" ] || return 1
  printf '%s\n' "$channel"
}

aap_demo_olm_wait_subscription() {
  local name="$1" namespace="$2" wait_seconds="$3" display_name="$4" elapsed=0 csv phase
  while [ "$elapsed" -lt "$wait_seconds" ]; do
    csv=$(kubectl get subscription "$name" -n "$namespace" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [ -n "$csv" ]; then
      phase=$(kubectl get csv "$csv" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      case "$phase" in
        Succeeded) echo "  ✓ ${display_name} is ready (${csv})"; return 0 ;;
        Failed) echo "ERROR: ${display_name} install CSV failed: ${csv}" >&2; kubectl describe csv "$csv" -n "$namespace" >&2 || true; return 1 ;;
      esac
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "ERROR: Timed out after ${wait_seconds}s waiting for ${display_name}" >&2
  echo "  Check: kubectl get subscription,csv -n ${namespace}" >&2
  return 1
}
