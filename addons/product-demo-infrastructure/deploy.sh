#!/usr/bin/env bash
# Product Demo - Infrastructure
#
# Imports the upstream APD Infrastructure setup template only. It never runs
# the template, so cloud resources and external systems remain user-controlled.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../product-demos-base/lib.sh
source "${SCRIPT_DIR}/../product-demos-base/lib.sh"
NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"
DEMO_CATEGORY="infrastructure"
PRODUCT_DEMOS_REPO="${PRODUCT_DEMOS_REPO:-https://github.com/ansible/product-demos}"
PRODUCT_DEMOS_REF="${PRODUCT_DEMOS_REF:-${PRODUCT_DEMOS_BRANCH:-90dea07d34d9bf5bf59acd7b6927ab576c0cddf4}}"
PRODUCT_DEMOS_BRANCH="$PRODUCT_DEMOS_REF"
PRODUCT_DEMOS_EE_NAME="${PRODUCT_DEMOS_EE_NAME:-Product Demos EE}"

if [ "$ACTION" = --delete ] || [ "$ACTION" = delete ]; then
  echo "Infrastructure demo templates remain in AAP until removed in the UI."
  echo "✓ product-demo-infrastructure addon disabled"
  exit 0
fi

if ! kubectl cluster-info >/dev/null 2>&1 || ! kubectl get aap -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: A running AAP deployment is required" >&2
  exit 1
fi

if ! apd_base_is_recorded; then
  echo "Installing product-demos-base dependency..."
  bash "${SCRIPT_DIR}/../product-demos-base/deploy.sh"
fi

command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq is required" >&2
  exit 1
}
apd_init_aap_connection
echo "Resolving Product Demos base resources..."
apd_wait_for_domain_install_ids "$PRODUCT_DEMOS_EE_NAME"
template_id=$(apd_ensure_domain_job_template "$DEMO_CATEGORY" "$APD_PROJECT_ID" "$APD_EE_ID" "$APD_CRED_ID")

echo "✓ Infrastructure demo template imported (ID: ${template_id}): $(apd_domain_template_name "$DEMO_CATEGORY")"
echo "  It was not launched. Configure its required cloud, Kafka, and host credentials before running it."
