#!/usr/bin/env bash
# GPU passthrough support for the local libvirt-backed CRC/MicroShift VM.
#
# This deliberately is not part of normal addon deployment: passing a PCI
# device through briefly stops the local cluster and changes the host driver's
# binding.  `aap-demo gpu enable --apply` makes that consequential operation
# explicit, while the Ollama addon continues to select GPU automatically once
# Kubernetes advertises it.

if [ -n "${_AAP_DEMO_GPU_PASSTHROUGH_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_GPU_PASSTHROUGH_LOADED=1

_AAP_DEMO_GPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_DEMO_GPU_DOMAIN="${AAP_DEMO_GPU_DOMAIN:-crc}"
AAP_DEMO_NVIDIA_DEVICE_PLUGIN_VERSION="${AAP_DEMO_NVIDIA_DEVICE_PLUGIN_VERSION:-v0.17.4}"
# Test seams; normal users should leave these at the kernel-provided paths.
AAP_DEMO_GPU_SYSFS_ROOT="${AAP_DEMO_GPU_SYSFS_ROOT:-/sys}"
AAP_DEMO_GPU_IOMMU_ROOT="${AAP_DEMO_GPU_IOMMU_ROOT:-/sys/kernel/iommu_groups}"

_aap_demo_gpu_require_linux() {
  if [ "$(uname -s)" != Linux ]; then
    echo "ERROR: GPU passthrough is currently supported only on Linux/libvirt." >&2
    return 1
  fi
  command -v virsh >/dev/null 2>&1 || {
    echo "ERROR: virsh is required for GPU passthrough." >&2
    return 1
  }
}

_aap_demo_gpu_nvidia_display_bdf() {
  local device class vendor
  for device in "$AAP_DEMO_GPU_SYSFS_ROOT"/bus/pci/devices/*; do
    [ -r "$device/vendor" ] && [ -r "$device/class" ] || continue
    vendor=$(<"$device/vendor")
    class=$(<"$device/class")
    if [ "$vendor" = 0x10de ] && [[ "$class" = 0x03* ]]; then
      basename "$device"
      return 0
    fi
  done
  return 1
}

_aap_demo_gpu_group_devices() {
  local display_bdf="$1" device group target vendor
  device="$AAP_DEMO_GPU_SYSFS_ROOT/bus/pci/devices/${display_bdf}"
  [ -L "$device/iommu_group" ] || {
    echo "ERROR: ${display_bdf} has no IOMMU group. Enable IOMMU before using passthrough." >&2
    return 1
  }
  group=$(basename "$(readlink -f "$device/iommu_group")")
  for target in "$AAP_DEMO_GPU_IOMMU_ROOT/${group}/devices/"*; do
    [ -r "$target/vendor" ] || continue
    vendor=$(<"$target/vendor")
    if [ "$vendor" != 0x10de ]; then
      echo "ERROR: IOMMU group ${group} also contains non-NVIDIA device $(basename "$target"); refusing unsafe passthrough." >&2
      return 1
    fi
    basename "$target"
  done
}

_aap_demo_gpu_xml_address() {
  local bdf="$1" domain bus slot function
  if [[ ! "$bdf" =~ ^([[:xdigit:]]{4}):([[:xdigit:]]{2}):([[:xdigit:]]{2})\.([[:xdigit:]])$ ]]; then
    echo "ERROR: Invalid PCI address: $bdf" >&2
    return 1
  fi
  domain="${BASH_REMATCH[1]}"
  bus="${BASH_REMATCH[2]}"
  slot="${BASH_REMATCH[3]}"
  function="${BASH_REMATCH[4]}"
  printf "domain='0x%s' bus='0x%s' slot='0x%s' function='0x%s'" "$domain" "$bus" "$slot" "$function"
}

_aap_demo_gpu_domain_has_bdf() {
  local bdf="$1" address xml hostdev_sources
  address=$(_aap_demo_gpu_xml_address "$bdf") || return 1
  xml=$(sudo virsh dumpxml "$AAP_DEMO_GPU_DOMAIN" 2>/dev/null) || return 1
  # Do not search the entire XML: libvirt's *guest* PCI target can happen to
  # have the same numeric BDF as a host controller. Only hostdev source blocks
  # tell us that a physical device is assigned.
  hostdev_sources=$(awk '
    /<hostdev / { in_hostdev=1 }
    in_hostdev && /<source>/ { in_source=1 }
    in_source && /<address / { print }
    in_hostdev && /<\/hostdev>/ { in_hostdev=0; in_source=0 }
  ' <<<"$xml")
  grep -Fq "$address" <<<"$hostdev_sources"
}

_aap_demo_gpu_guest_has_nvidia() {
  # shellcheck source=infra-crc.sh
  source "${_AAP_DEMO_GPU_DIR}/infra-crc.sh"
  _crc_exec 'test -d /sys/bus/pci/devices && grep -ql "0x10de" /sys/bus/pci/devices/*/vendor' >/dev/null 2>&1
}

_aap_demo_gpu_require_unused_host_device() {
  # `managed=yes` can only hand a device to vfio when no host process owns an
  # NVIDIA device node. In particular, do not tear down a Wayland/X session or
  # a GPU-offloaded application behind the user's back.
  local device_users
  # This service holds /dev/nvidia* even when no desktop/client is using the
  # device. It is safe to stop for an explicit passthrough request; disable
  # starts it again when the GPU returns to the host.
  if systemctl is-active --quiet nvidia-powerd.service 2>/dev/null; then
    echo "  Stopping nvidia-powerd before PCI handoff..."
    sudo systemctl stop nvidia-powerd.service || {
      echo "ERROR: Unable to stop nvidia-powerd for GPU passthrough." >&2
      return 1
    }
  fi
  command -v fuser >/dev/null 2>&1 || return 0
  if fuser -s /dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset 2>/dev/null; then
    echo "ERROR: The NVIDIA GPU is currently in use by the host desktop or an application." >&2
    echo "  Close GPU-using applications and log out of the desktop session that owns it, then retry." >&2
    echo "  Active owners:" >&2
    device_users=$(fuser -v /dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset 2>&1 || true)
    printf '%s\n' "$device_users" >&2
    return 1
  fi
}

_aap_demo_gpu_wait_for_ssh() {
  local attempt
  # shellcheck source=infra-crc.sh
  source "${_AAP_DEMO_GPU_DIR}/infra-crc.sh"
  for attempt in $(seq 1 90); do
    _crc_exec true >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "ERROR: CRC SSH did not return within three minutes." >&2
  return 1
}

_aap_demo_gpu_write_hostdev_xml() {
  local bdf="$1" file="$2" address
  address=$(_aap_demo_gpu_xml_address "$bdf") || return 1
  cat >"$file" <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address ${address}/>
  </source>
</hostdev>
EOF
}

_aap_demo_gpu_attach() {
  local display_bdf bdf xml_file state attached_now=false
  display_bdf=$(_aap_demo_gpu_nvidia_display_bdf) || {
    echo "ERROR: No NVIDIA display controller was found on this host." >&2
    return 1
  }
  mapfile -t _aap_demo_gpu_bdfs < <(_aap_demo_gpu_group_devices "$display_bdf")
  [ "${#_aap_demo_gpu_bdfs[@]}" -gt 0 ] || return 1
  echo "  NVIDIA IOMMU group: ${_aap_demo_gpu_bdfs[*]}"
  _aap_demo_gpu_require_unused_host_device || return 1

  state=$(sudo virsh domstate "$AAP_DEMO_GPU_DOMAIN" 2>/dev/null) || {
    echo "ERROR: Local CRC libvirt domain '${AAP_DEMO_GPU_DOMAIN}' was not found." >&2
    return 1
  }
  state=$(tr -d '[:space:]' <<<"$state")
  if [ "$state" != shutoff ]; then
    echo "  Stopping the local CRC/MicroShift VM to update its persistent PCI configuration..."
    crc stop || return 1
    for _aap_demo_gpu_stop_attempt in $(seq 1 60); do
      state=$(sudo virsh domstate "$AAP_DEMO_GPU_DOMAIN" 2>/dev/null || true)
      state=$(tr -d '[:space:]' <<<"$state")
      [ "$state" = shutoff ] && break
      sleep 2
    done
    [ "$state" = shutoff ] || {
      echo "ERROR: CRC VM did not stop; no PCI devices were changed." >&2
      return 1
    }
  fi

  for bdf in "${_aap_demo_gpu_bdfs[@]}"; do
    if _aap_demo_gpu_domain_has_bdf "$bdf"; then
      echo "  ✓ ${bdf} is already assigned to ${AAP_DEMO_GPU_DOMAIN}"
      continue
    fi
    xml_file=$(mktemp "${TMPDIR:-/tmp}/aap-demo-gpu-hostdev.XXXXXX.xml") || return 1
    _aap_demo_gpu_write_hostdev_xml "$bdf" "$xml_file" || {
      rm -f "$xml_file"
      return 1
    }
    if sudo virsh attach-device "$AAP_DEMO_GPU_DOMAIN" "$xml_file" --config; then
      echo "  ✓ Assigned ${bdf} to ${AAP_DEMO_GPU_DOMAIN}"
      attached_now=true
    else
      rm -f "$xml_file"
      echo "ERROR: libvirt could not assign ${bdf}. It may still be in use by a host process." >&2
      return 1
    fi
    rm -f "$xml_file"
  done

  echo "  Starting CRC/MicroShift with the NVIDIA PCI devices..."
  crc start || return 1
  _aap_demo_gpu_wait_for_ssh || return 1
  if ! _aap_demo_gpu_guest_has_nvidia; then
    echo "ERROR: CRC started, but the NVIDIA device is not visible in its guest." >&2
    echo "  Run 'aap-demo gpu status' and 'aap-demo gpu disable --apply' to recover." >&2
    return 1
  fi
  [ "$attached_now" = true ] && echo "✓ NVIDIA PCI passthrough is active in the CRC guest"
}

_aap_demo_gpu_configure_guest() {
  local setup_script="${_AAP_DEMO_GPU_DIR}/../addons/ollama/gpu-guest-setup.sh" rc
  [ -r "$setup_script" ] || {
    echo "ERROR: NVIDIA guest setup script is missing." >&2
    return 1
  }
  # shellcheck source=infra-crc.sh
  source "${_AAP_DEMO_GPU_DIR}/infra-crc.sh"
  echo "  Installing/reconciling the NVIDIA guest driver, CRI-O toolkit, and device plugin..."
  _crc_exec sudo env "AAP_DEMO_NVIDIA_DEVICE_PLUGIN_VERSION=$AAP_DEMO_NVIDIA_DEVICE_PLUGIN_VERSION" bash -s <"$setup_script" || rc=$?
  case "${rc:-0}" in
    0) ;;
    20)
      echo "  Rebooting the CRC guest to activate the NVIDIA kernel driver..."
      _crc_exec sudo systemctl reboot || true
      _aap_demo_gpu_wait_for_ssh || return 1
      _crc_exec sudo env "AAP_DEMO_NVIDIA_DEVICE_PLUGIN_VERSION=$AAP_DEMO_NVIDIA_DEVICE_PLUGIN_VERSION" bash -s <"$setup_script" || return 1
      ;;
    *) return "$rc" ;;
  esac
}

_aap_demo_gpu_wait_for_resource() {
  local attempt count
  for attempt in $(seq 1 90); do
    count=$(kubectl get nodes -o json 2>/dev/null | jq -r '[.items[].status.allocatable["nvidia.com/gpu"] // "0" | tonumber] | add // 0' 2>/dev/null || echo 0)
    [ "$count" -gt 0 ] 2>/dev/null && {
      echo "✓ Kubernetes now advertises ${count} NVIDIA GPU(s)"
      return 0
    }
    sleep 2
  done
  echo "ERROR: NVIDIA device plugin did not advertise nvidia.com/gpu within three minutes." >&2
  return 1
}

_aap_demo_gpu_disable() {
  local display_bdf bdf xml_file state
  display_bdf=$(_aap_demo_gpu_nvidia_display_bdf) || {
    echo "ERROR: No NVIDIA display controller was found on this host." >&2
    return 1
  }
  mapfile -t _aap_demo_gpu_bdfs < <(_aap_demo_gpu_group_devices "$display_bdf")
  state=$(sudo virsh domstate "$AAP_DEMO_GPU_DOMAIN" 2>/dev/null) || return 1
  state=$(tr -d '[:space:]' <<<"$state")
  if [ "$state" != shutoff ]; then
    echo "  Stopping the local CRC/MicroShift VM before detaching NVIDIA PCI devices..."
    crc stop || return 1
  fi
  for bdf in "${_aap_demo_gpu_bdfs[@]}"; do
    _aap_demo_gpu_domain_has_bdf "$bdf" || continue
    xml_file=$(mktemp "${TMPDIR:-/tmp}/aap-demo-gpu-hostdev.XXXXXX.xml") || return 1
    _aap_demo_gpu_write_hostdev_xml "$bdf" "$xml_file" || {
      rm -f "$xml_file"
      return 1
    }
    sudo virsh detach-device "$AAP_DEMO_GPU_DOMAIN" "$xml_file" --config || {
      rm -f "$xml_file"
      return 1
    }
    rm -f "$xml_file"
    echo "  ✓ Returned ${bdf} to the host"
  done
  crc start || return 1
  if systemctl list-unit-files nvidia-powerd.service >/dev/null 2>&1; then
    sudo systemctl start nvidia-powerd.service 2>/dev/null || true
  fi
  echo "✓ NVIDIA PCI passthrough disabled; the CRC VM is running without the GPU"
}

aap_demo_gpu_status() {
  local display_bdf bdf state resource="unknown"
  _aap_demo_gpu_require_linux || return 1
  display_bdf=$(_aap_demo_gpu_nvidia_display_bdf) || {
    echo "No NVIDIA display controller detected on the host."
    return 0
  }
  mapfile -t _aap_demo_gpu_bdfs < <(_aap_demo_gpu_group_devices "$display_bdf")
  echo "NVIDIA GPU passthrough status"
  echo "  Host PCI devices: ${_aap_demo_gpu_bdfs[*]}"
  state=$(sudo virsh domstate "$AAP_DEMO_GPU_DOMAIN" 2>/dev/null || echo "not-found")
  state=$(tr -d '[:space:]' <<<"$state")
  echo "  CRC domain:       ${AAP_DEMO_GPU_DOMAIN} (${state})"
  for bdf in "${_aap_demo_gpu_bdfs[@]}"; do
    if _aap_demo_gpu_domain_has_bdf "$bdf"; then echo "  ${bdf}: assigned to CRC"; else echo "  ${bdf}: host-managed"; fi
  done
  if command -v kubectl >/dev/null 2>&1; then
    resource=$(kubectl get nodes -o json 2>/dev/null | jq -r '[.items[].status.allocatable["nvidia.com/gpu"] // "0" | tonumber] | add // 0' 2>/dev/null || echo "unavailable")
  fi
  echo "  Kubernetes GPUs:  ${resource}"
}

cmd_gpu() {
  local action="${1:-status}" apply="${2:-false}"
  case "$action" in
    status) aap_demo_gpu_status ;;
    enable)
      if [ "$apply" != true ]; then
        echo "Preview only. Run 'aap-demo gpu enable --apply' to assign the NVIDIA GPU to CRC, restart it, and install the Kubernetes device plugin."
        aap_demo_gpu_status
        return 0
      fi
      _aap_demo_gpu_require_linux || return 1
      _aap_demo_gpu_attach || return 1
      _aap_demo_gpu_configure_guest || return 1
      _aap_demo_gpu_wait_for_resource || return 1
      echo "Reconcile Ollama with GPU scheduling: OLLAMA_GPU=auto aap-demo enable ollama"
      ;;
    disable)
      [ "$apply" = true ] || {
        echo "Preview only. Run 'aap-demo gpu disable --apply' to detach the NVIDIA GPU from CRC."
        aap_demo_gpu_status
        return 0
      }
      _aap_demo_gpu_require_linux || return 1
      _aap_demo_gpu_disable
      ;;
    *)
      echo "Usage: aap-demo gpu [status|enable|disable] [--apply]" >&2
      return 2
      ;;
  esac
}
