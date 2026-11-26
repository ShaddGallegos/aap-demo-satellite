#!/usr/bin/env bash
# Local, read-only operations-tracking foundation.  It deliberately does not
# invoke an LLM/MCP server, remediate anything, schedule work, or contact vendors.

if [ -n "${_AAP_DEMO_STEWARD_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_STEWARD_LOADED=1

_steward_dir() {
  printf '%s' "${AAP_DEMO_STEWARD_DIR:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/steward}"
}

_steward_prepare_dir() {
  local dir
  dir=$(_steward_dir)
  (umask 077 && mkdir -p "$dir/reports") || return 1
  chmod 700 "$dir" "$dir/reports" || return 1
}

_steward_state_file() { printf '%s/state.json' "$(_steward_dir)"; }

_steward_tracking_file() {
  if [ -n "${AAP_DEMO_STEWARD_TRACKING_FILE:-}" ]; then
    printf '%s' "$AAP_DEMO_STEWARD_TRACKING_FILE"
  elif [ -n "${SYSTEM_INFO_OUTPUT:-}" ]; then
    printf '%s' "$SYSTEM_INFO_OUTPUT"
  else
    printf '%s/FIX_TRACKING.md' "$PWD"
  fi
}

_steward_atomic_write() {
  local destination="$1" temporary
  temporary=$(umask 077 && mktemp "${destination}.tmp.XXXXXX") || return 1
  if ! cat >"$temporary" || ! chmod 600 "$temporary" || ! mv -f "$temporary" "$destination"; then
    rm -f "$temporary"
    return 1
  fi
}

_steward_sanitize_file() {
  local raw="$1" sanitized="$2"
  python3 "$SCRIPT_DIR/scripts/sanitize-steward-report.py" "$raw" | _steward_atomic_write "$sanitized"
}

_steward_issue_id() {
  local source="$1" summary="$2" digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s\t%s' "$source" "$summary" | sha256sum | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s\t%s' "$source" "$summary" | shasum -a 256 | awk '{print $1}')
  else
    digest=$(printf '%s\t%s' "$source" "$summary" | cksum | awk '{print $1}')
  fi
  printf 'STW-%s' "${digest:0:12}"
}

_steward_add_finding() {
  local findings="$1" source="$2" severity="$3" summary="$4" id
  summary=$(printf '%s' "$summary" | tr '\n\r\t' '   ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$summary" ] || return 0
  id=$(_steward_issue_id "$source" "$summary")
  jq -cn --arg id "$id" --arg source "$source" --arg severity "$severity" \
    --arg summary "$summary" '{id:$id,source:$source,severity:$severity,summary:$summary}' >>"$findings"
  printf '\n' >>"$findings"
}

_steward_extract_findings() {
  local source="$1" report="$2" findings="$3" line summary found=false
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '  ✗ '* | '✗ '*) summary="${line#*✗ }"; _steward_add_finding "$findings" "$source" high "$summary"; found=true ;;
      '  ⚠ '* | '⚠ '*) summary="${line#*⚠ }"; _steward_add_finding "$findings" "$source" warning "$summary"; found=true ;;
      FAIL[[:space:]]*) summary="${line#FAIL }"; _steward_add_finding "$findings" "$source" high "$summary"; found=true ;;
      ERROR:*) summary="${line#ERROR:}"; _steward_add_finding "$findings" "$source" high "$summary"; found=true ;;
    esac
  done <"$report"
  "$found"
}

_steward_capture() {
  local source="$1" findings="$2" timestamp="$3" raw report rc=0
  shift 3
  raw=$(umask 077 && mktemp "$(_steward_dir)/reports/${timestamp}-${source}.raw.XXXXXX") || return 1
  trap 'rm -f "$raw"' EXIT HUP INT TERM
  report="$(_steward_dir)/reports/${timestamp}-${source}.txt"
  if "$@" >"$raw" 2>&1; then rc=0; else rc=$?; fi
  if ! _steward_sanitize_file "$raw" "$report"; then
    rm -f "$raw"
    trap - EXIT HUP INT TERM
    echo "ERROR: Cannot sanitize steward evidence for $source" >&2
    return 1
  fi
  rm -f "$raw"
  trap - EXIT HUP INT TERM
  if ! _steward_extract_findings "$source" "$report" "$findings" && [ "$rc" -ne 0 ]; then
    _steward_add_finding "$findings" "$source" high "inspection command returned exit code $rc"
  fi
  printf '%s\n' "$report"
}

_steward_initialize_state() {
  local state="$1"
  [ -f "$state" ] && return 0
  jq -n '{schema_version:1,issues:[]}' | _steward_atomic_write "$state"
}

_steward_update_state() {
  local findings="$1" timestamp="$2" evidence="$3" state temporary normalized current_ids
  state=$(_steward_state_file)
  _steward_initialize_state "$state" || return 1
  temporary=$(umask 077 && mktemp "${state}.tmp.XXXXXX") || return 1
  normalized=$(umask 077 && mktemp "$(_steward_dir)/findings-normalized.XXXXXX") || { rm -f "$temporary"; return 1; }
  if ! jq -s 'unique_by(.id)' "$findings" >"$normalized"; then
    rm -f "$temporary" "$normalized"
    return 1
  fi
  current_ids=$(jq '[.[].id]' "$normalized") || { rm -f "$temporary" "$normalized"; return 1; }
  if ! jq --slurpfile fresh "$normalized" --arg now "$timestamp" --arg evidence "$evidence" \
    --argjson current_ids "$current_ids" '
      def current($id): $current_ids | index($id) != null;
      .schema_version = 1 |
      .issues = [.issues[] as $old |
        if current($old.id) then
          ($fresh[0][] | select(.id == $old.id)) as $new |
          $old + $new + {first_seen:($old.first_seen // $now),last_seen:$now,
            occurrences:(($old.occurrences // 0) + 1),status:"open",evidence:$evidence}
        elif $old.status == "open" then $old + {status:"watch"} else $old end
      ] |
      reduce $fresh[0][] as $new (.;
        if any(.issues[]; .id == $new.id) then .
        else .issues += [$new + {first_seen:$now,last_seen:$now,occurrences:1,status:"open",evidence:$evidence}] end
      ) | .last_scan = $now
    ' "$state" >"$temporary"; then
    rm -f "$temporary" "$normalized"
    return 1
  fi
  rm -f "$normalized"
  chmod 600 "$temporary" && mv -f "$temporary" "$state"
}

_steward_render_tracking() {
  local tracking="$1" state
  state=$(_steward_state_file)
  if [ -e "$tracking" ] && ! grep -Fq '<!-- aap-demo-steward: v1 -->' "$tracking"; then
    echo "ERROR: Refusing to overwrite unowned tracking file: $tracking" >&2
    return 1
  fi
  jq -r '
    def rows($issues): $issues[] | "| \(.id) | \(.severity) | \(.source) | \(.first_seen) | \(.last_seen) | \(.occurrences) | \(.summary | gsub("\\|"; "\\\\|")) |";
    "<!-- aap-demo-steward: v1 -->", "# Fix tracking", "",
    "Generated from sanitized, local read-only inspection evidence. This file contains no credentials and does not authorize a repair, scheduled action, LLM request, MCP tool call, or vendor ticket.", "",
    "Last scan: \(.last_scan // "not yet scanned")", "", "## Open findings", "",
    "| ID | Severity | Source | First seen | Last seen | Occurrences | Summary |", "| --- | --- | --- | --- | --- | --- | --- |",
    (if ([.issues[] | select(.status == "open")] | length) == 0 then "| — | — | — | — | — | — | No open findings. |" else rows([.issues[] | select(.status == "open")]) end),
    "", "## Watching", "", "| ID | Severity | Source | First seen | Last seen | Occurrences | Summary |", "| --- | --- | --- | --- | --- | --- | --- |",
    (if ([.issues[] | select(.status == "watch")] | length) == 0 then "| — | — | — | — | — | — | No deferred findings. |" else rows([.issues[] | select(.status == "watch")]) end),
    "", "## Safety boundary", "",
    "Evidence is stored privately under the local aap-demo state directory. Review a finding before any repair. Future LLM, MCP, scheduler, remediation, advisory-watch, or vendor-ticket features must be separately enabled and approval-gated."
  ' "$state" | _steward_atomic_write "$tracking"
}

_steward_scan() {
  local timestamp findings report tracking
  command -v jq >/dev/null 2>&1 || { echo "ERROR: steward requires jq" >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "ERROR: steward requires python3 for local report redaction" >&2; return 1; }
  _steward_prepare_dir || { echo "ERROR: Cannot create private steward state directory" >&2; return 1; }
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  findings=$(umask 077 && mktemp "$(_steward_dir)/findings.XXXXXX") || return 1
  : >"$findings"
  echo "Operations steward (read-only; no LLM, MCP, repairs, scheduler, or vendor tickets)"
  report=$(_steward_capture preflight "$findings" "$timestamp" cmd_preflight) || { rm -f "$findings"; return 1; }
  echo "  ✓ Sanitized preflight evidence: ${report##*/}"
  report=$(_steward_capture diagnose "$findings" "$timestamp" cmd_diagnose) || { rm -f "$findings"; return 1; }
  echo "  ✓ Sanitized diagnosis evidence: ${report##*/}"
  report=$(_steward_capture integrations "$findings" "$timestamp" cmd_check_integrations) || { rm -f "$findings"; return 1; }
  echo "  ✓ Sanitized integration evidence: ${report##*/}"
  _steward_update_state "$findings" "$timestamp" "$timestamp" || { rm -f "$findings"; echo "ERROR: Cannot update private steward state" >&2; return 1; }
  tracking=$(_steward_tracking_file)
  _steward_render_tracking "$tracking" || { rm -f "$findings"; return 1; }
  rm -f "$findings"
  echo "✓ Tracking report: $tracking"
  echo "✓ Private sanitized evidence: $(_steward_dir)/reports"
}

cmd_steward() {
  local action="${1:-scan}" tracking
  case "$action" in
    scan) _steward_scan ;;
    report)
      _steward_prepare_dir || return 1
      [ -f "$(_steward_state_file)" ] || { echo "ERROR: No steward scan exists yet; run: aap-demo steward scan" >&2; return 1; }
      tracking=$(_steward_tracking_file)
      _steward_render_tracking "$tracking" || return 1
      echo "✓ Tracking report: $tracking"
      ;;
    help | --help | -h)
      cat <<'EOF'
Usage: aap-demo steward [scan|report] [--output FILE]

scan    Run approved read-only local checks, redact stored evidence, and update tracking.
report  Render the last private scan into FIX_TRACKING.md without contacting services.

The steward does not use an LLM or MCP, make repairs, install a scheduler,
watch external advisory feeds, or create vendor tickets. Evidence stays local
under ~/.aap-demo/steward (or $AAP_DEMO_STEWARD_DIR).
EOF
      ;;
    *) echo "ERROR: Unknown steward action: $action (use scan or report)" >&2; return 2 ;;
  esac
}
