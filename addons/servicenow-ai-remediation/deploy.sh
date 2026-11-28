#!/usr/bin/env bash
# Guarded ServiceNow + AI remediation demo preparation.  This addon never
# contacts ServiceNow, starts an EDA activation, launches an AO workflow, or
# changes a Fleet host.  It validates the local prerequisites and exposes the
# versioned Gitea-ready demo assets for an operator to review and import.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"

case "$ACTION" in
  --delete | delete)
    printf '%s\n' 'ServiceNow demo assets and any external incidents remain untouched.'
    printf '%s\n' 'Disable removes only the aap-demo addon selection; remove EDA/AO/Gitea records deliberately.'
    exit 0
    ;;
  deploy | --prepare) ;;
  *)
    printf 'ERROR: Usage: deploy.sh [--prepare|--delete]\n' >&2
    exit 2
    ;;
esac

if [ "${SERVICENOW_AI_DEMO_PREPARE:-false}" != true ]; then
  printf '%s\n' 'ERROR: This scenario is guarded because it can be connected to a real ServiceNow instance.' >&2
  printf '%s\n' 'Review addons/servicenow-ai-remediation/README.md, then run:' >&2
  printf '%s\n' '  SERVICENOW_AI_DEMO_PREPARE=true aap-demo enable servicenow-ai-remediation' >&2
  exit 2
fi

command -v kubectl >/dev/null 2>&1 || {
  printf '%s\n' 'ERROR: kubectl is required to check the local AAP and EDA prerequisites.' >&2
  exit 1
}

aap_name=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$aap_name" ] || {
  printf 'ERROR: No AnsibleAutomationPlatform CR exists in namespace %s\n' "$NAMESPACE" >&2
  exit 1
}
eda_disabled=$(kubectl get aap "$aap_name" -n "$NAMESPACE" \
  -o jsonpath='{.spec.eda.disabled}' 2>/dev/null || true)
[ "$eda_disabled" != true ] || {
  printf '%s\n' 'ERROR: Event-Driven Ansible is disabled. Run: aap-demo enable eda' >&2
  exit 1
}

for path in \
  "$SCRIPT_DIR/extensions/eda/rulebooks/httpd_outage.yml" \
  "$SCRIPT_DIR/playbooks/create_servicenow_incident.yml" \
  "$SCRIPT_DIR/playbooks/collect_httpd_evidence.yml" \
  "$SCRIPT_DIR/playbooks/remediate_httpd.yml" \
  "$SCRIPT_DIR/playbooks/update_servicenow_incident.yml"; do
  [ -f "$path" ] || {
    printf 'ERROR: Required demo asset is missing: %s\n' "$path" >&2
    exit 1
  }
done

printf '%s\n' '✓ ServiceNow AI remediation demo assets are prepared for review'
printf '%s\n' "  Assets: ${SCRIPT_DIR}"
printf '%s\n' '  Next: import this directory into an owned private Gitea repository, create the documented AAP templates and EDA activation, then configure the AO approval workflow.'
printf '%s\n' '  No ServiceNow request, AI invocation, Gitea push, EDA activation, workflow run, or host change was performed.'
