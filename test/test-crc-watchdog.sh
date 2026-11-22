#!/usr/bin/env bash
# Tests for scripts/aap-demo-crc-watchdog.sh (CRC vsock forward self-healing).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHDOG="$REPO_ROOT/scripts/aap-demo-crc-watchdog.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# --- behavioral assertions via the real script with stubs on PATH -----------
stub_bin="$TEST_DIR/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/crc" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then printf 'CRC VM:                  %s\n' "${VM_STATE:-Running}"; fi
EOF
cat >"$stub_bin/ssh" <<'EOF'
#!/usr/bin/env bash
f="$STUB_DIR/ssh-calls"
n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); printf '%s' "$n" >"$f"
case "${SSH_MODE:-up}" in
  up) exit 0 ;;
  down) exit 255 ;;
  flap) [ "$n" -le 2 ] && exit 255 || exit 0 ;;
esac
EOF
cat >"$stub_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[ -z "${SYSTEMCTL_LOG:-}" ] || printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
if [ "${FAIL_SERVICE_STOP:-false}" = true ] && [ "$*" = "--user stop aap-demo-crc-watchdog.service" ]; then
  exit 1
fi
exit 0
EOF
# The watchdog detects VM state via virsh (libvirt), independent of the daemon.
cat >"$stub_bin/virsh" <<'EOF'
#!/usr/bin/env bash
# Report the stubbed VM state for `virsh -c qemu:///system domstate crc`.
if [ "${1:-}" = "-c" ]; then
  # args: -c qemu:///system domstate crc
  printf '%s\n' "${VM_STATE:-Running}" | tr '[:upper:]' '[:lower:]'
fi
EOF
chmod +x "$stub_bin"/*

# The watchdog's _ssh_forward_up needs a CRC SSH key present to attempt the
# probe; provide a dummy key so the ssh stub (not key detection) decides.
mkdir -p "$TEST_DIR/home/.crc/machines/crc"
printf 'dummy-key\n' >"$TEST_DIR/home/.crc/machines/crc/id_ed25519"
chmod 600 "$TEST_DIR/home/.crc/machines/crc/id_ed25519"

run_real() {
  local vm_state="$1" ssh_mode="$2"
  env -i HOME="$TEST_DIR/home" PATH="$stub_bin:/usr/bin:/bin" \
    VM_STATE="$vm_state" SSH_MODE="$ssh_mode" STUB_DIR="$TEST_DIR" \
    AAP_DEMO_DIR="$TEST_DIR/home/.aap-demo" \
    AAP_DEMO_WATCHDOG_DAEMON_RETRIES=3 AAP_DEMO_WATCHDOG_REBOOT_RETRIES=2 \
    AAP_DEMO_WATCHDOG_RETRY_SLEEP=0 \
    bash "$WATCHDOG" check 2>&1
}

# healthy: no recovery
out=$(run_real Running up)
grep -q 'watchdog: healthy' <<<"$out"
! grep -q 'restarting crc-daemon' <<<"$out"

# dropped forward -> daemon restart -> recovered
out=$(run_real Running flap)
grep -q 'dropped vsock forward detected' <<<"$out"
grep -q 'recovered after daemon restart' <<<"$out"

# VM stopped -> nothing to do
out=$(run_real Stopped down)
grep -q 'VM not running' <<<"$out"

unit_dir="$TEST_DIR/home/.config/systemd/user"
mkdir -p "$unit_dir"
touch "$unit_dir/aap-demo-crc-watchdog.timer" "$unit_dir/aap-demo-crc-watchdog.service"
if env -i HOME="$TEST_DIR/home" PATH="$stub_bin:/usr/bin:/bin" \
  SYSTEMCTL_LOG="$TEST_DIR/systemctl.log" FAIL_SERVICE_STOP=true \
  bash "$WATCHDOG" uninstall; then
  echo "FAIL: watchdog uninstall hid a service stop failure" >&2
  exit 1
fi
[ -f "$unit_dir/aap-demo-crc-watchdog.service" ]
env -i HOME="$TEST_DIR/home" PATH="$stub_bin:/usr/bin:/bin" \
  SYSTEMCTL_LOG="$TEST_DIR/systemctl.log" bash "$WATCHDOG" uninstall
grep -q -- '--user disable --now aap-demo-crc-watchdog.timer' "$TEST_DIR/systemctl.log"
grep -q -- '--user stop aap-demo-crc-watchdog.service' "$TEST_DIR/systemctl.log"
[ ! -e "$unit_dir/aap-demo-crc-watchdog.timer" ]
[ ! -e "$unit_dir/aap-demo-crc-watchdog.service" ]

echo "PASS: watchdog detects a dropped forward, recovers via daemon restart, and is a no-op when healthy or stopped"
