#!/usr/bin/env bash
# ADDON_REQUIRES_AAP=true
# Optional Red Hat Quay operator prerequisite. It installs only an owned OLM
# subscription. A QuayRegistry, storage, routes, users, robot accounts,
# mirroring, scanning, and image content are separate explicit decisions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-deploy}"
OPERATOR_NAMESPACE="${QUAY_OPERATOR_NAMESPACE:-aap-demo-quay-operator}"
CATALOG_NAMESPACE="${QUAY_CATALOG_NAMESPACE:-openshift-marketplace}"
CATALOG_SOURCE="${QUAY_CATALOG_SOURCE:-redhat-operators}"
PACKAGE_NAME="quay-operator"
SUBSCRIPTION_NAME="aap-demo-quay-operator"
OPERATOR_GROUP_NAME="aap-demo-quay-operator"
WAIT_SECONDS="${QUAY_WAIT_SECONDS:-900}"
source "$SCRIPT_DIR/../lib/olm-scenario.sh"

valid_dns_label() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

valid_channel() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]
}

validate_settings() {
  local value
  [[ "$WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: QUAY_WAIT_SECONDS must be a positive integer" >&2
    return 1
  }
  for value in "$OPERATOR_NAMESPACE" "$CATALOG_NAMESPACE" "$CATALOG_SOURCE"; do
    valid_dns_label "$value" || {
      echo "ERROR: Quay namespaces and CatalogSource names must be DNS-safe identifiers" >&2
      return 1
    }
  done
}

resource_is_owned_or_absent() {
  aap_demo_olm_resource_owned_or_absent "aap-demo/openshift-quay" "$@"
}

package_channel() {
  aap_demo_olm_package_channel "$PACKAGE_NAME" "$CATALOG_NAMESPACE" "$CATALOG_SOURCE"
}

wait_for_subscription() {
  aap_demo_olm_wait_subscription "$SUBSCRIPTION_NAME" "$OPERATOR_NAMESPACE" "$WAIT_SECONDS" "Red Hat Quay Operator"
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
    echo "ERROR: Refusing to change an unowned Quay operator namespace" >&2
    return 1
  }
  resource_is_owned_or_absent operatorgroup "$OPERATOR_GROUP_NAME" "$OPERATOR_NAMESPACE" || {
    echo "ERROR: Refusing to change an unowned Quay OperatorGroup" >&2
    return 1
  }
  resource_is_owned_or_absent subscription "$SUBSCRIPTION_NAME" "$OPERATOR_NAMESPACE" || {
    echo "ERROR: Refusing to change an unowned Quay Subscription" >&2
    return 1
  }
}

deploy() {
  local channel rendered
  preflight || return 1
  channel=$(package_channel) || {
    echo "ERROR: Package ${PACKAGE_NAME} is not available from ${CATALOG_SOURCE}" >&2
    return 1
  }
  valid_channel "$channel" || {
    echo "ERROR: Catalog returned an unsafe Quay operator channel name" >&2
    return 1
  }
  rendered=$(sed \
    -e "s|__OPERATOR_NAMESPACE__|${OPERATOR_NAMESPACE}|g" \
    -e "s|__OPERATOR_GROUP_NAME__|${OPERATOR_GROUP_NAME}|g" \
    -e "s|__SUBSCRIPTION_NAME__|${SUBSCRIPTION_NAME}|g" \
    -e "s|__CHANNEL__|${channel}|g" \
    -e "s|__CATALOG_SOURCE__|${CATALOG_SOURCE}|g" \
    -e "s|__CATALOG_NAMESPACE__|${CATALOG_NAMESPACE}|g" \
    "$SCRIPT_DIR/quay-operator.yaml") || return 1
  printf '%s\n' "$rendered" | kubectl apply -f - >/dev/null
  echo "Waiting for the Red Hat Quay Operator..."
  wait_for_subscription
  echo "✓ Red Hat Quay Operator prerequisite is ready"
  echo "  No QuayRegistry, storage, route, user, robot account, mirror, scan, credential, or image content was created."
}

remove() {
  command -v jq >/dev/null 2>&1 || {
    echo "ERROR: jq is required for safe ownership checks" >&2
    return 1
  }
  if kubectl get namespace "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    resource_is_owned_or_absent namespace "$OPERATOR_NAMESPACE" || {
      echo "ERROR: Refusing to delete an unowned Quay operator namespace" >&2
      return 1
    }
    kubectl delete namespace "$OPERATOR_NAMESPACE" --ignore-not-found >/dev/null
  fi
  echo "✓ Removed the aap-demo-owned Quay operator namespace"
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
