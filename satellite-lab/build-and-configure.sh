#!/usr/bin/env bash
# build-and-configure.sh — orchestrate the full Satellite lab build from the
# aap-demo host, non-interactively. Drives the satellite-lab stages in order:
#   network -> host NFS storage -> provision VM -> wait for install ->
#   satellite-installer -> content (hammer) -> provisioning -> integrations
#
# Invoked by `aap-demo create --full-demo --satellite` when the Satellite VM
# does not yet exist. Safe to re-run: each stage is skipped when already done.
#
# Required env / Vault:
#   - Red Hat offline token in the Vault (satellite-manifest addon uses it)
#   - RHSM_USERNAME/RHSM_PASSWORD (or RHSM_ORG/RHSM_AK) in the Vault for the VM
#   - RHEL 9.x DVD ISO at $RHEL_ISO (default /var/lib/libvirt/images/rhel-9.5-x86_64-dvd.iso)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../includes/credential-vault.sh
source "${REPO_ROOT}/includes/credential-vault.sh"

SAT_IP="${SATELLITE_LAB_IP:-192.168.122.20}"
SAT_HOST="${SATELLITE_LAB_HOST:-satellite.demo.lab}"
SAT_SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 root@${SAT_IP}"
SAT_SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
RHEL_ISO="${RHEL_ISO:-/var/lib/libvirt/images/rhel-9.5-x86_64-dvd.iso}"
MANIFEST="${MANIFEST:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/satellite/manifest.zip}"
VIRSH="virsh -c qemu:///system"

_err() { printf 'ERROR: %s\n' "$*" >&2; }
_log() { printf '  %s\n' "$*"; }

# --- credential helpers -----------------------------------------------------
_vault_val() { aap_demo_vault_get "$1" 2>/dev/null || true; }

# --- stage checks -----------------------------------------------------------
_sat_vm_exists() { $VIRSH dominfo satellite >/dev/null 2>&1; }
_sat_ssh_ready() { $SAT_SSH 'true' 2>/dev/null; }
_sat_installed() { $SAT_SSH 'systemctl is-active foreman.service >/dev/null 2>&1' 2>/dev/null; }
_sat_content_done() { $SAT_SSH 'hammer content-view list 2>/dev/null | grep -q RHEL9' 2>/dev/null; }

# --- stages -----------------------------------------------------------------
_stage_network() {
  _log "▸ Stage: network setup"
  sudo bash "${SCRIPT_DIR}/00-network-setup.sh"
}

_stage_manifest() {
  if [ -s "$MANIFEST" ]; then
    _log "✓ Manifest already present: $MANIFEST"
    return 0
  fi
  _log "▸ Stage: build subscription manifest (satellite-manifest addon)"
  QUIET=true bash "${REPO_ROOT}/aap-demo.sh" enable satellite-manifest
  [ -s "$MANIFEST" ] || { _err "Manifest not produced at $MANIFEST"; return 1; }
}

_stage_provision() {
  if _sat_vm_exists; then
    _log "✓ Satellite VM already exists"
    return 0
  fi
  # Default to the fully automatic netboot path (no ISO) when the host is
  # registered with RHSM; otherwise require the DVD/boot ISO.
  local install_source="${RHEL_INSTALL_SOURCE:-}"
  if [ -z "$install_source" ]; then
    if sudo subscription-manager identity >/dev/null 2>&1; then
      install_source="netboot"
    else
      install_source="dvd"
    fi
  fi
  if [ "$install_source" != "netboot" ]; then
    [ -f "$RHEL_ISO" ] || {
      _err "RHEL ISO not found: $RHEL_ISO"
      _err "Either register the host with RHSM (subscription-manager register) for the"
      _err "automatic netboot path, or place the RHEL 9.x ISO at $RHEL_ISO."
      return 1
    }
  fi
  _log "▸ Stage: provision Satellite VM (unattended kickstart, source=$install_source)"
  local rhsm_user rhsm_pass rhsm_org rhsm_ak
  rhsm_user=$(_vault_val RHSM_USERNAME)
  rhsm_pass=$(_vault_val RHSM_PASSWORD)
  rhsm_org=$(_vault_val RHSM_ORG_ID)
  rhsm_ak=$(_vault_val RHSM_ACTIVATION_KEY)
  sudo \
    RHSM_USER="$rhsm_user" RHSM_PASS="$rhsm_pass" \
    RHSM_ORG="$rhsm_org" RHSM_AK="$rhsm_ak" \
    RHEL_ISO="$RHEL_ISO" RHEL_INSTALL_SOURCE="$install_source" \
    bash "${SCRIPT_DIR}/01-provision-satellite-vm.sh"
}

_stage_wait_install() {
  _log "▸ Stage: wait for the kickstart install to finish (VM reboots when done)"
  # The installer reboots the VM; SSH becomes available once RHEL is up.
  local attempt
  for attempt in $(seq 1 120); do
    if _sat_ssh_ready; then
      _log "✓ Satellite VM is up and reachable over SSH"
      return 0
    fi
    sleep 15
  done
  _err "Timed out waiting for the Satellite VM to become SSH-ready"
  return 1
}

_stage_installer() {
  if _sat_installed; then
    _log "✓ Satellite already installed"
    return 0
  fi
  _log "▸ Stage: run satellite-installer on the VM"
  $SAT_SCP "${SCRIPT_DIR}/02-satellite-installer.sh" "root@${SAT_IP}:/root/" || return 1
  $SAT_SSH 'bash /root/02-satellite-installer.sh' || return 1
}

_stage_content() {
  if _sat_content_done; then
    _log "✓ Satellite content already configured"
    return 0
  fi
  _log "▸ Stage: content architecture (manifest + RHEL 9/10 repos, on_demand)"
  $SAT_SCP "$MANIFEST" "root@${SAT_IP}:/root/manifest.zip" || return 1
  $SAT_SCP "${SCRIPT_DIR}/03-content-hammer.sh" "root@${SAT_IP}:/root/" || return 1
  $SAT_SSH 'bash /root/03-content-hammer.sh /root/manifest.zip' || return 1
}

_stage_provisioning() {
  _log "▸ Stage: provisioning (kickstart host groups)"
  $SAT_SCP "${SCRIPT_DIR}/04-provisioning-kickstart.sh" "root@${SAT_IP}:/root/" || return 1
  $SAT_SSH 'bash /root/04-provisioning-kickstart.sh' || return 1
}

_stage_integrations() {
  _log "▸ Stage: integrations (libvirt compute resource, rhc/Insights)"
  $SAT_SCP "${SCRIPT_DIR}/06-integrations.sh" "root@${SAT_IP}:/root/" || return 1
  $SAT_SSH 'bash /root/06-integrations.sh' || return 1
}

main() {
  echo ""
  echo "Satellite Build and Configure - building the Satellite lab..."
  _stage_network
  _stage_manifest
  _stage_provision
  _stage_wait_install
  _stage_installer
  _stage_content
  _stage_provisioning
  _stage_integrations
  echo ""
  echo "✓ Satellite Build and Configure complete"
  echo "  Satellite UI: https://${SAT_HOST} (admin / RedHat123!)"
  echo "  Next: aap-demo enable product-demo-satellite (Satellite Demo content)"
}

main "$@"
