#!/usr/bin/env bash
# Regression checks for the optional OpenShift GitOps/Pipelines scenario.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDON="$ROOT/addons/openshift-delivery"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-delivery.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

python3 "$ROOT/scripts/validate-addon-contract.py" "$ADDON/scenario.json" >/dev/null
bash -n "$ADDON/deploy.sh"

grep -Fq 'No repository, Argo CD Application, PipelineRun, credential, or workload was created.' \
  "$ADDON/deploy.sh"
grep -Fq 'Refusing to change an unowned GitOps Subscription' "$ADDON/deploy.sh"
grep -Fq 'Refusing to delete unowned namespace' "$ADDON/deploy.sh"
grep -Fq 'openshift-gitops-operator' "$ADDON/delivery-operators.yaml"
grep -Fq 'openshift-pipelines-operator-rh' "$ADDON/delivery-operators.yaml"

mkdir -p "$TEST_DIR/bin"
cat >"$TEST_DIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${AAP_DEMO_TEST_LOG:?}"
case "$*" in
  'cluster-info') exit 0 ;;
  'get crd subscriptions.operators.coreos.com') exit 0 ;;
  'get catalogsource redhat-operators -n openshift-marketplace') exit 0 ;;
  'get namespace openshift-operators') exit 0 ;;
  *'get subscription aap-demo-openshift-gitops'*'-o json') exit 1 ;;
  *'get subscription aap-demo-openshift-pipelines'*'-o json') exit 1 ;;
  *'get packagemanifest openshift-gitops-operator'*'-o json')
    if [ "${AAP_DEMO_WRONG_CATALOG:-false}" = true ]; then
      printf '%s\n' '{"metadata":{"labels":{"catalog":"other-catalog"}},"status":{"defaultChannel":"latest"}}'
      exit 0
    fi
    printf '%s\n' '{"metadata":{"labels":{"catalog":"redhat-operators"}},"status":{"defaultChannel":"latest"}}'
    ;;
  *'get packagemanifest openshift-pipelines-operator-rh'*'-o json')
    printf '%s\n' '{"metadata":{"labels":{"catalog":"redhat-operators"}},"status":{"defaultChannel":"pipelines-1.22"}}'
    ;;
  *'apply -f -') cat >/dev/null ;;
  *'get subscription aap-demo-openshift-gitops'*'installedCSV'*) printf gitops.v1 ;;
  *'get subscription aap-demo-openshift-pipelines'*'installedCSV'*) printf pipelines.v1 ;;
  *'get csv gitops.v1'*'jsonpath='*) printf Succeeded ;;
  *'get csv pipelines.v1'*'jsonpath='*) printf Succeeded ;;
  *) echo "unexpected kubectl: $*" >&2; exit 2 ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/kubectl"

PATH="$TEST_DIR/bin:$PATH" AAP_DEMO_TEST_LOG="$TEST_DIR/calls" \
  OPENSHIFT_DELIVERY_WAIT_SECONDS=5 "$ADDON/deploy.sh" >"$TEST_DIR/output"

grep -Fq 'OpenShift delivery operators are ready' "$TEST_DIR/output"
grep -Fq 'get packagemanifest openshift-gitops-operator' "$TEST_DIR/calls"
grep -Fq 'get packagemanifest openshift-pipelines-operator-rh' "$TEST_DIR/calls"
grep -Fq 'apply -f -' "$TEST_DIR/calls"

if PATH="$TEST_DIR/bin:$PATH" AAP_DEMO_TEST_LOG="$TEST_DIR/catalog-calls" \
  AAP_DEMO_WRONG_CATALOG=true OPENSHIFT_DELIVERY_WAIT_SECONDS=5 "$ADDON/deploy.sh" >"$TEST_DIR/catalog-output" 2>&1; then
  echo "FAIL: a package from an unexpected CatalogSource was accepted" >&2
  exit 1
fi
grep -Fq 'is not available from redhat-operators' "$TEST_DIR/catalog-output"
if grep -Fq 'apply -f -' "$TEST_DIR/catalog-calls"; then
  echo "FAIL: resources were applied after a CatalogSource mismatch" >&2
  exit 1
fi

echo "PASS: OpenShift delivery addon validates ownership, discovers catalog channels, and waits for both operators"
