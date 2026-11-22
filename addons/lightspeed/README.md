# Ansible Lightspeed Addon

Deploys the Ansible Lightspeed intelligent assistant into the AAP namespace,
backed by the local [Ollama](https://ollama.com/) LLM (`qwen2.5:3b`) instead of
a cloud model. The `ansible-lightspeed` operator (installed with AAP)
reconciles AAP's managed `AnsibleLightspeed` resource into the Lightspeed API and
chatbot, wired to Ollama's in-cluster OpenAI-compatible endpoint. The addon updates
the parent AAP resource so that gateway registration and authentication remain
operator-managed.

## Usage

```bash
aap-demo enable ollama       # Prerequisite: provides the model endpoint
aap-demo enable lightspeed   # Deploy Lightspeed wired to Ollama
aap-demo disable lightspeed  # Remove Lightspeed
```

The addon automatically:

1. Creates a chatbot-configuration Secret pointing at the in-cluster Ollama
   `/v1` endpoint, with provider `openai` and model `qwen2.5:3b`.
2. Enables the assistant in the parent AAP resource with one API and one chatbot
   replica, without replacing existing code-generation provider settings.
3. Configures internal gateway and controller URLs so the operator deploys the
   native MCP sidecars (Technology Preview).
4. Waits for both API and chatbot rollouts. A healthy API alone is not success.

The chat assistant and code-generation service use different configuration
contracts. Ollama's OpenAI-compatible endpoint is not a `wca-onprem` endpoint.
This addon configures chat, not a Watson Code Assistant replacement.

Access the assistant from the AAP console → Lightspeed intelligent assistant.

## Prerequisites

- `aap-demo enable ollama` (provides the model endpoint)
- The `ansible-lightspeed` operator, installed with AAP 2.7+

## Configuration

Override via environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `LIGHTSPEED_MODEL_URL` | in-cluster Ollama `/v1` | Model endpoint |
| `LIGHTSPEED_MODEL_ID` | `qwen2.5:3b` | Model name |
| `LIGHTSPEED_MODEL_API_KEY` | `ollama` | Non-empty placeholder for local Ollama |
| `LIGHTSPEED_CHATBOT_SECRET` | `aap-lightspeed-chatbot-config` | Chatbot Secret |
| `LIGHTSPEED_API_CPU_REQUEST` / `LIGHTSPEED_API_MEMORY_REQUEST` | `200m` / `2Gi` | Local-demo API requests |
| `LIGHTSPEED_CHATBOT_CPU_REQUEST` / `LIGHTSPEED_CHATBOT_MEMORY_REQUEST` | `500m` / `5Gi` | Local-demo chatbot requests |
| `LIGHTSPEED_API_CPU_LIMIT` / `LIGHTSPEED_API_MEMORY_LIMIT` | `1000m` / `4Gi` | API limits |
| `LIGHTSPEED_CHATBOT_CPU_LIMIT` / `LIGHTSPEED_CHATBOT_MEMORY_LIMIT` | `1500m` / `8Gi` | Chatbot limits |
| `AAP_CR_NAME` | `aap` | Parent AAP resource name |
| `LIGHTSPEED_CR_NAME` | `<AAP_CR_NAME>-lightspeed` | Must match the managed child |
| `LIGHTSPEED_NAMESPACE` | `aap-operator` | Target namespace |
| `LIGHTSPEED_ROLLOUT_TIMEOUT` | `600s` | Timeout for each deployment rollout |

## Ownership and removal

Database and authentication configuration belong to the AAP operator. The addon
does not launch root-owned repair pods, change PVC ownership, or restart databases.
Disabling sets `spec.lightspeed.disabled: true` on AAP and removes the addon chatbot
Secret. It does not erase existing code-generation Secrets or retained PVCs.

## Status

```bash
kubectl get ansiblelightspeed -n aap-operator
kubectl get pods -n aap-operator -l app.kubernetes.io/part-of=aap-lightspeed
```

## Troubleshooting

### Lightspeed API not answering

Confirm the API pod is ready and the route is admitted:

```bash
kubectl get pods -n aap-operator | grep aap-lightspeed
kubectl get route -n aap-operator aap-lightspeed
```

### Model errors / no response from the assistant

Confirm the Lightspeed API can reach Ollama in-cluster:

```bash
kubectl exec -n aap-operator deploy/aap-lightspeed-api -- \
  curl -s http://ollama.aap-demo-ollama.svc.cluster.local:11434/api/tags
```

The output should list `qwen2.5:3b`. If not, verify the Ollama addon is healthy
(`aap-demo enable ollama` is idempotent), then re-enable Lightspeed. Check the
chatbot deployment and native MCP containers separately; pod readiness does not
prove that a chat request or tool call succeeds.

See the [AI integration guide](../../docs/guides/ai-integrations.md) for product
boundaries and end-to-end validation.
