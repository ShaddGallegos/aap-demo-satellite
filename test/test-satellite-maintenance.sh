#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
source "$REPO_ROOT/satellite-lab/maintain-satellite.sh"
LOG="$TEST_DIR/log"
SATELLITE_BACKUP_DIR="$TEST_DIR/backups"
os_major=$(. /etc/os-release; printf '%s' "${VERSION_ID%%.*}")
reset_case() {
  : >"$LOG"
  printf 6.17.12 >"$TEST_DIR/version"
  printf 6.17 >"$TEST_DIR/target"
  printf 0 >"$TEST_DIR/pending"
  RELEASES="" BACKUP_FAIL=false CHECK_FAIL=false PARTIAL=false REBOOT_RC=0 DISCOVERY_RC="" NO_APPLY=false
}
rpm() {
  case "$*" in
    '-q --qf %{VERSION} satellite') cat "$TEST_DIR/version" ;;
    '--eval %{_arch}') printf x86_64 ;;
    '-q satellite') return 0 ;;
    *) return 1 ;;
  esac
}
test() {
  if [ "${1:-}" = -s ] && [[ "${2:-}" == /etc/foreman* ]]; then
    [ "$PARTIAL" != true ]
  else
    builtin test "$@"
  fi
}
satellite_maintenance_target() { cat "$TEST_DIR/target"; }
satellite-maintain() {
  printf '%s\n' "$*" >>"$LOG"
  case "$1 ${2:-}" in
    'backup offline') [ "$BACKUP_FAIL" != true ] ;;
    'update check'|'upgrade check') [ "$CHECK_FAIL" != true ] ;;
    'update run')
      if [ "$NO_APPLY" != true ]; then
        printf 0 >"$TEST_DIR/pending"
        printf 6.17.99 >"$TEST_DIR/version"
      fi
      ;;
    'upgrade run') printf '%s.0' "$(cat "$TEST_DIR/target")" >"$TEST_DIR/version" ;;
  esac
}
dnf() {
  printf 'dnf %s\n' "$*" >>"$LOG"
  case "$*" in
    *check-update) return "${DISCOVERY_RC:-$(cat "$TEST_DIR/pending")}" ;;
    *needs-restarting*) return "$REBOOT_RC" ;;
    *satellite-maintenance-6.18-*) printf 6.18 >"$TEST_DIR/target" ;;
    *satellite-maintenance-6.19-*) printf 6.19 >"$TEST_DIR/target" ;;
    *) return 1 ;;
  esac
}
subscription-manager() {
  local release
  for release in $RELEASES; do
    printf 'Repo ID: satellite-%s-for-rhel-%s-x86_64-rpms\n' "$release" "$os_major"
    printf 'Repo ID: satellite-maintenance-%s-for-rhel-%s-x86_64-rpms\n' "$release" "$os_major"
  done
}
reset_case
satellite_maintenance_main >"$TEST_DIR/output"
! grep -Eq '^backup |^(update|upgrade) run' "$LOG"
reset_case
printf 100 >"$TEST_DIR/pending"
RELEASES="6.18 6.19"
satellite_maintenance_main >"$TEST_DIR/output"
[[ "$(cat "$TEST_DIR/version")" == 6.19.0 ]]
[[ "$(grep -c '^upgrade run' "$LOG")" == 2 ]]
awk '
  /^backup offline/ {backup=NR}
  /^self-upgrade$/ {if(!backup || backup>NR) exit 1}
  /^dnf .* upgrade satellite-maintain/ {if(!backup || backup>NR) exit 1}
  /^(update|upgrade) check/ {check=NR}
  /^(update|upgrade) run/ {if(!backup || !check || check<backup) exit 1}
' "$LOG"
satellite_maintenance_main >"$TEST_DIR/output"
[[ "$(grep -c '^upgrade run' "$LOG")" == 2 ]]
[[ "$(grep -c '^backup offline' "$LOG")" == 3 ]]
for failure in backup check discovery partial; do
  reset_case
  printf 100 >"$TEST_DIR/pending"
  case "$failure" in
    backup) BACKUP_FAIL=true ;;
    check) CHECK_FAIL=true ;;
    discovery) DISCOVERY_RC=1 ;;
    partial) PARTIAL=true ;;
  esac
  if satellite_maintenance_main >"$TEST_DIR/output" 2>&1; then
    echo "FAIL: $failure failure was ignored" >&2; exit 1
  fi
  ! grep -Eq '^(update|upgrade) run|^dnf .* upgrade satellite-maintain' "$LOG"
done
reset_case
printf 100 >"$TEST_DIR/pending"
NO_APPLY=true
if satellite_maintenance_main >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: maintenance reported success with unapplied updates" >&2; exit 1
fi
grep -q 'Package updates remain' "$TEST_DIR/output"
reset_case
printf 6.19 >"$TEST_DIR/target"
if satellite_maintenance_main >"$TEST_DIR/output" 2>&1; then
  echo "FAIL: unsupported release jump was accepted" >&2; exit 1
fi
! grep -q '^backup ' "$LOG"
reset_case
REBOOT_RC=1
rc=0
satellite_maintenance_main >"$TEST_DIR/output" 2>&1 || rc=$?
[[ "$rc" == 194 ]]

# Exercise the real builder dispatch without a VM, registration, or package changes.
(
  source "$REPO_ROOT/satellite-lab/build-and-configure.sh"
  _sat_ssh_ready() { [ "${SSH_READY:-true}" = true ]; }
  _sat_install_state() {
    [ "${STATE_FAIL:-false}" != true ] || return 255
    cat "$TEST_DIR/install-state"
  }
  _stage_network() { echo network >>"$LOG"; }
  _stage_manifest() { echo manifest >>"$LOG"; }
  _stage_provision() { echo provision >>"$LOG"; }
  _stage_wait_install() { echo wait >>"$LOG"; }
  _stage_register() { echo register >>"$LOG"; }
  _stage_installer() { echo installer >>"$LOG"; echo installed >"$TEST_DIR/install-state"; }
  _stage_maintenance() { echo maintenance >>"$LOG"; [ "${MAINTENANCE_FAIL:-false}" != true ]; }
  _stage_upload_manifest() { echo import >>"$LOG"; }
  _stage_content() { echo content >>"$LOG"; }
  _stage_provisioning() { echo provisioning >>"$LOG"; }
  _stage_integrations() { echo integrations >>"$LOG"; }
  _stage_ca_trust() { echo trust >>"$LOG"; }
  : >"$LOG"
  echo absent >"$TEST_DIR/install-state"
  main >"$TEST_DIR/output"
  [[ "$(grep -c '^installer$' "$LOG")" == 1 ]]
  : >"$LOG"
  main >"$TEST_DIR/output"
  [[ "$(cat "$LOG")" == $'maintenance\nmanifest\nimport\ntrust' ]]
  : >"$LOG"
  SSH_READY=false main >"$TEST_DIR/output"
  [[ "$(cat "$LOG")" == $'network\nmanifest\nprovision\nwait\nmaintenance\nimport\ntrust' ]]
  : >"$LOG"
  if MAINTENANCE_FAIL=true main >"$TEST_DIR/output" 2>&1; then exit 1; fi
  [[ "$(cat "$LOG")" == maintenance ]]
  : >"$LOG"
  if STATE_FAIL=true main >"$TEST_DIR/output" 2>&1; then exit 1; fi
  [[ ! -s "$LOG" ]]
)
(
  source "$REPO_ROOT/satellite-lab/build-and-configure.sh"
  printf old-boot >"$TEST_DIR/boot"
  printf 0 >"$TEST_DIR/maintenance-calls"
  mock_scp() { :; }
  sleep() { :; }
  mock_ssh() {
    case "$1" in
      'cat /proc/sys/kernel/random/boot_id') cat "$TEST_DIR/boot" ;;
      'bash -s')
        cat >/dev/null
        count=$(cat "$TEST_DIR/maintenance-calls")
        printf '%s' "$((count + 1))" >"$TEST_DIR/maintenance-calls"
        [ "$count" -ne 0 ] || return 194
        ;;
      systemd-run*) printf new-boot >"$TEST_DIR/boot" ;;
      *) return 1 ;;
    esac
  }
  SAT_SCP=mock_scp SAT_SSH=mock_ssh
  _stage_maintenance >"$TEST_DIR/output"
  [[ "$(cat "$TEST_DIR/maintenance-calls")" == 2 ]]
  [[ "$(cat "$TEST_DIR/boot")" == new-boot ]]
)
(
  source "$REPO_ROOT/satellite-lab/build-and-configure.sh"
  export TEST_DIR CONTENT_ORGS=1
  hammer() {
    case "$1 $2" in
      'organization list') printf '[{"Id":1,"Name":"Demo Org"},{"Id":3,"Name":"Default Organization"}]' ;;
      'subscription upload') printf '%s\n' "$4" >"$TEST_DIR/imported-org" ;;
      *)
        case "$*" in
          *'repository list'*)
            if [[ "$*" == *'--organization-id 1' ]] || [ "$CONTENT_ORGS" = 2 ]; then
              printf '[{"Id":8}]'
            else
              printf '[]'
            fi
            ;;
          *'organization list'*) printf '[{"Id":1,"Name":"Demo Org"},{"Id":3,"Name":"Default Organization"}]' ;;
          *) return 1 ;;
        esac
        ;;
    esac
  }
  export -f hammer
  mock_scp() { :; }
  mock_ssh() { bash -s; }
  SAT_SCP=mock_scp SAT_SSH=mock_ssh SAT_ORG=""
  _stage_upload_manifest >"$TEST_DIR/output"
  [[ "$(cat "$TEST_DIR/imported-org")" == 'Demo Org' ]]
  rm "$TEST_DIR/imported-org"
  if CONTENT_ORGS=2 _stage_upload_manifest >"$TEST_DIR/output" 2>&1; then
    echo "FAIL: ambiguous content organizations were accepted" >&2; exit 1
  fi
  [[ ! -e "$TEST_DIR/imported-org" ]]
  SAT_ORG="Custom's Org" _stage_upload_manifest >"$TEST_DIR/output"
  [[ "$(cat "$TEST_DIR/imported-org")" == "Custom's Org" ]]
)
echo "PASS: existing Satellite is maintained, upgrades are sequential and backed up, failures stop the build"
