#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AAP_DEMO_SH="$REPO_ROOT/aap-demo.sh"
LOG_FILE=$(mktemp)
AAP_DEMO_DIR=$(mktemp -d)
trap 'rm -f "$LOG_FILE" "$LOG_FILE.output"; rm -rf "$AAP_DEMO_DIR"' EXIT
source "$REPO_ROOT/includes/workflow-journal.sh"

cmd_create() {
  printf 'create quiet=%s addons=%s\n' "$QUIET" "$ADDONS" >>"$LOG_FILE"
}

cmd_start() {
  printf 'start-existing\n' >>"$LOG_FILE"
}

aap_demo_service_managed() {
  [ "${MANAGED_DEMO:-false}" = true ]
}

# shellcheck disable=SC2329
infra_get_state() {
  printf 'not_created'
}

cmd_deploy() {
  printf 'deploy skip_ao=%s\n' "${AAP_DEMO_SKIP_STANDARD_AO:-false}" >>"$LOG_FILE"
}

cmd_enable() {
  printf 'enable %s provider=%s\n' "$1" "${AO_LLM_PROVIDER:-unset}" >>"$LOG_FILE"
}

cmd_fleet() {
  printf 'fleet %s\n' "$*" >>"$LOG_FILE"
  if [ "${1:-}" = auth ] && [ "${2:-}" = status ] \
    && [ "${FLEET_AUTH_CONFIGURED:-true}" != true ]; then
    return 1
  fi
  if [ "${1:-}" = auth ] && [ "${2:-}" = configure ]; then
    FLEET_AUTH_CONFIGURED=true
  fi
}

cmd_credentials() {
  printf 'credentials %s\n' "$*" >>"$LOG_FILE"
}

# shellcheck disable=SC2329
fleet_count() {
  printf '0'
}

cmd_wire() {
  printf 'wire\n' >>"$LOG_FILE"
}

aap_demo_generate_system_info() {
  printf 'system-info\n' >>"$LOG_FILE"
}

_aap_demo_release_operation_lock() {
  printf 'release-lock\n' >>"$LOG_FILE"
}

cmd_service() {
  printf 'service %s\n' "$*" >>"$LOG_FILE"
  [ "${FAIL_SERVICE_INSTALL:-false}" != true ]
}

cmd_dashboard() {
  printf 'dashboard\n' >>"$LOG_FILE"
  [ "${FAIL_DASHBOARD:-false}" != true ]
}

_aap_demo_auto_console() {
  printf 'console\n' >>"$LOG_FILE"
}

# Overridable satellite helpers (mirror the defaults in aap-demo.sh).
_full_demo_satellite_build() {
  printf 'satellite build-and-configure\n' >>"$LOG_FILE"
  [ "${FAIL_SATELLITE_BUILD:-false}" != true ]
}

_full_demo_lightwell_preflight() {
  printf 'lightwell preflight\n' >>"$LOG_FILE"
  [ "${FAIL_LIGHTWELL_PREFLIGHT:-false}" != true ]
}

_full_demo_lightwell_enable() {
  cmd_enable lightwell
}

_full_demo_gitea_preflight() {
  printf 'gitea preflight\n' >>"$LOG_FILE"
  [ "${FAIL_GITEA_PREFLIGHT:-false}" != true ]
}

# The test evaluates cmd_full_demo in isolation.  Keep interactive prompts out
# of the orchestration-order assertions; their presence is checked below.
_full_demo_prompt_rhis_templates() {
  :
}

full_demo_function=$(sed -n '/^cmd_full_demo()/,/^}$/p' "$AAP_DEMO_SH")
# cmd_full_demo references FULL_DEMO_SATELLITE (set by aap-demo.sh arg parsing);
# default it here so the extracted function runs under `set -u`.
FULL_DEMO_SATELLITE="${FULL_DEMO_SATELLITE:-false}"
FULL_DEMO_GITEA="${FULL_DEMO_GITEA:-false}"
FULL_DEMO_LIGHTSPEED="${FULL_DEMO_LIGHTSPEED:-false}"
FULL_DEMO_LIGHTWELL="${FULL_DEMO_LIGHTWELL:-false}"
eval "$full_demo_function"
managed_guard=$(sed -n '/^if aap_demo_service_managed; then$/,/^fi$/p' "$AAP_DEMO_SH")
_err() { printf 'ERROR: %s\n' "$*" >&2; }
(
  uname() { echo Linux; }
  MANAGED_DEMO=true COMMAND=create FULL_DEMO=true eval "$managed_guard"
)
for command in create destroy redeploy-all; do
  if (
    uname() { echo Linux; }
    MANAGED_DEMO=true COMMAND="$command" FULL_DEMO=false eval "$managed_guard"
  ) >"$LOG_FILE.output" 2>&1; then
    echo "FAIL: managed guard allowed destructive command: $command"
    exit 1
  fi
  grep -Fq 'Disable automatic recovery' "$LOG_FILE.output"
done
cmd_full_demo >/dev/null

cat >"$LOG_FILE.expected" <<'EOF'
fleet auth status
create quiet=true addons=mcp-server,setup-pah,product-demos,ollama,eda,ao,fleet
deploy skip_ao=true
enable setup-pah provider=unset
credentials keepalive enable
enable ollama provider=unset
enable eda provider=unset
enable ao provider=ollama
enable fleet provider=unset
fleet add 3 --image rhel9
fleet start
fleet register
enable product-demos provider=unset
wire
system-info
release-lock
service install
dashboard
console
EOF

if ! cmp -s "$LOG_FILE" "$LOG_FILE.expected"; then
  echo "FAIL: full demo orchestration order is incorrect"
  diff -u "$LOG_FILE.expected" "$LOG_FILE" || true
  rm -f "$LOG_FILE.expected"
  exit 1
fi
rm -f "$LOG_FILE.expected"

# With --satellite and no existing Satellite VM, the build runs before the
# Satellite Demo content install.
: >"$LOG_FILE"
FULL_DEMO_SATELLITE=true SATELLITE_VM_EXISTS=false cmd_full_demo >/dev/null
cat >"$LOG_FILE.expected" <<'EOF'
fleet auth status
create quiet=true addons=mcp-server,setup-pah,product-demos,ollama,eda,ao,fleet
deploy skip_ao=true
enable setup-pah provider=unset
credentials keepalive enable
enable ollama provider=unset
enable eda provider=unset
enable ao provider=ollama
enable fleet provider=unset
fleet add 3 --image rhel9
fleet start
fleet register
enable product-demos provider=unset
satellite build-and-configure
enable product-demo-satellite provider=unset
wire
system-info
release-lock
service install
dashboard
console
EOF
if ! cmp -s "$LOG_FILE" "$LOG_FILE.expected"; then
  echo "FAIL: full demo --satellite order is incorrect"
  diff -u "$LOG_FILE.expected" "$LOG_FILE" || true
  rm -f "$LOG_FILE.expected"
  exit 1
fi
rm -f "$LOG_FILE.expected"

# Existing VMs also enter the state-aware builder, which decides maintenance vs install.
: >"$LOG_FILE"
FULL_DEMO_SATELLITE=true SATELLITE_VM_EXISTS=true cmd_full_demo >/dev/null
grep -Fxq 'satellite build-and-configure' "$LOG_FILE"
grep -Fq 'enable product-demo-satellite' "$LOG_FILE" || {
  echo "FAIL: satellite demo content was not installed with an existing VM"
  exit 1
}
: >"$LOG_FILE"
if FULL_DEMO_SATELLITE=true SATELLITE_VM_EXISTS=true FAIL_SATELLITE_BUILD=true \
  cmd_full_demo >"$LOG_FILE.output" 2>&1; then
  echo "FAIL: full demo reported success after Satellite reconciliation failure"
  exit 1
fi
grep -Fq 'ERROR: Satellite Build and Configure failed' "$LOG_FILE.output"
if grep -Fq 'enable product-demo-satellite' "$LOG_FILE" || grep -Fxq wire "$LOG_FILE"; then
  echo "FAIL: full demo continued after Satellite manifest failure"
  exit 1
fi

: >"$LOG_FILE"
if FAIL_SERVICE_INSTALL=true cmd_full_demo >"$LOG_FILE.output" 2>&1; then
  echo "FAIL: full demo reported success without boot recovery"
  exit 1
fi
grep -Fq 'ERROR: Full demo boot recovery could not be installed' "$LOG_FILE.output"
if grep -Fq 'dashboard' "$LOG_FILE" || grep -Fq 'automatic recovery are ready' "$LOG_FILE.output"; then
  echo "FAIL: full demo continued after boot recovery failed"
  exit 1
fi
: >"$LOG_FILE"
if FAIL_DASHBOARD=true cmd_full_demo >"$LOG_FILE.output" 2>&1; then
  echo "FAIL: full demo reported success without the dashboard"
  exit 1
fi
if grep -Fq 'automatic recovery are ready' "$LOG_FILE.output"; then
  echo "FAIL: full demo printed success before dashboard readiness"
  exit 1
fi
rm -f "$LOG_FILE.output"

: >"$LOG_FILE"
MANAGED_DEMO=true cmd_full_demo >/dev/null
grep -Fxq 'start-existing' "$LOG_FILE"
if grep -Fq 'create quiet=' "$LOG_FILE"; then
  echo "FAIL: full demo recreated a stopped managed CRC"
  exit 1
fi

fleet_count() {
  printf '3'
}
: >"$LOG_FILE"
cmd_full_demo >/dev/null
if grep -Fq 'fleet add ' "$LOG_FILE"; then
  echo "FAIL: full demo duplicated an existing three-node Fleet"
  exit 1
fi
grep -Fq 'fleet start' "$LOG_FILE"
grep -Fq 'fleet register' "$LOG_FILE"

# shellcheck disable=SC2329
infra_get_state() {
  printf 'running'
}
: >"$LOG_FILE"
cmd_full_demo >/dev/null
if grep -Fq 'create quiet=' "$LOG_FILE"; then
  echo "FAIL: full demo tried to recreate an already-running cluster"
  exit 1
fi
grep -Fq 'deploy skip_ao=true' "$LOG_FILE"

# shellcheck disable=SC2329
infra_get_state() {
  printf 'not_created'
}
FLEET_AUTH_CONFIGURED=false
prompt_device=$(mktemp)
: >"$LOG_FILE"
AAP_DEMO_SECRET_PROMPT_DEVICE="$prompt_device" cmd_full_demo >/dev/null
cat >"$LOG_FILE.auth.expected" <<'EOF'
fleet auth status
fleet auth configure
fleet auth status
create quiet=true addons=mcp-server,setup-pah,product-demos,ollama,eda,ao,fleet
EOF
if ! head -4 "$LOG_FILE" | cmp -s - "$LOG_FILE.auth.expected"; then
  echo "FAIL: full demo did not configure missing Fleet credentials first"
  diff -u "$LOG_FILE.auth.expected" <(head -4 "$LOG_FILE") || true
  rm -f "$LOG_FILE.auth.expected" "$prompt_device"
  exit 1
fi
rm -f "$LOG_FILE.auth.expected" "$prompt_device"

if QUIET=true "$AAP_DEMO_SH" status --full-demo >/tmp/aap-demo-full-demo-error 2>&1; then
  echo "FAIL: --full-demo was accepted outside create"
  rm -f /tmp/aap-demo-full-demo-error
  exit 1
fi
grep -Fq -- "--full-demo is supported only by create" /tmp/aap-demo-full-demo-error
rm -f /tmp/aap-demo-full-demo-error

# --satellite is a create profile and must be rejected for non-create commands.
if QUIET=true "$AAP_DEMO_SH" status --satellite >/tmp/aap-demo-sat-error 2>&1; then
  echo "FAIL: --satellite was accepted outside create"
  rm -f /tmp/aap-demo-sat-error
  exit 1
fi
grep -Fq -- "--satellite is supported only by create (it enables --ansible)" /tmp/aap-demo-sat-error
rm -f /tmp/aap-demo-sat-error

if QUIET=true "$AAP_DEMO_SH" status --lightspeed >/tmp/aap-demo-lightspeed-error 2>&1; then
  echo "FAIL: --lightspeed was accepted outside create"
  rm -f /tmp/aap-demo-lightspeed-error
  exit 1
fi
grep -Fq -- "--lightspeed is supported only by create (it enables --ansible)" /tmp/aap-demo-lightspeed-error
rm -f /tmp/aap-demo-lightspeed-error

unconfigured_home=$(mktemp -d)
if HOME="$unconfigured_home" QUIET=true AAP_DEMO_DISABLE_LOCK=true \
  "$AAP_DEMO_SH" create --full-demo >"$unconfigured_home/output" 2>&1; then
  echo "FAIL: full demo accepted missing Fleet credentials"
  rm -rf "$unconfigured_home"
  exit 1
fi
grep -Fq 'Full demo cannot prompt for credentials with QUIET=true' "$unconfigured_home/output"
if grep -Fq 'failed unexpectedly' "$unconfigured_home/output"; then
  echo "FAIL: expected full-demo preflight failure was reported as an internal error"
  rm -rf "$unconfigured_home"
  exit 1
fi
rm -rf "$unconfigured_home"

: >"$LOG_FILE"
FULL_DEMO_LIGHTWELL=true FULL_DEMO_GITEA=true cmd_full_demo >"$LOG_FILE.output"
grep -Fxq 'lightwell preflight' "$LOG_FILE"
grep -Fxq 'gitea preflight' "$LOG_FILE"
grep -Fxq 'enable gitea provider=unset' "$LOG_FILE"
grep -Fxq 'enable lightwell provider=unset' "$LOG_FILE"
awk '/^enable gitea / {gitea=NR} /^create / {if(!gitea || NR<gitea) exit 1} /^wire$/ {wire=NR} /^enable lightwell / {if(!wire || NR<wire) exit 1}' "$LOG_FILE"
: >"$LOG_FILE"
if FULL_DEMO_LIGHTWELL=true FAIL_LIGHTWELL_PREFLIGHT=true cmd_full_demo >"$LOG_FILE.output" 2>&1; then
  echo "FAIL: full demo continued after Lightwell preflight failed"
  exit 1
fi
[[ "$(cat "$LOG_FILE")" == 'lightwell preflight' ]]
if QUIET=true "$AAP_DEMO_SH" status --lightwell >"$LOG_FILE.output" 2>&1; then
  echo "FAIL: --lightwell was accepted outside create"
  exit 1
fi
grep -Fq -- '--lightwell is supported only by create' "$LOG_FILE.output"
parser=$(sed -n '/^# Parse command line arguments$/,/^# Check for unprocessed pending flag$/p' "$AAP_DEMO_SH")
grep -Fq '_full_demo_prompt_rhis_templates' "$AAP_DEMO_SH"
grep -Fq 'Type RHIS-GPL to accept the upstream GPL-3.0 license' "$AAP_DEMO_SH"
while IFS='|' read -r args expected; do
  output=$(bash -s -- $args <<EOF
$parser
printf '%s|%s|%s|%s|%s|%s' "\$COMMAND" "\$FULL_DEMO" "\$FULL_DEMO_SATELLITE" "\$FULL_DEMO_LIGHTSPEED" "\$FULL_DEMO_GITEA" "\$FULL_DEMO_LIGHTWELL"
EOF
)
  [[ "$output" == "$expected" ]] || {
    echo "FAIL: profile dependencies were not selected for '$args': $output"
    exit 1
  }
done <<'EOF'
create --ansible|create|true|false|false|false|false
--full-demo|create|true|false|false|false|false
--satellite|create|true|true|false|false|false
--lightspeed|create|true|false|true|false|false
create --lightwell|create|true|true|true|true|true
--lightwell|create|true|true|true|true|true
EOF

: >"$LOG_FILE"
FULL_DEMO_LIGHTSPEED=true cmd_full_demo >"$LOG_FILE.output"
grep -Fxq 'enable lightspeed provider=unset' "$LOG_FILE"
awk '/^enable ao / {ao=NR} /^enable lightspeed / {if(!ao || NR<ao) exit 1; lightspeed=NR} /^enable fleet / {if(!lightspeed || NR<lightspeed) exit 1}' "$LOG_FILE"

: >"$LOG_FILE"
FULL_DEMO_GITEA=true cmd_full_demo >"$LOG_FILE.output"
grep -Fxq 'gitea preflight' "$LOG_FILE"
grep -Fxq 'enable gitea provider=unset' "$LOG_FILE"
awk '/^enable gitea / {gitea=NR} /^create / {if(!gitea || NR<gitea) exit 1}' "$LOG_FILE"
: >"$LOG_FILE"
if FULL_DEMO_GITEA=true FAIL_GITEA_PREFLIGHT=true cmd_full_demo >"$LOG_FILE.output" 2>&1; then
  echo "FAIL: full demo continued after Gitea preflight failed"
  exit 1
fi
[[ "$(cat "$LOG_FILE")" == 'gitea preflight' ]]
echo "PASS: create --full-demo bootstraps credentials and uses the required fail-fast order"
