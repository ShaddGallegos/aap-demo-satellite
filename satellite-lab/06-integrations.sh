#!/usr/bin/env bash
# 06-integrations.sh — run ON the Satellite VM as root.
# 1) Local libvirt compute resource (provision fleet VMs onto this KVM host)
# 2) Red Hat connector (rhc) / Insights rollout across the fleet
set -euo pipefail

HYPERVISOR=192.168.122.1     # KVM host, reachable via the 'default' network NIC
# The hypervisor's sshd refuses root login (PermitRootLogin no via the
# csb-remote-access policy), so the compute resource connects as a dedicated
# user in the host's libvirt group. Passed by build-and-configure.sh.
HYPERVISOR_USER="${HYPERVISOR_USER:-}"
ORG="${SAT_ORG:-Default Organization}"
LOC="${SATELLITE_LOCATION:-Lab}"
SATELLITE_PROXY="${SATELLITE_PROXY:-satellite.demo.lab}"
SATELLITE_SUBNET="${SATELLITE_SUBNET:-satlab}"
COMPUTE_RESOURCE="${SATELLITE_COMPUTE_RESOURCE:-KVM-Host}"
COMPUTE_PROFILE="${SATELLITE_COMPUTE_PROFILE:-aap-demo-general-small}"

reconcile_satellite_plugins() {
  # Assert the plugins used by the local lab in one installer run. The
  # installer is declarative, so repeating this leaves existing settings intact.
  satellite-installer --scenario satellite \
    --enable-foreman-plugin-rh-cloud \
    --enable-foreman-plugin-remote-execution \
    --enable-foreman-proxy-plugin-remote-execution-script \
    --enable-foreman-plugin-ansible \
    --enable-foreman-proxy-plugin-ansible
}

reconcile_compute_profile() {
  # This profile is deliberately local/libvirt only. Cloud and VMware provider
  # profiles require explicit, provider-specific preflight and credentials.
  if hammer compute-profile info --name "$COMPUTE_PROFILE" >/dev/null 2>&1; then
    echo "  compute profile $COMPUTE_PROFILE already exists"
  else
    hammer compute-profile create --name "$COMPUTE_PROFILE" \
      --location "$LOC" --organization "$ORG"
  fi

  local output
  if output=$(hammer compute-profile values create \
    --compute-profile "$COMPUTE_PROFILE" --compute-resource "$COMPUTE_RESOURCE" \
    --compute-attributes 'cpus=2,memory=4294967296' \
    --volume 'pool_name=default,capacity=15G,format_type=qcow2' \
    --interface 'compute_type=network,compute_network=satlab,compute_model=virtio' 2>&1); then
    echo "  ✓ compute profile $COMPUTE_PROFILE set to 2 vCPU / 4096 MiB / 15 GiB"
  elif [[ "$output" == *already* || "$output" == *exists* ]]; then
    hammer compute-profile values update \
      --compute-profile "$COMPUTE_PROFILE" --compute-resource "$COMPUTE_RESOURCE" \
      --compute-attributes 'cpus=2,memory=4294967296' \
      --volume 'pool_name=default,capacity=15G,format_type=qcow2' \
      --interface 'compute_type=network,compute_network=satlab,compute_model=virtio'
    echo "  ✓ compute profile $COMPUTE_PROFILE refreshed to 2 vCPU / 4096 MiB / 15 GiB"
  else
    printf '%s\n' "$output" >&2
    return 1
  fi
}

reconcile_remote_execution() {
  local proxy proxy_id subnet existing_ids ids
  proxy=$(hammer --output json proxy list --search "name = $SATELLITE_PROXY") || return 1
  proxy_id=$(jq -er '.[0].Id // .[0].id' <<<"$proxy") || {
    echo "ERROR: Remote Execution Capsule '$SATELLITE_PROXY' was not found" >&2
    return 1
  }
  subnet=$(hammer --output json subnet info --name "$SATELLITE_SUBNET") || return 1
  existing_ids=$(jq -r '."Remote execution proxies"[]? | (.Id // .id)' <<<"$subnet" | sort -un)
  ids=$(printf '%s\n%s\n' "$existing_ids" "$proxy_id" | awk 'NF && !seen[$0]++' | paste -sd, -)
  [ -n "$ids" ] || return 1
  hammer subnet update --name "$SATELLITE_SUBNET" --remote-execution-proxy-ids "$ids"
  subnet=$(hammer --output json subnet info --name "$SATELLITE_SUBNET") || return 1
  jq -e --argjson proxy_id "$proxy_id" \
    'any(."Remote execution proxies"[]?; (.Id // .id) == $proxy_id)' <<<"$subnet" >/dev/null || {
      echo "ERROR: Remote Execution Capsule was not assigned to subnet '$SATELLITE_SUBNET'" >&2
      return 1
    }
  echo "  ✓ Remote Execution Capsule $SATELLITE_PROXY assigned to subnet $SATELLITE_SUBNET"
}

reconcile_ansible_roles() {
  local proxy proxy_id fetched roles requested remaining deadline
  proxy=$(hammer --output json proxy list --search "name = $SATELLITE_PROXY") || return 1
  proxy_id=$(jq -er '.[0].Id // .[0].id' <<<"$proxy") || {
    echo "ERROR: Ansible Capsule '$SATELLITE_PROXY' was not found" >&2
    return 1
  }
  # Satellite 6.17 queues a role-sync task but does not import its discovered
  # roles unless their names are supplied. Fetch first, then synchronize the
  # complete available set; this keeps future role additions idempotent.
  fetched=$(hammer --output json ansible roles fetch --proxy-id "$proxy_id" \
    --organization "$ORG" --location "$LOC") || return 1
  requested=$(jq -r '.. | objects | .["Role Name"]? // empty' <<<"$fetched" \
    | paste -sd, -)
  if [ -n "$requested" ]; then
    hammer ansible roles sync --proxy-id "$proxy_id" --role-names "$requested" \
      --organization "$ORG" --location "$LOC"
    deadline=$((SECONDS + ${SATELLITE_ANSIBLE_ROLE_SYNC_TIMEOUT:-180}))
    while [ "$SECONDS" -lt "$deadline" ]; do
      fetched=$(hammer --output json ansible roles fetch --proxy-id "$proxy_id" \
        --organization "$ORG" --location "$LOC") || return 1
      remaining=$(jq -r '.. | objects | .["Role Name"]? // empty' <<<"$fetched" | wc -l)
      [ "$remaining" -eq 0 ] && break
      echo "  ▸ Waiting for ${remaining} Ansible role(s) to import..."
      sleep 3
    done
    [ "${remaining:-0}" -eq 0 ] || {
      echo "ERROR: Timed out waiting for Satellite Ansible roles to import" >&2
      return 1
    }
  else
    echo "  ✓ No new Ansible roles need importing"
  fi
  roles=$(hammer --output json ansible roles list --organization "$ORG" --location "$LOC") || return 1
  jq -e 'length > 0' <<<"$roles" >/dev/null || {
    echo "ERROR: No Ansible roles were imported; verify the Satellite Ansible role paths" >&2
    return 1
  }
  echo "  ✓ Imported $(jq 'length' <<<"$roles") Ansible role(s) into Satellite"
}

echo "== 1. Libvirt compute resource and profile =="
# The Libvirt provider uses qemu+ssh as the 'foreman' user -> the hypervisor
# user (libvirt group member; the host's sshd refuses root login).
sudo -u foreman mkdir -p /usr/share/foreman/.ssh
[[ -f /usr/share/foreman/.ssh/id_ed25519 ]] || \
  sudo -u foreman ssh-keygen -t ed25519 -N '' -f /usr/share/foreman/.ssh/id_ed25519
# The foreman public key is authorized on the hypervisor by the orchestrator
# (build-and-configure.sh runs on the host) before this script runs. Here we
# only accept the host key and verify the connection non-interactively.
# The hypervisor user must be in the host's libvirt group (root login is
# refused by the host's sshd policy).
HV_CONN_USER="${HYPERVISOR_USER:-root}"
sudo -u foreman ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 "${HV_CONN_USER}@$HYPERVISOR" true

# Idempotent: the compute resource persists across re-runs.
if hammer compute-resource info --name "$COMPUTE_RESOURCE" >/dev/null 2>&1; then
  echo "  compute resource $COMPUTE_RESOURCE already exists"
else
  hammer compute-resource create --name "$COMPUTE_RESOURCE" --provider Libvirt \
    --url "qemu+ssh://${HV_CONN_USER}@$HYPERVISOR/system" \
    --display-type VNC --set-console-password true \
    --locations "$LOC" --organizations "$ORG"
fi

# Verify Satellite can see the satlab network + storage pools on the hypervisor.
# These queries are not implemented for the Libvirt provider in some Satellite
# versions (ERF42-7329); they are informational only, so never fail the build.
hammer compute-resource networks --name "$COMPUTE_RESOURCE" || \
  echo "  (networks query not supported for Libvirt here — continuing)"
if hammer compute-resource --help 2>&1 | grep -q 'storage-pools'; then
  hammer compute-resource storage-pools --name "$COMPUTE_RESOURCE" || \
    echo "  (storage-pools query not supported for Libvirt here — continuing)"
else
  echo "  (storage-pool query is not provided by this Satellite CLI — continuing)"
fi
reconcile_compute_profile

echo
echo "== 2. Remote Execution and Ansible roles =="
reconcile_satellite_plugins
reconcile_remote_execution
reconcile_ansible_roles

echo
echo "== 3. Red Hat connector (rhc) / Insights =="
bash "$(dirname "${BASH_SOURCE[0]}")/configure-cloud-connector.sh"
echo "Fleet nodes must be registered through Satellite and verified separately."
echo "No remediation or direct-cloud node registration jobs were launched."
