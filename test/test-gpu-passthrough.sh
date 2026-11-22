#!/usr/bin/env bash
# Regression checks for the explicit CRC/MicroShift GPU passthrough workflow.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
PASSED=0 FAILED=0
pass() { echo "✓ $1"; ((PASSED++)); }
fail() { echo "✗ $1" >&2; ((FAILED++)); }

mkdir -p "$TEST_DIR/sys/bus/pci/devices" "$TEST_DIR/iommu/15/devices"
for bdf in 0000:01:00.0 0000:01:00.1; do
  mkdir -p "$TEST_DIR/devices/$bdf"
  printf '0x10de\n' >"$TEST_DIR/devices/$bdf/vendor"
  if [ "$bdf" = 0000:01:00.0 ]; then printf '0x030000\n' >"$TEST_DIR/devices/$bdf/class"; else printf '0x040300\n' >"$TEST_DIR/devices/$bdf/class"; fi
  ln -s "$TEST_DIR/devices/$bdf" "$TEST_DIR/sys/bus/pci/devices/$bdf"
  ln -s "$TEST_DIR/iommu/15" "$TEST_DIR/devices/$bdf/iommu_group"
  ln -s "$TEST_DIR/devices/$bdf" "$TEST_DIR/iommu/15/devices/$bdf"
done

export AAP_DEMO_GPU_SYSFS_ROOT="$TEST_DIR/sys"
export AAP_DEMO_GPU_IOMMU_ROOT="$TEST_DIR/iommu"
# shellcheck source=../includes/gpu-passthrough.sh
source "$ROOT/includes/gpu-passthrough.sh"

if [ "$(_aap_demo_gpu_nvidia_display_bdf)" = 0000:01:00.0 ]; then pass "discovers_nvidia_display_controller"; else fail "discovers_nvidia_display_controller"; fi
if group=$(_aap_demo_gpu_group_devices 0000:01:00.0) \
  && [ "$group" = $'0000:01:00.0\n0000:01:00.1' ]; then
  pass "selects_complete_isolated_iommu_group"
else
  fail "selects_complete_isolated_iommu_group"
fi
if address=$(_aap_demo_gpu_xml_address 0000:01:00.1) \
  && [ "$address" = "domain='0x0000' bus='0x01' slot='0x00' function='0x1'" ]; then
  pass "renders_valid_libvirt_pci_address"
else
  fail "renders_valid_libvirt_pci_address"
fi

mkdir -p "$TEST_DIR/devices/0000:01:00.2"
printf '0x8086\n' >"$TEST_DIR/devices/0000:01:00.2/vendor"
printf '0x088000\n' >"$TEST_DIR/devices/0000:01:00.2/class"
ln -s "$TEST_DIR/devices/0000:01:00.2" "$TEST_DIR/iommu/15/devices/0000:01:00.2"
if ! _aap_demo_gpu_group_devices 0000:01:00.0 >/dev/null 2>&1; then
  pass "refuses_mixed_iommu_group"
else
  fail "refuses_mixed_iommu_group"
fi

help_output=$(bash "$ROOT/aap-demo.sh" help)
if grep -q 'gpu \[status|enable|disable\]' <<<"$help_output"; then
  pass "cli_help_documents_reversible_gpu_command"
else
  fail "cli_help_documents_reversible_gpu_command"
fi
if grep -q 'nvidia-device-plugin-privileged-with-service-account.yml' "$ROOT/addons/ollama/gpu-guest-setup.sh" \
  && grep -q 'nvidia-ctk runtime configure --runtime=crio' "$ROOT/addons/ollama/gpu-guest-setup.sh"; then
  pass "guest_setup_configures_crio_and_device_plugin"
else
  fail "guest_setup_configures_crio_and_device_plugin"
fi
if grep -q 'systemctl stop nvidia-powerd.service' "$ROOT/includes/gpu-passthrough.sh" \
  && grep -q 'fuser -s /dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset' "$ROOT/includes/gpu-passthrough.sh" \
  && grep -q '_aap_demo_gpu_require_unused_host_device || return 1' "$ROOT/includes/gpu-passthrough.sh"; then
  pass "refuses_passthrough_while_host_gpu_is_in_use"
else
  fail "refuses_passthrough_while_host_gpu_is_in_use"
fi

echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
