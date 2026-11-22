---
name: aap-integration-validation
description: >
  Verify local aap-demo wiring between Automation Orchestrator, AAP, MCP,
  Ollama, Satellite, and Fleet. Use for integration health checks, wiring
  verification, or questions such as "is everything connected?"
---

# AAP integration validation

## Scope and preparation

- Read [the workflow guide](../../../docs/guides/assistant-skills.md).
- This skill validates connections; it does not install or rewire services.
- Run `aap-demo version`, `aap-demo status`, and `aap-demo diagnose`.
  Confirm the local kubeconfig, namespaces, enabled addons, and CLI variant.
  For Bash-only features, use `bash ./aap-demo.sh` from the repository root.
- Discover actual route hosts and configured resource names. Never assume
  `apps-crc.testing`, an IP address, or a particular AAP instance.
- Retrieve credentials only into private process state using existing
  authentication helpers. Do not print secrets, dump credential objects,
  or put credentials in command arguments. Follow the repository's
  [secure curl helper](../../../includes/secure-curl.sh).
- `bash ./aap-demo.sh check-integrations` provides a repeatable first pass.
  Its AO validation and historical job results do not prove current
  connectivity or Fleet registration; apply the deeper checks below as needed.

## Validation sequence

1. Inspect AAP conditions, pod readiness, and PVC binding. A successful
   diagnosis or a running pod is not proof of working integration.
2. Read AO integrations through its authenticated API. Check the configured
   endpoints and enabled flags. Use the existing API/authentication helpers
   in [addon wiring](../../../includes/addon-wire.sh), not a parallel client.
   Do not call the top-level wiring routine during inspection.
3. Check authenticated AO-to-AAP read access, such as the inventory proxy.
   If API validation is needed, inspect the installed API contract and
   invoke only connection validation, never automation execution.
4. Check MCP discovery and enabled tools through AO. Distinguish tool
   discovery from a successful tool execution; do not invoke mutating tools.
5. From the AO backend, check the configured Ollama endpoint and model list.
   Confirm that the selected default model exists and is enabled in AO.
   Reachability alone does not prove a successful LLM workflow.
6. For enabled Satellite integration, check the inventory source's latest
   synchronization result and actual registered Fleet hosts. Inspect recent
   Fleet/APD ping results. Request approval before launching new jobs.
7. Classify unrelated external-demo inventory failures separately. Do not
   declare AWS, Insights, or other integrations working without evidence.

The existing [AO smoke test](../../../test/test-ao-live-smoke.py) provides
additional read-only checks of expected demo content. Inspect its prerequisites
and expected content first; missing optional demos are not necessarily broken
wiring. Lab-specific TLS exceptions must remain local, not global trust changes.

## Result

Return a short table: connection, evidence, and PASS / FAIL / NOT TESTED /
DISABLED. Include failures, timestamps or job IDs, and verification limits.
Report missing CPU metrics separately from connection health. Propose the
smallest repair and obtain approval before running `aap-demo wire`, enabling
addons, changing credentials, or restarting workloads.
