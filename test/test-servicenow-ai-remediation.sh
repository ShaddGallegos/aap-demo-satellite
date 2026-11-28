#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDON="$REPO_ROOT/addons/servicenow-ai-remediation"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

python3 "$REPO_ROOT/scripts/validate-addon-contract.py" "$ADDON/scenario.json" >/dev/null

if "$ADDON/deploy.sh" >"$TMP/guard" 2>&1; then
  echo 'FAIL: ServiceNow demo accepted a missing explicit prepare opt-in' >&2
  exit 1
fi
grep -Fq 'SERVICENOW_AI_DEMO_PREPARE=true' "$TMP/guard"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = aap ] && [ "${3:-}" = aap ]; then
  printf '%s' false
elif [ "${1:-}" = get ] && [ "${2:-}" = aap ] && [ "${3:-}" = -n ]; then
  printf '%s' aap
else
  echo "unexpected kubectl: $*" >&2
  exit 2
fi
EOF
chmod +x "$TMP/bin/kubectl"
PATH="$TMP/bin:$PATH" SERVICENOW_AI_DEMO_PREPARE=true "$ADDON/deploy.sh" >"$TMP/prepared"
grep -Fq 'No ServiceNow request, AI invocation, Gitea push, EDA activation, workflow run, or host change was performed.' "$TMP/prepared"

for playbook in "$ADDON"/playbooks/*.yml; do
  if grep -Eq 'validate_certs:[[:space:]]*false|GIT_SSL_NO_VERIFY' "$playbook"; then
    echo "FAIL: insecure TLS setting in $playbook" >&2
    exit 1
  fi
done
grep -Fq 'remediation_approved | bool' "$ADDON/playbooks/remediate_httpd.yml"
grep -Fq "service_name in ['httpd', 'nginx']" "$ADDON/playbooks/remediate_httpd.yml"
grep -Fq "aap_demo.servicenow.instance_url" "$ADDON/deploy.sh"
grep -Fq "aap_demo.servicenow.username" "$ADDON/deploy.sh"
grep -Fq "aap_demo.servicenow.password" "$ADDON/deploy.sh"
grep -Fq -- '--configure --reconfigure' "$ADDON/deploy.sh"
grep -Fq 'ansible.eda' "$ADDON/execution-environment/requirements.yml"
grep -Fq 'servicenow.itsm' "$ADDON/execution-environment/requirements.yml"
grep -Fq 'AI ServiceNow | Analyze HTTP outage' "$ADDON/extensions/eda/rulebooks/httpd_outage.yml"
grep -Fq 'servicenow-ai-remediation' "$REPO_ROOT/config/addons-dashboard.json"

echo 'PASS: ServiceNow AI remediation scenario is opt-in, TLS-safe, approval-gated, and packaged with EDA/EE requirements'
