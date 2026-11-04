#!/usr/bin/env bash
# 01-provision-satellite-vm.sh — run on the KVM host as root.
# Creates the Satellite VM: 4 vCPU / 32 GB / 150 GB qcow2, dual-homed on the
# libvirt 'default' network (NAT to host/upstream) and the isolated 'satlab'
# network (Satellite-owned DHCP/PXE), kickstarted unattended.
#
# Adapted for CRC user-mode networking: no bridged 'crc' libvirt network exists
# on this host, so NIC1 uses 'default' and the VM reaches AAP/CRC through the
# host's forwarded ports.
set -euo pipefail
cd "$(dirname "$0")"

# ---- editable variables ---------------------------------------------------
VM_NAME=satellite
VM_VCPUS=4
VM_RAM=32768                                   # MiB
VM_DISK=/var/lib/libvirt/images/${VM_NAME}.qcow2
VM_DISK_SIZE=40                                # GiB (minimal OS; Pulp content on host NFS)
# Install source. Three options:
#   dvd (default): rhel-9.5-x86_64-dvd.iso  (~10 GB, fully offline install)
#   cdn:           rhel-9.5-x86_64-boot.iso (~1 GB) + packages from the CDN
#   netboot:       NO ISO at all — download just the kernel+initrd from the CDN
#                  (a few MB) using the host's RHSM entitlement cert, boot them,
#                  and install from the CDN tree. Fully automatic.
RHEL_ISO="${RHEL_ISO:-/var/lib/libvirt/images/rhel-9.5-x86_64-dvd.iso}"
RHEL_INSTALL_SOURCE="${RHEL_INSTALL_SOURCE:-dvd}"   # dvd | cdn | netboot
RHEL_VERSION="${RHEL_VERSION:-9.5}"
CDN_BASE="https://cdn.redhat.com/content/dist/rhel9/${RHEL_VERSION}/x86_64/baseos/kickstart"
HOST_NET=default                               # libvirt network for NIC1 (NAT to host)
LAB_NET=satlab                                 # from 00-network-setup.sh
MAC_HOST="52:54:00:5a:7e:01"                   # must match satellite-vm.ks
MAC_LAB="52:54:00:5a:7e:02"

# Secrets rendered into the kickstart (prefer env vars over editing this file)
ROOTPW="${ROOTPW:-RedHat123!}"
RHSM_ORG="${RHSM_ORG:-}"                       # activation-key org id (preferred)
RHSM_AK="${RHSM_AK:-}"                         # activation key name
RHSM_USER="${RHSM_USER:-}"                     # fallback: username/password
RHSM_PASS="${RHSM_PASS:-}"
# ---------------------------------------------------------------------------

VIRSH="virsh -c qemu:///system"

case "$RHEL_INSTALL_SOURCE" in
  dvd | cdn | netboot) ;;
  *) echo "ERROR: RHEL_INSTALL_SOURCE must be 'dvd', 'cdn', or 'netboot' (got '$RHEL_INSTALL_SOURCE')"; exit 1 ;;
esac
if [ "$RHEL_INSTALL_SOURCE" != "netboot" ]; then
  [[ -f $RHEL_ISO ]] || {
    echo "ERROR: $RHEL_ISO not found"
    if [ "$RHEL_INSTALL_SOURCE" = "cdn" ]; then
      echo "  CDN mode needs the smaller boot ISO: rhel-9.5-x86_64-boot.iso (~1 GB)"
      echo "  Set RHEL_ISO=/var/lib/libvirt/images/rhel-9.5-x86_64-boot.iso"
    else
      echo "  DVD mode needs: rhel-9.5-x86_64-dvd.iso (~10 GB)"
      echo "  Tip: RHEL_INSTALL_SOURCE=netboot needs no ISO at all (uses the host's RHSM entitlement)."
    fi
    exit 1
  }
fi
$VIRSH net-info "$LAB_NET" >/dev/null 2>&1 || { echo "ERROR: run 00-network-setup.sh first"; exit 1; }
$VIRSH net-info "$HOST_NET" >/dev/null 2>&1 || { echo "ERROR: libvirt network '$HOST_NET' not found"; exit 1; }

# Resolve the install source line rendered into the kickstart.
#   dvd: no extra line — Anaconda installs from the DVD media.
#   cdn: register with RHSM during install and pull packages from the CDN.
INSTALL_SOURCE_LINE=""
case "$RHEL_INSTALL_SOURCE" in
  cdn)
    if [ -n "$RHSM_AK" ] && [ -n "$RHSM_ORG" ]; then
      INSTALL_SOURCE_LINE="rhsm --organization=\"$RHSM_ORG\" --activation-key=\"$RHSM_AK\""
    else
      INSTALL_SOURCE_LINE="rhsm --username=\"$RHSM_USER\" --password=\"$RHSM_PASS\""
    fi
    ;;
  netboot)
    # Install from the CDN kickstart tree; Anaconda authenticates with the
    # host's RHSM entitlement cert injected via --initrd-inject.
    INSTALL_SOURCE_LINE="url --url=${CDN_BASE}/ --sslcacert=/etc/pki/entitlement/ca.pem --sslclientcert=/etc/pki/entitlement/client.pem --sslclientkey=/etc/pki/entitlement/client-key.pem"
    ;;
esac

# Render kickstart with secrets (escape & for sed)
esc() { printf '%s' "${1//&/\\&}"; }
RENDERED_KS=$(mktemp /tmp/satellite-vm.XXXXXX.ks)
sed -e "s|__ROOTPW__|$(esc "$ROOTPW")|g" \
    -e "s|__RHSM_ORG__|$(esc "$RHSM_ORG")|g" \
    -e "s|__RHSM_AK__|$(esc "$RHSM_AK")|g" \
    -e "s|__RHSM_USER__|$(esc "$RHSM_USER")|g" \
    -e "s|__RHSM_PASS__|$(esc "$RHSM_PASS")|g" \
    -e "s|__INSTALL_SOURCE__|$(esc "$INSTALL_SOURCE_LINE")|g" \
    satellite-vm.ks > "$RENDERED_KS"
chmod 600 "$RENDERED_KS"

# Set up the host NFS export for /var/lib/pulp before the VM boots, so the
# kickstart %post can mount it. Skip with SATLAB_SKIP_NFS=1 (Pulp stays local).
if [ "${SATLAB_SKIP_NFS:-0}" != "1" ]; then
  echo "▸ Setting up host NFS storage for /var/lib/pulp..."
  bash "$(dirname "$0")/00b-host-nfs-storage.sh"
fi

[[ -f $VM_DISK ]] || qemu-img create -f qcow2 "$VM_DISK" "${VM_DISK_SIZE}G"

$VIRSH destroy "$VM_NAME" 2>/dev/null || true

if [ "$RHEL_INSTALL_SOURCE" = "netboot" ]; then
  # ISO-free install: fetch just the kernel + initrd from the CDN (a few MB)
  # using the host's RHSM entitlement cert, inject the cert + kickstart into
  # the initrd, and boot straight into a CDN install.
  echo "▸ Netboot: downloading the RHEL ${RHEL_VERSION} kernel + initrd from the CDN..."
  ENT_CERT=$(sudo ls /etc/pki/entitlement/*.pem 2>/dev/null | grep -v -- '-key' | head -1)
  ENT_KEY=$(sudo ls /etc/pki/entitlement/*-key.pem 2>/dev/null | head -1)
  [ -n "$ENT_CERT" ] && [ -n "$ENT_KEY" ] || {
    echo "ERROR: netboot needs the host registered with RHSM (entitlement cert in /etc/pki/entitlement)"
    exit 1
  }
  BOOT_DIR=$(mktemp -d /tmp/satellite-netboot.XXXXXX)
  sudo curl -sk --cert "$ENT_CERT" --key "$ENT_KEY" \
    -o "$BOOT_DIR/vmlinuz" "$CDN_BASE/images/pxeboot/vmlinuz"
  sudo curl -sk --cert "$ENT_CERT" --key "$ENT_KEY" \
    -o "$BOOT_DIR/initrd.img" "$CDN_BASE/images/pxeboot/initrd.img"
  sudo chmod 644 "$BOOT_DIR/vmlinuz" "$BOOT_DIR/initrd.img"
  [ -s "$BOOT_DIR/vmlinuz" ] && [ -s "$BOOT_DIR/initrd.img" ] || {
    echo "ERROR: failed to download the netboot kernel/initrd from the CDN"
    exit 1
  }

  # Stage the entitlement cert + CA so Anaconda can reach the CDN, and the
  # kickstart, all injected into the initrd.
  INJECT_DIR=$(mktemp -d /tmp/satellite-inject.XXXXXX)
  mkdir -p "$INJECT_DIR/etc/pki/entitlement"
  sudo cp "$ENT_CERT" "$INJECT_DIR/etc/pki/entitlement/client.pem"
  sudo cp "$ENT_KEY" "$INJECT_DIR/etc/pki/entitlement/client-key.pem"
  # The CDN CA chain (Red Hat's issuing CAs) for TLS verification.
  sudo cp /etc/rhsm/ca/redhat-uep.pem "$INJECT_DIR/etc/pki/entitlement/ca.pem" 2>/dev/null \
    || sudo cp /etc/pki/ca-trust/source/anchors/*.pem "$INJECT_DIR/etc/pki/entitlement/ca.pem" 2>/dev/null \
    || true
  sudo chmod 644 "$INJECT_DIR/etc/pki/entitlement/"*.pem 2>/dev/null || true
  cp "$RENDERED_KS" "$INJECT_DIR/satellite-vm.ks"

  # Build the initrd-inject args as an array (kickstart + each cert PEM).
  local_inject_args=(--initrd-inject "$INJECT_DIR/satellite-vm.ks")
  for f in "$INJECT_DIR"/etc/pki/entitlement/*.pem; do
    [ -e "$f" ] || continue
    local_inject_args+=(--initrd-inject "$f")
  done

  virt-install \
    --connect qemu:///system \
    --name "$VM_NAME" \
    --vcpus "$VM_VCPUS" --cpu host-passthrough \
    --memory "$VM_RAM" \
    --disk path="$VM_DISK",format=qcow2,bus=virtio,cache=writeback,discard=unmap \
    --network network="$HOST_NET",model=virtio,mac="$MAC_HOST" \
    --network network="$LAB_NET",model=virtio,mac="$MAC_LAB" \
    --kernel "$BOOT_DIR/vmlinuz" \
    --initrd "$BOOT_DIR/initrd.img" \
    "${local_inject_args[@]}" \
    --extra-args "inst.ks=file:/satellite-vm.ks console=ttyS0,115200n8" \
    --os-variant rhel9.0 \
    --graphics none --console pty,target_type=serial \
    --noautoconsole

  rm -rf "$BOOT_DIR" "$INJECT_DIR"
else
  virt-install \
    --connect qemu:///system \
    --name "$VM_NAME" \
    --vcpus "$VM_VCPUS" --cpu host-passthrough \
    --memory "$VM_RAM" \
    --disk path="$VM_DISK",format=qcow2,bus=virtio,cache=writeback,discard=unmap \
    --network network="$HOST_NET",model=virtio,mac="$MAC_HOST" \
    --network network="$LAB_NET",model=virtio,mac="$MAC_LAB" \
    --location "$RHEL_ISO",kernel=images/pxeboot/vmlinuz,initrd=images/pxeboot/initrd.img \
    --initrd-inject "$RENDERED_KS" \
    --extra-args "inst.ks=file:/$(basename "$RENDERED_KS") console=ttyS0,115200n8" \
    --os-variant rhel9.0 \
    --graphics none --console pty,target_type=serial \
    --noautoconsole
fi

rm -f "$RENDERED_KS"
cat <<EOF

VM '$VM_NAME' is installing unattended.
Watch progress:   $VIRSH console $VM_NAME
When done:        ssh root@192.168.122.20   (NIC1, default net) or 192.168.150.10 (NIC2, satlab)
Next step:        copy your manifest to the VM, then run 02-satellite-installer.sh on it.
EOF
