#!/usr/bin/env bash
# ADDON_REQUIRES_AAP=true
# Optional Red Hat OpenShift GitOps and Pipelines operator scenario.
# It installs only operator subscriptions. Customer repositories, credentials,
# Argo CD Applications, PipelineRuns, and workloads remain opt-in.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-deploy}"
GITOPS_NAMESPACE="${OPENSHIFT_DELIVERY_GITOPS_NAMESPACE:-openshift-gitops-operator}"
PIPELINES_NAMESPACE="${OPENSHIFT_DELIVERY_PIPELINES_NAMESPACE:-openshift-operators}"
CATALOG_NAMESPACE="${OPENSHIFT_DELIVERY_CATALOG_NAMESPACE:-openshift-marketplace}"
CATALOG_SOURCE="${OPENSHIFT_DELIVERY_CATALOG_SOURCE:-redhat-operators}"
GITOPS_PACKAGE="openshift-gitops-operator"
PIPELINES_PACKAGE="openshift-pipelines-operator-rh"
WAIT_SECONDS="${OPENSHIFT_DELIVERY_WAIT_SECONDS:-900}"

valid_dns_label() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

valid_channel() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]
}

validate_settings() {
  local value
  [[ "$WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: OPENSHIFT_DELIVERY_WAIT_SECONDS must be a positive integer" >&2
    return 1
  }
  for value in "$GITOPS_NAMESPACE" "$PIPELINES_NAMESPACE" "$CATALOG_NAMESPACE" "$CATALOG_SOURCE"; do
    valid_dns_label "$value" || {
      echo "ERROR: delivery namespace and CatalogSource names must be DNS-safe identifiers" >&2
      return 1
    }
  done
}

subscription_owner_is_safe() {
  local name="$1" namespace="$2" existing
  existing=$(kubectl get subscription "$name" -n "$namespace" \
    -o json 2>/dev/null | jq -r '.metadata.labels["aap-demo/openshift-delivery"] // ""' 2>/dev/null || true)
  [ -z "$existing" ] || [ "$existing" = managed ]
}

package_is_available() {
  local package="$1" manifest channel catalog
  manifest=$(kubectl get packagemanifest "$package" -n "$CATALOG_NAMESPACE" -o json 2>/dev/null) || return 1
  catalog=$(jq -r '.metadata.labels.catalog // ""' <<<"$manifest") || return 1
  [ "$catalog" = "$CATALOG_SOURCE" ] || return 1
  channel=$(jq -r '.status.defaultChannel // ""' <<<"$manifest") || return 1
  [ -n "$channel" ] || return 1
  printf '%s\n' "$channel"
}

wait_for_subscription() {
  local name="$1" namespace="$2" elapsed=0 csv phase
  while [ "$elapsed" -lt "$WAIT_SECONDS" ]; do
    csv=$(kubectl get subscription "$name" -n "$namespace" \
      -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [ -n "$csv" ]; then
      phase=$(kubectl get csv "$csv" -n "$namespace" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)
      case "$phase" in
        Succeeded)
          echo "  ✓ ${name} is ready (${csv})"
          return 0
          ;;
        Failed)
          echo "ERROR: ${name} install CSV failed: ${csv}" >&2
          kubectl describe csv "$csv" -n "$namespace" >&2 || true
          return 1
          ;;
      esac
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "ERROR: Timed out after ${WAIT_SECONDS}s waiting for ${name}" >&2
  echo "  Check: kubectl get subscription,csv -n ${namespace}" >&2
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
  kubectl get namespace "$PIPELINES_NAMESPACE" >/dev/null 2>&1 || {
    echo "ERROR: Shared operator namespace ${PIPELINES_NAMESPACE} is unavailable" >&2
    return 1
  }
  subscription_owner_is_safe aap-demo-openshift-gitops "$GITOPS_NAMESPACE" || {
    echo "ERROR: Refusing to change an unowned GitOps Subscription" >&2
    return 1
  }
  subscription_owner_is_safe aap-demo-openshift-pipelines "$PIPELINES_NAMESPACE" || {
    echo "ERROR: Refusing to change an unowned Pipelines Subscription" >&2
    return 1
  }
}

deploy() {
  local gitops_channel pipelines_channel rendered
  preflight || return 1
  gitops_channel=$(package_is_available "$GITOPS_PACKAGE") || {
    echo "ERROR: Package ${GITOPS_PACKAGE} is not available from ${CATALOG_SOURCE}" >&2
    return 1
  }
  pipelines_channel=$(package_is_available "$PIPELINES_PACKAGE") || {
    echo "ERROR: Package ${PIPELINES_PACKAGE} is not available from ${CATALOG_SOURCE}" >&2
    return 1
  }
  for channel in "$gitops_channel" "$pipelines_channel"; do
    valid_channel "$channel" || {
      echo "ERROR: Catalog returned an unsafe operator channel name" >&2
      return 1
    }
  done
  rendered=$(sed \
    -e "s|__GITOPS_NAMESPACE__|${GITOPS_NAMESPACE}|g" \
    -e "s|__PIPELINES_NAMESPACE__|${PIPELINES_NAMESPACE}|g" \
    -e "s|__GITOPS_CHANNEL__|${gitops_channel}|g" \
    -e "s|__PIPELINES_CHANNEL__|${pipelines_channel}|g" \
    -e "s|__CATALOG_SOURCE__|${CATALOG_SOURCE}|g" \
    -e "s|__CATALOG_NAMESPACE__|${CATALOG_NAMESPACE}|g" \
    "$SCRIPT_DIR/delivery-operators.yaml") || return 1
  printf '%s\n' "$rendered" | kubectl apply -f - >/dev/null
  echo "Waiting for OpenShift GitOps and Pipelines operators..."
  wait_for_subscription aap-demo-openshift-gitops "$GITOPS_NAMESPACE"
  wait_for_subscription aap-demo-openshift-pipelines "$PIPELINES_NAMESPACE"
  echo "✓ OpenShift delivery operators are ready"
  echo "  No repository, Argo CD Application, PipelineRun, credential, or workload was created."
}

remove() {
  local owner
  command -v jq >/dev/null 2>&1 || {
    echo "ERROR: jq is required for safe ownership checks" >&2
    return 1
  }
  if kubectl get subscription aap-demo-openshift-pipelines -n "$PIPELINES_NAMESPACE" >/dev/null 2>&1; then
    subscription_owner_is_safe aap-demo-openshift-pipelines "$PIPELINES_NAMESPACE" || {
      echo "ERROR: Refusing to delete an unowned Pipelines Subscription" >&2
      return 1
    }
    kubectl delete subscription aap-demo-openshift-pipelines -n "$PIPELINES_NAMESPACE" --ignore-not-found >/dev/null
  fi
  if kubectl get namespace "$GITOPS_NAMESPACE" >/dev/null 2>&1; then
    owner=$(kubectl get namespace "$GITOPS_NAMESPACE" \
      -o json 2>/dev/null | jq -r '.metadata.labels["aap-demo/openshift-delivery"] // ""' 2>/dev/null || true)
    [ "$owner" = managed ] || {
      echo "ERROR: Refusing to delete unowned namespace ${GITOPS_NAMESPACE}" >&2
      return 1
    }
    kubectl delete namespace "$GITOPS_NAMESPACE" --ignore-not-found >/dev/null
  fi
  echo "✓ Removed aap-demo-owned delivery operator subscriptions"
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
