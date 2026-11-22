#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for script in \
  "$ROOT/satellite-lab/01-provision-satellite-vm.sh" \
  "$ROOT/satellite-lab/02-satellite-installer.sh" \
  "$ROOT/satellite-lab/04-provisioning-kickstart.sh"; do
  bash -n "$script"
done

if rg -n 'RedHat123|ROOTPW=.*:-[^}]|ADMIN_PASS=.*:-[^}]' \
  "$ROOT/satellite-lab" --glob '*.sh'; then
  echo 'FAIL: Satellite scripts retain a committed password fallback' >&2
  exit 1
fi

for helper in \
  aap_demo_satellite_admin_password \
  aap_demo_satellite_root_password \
  aap_demo_satellite_provisioning_root_password; do
  grep -Fq "$helper()" "$ROOT/includes/credential-vault.sh"
done

grep -Fq 'ROOTPW="$root_pass"' "$ROOT/satellite-lab/build-and-configure.sh"
grep -Fq 'aap_demo_satellite_provisioning_root_password' "$ROOT/satellite-lab/build-and-configure.sh"
grep -Fq 'ANSWERS_FILE=/etc/foreman-installer/scenarios.d/satellite-answers.yaml' \
  "$ROOT/satellite-lab/02-satellite-installer.sh"
installer_invocation=$(sed -n '/^satellite-installer --scenario satellite \\/,/^# NOTE:/p' \
  "$ROOT/satellite-lab/02-satellite-installer.sh")
if grep -Fq -- '--foreman-initial-admin-password' <<<"$installer_invocation"; then
  echo 'FAIL: Satellite administrator password is exposed in installer arguments' >&2
  exit 1
fi

echo 'PASS: Satellite passwords are generated and retained only in the encrypted Vault'
