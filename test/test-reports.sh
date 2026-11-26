#!/usr/bin/env bash
# Regression tests for capture-first weekly reports.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export AAP_DEMO_DIR="$TEST_DIR/state"
export SCRIPT_DIR="$ROOT"
AVAILABLE_ADDONS='ao mcp-server lightspeed fleet'

# shellcheck source=../includes/steward.sh
source "$ROOT/includes/steward.sh"
# shellcheck source=../includes/reports.sh
source "$ROOT/includes/reports.sh"

aap_demo_version_short() { printf '%s' 'test-version'; }
_addons_list() { printf '%s\n' 'ao fleet'; }

cmd_steward() {
  local state="${AAP_DEMO_DIR}/steward/state.json" tracking="${AAP_DEMO_STEWARD_TRACKING_FILE:?}"
  mkdir -p "$(dirname "$state")"
  printf '%s\n' '{"schema_version":1,"last_scan":"2026-11-25T00:00:00Z","issues":[{"id":"STW-fixture","severity":"high","source":"diagnose","status":"open","last_seen":"2026-11-25T00:00:00Z","summary":"API unavailable"}]}' >"$state"
  printf '%s\n' '<!-- aap-demo-steward: v1 -->' >"$tracking"
  printf '%s\n' 'steward fixture output'
}

report_dir=$(_reports_generate)
[ -f "$report_dir/weekly-health-report.html" ]
[ -f "$report_dir/weekly-health-report.txt" ]
[ "$(stat -c '%a' "$report_dir/weekly-health-report.html")" = 600 ]
grep -Fq 'AAP Demo weekly health report' "$report_dir/weekly-health-report.html"
grep -Fq 'API unavailable' "$report_dir/weekly-health-report.html"
grep -Fq 'mcp-server' "$report_dir/weekly-health-report.html"

_reports_send >"$TEST_DIR/send-output"
eml=$(sed -n 's/^✓ Report captured locally: //p' "$TEST_DIR/send-output")
[ -f "$eml" ]
[ "$(stat -c '%a' "$eml")" = 600 ]
grep -Fq 'Content-Type: text/html' "$eml"
grep -Fq 'API unavailable' "$eml"

printf '%s\n' '{"capture_enabled":false}' >"$AAP_DEMO_DIR/reports/preferences.json"
if _reports_capture_email "$report_dir" >/dev/null 2>&1; then
  echo 'FAIL: local mail capture ignored the one-time opt-out preference' >&2
  exit 1
fi
MAINTENANCE_RECONFIGURE=true cmd_reports >"$TEST_DIR/reconfigure-output"
grep -Fq 'preferences cleared' "$TEST_DIR/reconfigure-output"
[ ! -e "$AAP_DEMO_DIR/reports/preferences.json" ]

echo 'PASS: weekly reports are formatted, private, and captured locally without SMTP delivery'
