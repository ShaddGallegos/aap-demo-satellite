---
name: aap-release-validation
description: >
  Prepare aap-demo changes for publication with scoped tests, changelog and
  documentation checks, offline secret scanning, and branch/PR verification.
  Use for pre-push checks, release readiness, or requested commits and PRs.
---

# AAP release validation

## Establish publication scope

Read [CONTRIBUTING](../../../CONTRIBUTING.md),
[linting guidance](../../../docs/LINTING.md), and
[the PR template](../../../.github/PULL_REQUEST_TEMPLATE.md).
Inspection does not authorize committing, pushing, merging, or releasing.
Perform those operations only when requested.

1. Inspect worktree/staged changes, branch, remote URLs, and recent commits.
   Do not discard unrelated edits or include them without authorization.
2. Distinguish the Bash CLI from the Python package. Do not bump versions
   or publish PyPI packages for an ordinary documentation or bugfix PR.
3. Determine the intended repository and base explicitly. Multiple remotes
   can cause `gh` to select upstream unexpectedly. Pass `-R owner/repo` to
   GitHub operations after confirming the destination.
4. When publication is requested, fetch the selected base and inspect
   divergence and the complete PR diff, not just uncommitted changes.
   Report inherited commits and conflicts. Never force-push, merge, or
   rebase merely to make a PR appear clean without authorization.

## Validate

- Select the smallest existing tests covering changed behavior. For Python,
  follow the pytest/Ruff checks in CONTRIBUTING; for Bash, use focused
  scripts under `test/`, syntax checks, and repository ShellCheck settings.
- Lint modified Markdown. Ensure changelog claims distinguish automated
  tests, actual live evidence, and untested/destructive scenarios.
- Use the existing secret scanner and baseline with network verification
  disabled (`--no-verify`). Do not send candidate credentials for external
  verification. Review findings without exposing values. Do not suppress
  a real finding or regenerate the baseline just to pass.
- Inspect staged changes and run `git diff --check`. Verify only intended
  files are staged. Preserve directly related user edits.

## Requested publication

Use the required Conventional Commit format, signoff, and applicable coauthor
trailer. Push normally to the confirmed remote/branch. Use the PR template
and record exact tests, failures, limitations, and live validation scope.
Update an existing matching PR rather than creating a duplicate.

Verify the remote branch hash equals the intended local commit, the PR has
the correct repository/base/head, and the worktree state is understood.
Check mergeability and CI results separately; creating a PR does not mean
it is mergeable, tested by CI, merged, or released.

Return the commit and PR link plus remaining blockers. Do not disclose
credentials, attach private diagnostic logs, or claim unrun checks passed.
