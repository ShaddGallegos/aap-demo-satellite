#!/usr/bin/env bash
# Product Demo - Satellite
#
# Installs Red Hat Satellite integration demos from the Ansible Product Demos collection.
# Requires product-demos-base addon (automatically installed if needed).
#
# Environment variables:
#   PRODUCT_DEMOS_REPO   - Git repository URL (default: https://github.com/ansible/product-demos)
#   PRODUCT_DEMOS_BRANCH - Git branch to use (default: main)
#
# Usage:
#   ./deploy.sh          # Deploy satellite demos
#   ./deploy.sh --delete # Remove satellite demos

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../product-demos-base/lib.sh
source "${SCRIPT_DIR}/../product-demos-base/lib.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"
DEMO_CATEGORY="satellite"

# Product demos configuration
PRODUCT_DEMOS_REPO="${PRODUCT_DEMOS_REPO:-https://github.com/ansible/product-demos}"
PRODUCT_DEMOS_BRANCH="${PRODUCT_DEMOS_BRANCH:-main}"

# ==============================================================================
# DELETE HANDLER
# ==============================================================================

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing Red Hat Satellite integration demo resources from AAP..."
  echo ""
  echo "To remove satellite demo job templates, log into AAP UI and:"
  echo "  1. Navigate to the 'Ansible Product Demos (APD)' organization"
  echo "  2. Go to Templates"
  echo "  3. Delete templates starting with 'SATELLITE |'"
  echo ""
  echo "✓ product-demo-satellite addon disabled"
  exit 0
fi

# ==============================================================================
# DEPLOYMENT
# ==============================================================================

echo "Deploying Ansible Product Demos - Satellite..."
echo ""

# Check cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
  echo "❌ ERROR: Cannot connect to cluster"
  echo "Please ensure your cluster is running: aap-demo status"
  exit 1
fi

# Check if AAP is deployed
if ! kubectl get aap -n "$NAMESPACE" &>/dev/null; then
  echo "❌ ERROR: AAP not found in namespace $NAMESPACE"
  echo "Please deploy AAP first: aap-demo deploy"
  exit 1
fi

# ==============================================================================
# ENSURE BASE ADDON IS INSTALLED
# ==============================================================================

echo "Checking for product-demos-base..."

if ! apd_base_is_recorded; then
  echo "product-demos-base not found. Installing dependency..."
  echo ""

  if [ -f "$SCRIPT_DIR/../product-demos-base/deploy.sh" ]; then
    bash "$SCRIPT_DIR/../product-demos-base/deploy.sh"
    echo ""
  else
    echo "❌ ERROR: Cannot find product-demos-base addon"
    echo "Please ensure product-demos-base exists in addons/ directory"
    exit 1
  fi
else
  echo "✓ product-demos-base is installed"
  echo ""
fi

# ==============================================================================
# INSTALL VIA AAP JOB TEMPLATE
# ==============================================================================

echo "Retrieving AAP connection details..."

if ! command -v jq &>/dev/null; then
  echo "❌ ERROR: jq is required"
  exit 1
fi

apd_init_aap_connection || exit 1
echo "✓ AAP credentials retrieved"
echo ""

# ==============================================================================
# WIRE SATELLITE CREDENTIALS
# ==============================================================================
# Upstream ships placeholder Satellite credentials (https://satellite.example.com,
# REPLACEME). The "SETUP | Satellite" install job connects to the Satellite, so
# point both APD credentials at the real server before installing. Defaults match
# the satellite-lab VM; override with SATELLITE_URL / SATELLITE_USERNAME /
# SATELLITE_PASSWORD for an external Satellite.
# A first install creates these credentials; reconcile them after installation.
echo ""

apd_resolve_domain_install_ids || exit 1
if apd_satellite_is_lab; then
  apd_discover_satellite_lab || exit 1
fi

echo "Installing $DEMO_CATEGORY demo resources via AAP job template..."
echo "This may take a few minutes..."
echo ""

# The install job creates the Satellite credentials (placeholders) and launches
# "SETUP | Satellite", which fails while the placeholders point at
# satellite.example.com. So: install the templates, wire the real credentials,
# then re-run SETUP | Satellite against the wired server.
install_rc=0
if apd_satellite_is_lab; then
  apd_install_satellite_lab || install_rc=$?
else
  apd_install_domain_demo "$DEMO_CATEGORY" || install_rc=$?
fi

# Wire the credentials now that the install created them.
if ! apd_wire_satellite_credentials; then
  echo "ERROR: Satellite credentials could not be wired; the addon is not ready." >&2
  exit 1
fi

# Re-run SETUP | Satellite against the wired Satellite server.
apd_rerun_satellite_setup() {
  local setup_name="SETUP | Satellite"
  local template_id job_id
  template_id=$(apd_satellite_template "$setup_name" | jq -er '.id') || return 1
  if [ -z "$template_id" ]; then
    echo "  ⚠ $setup_name template not found; skipping re-run" >&2
    return 1
  fi
  echo "Re-running $setup_name against ${SATELLITE_URL:-https://satellite.demo.lab}..."
  job_id=$(curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST -H "Content-Type: application/json" \
    "${AAP_API}/job_templates/${template_id}/launch/" 2>&1 | jq -r '.id // empty')
  if [ -z "$job_id" ]; then
    echo "  ⚠ Could not launch $setup_name" >&2
    return 1
  fi
  echo "✓ $setup_name launched (ID: ${job_id})"
  apd_monitor_job "$job_id" "Satellite setup" 160
}

if apd_complete_satellite_install "$install_rc"; then
  echo ""
  echo "✓ Red Hat Satellite integration demos installed successfully!"
  echo ""
  echo "Demo templates configured:"
  echo "  - SETUP | Satellite"
  echo "  - SATELLITE | Publish Content View Version"
  echo "  - SATELLITE | Promote Content View Version"
  echo "  - LINUX | Register with Satellite"
  echo "  - Patch Dev (workflow)"
  if apd_satellite_is_lab; then
    echo "  OpenSCAP requires separate version-appropriate policy content."
  fi
  echo ""
  echo "Satellite credentials wired to ${SATELLITE_URL:-https://satellite.demo.lab}."
  echo "  - Log into AAP UI at: ${AAP_UI_URL}"
  echo "  - Navigate to 'Ansible Product Demos (APD)' organization"
  echo "  - Run demo job templates"
  echo ""
else
  echo ""
  echo "❌ ERROR: Red Hat Satellite integration demo installation failed"
  echo "Re-run from Templates: $(apd_domain_template_name "$DEMO_CATEGORY")"
  exit 1
fi
