#!/usr/bin/env bash
# =============================================================================
# fleet-satellite.sh — Register running Fleet nodes to the Satellite lab
# =============================================================================
#
# Fleet nodes register to the Satellite (not directly to Red Hat) so content
# is served from the local Pulp, hosts appear in the Satellite inventory, and
# Insights data flows through the Satellite's rh_cloud connector. Each node:
#   1. trusts the Satellite CA (katello-ca-consumer)
#   2. registers with subscription-manager using a Satellite activation key
#   3. enables Insights + remote execution (rhc) via the Satellite
#
# Usage:
#   source "${SCRIPT_DIR}/includes/fleet-satellite.sh"
#   fleet_satellite_register
#
# =============================================================================

if [ -n "${_FLEET_SATELLITE_LOADED:-}" ]; then return 0; fi
_FLEET_SATELLITE_LOADED=1

# shellcheck source=fleet-access.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fleet-access.sh"

SAT_HOST="${SATELLITE_LAB_HOST:-satellite.demo.lab}"
SAT_IP="${SATELLITE_LAB_IP:-192.168.122.20}"
SAT_AK_NAME="${SAT_FLEET_AK:-fleet-rhel9}"
# The APD lab profile supplies the discovered content organization explicitly.
SAT_ORG="${SAT_ORG:-Demo Org}"
SAT_ORG_LABEL="${SAT_ORG_LABEL:-Demo_Org}"

_sat_ssh() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=10 "root@${SAT_IP}" "$@"
}

# Ensure the Satellite has an activation key for the fleet; echo its name.
_fleet_satellite_ensure_ak() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    "${script_dir}/../satellite-lab/07-fleet-activation-key.sh" "root@${SAT_IP}:/root/" >/dev/null 2>&1 || return 1
  printf '%s\t%s\t%s\t%s\n' "$SAT_ORG" "$SAT_AK_NAME" "${SAT_FLEET_CV:-RHEL9}" "${SAT_FLEET_LCE:-Library}" \
    | _sat_ssh 'IFS="$(printf "\t")" read -r SAT_ORG SAT_FLEET_AK SAT_FLEET_CV SAT_FLEET_LCE
export SAT_ORG SAT_FLEET_AK SAT_FLEET_CV SAT_FLEET_LCE
bash /root/07-fleet-activation-key.sh' | tail -1
}

# Register a single node. Credentials and the AK name cross SSH via stdin,
# never as argv, so they do not leak into the remote process list or logs.
_fleet_satellite_register_node() {
  local port="$1" ak_name="$2"
  local remote ca expected_major="${SAT_FLEET_CV:-RHEL9}"
  expected_major="${expected_major#RHEL}"
  ca=$(curl -fsS --connect-timeout 10 --max-time 60 \
    "https://${SAT_HOST}/pub/katello-server-ca.crt") || {
    _err "Cannot fetch the Satellite CA through the host's trusted HTTPS connection"
    return 1
  }
  printf '%s' "$ca" | openssl x509 -noout -text | grep -q 'CA:TRUE' || {
    _err "Satellite did not return a CA certificate"
    return 1
  }
  remote=$(cat <<'REMOTE'
set -euo pipefail
# Registration parameters and the public CA arrive on stdin, not in argv.
IFS=$'\t' read -r ak_name sat_host sat_ip org_label expected_major
# Validate the host is a bare FQDN/IP before it is used in URLs and rpm names.
case "$sat_host" in
  *[!a-zA-Z0-9.-]* | "" | .* | *..*)
    echo "ERROR: invalid satellite host: $sat_host" >&2
    exit 1
    ;;
esac
[[ "$sat_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: invalid Satellite IPv4 address" >&2; exit 1;
}
source /etc/os-release
if [ "${VERSION_ID%%.*}" != "$expected_major" ]; then
  echo "ERROR: RHEL major does not match the selected Satellite content view" >&2
  exit 1
fi
ca_file=$(mktemp /tmp/aap-demo-satellite-ca.XXXXXX)
rpm_file=$(mktemp /tmp/aap-demo-satellite-consumer.XXXXXX.rpm)
trap 'rm -f "$ca_file" "$rpm_file"' EXIT
cat >"$ca_file"
openssl x509 -in "$ca_file" -noout -text | grep -q 'CA:TRUE'
resolved=$(getent ahostsv4 "$sat_host" | awk 'NR == 1 {print $1}') || resolved=""
if [ -z "$resolved" ]; then
  printf '%s %s # aap-demo Satellite\n' "$sat_ip" "$sat_host" >>/etc/hosts
elif [ "$resolved" != "$sat_ip" ]; then
  echo "ERROR: $sat_host resolves to $resolved, expected $sat_ip; refusing to replace custom DNS" >&2
  exit 1
fi
# Fetch and validate the consumer package before changing an existing registration.
curl -fsS --cacert "$ca_file" --connect-timeout 10 --max-time 60 \
  "https://${sat_host}/pub/katello-ca-consumer-latest.noarch.rpm" -o "$rpm_file"
rpm -qp "$rpm_file" >/dev/null
current_server=$(subscription-manager config --list | awk '
  $1 == "hostname" {gsub(/[][]/, "", $3); print $3; exit}')
registered=false
if subscription-manager identity >/dev/null 2>&1; then
  registered=true
  if [ "$current_server" != "$sat_host" ]; then
    subscription-manager unregister
    registered=false
  elif ! subscription-manager identity | grep -Fq "org ID: $org_label"; then
    echo "ERROR: Host is registered to another Satellite organization; migrate it explicitly" >&2
    exit 1
  fi
fi

# 1. The public CA arrives over the existing SSH trust channel.
install -m 0644 "$ca_file" /etc/pki/ca-trust/source/anchors/aap-demo-satellite.crt
update-ca-trust
if ! rpm -q "katello-ca-consumer-${sat_host}" >/dev/null 2>&1; then
  rpm -Uvh "$rpm_file"
fi
subscription-manager config --server.hostname="$sat_host" --server.prefix=/rhsm \
  --server.port=443 --rhsm.baseurl="https://${sat_host}/pulp/content/"

# 2. Register to the Satellite with the activation key (idempotent). Fleet
# nodes are cloned from one image and share a DMI UUID, which Satellite
# rejects as a duplicate ("DMI UUID matches other registered hosts"). Give
# each node a unique product UUID before registering.
if [ "$registered" != true ]; then
  if [ ! -f /etc/aap-demo-fleet-uuid ]; then
    uuidgen > /etc/aap-demo-fleet-uuid
  fi
  mkdir -p /etc/rhsm/facts
  printf '{"dmi.system.uuid": "%s"}\n' "$(cat /etc/aap-demo-fleet-uuid)" \
    > /etc/rhsm/facts/uuid.facts
  subscription-manager register --org="$org_label" \
    --activationkey "$ak_name" >/dev/null
fi

# 3. Insights via the Satellite's rh_cloud connector. The client uploads to
# the Satellite, which forwards to Red Hat — but only after the org has a
# Hybrid Cloud branch ID (rh_cloud:hybridcloud_register). Register only when
# not already registered; a stale .registered file from a pre-Satellite direct
# attempt must be cleared first or --register refuses with "Machine-id found".
if rpm -q insights-client >/dev/null 2>&1; then
  if ! insights-client --status 2>/dev/null | grep -q "Insights API confirms registration"; then
    rm -f /etc/insights-client/.registered /etc/insights-client/.unregistered 2>/dev/null || true
    insights-client --register >/dev/null 2>&1 || true
  fi
fi
# Remote execution / rhc: connect when the daemon is present but not connected.
if rpm -q rhc >/dev/null 2>&1; then
  rhc status 2>/dev/null | grep -q "Remote Host Configuration daemon is active" \
    || rhc connect >/dev/null 2>&1 || true
fi

subscription-manager identity | grep -Fq "org ID: $org_label"
subscription-manager config --list | awk -v expected="$sat_host" '
  $1 == "hostname" {gsub(/[][]/, "", $3); if ($3 == expected) found=1}
  END {exit(found ? 0 : 1)}'
REMOTE
)
  { printf '%s\t%s\t%s\t%s\t%s\n' "$ak_name" "$SAT_HOST" "$SAT_IP" "$SAT_ORG_LABEL" \
      "$expected_major"; printf '%s\n' "$ca"; } \
    | fleet_stack_ssh "$port" "sudo bash -c $(
      printf '%q' "$remote"
    )"
}

fleet_satellite_register() {
  if [ "$#" -ne 0 ]; then
    _err "Usage: aap-demo fleet satellite-register (running Fleet VMs only)"
    return 1
  fi

  local nodes ak_name row index port failed=false
  nodes=$(fleet_access_inventory omit) || return 1
  nodes=$(jq -c '[.[] | select(.state == "running")]' <<<"$nodes") || return 1
  [ "$nodes" != '[]' ] || { _err "No running Fleet nodes to register"; return 1; }

  echo "Preparing Satellite activation key for the fleet..."
  ak_name=$(_fleet_satellite_ensure_ak) || {
    _err "Could not create the Satellite activation key (is the Satellite up?)"
    return 1
  }
  ak_name=$(tail -1 <<<"$ak_name" | tr -d '[:space:]')
  [ -n "$ak_name" ] || { _err "Satellite activation key name is empty"; return 1; }
  echo "  Using activation key: $ak_name"

  echo "Registering running Fleet nodes to Satellite ($SAT_HOST)..."
  while IFS= read -r row; do
    index=$(jq -r '.index' <<<"$row")
    port=$(jq -r '.ssh_port' <<<"$row")
    echo "  Fleet node $index:"
    if _fleet_satellite_register_node "$port" "$ak_name"; then
      echo "    ✓ registered to Satellite"
    else
      _err "Satellite registration failed for Fleet node $index"
      failed=true
    fi
  done < <(jq -c '.[]' <<<"$nodes")

  if [ "$failed" = true ]; then return 1; fi
  echo "✓ All running Fleet nodes are registered to the Satellite"
  echo "  Verify: ssh root@${SAT_IP} 'hammer host list'"
}
