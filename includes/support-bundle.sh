#!/usr/bin/env bash
# Private, local-only support-bundle collection.

if [ -n "${_AAP_DEMO_SUPPORT_BUNDLE_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_SUPPORT_BUNDLE_LOADED=1

_aap_demo_support_bundle_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

_aap_demo_support_bundle_contains_secret() {
  # Generated inputs are already redacted. This is a defence-in-depth offline
  # check that rejects the most damaging accidental inclusions before the
  # temporary directory is promoted to a user-visible bundle.
  grep -EIR \
    --exclude='manifest.json' \
    -- '(^|[^[:alnum:]_])(Authorization:[[:space:]]*Bearer|-----BEGIN[[:space:]].*PRIVATE KEY|\$ANSIBLE_VAULT|password[[:space:]]*[:=][[:space:]]*[^*[:space:]]|token[[:space:]]*[:=][[:space:]]*[^*[:space:]])' \
    "$1" \
    | grep -Ev 'Generated for client configuration but not persisted|not configured|not available|unavailable|redacted' \
    | grep -q .
}

aap_demo_support_bundle_preview() {
  cat <<EOF
Support bundle preview (local only)

  Included:  redacted system information (Markdown and JSON), bundle metadata,
             SHA-256 manifest, and explicit unavailable-evidence notes.
  Excluded:  Vault files/password files, kubeconfig, pull secrets, private keys,
             raw logs, must-gather archives, and all external uploads.
  Safety:    output is owner-only; generated files are scanned offline before
             the bundle is retained. Existing directories are never replaced.

Create with: aap-demo support-bundle create --output /safe/local/path
EOF
}

aap_demo_support_bundle_create() {
  local output_dir="$1" parent stage file files_json generated_at
  [ -n "$output_dir" ] || {
    echo "ERROR: support-bundle create requires --output DIRECTORY" >&2
    return 2
  }
  if [ -e "$output_dir" ] || [ -L "$output_dir" ]; then
    echo "ERROR: Support bundle destination already exists: $output_dir" >&2
    return 1
  fi
  parent=$(dirname "$output_dir")
  if ! mkdir -p "$parent"; then
    echo "ERROR: Could not create support bundle parent directory: $parent" >&2
    return 1
  fi
  umask 077
  stage=$(mktemp -d "$parent/.aap-demo-support-bundle.XXXXXX") || return 1
  chmod 700 "$stage"
  trap 'rm -rf -- "${stage:-}"' RETURN

  if ! aap_demo_generate_system_info redact markdown "$stage/system-info.md" >/dev/null \
    || ! aap_demo_generate_system_info redact json "$stage/system-info.json" >/dev/null; then
    echo "ERROR: Could not collect redacted system information; no bundle was retained." >&2
    return 1
  fi
  generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat >"$stage/evidence-notes.md" <<EOF
# Evidence notes

This local bundle intentionally excludes Vault files, kubeconfig, pull secrets,
private keys, raw logs, and must-gather archives. Run must-gather separately
only when its scope and storage have been approved. This command never uploads
evidence or contacts a support vendor.
EOF
  chmod 600 "$stage"/*
  if _aap_demo_support_bundle_contains_secret "$stage"; then
    echo "ERROR: Offline secret scan rejected generated evidence; no bundle was retained." >&2
    return 1
  fi

  files_json='[]'
  for file in "$stage"/system-info.md "$stage"/system-info.json "$stage"/evidence-notes.md; do
    files_json=$(jq -c --arg name "$(basename "$file")" --arg sha256 "$(_aap_demo_support_bundle_hash "$file")" \
      '. + [{name: $name, sha256: $sha256}]' <<<"$files_json") || return 1
  done
  jq -n \
    --arg generated_at "$generated_at" \
    --arg tool_version "$(aap_demo_version_short 2>/dev/null || echo unknown)" \
    --argjson files "$files_json" \
    '{schema_version: 1, redacted: true, local_only: true, generated_at: $generated_at, tool_version: $tool_version, files: $files}' \
    >"$stage/manifest.json" || return 1
  chmod 600 "$stage/manifest.json"
  if ! mv "$stage" "$output_dir"; then
    echo "ERROR: Could not retain support bundle at: $output_dir" >&2
    return 1
  fi
  stage=""
  chmod 700 "$output_dir"
  echo "✓ Redacted support bundle created locally: $output_dir"
  echo "  Review its manifest and contents before sharing. Nothing was uploaded."
}

cmd_support_bundle() {
  local action="${1:-preview}"
  case "$action" in
    preview | help | --help | -h) aap_demo_support_bundle_preview ;;
    create) aap_demo_support_bundle_create "${SYSTEM_INFO_OUTPUT:-}" ;;
    *)
      echo "ERROR: Usage: aap-demo support-bundle [preview|create] [--output DIRECTORY]" >&2
      return 2
      ;;
  esac
}
