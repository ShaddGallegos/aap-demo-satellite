#!/usr/bin/env bash
# GitHub CLI authentication backed by the shared encrypted aap-demo Vault.

if [ -n "${_AAP_DEMO_GITHUB_AUTH_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_GITHUB_AUTH_LOADED=1

AAP_DEMO_GITHUB_TOKEN_KEY="aap_demo.github.token"

_aap_demo_github_login_with_file() {
  local token_file="$1"
  gh auth login --hostname github.com --git-protocol https --with-token <"$token_file"
}

aap_demo_github_login() {
  command -v gh >/dev/null 2>&1 || {
    _err "GitHub CLI (gh) is required; install it before configuring GitHub authentication"
    return 1
  }
  aap_demo_vault_with_file "$AAP_DEMO_GITHUB_TOKEN_KEY" _aap_demo_github_login_with_file || {
    _err "GitHub token is missing or could not authenticate; run: aap-demo credentials github configure"
    return 1
  }
}

aap_demo_github_configure() {
  local token
  if [ ! -r "$AAP_DEMO_SECRET_PROMPT_DEVICE" ]; then
    _err "GitHub token setup requires an interactive terminal"
    return 1
  fi
  printf 'GitHub personal access token (hidden): ' >"$AAP_DEMO_SECRET_PROMPT_OUTPUT"
  IFS= read -r -s token <"$AAP_DEMO_SECRET_PROMPT_DEVICE" || return 1
  printf '\n' >"$AAP_DEMO_SECRET_PROMPT_OUTPUT"
  [ -n "$token" ] || { _err "GitHub token cannot be empty"; return 1; }
  if ! [[ "$token" =~ ^(ghp_|github_pat_)[A-Za-z0-9_]+$ ]]; then
    unset token
    _err "GitHub token must be a classic or fine-grained personal access token"
    return 1
  fi
  aap_demo_vault_set "$AAP_DEMO_GITHUB_TOKEN_KEY" "$token" || {
    unset token
    return 1
  }
  unset token
  echo "✓ GitHub token saved in the encrypted credential Vault"
  aap_demo_github_login && echo "✓ GitHub CLI authenticated"
}

aap_demo_github_status() {
  if ! aap_demo_vault_get "$AAP_DEMO_GITHUB_TOKEN_KEY" >/dev/null 2>&1; then
    echo "GitHub token: not configured"
    return 1
  fi
  echo "GitHub token: configured in encrypted Vault"
  command -v gh >/dev/null 2>&1 && gh auth status -h github.com
}

cmd_github_credentials() {
  case "${1:-status}" in
    configure | login) aap_demo_github_configure ;;
    status) aap_demo_github_status ;;
    *)
      _err "Usage: aap-demo credentials github [configure|status]"
      return 2
      ;;
  esac
}
