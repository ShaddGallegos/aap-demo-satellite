#!/usr/bin/env bash
# Verify non-destructive validation runs on pull requests while workflows that
# publish, mutate host trust, update badges, or perform CodeQL remain manual.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow_dir="$repo_root/.github/workflows"

failures=0
for workflow in lint.yaml test.yaml python-tests.yaml version-check.yaml commitlint.yaml pr-checks.yaml; do
    workflow="$workflow_dir/$workflow"
    if ! grep -Eq '^[[:space:]]*workflow_dispatch:' "$workflow"; then
        printf 'FAIL: %s has no manual workflow_dispatch trigger\n' "$workflow" >&2
        failures=1
    fi
    if ! grep -Eq '^[[:space:]]*pull_request:' "$workflow"; then
        printf 'FAIL: %s does not run on pull requests\n' "$workflow" >&2
        failures=1
    fi
done

for workflow in codeql.yaml host-trust.yaml pypi-publish.yaml status-badges.yaml; do
    workflow="$workflow_dir/$workflow"
    if ! grep -Eq '^[[:space:]]*workflow_dispatch:' "$workflow"; then
        printf 'FAIL: %s has no manual workflow_dispatch trigger\n' "$workflow" >&2
        failures=1
    fi
    if grep -Eq '^[[:space:]]*(push|pull_request|pull_request_target|schedule|repository_dispatch|workflow_call):' "$workflow"; then
        printf 'FAIL: %s has an unsafe automatic workflow trigger\n' "$workflow" >&2
        failures=1
    fi
done

if ((failures)); then
    exit 1
fi

printf 'PASS: GitHub Actions separates PR-safe validation from manual-only workflows\n'
