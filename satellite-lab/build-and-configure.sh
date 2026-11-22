#!/usr/bin/env bash
# build-and-configure.sh — orchestrate the full Satellite lab build from the
# aap-demo host, non-interactively. Drives the satellite-lab stages in order:
#   network -> host NFS storage -> provision VM -> wait for install ->
#   satellite-installer -> content (hammer) -> provisioning -> integrations
#
# Invoked by `aap-demo create --full-demo --satellite`. Existing installations
# receive supported maintenance instead of initial-install configuration.
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
# shellcheck source=../includes/satellite-ca-trust.sh
source "${REPO_ROOT}/includes/satellite-ca-trust.sh"
# shellcheck source=../includes/workflow-journal.sh
source "${REPO_ROOT}/includes/workflow-journal.sh"

SAT_IP="${SATELLITE_LAB_IP:-192.168.122.20}"
SAT_HOST="${SATELLITE_LAB_HOST:-satellite.demo.lab}"
SAT_STATE_DIR="${AAP_DEMO_DIR:-$HOME/.aap-demo}/satellite"
# Satellite lab VMs are deliberately recreated at a stable private IP. Keep
# their trust material separate from the user's global known_hosts so a prior
# lab VM cannot block a new unattended installation.
SAT_KNOWN_HOSTS="${SAT_STATE_DIR}/known_hosts"

# The kickstart injects the invoking user's SSH key for root, but this script
# runs under sudo (where $HOME is /root and root has no key). Point ssh/scp at
# the invoking user's key explicitly so the post-boot stages can connect.
_SAT_KEY=""
if [ -n "${SUDO_USER:-}" ]; then
  _sat_user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  for _k in "$_sat_user_home/.ssh/id_ed25519" "$_sat_user_home/.ssh/id_rsa"; do
    [ -f "$_k" ] && {
      _SAT_KEY="$_k"
      break
    }
  done
fi
for _k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
  if [ -z "$_SAT_KEY" ] && [ -f "$_k" ]; then
    _SAT_KEY="$_k"
  fi
done
_SAT_KEY_OPTS=""
[ -n "$_SAT_KEY" ] && _SAT_KEY_OPTS="-i $_SAT_KEY -o IdentitiesOnly=yes"

SAT_SSH="ssh $_SAT_KEY_OPTS -o UserKnownHostsFile=${SAT_KNOWN_HOSTS} -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 root@${SAT_IP}"
SAT_SCP="scp $_SAT_KEY_OPTS -o UserKnownHostsFile=${SAT_KNOWN_HOSTS} -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
# Let 01-provision-satellite-vm.sh resolve the ISO path from RHEL_INSTALL_SOURCE
# (boot vs dvd) unless the caller pinned an explicit path.
RHEL_ISO="${RHEL_ISO:-}"
_MANIFEST_PROVIDED="${MANIFEST:+true}"
MANIFEST="${MANIFEST:-${MANIFEST_DIR:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/satellite}/manifest.zip}"
VIRSH="virsh -c qemu:///system"
# The Discovery plugin downloads a large boot image during first configuration.
# Keep a validated host-side copy alongside the managed VM disks so a recreated
# lab does not need to retrieve the same image from the Internet again.
SAT_DISCOVERY_IMAGE_URL="${SATELLITE_DISCOVERY_IMAGE_URL:-https://downloads.theforeman.org/discovery/releases/latest/fdi-image-latest.tar}"
SAT_DISCOVERY_IMAGE_CACHE="${SATELLITE_DISCOVERY_IMAGE_CACHE:-/var/lib/libvirt/images/aap-demo-fdi-image-latest.tar}"
SAT_DISCOVERY_IMAGE_GUEST_PATH="/var/lib/tftpboot/boot/fdi-image-latest.tar"

_err() { printf 'ERROR: %s\n' "$*" >&2; }
_log() { printf '  %s\n' "$*"; }

# --- credential helpers -----------------------------------------------------
_vault_val() { aap_demo_vault_get "$1" 2>/dev/null || true; }

# --- stage checks -----------------------------------------------------------
_sat_vm_exists() { $VIRSH dominfo satellite >/dev/null 2>&1; }
_sat_ssh_ready() {
  local output
  if output=$(LC_ALL=C $SAT_SSH 'true' 2>&1); then
    return 0
  fi
  case "$output" in
    *"REMOTE HOST IDENTIFICATION HAS CHANGED"* | *"Host key verification failed"*) return 2 ;;
  esac
  return 1
}
_sat_ssh_trust_error() {
  _err "Satellite SSH host key verification failed for ${SAT_IP}; saved trust was not changed."
  _err "Verify the VM fingerprint out of band, then explicitly update only its approved known-hosts entry before retrying."
  return 1
}
_sat_installed() { $SAT_SSH 'rpm -q satellite >/dev/null 2>&1'; }
_sat_install_state() {
  $SAT_SSH 'if rpm -q satellite >/dev/null 2>&1; then echo installed; else echo absent; fi'
}
_sat_content_done() { $SAT_SSH 'hammer content-view list 2>/dev/null | grep -q RHEL9' 2>/dev/null; }

_satellite_ensure_ssh_store() {
  mkdir -p "$SAT_STATE_DIR" || return 1
  chmod 700 "$SAT_STATE_DIR" || return 1
  touch "$SAT_KNOWN_HOSTS" || return 1
  chmod 600 "$SAT_KNOWN_HOSTS" || return 1
}

_satellite_reset_fresh_vm_ssh_trust() {
  _satellite_ensure_ssh_store || return 1
  # This file is owned by aap-demo. Remove only the stable lab IP, never the
  # user's global known_hosts or another host's approved fingerprint.
  ssh-keygen -q -R "$SAT_IP" -f "$SAT_KNOWN_HOSTS" >/dev/null 2>&1 || true
  ssh-keygen -q -R "[$SAT_IP]:22" -f "$SAT_KNOWN_HOSTS" >/dev/null 2>&1 || true
}

_satellite_discovery_cache_path_is_safe() {
  case "$SAT_DISCOVERY_IMAGE_CACHE" in
    /var/lib/libvirt/images/aap-demo-fdi-image-latest.tar) return 0 ;;
    *)
      _err "SATELLITE_DISCOVERY_IMAGE_CACHE must be /var/lib/libvirt/images/aap-demo-fdi-image-latest.tar"
      return 1
      ;;
  esac
}

# Seed the guest before satellite-installer runs.  The Satellite Discovery
# Puppet resource deliberately uses replace => false, so a valid pre-existing
# tarball is extracted instead of fetched a second time.
_satellite_seed_discovery_image() {
  _satellite_discovery_cache_path_is_safe || return 1
  local cache_tmp guest_seed
  cache_tmp=$(mktemp) || return 1
  guest_seed=$(mktemp) || { rm -f -- "$cache_tmp"; return 1; }

  if sudo test -s "$SAT_DISCOVERY_IMAGE_CACHE" && \
    sudo tar -tf "$SAT_DISCOVERY_IMAGE_CACHE" >/dev/null 2>&1; then
    _log "✓ Reusing cached Satellite Discovery image: ${SAT_DISCOVERY_IMAGE_CACHE}"
  else
    _log "▸ Downloading Satellite Discovery image once into the libvirt cache..."
    if ! curl --fail --location --retry 3 --retry-delay 2 \
      --output "$cache_tmp" "$SAT_DISCOVERY_IMAGE_URL"; then
      _err "Could not download the Satellite Discovery image"
      rm -f -- "$cache_tmp" "$guest_seed"
      return 1
    fi
    if ! tar -tf "$cache_tmp" >/dev/null 2>&1; then
      _err "Downloaded Satellite Discovery image is not a valid tar archive"
      rm -f -- "$cache_tmp" "$guest_seed"
      return 1
    fi
    sudo install -d -m 0755 /var/lib/libvirt/images || { rm -f -- "$cache_tmp" "$guest_seed"; return 1; }
    sudo install -m 0644 "$cache_tmp" "${SAT_DISCOVERY_IMAGE_CACHE}.new" || { rm -f -- "$cache_tmp" "$guest_seed"; return 1; }
    sudo mv -f -- "${SAT_DISCOVERY_IMAGE_CACHE}.new" "$SAT_DISCOVERY_IMAGE_CACHE" || { rm -f -- "$cache_tmp" "$guest_seed"; return 1; }
    _log "✓ Cached Satellite Discovery image: ${SAT_DISCOVERY_IMAGE_CACHE}"
  fi

  # Read the root-owned cache through a user-owned temporary file so scp never
  # needs elevated privileges.  The temporary file is removed on every return.
  sudo install -m 0600 "$SAT_DISCOVERY_IMAGE_CACHE" "$guest_seed" || { rm -f -- "$cache_tmp" "$guest_seed"; return 1; }
  $SAT_SSH "install -d -m 0755 $(dirname "$SAT_DISCOVERY_IMAGE_GUEST_PATH")" || { rm -f -- "$cache_tmp" "$guest_seed"; return 1; }
  $SAT_SCP "$guest_seed" "root@${SAT_IP}:${SAT_DISCOVERY_IMAGE_GUEST_PATH}" || { rm -f -- "$cache_tmp" "$guest_seed"; return 1; }
  rm -f -- "$cache_tmp" "$guest_seed"
  _log "✓ Seeded cached Discovery image on the Satellite VM"
}

_satellite_installer_progress() {
  # The installer writes detailed Puppet output only after a resource finishes.
  # Polling its own log and the Discovery-image temporary file gives the CLI a
  # meaningful heartbeat while a single large resource is downloading.
  local status resource current total image_bytes image_mib
  status=$($SAT_SSH '
    log=/var/log/foreman-installer/satellite.log
    resource=""
    if test -r "$log"; then
      resource=$(grep "Starting to evaluate the resource" "$log" | tail -n 1 | sed -n "s/.*resource (\\([0-9][0-9]*\\) of \\([0-9][0-9]*\\)).*/\\1 \\2/p")
    fi
    image_bytes=$(find /var/lib/tftpboot/boot -maxdepth 1 -type f -name "fdi-image-latest.tar*" -printf "%s\\n" 2>/dev/null | sort -nr | head -n 1)
    printf "%s|%s\\n" "$resource" "$image_bytes"
  ' 2>/dev/null) || return 0
  resource=${status%%|*}
  image_bytes=${status#*|}
  if [ -n "$resource" ]; then
    current=${resource%% *}
    total=${resource##* }
    if [ "$total" -gt 0 ] 2>/dev/null; then
      _log "Satellite installer progress: ${current}/${total} resources ($((current * 100 / total))%)"
    fi
  fi
  if [ -n "$image_bytes" ] && [ "$image_bytes" -gt 0 ] 2>/dev/null; then
    image_mib=$((image_bytes / 1024 / 1024))
    _log "Discovery image transfer: ${image_mib} MiB downloaded"
  fi
}

_satellite_run_installer_with_progress() {
  local admin_pass="$1" installer_pid rc=0
  # Send the password over stdin; the installer reads it if
  # SATELLITE_ADMIN_PASSWORD is unset. This keeps it out of the host process
  # list and encrypted Vault exports.
  printf '%s\n' "$admin_pass" | $SAT_SSH \
    'SATELLITE_ADMIN_PASSWORD="${SATELLITE_ADMIN_PASSWORD:-$(cat)}" bash /root/02-satellite-installer.sh' &
  installer_pid=$!
  while kill -0 "$installer_pid" 2>/dev/null; do
    _satellite_installer_progress
    sleep 15
  done
  wait "$installer_pid" || rc=$?
  return "$rc"
}

_satellite_maintenance_progress() {
  # satellite-maintain delegates lengthy package work to DNF. Its stdout can be
  # silent for minutes, so expose a heartbeat with the cache growth and last
  # DNF status without leaking command arguments or credentials.
  local status task cache_mib message
  status=$($SAT_SSH '
    task=""
    pgrep -x dnf >/dev/null 2>&1 && task="package download/update"
    if test -z "$task" && pgrep -f "satellite-maintain" >/dev/null 2>&1; then
      task="Satellite maintenance"
    fi
    cache_mib=$(du -sm /var/cache/dnf 2>/dev/null | awk "{print \\$1}" || true)
    message=$(tail -n 1 /var/log/dnf.log 2>/dev/null | tr "\n" " " || true)
    printf "%s|%s|%s\\n" "$task" "$cache_mib" "$message"
  ' 2>/dev/null) || return 0
  task=${status%%|*}
  status=${status#*|}
  cache_mib=${status%%|*}
  message=${status#*|}
  [ -n "$task" ] || return 0
  _log "Satellite maintenance progress: ${task}${cache_mib:+ (DNF cache: ${cache_mib} MiB)}"
  [ -n "$message" ] && _log "  DNF: ${message}"
}

_satellite_run_maintenance_with_progress() {
  local backup_dir="$1" maintenance_pid rc=0
  printf 'export SATELLITE_BACKUP_DIR=%q\nbash /root/maintain-satellite.sh\n' "$backup_dir" | \
    $SAT_SSH 'bash -s' &
  maintenance_pid=$!
  while kill -0 "$maintenance_pid" 2>/dev/null; do
    _satellite_maintenance_progress
    sleep 15
  done
  wait "$maintenance_pid" || rc=$?
  return "$rc"
}

# A Satellite database is not interchangeable with another installation's
# Pulp tree.  The managed builder consequently creates a unique host export
# for a new VM.  The marker lives in disposable aap-demo state: a managed
# uninstall removes it, while a normal retry of a VM that already exists never
# reaches this helper.
_satellite_prepare_fresh_nfs() {
  local data_dir="${AAP_DEMO_DIR:-$HOME/.aap-demo}"
  local state_dir="$data_dir/satellite"
  local marker="$state_dir/nfs-install-id"
  local nfs_root="${SATLAB_NFS_ROOT:-/var/lib/satlab/instances}"
  local install_id expected_id expected_dir

  case "$nfs_root" in
    /*) ;;
    *) _err "SATLAB_NFS_ROOT must be an absolute path"; return 1 ;;
  esac
  case "$nfs_root" in
    *'..'* | *'//'*) _err "SATLAB_NFS_ROOT contains an unsafe path component"; return 1 ;;
  esac

  if [ -e "$marker" ]; then
    install_id=$(<"$marker")
  else
    install_id="${SATLAB_NFS_INSTALL_ID:-satellite-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}${RANDOM}}"
  fi
  [[ "$install_id" =~ ^satellite-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+$ ]] || {
    _err "Satellite NFS install marker is invalid; refusing to select an export"
    return 1
  }
  expected_dir="$nfs_root/$install_id/pulp"

  if [ -n "${SATLAB_NFS_DIR:-}" ] && [ "$SATLAB_NFS_DIR" != "$expected_dir" ]; then
    _err "SATLAB_NFS_DIR does not match the managed per-install export"
    return 1
  fi
  SATLAB_NFS_DIR="$expected_dir"

  # _stage_provision calls us only after confirming that the domain is absent.
  # An existing export here could be Pulp data from a failed/manual teardown;
  # starting a new VM against it would combine it with a new database.
  if sudo test -e "$SATLAB_NFS_DIR"; then
    _err "Satellite NFS export already exists without a managed VM: $SATLAB_NFS_DIR"
    _err "Preserve that data and review it; remove only the stale install marker before retrying."
    return 1
  fi

  if [ ! -e "$marker" ]; then
    mkdir -p "$state_dir" || return 1
    umask 077
    printf '%s\n' "$install_id" >"$marker" || return 1
  fi
  export SATLAB_NFS_DIR SATLAB_NFS_ROOT
  _log "✓ Fresh Satellite NFS export reserved: $SATLAB_NFS_DIR"
}

# --- stages -----------------------------------------------------------------
_stage_network() {
  _log "▸ Stage: network setup"
  sudo bash "${SCRIPT_DIR}/00-network-setup.sh"
}

_stage_manifest() {
  if [ "$_MANIFEST_PROVIDED" = true ]; then
    [ -s "$MANIFEST" ] || {
      _err "Provided manifest is missing or empty: $MANIFEST"
      return 1
    }
    _log "✓ Using provided manifest: $MANIFEST"
    return 0
  fi
  _log "▸ Stage: attach subscriptions and refresh manifest (satellite-manifest addon)"
  QUIET=true bash "${REPO_ROOT}/aap-demo.sh" enable satellite-manifest || return 1
  [ -s "$MANIFEST" ] || {
    _err "Manifest not produced at $MANIFEST"
    return 1
  }
}

_stage_provision() {
  if _sat_vm_exists; then
    _log "✓ Satellite VM already exists"
    return 0
  fi
  _satellite_reset_fresh_vm_ssh_trust || return 1
  _satellite_prepare_fresh_nfs || return 1
  # The ISO is downloaded automatically from the CDN (using the host's RHSM
  # entitlement cert) when missing. Default to the DVD (full offline package
  # tree). A CDN/network install is not used: the boot ISO carries no packages
  # and the CDN does not publish a .treeinfo-bearing install tree, so Anaconda
  # cannot set up a network software source. The DVD is the reliable path.
  local install_source="${RHEL_INSTALL_SOURCE:-dvd}"
  _log "▸ Stage: provision Satellite VM (unattended kickstart, source=$install_source)"
  local rhsm_user rhsm_pass rhsm_org rhsm_ak ssh_pubkey root_pass
  rhsm_user=$(_vault_val RHSM_USERNAME)
  rhsm_pass=$(_vault_val RHSM_PASSWORD)
  rhsm_org=$(_vault_val RHSM_ORG_ID)
  rhsm_ak=$(_vault_val RHSM_ACTIVATION_KEY)
  root_pass=$(aap_demo_satellite_root_password) || {
    _err "Could not read/generate the Satellite root password from the Vault"
    return 1
  }
  # Pass the invoking user's SSH public key (sudo changes $HOME to /root).
  ssh_pubkey=""
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    [ -f "$k" ] && {
      ssh_pubkey=$(cat "$k")
      break
    }
  done
  sudo \
    ROOTPW="$root_pass" RHSM_USER="$rhsm_user" RHSM_PASS="$rhsm_pass" \
    RHSM_ORG="$rhsm_org" RHSM_AK="$rhsm_ak" \
    SATELLITE_SSH_PUBKEY="$ssh_pubkey" \
    SATLAB_NFS_DIR="$SATLAB_NFS_DIR" SATLAB_NFS_ROOT="${SATLAB_NFS_ROOT:-/var/lib/satlab/instances}" \
    SATLAB_NFS_REQUIRE_SCOPED=1 \
    RHEL_ISO="$RHEL_ISO" RHEL_INSTALL_SOURCE="$install_source" \
    bash "${SCRIPT_DIR}/01-provision-satellite-vm.sh"
  unset root_pass
}

_stage_wait_install() {
  _log "▸ Stage: wait for the kickstart install to finish (VM reboots when done)"
  # The installer reboots the VM; SSH becomes available once RHEL is up.
  # With virt-install --noautoconsole + the kickstart `reboot`, the VM can be
  # left shut off after the install completes — detect that and start it.
  local attempt ssh_rc
  for attempt in $(seq 1 120); do
    ssh_rc=0
    _sat_ssh_ready || ssh_rc=$?
    case "$ssh_rc" in
      0)
        _log "✓ Satellite VM is up and reachable over SSH"
        return 0
        ;;
      2)
        _sat_ssh_trust_error
        return 1
        ;;
    esac
    # If the VM is shut off, the install finished and it needs starting.
    if [ "$($VIRSH domstate satellite 2>/dev/null)" = "shut off" ]; then
      _log "  VM is off after install; starting it..."
      $VIRSH start satellite >/dev/null 2>&1 || true
      $VIRSH autostart satellite >/dev/null 2>&1 || true
    fi
    sleep 15
  done
  _err "Timed out waiting for the Satellite VM to become SSH-ready"
  return 1
}

# Register the VM with RHSM over SSH (post-boot). The kickstart %post cannot
# register reliably: there is no TTY to debug auth failures, and a bad
# credential hangs the install silently. Doing it here surfaces errors and
# lets us retry. Order: existing registration -> activation key -> shared CDN
# username/password -> legacy RHSM username/password -> existing cert access
# -> host entitlement certs (the same CDN cert-auth pattern 00a-fetch-rhel-iso.sh
# uses for the ISO download). Certificate-only access can install packages but
# cannot enable Cloud Connector, so it is deliberately the fallback.
_stage_register() {
  if $SAT_SSH 'subscription-manager identity >/dev/null 2>&1'; then
    _log "✓ Satellite VM already registered with RHSM"
    _stage_repos
    return 0
  fi
  _log "▸ Stage: register Satellite VM with RHSM"
  local rhsm_user rhsm_pass legacy_user legacy_pass rhsm_org rhsm_ak
  # The shared CDN values are retained in the encrypted Vault by the
  # subscription attachment workflow. Keep legacy RHSM keys as a compatibility
  # fallback for existing lab Vaults.
  rhsm_user=$(_vault_val aap_demo.redhat.cdn_username)
  rhsm_pass=$(_vault_val aap_demo.redhat.cdn_password)
  legacy_user=$(_vault_val RHSM_USERNAME)
  legacy_pass=$(_vault_val RHSM_PASSWORD)
  rhsm_org=$(_vault_val RHSM_ORG_ID)
  rhsm_ak=$(_vault_val RHSM_ACTIVATION_KEY)

  if [ -n "$rhsm_ak" ] && [ -n "$rhsm_org" ]; then
    _log "  using activation key (org $rhsm_org)"
    if $SAT_SSH "subscription-manager register --org='$rhsm_org' --activationkey='$rhsm_ak'"; then
      _stage_repos
      return 0
    fi
    _log "  activation-key registration failed; trying next method"
  fi

  if [ -n "$rhsm_user" ] && [ -n "$rhsm_pass" ]; then
    _log "  using encrypted CDN credentials"
    # Pass the secret over stdin to keep it out of the process list.
    if printf '%s' "$rhsm_pass" | $SAT_SSH \
      "subscription-manager register --username='$rhsm_user' --password=\"$(cat)\" --auto-attach"; then
      _stage_repos
      return 0
    fi
    _log "  encrypted CDN credential registration failed"
  fi

  # Older Vaults can retain a separate RHSM pair. Try it only when it is a
  # complete, distinct credential; do not replace the shared CDN values.
  if [ -n "$legacy_user" ] && [ -n "$legacy_pass" ] \
    && { [ "$legacy_user" != "$rhsm_user" ] || [ "$legacy_pass" != "$rhsm_pass" ]; }; then
    _log "  trying legacy RHSM credentials"
    if printf '%s' "$legacy_pass" | $SAT_SSH \
      "subscription-manager register --username='$legacy_user' --password=\"$(cat)\" --auto-attach"; then
      _stage_repos
      return 0
    fi
    _log "  legacy RHSM credential registration failed"
  fi

  if $SAT_SSH 'dnf list satellite >/dev/null 2>&1'; then
    _log "✓ Satellite packages already accessible (entitlement certs present)"
    _stage_repos
    return 0
  fi

  _stage_register_host_certs
}

# Enable only the repos Satellite 6.17 on RHEL 9 needs. Enable and verify each
# repo individually: a combined --disable='*' --enable=... can silently drop a
# repo when the entitlement cert's content list has not refreshed yet.
_stage_repos() {
  local repo
  $SAT_SSH "subscription-manager repos --disable='*' >/dev/null" || return 1
  for repo in \
    rhel-9-for-x86_64-baseos-rpms \
    rhel-9-for-x86_64-appstream-rpms \
    satellite-6.17-for-rhel-9-x86_64-rpms \
    satellite-maintenance-6.17-for-rhel-9-x86_64-rpms; do
    $SAT_SSH "subscription-manager repos --enable='$repo' >/dev/null" || {
      _err "Failed to enable repository: $repo"
      return 1
    }
  done
  # Refresh metadata and confirm the satellite package is actually visible.
  # 'dnf list' (not 'list available') so an already-installed package passes.
  $SAT_SSH 'dnf clean all >/dev/null 2>&1; dnf list satellite >/dev/null 2>&1' || {
    _err "Satellite packages are not reachable after enabling repositories"
    return 1
  }
  _log "✓ Satellite VM content access ready"
}

# Fallback: copy the host's RHSM entitlement cert to the VM so it can pull
# packages from the CDN without its own registration. This mirrors how
# 00a-fetch-rhel-iso.sh downloads the RHEL ISO with the host cert.
_stage_register_host_certs() {
  _log "▸ Stage: grant the Satellite VM CDN access via the host entitlement"
  local ent_cert="" ent_key="" f
  for f in /etc/pki/entitlement/*.pem; do
    [ -e "$f" ] || continue
    case "$f" in
      *-key.pem) [ -z "$ent_key" ] && ent_key="$f" ;;
      *) [ -z "$ent_cert" ] && ent_cert="$f" ;;
    esac
  done
  if [ -z "$ent_cert" ] || [ -z "$ent_key" ]; then
    _err "No working RHSM credentials and no host entitlement cert found."
    _err "  Set RHSM credentials: aap-demo fleet auth configure"
    _err "  Or register this host: subscription-manager register ..."
    return 1
  fi

  $SAT_SSH 'mkdir -p /etc/pki/entitlement && chmod 755 /etc/pki/entitlement' || return 1
  $SAT_SCP "$ent_cert" "$ent_key" "root@${SAT_IP}:/etc/pki/entitlement/" || return 1
  $SAT_SSH 'chmod 600 /etc/pki/entitlement/*-key.pem' || return 1

  # subscription-manager reads entitlement certs directly from
  # /etc/pki/entitlement even without a consumer identity, so repo enablement
  # and dnf metadata fetches authenticate with the host cert.
  _stage_repos || return 1

  # Prove the Satellite repo metadata is reachable before the installer runs.
  $SAT_SSH 'dnf clean all >/dev/null 2>&1; dnf list satellite >/dev/null 2>&1' || {
    _err "Satellite packages are not reachable via the host entitlement cert"
    return 1
  }
  _log "✓ Satellite packages accessible via host entitlement cert"
}

_stage_installer() {
  if _sat_installed; then
    _log "✓ Satellite already installed"
    return 0
  fi
  _log "▸ Stage: run satellite-installer on the VM"
  # Pull the admin password from the encrypted Vault (generated on first use)
  # and pass it to the installer over the SSH environment, never on the command
  # line or in the repo.
  local admin_pass
  admin_pass=$(aap_demo_satellite_admin_password) || {
    _err "Could not read/generate the Satellite admin password from the Vault"
    return 1
  }
  $SAT_SCP "${SCRIPT_DIR}/02-satellite-installer.sh" "root@${SAT_IP}:/root/" || return 1
  _satellite_seed_discovery_image || return 1
  _satellite_run_installer_with_progress "$admin_pass" || {
    unset admin_pass
    return 1
  }
  unset admin_pass
}

_stage_maintenance() {
  _log "▸ Stage: maintain existing Satellite (backup, update, supported upgrades)"
  $SAT_SCP "${SCRIPT_DIR}/maintain-satellite.sh" "root@${SAT_IP}:/root/" || return 1
  local rc boot_id new_boot_id attempt ready
  while :; do
    boot_id=$($SAT_SSH 'cat /proc/sys/kernel/random/boot_id') || return 1
    rc=0
    _satellite_run_maintenance_with_progress \
      "${SATELLITE_BACKUP_DIR:-/var/backup/satellite}" || rc=$?
    [ "$rc" -ne 194 ] || {
      _log "Satellite maintenance requires a reboot; waiting for a new boot"
      $SAT_SSH 'systemd-run --collect --unit=aap-demo-satellite-reboot --on-active=3s systemctl reboot' || return 1
      ready=false
      for attempt in $(seq 1 120); do
        sleep 5
        new_boot_id=$($SAT_SSH 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) || continue
        if [ -n "$new_boot_id" ] && [ "$new_boot_id" != "$boot_id" ]; then
          ready=true
          break
        fi
      done
      [ "$ready" = true ] || {
        _err "Satellite did not return after reboot"
        return 1
      }
      continue
    }
    return "$rc"
  done
}

_stage_upload_manifest() {
  _log "▸ Stage: import subscription manifest"
  $SAT_SCP "$MANIFEST" "root@${SAT_IP}:/root/manifest.zip" || return 1
  {
    printf 'set -euo pipefail\norg=%q\n' "${SAT_ORG:-}"
    cat <<'REMOTE'
if [ -z "$org" ]; then
  orgs=$(hammer --output json organization list)
  if [ "$(jq length <<<"$orgs")" -eq 1 ]; then
    org=$(jq -er '.[0].Name' <<<"$orgs")
  else
    candidates='[]'
    while IFS= read -r row; do
      id=$(jq -er '.Id' <<<"$row")
      repos=$(hammer --output json repository list --organization-id "$id")
      if [ "$(jq length <<<"$repos")" -gt 0 ]; then
        candidates=$(jq -c --arg name "$(jq -er '.Name' <<<"$row")" '. + [$name]' <<<"$candidates")
      fi
    done < <(jq -c '.[]' <<<"$orgs")
    [ "$(jq length <<<"$candidates")" -eq 1 ] || {
      echo "ERROR: Cannot uniquely select the existing content organization; set SAT_ORG explicitly." >&2
      exit 1
    }
    org=$(jq -er '.[0]' <<<"$candidates")
  fi
fi
hammer subscription upload --organization "$org" --file /root/manifest.zip
REMOTE
  } | $SAT_SSH 'bash -s'
}

_stage_content() {
  if _sat_content_done; then
    _stage_upload_manifest || return 1
    _log "✓ Satellite content already configured"
    return 0
  fi
  _log "▸ Stage: content architecture (manifest + RHEL 9/10 repos, on_demand)"
  $SAT_SCP "$MANIFEST" "root@${SAT_IP}:/root/manifest.zip" || return 1
  $SAT_SCP "${SCRIPT_DIR}/03-content-hammer.sh" "root@${SAT_IP}:/root/" || return 1
  $SAT_SSH 'bash /root/03-content-hammer.sh /root/manifest.zip' || return 1
}

_stage_sync_plan() {
  _log "▸ Stage: reconcile Satellite content sync plan"
  $SAT_SCP "${SCRIPT_DIR}/09-content-sync-plan.sh" "root@${SAT_IP}:/root/" || return 1
  local remote_env collection_token credentials_file
  collection_token=$(_vault_val ah_offline_token)
  credentials_file=""
  if [ -n "$collection_token" ]; then
    credentials_file=$(mktemp) || { unset collection_token; return 1; }
    chmod 600 "$credentials_file"
    printf 'export SATELLITE_COLLECTIONS_AUTH_TOKEN=%q\n' "$collection_token" >"$credentials_file"
    unset collection_token
    $SAT_SCP "$credentials_file" "root@${SAT_IP}:/root/.aap-demo-sync-plan.env" || {
      rm -f -- "$credentials_file"
      return 1
    }
    rm -f -- "$credentials_file"
  fi
  printf -v remote_env 'SAT_ORG=%q SATELLITE_SYNC_PLAN_NAME=%q SATELLITE_SYNC_PLAN_INTERVAL=%q SATELLITE_SYNC_PLAN_SYNC_DATE=%q' \
    "${SAT_ORG:-}" "${SATELLITE_SYNC_PLAN_NAME:-}" \
    "${SATELLITE_SYNC_PLAN_INTERVAL:-}" "${SATELLITE_SYNC_PLAN_SYNC_DATE:-}"
  $SAT_SSH "if [ -f /root/.aap-demo-sync-plan.env ]; then source /root/.aap-demo-sync-plan.env; rm -f /root/.aap-demo-sync-plan.env; fi; $remote_env bash /root/09-content-sync-plan.sh"
}

_stage_provisioning() {
  _log "▸ Stage: provisioning (kickstart host groups)"
  local root_pass
  root_pass=$(aap_demo_satellite_provisioning_root_password) || {
    _err "Could not read/generate the provisioned-host root password from the Vault"
    return 1
  }
  $SAT_SCP "${SCRIPT_DIR}/04-provisioning-kickstart.sh" "root@${SAT_IP}:/root/" || return 1
  printf '%s\n' "$root_pass" | $SAT_SSH 'ROOTPW="$(cat)" bash /root/04-provisioning-kickstart.sh' || {
    unset root_pass
    return 1
  }
  unset root_pass
}

_stage_installation_media() {
  _log "▸ Stage: reconcile Satellite installation media"
  $SAT_SCP "${SCRIPT_DIR}/04-provisioning-kickstart.sh" "root@${SAT_IP}:/root/" || return 1
  $SAT_SSH 'SATELLITE_MEDIA_ONLY=true bash /root/04-provisioning-kickstart.sh'
}

_stage_openscap() {
  _log "▸ Stage: enable OpenSCAP and load SCAP content"
  $SAT_SCP "${SCRIPT_DIR}/10-openscap.sh" "root@${SAT_IP}:/root/" || return 1
  local _satellite_openscap_env
  printf -v _satellite_openscap_env 'SAT_ORG=%q SATELLITE_LOCATION=%q' \
    "${SAT_ORG:-Default Organization}" "${SATELLITE_LOCATION:-Lab}"
  $SAT_SSH "$_satellite_openscap_env bash /root/10-openscap.sh"
}

_stage_integrations() {
  _log "▸ Stage: integrations (libvirt compute resource, rhc/Insights)"

  # The Satellite's foreman user drives the hypervisor over qemu+ssh. The
  # host's sshd policy (99-csb-remote-access.conf) sets PermitRootLogin no, so
  # the compute resource connects as the invoking user (who is in the libvirt
  # group), never root. Generate the foreman key on the VM, then authorize it
  # in that user's authorized_keys here (this orchestrator runs on the host).
  local hv_user="${SATELLITE_HYPERVISOR_USER:-${SUDO_USER:-$USER}}"
  $SAT_SSH 'sudo -u foreman mkdir -p /usr/share/foreman/.ssh && \
    [ -f /usr/share/foreman/.ssh/id_ed25519 ] || \
    sudo -u foreman ssh-keygen -t ed25519 -N "" -f /usr/share/foreman/.ssh/id_ed25519' || return 1
  local foreman_pubkey
  foreman_pubkey=$($SAT_SSH 'cat /usr/share/foreman/.ssh/id_ed25519.pub' 2>/dev/null) || {
    _err "Could not read the foreman public key from the Satellite VM"
    return 1
  }
  if [ -n "$foreman_pubkey" ]; then
    local hv_home auth_keys
    hv_home=$(getent passwd "$hv_user" | cut -d: -f6)
    auth_keys="$hv_home/.ssh/authorized_keys"
    mkdir -p "$hv_home/.ssh" && chmod 700 "$hv_home/.ssh"
    touch "$auth_keys" && chmod 600 "$auth_keys"
    chown -R "$hv_user:$(id -gn "$hv_user")" "$hv_home/.ssh"
    grep -qF "$foreman_pubkey" "$auth_keys" 2>/dev/null || {
      echo "$foreman_pubkey" >>"$auth_keys"
      _log "  Authorized the Satellite foreman key on the hypervisor ($hv_user)"
    }
  fi

  $SAT_SCP "${SCRIPT_DIR}/06-integrations.sh" "root@${SAT_IP}:/root/" || return 1
  $SAT_SCP "${SCRIPT_DIR}/configure-cloud-connector.sh" "root@${SAT_IP}:/root/" || return 1
  # Pass the hypervisor user so the compute resource URL is qemu+ssh://user@host.
  $SAT_SSH "HYPERVISOR_USER='$hv_user' bash /root/06-integrations.sh" || return 1
}

_stage_settings_baseline() {
  _log "▸ Stage: reconcile Satellite provisioning and management settings"
  $SAT_SCP "${SCRIPT_DIR}/11-settings-baseline.sh" "root@${SAT_IP}:/root/" || return 1
  local remote_env
  printf -v remote_env 'SAT_ORG=%q SATELLITE_LOCATION=%q' \
    "${SAT_ORG:-Default Organization}" "${SATELLITE_LOCATION:-Lab}"
  $SAT_SSH "$remote_env bash /root/11-settings-baseline.sh"
}

_stage_rhis_report_templates() {
  _log "▸ Stage: optional RHIS Satellite report templates"
  $SAT_SCP "${SCRIPT_DIR}/12-rhis-report-templates.sh" "root@${SAT_IP}:/root/" || return 1
  local remote_env
  printf -v remote_env 'SAT_ORG=%q SATELLITE_IMPORT_RHIS_TEMPLATES=%q SATELLITE_RHIS_TEMPLATE_LICENSE_ACCEPTED=%q' \
    "${SAT_ORG:-Default Organization}" "${SATELLITE_IMPORT_RHIS_TEMPLATES:-false}" \
    "${SATELLITE_RHIS_TEMPLATE_LICENSE_ACCEPTED:-false}"
  $SAT_SSH "$remote_env bash /root/12-rhis-report-templates.sh"
}

_stage_general_nodes() {
  local count prefix resource profile image attrs volume interface remote_env
  count="${SATELLITE_GENERAL_NODE_COUNT:-0}"
  prefix="${SATELLITE_GENERAL_NODE_PREFIX:-aap-demo-general-node}"
  resource="${SATELLITE_COMPUTE_RESOURCE:-KVM-Host}"
  profile="${SATELLITE_GENERAL_NODE_COMPUTE_PROFILE:-aap-demo-general-small}"
  image="${SATELLITE_GENERAL_NODE_IMAGE:-}"
  attrs="${SATELLITE_GENERAL_NODE_COMPUTE_ATTRIBUTES:-}"
  volume="${SATELLITE_GENERAL_NODE_VOLUME:-}"
  interface="${SATELLITE_GENERAL_NODE_INTERFACE:-}"
  if [ "$count" = 0 ]; then
    _log "✓ General Satellite VM nodes not requested (set SATELLITE_GENERAL_NODE_COUNT=3 with an image to enable)"
    return 0
  fi
  _log "▸ Stage: provision ${count} general Satellite VM node(s)"
  $SAT_SCP "${SCRIPT_DIR}/08-provision-general-nodes.sh" "root@${SAT_IP}:/root/" || return 1
  printf -v remote_env 'SATELLITE_GENERAL_NODE_COUNT=%q SATELLITE_GENERAL_NODE_PREFIX=%q SATELLITE_COMPUTE_RESOURCE=%q SATELLITE_GENERAL_NODE_COMPUTE_PROFILE=%q SATELLITE_GENERAL_NODE_IMAGE=%q SATELLITE_GENERAL_NODE_COMPUTE_ATTRIBUTES=%q SATELLITE_GENERAL_NODE_VOLUME=%q SATELLITE_GENERAL_NODE_INTERFACE=%q' \
    "$count" "$prefix" "$resource" "$profile" "$image" "$attrs" "$volume" "$interface"
  $SAT_SSH "$remote_env bash /root/08-provision-general-nodes.sh"
}

# Trust the Satellite's Katello CA on the host so the UI and CLI tools stop
# warning about the self-signed cert. Runs as the invoking user (not root) so
# the NSS import lands in that user's browser stores; the system ca-trust
# import uses sudo. Idempotent and skipped when the CA is already trusted.
_stage_ca_trust() {
  _log "▸ Stage: trust Satellite CA on host (browser + CLI)"
  # The orchestrator may run under sudo; import into the invoking user's
  # stores so browser trust lands in the right NSS DB.
  if [ -n "${SUDO_USER:-}" ]; then
    sudo -u "$SUDO_USER" AAP_DEMO_TRUST_CA="${AAP_DEMO_TRUST_CA:-true}" \
      bash -c "source '${REPO_ROOT}/includes/satellite-ca-trust.sh'; install_satellite_ca_trust" || return 1
  else
    install_satellite_ca_trust || return 1
  fi
}

_stage_cloud_connector() {
  $SAT_SCP "${SCRIPT_DIR}/configure-cloud-connector.sh" "root@${SAT_IP}:/root/" || return 1
  $SAT_SSH 'bash /root/configure-cloud-connector.sh'
}

main() {
  local install_state=unreachable ssh_rc=0 registration_reconciled=false
  if [ "${1:-}" = --cloud-connector-only ] && [ "$#" -eq 1 ]; then
    workflow_begin satellite-cloud-connector || return 1
    workflow_phase cloud-connector _stage_cloud_connector || return 1
    workflow_finish
    return $?
  fi
  if [ "${1:-}" = --manifest-only ] && [ "$#" -eq 1 ]; then
    workflow_begin satellite-manifest || return 1
    workflow_phase manifest _stage_manifest || return 1
    workflow_phase upload-manifest _stage_upload_manifest || return 1
    workflow_finish
    return $?
  fi
  if [ "$#" -ne 0 ]; then
    _err "Usage: build-and-configure.sh [--manifest-only|--cloud-connector-only]"
    return 1
  fi
  workflow_begin satellite || return 1
  echo ""
  echo "Satellite Build and Configure - reconciling the Satellite lab..."
  _sat_ssh_ready || ssh_rc=$?
  if [ "$ssh_rc" -eq 0 ]; then
    install_state=$(workflow_phase inspect-installation _sat_install_state) || return 1
  elif [ "$ssh_rc" -eq 2 ]; then
    workflow_phase ssh-trust _sat_ssh_trust_error || return 1
  fi
  if [ "$install_state" = installed ]; then
    _log "✓ Satellite RPM already installed; preserving its configuration"
    workflow_phase maintenance _stage_maintenance || return 1
    workflow_phase manifest _stage_manifest || return 1
    workflow_phase upload-manifest _stage_upload_manifest || return 1
  else
    workflow_phase network _stage_network || return 1
    workflow_phase manifest _stage_manifest || return 1
    workflow_phase provision _stage_provision || return 1
    workflow_phase wait-install _stage_wait_install || return 1
    install_state=$(workflow_phase inspect-installation _sat_install_state) || return 1
    if [ "$install_state" = installed ]; then
      workflow_phase maintenance _stage_maintenance || return 1
      workflow_phase upload-manifest _stage_upload_manifest || return 1
    else
      workflow_phase register _stage_register || return 1
      registration_reconciled=true
      workflow_phase installer _stage_installer || return 1
      workflow_phase maintenance _stage_maintenance || return 1
      workflow_phase content _stage_content || return 1
    fi
  fi
  if [ "$registration_reconciled" = false ]; then
    # Existing Satellites need a direct RHSM identity too: certificate-only CDN
    # access is sufficient for package maintenance but not for Cloud Connector.
    workflow_phase registration _stage_register || return 1
  fi
  # Keep provisioning primitives current for both a new VM and an existing
  # Satellite. The stage updates only the owned demo domain/subnet, media,
  # host groups, and activation-key parameter.
  workflow_phase provisioning _stage_provisioning || return 1
  # Reconcile the local compute resource/profile, DNS/DHCP/Rex Capsule wiring,
  # Ansible roles, and Cloud Connector on every run. This is intentionally
  # outside the first-install branch so an existing Satellite receives the same
  # declarative configuration as a freshly created one.
  workflow_phase integrations _stage_integrations || return 1
  workflow_phase settings _stage_settings_baseline || return 1
  workflow_phase installation-media _stage_installation_media || return 1
  workflow_phase sync-plan _stage_sync_plan || return 1
  workflow_phase openscap _stage_openscap || return 1
  workflow_phase rhis-report-templates _stage_rhis_report_templates || return 1
  workflow_phase general-nodes _stage_general_nodes || return 1
  workflow_phase ca-trust _stage_ca_trust || return 1
  workflow_finish || return 1
  echo ""
  echo "✓ Satellite Build and Configure complete"
  echo "  Satellite UI: https://${SAT_HOST} (admin / see 'aap-demo status --show-secrets')"
  echo "  Next: aap-demo enable product-demo-satellite (Satellite Demo content)"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
