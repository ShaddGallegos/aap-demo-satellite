#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The APD scenario must fail closed before it attempts a cluster operation.
if "$ROOT/addons/product-demo-eda/deploy.sh" >"$TMP/gate" 2>&1; then
  echo "FAIL: guarded EDA demo accepted a missing opt-in" >&2
  exit 1
fi
grep -Fq 'PRODUCT_DEMOS_ENABLE_EDA=true' "$TMP/gate"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "get aap -n aap-operator -o jsonpath={.items[0].metadata.name}") printf 'aap' ;;
  "get aap aap -n aap-operator -o jsonpath={.spec.eda.disabled}") printf 'false' ;;
  *) echo "unexpected kubectl invocation: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/kubectl"
PATH="$TMP/bin:$PATH" "$ROOT/addons/eda/deploy.sh" >"$TMP/eda"
grep -Fq 'already enabled' "$TMP/eda"

for script in "$ROOT"/addons/product-demos*/deploy.sh "$ROOT"/addons/product-demo-{linux,windows,network,cloud,openshift,satellite,infrastructure}/deploy.sh; do
  grep -Fq '90dea07d34d9bf5bf59acd7b6927ab576c0cddf4' "$script"
done

grep -Fq '_ensure_addon_dependency eda' "$ROOT/aap-demo.sh"
grep -Fq '_ensure_addon_dependency ao' "$ROOT/aap-demo.sh"
if grep -Fq 'apd_install_domain_demo' "$ROOT/addons/product-demo-infrastructure/deploy.sh"; then
  echo "FAIL: Infrastructure import must not launch the upstream scenario" >&2
  exit 1
fi
echo "PASS: EDA guard, service enablement, and APD revision pin are wired"
