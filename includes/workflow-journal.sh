#!/usr/bin/env bash

if [ -n "${_AAP_DEMO_WORKFLOW_JOURNAL_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_WORKFLOW_JOURNAL_LOADED=1

_workflow_write() {
  local tmp
  tmp=$(
    umask 077
    mktemp "${_WORKFLOW_JOURNAL}.tmp.XXXXXX"
  ) || return 1
  if ! jq "$@" "$_WORKFLOW_JOURNAL" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$_WORKFLOW_JOURNAL"; then
    rm -f "$tmp"
    return 1
  fi
}

workflow_begin() {
  local name="$1" dir environment
  case "$name" in full-demo | satellite | satellite-manifest | satellite-cloud-connector) ;; *) return 1 ;; esac
  dir="${AAP_DEMO_DIR:-$HOME/.aap-demo}/workflow-journals"
  if ! (
    umask 077
    mkdir -p "$dir" && chmod 700 "$dir"
  ); then
    echo "ERROR: Cannot create private workflow journal directory." >&2
    return 1
  fi
  _WORKFLOW_JOURNAL=$(
    umask 077
    mktemp "$dir/$name.XXXXXX"
  ) || {
    echo "ERROR: Cannot create workflow journal." >&2
    return 1
  }
  environment="${AAP_DEMO_WORKFLOW_ENVIRONMENT:-local}"
  if ! jq -n --arg name "$name" --arg time "$(date -u +%FT%TZ)" \
    --arg environment "$environment" \
    '{workflow:$name, environment:$environment, started:$time, status:"running", phases:[], warnings:[]}' >"$_WORKFLOW_JOURNAL"; then
    echo "ERROR: Cannot initialize workflow journal: $_WORKFLOW_JOURNAL" >&2
    return 1
  fi
  echo "Progress journal: $_WORKFLOW_JOURNAL"
}

_workflow_color_enabled() {
  case "${AAP_DEMO_COLOR:-auto}" in
    always) return 0 ;;
    never) return 1 ;;
    auto | '') [ -t 1 ] || [ -t 2 ] ;;
    *) return 1 ;;
  esac
}

workflow_warning() {
  local type="${1:-warning}" message
  shift || true
  message="$*"
  case "$type" in warning | improvement) ;; *) return 2 ;; esac
  [ -n "$message" ] || return 2
  _workflow_write --arg type "$type" --arg message "$message" \
    --arg time "$(date -u +%FT%TZ)" \
    '.warnings += [{type:$type, message:$message, time:$time}]' || return 1
  printf '%s: %s\n' "${type^}" "$message" >&2
}

workflow_report() {
  local journal="${1:-${_WORKFLOW_JOURNAL:-}}" red='' yellow='' reset=''
  [ -n "$journal" ] && [ -r "$journal" ] || return 1
  if _workflow_color_enabled; then
    red=$'\033[31m'
    yellow=$'\033[33m'
    reset=$'\033[0m'
  fi
  jq -r --arg red "$red" --arg yellow "$yellow" --arg reset "$reset" '
    def duration:
      floor as $seconds |
      "\(($seconds / 3600 | floor))h \((($seconds % 3600) / 60 | floor))m \($seconds % 60)s";
    def elapsed($start; $finish):
      (($finish | fromdateiso8601) - ($start | fromdateiso8601)) | duration;
    def status_label($status):
      if $status == "failed" then "\($red)\($status)\($reset)"
      elif $status == "warning" then "\($yellow)\($status)\($reset)"
      else $status end;
    "",
    "=== aap-demo deployment summary ===",
    "Workflow: \(.workflow)  |  Environment: \(.environment // "local")",
    "Result: \(status_label(.status))  |  Total time: \(elapsed(.started; .finished))",
    "Started: \(.started)  |  Finished: \(.finished)",
    "Phases:",
    (.phases[] | "  \(.name): \(status_label(.status)) — \(elapsed(.started; .finished))"),
    if (.warnings // [] | length) > 0 then
      "\($yellow)Warnings and improvements:\($reset)",
      (.warnings[] | "\($yellow)  [\(.type)] \(.message)\($reset)")
    else empty end,
    "Journal: \($journal)"
  ' --arg journal "$journal" "$journal"
}

_workflow_phase_elapsed() {
  local elapsed="$1"
  printf '%02dm%02ds' "$((elapsed / 60))" "$((elapsed % 60))"
}

_workflow_progress_interactive() {
  [ "${AAP_DEMO_PROGRESS:-auto}" != off ] && [ -t 1 ]
}

_workflow_spinner_start() {
  local name="$1" started="$2"
  _workflow_progress_interactive || return 0
  (
    local frames='|/-\' frame=0 elapsed
    trap 'exit 0' INT TERM EXIT
    while :; do
      elapsed=$((SECONDS - started))
      printf '\r  [%s] %s in progress (%s)' "${frames:frame++%${#frames}:1}" \
        "$name" "$(_workflow_phase_elapsed "$elapsed")" >&2
      sleep 0.2
    done
  ) &
  _WORKFLOW_SPINNER_PID=$!
}

_workflow_spinner_stop() {
  local name="$1" started="$2" status="$3" elapsed
  elapsed=$((SECONDS - started))
  if [ -n "${_WORKFLOW_SPINNER_PID:-}" ]; then
    kill "$_WORKFLOW_SPINNER_PID" 2>/dev/null || true
    wait "$_WORKFLOW_SPINNER_PID" 2>/dev/null || true
    _WORKFLOW_SPINNER_PID=""
    printf '\r\033[K' >&2
  fi
  if [ "$status" = succeeded ]; then
    printf '  ✓ %s completed in %s\n' "$name" "$(_workflow_phase_elapsed "$elapsed")" >&2
  else
    printf '  ✗ %s failed after %s\n' "$name" "$(_workflow_phase_elapsed "$elapsed")" >&2
  fi
}

workflow_phase() {
  local name="$1" rc=0 started status
  shift
  if ! _workflow_write --arg name "$name" --arg time "$(date -u +%FT%TZ)" \
    '.phases += [{name:$name, started:$time, status:"running"}]'; then
    echo "ERROR: Cannot record workflow phase start." >&2
    return 1
  fi
  started=$SECONDS
  # Progress is stderr because selected phases return a small machine value
  # through stdout (for example the Satellite installation state).
  printf '  ▸ %s in progress\n' "$name" >&2
  _workflow_spinner_start "$name" "$started"
  "$@" || rc=$?
  status="$([ "$rc" -eq 0 ] && echo succeeded || echo failed)"
  _workflow_spinner_stop "$name" "$started" "$status"
  if ! _workflow_write --arg status "$status" \
    --arg time "$(date -u +%FT%TZ)" \
    '.phases[-1].status=$status | .phases[-1].finished=$time |
     if $status == "failed" then .status="failed" | .finished=$time else . end'; then
    echo "ERROR: Cannot record workflow phase result; inspect the environment before retrying." >&2
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: Phase $name failed. Inspect its output and current state before retrying." >&2
    workflow_report >&2 || true
  fi
  return "$rc"
}

workflow_finish() {
  if ! _workflow_write --arg time "$(date -u +%FT%TZ)" \
    '.status="succeeded" | .finished=$time'; then
    echo "ERROR: Cannot record workflow completion." >&2
    return 1
  fi
  workflow_report
}
