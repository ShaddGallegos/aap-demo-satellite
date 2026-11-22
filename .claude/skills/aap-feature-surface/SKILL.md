---
name: aap-feature-surface
description: Keep aap-demo feature changes consistent across CLI help, examples, indexed documentation, dashboard controls, and focused tests. Use when adding or changing a user-visible command, profile, addon, setting, prompt, or dashboard action.
---

# AAP feature surface

Use this workflow after implementing a user-visible aap-demo feature or fix.
It reconciles the user-facing surface with the actual implementation; it does
not authorize live deployment, external service changes, or unrelated cleanup.

## Discover the affected surface

Read the implementation and identify the actual command syntax, dependencies,
defaults, safety boundaries, prompts, and idempotency behavior. Then review
only the surfaces that expose that behavior:

- CLI parser and help: `aap-demo.sh`, `includes/help.sh`, and the relevant
  parser/help tests.
- Quick start: `README.md`. Keep it concise and link to longer material.
- Long-form documentation: choose the relevant indexed page under `docs/`,
  preserve its front matter, and update `docs/index.md` only for a new page.
- Addon or Satellite documentation when the feature belongs there.
- Dashboard catalog, server, and UI when a dashboard card, status, route, or
  action exposes the feature.
- `docs/ROADMAP.md` and `docs/CHANGELOG.md` when the feature completes a
  tracked roadmap item or the repository's existing changelog convention calls
  for an entry.

Do not claim a component is available merely because a parser recognizes a
flag. Describe required credentials, hardware, licenses, external prerequisites,
or explicit opt-ins at the closest user decision point.

## Prompts and sensitive configuration

For values that must be supplied interactively, make the normal TTY path prompt
before the first dependent action. Environment variables supplied by an operator
or automation take precedence and must keep noninteractive runs non-blocking.
Never place secrets in help text, examples, dashboard responses, command-line
arguments, tests, or repository files. Store supported sensitive values through
the encrypted Vault workflow and document only their variable names and purpose.

An opt-in for licensed, external, or potentially mutating content must explain
what it changes, require affirmative acknowledgement, and remain explicit in
automation. Do not silently turn a declined opt-in into a default on rerun.

## Dashboard behavior

Dashboard controls must match CLI safety semantics. Do not present a generic
enable/configure control when a feature needs acknowledgement or extra
prerequisites. Use a clear label, collect the acknowledgement client-side, and
enforce it again server-side. Scope any enablement environment variable to that
one operation unless persistence is an explicit product requirement.

Operation output must remain safe for browser display: redact credentials and
remove terminal control sequences. Dashboard checks must be read-only unless a
user deliberately invokes a mutating control.

## Verify proportionately

At minimum, run syntax checks and the focused parser/help tests for a CLI change.
For dashboard changes, run the dashboard test suite and route/UI test. For
documentation-only edits, lint the changed Markdown files when the linter is
available. Run `git diff --check` before handing off.

Report which surfaces changed, what was verified, and any intentionally unrun
live action. Do not call a live component healthy without evidence.
