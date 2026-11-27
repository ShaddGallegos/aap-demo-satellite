---
type: Guide
title: aap-demo roadmap and reusable agent prompt
description: Selectable improvement tasks with scope, dependencies, safeguards, and evidence-based acceptance criteria.
---

# aap-demo Roadmap and Agent Prompt

**Last updated:** 2026-11-26

This is a directional backlog, not a release commitment or permission to execute
every task. Existing capabilities may already satisfy parts of a task; inspect
the current checkout before proposing changes. Do not treat this document as a
verified inventory of missing features.

Cloud and VMware provisioning remains **deferred**. The local-only profile
contract is implemented, but it does not authorize infrastructure changes,
provider spending, scheduled actions, or a claim that a provider is qualified.

## 1. Copy-and-use prompt

Copy this prompt into a new conversation and replace the selection:

```text
Use docs/ROADMAP.md as the task catalog for this aap-demo checkout.

SELECTED_IDS: <one task ID, such as RM-09 or RM-08F>
MODE: plan
TARGET: current checkout; no live infrastructure changes authorized

1. Read README.md, CONTRIBUTING.md, docs/index.md, and the selected task.
2. Verify the branch, worktree, existing implementation, and relevant tests.
   Preserve unrelated edits. Do not assume roadmap work is entirely missing.
3. Check the selected task's prerequisites and report missing decisions.
   Work only on the selection, not the entire roadmap or its prerequisites.
4. In plan mode, return a bounded implementation plan, affected paths,
   acceptance checks, risks, and required approvals. Do not change code or
   infrastructure. Plan mode is the default.
5. In implement mode, apply only the explicitly selected and approved scope.
   Reuse existing helpers, preserve behavior, update related documentation,
   and run the smallest relevant existing tests.
6. Obtain separate approval for destructive/disruptive operations, cloud
   spending, scheduler activation, publication, and changes to shared resources.
7. Report verified results and blockers. Do not mark a task complete without
   acceptance evidence, or claim unrun live scenarios passed.

Return: selected IDs; existing evidence; plan or changes; checks and results;
remaining risks/blockers; next safe action. Never include secret values.
```

Change `MODE` to `implement` only when requesting implementation. Replace
`TARGET` with an explicitly approved disposable environment when live testing
is intended. A task may be split into a smaller independently verifiable slice;
retain its parent ID and list which acceptance checks remain outstanding.

### Dashboard and platform-safety planning prompt

```text
Use docs/ROADMAP.md and the active implementation worktree identified below.
SELECTED_IDS: RM-05A, RM-05B, RM-05C, RM-11
MODE: plan
TARGET: current local lab; shared host; no live changes authorized

Plan a more professional Red Hat product-style dashboard, with an approachable
front page for live status, usage, available features, inventory and reports.
Evaluate ansible-cmdb for that front page; distinguish generated fact reports
from current telemetry. Keep the existing guarded CLI/dashboard operations.

Make demos polished and credible, but never substitute fake success for a
failed or untested integration. Satellite content, host registration, cloud
reporting and remote remediation need separate evidence and controls. Opening
a console is neither a reporting check nor permission to execute remediation.

Plan firewalld, SELinux and related safeguards for the specific environments,
apps and configurations enabled in aap-demo. Preserve enforcing mode, native
operator ownership, unrelated workloads and the private dashboard boundary.
Propose scoped required flows/policies, verification and rollback; never use
global security disablement as an installation workaround.

Read the selected catalog entries and existing implementation before proposing
changes. Return a bounded layout/design, data-source and freshness contracts,
ansible-cmdb suitability/dependency assessment, demo evidence/action matrix,
security flow/policy matrix, tests and required approvals.
This prompt authorizes planning only, not installation, redesign, remediation,
firewall changes, policy changes, destructive testing or publication.
```

### Current-work takeover prompt

Use this instead of the generic planning prompt to continue the active work.
Completed implementation is baseline, not a request to recreate it.

```text
Continue the existing Satellite/CI-CD work, not a project-wide refactor.
SELECTED_IDS: RM-04C, RM-04D, RM-04E, RM-04F
MODE: implement remaining approved work; preserve all unrelated edits

Read this roadmap, README.md, CONTRIBUTING.md, and docs/index.md first.
The primary checkout does NOT contain the latest implementation:
  /home/sgallego/GIT/aap-demo-satellite
The active implementation is in this existing worktree:
  SESSION=/home/sgallego/.copilot/session-state/81be407f-912c-4088-8b8e-4d2f477de29a
  WORKTREE=$SESSION/files/release-worktree
Use that worktree for code changes and validation. Verify branch/status first.
Expected branch: release-sync-satellite-20261116; recorded HEAD: da017e6.
An unfinished merge has zero unmerged paths. Many older edits are staged;
current integration changes include unstaged and untracked files. Do not
revert, blanket-stage, overwrite the primary checkout, or finish the merge.
Both roadmap copies are updated for discoverability, not code synchronization.

First inspect existing code and the evidence below. Do not rerun completed
Satellite installation/maintenance/manifest import or rotate a healthy native
connector token. Continue only the remaining tasks, not the whole backlog.
Keep working code and acceptance evidence; remove verified completed steps
from this roadmap's Work lists and retain history in the changelog.

User-authorized scope includes integrating the upstream CI/CD simulation,
dashboard services/functions, focused tests, and a managed full uninstall/
reinstall with:
  bash ./aap-demo.sh --full-demo --sno --satellite --lightwell
This host is SHARED, not disposable. Authorization covers owned lab resources
only. Before teardown, prove a reconstructible install and preserve source,
encrypted credentials, retained NFS data and off-VM recovery backups.
Do not delete a working lab while its reinstall prerequisites are missing.
No application PR simulation/merge, production deployment, reset, remote
remediation, unrelated VM mutation, or forced shutdown is authorized merely
to validate configuration. Preserve the workflow's human approval gate.

Start with RM-04E's remaining code checks, then read-only live preflight.
If blocked, record the exact missing prerequisite rather than claim success.
Do not silently enable timers, weaken TLS/SSH checks, or bypass native checks.
Do not commit/push/open or update a PR before the user's full-success condition
is met. No release/version bump is authorized. PR #2 conflict resolution still
requires approval of merge versus rebase; never force-push without approval.

Return PASS/FAIL/BLOCKED/NOT TESTED with exact evidence and next safe action.
Keep secrets, manifests, entitlement data and private logs out of the report.
```

**Verified baseline; do not repeat as implementation work:**

- Satellite 6.18.11 was recovered through supported maintenance, directly
  registered with Red Hat, and given its owner-matched manifest: three
  subscriptions. Pulp and backup NFS paths and retained recovery backups exist.
- Native connector invocation 1 failed on proxy-to-self SSH authorization.
  Existing keys were preserved and only the native proxy public key authorized.
  Invocation 2 succeeded: success 1, failed 0. Latest read-only verification:
  `rhcd` active/enabled, worker present, connector identity populated.
  This does **not** prove hosted inventory acceptance or Fleet reporting.
- Scoped connector reconciliation and negative-path tests already exist.
  A healthy connector is reused without rotating the native service token.
- The Lightwell addon, CLI flag/implicit `create`, pinned AAP/AO integration,
  dashboard links, and focused tests already exist in the active worktree.
  They are not yet qualified live. Do not recreate these components.
- Dashboard Overview/Demos/Add-ons/Services-and-Fleet navigation and individual
  Lightwell/Satellite/Product Demos submenus are implemented and browser-tested.
  Configure/remove buttons reuse guarded operations. The authenticated,
  allowlisted check button runs only `check-integrations`; a live click passed.
  Native application buttons navigate, not launch jobs or grant approval.

**Implementation map in the active worktree:**

- Connector: `satellite-lab/configure-cloud-connector.sh`,
  `satellite-lab/build-and-configure.sh --cloud-connector-only`,
  `satellite-lab/06-integrations.sh`, `includes/workflow-journal.sh`,
  `test/test-satellite-cloud-connector.sh`.
- CI/CD: `addons/lightwell/{deploy.sh,provision.py,README.md}`, `aap-demo.sh`,
  `includes/help.sh`, `config/addons-dashboard.json`, `test/test-lightwell.py`,
  `test/test-full-demo.sh`. Reuse `addons/ao/scripts/import-demos.py`,
  `provision-aap-demos.py`, `includes/addon-wire.sh`, and `secure-curl.sh`.
- Dashboard: `dashboard/server.py`, `dashboard/static/app.js`,
  `dashboard/static/index.html`, `dashboard/static/app.css`,
  `test/test-dashboard.py`, `test/test-dashboard-routes.js`.
- Related documentation: `docs/CHANGELOG.md`, `docs/index.md`,
  `docs/guides/ai-integrations.md`, and `satellite-lab/README.md`.
  The primary checkout has older related documentation; preserve its edits.

**Validation evidence and remaining limits:**

- Passed: connector mock tests; Satellite maintenance and workflow-journal
  regressions; full-demo order/fail-fast tests; ten Lightwell tests, including
  repeated import, ownership, approval safety, cleanup, and temporary-token
  revocation on success/failure; eight existing AO importer tests; 36 dashboard
  Python tests; dashboard JavaScript link/escaping/status tests.
- The actual pinned upstream workflow passed final name/graph/no-tools/trigger
  validation. Workflow-name and unmanaged-project cleanup guards have tests.
- New connector/addon shell lint and modified Markdown lint passed before this
  handoff edit. Warning-level checks passed on the larger shell files; stricter
  checks still report existing informational/style findings.
- Scoped Ruff checks pass for the new Lightwell Python implementation/tests.
  Existing dashboard files have inherited lint findings; do not describe the
  whole tree as lint-clean.
- RM-04E's current code checks pass: AO importer selection guards, Lightwell,
  integration-check, full-demo order/fail-fast, dashboard-route, shell syntax,
  and warning-level shell lint. The read-only live integration inspection uses
  strict TLS and makes no kubeconfig or lab changes. On 2026-11-18, AO,
  AO-to-AAP, AO-to-MCP, AO-to-Ollama, and the latest Fleet ping passed;
  Satellite inventory sync was disabled because `product-demo-satellite` was
  not enabled. No CI/CD job, PR, merge, promotion, or remediation was launched.
- Offline secret scan found a public pinned commit SHA, synthetic credential
  test fixture, and an existing baseline-matched `secret_mode` finding. No real
  secret was identified. Repeat the offline scan after final edits, including
  untracked files; never regenerate the baseline to hide findings.
- The earlier full-demo URL blocker is repaired by retained managed origins.
  `--preflight` still checks configuration, not complete rebuild readiness.
- Satellite is running; Fleet 1-3 remain stopped and isolated Fleet 4 is running.
  CRC is now reachable:
  native status reports OpenShift 4.22.14 running; diagnosis has no critical
  failures, with storage-class/CPU-metrics warnings. Do not repeat CRC repair
  based on the older unreachable-API observation.
- Managed Lightwell prerequisites now exist: retained OpenFlake/PostgreSQL,
  private `aap-demo/inventory-service`, an unprivileged repository-scoped runner,
  strict supported CA/SSH trust, dedicated AAP inventory/credentials, and an AO
  service account using short-lived tokens. Native CI runs 1 and 2 passed.
  Runner-to-AO trusted HTTPS and authenticated AO reads passed. No upstream
  AWS bootstrap or cloud resources were used.
  The guarded native AO version is now activated with an expected-version
  check; a disabled imported draft was not treated as ready. No run was launched.
- Dedicated Fleet 4 passed RHSM, Insights and RHC enrollment. Kernel evidence
  proved package-manager OOM at 1 GiB; 4 GiB survived an ordinary restart.
  Native application setup job 83 passed and both baseline endpoints responded.
  Repeated preparation reused service identities. Full-demo reconstruction code
  covers marked-node reuse/new dedicated-node creation; its fresh path has
  focused tests, not destructive live qualification.
- Browser qualification passed navigation, cancellation without mutation,
  unconfigured-demo guards, Satellite links, and real read-only inspection.
  No full-lab uninstall/reinstall, live CI/CD deployment, GitHub commit/push, PR update,
  or release has been performed for this integration.
- Local Gitea is now installed outside CRC on Fedora 45, with a reserved
  libvirt address and dedicated host NFS export. Reuse it; do not recreate it
  or run the upstream AWS bootstrap. `--gitea` and `--gittea`, addon commands,
  dashboard install/start, retaining stop, and service links are implemented.
  The Bash CLI symlink now targets the active implementation worktree.
- Live Gitea qualification passed strict authenticated HTTPS, private Git
  clone/push, repeated enable, and dashboard stop/start with unchanged VM UUID,
  source commit, CA and administrator credential. Fedora SELinux is enforcing;
  root-squashed NFS and consistent database backups were checked. Native Git
  read access from the AAP execution environment passed with an explicit CA.
  See `addons/gitea/README.md` and `test/test-gitea.py`. Service origin is
  `https://192.168.122.4:3000`; read current state instead of assuming that IP
  on another host. The private example repo is `aap-demo/aap-demo-local-source`.
  No runner or AAP SCM credential/project was automatically installed.

**Deferred follow-up, still unfinished:** In a new VS Code chat verify optional
agents appear in the picker and exercise each; a background worker attempt here
did not implement anything. Review release readiness only after RM-04 gates.
PR #2 source-control decisions and publication remain separately gated above.

## 2. Mission and boundaries

Make aap-demo reliable for creating, demonstrating, operating, pausing, recovering,
and removing development/demo environments. It is never a production deployment
pattern.

- Use [README](../README.md), [CONTRIBUTING](../CONTRIBUTING.md), and the
  [documentation index](index.md) as the sources of truth.
- Preserve existing commands, aliases, defaults, state, and supported platforms.
  Keep the Bash CLI and Python package distinct; do not assume feature parity.
- Reuse lifecycle, readiness, locking, secure HTTP, credential, and addon helpers.
  Do not grow the main dispatcher except for bootstrap/dispatch needs.
- Keep retained secrets encrypted. Exclude credentials, keys, authorization
  headers, manifests, and sensitive request bodies from ordinary output and logs.
  Use offline secret scanning; review false positives individually.
- Preserve unrelated VMs, networks, disks, existing identities, and retained
  backups. Verify ownership before cleanup. Never silently replace an SSH identity.
- Respect operator ownership on OpenShift and native Red Hat lifecycle tooling.
  Do not bypass failed prechecks, weaken certificate/host-key validation, or force
  reinstallations to hide health failures.
- Keep local services local. Future hosted demos require reviewed private access,
  not public dashboard exposure or a claim of production security.
- Keep failure reporting explicit, retries bounded, and noninteractive behavior
  deterministic. No success-shaped fallbacks or silent provider/cost changes.
- Do not commit, push, merge, publish, activate timers, or incur provider charges
  merely because a roadmap task mentions those operations.

## 3. Task selection and ordering

Priorities are recommendations, not authorization. Dependencies name prerequisite
contracts or evidence, not a requirement to finish every unrelated part of a task.
Except for explicitly deferred work, implementation status must be assessed when
a task is selected.

| ID | Priority | Objective | Prerequisite |
|----|----------|-----------|--------------|
| RM-01 | Now | Thin CLI and consistent command contracts | Qualified baseline; RM-09 isolation |
| RM-02 | In progress | Declarative addons and versioned state | Relevant RM-01 interfaces |
| RM-03 | In progress | Observable workflows and safe reconciliation | Relevant RM-01/RM-02 contracts |
| RM-04 | Now | Clear publication blockers and qualify live releases | RM-09 isolation before live tests |
| RM-04E | Now | Finish existing CI/CD integration qualification | Prepared services and RM-04C/D |
| RM-04F | Blocked | Qualify managed full uninstall/reinstall | Reconstructible lab and RM-04E preflight |
| RM-05 | Next | Predictable daily UX and structured output | Relevant RM-01/RM-02 interfaces |
| RM-05A | Next | Professional Red Hat-style dashboard | Existing guarded dashboard; scoped design review |
| RM-05B | Next | Front-page live inventory, usage and reports | RM-05A data contracts; ansible-cmdb evaluation |
| RM-05C | Next | Credible demos with verified operational controls | RM-04C/D/E evidence; existing operation boundary |
| RM-06 | Later | Tested host/platform parity | RM-02 declarations and RM-04 evidence |
| RM-07 | Later | Verifiable releases and dependency hygiene | Existing contribution/release rules |
| RM-08 | Foundation only | Cloud/VMware provisioning and operations | Reviewed contracts and provider scope |
| RM-09 | Partial | Strict test isolation and failure injection | None |
| RM-10 | Partial | Credential recovery and private support bundles | Existing Vault and diagnostics helpers |
| RM-11 | Next | Scoped platform firewall, SELinux and access safeguards | Enabled-component inventory; RM-09 isolation |

Within RM-08, prioritize private connectivity, durable state, verified backup/
restore, and budget controls before expanding the provider matrix.

Recommended refactoring sequence:

1. Complete outstanding lifecycle validation, resolve known blockers, and establish
   an integrated, tested baseline. Integrate pending changes only with publication
   or source-control approval; do not mix unfinished fixes with broad structural moves.
2. Verify RM-09 test isolation before relying on the regression suite.
3. Use RM-01A/RM-01B to capture behavior and module boundaries, then extract
   configuration, argument handling, and read-only commands first.
4. Move mutating lifecycle operations behind focused regression tests and the
   shared operation boundary in RM-01C, using RM-01D migration slices.
5. Establish RM-02 addon/provider contracts before starting deferred RM-08 work.
6. Evaluate a shared Python core or another implementation language only after
   the boundaries and RM-01E evidence justify the architecture decision.

## 4. Task catalog

### RM-01: Thin CLI and consistent command contracts

**Goal:** Reduce regression risk without rewriting working behavior.

**Work:**

- Inspect [the Bash entry point](../aap-demo.sh) and [shared modules](../includes/).
  Extract cohesive cluster, deployment, diagnostic, credential, Fleet, addon, and
  maintenance responsibilities where still needed.
- Keep bootstrap, dispatch, and compatible aliases in the entry point. Consolidate
  duplicated waits and define shared exit/error, timeout, prompt, progress,
  `QUIET=true`, and structured-output rules.
- Document boundaries in an ADR; sourceable modules must have no loading side effects.

**Accept when:** Public command behavior is preserved; mutating commands have focused
regressions; required failures return nonzero with a next action; relevant tests/lint
pass. Treat fewer than 1,500 entry-point lines as a directional target, not a release
gate or proof of improvement. Never reach it through minification or opaque indirection.

#### RM-01A: Behavioral compatibility baseline

**Work:** Capture supported commands/aliases/options, environment/configuration
precedence, prompts, exit codes, stdout/stderr behavior, state formats, and dashboard
request/response contracts before structural changes. Add focused characterization
tests for affected behavior without recording secrets. Separate intended behavior
from known defects; do not freeze bugs into compatibility requirements.

**Accept when:** Each selected extraction has before/after contract evidence;
public behavior stays compatible unless a separately approved change and migration
note explicitly explain the difference.

#### RM-01B: Module ownership and dependency rules

**Work:** Map responsibilities and dependencies across the Bash/Python/PowerShell
entry points, shared helpers, addons, and dashboard. Define permitted dependency
directions, explicit inputs/outputs, and ownership of configuration/state mutations.
Reuse existing modules; prevent circular dependencies and hidden global-state coupling.

**Accept when:** An ADR records the boundaries; affected modules load without side
effects; focused tests or existing static checks detect prohibited dependencies
and unintended configuration/state mutation.

#### RM-01C: Shared operation boundary

**Work:** Route dashboard and CLI lifecycle requests through the same authoritative
operation behavior where they control the same environment. Share locking,
authorization/approval policy, validation, readiness, and error semantics rather
than duplicating orchestration. Keep presentation and transport adapters thin;
do not assume separate Bash/Python backends already have identical capabilities.

**Accept when:** Equivalent dashboard/CLI requests produce consistent outcomes;
concurrent requests cannot bypass operation locks; unauthorized, unsupported, or
failed actions surface equivalent explicit errors without changing unrelated state.

#### RM-01D: Small, reversible migration slices

**Work:** Extract one cohesive responsibility per independently reviewable change.
Separate mechanical moves from behavior fixes and language conversions. Start with
configuration, argument handling, and read-only commands; migrate mutating operations
only after their contracts are covered. Document rollback and state-compatibility
limits without relying on destructive resets or discarding unrelated edits.

**Accept when:** Every slice builds/tests independently, preserves public contracts,
and has a safe rollback path or explicit migration constraints. No slice requires
an all-at-once rewrite or leaves a partially migrated public command unusable.

#### RM-01E: Architecture success measures

**Work:** Establish comparable before/after evidence for duplicated lifecycle logic,
dependency cycles, implicit mutable state, test isolation, and regression coverage.
Measure command startup or operation time only where the refactor affects it;
record the environment and scenario. Track file size as supporting information,
not the primary success measure.

**Accept when:** Each completed slice identifies the responsibility or duplication
removed and demonstrates preserved behavior. Claimed improvements have baseline
comparisons, and extraction does not merely redistribute coupling into more files.

### RM-02: Declarative addons and versioned state

**Status:** In progress. All public add-ons now have validated scenario contracts,
and the scenario harness derives dependency-closed compatibility cases from them.
The remaining work is to make these declarations the single source for help,
completion, dashboard catalog metadata, lifecycle behavior, and state migrations.

**Goal:** Make extensions and upgrades predictable.

**Work:**

- Define addon declarations for name/version, lifecycle scripts, dependencies,
  conflicts, architectures, resources, external services, readiness, wiring,
  cleanup/purge, and credential references without values.
- Generate help, completion, preflight, and dashboard metadata from the same
  declarations; validate before enablement.
- Version local state and Vault schemas. Provide backed-up, idempotent migrations,
  documented rollback limits, and explicit unknown/removed/partial-addon diagnosis.

**Accept when:** Adding a normal addon needs no dispatcher edit; consumers share
one contract; supported prior schemas migrate repeatably; invalid state fails
explicitly without disclosing secrets.

### RM-03: Observable workflows and safe reconciliation

**Status:** In progress. The dashboard now makes its operator-initiated Refresh a
fresh `aap-demo status --json` observation, while automatic refreshes retain a
bounded 30-second cache. The response identifies the collector, collection time,
cache TTL, and whether a fresh probe was requested. Shared lifecycle phases,
reconciliation, and cross-surface state evidence remain outstanding.

**Goal:** Make interruption and health failures understandable and recoverable.

**Work:**

- Extend existing phase/journal behavior rather than adding a second system.
  Cover create, deploy, start, full-demo, restore, and uninstall; record times,
  results, retry counts, and redacted error summaries.
- Share `ready`, `progressing`, `degraded`, `blocked`, and `stopped` states across
  status, diagnostics, JSON, and dashboard views.
- Keep status provenance explicit. Dashboard and CLI status use the same collector;
  operator refresh must bypass the dashboard cache and report its freshness rather
  than presenting cached data as a new observation.
- Show active phase, elapsed time, last success, and actionable blocker.
  Resume only verified idempotent operations; confirm destructive or externally
  visible retries. Define cancellation and stale-operation-lock recovery.
- Design a reconcile command, or equivalent existing-command behavior, that repairs
  drift without recreating healthy resources. New command names remain proposals.

**Accept when:** Phase interruption/retry converges without duplicates; terminal and
dashboard agree; cancellation preserves recoverable state; journals contain no
secrets and identify the next safe action.

### RM-04: Live release qualification

**Goal:** Separate isolated CI confidence from verified environment behavior.

**Work:**

- Define an opt-in, versioned lane on approved disposable hardware: clean preflight,
  create, AAP/subscription setup, full-demo, endpoint/integration checks, repeated
  idempotency, stop/start, separately approved host reboot, support collection,
  and uninstall with residue checks.
- Qualify MicroShift and SNO independently; include Satellite only with appropriate
  entitlement and backup approval. Do not infer subscription suitability from an
  unfamiliar product name.
- Run on a schedule/before releases, not automatically against arbitrary PR hosts.
  Retain private evidence and sanitized versions, timings, resource peaks, and results.
- Use sanitized API fixtures for Red Hat/AAP authentication rejection, empty and
  paginated responses, ambiguous subscriptions, rate limits, and malformed bodies.
- Make correctness gates blocking after existing violations are resolved; scan
  generated support/log artifacts offline as well as source.

**Accept when:** A qualified release links its tested version matrix and live results,
including install-time/disk measurements. Report skipped/blocked scenarios explicitly;
historical integration validation is not proof of current tool or model execution.

**Recorded blockers (2026-11-18):** Publication remains blocked by Lightspeed
reliability, Portal validation, and unfinished Satellite setup. The pending work
has not been committed or pushed. Complete applicable RM-04A through RM-04F and
release checks before requesting publication approval; this roadmap does not
authorize a commit, push, PR update, merge, or release.

#### RM-04A: Reliable authenticated Lightspeed conversations

**Work:** Reproduce the intermittent HTTP 502/504 failures through the native AAP
gateway, including cold- and warm-model requests. Trace application, proxy, and
model timing and resource constraints before choosing a supported fix. Preserve
operator ownership and authentication; do not hide failures with retries, weaken
TLS, or treat deployment readiness or one successful response as qualification.
Extend the existing opt-in live checks with harmless, tools-disabled queries.
Verify native MCP discovery and read-only tool execution separately before
claiming those integrations work.

**Accept when:** Repeated cold- and warm-model conversations return valid responses
within documented supported timeouts without intermittent 502/504 errors;
missing/invalid authentication is rejected; focused regressions pass. Record the
tested request path, resource settings, timing, and any unverified MCP behavior.
No automation jobs are launched merely to test chat.

#### RM-04B: Portal chat and MCP runtime qualification

**Work:** Verify the exact supported Portal chart, RHDH image, Lightspeed plugins,
and MCP backend package/configuration before enabling the approved profile.
Validate authenticated Portal chat against the local model, MCP discovery, and an
explicitly read-only tool call independently. Check upstream results rather than
only tool listings or HTTP success. Report missing plugins, unsupported profiles,
and incomplete authentication as blockers, not successful fallback behavior.

**Accept when:** The approved Portal profile installs and reconciles successfully;
authenticated chat and the selected read-only MCP tool work through their real
application paths; unauthorized requests fail; isolated regressions and scoped
live checks pass without exposing credentials. Record compatibility and resource
requirements, and distinguish UI validation from backend-only checks.

#### RM-04C: Safe completion of interrupted Satellite setup

**Work:** Inspect the existing installation before resuming unfinished content,
provisioning, and integration phases. The recorded installation has healthy
Satellite 6.18.11 and persistent NFS mounts, but only the default content view and
no activation keys. Recheck that state rather than assuming it remains unchanged.
Add narrowly scoped progress/resume handling for managed new installations;
preserve the existing-server path and administrator/organization settings.
Make partial-phase retries safe before replaying scripts that create repositories,
lifecycle environments, content views, or provisioning resources.

**Accept when:** The approved full-demo workflow completes successfully; intended
content is synchronized and published; the exact configured activation key works;
Fleet registration and current AAP Satellite inventory synchronization are
verified. Interrupted setup resumes without duplicate resources, reinstalling a
healthy server, overlaying retained Pulp data, or losing backups. Native health,
HTTPS, and persistent Pulp/backup mounts remain healthy after reconciliation.

#### RM-04D: Hosted Satellite Lightspeed and RHC

**Goal:** Show current hosted Red Hat Lightspeed/Insights information for the
owned Fleet nodes in Satellite without confusing it with Ansible chat.

**Status:** Native connector repair is complete; see the verified baseline above.
Do not repeat enablement, RHSM registration, or manifest import. Content,
Fleet registration, cloud inventory acceptance, recommendation synchronization,
and connection persistence after restart remain incomplete.

**Work:**

- Reconcile the incorrect stored Vault RHSM organization ID with authenticated
  discovery and the registered identity. Never log account identifiers,
  credentials, connector tokens, manifests, or entitlement keys.
- Reconcile only the required RHEL 9 repositories, synchronization, content
  view, and exact activation key in `Default Organization`; preserve its
  `Default_Organization` label. Do not replay all initial content/provisioning
  scripts or silently select another RHEL major.
- Fix and test required client failure propagation in Fleet registration.
  Preserve valid Insights markers; do not hide failed registration or blindly
  run direct-cloud `rhc connect` on Satellite-managed nodes.
- Register the three owned nodes through Satellite, configure the supported
  Insights reporting path, then perform and verify native inventory upload
  and recommendation synchronization. Keep server RHSM registration, client
  reporting, inventory upload, analytics, and remote remediation distinct.
- Do not launch remediation jobs, install a separate local analytics stack,
  or rerun full-demo merely to repair cloud reporting.

**Accept when:** The repaired native connector remains connected after an
approved restart; each owned node has the expected Satellite identity and
verified reporting path; fresh cloud uploads and Satellite synchronization
succeed with recorded timestamps/status. Zero recommendations is acceptable
when reporting and synchronization are proven. Focused negative-path tests
reject failed registration, upload, or connector setup rather than reporting
success. Preserve existing backups and unrelated workloads.

**Resume:** Use the current-work takeover prompt and recheck actual state.
The previous travel shutdown was partial; do not assume all guests are off.

#### RM-04E: Finish existing Lightwell CI/CD integration qualification

**Status:** Service/application prerequisites repaired and baseline-qualified;
end-to-end change delivery and promotion remain untested. As of 2026-11-18,
strict read-only AO inspection and the latest Fleet ping passed; Satellite
inventory sync was disabled because `product-demo-satellite` was not enabled.
No runtime operation was launched.
This is a patch simulation, not deployment of a real Lightwell backport service.

**Work:**

- Inspect the existing addon rather than importing a second copy. Upstream is
  `ansible-tmm/aap-orchestrator-demos/cicd-pipeline`, pinned to
  `3e2b24e6c3d5519cb380298ce45727412f17e20d`. No license declaration was found;
  preserve pinned runtime references, not vendored upstream files.
- Do not repeat completed service installation, baseline CI, RHC enrollment,
  application setup, or identity creation. Reuse managed `--prepare` and retained
  origins. Its normal enable/full-demo imports configure resources, not jobs.
- With deliberate runtime approval, qualify the change-tracked private PR,
  manual merge, CI webhook, development test and human approval boundary.
  Upstream opens a PR for manual merge; it does not automatically merge.
  Preserve rejecting production/rollback edges and tool-free AI notes.
- After provisioning, verify the new Gitea/OpenFlake links against real services.
  Preserve the browser-qualified menu, cancellation, and read-only controls.
  Keep configured-versus-runtime-verified explicit.
  Satellite supplies supported host/content/reporting; no invented remediation
  API, AI write tools, or implied repair of native Ansible Lightspeed chat.
- Repeat focused tests/lint and offline secret scanning after final changes.
  Update related docs with actual results and retain clear runtime blockers.

**Accept when:** Repeat enable/disable affects only owned resources and preserves
host/service data and credentials; real AAP/AO bindings and dashboard functions
work; failure paths are explicit; any approved runtime flow preserves human
approval and rollback. Mocked tests alone do not satisfy runtime acceptance.

#### RM-04F: Qualify managed full uninstall and reinstall

**Status:** Lightwell service/app prerequisites are available. Destructive
reconstruction remains gated on current entitlement/recovery checks and explicit
teardown approval. No uninstall/reinstall has run.

**Work:**

- Establish complete rebuild prerequisites, not merely URL syntax: trusted
  retained media, encrypted credentials, off-VM OpenFlake database/attachments
  recovery, Satellite entitlement/content, capacity, and storage.
  Recheck organization/owner against authenticated native identity; older
  mismatch reports are not proof that the mismatch still exists.
- Preserve required local recovery/config snapshots before native managed
  uninstall; some state-directory backups are removable. Preview with
  `aap-demo maintenance uninstall`, inspect ownership/scope, and only then use
  its approved apply path. Preserve source, Vault, unrelated VMs/networks,
  retained host NFS exports, and off-VM maintenance backups.
- Run the requested Bash full-demo SNO/Satellite/Lightwell command only when
  reconstructible. Use a fresh per-install Satellite NFS export; never combine
  retained Pulp data with a new database or substitute raw libvirt deletion.
- Verify uninstall residue, reinstall completion, native health/HTTPS/mounts,
  exact activation key, Fleet identity/content/reporting, current inventory
  sync, AAP/AO/model access, and dashboard. Record versions, timing, resources,
  failures, and explicit untested recovery paths.

**Accept when:** The actual approved managed uninstall and complete rebuild pass
without lost backups or unrelated mutations, followed by current functional
checks. A preflight rejection or mocked test is not a successful lifecycle test.
If prerequisites remain missing, leave the existing lab intact and report BLOCKED.

### RM-05: Daily UX and structured output

**Goal:** Make human use and unattended operation predictable.

**Work:**

- Provide documented minimal/standard/full-demo resource profiles and preflight
  before mutation. Respect explicit resource choices; explain capacity warnings.
- Support versioned non-secret configuration and machine-readable status,
  preflight, diagnose, version, and addon inventory with stable output schemas.
- Offer previewable repairs through existing commands or a proposed doctor mode.
  Never silently perform destructive recovery.
- Keep terminal progress useful interactively and in automation; link failure
  classes to repair guidance. Maintain changelog and state/behavior migration notes.

**Accept when:** Automation need not parse human output; missing noninteractive input
fails with a complete settings list; repairs require appropriate approval; upgrades
document configuration, credential, platform, and state impacts.

#### RM-05A: Professional Red Hat-style dashboard

**Status:** Requested; not implemented. Roadmap entry is not redesign approval.

**Goal:** Replace the current utilitarian appearance with a coherent,
professional product-style experience appropriate for a Red Hat/Ansible demo.

**Work:**

- Review current views and representative Red Hat product patterns. Evaluate
  PatternFly where appropriate; reuse permitted design-system components and
  assets, not copied proprietary screens or misleading product branding.
- Propose a clean application shell, clear navigation/submenus, consistent
  typography, spacing, tables, status cards, notifications and operation detail.
  Keep the front page useful to a less technical demo user.
- Preserve existing Fleet/terminal, addon, service-link, confirmation, operation
  lock, origin/session protection and read-only inspection behavior.
- Include responsive layouts, keyboard access, readable contrast and explicit
  loading, empty, disabled, stale and error states. Do not hide failures behind
  green summary cards or replace actionable detail with decorative charts.

**Accept when:** The approved design is browser-qualified at common viewport
sizes, accessible by keyboard, consistent across views, and preserves existing
guarded operations and their focused tests.

#### RM-05B: Front-page inventory, usage, features and reports

**Status:** Requested; not implemented. Evaluate ansible-cmdb before adding it.

**Work:**

- Evaluate ansible-cmdb's maintenance, license, runtime compatibility, output
  formats, dependencies and secure embedding options. Explain any suitability
  limits and propose an alternative for approval rather than silently swapping
  tools or adding an unsupported dependency.
- Present managed hosts/services, current availability, CPU/memory/storage usage,
  enabled/available features and useful inventory/report links on the front page.
  Reuse authoritative native facts, AAP jobs and existing status/diagnose helpers.
- Treat ansible-cmdb output as a generated report from a timestamped facts
  collection, not an inherently live monitoring service. Show source, collection
  result, age and refresh state for every report/metric; separate snapshots,
  history, estimates and current telemetry.
- Use bounded refresh/caching and explicit collection scope. Missing metrics,
  stopped hosts, partial collection and unavailable APIs must remain visible;
  never fabricate usage values or treat cached facts as a successful new check.
- Keep facts/reports private and redacted. Review collected fields, escape
  untrusted fact content, and protect generated HTML/downloads with the same
  access boundary. Assess sandbox/CSP and offline assets before embedding HTML;
  no automatic upload of inventory or loading of unnecessary third-party assets.

**Accept when:** Users can see current service state, meaningful usage, feature
availability and readable reports; freshness and failed collection are explicit.
Real scoped collection, partial failure, stale/offline states and protected
report access pass tests without exposing credentials or unrelated inventory.

#### RM-05C: Credible demonstrations backed by real operations

**Goal:** Demo smoothly while keeping advertised functions usable when enabled
and authorized; do not make a nonworking integration merely appear healthy.

**Work:**

- Show separate Satellite readiness/evidence for content availability, host
  registration, cloud reporting and remote remediation, reusing RM-04C/D native
  workflows. Console navigation or configured-demo state proves none of these.
- Identify each check's source, target, last attempt/success, result and next
  safe action. Distinguish configured, reachable, authenticated, reporting,
  operation-verified, failed, disabled and not-tested states.
- Keep read-only inspection separate from mutating actions. Real registration,
  sync and remediation use supported native/AAP workflows with scoped targets,
  previews, required permissions, confirmation, progress and explicit failures.
  Preserve human production approval and recovery/rollback boundaries.
- If an offline/scripted demo uses sample data, label it as sample/simulated,
  isolate it from live targets and make the mode unmistakable. Never silently
  fall back to sample success when a live integration fails.

**Accept when:** A scoped real demonstration proves each advertised operational
path independently; unavailable functions are disabled with a reason. Opening
a console never executes remediation or changes a reporting indicator, and
sample/offline demonstrations cannot be mistaken for verified live operation.

### RM-06: Host and runtime parity

**Status:** Not started. Scenario contracts are an input to the eventual generated
capability matrix, but no host/platform qualification matrix exists yet.

**Goal:** Advertise only capabilities backed by declarations and evidence.

**Work:** Generate a Linux/macOS/native-Windows/WSL capability matrix; distinguish Bash
and Python interfaces, host/guest architectures, cluster runtimes, and addon versions.
Share schemas, fixtures, and lifecycle contracts across Bash/PowerShell. Qualify
real-host recovery where runners exist; label supported, experimental, unavailable,
and awaiting-live-validation combinations explicitly.

**Accept when:** Platform limits are detected before mutation; equivalent commands
report equivalent state/error categories; the matrix is generated rather than
duplicated manually; unsupported combinations are not presented as supported.

### RM-07: Release and supply-chain hygiene

**Goal:** Make distributed artifacts and changes independently verifiable.

**Work:** Produce checksums/signatures and an SBOM; pin or authenticate executable
downloads and images where supported; automate dependency/base-image proposals.
Publish tested product/host versions, known limitations, migration instructions,
and deprecation policy. Preserve the existing package/version/publication rules.

**Accept when:** Release artifacts are verifiable, downloaded executables are
authenticated or checksum-verified, and each release has a support matrix and
upgrade notes. Do not bump package versions or publish for unrelated roadmap work.

### RM-08: Cloud and VMware environments

**Status:** AWS/GCP read-only preflight plus profile foundation implemented;
provisioning deferred. `aap-demo cloud` creates and validates versioned,
local-only planning profiles for AWS, Azure, GCP, and VMware. Explicit AWS and
GCP preflights use only provider read operations to verify identity, private
network, DNS/egress prerequisites, firewall exposure, and workload identity.
Profiles require ownership, topology, identity-reference, and charge-approval
inputs while rejecting plaintext secret-like fields. No credentials are
collected and no resources, schedules, or costs are created. AWS/GCP
quota/image/private-DNS/Cloud-DNS discovery and all Azure/VMware discovery
remain future slices; do not implement every provider simultaneously.

**Prerequisites:** Relevant addon/state/lifecycle contracts; RM-09 isolation; reviewed
provider/runtime support and licensing constraints; explicit infrastructure scope.
The host provider does not establish that CRC, nested virtualization, or Satellite
is supported there. Establish that separately before provisioning.

#### RM-08A: Detection, provider preflight, and repeatable profiles

**Work:** Detect evidence of libvirt/KVM, VMware, AWS, GCP, or Azure hosting without
treating detection as authority. Handle unknown/ambiguous results; confirm the target
and permit overrides. Check permissions, quotas, images, architecture, compute,
storage, nested virtualization where required, and connectivity. Offer provider API
VMs or explicit existing-node integration when supported, never an unsupported
nested-virtualization fallback.

Prompt only for missing values; support noninteractive inputs and versioned non-secret
profiles with credential references:

| Provider | Settings to discover or request |
|----------|--------------------------------|
| libvirt | Connection, network, storage pool, images |
| VMware | Endpoint, datacenter, cluster/resource pool, datastore, port group, templates |
| AWS | Account/profile, region, VPC/subnet, security groups, image, instance sizes |
| GCP | Project, region/zone, VPC/subnet, service identity, image, machine sizes |
| Azure | Subscription/tenant, resource group, region, VNet/subnet, identity, image, VM sizes |

Include node counts, disk capacity, SSH access, private DNS, Satellite hostname,
content/backup storage, and Red Hat entitlement access. VMware preflight must check
vCenter certificate trust/privileges, template compatibility, VMware Tools readiness,
datastore capacity, and placement constraints.

**Accept when:** Detection/override/unsupported paths are tested; profiles recreate
intended settings without copying incompatible provider identifiers; missing inputs
or capabilities stop before chargeable provisioning; the default local path is unchanged.

#### RM-08B: Private connectivity wizard

**Work:** Validate VPN/private access, required forward/reverse DNS, certificates,
and bidirectional AAP/Fleet/Satellite paths. Check prerequisites before provisioning
and actual endpoints after creation. Account for restart address changes without
opening public ingress or weakening trust.

**Accept when:** Failed paths identify a concrete remedy; advertised environments
pass actual registration, inventory sync, and integration access over private paths.

#### RM-08C: Durable infrastructure state

**Work:** Retain protected provider/resource inventory outside the managed host;
lock concurrent mutations; track ownership; detect drift/orphans; reconcile partial
runs before retrying. Preview cleanup and preserve external resources and backups.

**Accept when:** Host loss and concurrent/interrupted requests do not cause duplicate
creation or deletion of unrelated VMs, networks, disks, schedules, or identities.

#### RM-08D: Backup and restore qualification

**Work:** Use supported application-consistent AAP/Satellite procedures, protected
off-host storage, retention policies, and restore drills. Define recovery-time and
data-loss objectives. VM snapshots alone are not verified application recovery.

**Accept when:** Restore drills meet the declared objectives and prove application,
content, credential, registration, and integration recovery; untested paths are labeled.

#### RM-08E: Budgets, runtime limits, and expiration

**Work:** Preview chargeable resources; obtain spending approval. Offer spending
alerts, maximum runtime, and explicit demo-expiration policies. Distinguish estimated
from actual cost, and alerts from enforcement. Disclose storage/address/network/
scheduler charges while compute is stopped.

Automatic deletion requires a separate explicit opt-in policy, verified required
backups, ownership checks, and preservation of retained backups/shared resources.
Budget limits must not silently change provider, region, machine size, or data retention.

**Accept when:** Warning, limit, missing-cost-data, expiration, and failed-backup paths
are tested; users can see remaining chargeable resources; stop never means delete.

#### RM-08F: Dashboard power controls and timers

**Work:** Add manual Start/graceful Stop for managed Fleet/Satellite nodes and the
whole VMware/AWS/GCP/Azure demo, similar to Fleet power buttons. Show provider state,
pending operations, and failures. Support countdowns, one-shot/recurring start/stop,
edit/disable/cancel, explicit timezone, next run, daylight-saving, and missed-run rules.

Run schedules outside the managed demo host so startup works when its dashboard is
off; document an authenticated external start path, not public dashboard exposure.
Confirm resource scope/schedules, honor dependencies, warn about active jobs/sync/
installation/maintenance, and check application readiness after startup. For VMware,
use vCenter/VMware Tools where available; forced power-off needs separate approval.
Explain stop/deallocation differences, restart capacity, IP changes, and residual cost.

**Accept when:** Each advertised backend passes manual/timer lifecycle, dashboard-off
startup, cancellation, permission/API failure, and dependency-recovery tests without
resource deletion. Unsupported power operations are disabled with a reason.

#### RM-08G: Dashboard authorization and audit

**Work:** Keep access private; separate view, power, and deletion permissions;
limit identities/schedulers to explicitly managed resources. Record actor, scope,
schedule changes, and redacted results. Remove owned schedules during teardown.

**Accept when:** Unauthorized requests are rejected and tested; scheduled actions
cannot outlive approved ownership/policy; audit records reveal no credentials.

#### RM-08H: Provider failure recovery and qualification

**Work:** Handle throttling with bounded retries; surface expired identities,
capacity/image failures, and interrupted operations. Reconcile before retrying;
seek approval for provider/region/size/cost alternatives. Publish a tested capability
matrix instead of promising universal cloud support.

**Accept when:** Each advertised backend has live evidence for Fleet, Satellite,
private connectivity, AAP wiring, registration, inventory sync, power/timers, and
safe teardown. Unsupported or untested capabilities remain visibly labeled.

### RM-09: Strict test isolation and failure injection

**Status:** Partial. The non-live runner now isolates HOME, aap-demo state,
XDG paths, kubeconfig, and socket-probe behavior, and the current unit suite runs
without using the caller's Vault or state directory. Remaining work includes
systematic unexpected-call guards and broader failure-injection coverage for
external tools and providers.

**Goal:** Prevent a supposedly non-live test from affecting a shared host.

**Work:** Audit the [non-live runner](../test/run-unit-tests.sh) and its fixtures.
Isolate HOME, state, sockets, and relevant XDG paths; stub external mutations such
as systemd, CRC, libvirt, SSH, provider APIs, and credential access. Fail on unexpected
calls rather than falling through to host tools. Keep real lifecycle checks opt-in.
Add focused malformed/empty-response, timeout, permission, retry, and partial-failure
cases for behavior being changed; verify the intended failure point, not just nonzero exit.

**Accept when:** The non-live suite passes with no cluster/cloud credentials and
cannot mutate real services, VMs, provider resources, or the user's Vault. Validate
isolation with denied/unexpected-call guards, not by risking a real environment.

### RM-10: Credential recovery and private support bundles

**Status:** Partial. A local-only, redacted support-bundle preview/create command
with restrictive permissions and offline secret scanning is available. Credential
rotation/recovery playbooks and the remaining documented recovery cases still need
isolated acceptance evidence.

**Goal:** Make diagnosis and access recovery safe without leaking or replacing secrets.

**Work:**

- Document recovery from lost/unreadable Vault passwords, expired tokens, SSH
  host-key changes, and missing identities. Explain irrecoverable cases honestly;
  never generate a replacement identity for existing nodes without explicit approval.
- Design approved credential rotation with readback verification, consumer updates,
  and rollback limits; prefer provider workload identities where appropriate.
- Build one redacted support-bundle manifest using existing status/diagnose/
  must-gather helpers. Preview collection, exclude secret-bearing inputs, use
  restrictive file permissions, scan offline, and document retention/cleanup.
  Do not upload automatically.

**Accept when:** Isolated rotation/recovery failures preserve valid existing access;
bundles contain useful versions/health/phases without secrets; inaccessible or unsafe
evidence is reported as unavailable rather than replaced by misleading success.

### RM-11: Platform firewall, SELinux and access safeguards

**Status:** Requested; assessment/plan first. No broad host changes authorized.

**Goal:** Enabled aap-demo environments and applications operate through explicit,
least-privilege allowances without weakening shared-host security.

**Work:**

- Inventory enabled components and actual host/VM/container/cluster boundaries.
  Produce a required-flow matrix with source, destination, interface/zone,
  protocol/port, purpose, owner and lifecycle. Include only needed DNS, HTTPS,
  SSH, NFS, management and application paths; discover actual endpoints.
- Inspect native firewalld zones, policies and persistent/runtime rules.
  Reconcile only owned, narrowly scoped allowances. Preserve unrelated rules,
  networks, exports and workloads; never flush rules, trust a whole interface
  unnecessarily, expose management publicly or disable the firewall to fix access.
- Preserve SELinux enforcing mode. Diagnose AVC denials and use supported
  persistent file/port labels, narrowly justified booleans or reviewed scoped
  policies. Preserve operator ownership and container volume semantics; no
  permissive-mode workaround, broad automatic allow policy or recursive relabel
  of unrelated storage.
- Review adjacent safeguards for the selected components: verified TLS/SSH,
  Vault/native credential handling, private dashboard access, authorization,
  session/origin protection, service users, sudo/container privileges, file/NFS
  permissions and cluster RBAC/network policy where applicable.
- Integrate declared requirements into enable/start/diagnose/reconciliation and
  owned cleanup. Preview privileged changes, define rollback, and verify both
  allowed operation and denied unintended access after restart/re-enable.
  Do not enable schedules or expand to deferred providers as part of this task.

**Accept when:** Each selected enabled feature has a reviewed flow/policy entry
and functional evidence under enforcing SELinux and the intended firewall.
Positive/negative access tests, persistence, idempotency, scoped cleanup and
failure/rollback checks preserve unrelated resources. Remaining exceptions and
untested combinations are explicit; do not claim production certification.

## 5. Evidence and completion contract

For any selected task:

1. Record its ID and verified initial state; list the exact approved slice.
2. Map each applicable acceptance criterion to changed paths and a check/result.
3. Run focused existing tests/lint first. Distinguish mocked tests, read-only
   inspection, current functional execution, destructive lifecycle, and recovery drills.
4. Update directly related help, completion, dashboard metadata, changelog, and
   migration guidance as applicable; do not move design detail into the quick start.
5. Record known limitations, unrun checks, ownership/backups preserved, and next
   safe action. Mark complete only with evidence, otherwise partial or blocked.

Track fresh full-demo success rate; repeat-run changes; median/worst install time;
disk/resource peaks; actionable failure coverage; tested platform/version combinations;
recovery after interruption; and secret leaks in source, logs, and support bundles
(target zero). Record baseline and comparison scope before claiming improvement.

## 6. Architecture decision gate and non-goals

Do not rewrite the project solely because a Bash file is large. First establish
module, state, addon, and command contracts. Any later ADR comparing Bash/PowerShell
with shared contracts, a Python core, or a compiled CLI must measure prerequisites,
distribution size, privilege boundaries, testability, parity, contributor familiarity,
and migration risk. Preserve public behavior and state before changing defaults.

Non-goals: production deployment; public exposure of local demo services; replacing
supported Red Hat installers; bypassing native maintenance checks; plaintext retained
credentials; silent telemetry/uploads; or adding providers/addons faster than
reliability, qualification, and cleanup safeguards can support.
