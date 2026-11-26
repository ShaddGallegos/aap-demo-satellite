#!/usr/bin/env bash
# Regression checks for the optional ACM Operator prerequisite scenario.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDON="$ROOT/addons/openshift-acm"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-acm.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

python3 "$ROOT/scripts/validate-addon-contract.py" "$ADDON/scenario.json" >/dev/null
bash -n "$ADDON/deploy.sh"
grep -Fq 'No MultiClusterHub, managed cluster import, policy, credential, compliance rule, or customer workload was created.' "$ADDON/deploy.sh"
grep -Fq 'Refusing to change an unowned ACM Subscription' "$ADDON/deploy.sh"

mkdir -p "$TEST_DIR/bin"
cat >"$TEST_DIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${AAP_DEMO_TEST_LOG:?}"
case "$*" in
  'cluster-info'|'get crd subscriptions.operators.coreos.com'|'get catalogsource redhat-operators -n openshift-marketplace') exit 0 ;;
  *'get namespace open-cluster-management -o json'|*'get operatorgroup aap-demo-acm-operator -n open-cluster-management -o json') exit 1 ;;
  *'get subscription aap-demo-acm-operator -n open-cluster-management -o json')
    if [ "${AAP_DEMO_UNOWNED:-false}" = true ]; then printf '%s\n' '{"metadata":{"labels":{}}}'; exit 0; fi
    exit 1 ;;
  *'get packagemanifest advanced-cluster-management'*'-o json')
    if [ "${AAP_DEMO_WRONG_CATALOG:-false}" = true ]; then printf '%s\n' '{"metadata":{"labels":{"catalog":"other-catalog"}},"status":{"defaultChannel":"release-2.15"}}'; exit 0; fi
    printf '%s\n' '{"metadata":{"labels":{"catalog":"redhat-operators"}},"status":{"defaultChannel":"release-2.15"}}' ;;
  *'apply -f -') cat >/dev/null ;;
  *'get subscription aap-demo-acm-operator'*'installedCSV'*) printf acm.v1 ;;
  *'get csv acm.v1'*'jsonpath='*) printf Succeeded ;;
  *) echo "unexpected kubectl: $*" >&2; exit 2 ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/kubectl"

PATH="$TEST_DIR/bin:$PATH" AAP_DEMO_TEST_LOG="$TEST_DIR/calls" ACM_WAIT_SECONDS=5 "$ADDON/deploy.sh" >"$TEST_DIR/output"
grep -Fq 'ACM Operator prerequisite is ready' "$TEST_DIR/output"
grep -Fq 'get packagemanifest advanced-cluster-management' "$TEST_DIR/calls"
grep -Fq 'apply -f -' "$TEST_DIR/calls"

for guard in unowned catalog; do
  if [ "$guard" = unowned ]; then extra_env=(AAP_DEMO_UNOWNED=true); expected='Refusing to change an unowned ACM Subscription'; else extra_env=(AAP_DEMO_WRONG_CATALOG=true); expected='is not available from redhat-operators'; fi
  if env "${extra_env[@]}" PATH="$TEST_DIR/bin:$PATH" AAP_DEMO_TEST_LOG="$TEST_DIR/${guard}-calls" ACM_WAIT_SECONDS=5 "$ADDON/deploy.sh" >"$TEST_DIR/${guard}-output" 2>&1; then
    echo "FAIL: ${guard} guard was accepted" >&2; exit 1
  fi
  grep -Fq "$expected" "$TEST_DIR/${guard}-output"
  if grep -Fq 'apply -f -' "$TEST_DIR/${guard}-calls"; then echo "FAIL: resources were applied after ${guard} guard failure" >&2; exit 1; fi
done

echo "PASS: OpenShift ACM addon validates ownership, verifies its catalog source, and waits for ACM"
