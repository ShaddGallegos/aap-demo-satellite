#!/usr/bin/env bash
set -euo pipefail
umask 077
if ! command -v podman >/dev/null || ! command -v git >/dev/null; then
  dnf install -y podman git-core
fi
install -d -m 700 /var/lib/aap-demo-lightwell
install -d -m 755 /etc/containers/systemd
python3 - <<'PY'
import configparser
import json
import os
from pathlib import Path
import subprocess

values = json.loads(os.environ["LIGHTWELL_CONFIG"])
root = Path("/var/lib/aap-demo-lightwell")
marker = "Managed by aap-demo lightwell"
owner = root / "owner"
if owner.exists() and owner.read_text().strip() != marker:
    raise SystemExit("ERROR: Unowned Lightwell service data")
owner.write_text(marker + "\n")
for name in ("postgres", "attachments", "tls"):
    (root / name).mkdir(mode=0o700, exist_ok=True)
attachments = root / "attachments"
if attachments.stat().st_uid not in (0, 1001):
    raise SystemExit("ERROR: Unexpected OpenFlake attachment directory ownership")
os.chown(attachments, 1001, 1001)
attachments.chmod(0o750)
(root / "postgres.env").write_text(
    "POSTGRES_USER=openflake\nPOSTGRES_DB=openflake\nPOSTGRES_PASSWORD=" +
    values["postgres_password"] + "\n"
)
(root / "backend.env").write_text(
    "DATABASE_URL=postgresql+asyncpg://openflake:" + values["postgres_password"] +
    "@postgres:5432/openflake\nSECRET_KEY=" + values["secret_key"] +
    "\nADMIN_USERNAME=admin\nADMIN_PASSWORD=" + values["admin_password"] +
    "\nBASE_URL=" + values["openflake"] + "\nCORS_ORIGINS=" + values["openflake"] +
    "\nTRUSTED_PROXIES=10.89.0.0/16\nATTACHMENTS_PATH=/data/attachments\n"
)
units = {
    "aap-demo-lightwell.network": "[Network]\nNetworkName=aap-demo-lightwell\n",
    "aap-demo-lightwell-db.container":
        f"[Container]\nImage={values['postgres']}\nContainerName=aap-demo-lightwell-db\n"
        "Network=aap-demo-lightwell.network\nNetworkAlias=postgres\n"
        f"EnvironmentFile={root}/postgres.env\nVolume={root}/postgres:/var/lib/postgresql/data:Z\n",
    "aap-demo-lightwell-backend.container":
        "[Unit]\nRequires=aap-demo-lightwell-db.service\nAfter=aap-demo-lightwell-db.service\n"
        f"[Container]\nImage={values['backend']}\nContainerName=aap-demo-lightwell-backend\n"
        "Network=aap-demo-lightwell.network\nNetworkAlias=backend\n"
        f"EnvironmentFile={root}/backend.env\nVolume={root}/attachments:/data/attachments:Z\n",
    "aap-demo-lightwell-web.container":
        "[Unit]\nRequires=aap-demo-lightwell-backend.service\nAfter=aap-demo-lightwell-backend.service\n"
        f"[Container]\nImage={values['frontend']}\nContainerName=aap-demo-lightwell-web\n"
        "Network=aap-demo-lightwell.network\nPublishPort=8443:443\n"
        "Entrypoint=/usr/sbin/nginx\nExec=-g \"daemon off;\"\n"
        f"Volume={root}/nginx.conf:/etc/nginx/conf.d/default.conf:ro,Z\n"
        f"Volume={root}/tls:/etc/nginx/certs:ro,Z\n",
}
for filename, content in units.items():
    path = Path("/etc/containers/systemd") / filename
    if path.exists() and not path.read_text().startswith("# " + marker):
        raise SystemExit(f"ERROR: Refusing to replace unowned unit {filename}")
    if filename.endswith(".container"):
        name = filename.removesuffix(".container")
        exists = subprocess.run(["podman", "container", "exists", name]).returncode == 0
        if exists:
            label = subprocess.check_output(
                ["podman", "inspect", "--format", '{{index .Config.Labels "io.aap-demo.owner"}}', name],
                text=True).strip()
            if label != "lightwell":
                raise SystemExit(f"ERROR: Refusing to replace unowned container {name}")
        content += "Label=io.aap-demo.owner=lightwell\n[Service]\nRestart=on-failure\nRestartSec=5\nTimeoutStartSec=900\n"
        content += "[Install]\nWantedBy=multi-user.target\n"
    path.write_text("# " + marker + "\n" + content)
(root / "nginx.conf").write_text("""
server {
    listen 443 ssl;
    server_name _;
    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /usr/share/nginx/html;
    location / { try_files $uri $uri/ /index.html; }
    location /api/ { proxy_pass http://backend:8000; proxy_set_header X-Forwarded-Proto https; }
    location /oauth_token.do { proxy_pass http://backend:8000; }
    location /health/ { proxy_pass http://backend:8000; }
}
""")
path = Path("/etc/gitea/app.ini")
config = configparser.ConfigParser(interpolation=None)
config.optionxform = str
config.read_string("[DEFAULT]\n" + path.read_text())
config["actions"]["ENABLED"] = "true"
with path.open("w") as stream:
    for key, value in config.defaults().items():
        stream.write(f"{key} = {value}\n")
    config["DEFAULT"].clear()
    config.write(stream)
PY
unset LIGHTWELL_CONFIG
install -m 644 /etc/gitea/https.crt /var/lib/aap-demo-lightwell/tls/fullchain.pem
install -m 600 /etc/gitea/https.key /var/lib/aap-demo-lightwell/tls/privkey.pem
install -m 755 /home/admin/gitea-runner.bin /usr/local/bin/gitea-runner
rm -f /home/admin/gitea-runner.bin
if command -v restorecon >/dev/null; then restorecon /usr/local/bin/gitea-runner; fi
systemctl daemon-reload
systemctl start aap-demo-lightwell-web.service
systemctl restart gitea
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=8443/tcp >/dev/null
  firewall-cmd --add-port=8443/tcp >/dev/null
fi
