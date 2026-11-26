#!/usr/bin/env bash
# ADDON_REQUIRES_AAP=true
# Optional Red Hat Advanced Cluster Security (RHACS) operator prerequisite.
# It installs only an owned Operator Lifecycle Manager subscription. Central,
# SecuredCluster, init bundles, policy changes, scans, and integrations remain
# deliberate operator actions outside this addon.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-deploy}"
OPERATOR_NAMESPACE="${RHACS_OPERATOR_NAMESPACE:-rhacs-operator}"
CATALOG_NAMESPACE="${RHACS_CATALOG_NAMESPACE:-openshift-marketplace}"
CATALOG_SOURCE="${RHACS_CATALOG_SOURCE:-redhat-operators}"
PACKAGE_NAME="rhacs-operator"
SUBSCRIPTION_NAME="aap-demo-rhacs-operator"
OPERATOR_GROUP_NAME="aap-demo-rhacs-operator"
WAIT_SECONDS="${RHACS_WAIT_SECONDS:-900}"

valid_dns_label() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

valid_channel() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]
}

validate_settings() {
  local value
  [[ "$WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: RHACS_WAIT_SECONDS must be a positive integer" >&2
    return 1
  }
  for value in "$OPERATOR_NAMESPACE" "$CATALOG_NAMESPACE" "$CATALOG_SOURCE"; do
    valid_dns_label "$value" || {
      echo "ERROR: RHACS namespaces and CatalogSource names must be DNS-safe identifiers" >&2
      return 1
    }
  done
}

resource_is_owned_or_absent() {
  local resource="$1" name="$2" namespace="${3:-}" manifest owner
  if [ -n "$namespace" ]; then
    if ! manifest=$(kubectl get "$resource" "$name" -n "$namespace" -o json 2>/dev/null); then
      return 0
    fi
  else
    if ! manifest=$(kubectl get "$resource" "$name" -o json 2>/dev/null); then
      return 0
    fi
  fi
  owner=$(jq -r '.metadata.labels["aap-demo/openshift-security"] // ""' <<<"$manifest") || return 1
  [ "$owner" = managed ]
}

package_channel() {
  kubectl get packagemanifest "$PACKAGE_NAME" -n "$CATALOG_NAMESPACE" \
    -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true
}

wait_for_subscription() {
  local elapsed=0 csv phase
  while [ "$elapsed" -lt "$WAIT_SECONDS" ]; do
    csv=$(kubectl get subscription "$SUBSCRIPTION_NAME" -n "$OPERATOR_NAMESPACE" \
      -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [ -n "$csv" ]; then
      phase=$(kubectl get csv "$csv" -n "$OPERATOR_NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)
      case "$phase" in
        Succeeded)
          echo "  ✓ RHACS Operator is ready (${csv})"
          return 0
          ;;
        Failed)
          echo "ERROR: RHACS Operator install CSV failed: ${csv}" >&2
          kubectl describe csv "$csv" -n "$OPERATOR_NAMESPACE" >&2 || true
          return 1
          ;;
      esac
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "ERROR: Timed out after ${WAIT_SECONDS}s waiting for the RHACS Operator" >&2
  echo "  Check: kubectl get subscription,csv -n ${OPERATOR_NAMESPACE}" >&2
  return 1
}

preflight() {
  command -v jq >/dev/null 2>&1 || {
    echo "ERROR: jq is required for safe ownership checks" >&2
    return 1
  }
  kubectl cluster-info >/dev/null 2>&1 || {
    echo "ERROR: kubectl is not connected to a cluster" >&2
    return 1
  }
  kubectl get crd subscriptions.operators.coreos.com >/dev/null 2>&1 || {
    echo "ERROR: OLM Subscription CRD is unavailable; enable OLM before this addon" >&2
    return 1
  }
  kubectl get catalogsource "$CATALOG_SOURCE" -n "$CATALOG_NAMESPACE" >/dev/null 2>&1 || {
    echo "ERROR: CatalogSource ${CATALOG_SOURCE} is unavailable in ${CATALOG_NAMESPACE}" >&2
    echo "  Configure Red Hat operator catalog access before enabling this optional scenario." >&2
    return 1
  }
  resource_is_owned_or_absent namespace "$OPERATOR_NAMESPACE" || {
    echo "ERROR: Refusing to change an unowned RHACS operator namespace" >&2
    return 1
  }
  resource_is_owned_or_absent operatorgroup "$OPERATOR_GROUP_NAME" "$OPERATOR_NAMESPACE" || {
    echo "ERROR: Refusing to change an unowned RHACS OperatorGroup" >&2
    return 1
  }
  resource_is_owned_or_absent subscription "$SUBSCRIPTION_NAME" "$OPERATOR_NAMESPACE" || {
    echo "ERROR: Refusing to change an unowned RHACS Subscription" >&2
    return 1
  }
}

deploy() {
  local channel rendered
  preflight || return 1
  channel=$(package_channel)
  [ -n "$channel" ] || {
    echo "ERROR: Package ${PACKAGE_NAME} is not available from ${CATALOG_SOURCE}" >&2
    return 1
  }
  valid_channel "$channel" || {
    echo "ERROR: Catalog returned an unsafe RHACS operator channel name" >&2
    return 1
  }
  rendered=$(sed \
    -e "s|__OPERATOR_NAMESPACE__|${OPERATOR_NAMESPACE}|g" \
    -e "s|__OPERATOR_GROUP_NAME__|${OPERATOR_GROUP_NAME}|g" \
    -e "s|__SUBSCRIPTION_NAME__|${SUBSCRIPTION_NAME}|g" \
    -e "s|__CHANNEL__|${channel}|g" \
    -e "s|__CATALOG_SOURCE__|${CATALOG_SOURCE}|g" \
    -e "s|__CATALOG_NAMESPACE__|${CATALOG_NAMESPACE}|g" \
    "$SCRIPT_DIR/rhacs-operator.yaml") || return 1
  printf '%s\n' "$rendered" | kubectl apply -f - >/dev/null
  echo "Waiting for the RHACS Operator..."
  wait_for_subscription
  echo "✓ RHACS Operator prerequisite is ready"
  echo "  No Central, SecuredCluster, init bundle, policy, scan, credential, or customer workload was created."
}

remove() {
  command -v jq >/dev/null 2>&1 || {
    echo "ERROR: jq is required for safe ownership checks" >&2
    return 1
  }
  if kubectl get namespace "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    resource_is_owned_or_absent namespace "$OPERATOR_NAMESPACE" || {
      echo "ERROR: Refusing to delete an unowned RHACS operator namespace" >&2
      return 1
    }
    kubectl delete namespace "$OPERATOR_NAMESPACE" --ignore-not-found >/dev/null
  fi
  echo "✓ Removed the aap-demo-owned RHACS operator namespace"
}

validate_settings
case "$ACTION" in
  deploy) deploy ;;
  --delete | delete) remove ;;
  *)
    echo "ERROR: Usage: deploy.sh [--delete]" >&2
    exit 2
    ;;
esac
