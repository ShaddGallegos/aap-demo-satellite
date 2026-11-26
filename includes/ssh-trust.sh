#!/usr/bin/env bash
# Managed SSH trust for local lab peers.
#
# Default mode deliberately preserves the existing local-lab TOFU behavior.
# Set AAP_DEMO_SSH_TRUST_MODE=verify and provide a fingerprint in
# AAP_DEMO_SSH_FINGERPRINTS to pin first use, for example:
#   AAP_DEMO_SSH_FINGERPRINTS='192.168.122.20:22=SHA256:...,127.0.0.1:2222=SHA256:...'
# Set AAP_DEMO_SSH_TRUST_MODE=strict to require pre-populated managed
# known-host entries without performing first-use enrollment.

if [ -n "${_AAP_DEMO_SSH_TRUST_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_SSH_TRUST_LOADED=1

_aap_demo_ssh_fingerprint_for() {
  local host="$1" port="$2" entry key="${host}:${port}="
  local fingerprints="${AAP_DEMO_SSH_FINGERPRINTS:-}"
  local -a entries
  IFS=',' read -r -a entries <<<"$fingerprints"
  for entry in "${entries[@]}"; do
    case "$entry" in
      "$key"*) printf '%s\n' "${entry#"$key"}"; return 0 ;;
    esac
  done
  return 1
}

_aap_demo_ssh_known_host_entries() {
  local known_hosts="$1" host="$2" port="$3"
  if [ "$port" = 22 ]; then
    ssh-keygen -F "$host" -f "$known_hosts" 2>/dev/null || true
  else
    ssh-keygen -F "[$host]:$port" -f "$known_hosts" 2>/dev/null || true
  fi
}

_aap_demo_ssh_entries_match_fingerprint() {
  local entries="$1" expected="$2"
  printf '%s\n' "$entries" | ssh-keygen -lf -E sha256 - 2>/dev/null \
    | awk -v expected="$expected" '$2 == expected { found=1 } END { exit !found }'
}

# Prepares AAP_DEMO_SSH_TRUST_OPTS for ssh/scp. The caller must use the array
# in the same shell immediately after this function returns.
aap_demo_ssh_prepare_trust() {
  local known_hosts="$1" host="$2" port="${3:-22}" mode expected entries scanned
  mode="${AAP_DEMO_SSH_TRUST_MODE:-tofu}"
  case "$mode" in tofu|verify|strict) ;; *)
    echo "ERROR: AAP_DEMO_SSH_TRUST_MODE must be tofu, verify, or strict" >&2
    return 2
    ;;
  esac

  mkdir -p "$(dirname "$known_hosts")" || return 1
  chmod 700 "$(dirname "$known_hosts")" || return 1
  touch "$known_hosts" || return 1
  chmod 600 "$known_hosts" || return 1
  entries=$(_aap_demo_ssh_known_host_entries "$known_hosts" "$host" "$port")

  case "$mode" in
    tofu)
      AAP_DEMO_SSH_TRUST_OPTS=(-o "UserKnownHostsFile=$known_hosts" -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new)
      ;;
    strict)
      [ -n "$entries" ] || {
        echo "ERROR: no managed SSH host key exists for ${host}:${port}; enroll it with verified mode first" >&2
        return 1
      }
      AAP_DEMO_SSH_TRUST_OPTS=(-o "UserKnownHostsFile=$known_hosts" -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes)
      ;;
    verify)
      expected=$(_aap_demo_ssh_fingerprint_for "$host" "$port") || {
        echo "ERROR: verified SSH trust needs ${host}:${port}=SHA256:<fingerprint> in AAP_DEMO_SSH_FINGERPRINTS" >&2
        return 1
      }
      case "$expected" in SHA256:*) ;; *)
        echo "ERROR: SSH fingerprint for ${host}:${port} must use SHA256: format" >&2
        return 2
        ;;
      esac
      if [ -n "$entries" ]; then
        _aap_demo_ssh_entries_match_fingerprint "$entries" "$expected" || {
          echo "ERROR: managed SSH host key for ${host}:${port} does not match its configured fingerprint" >&2
          return 1
        }
      else
        scanned=$(ssh-keyscan -T 10 -p "$port" "$host" 2>/dev/null) || {
          echo "ERROR: cannot retrieve SSH host key for ${host}:${port}" >&2
          return 1
        }
        _aap_demo_ssh_entries_match_fingerprint "$scanned" "$expected" || {
          echo "ERROR: SSH fingerprint mismatch for ${host}:${port}; refusing to trust this host" >&2
          return 1
        }
        printf '%s\n' "$scanned" >>"$known_hosts"
        chmod 600 "$known_hosts"
      fi
      AAP_DEMO_SSH_TRUST_OPTS=(-o "UserKnownHostsFile=$known_hosts" -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes)
      ;;
  esac
}
