#!/usr/bin/env bash
# Runs as root inside the CRC/MicroShift guest.  Exit 20 asks the caller to
# reboot the guest after a new NVIDIA kernel module is installed.
set -euo pipefail

plugin_version="${AAP_DEMO_NVIDIA_DEVICE_PLUGIN_VERSION:-v0.17.4}"
case "$plugin_version" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "ERROR: Invalid NVIDIA device plugin version." >&2; exit 2;; esac

if ! grep -ql '0x10de' /sys/bus/pci/devices/*/vendor 2>/dev/null; then
  echo "ERROR: No NVIDIA PCI device is visible in the CRC guest." >&2
  exit 1
fi

if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi -L >/dev/null 2>&1; then
  echo "  Installing NVIDIA driver from NVIDIA's RHEL 9 repository..."
  dnf -y install dnf-plugins-core
  dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
  dnf -y install "kernel-devel-$(uname -r)" || dnf -y install kernel-devel
  dnf -y module install nvidia-driver:latest-dkms
  echo "  NVIDIA driver installed; a guest reboot is required."
  exit 20
fi

echo "  NVIDIA driver is active: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
dnf -y install dnf-plugins-core
dnf config-manager --add-repo https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
dnf -y install nvidia-container-toolkit
setsebool -P container_use_devices on
nvidia-ctk runtime configure --runtime=crio --set-as-default --drop-in-config=/etc/crio/crio.conf.d/99-nvidia.conf
mkdir -p /etc/microshift/manifests.d/nvidia-device-plugin
curl --fail --location --proto '=https' --tlsv1.2 --retry 5 \
  "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${plugin_version}/deployments/static/nvidia-device-plugin-privileged-with-service-account.yml" \
  -o /etc/microshift/manifests.d/nvidia-device-plugin/nvidia-device-plugin.yml
systemctl restart crio
systemctl restart microshift
echo "  NVIDIA container runtime and MicroShift device plugin are configured."
