#!/usr/bin/env bash
# 06-integrations.sh — run ON the Satellite VM as root.
# 1) Local libvirt compute resource (provision fleet VMs onto this KVM host)
# 2) Red Hat connector (rhc) / Insights rollout across the fleet
set -euo pipefail

HYPERVISOR=192.168.122.1     # KVM host, reachable via the 'default' network NIC
ORG="Demo Org"
LOC="Lab"

echo "== 1. Libvirt compute resource =="
# The Libvirt provider uses qemu+ssh as the 'foreman' user -> root on the hypervisor.
sudo -u foreman mkdir -p /usr/share/foreman/.ssh
[[ -f /usr/share/foreman/.ssh/id_ed25519 ]] || \
  sudo -u foreman ssh-keygen -t ed25519 -N '' -f /usr/share/foreman/.ssh/id_ed25519
sudo -u foreman ssh-copy-id -i /usr/share/foreman/.ssh/id_ed25519.pub "root@$HYPERVISOR"
sudo -u foreman ssh -o StrictHostKeyChecking=accept-new "root@$HYPERVISOR" true
# NOTE: hypervisor sshd must permit root login, or use a dedicated user in the
# 'libvirt' group and adjust the URL below accordingly.

hammer compute-resource create --name "KVM-Host" --provider Libvirt \
  --url "qemu+ssh://root@$HYPERVISOR/system" \
  --display-type vnc --set-console-password true \
  --locations "$LOC" --organizations "$ORG"

# Verify Satellite can see the satlab network + storage pools on the hypervisor
hammer compute-resource networks --name "KVM-Host"
hammer compute-resource storage-pools --name "KVM-Host"

echo
echo "== 2. Red Hat connector (rhc) / Insights =="
# Cloud plugin is enabled by default on current Satellite; harmless to re-assert:
satellite-installer --scenario satellite --enable-foreman-plugin-rh-cloud

# Stage the clients on every managed node via Remote Execution:
hammer job-invocation create --job-template "Run Command - Script Default" \
  --search-query "os_family = Redhat" \
  --inputs command="dnf install -y rhc insights-client"

cat <<'EOF'
Choose ONE connectivity pattern per node:

Option A — direct egress to the Hybrid Cloud Console (simplest demo path)
  # Create an activation key first: console.redhat.com -> Insights ->
  # Remote Host Configuration -> Activation keys (note your ORG ID from
  # console.redhat.com -> Settings -> Remote Host Configuration).
  hammer job-invocation create --job-template "Run Command - Script Default" \
    --search-query "os_family = Redhat" \
    --inputs command="rhc connect --organization RH_ORG_ID --activation-key INSIGHTS_AK && rhc status"
  # One command delivers: Insights registration + remediations (rhc worker) +
  # optional subscription attach. 'rhc disconnect' reverses it.

Option B — no node egress: Insights proxied through Satellite
  # katello-host-tools (installed at registration) already points insights-client
  # at the Satellite; hosts report via Satellite without internet access:
  #     insights-client --register        # automatic during host registration
  #     insights-client --status
  # Remediations need the Red Hat connector ON THE SATELLITE:
  #   console.redhat.com -> Insights -> Remediations -> Connections ->
  #   "Red Hat Satellite" -> run the generated Ansible playbook against the
  #   Satellite (it enables the rhc/cloud-connector worker locally).
  # Then: Insights -> Remediations -> select Satellite-managed hosts -> the fix
  # is pushed through Satellite Remote Execution (SSH).
EOF
