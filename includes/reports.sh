#!/usr/bin/env bash
# Optional local reporting. Delivery defaults to a local capture mailbox; it
# never installs a mail relay or sends to the network by default.

if [ -n "${_AAP_DEMO_REPORTS_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_REPORTS_LOADED=1

_reports_dir() { printf '%s/reports' "${AAP_DEMO_DIR:-$HOME/.aap-demo}"; }

_reports_prepare_dir() {
  local directory
  directory=$(_reports_dir)
  (umask 077 && mkdir -p "$directory/outbox") || return 1
  chmod 700 "$directory" "$directory/outbox" || return 1
}

_reports_config() { printf '%s/config.json' "$(_reports_dir)"; }

_reports_atomic_write() {
  local destination="$1" temporary
  temporary=$(umask 077 && mktemp "${destination}.tmp.XXXXXX") || return 1
  if ! cat >"$temporary" || ! chmod 600 "$temporary" || ! mv -f "$temporary" "$destination"; then
    rm -f "$temporary"
    return 1
  fi
}

_reports_generate() {
  local timestamp report_dir tracking html text enabled
  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: reports requires python3" >&2
    return 1
  }
  _reports_prepare_dir || return 1
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  report_dir="$(_reports_dir)/$timestamp"
  (umask 077 && mkdir -p "$report_dir") || return 1
  chmod 700 "$report_dir"
  tracking="$report_dir/FIX_TRACKING.md"
  AAP_DEMO_STEWARD_TRACKING_FILE="$tracking" cmd_steward scan >&2 || return 1
  html="$report_dir/weekly-health-report.html"
  text="$report_dir/weekly-health-report.txt"
  enabled=$(_addons_list 2>/dev/null || true)
  if ! python3 "$SCRIPT_DIR/scripts/render-weekly-report.py" \
    --state "$(_steward_state_file)" --html "$html" --text "$text" \
    --enabled "$enabled" --available "${AVAILABLE_ADDONS:-}" --version "$(aap_demo_version_short)"; then
    rm -f "$report_dir/FIX_TRACKING.md" "$report_dir/weekly-health-report.html" \
      "$report_dir/weekly-health-report.txt"
    rmdir "$report_dir" 2>/dev/null || true
    return 1
  fi
  chmod 600 "$tracking" "$html" "$text"
  printf '%s\n' "$report_dir"
}

_reports_capture_email() {
  local report_dir="$1" outbox eml timestamp preferences
  preferences="$(_reports_dir)/preferences.json"
  if [ -f "$preferences" ] && ! jq -e '.capture_enabled == true' "$preferences" >/dev/null 2>&1; then
    echo "ERROR: Local report capture was declined during dashboard setup; reconfigure or zero-reset before enabling it." >&2
    return 1
  fi
  outbox="$(_reports_dir)/outbox"
  timestamp=$(basename "$report_dir")
  eml="$outbox/${timestamp}.eml"
  {
    printf 'From: aap-demo local reports <reports@localhost>\n'
    printf 'To: local capture mailbox\n'
    printf 'Subject: AAP Demo weekly health report\n'
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: multipart/alternative; boundary="aap-demo-report"\n\n'
    printf '%s\nContent-Type: text/plain; charset=UTF-8\n\n' '--aap-demo-report'
    cat "$report_dir/weekly-health-report.txt"
    printf '%s\nContent-Type: text/html; charset=UTF-8\n\n' '--aap-demo-report'
    cat "$report_dir/weekly-health-report.html"
    printf '%s--\n' '--aap-demo-report'
  } | _reports_atomic_write "$eml" || return 1
  printf '%s\n' "$eml"
}

_reports_send() {
  local report_dir eml
  report_dir=$(_reports_generate) || return 1
  eml=$(_reports_capture_email "$report_dir") || return 1
  echo "✓ Report captured locally: $eml"
  echo "  No network email was sent. Configure an approved SMTP relay in a future delivery phase."
}

cmd_reports() {
  local action="${1:-generate}" report_dir
  if [ "${MAINTENANCE_RECONFIGURE:-false}" = true ]; then
    action=reconfigure
  fi
  case "$action" in
    generate)
      report_dir=$(_reports_generate) || return 1
      echo "✓ HTML report: $report_dir/weekly-health-report.html"
      echo "✓ Plain-text report: $report_dir/weekly-health-report.txt"
      echo "  Open the HTML report in a browser and print it to PDF when needed."
      ;;
    send) _reports_send ;;
    reconfigure)
      _reports_prepare_dir || return 1
      rm -f -- "$(_reports_dir)/preferences.json" || return 1
      echo "✓ Local report-mail preferences cleared; the dashboard will ask once on its next visit."
      ;;
    help | --help | -h)
      cat <<'EOF'
Usage: aap-demo reports [generate|send] [--reconfigure]

generate  Run sanitized, read-only health collection and create HTML/text reports.
send      Generate the report and store an RFC 5322 .eml message in the local capture mailbox.
--reconfigure  Clear only the one-time local-mail preference; preserve captured reports.

No SMTP relay, recipient, schedule, LLM, MCP tool, repair, or vendor ticket is
configured by this command. It cannot send mail off the local machine.
EOF
      ;;
    *)
      echo "ERROR: Unknown reports action: $action (use generate or send)" >&2
      return 2
      ;;
  esac
}
