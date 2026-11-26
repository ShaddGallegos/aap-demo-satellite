#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output=$(bash "$ROOT/scripts/security-audit.sh")
grep -q 'required guardrail present: includes/credential-vault.sh' <<<"$output"
grep -q 'required guardrail present: includes/operation-lock.sh' <<<"$output"
grep -q 'required guardrail present: includes/ssh-trust.sh' <<<"$output"
grep -q 'managed SSH trust supports fingerprint verification and strict mode' <<<"$output"
grep -q 'project skills discovered:' <<<"$output"
grep -q '^Summary: ' <<<"$output"
echo 'PASS: security audit reports repository guardrails without reading credentials'
