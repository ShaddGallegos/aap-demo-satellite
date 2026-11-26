#!/usr/bin/env bash
# Machine-readable addon scenario contracts.  A contract describes the
# boundary an addon owns; it never contains secret values.

if [ -n "${_AAP_DEMO_ADDON_CONTRACT_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_ADDON_CONTRACT_LOADED=1

aap_demo_validate_addon_contract() {
  local addon_dir="$1" contract validator
  contract="${addon_dir}/scenario.json"
  [ -f "$contract" ] || return 0

  validator="${SCRIPT_DIR}/scripts/validate-addon-contract.py"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required to validate addon scenario contracts" >&2
    return 1
  fi
  [ -f "$validator" ] || {
    echo "ERROR: Addon scenario contract validator is missing: ${validator}" >&2
    return 1
  }
  python3 "$validator" --quiet "$contract"
}
