#!/usr/bin/env bash
set -euo pipefail
umask 077
settings=/etc/aap-demo-lightwell-runner
if [ -e "$settings" ]; then
  [ ! -L "$settings" ] && [ "$(cat "$settings/owner")" = 'Managed by aap-demo lightwell' ] || {
    echo 'ERROR: Refusing to replace unowned CI runner settings' >&2
    exit 1
  }
elif id aap-demo-ci >/dev/null 2>&1 || [ -e /var/lib/aap-demo-lightwell-runner ]; then
  echo 'ERROR: Refusing to adopt an existing CI user or directory' >&2
  exit 1
else
  install -d -m 750 "$settings"
  printf '%s\n' 'Managed by aap-demo lightwell' >"$settings/owner"
fi
unit=/etc/systemd/system/aap-demo-lightwell-runner.service
if [ -e "$unit" ] && ! grep -Fxq '# Managed by aap-demo lightwell' "$unit"; then
  echo 'ERROR: Refusing to replace an unowned CI runner service' >&2
  exit 1
fi
id aap-demo-ci >/dev/null 2>&1 ||
  useradd --system --create-home --home-dir /var/lib/aap-demo-lightwell-runner \
    --shell /usr/sbin/nologin aap-demo-ci
install -d -m 700 -o aap-demo-ci -g aap-demo-ci /var/lib/aap-demo-lightwell-runner
chgrp aap-demo-ci "$settings"
python3 - <<'PY'
import json
import os
from pathlib import Path
import pwd

values = json.loads(os.environ["LIGHTWELL_CONFIG"])
root = Path("/var/lib/aap-demo-lightwell-runner")
settings = Path("/etc/aap-demo-lightwell-runner")
account = pwd.getpwnam("aap-demo-ci")
if account.pw_dir != str(root) or account.pw_shell != "/usr/sbin/nologin":
    raise SystemExit("ERROR: Unexpected CI user configuration")
identity = root / ".runner"
if identity.is_symlink() or (
    identity.exists() and json.loads(identity.read_text()).get("address") != values["origin"]
):
    raise SystemExit("ERROR: Existing runner belongs to another Git instance")
config = {"log": {"level": "info"}, "runner": {
    "file": str(root / ".runner"), "capacity": 1, "insecure": False,
    "timeout": "30m", "shutdown_timeout": "1m",
    "labels": ["aap-demo-lightwell:host"],
}, "cache": {"enabled": False}, "host": {"workdir_parent": str(root / "workspaces")}}
path = settings / "config.json"
path.write_text(json.dumps(config))
(settings / "origin").write_text(values["origin"])
os.chown(path, 0, account.pw_gid)
path.chmod(0o640)
if not identity.exists():
    registration = settings / "registration"
    registration.write_text(values["token"])
    os.chown(registration, 0, account.pw_gid)
    registration.chmod(0o640)
Path("/etc/pki/ca-trust/source/anchors/aap-demo-lightwell-crc.crt").write_text(values["crc_ca"])
hosts = Path("/etc/hosts")
start, end = "# BEGIN aap-demo lightwell", "# END aap-demo lightwell"
text = hosts.read_text()
if (start in text) != (end in text):
    raise SystemExit("ERROR: Incomplete managed hosts block")
if start in text:
    before, remainder = text.split(start, 1)
    _, after = remainder.split(end, 1)
    text = before + after
hosts.write_text(text.rstrip() + "\n" + start + "\n" +
                 values["crc_ip"] + " " + values["ao_route"] + "\n" + end + "\n")
PY
unset LIGHTWELL_CONFIG
update-ca-trust
trap 'rm -f /etc/aap-demo-lightwell-runner/registration' EXIT
if [ ! -s /var/lib/aap-demo-lightwell-runner/.runner ]; then
  cd /var/lib/aap-demo-lightwell-runner
  origin=$(cat /etc/aap-demo-lightwell-runner/origin)
  runuser -u aap-demo-ci -- /usr/local/bin/gitea-runner \
    --config /etc/aap-demo-lightwell-runner/config.json register --no-interactive \
    --instance "$origin" --token-file /etc/aap-demo-lightwell-runner/registration \
    --name aap-demo-lightwell --labels aap-demo-lightwell:host
fi
cat >/etc/systemd/system/aap-demo-lightwell-runner.service <<'UNIT'
# Managed by aap-demo lightwell
[Unit]
Description=Repository-scoped local Lightwell simulation runner
After=network-online.target gitea.service
Wants=network-online.target
[Service]
User=aap-demo-ci
Group=aap-demo-ci
WorkingDirectory=/var/lib/aap-demo-lightwell-runner
ExecStart=/usr/local/bin/gitea-runner --config /etc/aap-demo-lightwell-runner/config.json daemon
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/aap-demo-lightwell-runner
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now aap-demo-lightwell-runner
systemctl is-active --quiet aap-demo-lightwell-runner
