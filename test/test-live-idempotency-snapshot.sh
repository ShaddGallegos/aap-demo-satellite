#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/bin"
cat >"$DIR/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  cluster-info) exit 0 ;;
  api-resources)
    if [ "$SCENARIO" = discovery_failure ]; then exit 1; fi
    if [ "$SCENARIO" = required_missing ]; then
      printf '%s\n' statefulsets.apps daemonsets.apps services persistentvolumeclaims
    else
      printf '%s\n' deployments.apps statefulsets.apps daemonsets.apps services persistentvolumeclaims
    fi
    if [ "$SCENARIO" = optional_failure ]; then echo routes.route.openshift.io; fi
    if [ "$SCENARIO" = coverage_changed ] && [ "$(cat "$TEST_STAGE_FILE")" = 2 ]; then
      echo routes.route.openshift.io
    fi
    ;;
  get)
    if [ "$SCENARIO" = optional_failure ] && [ "$2" = routes.route.openshift.io ]; then exit 1; fi
    if [ "$SCENARIO" = malformed ]; then echo '{"items":{}}'; exit 0; fi
    if [ "$SCENARIO" = malformed_item ]; then echo '{"items":[{"metadata":{}}]}'; exit 0; fi
    if [ "$SCENARIO" = empty ]; then echo '{"items":[]}'; exit 0; fi
    if [ "$SCENARIO" = changed ] && [ "$(cat "$TEST_STAGE_FILE")" = 2 ]; then
      printf '%s\n' '{"items":[{"metadata":{"namespace":"test","name":"fixture"},"spec":{"replicas":2}}]}'
      exit 0
    fi
    printf '%s\n' '{"items":[{"metadata":{"namespace":"test","name":"fixture"},"spec":{"replicas":1}}]}'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$DIR/bin/kubectl"
export PATH="$DIR/bin:$PATH"
export TEST_STAGE_FILE="$DIR/stage"
cat >"$DIR/bin/converge" <<'EOF'
#!/usr/bin/env bash
n=0
[ ! -f "$TEST_STAGE_FILE" ] || n=$(cat "$TEST_STAGE_FILE")
echo "$((n + 1))" >"$TEST_STAGE_FILE"
EOF
chmod +x "$DIR/bin/converge"
for scenario in discovery_failure required_missing optional_failure malformed malformed_item empty changed coverage_changed; do
  rm -f "$TEST_STAGE_FILE"
  if SCENARIO="$scenario" AAP_DEMO_LIVE_IDEMPOTENCY=1 bash "$ROOT/test/test-live-idempotency.sh" -- converge >"$DIR/out" 2>&1; then
    echo "FAIL: $scenario produced a success-shaped snapshot" >&2
    exit 1
  fi
  grep -q 'ERROR:' "$DIR/out"
  case "$scenario" in
    changed | coverage_changed) [ "$(cat "$TEST_STAGE_FILE")" = 2 ] ;;
    *) [ "$(cat "$TEST_STAGE_FILE")" = 1 ] ;;
  esac
done
rm -f "$TEST_STAGE_FILE"
SCENARIO=ready AAP_DEMO_LIVE_IDEMPOTENCY=1 bash "$ROOT/test/test-live-idempotency.sh" -- converge >"$DIR/out" 2>&1
grep -q 'Second run preserved' "$DIR/out"
echo "PASS: incomplete or invalid snapshots fail; optional absent resources are skipped"
