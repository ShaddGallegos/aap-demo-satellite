#!/usr/bin/env python3
"""Explicitly prepare retained local services for the Lightwell simulation."""

from __future__ import annotations

import argparse
import base64
import fcntl
import importlib.util
import ipaddress
import json
import os
import secrets
import shlex
import ssl
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BACKEND = (
    "quay.io/zleblanc/openflake-backend@sha256:"
    "a6c1122625e9c7a8f19d5ced862d4357e3c0d8ad10b93b9bd7dd559d1e180722"
)
FRONTEND = (
    "quay.io/zleblanc/openflake-frontend@sha256:"
    "0a2fe2ea46c97cf85200461532f5d33d3fc7f41e6bb9d1702b48863c4c16d3ef"
)
POSTGRES = (
    "docker.io/library/postgres@sha256:"
    "81e77a4833487b8132fe4b00bedd39dc3f74b8641e387f19312a48f7de218c2e"
)
RUNNER = "gitea-runner-6.0.0-linux-amd64"
RUNNER_SHA256 = "62ecab223535968ba3fa46cf32f8f50279f0664ba14c6d3848c2f02210f9828e"
MARKER = "Managed by aap-demo lightwell"
REPOSITORY = "inventory-service"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load local helper: {path.name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gitea = load("lightwell_gitea", ROOT / "addons/gitea/manage.py")


def state_root() -> Path:
    return (
        Path(
            os.environ.get(
                "AAP_DEMO_LIGHTWELL_DIR",
                str(
                    Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
                    / "aap-demo/lightwell"
                ),
            )
        )
        .expanduser()
        .resolve()
    )


def save(config: dict) -> None:
    root = state_root()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = root / "config.json.tmp"
    temporary.write_text(json.dumps(config, indent=2) + "\n")
    temporary.chmod(0o600)
    temporary.replace(root / "config.json")


def credential(name: str) -> str:
    key = f"aap_demo.lightwell.{name}"
    value = gitea.vault("get", key=key)
    if value is None:
        value = secrets.token_urlsafe(32)
        gitea.vault("set", value, key=key)
    if not value:
        raise RuntimeError(f"Empty managed credential: {name}")
    return value


def request(origin: str, path: str, authorization: str, payload=None, method="GET"):
    data = None if payload is None else json.dumps(payload).encode()
    message = urllib.request.Request(
        origin + path,
        data=data,
        method=method,
        headers={"Accept": "application/json", "Content-Type": "application/json"},
    )
    message.add_unredirected_header("Authorization", authorization)
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
    )
    try:
        with opener.open(message, timeout=60) as response:
            data = response.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as error:
        raise RuntimeError(
            f"{method} {path.partition('?')[0]} returned HTTP {error.code}"
        ) from None


def basic(username: str, password: str) -> str:
    return "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode()


def git_api(config, path, payload=None, method="GET"):
    return request(
        config["gitea"], "/api/v1" + path, basic("aap-demo", gitea.vault("get")), payload, method
    )


def services(key: str) -> None:
    root = state_root()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    git_root = gitea.data_root()
    with (git_root / "operation.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = json.loads((git_root / "state.json").read_text())
        gitea.check_domain(gitea.virsh("dumpxml", gitea.DOMAIN), state)
        if gitea.virsh("domstate", gitea.DOMAIN) != "running":
            raise RuntimeError("Start the existing Gitea VM before preparing Lightwell")
        guest = gitea.Guest(git_root, state["ip"], key)
        config_path = root / "config.json"
        config = json.loads(config_path.read_text()) if config_path.exists() else {}
        config.update(
            gitea=state["url"],
            openflake=f"https://{state['ip']}:8443",
            gitea_owner="aap-demo",
            gitea_repo=REPOSITORY,
            gitea_uuid=state["uuid"],
        )
        if config_path.exists() and config.get("owner") != MARKER:
            raise RuntimeError("Unowned Lightwell service configuration; refusing to replace it")
        config["owner"] = MARKER
        values = {
            "backend": BACKEND,
            "frontend": FRONTEND,
            "postgres": POSTGRES,
            "openflake": config["openflake"],
            "admin_password": credential("openflake_password"),
            "postgres_password": credential("postgres_password"),
            "secret_key": credential("openflake_secret"),
        }
        gitea.download(
            f"https://gitea.com/gitea/runner/releases/download/v6.0.0/{RUNNER}",
            root / RUNNER,
            RUNNER_SHA256,
            "sha256",
        )
        gitea.run(
            "scp",
            *guest.options,
            str(root / RUNNER),
            f"admin@{state['ip']}:/home/admin/gitea-runner.bin",
        )
        source = (
            "LIGHTWELL_CONFIG=" + shlex.quote(json.dumps(values)) + "\nexport LIGHTWELL_CONFIG\n"
        )
        guest.ssh("sudo bash -s", source + (HERE / "services-guest.sh").read_text())
        state["lightwell_actions"] = True
        gitea.save_state(git_root, state)
        save(config)
        deadline = time.monotonic() + 180
        while True:
            try:
                result = request(
                    config["openflake"],
                    "/api/flake/table/change_request?sysparm_limit=1",
                    basic("admin", values["admin_password"]),
                )
                if not isinstance(result.get("result"), list):
                    raise RuntimeError("Unexpected OpenFlake Table API response")
                break
            except (RuntimeError, urllib.error.URLError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(5)
        print("PASS: authenticated OpenFlake change API over verified HTTPS")
        prepare_repository(config)
        save(config)


def prepare_repository(config: dict) -> None:
    repositories = git_api(config, "/user/repos?limit=50")
    matches = [repo for repo in repositories if repo["full_name"] == f"aap-demo/{REPOSITORY}"]
    if matches:
        if matches[0].get("description") != MARKER:
            raise RuntimeError("Unowned inventory-service repository; refusing to seed it")
        if not matches[0].get("empty"):
            print("Reusing the owned CI repository without resetting its branch or files")
            return
    else:
        git_api(
            config,
            "/user/repos",
            {
                "name": REPOSITORY,
                "private": True,
                "description": MARKER,
                "default_branch": "main",
                "auto_init": False,
            },
            "POST",
        )
    files = [
        {
            "operation": "create",
            "path": str(path.relative_to(HERE / "seed")),
            "content": base64.b64encode(path.read_bytes()).decode(),
        }
        for path in sorted((HERE / "seed").rglob("*"))
        if path.is_file()
    ]
    git_api(
        config,
        f"/repos/aap-demo/{REPOSITORY}/contents",
        {
            "branch": "main",
            "message": "Initialize the isolated local CI/CD simulation",
            "files": files,
        },
        "POST",
    )
    print("Seeded original simulation files; no vulnerable dependencies installed")


def managed(api, endpoint, name, payload):
    existing = api.find(endpoint, name)
    if existing and existing.get("description") != MARKER:
        raise RuntimeError(f"Refusing to adopt unowned {endpoint}: {name}")
    payload = {"name": name, "description": MARKER, **payload}
    if existing:
        return api.request(f"/{endpoint}/{existing['id']}/", "PATCH", payload)
    return api.request(f"/{endpoint}/", "POST", payload)


def prepare_platform_ca() -> None:
    namespace = os.environ.get("NAMESPACE", "aap-operator")
    command = ("kubectl", "-n", namespace)
    platforms = json.loads(gitea.run(*command, "get", "aap", "-o", "json"))["items"]
    if len(platforms) != 1:
        raise RuntimeError("Exactly one AAP platform is required in the selected namespace")
    platform = platforms[0]
    name = "aap-demo-lightwell-ca"
    current = platform.get("spec", {}).get("bundle_cacert_secret")
    if current and current != name:
        raise RuntimeError("AAP already uses another owner's CA bundle; refusing to replace it")
    existing = gitea.run(*command, "get", "secret", name, "--ignore-not-found", "-o", "json")
    labels = {"app.kubernetes.io/managed-by": "aap-demo-lightwell"}
    if (
        existing
        and json.loads(existing)["metadata"].get("labels", {}).get("app.kubernetes.io/managed-by")
        != labels["app.kubernetes.io/managed-by"]
    ):
        raise RuntimeError("Refusing to replace an unowned AAP CA secret")
    crc_ca = Path(os.environ.get("AAP_DEMO_DIR", Path.home() / ".aap-demo")) / "crc-ingress-ca.crt"
    bundle = (gitea.data_root() / "ca.crt").read_text().rstrip() + "\n" + crc_ca.read_text()
    ssl.create_default_context(cadata=bundle)
    secret = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": name, "namespace": namespace, "labels": labels},
        "type": "Opaque",
        "data": {"bundle-ca.crt": base64.b64encode(bundle.encode()).decode()},
    }
    gitea.run(*command, "apply", "-f", "-", input_text=json.dumps(secret))
    gitea.run(
        *command,
        "patch",
        "aap",
        platform["metadata"]["name"],
        "--type=merge",
        "-p",
        json.dumps({"spec": {"bundle_cacert_secret": name}}),
    )
    print("Configured the owned AAP CA bundle without disabling certificate validation")


def prepare_aap(api) -> None:
    import yaml

    path = state_root() / "config.json"
    config = json.loads(path.read_text())
    if config.get("owner") != MARKER:
        raise RuntimeError("Managed local services must be prepared explicitly first")
    index = int(os.environ.get("LIGHTWELL_APP_NODE", config.get("app_index", 0)))
    if index < 1:
        raise RuntimeError("Set LIGHTWELL_APP_NODE to the dedicated, newly prepared Fleet node")
    node = Path(os.environ.get("AAP_DEMO_DIR", Path.home() / ".aap-demo")) / f"fleet/node-{index}"
    if not (node / "meta").is_file():
        raise RuntimeError("The selected dedicated Fleet node has no native local metadata")
    metadata = dict(
        line.split("=", 1) for line in (node / "meta").read_text().splitlines() if "=" in line
    )
    if metadata.get("INDEX") != str(index):
        raise RuntimeError("Selected application node metadata has a different identity")
    if int(metadata.get("MEMORY_MB", "1024")) < 4096:
        raise RuntimeError(
            "Application setup needs at least 4 GiB; resize the selected node with "
            f"FLEET_NODE_MEM=4096 aap-demo fleet node {index} restart"
        )
    owner = node / "lightwell-owner"
    if owner.exists() and owner.read_text().strip() != MARKER:
        raise RuntimeError("The selected application node belongs to another owner")
    if not owner.exists() and "LIGHTWELL_APP_NODE" not in os.environ:
        raise RuntimeError("Set LIGHTWELL_APP_NODE to deliberately select an unmarked app node")
    name = f"aap-fleet-node-{index}"
    app_name = name
    fleet = api.find("inventories", "Fleet")
    if not fleet:
        raise RuntimeError("Register the dedicated Fleet application host first")
    hosts = api.request(f"/inventories/{fleet['id']}/hosts/?name={name}&page_size=2")
    if hosts.get("count") != 1:
        raise RuntimeError("Exactly one dedicated Fleet application host is required")
    host = hosts["results"][0]
    variables = yaml.safe_load(host["variables"])
    if not isinstance(variables, dict) or not variables.get("ansible_host"):
        raise RuntimeError("Invalid Fleet SSH endpoint")
    port = int(variables["ansible_port"])
    variables["ansible_ssh_common_args"] = (
        "-o StrictHostKeyChecking=yes "
        "-o UserKnownHostsFile={{ lookup('env', 'LIGHTWELL_KNOWN_HOSTS') }}"
    )
    known_hosts = (
        Path(os.environ.get("AAP_DEMO_DIR", Path.home() / ".aap-demo")) / "fleet/known_hosts"
    )
    entries = gitea.run("ssh-keygen", "-F", f"[127.0.0.1]:{port}", "-f", str(known_hosts))
    keys = [line.split()[1:3] for line in entries.splitlines() if not line.startswith("#")]
    if len(keys) != 1 or len(keys[0]) != 2:
        raise RuntimeError("No unambiguous previously verified Fleet SSH host key")
    prepare_platform_ca()
    trusted_host = f"[{variables['ansible_host']}]:{port} {' '.join(keys[0])}\n"
    organization = api.find("organizations", "Default")
    org_id = organization["id"]
    inventory = managed(api, "inventories", "Lightwell CI/CD", {"organization": org_id})
    associated = api.request(f"/inventories/{inventory['id']}/hosts/?page_size=2")
    if any(
        item["name"] != name or item.get("description") != MARKER
        for item in associated.get("results", [])
    ):
        raise RuntimeError("Unowned hosts in Lightwell inventory; refusing to alter it")
    host_payload = {
        "name": name,
        "description": MARKER,
        "variables": json.dumps(variables),
        "enabled": True,
    }
    if associated.get("results"):
        api.request(f"/hosts/{associated['results'][0]['id']}/", "PATCH", host_payload)
    else:
        api.request(f"/inventories/{inventory['id']}/hosts/", "POST", host_payload)
    definitions = [
        (
            "Lightwell OpenFlake API",
            [
                {"id": "username", "label": "Username", "type": "string"},
                {"id": "password", "label": "Password", "type": "string", "secret": True},
            ],
            {"env": {"SN_USERNAME": "{{ username }}", "SN_PASSWORD": "{{ password }}"}},
        ),
        (
            "Lightwell Gitea API",
            [{"id": "token", "label": "Repository API token", "type": "string", "secret": True}],
            {"extra_vars": {"gitea_token_override": "{{ token }}"}},
        ),
        (
            "Lightwell SSH Host Trust",
            [
                {
                    "id": "known_hosts",
                    "label": "Pinned host key",
                    "type": "string",
                    "multiline": True,
                }
            ],
            {
                "file": {"template": "{{ known_hosts }}"},
                "env": {"LIGHTWELL_KNOWN_HOSTS": "{{ tower.filename }}"},
            },
        ),
    ]
    types = {}
    for type_name, fields, injectors in definitions:
        record = managed(
            api,
            "credential_types",
            type_name,
            {
                "kind": "cloud",
                "inputs": {"fields": fields, "required": [f["id"] for f in fields]},
                "injectors": injectors,
            },
        )
        types[type_name] = record["id"]
    token = gitea.vault("get", key="aap_demo.lightwell.gitea_token")
    if not token:
        tokens = git_api(config, "/users/aap-demo/tokens")
        if any(item["name"] == "aap-demo-lightwell" for item in tokens):
            raise RuntimeError("Existing Lightwell Git token is missing from Vault; not rotated")
        result = git_api(
            config,
            "/users/aap-demo/tokens",
            {
                "name": "aap-demo-lightwell",
                "scopes": ["write:repository"],
            },
            "POST",
        )
        token = result["sha1"]
        gitea.vault("set", token, key="aap_demo.lightwell.gitea_token")
    for name, kind, inputs in (
        (
            "Lightwell OpenFlake",
            "Lightwell OpenFlake API",
            {"username": "admin", "password": credential("openflake_password")},
        ),
        ("Lightwell Gitea", "Lightwell Gitea API", {"token": token}),
        ("Lightwell SSH Host Trust", "Lightwell SSH Host Trust", {"known_hosts": trusted_host}),
    ):
        managed(
            api,
            "credentials",
            name,
            {
                "organization": org_id,
                "credential_type": types[kind],
                "inputs": inputs,
            },
        )
    config.update(app_index=index, app_host=app_name, ssh_credential="Lightwell SSH Host Trust")
    save(config)
    owner.write_text(MARKER + "\n")
    print(f"Prepared owned AAP inventory and credentials for isolated host {app_name}")


def runner(key: str) -> None:
    config = json.loads((state_root() / "config.json").read_text())
    if config.get("owner") != MARKER:
        raise RuntimeError("Managed Lightwell services are required")
    root = gitea.data_root()
    state = json.loads((root / "state.json").read_text())
    gitea.check_domain(gitea.virsh("dumpxml", gitea.DOMAIN), state)
    if config["gitea_uuid"] != state["uuid"]:
        raise RuntimeError("Recorded Git server identity changed")
    guest = gitea.Guest(root, state["ip"], key)
    token = git_api(
        config,
        f"/repos/aap-demo/{REPOSITORY}/actions/runners/registration-token",
        method="POST",
    )["token"]
    ca = Path(os.environ.get("AAP_DEMO_DIR", Path.home() / ".aap-demo")) / "crc-ingress-ca.crt"
    network = ET.fromstring(gitea.virsh("net-dumpxml", "default"))
    address = str(ipaddress.IPv4Address(network.find("ip").get("address")))
    if ipaddress.IPv4Address(address).is_loopback:
        raise RuntimeError("The runner needs a host ingress address reachable from the VM")
    route = os.environ.get("LIGHTWELL_AO_ROUTE")
    if not route or "/" in route or any(character.isspace() for character in route):
        raise RuntimeError("Discover and supply LIGHTWELL_AO_ROUTE")
    gitea.run("sudo", "bash", str(HERE / "host-ingress.sh"), state["ip"], address)
    payload = {
        "origin": config["gitea"],
        "token": token,
        "crc_ca": ca.read_text(),
        "crc_ip": address,
        "ao_route": route,
    }
    source = "LIGHTWELL_CONFIG=" + shlex.quote(json.dumps(payload)) + "\nexport LIGHTWELL_CONFIG\n"
    guest.ssh("sudo bash -s", source + (HERE / "runner-guest.sh").read_text())
    print("Registered the unprivileged repository-scoped CI runner with strict TLS")


def configure_ci(ao) -> str:
    config = json.loads((state_root() / "config.json").read_text())
    response = ao.request("/service_accounts?limit=100")
    accounts = response.get("resources", response.get("results", []))
    if len(accounts) >= 100:
        raise RuntimeError("AO service-account list may be truncated; refusing ambiguous selection")
    matches = [account for account in accounts if account["name"] == "aap-demo Lightwell CI"]
    if len(matches) != 1:
        raise RuntimeError("An unambiguous dedicated Lightwell webhook service account is required")
    account = matches[0]
    client_id = gitea.vault("get", key="aap_demo.lightwell.ao_client_id")
    secret = gitea.vault("get", key="aap_demo.lightwell.ao_client_secret")
    if config.get("ao_account_id") != account["id"]:
        result = ao.request(
            f"/service_accounts/{account['id']}/credentials",
            "POST",
            {"credential_type": "client_credentials"},
        )
        client_id, secret = result["identifier"], result["client_secret"]
        if not all(isinstance(value, str) and value for value in (client_id, secret)):
            raise RuntimeError("AO did not return usable service-account client credentials")
        gitea.vault("set", client_id, key="aap_demo.lightwell.ao_client_id")
        gitea.vault("set", secret, key="aap_demo.lightwell.ao_client_secret")
        config.update(
            ao_account_id=account["id"],
            ao_credential_id=result["id"],
            ao_credential_expires_at=result.get("expires_at"),
        )
        save(config)
    if not client_id or not secret:
        raise RuntimeError("Existing AO service-account secret is missing from Vault; not rotated")
    record = ao.request(
        f"/service_accounts/{account['id']}/credentials/{config['ao_credential_id']}"
    )
    expiry = record.get("expires_at")
    if record.get("status") != "active" or (
        expiry
        and datetime.fromisoformat(expiry.replace("Z", "+00:00")) <= datetime.now(timezone.utc)
    ):
        raise RuntimeError(
            "AO client credential is inactive or expired; renew it natively and update Vault"
        )
    endpoint = f"/repos/aap-demo/{REPOSITORY}/actions/secrets"
    for name, value in {
        "AO_ORIGIN": "https://" + os.environ["LIGHTWELL_AO_ROUTE"],
        "AO_CLIENT_ID": client_id,
        "AO_CLIENT_SECRET": secret,
    }.items():
        git_api(config, endpoint + "/" + name, {"data": value}, "PUT")
    files = []
    for name in (".gitea/workflows/ci.yml", "notify.py"):
        record = git_api(config, f"/repos/aap-demo/{REPOSITORY}/contents/{name}?ref=main")
        desired = (HERE / "seed" / name).read_bytes()
        if base64.b64decode(record["content"]) != desired:
            files.append(
                {
                    "operation": "update",
                    "path": name,
                    "sha": record["sha"],
                    "content": base64.b64encode(desired).decode(),
                }
            )
    if files:
        git_api(
            config,
            f"/repos/aap-demo/{REPOSITORY}/contents",
            {
                "branch": "main",
                "message": "Configure scoped local CI authentication",
                "files": files,
            },
            "POST",
        )
    print("Configured encrypted repository secrets for short-lived AO token exchange")
    return account["id"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("services", "runner"))
    parser.add_argument("--ssh-key", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    if args.action == "services":
        services(args.ssh_key)
    else:
        runner(args.ssh_key)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, KeyError, urllib.error.URLError) as error:
        print(f"ERROR: Lightwell preparation failed: {error}", file=sys.stderr)
        raise SystemExit(1) from None
