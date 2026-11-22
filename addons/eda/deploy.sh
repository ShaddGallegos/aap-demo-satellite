#!/usr/bin/env bash
# ADDON_REQUIRES_AAP=true
# Enable the AAP Event-Driven Ansible service.  This changes only the local
# AnsibleAutomationPlatform CR; it neither creates event sources nor launches
# rulebook activations.
set -euo pipefail

NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"

case "$ACTION" in
  deploy) ;;
  --delete|delete)
    echo "EDA remains enabled so existing rulebook activations are not interrupted."
    echo "Disable it deliberately by patching the AAP CR after removing its EDA resources."
    exit 0
    ;;
  *)
    echo "ERROR: Usage: deploy.sh [--delete]" >&2
    exit 2
    ;;
esac

aap_name=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$aap_name" ]; then
  echo "ERROR: No AnsibleAutomationPlatform CR exists in namespace $NAMESPACE" >&2
  exit 1
fi

eda_disabled=$(kubectl get aap "$aap_name" -n "$NAMESPACE" \
  -o jsonpath='{.spec.eda.disabled}' 2>/dev/null || true)
if [ "$eda_disabled" = false ]; then
  echo "✓ Event-Driven Ansible is already enabled in AAP ($aap_name)"
  exit 0
fi

echo "Enabling Event-Driven Ansible in AAP ($aap_name)..."
kubectl patch aap "$aap_name" -n "$NAMESPACE" --type merge \
  -p '{"spec":{"eda":{"disabled":false}}}' >/dev/null
echo "✓ EDA was enabled in the AAP custom resource"
echo "  The AAP operator now reconciles the EDA service. No rulebook activation or external event source was created."
