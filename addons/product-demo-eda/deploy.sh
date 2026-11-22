#!/usr/bin/env bash
# Product Demo - guarded Event-Driven Ansible integration.
#
# The upstream Infrastructure scenario requires external Kafka and cloud/host
# credentials. This addon imports its template only after an explicit opt-in;
# it never creates those services or starts a rulebook activation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"

if [ "$ACTION" = --delete ] || [ "$ACTION" = delete ]; then
  echo "EDA demo templates and any activation remain in AAP until removed deliberately."
  echo "✓ product-demo-eda addon disabled"
  exit 0
fi

if [ "${PRODUCT_DEMOS_ENABLE_EDA:-false}" != true ]; then
  echo "ERROR: EDA demo import is guarded because it needs external event-source configuration." >&2
  echo "  Review its prerequisites, then run:" >&2
  echo "  PRODUCT_DEMOS_ENABLE_EDA=true aap-demo enable product-demo-eda" >&2
  exit 2
fi

aap_name=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$aap_name" ]; then
  echo "ERROR: No AnsibleAutomationPlatform CR exists in namespace $NAMESPACE" >&2
  exit 1
fi
eda_disabled=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.spec.eda.disabled}' 2>/dev/null || true)
if [ "$eda_disabled" = true ]; then
  echo "ERROR: Event-Driven Ansible is not enabled. Run: aap-demo enable eda" >&2
  exit 1
fi

bash "${SCRIPT_DIR}/../product-demo-infrastructure/deploy.sh"
echo "✓ Guarded EDA integration is ready for manual configuration"
echo "  No Kafka broker, cloud resource, external credential, event source, or rulebook activation was created."
