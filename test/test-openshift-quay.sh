#!/usr/bin/env bash
# Regression checks for the optional Red Hat Quay Operator prerequisite scenario.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDON="$ROOT/addons/openshift-quay"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-quay.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

python3 "$ROOT/scripts/validate-addon-contract.py" "$ADDON/scenario.json" >/dev/null
bash -n "$ADDON/deploy.sh"

grep -Fq 'No QuayRegistry, storage, route, user, robot account, mirror, scan, credential, or image content was created.' \
  "$ADDON/deploy.sh"
grep -Fq 'Refusing to change an unowned Quay Subscription' "$ADDON/deploy.sh"
grep -Fq 'Refusing to delete an unowned Quay operator namespace' "$ADDON/deploy.sh"
grep -Fq 'name: quay-operator' "$ADDON/quay-operator.yaml"

mkdir -p "$TEST_DIR/bin"
cat >"$TEST_DIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${AAP_DEMO_TEST_LOG:?}"
case "$*" in
  'cluster-info') exit 0 ;;
  'get crd subscriptions.operators.coreos.com') exit 0 ;;
  'get catalogsource redhat-operators -n openshift-marketplace') exit 0 ;;
  *'get namespace aap-demo-quay-operator -o json') exit 1 ;;
  *'get operatorgroup aap-demo-quay-operator -n aap-demo-quay-operator -o json') exit 1 ;;
  *'get subscription aap-demo-quay-operator -n aap-demo-quay-operator -o json')
    if [ "${AAP_DEMO_UNOWNED:-false}" = true ]; then
      printf '%s\n' '{"metadata":{"labels":{}}}'
      exit 0
    fi
    exit 1
    ;;
  *'get packagemanifest quay-operator'*'-o json')
    if [ "${AAP_DEMO_WRONG_CATALOG:-false}" = true ]; then
      printf '%s\n' '{"metadata":{"labels":{"catalog":"other-catalog"}},"status":{"defaultChannel":"stable-3.14"}}'
      exit 0
    fi
    printf '%s\n' '{"metadata":{"labels":{"catalog":"redhat-operators"}},"status":{"defaultChannel":"stable-3.14"}}'
    ;;
  *'apply -f -') cat >/dev/null ;;
  *'get subscription aap-demo-quay-operator'*'installedCSV'*) printf quay.v1 ;;
  *'get csv quay.v1'*'jsonpath='*) printf Succeeded ;;
  *) echo "unexpected kubectl: $*" >&2; exit 2 ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/kubectl"

PATH="$TEST_DIR/bin:$PATH" AAP_DEMO_TEST_LOG="$TEST_DIR/calls" \
  QUAY_WAIT_SECONDS=5 "$ADDON/deploy.sh" >"$TEST_DIR/output"

grep -Fq 'Red Hat Quay Operator prerequisite is ready' "$TEST_DIR/output"
grep -Fq 'get packagemanifest quay-operator' "$TEST_DIR/calls"
grep -Fq 'apply -f -' "$TEST_DIR/calls"

if PATH="$TEST_DIR/bin:$PATH" AAP_DEMO_TEST_LOG="$TEST_DIR/unowned-calls" \
  AAP_DEMO_UNOWNED=true QUAY_WAIT_SECONDS=5 "$ADDON/deploy.sh" >"$TEST_DIR/unowned-output" 2>&1; then
  echo "FAIL: an unowned Quay Subscription was accepted" >&2
  exit 1
fi
grep -Fq 'Refusing to change an unowned Quay Subscription' "$TEST_DIR/unowned-output"
if grep -Fq 'apply -f -' "$TEST_DIR/unowned-calls"; then
  echo "FAIL: resources were applied after an ownership failure" >&2
  exit 1
fi

if PATH="$TEST_DIR/bin:$PATH" AAP_DEMO_TEST_LOG="$TEST_DIR/catalog-calls" \
  AAP_DEMO_WRONG_CATALOG=true QUAY_WAIT_SECONDS=5 "$ADDON/deploy.sh" >"$TEST_DIR/catalog-output" 2>&1; then
  echo "FAIL: a package from an unexpected CatalogSource was accepted" >&2
  exit 1
fi
grep -Fq 'is not available from redhat-operators' "$TEST_DIR/catalog-output"
if grep -Fq 'apply -f -' "$TEST_DIR/catalog-calls"; then
  echo "FAIL: resources were applied after a CatalogSource mismatch" >&2
  exit 1
fi

echo "PASS: OpenShift Quay addon validates ownership, discovers its catalog channel, and waits for Quay"
