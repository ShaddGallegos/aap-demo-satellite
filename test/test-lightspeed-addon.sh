#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
export HOME="$tmp/home" KUBECONFIG="$tmp/no-cluster" MOCK_DIR="$tmp"
REAL_JQ="$(command -v jq)"
export REAL_JQ
export PATH="$tmp/bin:/usr/bin:/bin"
export LIGHTSPEED_MODEL_API_KEY='placeholder"with\escaping'

cat >"$tmp/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_DIR/commands"
case "$*" in
  "get ansibleautomationplatform "*)
    [ "${MOCK_CASE:-}" != missing-aap ] ;;
  "get crd "* | "get svc "* | "get deploy "*) exit 0 ;;
  "wait --for=create ansiblelightspeed/"*) exit 0 ;;
  "wait --for=create deploy/aap-lightspeed-chatbot-api "*)
    [ "${MOCK_CASE:-}" != missing-chatbot-deployment ] ;;
  "wait --for=create "*)
    [ "${MOCK_CASE:-}" != missing-deployment ] ;;
  "get pod "*) exit 1 ;;
  "apply -f -")
    cat >"$MOCK_DIR/secret.json"
    [ "${MOCK_CASE:-}" != failed-secret ] ;;
  "patch ansibleautomationplatform "*)
    while [ "$1" != -p ]; do shift; done
    printf '%s' "$2" >"$MOCK_DIR/patch.json" ;;
  "patch ansiblelightspeed "*)
    while [ "$1" != -p ]; do shift; done
    printf '%s' "$2" >"$MOCK_DIR/child-patch.json" ;;
  "patch deployment aap-lightspeed-api "*)
    while [ "$1" != -p ]; do shift; done
    printf '%s' "$2" >"$MOCK_DIR/api-deployment-patch.json" ;;
  "patch deployment aap-lightspeed-chatbot-api "*)
    while [ "$1" != -p ]; do shift; done
    printf '%s' "$2" >"$MOCK_DIR/chatbot-deployment-patch.json" ;;
  "rollout status deploy/aap-lightspeed-chatbot-api "*)
    [ "${MOCK_CASE:-}" != failed-chatbot ] ;;
  "rollout status deploy/aap-lightspeed-api "*)
    [ "${MOCK_CASE:-}" != failed-api ] ;;
  "rollout status "*) exit 0 ;;
  "delete secret "*) exit 0 ;;
  *) printf 'Unexpected kubectl: %s\n' "$*" >&2; exit 91 ;;
esac
MOCK
cat >"$tmp/bin/jq" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "${TRACE_CREDENTIAL_ARGS:-}" = 1 ]; then
  printf 'jq %s\n' "$*" >>"$MOCK_DIR/commands"
fi
exec "$REAL_JQ" "$@"
MOCK
chmod +x "$tmp/bin/kubectl" "$tmp/bin/jq"

LIGHTSPEED_ROLLOUT_TIMEOUT=47s TRACE_CREDENTIAL_ARGS=1 \
  bash "$root/addons/lightspeed/deploy.sh" >"$tmp/output" 2>&1
jq -e --arg key "$LIGHTSPEED_MODEL_API_KEY" '
  .kind == "Secret" and .stringData.chatbot_token == $key and
  .stringData.chatbot_llm_provider_type == "openai" and
  .stringData.aap_gateway_url == "http://aap" and
  .stringData.aap_controller_url == "http://aap-controller-service" and
  (.stringData | has("model_type") | not)
' "$tmp/secret.json" >/dev/null
jq -e '.spec.lightspeed.disabled == false and
  .spec.lightspeed.chatbot_config_secret_name == "aap-lightspeed-chatbot-config" and
  (.spec.lightspeed | has("auth_config_secret_name") | not)
' "$tmp/patch.json" >/dev/null
jq -e '.spec.api.resource_requirements.requests == {"cpu":"200m","memory":"2Gi"} and
  .spec.api.resource_requirements.limits == {"cpu":"1000m","memory":"4Gi"} and
  .spec.api.strategy.type == "Recreate" and
  .spec.chatbot_api.resource_requirements.requests == {"cpu":"500m","memory":"5Gi"} and
  .spec.chatbot_api.resource_requirements.limits == {"cpu":"1500m","memory":"8Gi"} and
  .spec.chatbot_api.strategy.type == "Recreate"
' "$tmp/child-patch.json" >/dev/null
grep -Fxq "wait --for=create ansiblelightspeed/aap-lightspeed -n aap-operator --timeout=47s" "$tmp/commands"
jq -e '.spec.strategy.type == "Recreate" and .spec.template.spec.containers[0] == {
  "name":"model-api", "resources": {
    "requests":{"cpu":"200m","memory":"2Gi"}, "limits":{"cpu":"1000m","memory":"4Gi"}
  }} and .spec.template.spec.initContainers[0].name == "configure-combined-ca-bundle"
' "$tmp/api-deployment-patch.json" >/dev/null
jq -e '.spec.strategy.type == "Recreate" and .spec.template.spec.containers[0] == {
  "name":"ansible-chatbot", "resources": {
    "requests":{"cpu":"500m","memory":"5Gi"}, "limits":{"cpu":"1500m","memory":"8Gi"}
  }}
' "$tmp/chatbot-deployment-patch.json" >/dev/null
for deployment in api chatbot-api; do
  grep -Fxq "wait --for=create deploy/aap-lightspeed-${deployment} -n aap-operator --timeout=47s" "$tmp/commands"
  grep -Fxq "rollout status deploy/aap-lightspeed-${deployment} -n aap-operator --timeout=47s" "$tmp/commands"
done
if grep -Fq "$LIGHTSPEED_MODEL_API_KEY" "$tmp/commands" "$tmp/output"; then
  echo "FAIL: model key exposed in arguments or output" >&2
  exit 1
fi
if grep -Eq '^(apply.*Pod|delete pod|.*chown|.*chmod|.*persistentvolume)' "$tmp/commands"; then
  echo "FAIL: assistant setup attempted to repair database storage" >&2
  exit 1
fi

if MOCK_CASE=failed-chatbot bash "$root/addons/lightspeed/deploy.sh" >"$tmp/output" 2>&1; then
  echo "FAIL: chatbot rollout failure reported success" >&2
  exit 1
fi
grep -q 'assistant is not ready' "$tmp/output"

: >"$tmp/commands"
if MOCK_CASE=failed-secret bash "$root/addons/lightspeed/deploy.sh" >"$tmp/output" 2>&1; then
  echo "FAIL: Secret apply failure reported success" >&2
  exit 1
fi
if grep -q '^patch ' "$tmp/commands"; then
  echo "FAIL: failed Secret apply still changed AAP configuration" >&2
  exit 1
fi

if MOCK_CASE=failed-api bash "$root/addons/lightspeed/deploy.sh" >"$tmp/output" 2>&1; then
  echo "FAIL: API rollout failure reported success" >&2
  exit 1
fi
grep -q 'API deployment .* failed to roll out' "$tmp/output"

: >"$tmp/commands"
if MOCK_CASE=missing-deployment bash "$root/addons/lightspeed/deploy.sh" >"$tmp/output" 2>&1; then
  echo "FAIL: missing deployment reported success" >&2
  exit 1
fi
grep -q 'never appeared' "$tmp/output"
! grep -q '^rollout status ' "$tmp/commands"

: >"$tmp/commands"
if MOCK_CASE=missing-chatbot-deployment bash "$root/addons/lightspeed/deploy.sh" >"$tmp/output" 2>&1; then
  echo "FAIL: missing chatbot deployment reported success" >&2
  exit 1
fi
grep -q 'chatbot-api never appeared' "$tmp/output"
! grep -q '^rollout status deploy/aap-lightspeed-chatbot-api ' "$tmp/commands"

: >"$tmp/commands"
if MOCK_CASE=missing-aap bash "$root/addons/lightspeed/deploy.sh" >"$tmp/output" 2>&1; then
  echo "FAIL: missing AAP reported success" >&2
  exit 1
fi
if grep -Eq '^apply |^patch ' "$tmp/commands"; then
  echo "FAIL: missing-AAP preflight changed cluster resources" >&2
  exit 1
fi

: >"$tmp/commands"
if LIGHTSPEED_CR_NAME=unrelated-lightspeed bash "$root/addons/lightspeed/deploy.sh" >"$tmp/output" 2>&1; then
  echo "FAIL: unrelated Lightspeed resource name was accepted" >&2
  exit 1
fi
if [ -s "$tmp/commands" ]; then
  echo "FAIL: mismatched ownership reached the cluster" >&2
  exit 1
fi

: >"$tmp/commands"
bash "$root/addons/lightspeed/deploy.sh" --delete >"$tmp/output" 2>&1
jq -e '.spec.lightspeed.disabled == true' "$tmp/patch.json" >/dev/null
if grep -q '^delete ansiblelightspeed ' "$tmp/commands"; then
  echo "FAIL: delete bypassed the owning platform operator" >&2
  exit 1
fi
echo "PASS: managed Lightspeed chatbot configuration, readiness, and removal"
