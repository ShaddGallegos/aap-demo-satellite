#!/usr/bin/env bash
set -euo pipefail
umask 077
ip="$1" nfs_host="$2" export="$3" actions="${4:-false}"
[[ "$actions" == true || "$actions" == false ]] || {
  echo "ERROR: Invalid Gitea Actions setting" >&2
  exit 2
}

id git >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/gitea --shell /bin/bash git
install -d -o git -g git -m 750 /var/lib/gitea/{data,custom,log} /etc/gitea
install -d -o root -g root -m 700 /etc/gitea/ca
if ! findmnt -rn -C -M /srv/gitea -o SOURCE >/dev/null; then
  install -d -m 755 /srv/gitea
fi
python3 - "$nfs_host:$export" <<'PY'
import sys

source = sys.argv[1]
with open("/etc/fstab") as stream:
    lines = stream.readlines()
mounts = [line.split() for line in lines if line.strip() and not line.startswith("#")]
existing = [fields for fields in mounts if len(fields) >= 2 and fields[1] == "/srv/gitea"]
if existing and (len(existing) != 1 or existing[0][0] != source):
    raise SystemExit("ERROR: Unowned /srv/gitea mount; refusing to replace it")
if not existing:
    with open("/etc/fstab", "a") as stream:
        stream.write(f"\n{source} /srv/gitea nfs4 rw,hard,_netdev,nosuid,nodev 0 0\n")
PY
systemctl daemon-reload
if ! findmnt -rn -C -M /srv/gitea -o SOURCE >/dev/null; then
  mount /srv/gitea
fi
[ "$(findmnt -rn -C -M /srv/gitea -o SOURCE)" = "$nfs_host:$export" ] || {
  echo "ERROR: Unexpected backing storage mounted at /srv/gitea" >&2
  exit 1
}
runuser -u git -- mkdir -p /srv/gitea/{data,repositories,backups}

if [ ! -s /etc/gitea/ca/ca.crt ]; then
  openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
    -subj '/CN=aap-demo Gitea local CA' \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout /etc/gitea/ca/ca.key -out /etc/gitea/ca/ca.crt 2>/dev/null
fi
if [ ! -s /etc/gitea/https.crt ] ||
  ! openssl x509 -in /etc/gitea/https.crt -noout -checkip "$ip" >/dev/null ||
  ! openssl x509 -in /etc/gitea/https.crt -noout -checkend 604800 >/dev/null ||
  ! openssl x509 -in /etc/gitea/https.crt -noout -ext authorityKeyIdentifier |
    grep -q 'Authority Key Identifier'; then
  openssl req -new -newkey rsa:3072 -nodes -subj '/CN=gitea.demo.lab' \
    -keyout /etc/gitea/https.key -out /etc/gitea/https.csr 2>/dev/null
  printf 'subjectAltName=IP:%s,DNS:gitea.demo.lab\nbasicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\nauthorityKeyIdentifier=keyid,issuer\nsubjectKeyIdentifier=hash\n' \
    "$ip" >/etc/gitea/https.ext
  openssl x509 -req -days 365 -in /etc/gitea/https.csr \
    -CA /etc/gitea/ca/ca.crt -CAkey /etc/gitea/ca/ca.key -CAcreateserial \
    -extfile /etc/gitea/https.ext -out /etc/gitea/https.crt 2>/dev/null
  chown git:git /etc/gitea/https.{key,crt}
  chmod 600 /etc/gitea/https.key
  rm -f /etc/gitea/https.csr /etc/gitea/https.ext
fi
install -m 644 /etc/gitea/ca/ca.crt /etc/pki/ca-trust/source/anchors/aap-demo-gitea.crt
update-ca-trust

if [ ! -e /etc/gitea/app.ini ]; then
  cat >/etc/gitea/app.ini <<'INI'
APP_NAME = aap-demo Local Git
RUN_USER = git
RUN_MODE = prod
WORK_PATH = /var/lib/gitea
[database]
DB_TYPE = sqlite3
PATH = /var/lib/gitea/data/gitea.db
[repository]
ROOT = /srv/gitea/repositories
DEFAULT_PRIVATE = private
[server]
APP_DATA_PATH = /srv/gitea/data
PROTOCOL = https
HTTP_ADDR = 0.0.0.0
HTTP_PORT = 3000
CERT_FILE = /etc/gitea/https.crt
KEY_FILE = /etc/gitea/https.key
DISABLE_SSH = false
START_SSH_SERVER = false
SSH_PORT = 22
OFFLINE_MODE = true
LFS_START_SERVER = false
[security]
INSTALL_LOCK = true
[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = true
[actions]
ENABLED = false
[log]
MODE = console
LEVEL = warn
INI
fi
python3 - "$ip" "$actions" <<'PY'
import configparser
import re
import sys

path = "/etc/gitea/app.ini"
with open(path) as source:
    config = configparser.ConfigParser(interpolation=None)
    config.optionxform = str
    content = re.sub(r"(?m)^([A-Za-z0-9_]+)(\s*=)",
                     lambda match: match[1].upper() + match[2], source.read())
    config.read_string("[DEFAULT]\n" + content)
for name in ("DOMAIN", "SSH_DOMAIN"):
    config["server"][name] = sys.argv[1]
config["server"]["ROOT_URL"] = f"https://{sys.argv[1]}:3000/"
config["server"]["LOCAL_ROOT_URL"] = config["server"]["ROOT_URL"]
if "actions" not in config:
    config["actions"] = {}
config["actions"]["ENABLED"] = sys.argv[2] if len(sys.argv) > 2 else "false"
with open(path, "w") as target:
    # Gitea's top-level keys do not have an INI section.
    for key, value in config.defaults().items():
        target.write(f"{key} = {value}\n")
    config["DEFAULT"].clear()
    config.write(target)
PY
chown git:git /etc/gitea/app.ini
chmod 600 /etc/gitea/app.ini
cat >/etc/systemd/system/gitea.service <<'UNIT'
[Unit]
Description=aap-demo local Gitea
After=network-online.target
Wants=network-online.target
RequiresMountsFor=/srv/gitea
[Service]
User=git
Group=git
WorkingDirectory=/var/lib/gitea
Environment=USER=git HOME=/var/lib/gitea GITEA_WORK_DIR=/var/lib/gitea
ExecStart=/usr/local/bin/gitea web --config /etc/gitea/app.ini
ExecStopPost=/usr/local/bin/gitea-db-backup
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/gitea /etc/gitea /srv/gitea
UMask=0027
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
if command -v restorecon >/dev/null; then
  restorecon -RF /usr/local/bin/gitea /var/lib/gitea /etc/gitea
fi
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=3000/tcp >/dev/null
  firewall-cmd --add-port=3000/tcp >/dev/null
fi
runuser -u git -- /usr/local/bin/gitea --config /etc/gitea/app.ini migrate >/dev/null
systemctl enable gitea >/dev/null
cat >/usr/local/bin/gitea-db-backup <<'PY'
#!/usr/bin/python3
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile

with tempfile.TemporaryDirectory(dir="/var/lib/gitea") as directory:
    snapshot = Path(directory) / "gitea.db"
    with sqlite3.connect("file:/var/lib/gitea/data/gitea.db?mode=ro", uri=True) as source:
        with sqlite3.connect(snapshot) as target:
            source.backup(target)
    with tempfile.TemporaryDirectory(dir="/srv/gitea/backups") as staging:
        destination = Path(staging) / "gitea.db"
        shutil.copyfile(snapshot, destination)
        with destination.open("rb") as stream:
            os.fsync(stream.fileno())
        destination.replace(Path("/srv/gitea/backups/gitea.db"))
PY
chmod 755 /usr/local/bin/gitea-db-backup
cat >/etc/systemd/system/gitea-db-backup.service <<'UNIT'
[Unit]
Description=Consistent Gitea SQLite backup to retained NFS storage
RequiresMountsFor=/srv/gitea
After=gitea.service
[Service]
Type=oneshot
User=git
Group=git
UMask=0077
ExecStart=/usr/local/bin/gitea-db-backup
UNIT
cat >/etc/systemd/system/gitea-db-backup.timer <<'UNIT'
[Unit]
Description=Hourly Gitea database backup
[Timer]
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now gitea-db-backup.timer >/dev/null
