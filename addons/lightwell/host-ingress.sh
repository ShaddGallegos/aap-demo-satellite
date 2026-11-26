#!/usr/bin/env bash
set -euo pipefail
address="$1" gateway="$2"
python3 - "$address" "$gateway" <<'PY'
import ipaddress
import sys
for value in sys.argv[1:]:
    address = ipaddress.IPv4Address(value)
    if not address.is_private or address.is_loopback or address.is_unspecified:
        raise SystemExit("ERROR: Private, non-loopback ingress endpoints are required")
PY
if systemctl is-active --quiet firewalld; then
  interface=$(ip -4 route get "$address" \
    | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
  zone=$(firewall-cmd --get-zone-of-interface="$interface")
  [ -n "$zone" ]
  rule="rule family=\"ipv4\" source address=\"$address/32\" destination address=\"$gateway/32\" port port=\"443\" protocol=\"tcp\" accept"
  for mode in permanent runtime; do
    options=(--zone="$zone")
    [ "$mode" != permanent ] || options+=(--permanent)
    if ! firewall-cmd "${options[@]}" --query-rich-rule="$rule" >/dev/null; then
      firewall-cmd "${options[@]}" --add-rich-rule="$rule" >/dev/null
    fi
  done
  echo 'Configured VM-scoped HTTPS ingress access; unrelated firewall rules preserved'
else
  echo 'Host firewalld is inactive; no firewall configuration changed'
fi
