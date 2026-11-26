#!/usr/bin/env bash
set -euo pipefail
identity="$1" address="$2" uid="$3" gid="$4"
[[ "$identity" =~ ^[a-f0-9-]{36}$ && "$address" =~ ^[0-9.]+$ &&
  "$uid" =~ ^[1-9][0-9]*$ && "$gid" =~ ^[1-9][0-9]*$ ]] || {
  echo "ERROR: Invalid Gitea export identity, address or unprivileged UID/GID" >&2
  exit 2
}
root="/var/lib/aap-demo-gitea/instances/$identity"
exports="/etc/exports.d/aap-demo-gitea-$identity.exports"
marker="# aap-demo:gitea:$identity"

if [ -e "$root" ]; then
  [ "$(cat "$root/.aap-demo-owner")" = "$identity" ] || {
    echo "ERROR: Existing NFS data is not owned by this Gitea installation" >&2
    exit 1
  }
else
  install -d -m 755 /var/lib/aap-demo-gitea /var/lib/aap-demo-gitea/instances
  install -d -o "$uid" -g "$gid" -m 750 "$root"
  printf '%s\n' "$identity" >"$root/.aap-demo-owner"
  chmod 600 "$root/.aap-demo-owner"
fi
[ "$(stat -c '%u:%g' "$root")" = "$uid:$gid" ] || {
  echo "ERROR: NFS storage UID/GID changed; refusing recursive ownership changes" >&2
  exit 1
}
if [ -e "$exports" ] && [ "$(head -n 1 "$exports")" != "$marker" ]; then
  echo "ERROR: Refusing to replace an unowned NFS export definition" >&2
  exit 1
fi
install -d -m 755 /etc/exports.d
temporary=$(mktemp /etc/exports.d/.aap-demo-gitea.XXXXXX)
trap 'rm -f -- "$temporary"' EXIT
printf '%s\n%s %s(rw,sync,root_squash,no_subtree_check)\n' \
  "$marker" "$root" "$address" >"$temporary"
chmod 644 "$temporary"
mv "$temporary" "$exports"
exportfs -ra
if systemctl is-active --quiet firewalld; then
  interface=$(ip -4 route get "$address" \
    | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
  zone=$(firewall-cmd --get-zone-of-interface="$interface")
  [ -n "$zone" ]
  rule="rule family=\"ipv4\" source address=\"$address/32\" port port=\"2049\" protocol=\"tcp\" accept"
  for mode in permanent runtime; do
    options=(--zone="$zone")
    [ "$mode" != permanent ] || options+=(--permanent)
    if ! firewall-cmd "${options[@]}" --query-rich-rule="$rule" >/dev/null; then
      firewall-cmd "${options[@]}" --add-rich-rule="$rule" >/dev/null
    fi
  done
fi
printf 'NFS export ready for Gitea only: %s\n' "$root"
