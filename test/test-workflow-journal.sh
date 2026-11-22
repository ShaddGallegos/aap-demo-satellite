#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
AAP_DEMO_DIR="$TEST_DIR/state"
source "$ROOT/includes/workflow-journal.sh"

workflow_begin full-demo >"$TEST_DIR/output"
successful="$_WORKFLOW_JOURNAL"
workflow_phase prepare true >"$TEST_DIR/phase-output" 2>&1
grep -Fq 'prepare in progress' "$TEST_DIR/phase-output"
grep -Fq 'prepare completed in' "$TEST_DIR/phase-output"
workflow_phase configure printf '%s' 'private-argument' >/dev/null
workflow_warning improvement 'A reusable image cache would reduce future setup time'
summary=$(AAP_DEMO_COLOR=always workflow_finish)
jq -e '.status == "succeeded" and (.phases | length == 2) and
  all(.phases[]; .status == "succeeded" and .finished != null)' "$successful" >/dev/null
! grep -q 'private-argument' "$successful"
grep -Fq '=== aap-demo deployment summary ===' <<<"$summary"
grep -Fq 'Total time:' <<<"$summary"
grep -Fq 'prepare: succeeded' <<<"$summary"
grep -Fq $'\033[33mWarnings and improvements:' <<<"$summary"
grep -Fq '[improvement] A reusable image cache' <<<"$summary"
file_mode=$(stat -c '%a' "$successful" 2>/dev/null || stat -f '%Lp' "$successful")
dir_mode=$(stat -c '%a' "$AAP_DEMO_DIR/workflow-journals" 2>/dev/null || stat -f '%Lp' "$AAP_DEMO_DIR/workflow-journals")
[ "$file_mode" = 600 ]
[ "$dir_mode" = 700 ]

workflow_begin satellite >"$TEST_DIR/output"
failed="$_WORKFLOW_JOURNAL"
if AAP_DEMO_COLOR=always workflow_phase maintenance false 2>"$TEST_DIR/error"; then
  echo "FAIL: a failed phase returned success" >&2
  exit 1
fi
jq -e '.status == "failed" and .phases[-1].status == "failed"' "$failed" >/dev/null
grep -q 'Inspect its output and current state' "$TEST_DIR/error"
grep -Fq $'\033[31mfailed\033[0m' "$TEST_DIR/error"

(
  workflow_begin satellite >"$TEST_DIR/output"
  printf '%s' "$_WORKFLOW_JOURNAL" >"$TEST_DIR/interrupted-path"
  interrupt() { kill -TERM "$BASHPID"; }
  workflow_phase installer interrupt
) || true
interrupted=$(cat "$TEST_DIR/interrupted-path")
jq -e '.status == "running" and .phases[-1].status == "running"' "$interrupted" >/dev/null

workflow_begin satellite >"$TEST_DIR/output"
retry="$_WORKFLOW_JOURNAL"
workflow_phase installer true
workflow_finish
[ "$retry" != "$interrupted" ]
jq -e '.status == "running"' "$interrupted" >/dev/null

(
  workflow_begin full-demo >"$TEST_DIR/output"
  _workflow_write() { return 1; }
  if workflow_phase installer touch "$TEST_DIR/should-not-exist" 2>"$TEST_DIR/error"; then
    exit 1
  fi
  [ ! -e "$TEST_DIR/should-not-exist" ]
)
grep -q 'Cannot record workflow phase start' "$TEST_DIR/error"
echo "PASS: private journals preserve success, failure and interrupted attempts without arguments"
