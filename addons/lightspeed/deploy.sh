#!/usr/bin/env bash
# Deploy Ansible Lightspeed (intelligent assistant) for aap-demo, backed by the
# local Ollama LLM (qwen2.5:3b) instead of a cloud model.
#
# Configures the AAP-managed intelligent assistant and its native MCP sidecars.
# Code-generation providers are separate from the chatbot's OpenAI-compatible LLM.
#
# Prerequisites:
#   - aap-demo enable ollama   (provides the model endpoint)
#   - AAP operator installed   (ansible-lightspeed operator runs in aap-operator)
#
# Usage:
#   ./deploy.sh           # Deploy Lightspeed wired to Ollama
#   ./deploy.sh --delete  # Remove Lightspeed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="${LIGHTSPEED_NAMESPACE:-aap-operator}"
AAP_NAME="${AAP_CR_NAME:-aap}"
CR_NAME="${LIGHTSPEED_CR_NAME:-${AAP_NAME}-lightspeed}"
CHATBOT_SECRET="${LIGHTSPEED_CHATBOT_SECRET:-${CR_NAME}-chatbot-config}"
# In-cluster Ollama OpenAI-compatible endpoint (no TLS, no auth on the svc).
MODEL_URL="${LIGHTSPEED_MODEL_URL:-http://ollama.aap-demo-ollama.svc.cluster.local:11434/v1}"
MODEL_ID="${LIGHTSPEED_MODEL_ID:-qwen2.5:3b}"
# Ollama ignores the key but the operator requires a non-empty value.
MODEL_API_KEY="${LIGHTSPEED_MODEL_API_KEY:-ollama}"
ROLLOUT_TIMEOUT="${LIGHTSPEED_ROLLOUT_TIMEOUT:-600s}"
# The operator defaults allocate 500m CPU / 5Gi memory to both services. The
# local model API only needs 200m / 2Gi, while the chatbot's RAG stack retains
# its proven 500m / 5Gi request. This matters on a one-node AAP/Ollama demo.
API_CPU_REQUEST="${LIGHTSPEED_API_CPU_REQUEST:-200m}"
API_MEMORY_REQUEST="${LIGHTSPEED_API_MEMORY_REQUEST:-2Gi}"
API_CPU_LIMIT="${LIGHTSPEED_API_CPU_LIMIT:-1000m}"
API_MEMORY_LIMIT="${LIGHTSPEED_API_MEMORY_LIMIT:-4Gi}"
CHATBOT_CPU_REQUEST="${LIGHTSPEED_CHATBOT_CPU_REQUEST:-500m}"
CHATBOT_MEMORY_REQUEST="${LIGHTSPEED_CHATBOT_MEMORY_REQUEST:-5Gi}"
CHATBOT_CPU_LIMIT="${LIGHTSPEED_CHATBOT_CPU_LIMIT:-1500m}"
CHATBOT_MEMORY_LIMIT="${LIGHTSPEED_CHATBOT_MEMORY_LIMIT:-8Gi}"

_err() { printf 'ERROR: %s\n' "$*" >&2; }
_log() { printf '  %s\n' "$*"; }

ACTION="${1:-deploy}"

if [ "$CR_NAME" != "${AAP_NAME}-lightspeed" ]; then
  _err "LIGHTSPEED_CR_NAME must match the AAP-managed name ${AAP_NAME}-lightspeed."
  exit 1
fi

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing Ansible Lightspeed..."
  kubectl patch ansibleautomationplatform "$AAP_NAME" -n "$NAMESPACE" --type=merge \
    -p '{"spec":{"lightspeed":{"disabled":true}}}'
  kubectl delete secret "$CHATBOT_SECRET" -n "$NAMESPACE" --ignore-not-found
  echo "✓ Ansible Lightspeed removed"
  exit 0
fi

# --- preflight ---------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || {
  _err "kubectl not found"
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  _err "jq not found"
  exit 1
}

if ! kubectl get crd ansiblelightspeeds.lightspeed.ansible.com >/dev/null 2>&1; then
  _err "AnsibleLightspeed CRD not found — is the ansible-lightspeed operator installed?"
  exit 1
fi

if ! kubectl get ansibleautomationplatform "$AAP_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  _err "AAP instance ${AAP_NAME} not found in ${NAMESPACE}."
  exit 1
fi

if [[ "$MODEL_URL" == http://ollama.aap-demo-ollama.svc.cluster.local:11434/* ]] \
  && ! kubectl get svc ollama -n aap-demo-ollama >/dev/null 2>&1; then
  _err "Ollama service not found. Run: aap-demo enable ollama"
  exit 1
fi

# --- intelligent assistant configuration -------------------------------------
_log "▸ Creating chatbot configuration secret ($CHATBOT_SECRET)"
jq -n --arg name "$CHATBOT_SECRET" --arg ns "$NAMESPACE" \
  --arg url "$MODEL_URL" --arg model "$MODEL_ID" --arg aap "$AAP_NAME" \
  --rawfile key /dev/fd/3 '{
    apiVersion: "v1", kind: "Secret",
    metadata: {name: $name, namespace: $ns,
      labels: {"app.kubernetes.io/managed-by": "aap-demo"}},
    type: "Opaque",
    stringData: {
      chatbot_llm_provider_type: "openai", chatbot_url: $url,
      chatbot_model: $model, chatbot_token: $key,
      aap_gateway_url: ("http://" + $aap),
      aap_controller_url: ("http://" + $aap + "-controller-service")
    }
  }' 3< <(printf '%s' "$MODEL_API_KEY") | kubectl apply -f -

# The platform operator owns authentication, gateway registration and the child
# CR. Patching that child alone either loses these settings or is reconciled away.
_log "▸ Enabling the AAP-managed intelligent assistant ($CR_NAME)"
patch=$(jq -n --arg secret "$CHATBOT_SECRET" '{
  spec: {lightspeed: {
    disabled: false, chatbot_config_secret_name: $secret,
    api: {replicas: 1}, chatbot_api: {replicas: 1}
  }}
}')
kubectl patch ansibleautomationplatform "$AAP_NAME" -n "$NAMESPACE" --type=merge -p "$patch"

# AAP owns creation of this child, but the resource requirements belong to the
# AnsibleLightspeed API. The parent AAP CR only forwards replicas/config-secret
# fields, so setting resource_requirements there is silently ignored.
_log "▸ Applying local-demo resource profile to $CR_NAME"
if ! kubectl wait --for=create "ansiblelightspeed/${CR_NAME}" -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"; then
  _err "Lightspeed resource ${CR_NAME} never appeared in namespace ${NAMESPACE}"
  exit 1
fi
child_patch=$(jq -n \
  --arg api_cpu_request "$API_CPU_REQUEST" \
  --arg api_memory_request "$API_MEMORY_REQUEST" \
  --arg api_cpu_limit "$API_CPU_LIMIT" \
  --arg api_memory_limit "$API_MEMORY_LIMIT" \
  --arg chatbot_cpu_request "$CHATBOT_CPU_REQUEST" \
  --arg chatbot_memory_request "$CHATBOT_MEMORY_REQUEST" \
  --arg chatbot_cpu_limit "$CHATBOT_CPU_LIMIT" \
  --arg chatbot_memory_limit "$CHATBOT_MEMORY_LIMIT" '{
  spec: {
    api: {resource_requirements: {
      requests: {cpu: $api_cpu_request, memory: $api_memory_request},
      limits: {cpu: $api_cpu_limit, memory: $api_memory_limit}
    }, strategy: {type: "Recreate"}},
    chatbot_api: {resource_requirements: {
      requests: {cpu: $chatbot_cpu_request, memory: $chatbot_memory_request},
      limits: {cpu: $chatbot_cpu_limit, memory: $chatbot_memory_limit}
    }, strategy: {type: "Recreate"}}
  }
}')
kubectl patch ansiblelightspeed "$CR_NAME" -n "$NAMESPACE" --type=merge -p "$child_patch"

_log "▸ Waiting for Lightspeed API deployment..."
if ! kubectl wait --for=create "deploy/${CR_NAME}-api" -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"; then
  _err "Lightspeed API deployment ${CR_NAME}-api never appeared in namespace ${NAMESPACE}"
  exit 1
fi
# A child reconciliation already blocked on the operator defaults will not
# observe its new resource requirements until that Pending pod can run. Update
# the generated Deployments too: this unblocks the current reconciliation, and
# the child CR above makes the setting durable on its next pass.
api_deployment_patch=$(jq -n \
  --arg cpu_request "$API_CPU_REQUEST" --arg memory_request "$API_MEMORY_REQUEST" \
  --arg cpu_limit "$API_CPU_LIMIT" --arg memory_limit "$API_MEMORY_LIMIT" '{
  spec: {template: {spec: {
    containers: [{name: "model-api", resources: {
      requests: {cpu: $cpu_request, memory: $memory_request},
      limits: {cpu: $cpu_limit, memory: $memory_limit}
    }}],
    initContainers: [{name: "configure-combined-ca-bundle", resources: {
      requests: {cpu: $cpu_request, memory: $memory_request},
      limits: {cpu: $cpu_limit, memory: $memory_limit}
    }}]
  }}, strategy: {type: "Recreate", rollingUpdate: null}}
}')
kubectl patch deployment "${CR_NAME}-api" -n "$NAMESPACE" --type=strategic -p "$api_deployment_patch"
if ! kubectl rollout status "deploy/${CR_NAME}-api" -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"; then
  _err "Lightspeed API deployment ${CR_NAME}-api failed to roll out"
  exit 1
fi

_log "▸ Waiting for Lightspeed chatbot deployment..."
if ! kubectl wait --for=create "deploy/${CR_NAME}-chatbot-api" -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"; then
  _err "Lightspeed chatbot deployment ${CR_NAME}-chatbot-api never appeared."
  exit 1
fi
chatbot_deployment_patch=$(jq -n \
  --arg cpu_request "$CHATBOT_CPU_REQUEST" --arg memory_request "$CHATBOT_MEMORY_REQUEST" \
  --arg cpu_limit "$CHATBOT_CPU_LIMIT" --arg memory_limit "$CHATBOT_MEMORY_LIMIT" '{
  spec: {template: {spec: {containers: [{name: "ansible-chatbot", resources: {
    requests: {cpu: $cpu_request, memory: $memory_request},
    limits: {cpu: $cpu_limit, memory: $memory_limit}
  }}]}}, strategy: {type: "Recreate", rollingUpdate: null}}
}')
kubectl patch deployment "${CR_NAME}-chatbot-api" -n "$NAMESPACE" --type=strategic -p "$chatbot_deployment_patch"
kubectl rollout status "deploy/${CR_NAME}-chatbot-api" -n "$NAMESPACE" \
  --timeout="$ROLLOUT_TIMEOUT" || {
  _err "Lightspeed chatbot failed to roll out; the assistant is not ready."
  exit 1
}

echo ""
echo "✓ Ansible Lightspeed deployed"
echo "  Model:    ${MODEL_ID} via ${MODEL_URL}"
echo "  MCP:      native AAP gateway and controller sidecars (Technology Preview)"
echo "  CR:       ${CR_NAME} (namespace ${NAMESPACE})"
echo "  Access:   AAP console → Lightspeed intelligent assistant"
