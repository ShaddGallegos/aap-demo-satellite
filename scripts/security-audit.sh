#!/usr/bin/env bash
# Read-only posture check for repository guardrails. It never reads Vault data.
set -euo pipefail

strict=false
[ "${1:-}" = "--strict" ] && strict=true
[ -z "${1:-}" ] || [ "${1:-}" = "--strict" ] || {
  echo "Usage: $0 [--strict]" >&2
  exit 2
}

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
warnings=0
passes=0

pass() {
  printf 'PASS  %s\n' "$*"
  passes=$((passes + 1))
}
warn() {
  printf 'WARN  %s\n' "$*"
  warnings=$((warnings + 1))
}

for path in \
  includes/credential-vault.sh \
  includes/operation-lock.sh \
  includes/kubeconfig-guard.sh \
  includes/ssh-trust.sh \
  .secrets.baseline \
  .pre-commit-config.yaml \
  .github/workflows/codeql.yaml; do
  [ -f "$path" ] && pass "required guardrail present: $path" || warn "missing guardrail: $path"
done

skill_count=$(find .claude/skills -name SKILL.md -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$skill_count" -gt 0 ] && pass "project skills discovered: $skill_count" || warn "no project skills discovered"

curl_insecure=$(git grep -nE 'curl[^\n]*(^|[[:space:]])-k([[:space:]]|$)|curl[^\n]*--insecure' -- '*.sh' '*.py' 2>/dev/null || true)
[ -z "$curl_insecure" ] || warn "TLS verification bypasses require documented local-lab justification ($(printf '%s\n' "$curl_insecure" | wc -l | tr -d ' ') occurrence(s))"

cli_secrets=$(git grep -nE -- '--(password|token|upstream-password|ansible-collection-auth-token)[=[:space:]]*\$' -- '*.sh' 2>/dev/null || true)
[ -z "$cli_secrets" ] || warn "review command-line secret arguments; prefer stdin, files, or credential objects ($(printf '%s\n' "$cli_secrets" | wc -l | tr -d ' ') occurrence(s))"

if [ -f includes/ssh-trust.sh ] \
  && grep -q 'AAP_DEMO_SSH_TRUST_MODE' includes/ssh-trust.sh; then
  pass 'managed SSH trust supports fingerprint verification and strict mode'
else
  warn 'managed SSH trust has no fingerprint-verification control'
fi

git grep -q 'StrictHostKeyChecking=accept-new' -- '*.sh' 2>/dev/null \
  && warn 'some SSH paths retain local-lab TOFU; use AAP_DEMO_SSH_TRUST_MODE=verify for fingerprint-pinned first use' \
  || pass 'no SSH accept-new use detected'

if command -v detect-secrets >/dev/null 2>&1; then
  scanner_version=$(detect-secrets --version 2>&1 | head -n1)
  case "$scanner_version" in
    *1.5.0*) pass 'pinned detect-secrets scanner is available; run scripts/check-secrets.sh for the full baseline comparison' ;;
    *) warn "detect-secrets 1.5.0 is required for the baseline comparison (found: ${scanner_version})" ;;
  esac
else
  warn 'detect-secrets is unavailable; install the pinned development tooling before release validation'
fi

printf 'Summary: %s pass, %s warning(s)\n' "$passes" "$warnings"
if [ "$strict" = true ] && [ "$warnings" -gt 0 ]; then
  exit 1
fi
exit 0
