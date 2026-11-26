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

# Satellite Flatpak endpoints in some supported releases use uppercase ID,
# unlike the usual Id field. The reconciler must accept both forms.
: >"$HAMMER_LOG"
cat >"$TMPDIR/bin/hammer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$HAMMER_LOG"
case "$*" in
  "sync-plan info "*) exit 0 ;;
  "flatpak-remote --help") ;;
  "--output json flatpak-remote list "*) printf '%s\n' '[{"ID":1,"Name":"RHEL_Flatpak"}]' ;;
  "flatpak-remote update --id 1 --username test-user --token test-token") ;;
  "--output json product list "*) printf '%s\n' '[{"Id":1,"Name":"aap-demo-flatpak"}]' ;;
  "flatpak-remote scan --id 1") ;;
  "--output json flatpak-remote remote-repository list --flatpak-remote-id 1") printf '%s\n' '[{"ID":2,"Name":"rhel"}]' ;;
  "flatpak-remote remote-repository mirror --id 2 --flatpak-remote-id 1 --product-id 1") ;;
  "--output json task list --search state = running --per-page 100") printf '%s\n' '[]' ;;
  "--output json repository list --product-id 1")
    if [ -f "${HAMMER_LOG}.flatpak-repositories" ]; then
      printf '%s\n' '[{"ID":3,"Name":"rhel"}]'
    else
      : >"${HAMMER_LOG}.flatpak-repositories"
      printf '%s\n' '[]'
    fi
    ;;
  "repository update --id 3 --upstream-username test-user --upstream-password test-token") ;;
  "repository synchronize --id 3") ;;
  "product set-sync-plan "*) ;;
  *) echo "Unexpected hammer invocation: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMPDIR/bin/hammer"
PLAN_EXISTS=true SATELLITE_COLLECTIONS_ENABLED=false \
  SATELLITE_FLATPAK_USERNAME=test-user SATELLITE_FLATPAK_TOKEN=test-token \
  bash "$SCRIPT" >"$TMPDIR/output"
grep -q '^flatpak-remote update --id 1 --username test-user --token test-token$' "$HAMMER_LOG"
grep -q '^flatpak-remote scan --id 1$' "$HAMMER_LOG"
grep -q '^flatpak-remote remote-repository mirror --id 2 --flatpak-remote-id 1 --product-id 1$' "$HAMMER_LOG"
grep -q '^repository update --id 3 --upstream-username test-user --upstream-password test-token$' "$HAMMER_LOG"
grep -q '^repository synchronize --id 3$' "$HAMMER_LOG"
echo "PASS: uppercase Flatpak identifiers are reconciled"

grep -Fq -- '--download-concurrency "$COLLECTIONS_DOWNLOAD_CONCURRENCY"' "$SCRIPT"
grep -Fq 'timeout "$CONTENT_SYNC_TIMEOUT_SECONDS" hammer repository synchronize' "$SCRIPT"
grep -Fq 'recover_stalled_collection_worker' "$SCRIPT"
SATELLITE_COLLECTIONS_DOWNLOAD_CONCURRENCY=20 SATELLITE_FLATPAK_ENABLED=false \
  SATELLITE_COLLECTIONS_ENABLED=false bash "$SCRIPT" >"$TMPDIR/output" 2>&1 && {
  echo "FAIL: invalid collection concurrency was accepted" >&2
  exit 1
}
grep -q 'must be an integer from 1 to 19' "$TMPDIR/output"

if SATELLITE_SYNC_PLAN_INTERVAL=hourly bash "$SCRIPT" >/dev/null 2>&1; then
  echo "FAIL: invalid sync plan interval was accepted" >&2
  exit 1
fi

echo "PASS: Satellite sync plan is retained, covers every product, and validates its schedule"
