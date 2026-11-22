#!/usr/bin/env python3
"""Own one independent libvirt Gitea VM; never delete repository data."""

import argparse
import base64
import fcntl
import hashlib
import ipaddress
import json
import os
import platform
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DOMAIN = "aap-demo-gitea"
DISKS = Path("/var/lib/libvirt/images/aap-demo-gitea")
VERSION = "28.4.0"
BINARY = f"gitea-{VERSION}-linux-amd64"
BINARY_SHA256 = "154e775bd6bb589fc14cd93a689d8fbc64090aaa3ec537f0e3af298b13c6d386"
IMAGE = "Fedora-Cloud-Base-Generic-45-1.4.x86_64.qcow2"
IMAGE_BASE = "https://dl.fedoraproject.org/pub/fedora/linux/releases/45/Cloud/x86_64/images"
IMAGE_SHA256 = "50bdc5e70f6a24f540932d15411c1c6ae9fcfa40fb990d876d83c5cc823b2ad0"
PASSWORD_KEY = "aap_demo.gitea.admin_password"


def data_root() -> Path:
    return (
        Path(
            os.environ.get(
                "AAP_DEMO_GITEA_DIR",
                str(
                    Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
                    / "aap-demo/gitea"
                ),
            )
        )
        .expanduser()
        .resolve()
    )


def run(*command: str, input_text: str | None = None) -> str:
    result = subprocess.run(command, input=input_text, text=True, capture_output=True, check=False)
    if result.returncode:
        raise RuntimeError(
            f"{Path(command[0]).name} failed ({result.returncode}): {result.stderr[-1500:].strip()}"
        )
    return result.stdout.strip()


def virsh(*args: str) -> str:
    return run("virsh", "-c", "qemu:///system", *args)


def vault(action: str, value: str = "", key: str = PASSWORD_KEY) -> str | None:
    script = (
        'source "$1"; aap_demo_vault_get "$2"'
        if action == "get"
        else 'source "$1"; IFS= read -r value; aap_demo_vault_set "$2" "$value"'
    )
    result = subprocess.run(
        ["bash", "-c", script, "_", str(ROOT / "includes/credential-vault.sh"), key],
        input=value + "\n",
        text=True,
        capture_output=True,
        check=False,
    )
    if action == "get" and result.returncode == 1:
        return None
    if result.returncode:
        raise RuntimeError("Cannot read/write the managed credential in encrypted Vault")
    return result.stdout.strip() if action == "get" else None


def save_state(root: Path, state: dict) -> None:
    temporary = root / "state.json.tmp"
    temporary.write_text(json.dumps(state, indent=2) + "\n")
    temporary.chmod(0o600)
    temporary.replace(root / "state.json")


def check_domain(xml: str, state: dict) -> None:
    domain = ET.fromstring(xml)
    disk = domain.find("./devices/disk[@device='disk']/source")
    network = domain.find("./devices/interface/source")
    mac = domain.find("./devices/interface/mac")
    if (
        domain.findtext("uuid") != state["uuid"]
        or domain.findtext("description") != f"aap-demo:gitea:{state['uuid']}"
        or disk is None
        or disk.get("file") != str(DISKS / f"{state['uuid']}.qcow2")
        or network is None
        or network.get("network") != "default"
        or mac is None
        or mac.get("address") != state["mac"]
    ):
        raise RuntimeError("Gitea VM ownership/disk/network mismatch; refusing to change it")


def download(url: str, path: Path, checksum: str, algorithm: str) -> None:
    def digest(candidate: Path) -> str:
        hasher = hashlib.new(algorithm)
        with candidate.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                hasher.update(block)
        return hasher.hexdigest()

    if path.exists() and digest(path) == checksum:
        return
    temporary = path.with_suffix(path.suffix + ".part")
    print(f"Downloading verified artifact: {path.name}", flush=True)
    try:
        run(
            "curl",
            "--fail",
            "--show-error",
            "--silent",
            "--location",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--connect-timeout",
            "30",
            "--max-time",
            "900",
            "--output",
            str(temporary),
            url,
        )
        if digest(temporary) != checksum:
            raise RuntimeError(f"Checksum mismatch: {path.name}")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def preflight() -> None:
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise RuntimeError("Gitea VM currently requires Linux x86_64 with system libvirt/KVM")
    for command in (
        "virsh",
        "virt-install",
        "qemu-img",
        "genisoimage",
        "ssh",
        "scp",
        "sudo",
        "exportfs",
        "curl",
        "ssh-keygen",
    ):
        if not shutil.which(command):
            raise RuntimeError(f"Missing required tool: {command}")
    run("sudo", "-n", "true")
    run("systemctl", "is-active", "--quiet", "nfs-server")
    if not Path("/dev/kvm").exists():
        raise RuntimeError("KVM acceleration is unavailable")
    network = ET.fromstring(virsh("net-dumpxml", "default"))
    if network.find("forward") is None or network.find("forward").get("mode") != "nat":
        raise RuntimeError("Gitea requires the existing default libvirt NAT network")
    if "yes" not in virsh("net-info", "default").split("Active:", 1)[-1].splitlines()[0]:
        raise RuntimeError("The default libvirt network must already be active")


def create_vm(root: Path, state: dict, public_key: str) -> None:
    disk = DISKS / f"{state['uuid']}.qcow2"
    seed = DISKS / f"{state['uuid']}.iso"
    if disk.exists() or seed.exists():
        raise RuntimeError("Partial VM disks exist without a domain; inspect them before retrying")
    download(f"{IMAGE_BASE}/{IMAGE}", root / IMAGE, IMAGE_SHA256, "sha256")
    config = {
        "hostname": DOMAIN,
        "users": [
            {
                "name": "admin",
                "sudo": "ALL=(ALL) NOPASSWD:ALL",
                "shell": "/bin/bash",
                "lock_passwd": True,
                "ssh_authorized_keys": [public_key],
            }
        ],
        "ssh_pwauth": False,
        "disable_root": True,
        "package_update": True,
        "packages": ["git-core", "ca-certificates", "openssl", "qemu-guest-agent", "nfs-utils"],
        "runcmd": [
            [
                "install",
                "-m",
                "644",
                "/etc/ssh/ssh_host_ed25519_key.pub",
                "/etc/aap-demo-gitea-host.pub",
            ],
            ["restorecon", "/etc/aap-demo-gitea-host.pub"],
            ["systemctl", "start", "qemu-guest-agent"],
        ],
    }
    with tempfile.TemporaryDirectory(prefix="seed-", dir=root) as directory:
        source = Path(directory)
        (source / "user-data").write_text("#cloud-config\n" + json.dumps(config))
        (source / "meta-data").write_text(json.dumps({"instance-id": state["uuid"]}))
        run(
            "genisoimage",
            "-quiet",
            "-output",
            str(source / "seed.iso"),
            "-volid",
            "cidata",
            "-joliet",
            "-rock",
            str(source / "user-data"),
            str(source / "meta-data"),
        )
        run("sudo", "-n", "install", "-d", "-m", "755", str(DISKS))
        run("sudo", "-n", "cp", "--reflink=auto", str(root / IMAGE), str(disk))
        run("sudo", "-n", "qemu-img", "resize", str(disk), "40G")
        run("sudo", "-n", "install", "-m", "644", str(source / "seed.iso"), str(seed))
    run(
        "virt-install",
        "--connect",
        "qemu:///system",
        "--name",
        DOMAIN,
        "--uuid",
        state["uuid"],
        "--metadata",
        f"description=aap-demo:gitea:{state['uuid']}",
        "--memory",
        "2048",
        "--vcpus",
        "2",
        "--import",
        "--osinfo",
        "fedora-unknown",
        "--disk",
        f"path={disk},format=qcow2,bus=virtio",
        "--disk",
        f"path={seed},device=cdrom",
        "--network",
        f"network=default,model=virtio,mac={state['mac']}",
        "--channel",
        "unix,target.type=virtio,target.name=org.qemu.guest_agent.0",
        "--graphics",
        "none",
        "--noautoconsole",
    )


def guest_public_key() -> str:
    def agent(command: dict):
        return json.loads(virsh("qemu-agent-command", DOMAIN, json.dumps(command)))["return"]

    handle = agent(
        {
            "execute": "guest-file-open",
            "arguments": {"path": "/etc/aap-demo-gitea-host.pub", "mode": "r"},
        }
    )
    try:
        content = agent(
            {"execute": "guest-file-read", "arguments": {"handle": handle, "count": 4096}}
        )
        key = base64.b64decode(content["buf-b64"], validate=True).decode().strip()
        if not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\r\n]+)?", key):
            raise RuntimeError("Guest agent returned an invalid SSH host public key")
        return key
    finally:
        agent({"execute": "guest-file-close", "arguments": {"handle": handle}})


def wait_for_ssh(root: Path, state: dict) -> str:
    deadline = time.monotonic() + 900
    print("Waiting for DHCP, cloud-init and trusted guest-agent SSH identity...", flush=True)
    last_error = "No DHCP lease"
    while time.monotonic() < deadline:
        try:
            leases = virsh("domifaddr", DOMAIN, "--source", "lease")
            match = re.search(r"\bipv4\s+(\d+\.\d+\.\d+\.\d+)/\d+", leases)
            if match:
                address = str(ipaddress.IPv4Address(match[1]))
                key = guest_public_key()
                if state.get("ssh_host_key") and state["ssh_host_key"] != key:
                    raise ValueError(
                        "Gitea SSH host identity changed; refusing automatic replacement"
                    )
                state.update(ip=address, ssh_host_key=key)
                save_state(root, state)
                (root / "known_hosts").write_text(f"{address} {key}\n")
                return address
        except (RuntimeError, urllib.error.URLError) as error:
            last_error = str(error)
        time.sleep(5)
    raise RuntimeError(f"Gitea bootstrap timed out: {last_error}")


class Guest:
    def __init__(self, root: Path, address: str, key: str):
        self.address = address
        self.options = [
            "-i",
            key,
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            f"UserKnownHostsFile={root / 'known_hosts'}",
            "-o",
            "ConnectTimeout=15",
            "-o",
            "LogLevel=ERROR",
        ]

    def ssh(self, command: str, input_text: str | None = None) -> str:
        return run("ssh", *self.options, f"admin@{self.address}", command, input_text=input_text)

    def upload(self, path: Path) -> None:
        run("scp", *self.options, str(path), f"admin@{self.address}:/home/admin/gitea.bin")


def trust_ca(root: Path) -> None:
    if os.environ.get("AAP_DEMO_TRUST_CA", "true") != "true":
        print(f"CA trust not imported; use {root / 'ca.crt'} explicitly.", flush=True)
        return
    rhel = Path("/etc/pki/ca-trust/source/anchors")
    debian = Path("/usr/local/share/ca-certificates")
    if rhel.is_dir():
        anchor, update = rhel / "aap-demo-gitea.crt", "update-ca-trust"
    elif debian.is_dir():
        anchor, update = debian / "aap-demo-gitea.crt", "update-ca-certificates"
    else:
        raise RuntimeError(
            "No supported host CA store; set AAP_DEMO_TRUST_CA=false to use explicit CA"
        )
    run("sudo", "-n", "install", "-m", "644", str(root / "ca.crt"), str(anchor))
    run("sudo", "-n", update)
    if shutil.which("certutil"):
        databases = [Path.home() / ".pki/nssdb", Path.home() / ".local/share/pki/nssdb"]
        databases.extend((Path.home() / ".mozilla/firefox").glob("*/"))
        for directory in databases:
            if (directory / "cert9.db").is_file():
                run(
                    "certutil",
                    "-d",
                    f"sql:{directory}",
                    "-A",
                    "-t",
                    "C,,",
                    "-n",
                    "aap-demo-gitea",
                    "-i",
                    str(root / "ca.crt"),
                )
    else:
        print("WARNING: certutil unavailable; browser CA trust was not imported.", flush=True)


def api(root: Path, url: str, path: str, password: str) -> dict:
    credential = base64.b64encode(f"aap-demo:{password}".encode()).decode()
    request = urllib.request.Request(
        url + path,
        headers={"Accept": "application/json"},
    )
    request.add_unredirected_header("Authorization", f"Basic {credential}")
    context = ssl.create_default_context(cafile=str(root / "ca.crt"))
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=context),
    )
    with opener.open(request, timeout=30) as response:
        return json.load(response)


def reserve_address(state: dict, address: str) -> None:
    network = ET.fromstring(virsh("net-dumpxml", "default"))
    hosts = network.findall("./ip/dhcp/host")
    matches = [
        host
        for host in hosts
        if host.get("mac") == state["mac"]
        or host.get("ip") == address
        or host.get("name") == DOMAIN
    ]
    if matches:
        if len(matches) != 1 or any(
            matches[0].get(name) != value
            for name, value in {"mac": state["mac"], "ip": address, "name": DOMAIN}.items()
        ):
            raise RuntimeError("DHCP reservation conflicts with another VM; leaving it unchanged")
        return
    reservation = ET.Element("host", mac=state["mac"], name=DOMAIN, ip=address)
    virsh(
        "net-update",
        "default",
        "add-last",
        "ip-dhcp-host",
        ET.tostring(reservation, encoding="unicode"),
        "--live",
        "--config",
    )


def deploy(root: Path, state: dict, key: str) -> None:
    domains = virsh("list", "--all", "--name").splitlines()
    if DOMAIN not in domains:
        if state.get("provisioned"):
            raise RuntimeError(
                "Recorded Gitea VM is missing; refusing to replace its data automatically"
            )
        public = run("ssh-keygen", "-y", "-f", key)
        create_vm(root, state, public)
    check_domain(virsh("dumpxml", DOMAIN), state)
    if virsh("domstate", DOMAIN) != "running":
        virsh("start", DOMAIN)
    virsh("autostart", DOMAIN)
    address = wait_for_ssh(root, state)
    guest = Guest(root, address, key)
    guest.ssh("sudo cloud-init status --wait >/dev/null")
    reserve_address(state, address)
    guest.ssh(
        "id git >/dev/null 2>&1 || sudo useradd --system --create-home "
        "--home-dir /var/lib/gitea --shell /bin/bash git"
    )
    uid = guest.ssh("id -u git")
    gid = guest.ssh("id -g git")
    if not uid.isdecimal() or not gid.isdecimal() or int(uid) < 1 or int(gid) < 1:
        raise RuntimeError("Invalid unprivileged Gitea storage identity")
    network = ET.fromstring(virsh("net-dumpxml", "default"))
    gateway = str(ipaddress.IPv4Address(network.find("ip").get("address")))
    export = f"/var/lib/aap-demo-gitea/instances/{state['uuid']}"
    print("Reconciling dedicated host NFS storage...", flush=True)
    run("sudo", "-n", "bash", str(HERE / "host-nfs.sh"), state["uuid"], address, uid, gid)
    if not state.get("provisioned"):
        download(
            f"https://dl.gitea.com/gitea/{VERSION}/{BINARY}", root / BINARY, BINARY_SHA256, "sha256"
        )
        guest.upload(root / BINARY)
        guest.ssh(
            "sudo install -m 755 /home/admin/gitea.bin /usr/local/bin/gitea; "
            "rm -f /home/admin/gitea.bin"
        )
    print("Configuring native Gitea, HTTPS and database backups...", flush=True)
    actions = "true" if state.get("lightwell_actions") is True else "false"
    guest.ssh(
        f"sudo bash -s -- {address} {gateway} {export} {actions}",
        (HERE / "configure.sh").read_text(),
    )
    users = guest.ssh(
        "sudo -u git /usr/local/bin/gitea --config /etc/gitea/app.ini admin user list"
    )
    if not any(re.match(r"^\d+\s+aap-demo\s", line) for line in users.splitlines()):
        output = guest.ssh(
            "sudo -u git /usr/local/bin/gitea --config /etc/gitea/app.ini admin user create "
            "--username aap-demo --email admin@gitea.demo.lab --admin "
            "--random-password --random-password-length 32 --must-change-password=false"
        )
        password_match = re.search(r"(?m)^generated random password is '([^\r\n]+)'$", output)
        if not password_match:
            raise RuntimeError(
                "Native admin creation did not return the expected generated password"
            )
        vault("set", password_match[1])
        del output, password_match
    password = vault("get")
    if not password:
        raise RuntimeError(
            "Gitea admin exists but its encrypted Vault password is missing; not reset"
        )
    certificate = guest.ssh("sudo cat /etc/gitea/ca/ca.crt")
    ca = root / "ca.crt"
    if ca.exists() and ca.read_text().strip() != certificate:
        raise RuntimeError("Gitea CA identity changed; refusing automatic trust replacement")
    ca.write_text(certificate + "\n")
    guest.ssh("sudo systemctl restart gitea; sudo systemctl is-active --quiet gitea")
    url = f"https://{address}:3000"
    print("Verifying direct HTTPS administrator access...", flush=True)
    deadline = time.monotonic() + 120
    while True:
        try:
            user = api(root, url, "/api/v1/user", password)
            if user.get("login") != "aap-demo" or not user.get("is_admin"):
                raise RuntimeError("Gitea administrator authentication returned an unexpected user")
            break
        except urllib.error.HTTPError as error:
            if error.code not in (500, 502, 503, 504) or time.monotonic() >= deadline:
                raise RuntimeError(
                    f"Gitea authentication/health returned HTTP {error.code}"
                ) from None
            time.sleep(3)
        except urllib.error.URLError:
            if time.monotonic() >= deadline:
                raise RuntimeError("Gitea HTTPS/authentication did not become ready") from None
            time.sleep(3)
    del password
    print("Importing the verified local CA and taking a consistent database backup...", flush=True)
    trust_ca(root)
    guest.ssh("sudo systemctl start gitea-db-backup.service")
    state.update(url=url, provisioned=True, version=VERSION, os="Fedora 45", nfs_export=export)
    save_state(root, state)
    print(
        f"Gitea ready: {url}\nVM: {DOMAIN} (outside CRC)\n"
        f"Username: aap-demo; password: encrypted Vault key {PASSWORD_KEY}\n"
        "Disable stops the VM and retains repositories. No runner installed.",
        flush=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ssh-key")
    parser.add_argument("action", choices=("deploy", "stop", "preflight"))
    args = parser.parse_args()
    os.umask(0o077)
    preflight()
    if args.action == "preflight":
        print("Gitea VM prerequisites passed (no resources changed)")
        return
    root = data_root()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root / "operation.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another Gitea VM operation is running") from None
        path = root / "state.json"
        if path.exists():
            state = json.loads(path.read_text())
            if state.get("domain") != DOMAIN or str(uuid.UUID(state["uuid"])) != state["uuid"]:
                raise RuntimeError("Invalid Gitea ownership state")
        elif DOMAIN in virsh("list", "--all", "--name").splitlines():
            raise RuntimeError("An unowned Gitea VM already exists; refusing to adopt it")
        elif args.action == "stop":
            print("No managed Gitea VM; nothing to stop")
            return
        else:
            identity = uuid.uuid4()
            suffix = ":".join(f"{byte:02x}" for byte in identity.bytes[-3:])
            state = {
                "domain": DOMAIN,
                "uuid": str(identity),
                "mac": f"52:54:00:{suffix}",
                "provisioned": False,
            }
            save_state(root, state)
        if args.action == "stop":
            check_domain(virsh("dumpxml", DOMAIN), state)
            if virsh("domstate", DOMAIN) != "shut off":
                virsh("shutdown", DOMAIN)
                deadline = time.monotonic() + 120
                while virsh("domstate", DOMAIN) != "shut off":
                    if time.monotonic() >= deadline:
                        raise RuntimeError(
                            "Gitea graceful shutdown timed out; no force-stop attempted"
                        )
                    time.sleep(3)
            virsh("autostart", DOMAIN, "--disable")
            print("Gitea stopped; VM disk, repositories, credentials and CA retained outside CRC.")
        else:
            if not args.ssh_key:
                raise RuntimeError("An encrypted-Vault SSH key must be supplied by deploy.sh")
            deploy(root, state, args.ssh_key)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, ET.ParseError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
