#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/satellite-lab/09-content-sync-plan.sh"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/bin"

cat >"$TMPDIR/bin/hammer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$HAMMER_LOG"
case "$*" in
  "sync-plan info "*) [ "${PLAN_EXISTS:-false}" = true ] ;;
  "--output json product list "*)
    printf '%s\n' '[{"Name":"RHEL 9"},{"Name":"RHEL 10"},{"Name":"Satellite Client"}]' ;;
  "sync-plan create "*|"product set-sync-plan "*) ;;
  *) echo "Unexpected hammer invocation: $*" >&2; exit 1 ;;
esac
EOF
chmod 700 "$TMPDIR/bin/hammer"
export PATH="$TMPDIR/bin:$PATH"
export HAMMER_LOG="$TMPDIR/hammer.log"

SATELLITE_FLATPAK_ENABLED=false SATELLITE_COLLECTIONS_ENABLED=false \
  bash "$SCRIPT" >"$TMPDIR/output"
grep -Fq 'sync-plan create --organization Default Organization --name aap-demo-all-content --interval daily' "$HAMMER_LOG"
test "$(grep -c '^product set-sync-plan ' "$HAMMER_LOG")" -eq 3
grep -Fq "Sync plan 'aap-demo-all-content' is attached to 3 product(s)" "$TMPDIR/output"

: >"$HAMMER_LOG"
PLAN_EXISTS=true SATELLITE_SYNC_PLAN_INTERVAL=weekly \
  SATELLITE_FLATPAK_ENABLED=false SATELLITE_COLLECTIONS_ENABLED=false \
  bash "$SCRIPT" >"$TMPDIR/output"
if grep -q '^sync-plan create ' "$HAMMER_LOG"; then
  echo "FAIL: existing sync plan was recreated" >&2
  exit 1
fi
test "$(grep -c '^product set-sync-plan ' "$HAMMER_LOG")" -eq 3

if SATELLITE_SYNC_PLAN_INTERVAL=hourly bash "$SCRIPT" >/dev/null 2>&1; then
  echo "FAIL: invalid sync plan interval was accepted" >&2
  exit 1
fi

echo "PASS: Satellite sync plan is retained, covers every product, and validates its schedule"
