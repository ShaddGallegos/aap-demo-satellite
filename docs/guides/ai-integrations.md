---
type: Guide
title: Local MCP and LLM integrations
description: Configure local AI assistants and distinguish native tools from indirect product access.
---

# Local MCP and LLM integrations

These features use the [older Bash command](older-command.md). They are for a
local demo, not an unattended production agent. Wait for any active create,
upgrade, or wiring operation to finish before changing integrations.

## What connects to what

| Product | Integration path | Boundary |
|---------|------------------|----------|
| Automation Orchestrator | AAP MCP tools and local Ollama | Existing AO integrations; verify the selected model and a real response. |
| Private Automation Hub | Collection metadata and execution-environment repository tools in AAP MCP | Hub is a content service, not an LLM host. AAP permissions still apply. |
| Satellite | AAP inventories, synchronized Satellite hosts, and Satellite job templates exposed through AAP/AO | Indirect access; does not provide every Satellite API. |
| Ansible Lightspeed | Local OpenAI-compatible Ollama endpoint and native gateway/controller MCP sidecars | MCP-enabled assistant is Technology Preview; code-generation configuration is separate. |
| Self-Service Portal | RHDH Developer Lightspeed sidecar with Ollama; execution-environment builder MCP support | Separate from Ansible Lightspeed; chat tool execution needs separate verification. |

Satellite also has a native MCP server, introduced as Technology Preview in
Satellite 6.18. It requires its own compatible container, Satellite trust, and
per-client Foreman credentials. The installed AO MCP configuration does not expose
the two Foreman authentication headers. This workflow does not add a credential
translation proxy or claim native Satellite MCP is connected. Keep using the
existing AAP-mediated path unless deploying a separately supported client.

## Configure

Use the existing local model rather than sending environment data to an external
LLM:

```bash
aap-demo enable ollama
aap-demo enable mcp-server
aap-demo enable ao
aap-demo wire
aap-demo enable lightspeed
PORTAL_LIGHTSPEED=true aap-demo enable portal
```

Each command changes the local environment. Enabling the Portal can also create
AAP OAuth applications and tokens. It requires additional CPU, memory, and disk.
Check available capacity first. Resource expansion needs available host headroom
and authorization. Do not change storage ownership to force deployment.

See [Lightspeed settings](../../addons/lightspeed/README.md) and
[Portal settings](../../addons/portal/README.md). Keep real credentials in the
existing encrypted credential store. The local Ollama placeholder is not a paid
provider key. Never put real access tokens in examples, committed Helm values,
command-line arguments, or shared diagnostic logs.

## Verify separately

1. Run `aap-demo check-integrations`. It inspects saved validation records and
   selected APIs; it does not execute tools or chat.
2. Initialize an authenticated MCP session and list its actual tools. Check the
   read-only Hub collection and repository tools against the installed schema.
3. Execute an explicitly read-only tool and verify its upstream result, not only
   HTTP success. Do not test by launching an automation job.
4. Generate a harmless response from the configured local model, then test each
   assistant through its own authenticated application endpoint or UI.
5. For Satellite, verify the actual inventory synchronization and Fleet
   registration. An inventory name or a historical job is not current evidence.
6. For Portal, check the Lightspeed sidecar, authenticated MCP discovery, available
   tools, and a real assistant response independently. An execution-environment
   builder picker does not prove a running MCP server.

Report PASS, FAIL, DISABLED, or NOT TESTED for each connection. Keep Technology
Preview and unsupported native paths visible. A ready deployment, discovered tool,
or standalone Ollama response does not establish an end-to-end agent workflow.

### Repeatable tests

The normal [unit runner](../../test/run-unit-tests.sh) includes the isolated
Lightspeed, Portal, and integration-check regressions. These mock cluster commands
and cover credential escaping, ownership, readiness failures, and explicit error
propagation. They must not restart CRC or contact a real cluster.

The [live AI checks](../../test/test-ai-integrations-live.sh) are excluded from that
runner and require explicit opt-in and a kubeconfig for your local demo:

```bash
AAP_DEMO_RUN_LIVE_AI_TESTS=1 \
  KUBECONFIG="$HOME/.aap-demo/kubeconfig.microshift" \
  bash test/test-ai-integrations-live.sh
```

They test rejected missing/invalid MCP credentials, authenticated initialization,
a real read-only Hub repository tool call, and generation from AO's selected local
Ollama model. The test creates its own read-only AAP token, revokes it on exit, and
verifies that the revoked token is rejected. It does not launch jobs, patch hosts,
enable addons, or validate the Lightspeed/Portal chat UIs.

To also test the enabled native Lightspeed assistant, add
`AAP_DEMO_RUN_LIVE_LIGHTSPEED_TESTS=1` to that command. This rejects missing and
invalid authentication, then submits one harmless query through the AAP gateway.
Native chat requires read/write scope, so this check uses the existing
administrator authentication rather than broadening the temporary MCP token.
It explicitly disables tools and verifies the response contains no tool calls or
results. It creates a conversation; it does not launch automation or validate
the chat UI, native MCP tool execution, or Portal.

## Qualification handoff - 2026-11-17

CRC was recovered and verified at 12 CPUs and 49152 MiB. MCP authentication,
read-only Hub repository execution, and AO's selected Ollama model passed live
checks after restart convergence. This does not qualify every assistant.
Native Lightspeed deployments are ready, but repeated authenticated gateway
conversations intermittently return HTTP 502/504 near 60 seconds. Its live test
correctly fails. Portal runtime chat and native assistant MCP execution remain
unverified; do not publish on the basis of readiness or one successful response.

Hosted Red Hat Lightspeed/Insights is a separate integration. Satellite now has
a valid RHSM identity and an imported manifest. Native cloud-connector job
2 succeeded after repairing proxy-to-self SSH authorization; `rhcd` is active
and enabled. Fleet reporting, hosted inventory acceptance, and recommendations
remain unfinished.
See the [Satellite handoff](../../satellite-lab/README.md#hosted-red-hat-lightspeed-and-rhc)
and [publication gates](../ROADMAP.md#rm-04-live-release-qualification).
The [Lightwell simulation](../../addons/lightwell/README.md) reuses the AO model
for tool-free notes and preserves explicit production approval; it does not
claim to repair native Lightspeed chat. Integration is not marked complete.
Resume using the
[non-destructive restart procedure](older-command.md#pause-for-travel-without-deleting-data),
then repeat the relevant live checks before claiming the integrations work.

## Product references

- [AAP AI integration](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.7/discover-ai_integration_in_ansible_automation_platform)
- [AAP chatbot configuration](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.7/extend-proc_create_chatbot_config_secret)
- [Satellite MCP](https://docs.redhat.com/en/documentation/red_hat_satellite/6.18/html/managing_hosts/connecting-ai-applications-to-the-mcp-server-for-satellite)
- [Developer Lightspeed configuration](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/interacting_with_red_hat_developer_lightspeed_for_red_hat_developer_hub/configure-to-initialize-the-ai-assistant_interacting-with-developer-lightspeed-for-rhdh)
