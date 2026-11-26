#!/usr/bin/env python3
"""Bind the upstream Lightwell simulation to existing, explicitly selected lab services."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import ssl
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from types import SimpleNamespace
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
REF = "3e2b24e6c3d5519cb380298ce45727412f17e20d"
PROJECT = "aap-demo Lightwell CI/CD"
MARKER = "Managed by aap-demo lightwell"
WORKFLOW = "CI/CD Pipeline - Dev Test, Approval, Prod Deploy with Rollback"
TEMPLATES = {
    "CI/CD Demo - Deploy and Test Dev": "playbooks/cicd_deploy_dev_and_test.yml",
    "CI/CD Demo - Drain Load Balancer": "playbooks/cicd_drain_lb.yml",
    "CI/CD Demo - Deploy to Prod": "playbooks/cicd_deploy_prod.yml",
    "CI/CD Demo - Rollback to Snapshot": "playbooks/cicd_rollback_to_snapshot.yml",
    "CI/CD Demo - Close Loop": "playbooks/cicd_close_loop.yml",
    "CI/CD Demo - Simulate Lightwell PR": "playbooks/cicd_simulate_lightwell_pr.yml",
    "CI/CD Demo - Setup Demo Host": "setup/cicd_setup_demo_host.yml",
}
LOCAL_TEMPLATES = {"CI/CD Demo - Close Loop", "CI/CD Demo - Simulate Lightwell PR"}


def load_helper(name: str, filename: str) -> Any:
    spec = importlib.util.spec_from_file_location(name, ROOT / "addons/ao/scripts" / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load AO helper {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def service_url(variable: str) -> str:
    value = os.environ.get(variable, "").rstrip("/")
    parsed = urllib.parse.urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path not in ("", "/")
    ):
        raise ValueError(f"{variable} must be a credential-free HTTPS service origin")
    return value


def configuration() -> dict[str, str]:
    path = (
        Path(
            os.environ.get(
                "AAP_DEMO_LIGHTWELL_DIR",
                str(
                    Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
                    / "aap-demo/lightwell"
                ),
            )
        )
        / "config.json"
    )
    saved = json.loads(path.read_text()) if path.exists() else {}
    if saved and saved.get("owner") != MARKER:
        raise RuntimeError("Unowned Lightwell configuration")
    for variable, key in (
        ("LIGHTWELL_GITEA_URL", "gitea"),
        ("LIGHTWELL_OPENFLAKE_URL", "openflake"),
    ):
        if variable not in os.environ and saved.get(key):
            os.environ[variable] = saved[key]
    return {
        "gitea": service_url("LIGHTWELL_GITEA_URL"),
        "openflake": service_url("LIGHTWELL_OPENFLAKE_URL"),
        "inventory": os.environ.get("LIGHTWELL_INVENTORY", "Lightwell CI/CD"),
        "machine_credential": os.environ.get("LIGHTWELL_MACHINE_CREDENTIAL", "Fleet SSH Key"),
        "itsm_credential": os.environ.get("LIGHTWELL_ITSM_CREDENTIAL", "Lightwell OpenFlake"),
        "git_credential": os.environ.get("LIGHTWELL_GIT_CREDENTIAL", "Lightwell Gitea"),
        "gitea_owner": saved.get("gitea_owner", "gitea-admin"),
        "ssh_credential": saved.get("ssh_credential", ""),
    }


def require(api: Any, resource: str, name: str) -> dict[str, Any]:
    record = api.find(resource, name)
    if not record:
        raise RuntimeError(f"Required AAP {resource} record is missing: {name}")
    return record


def owned(record: dict[str, Any]) -> None:
    if not str(record.get("description", "")).startswith(MARKER):
        raise RuntimeError(
            f"Refusing to overwrite or delete unmanaged resource: {record.get('name')}"
        )


def validate_workflow(document: dict[str, Any]) -> None:
    if document.get("name") != WORKFLOW:
        raise RuntimeError("Unexpected upstream workflow name; refusing unchecked ownership")
    nodes = document.get("nodes", [])
    approvals = {node["id"] for node in nodes if node.get("type") == "approval"}
    if not approvals or any(
        node.get("parameters", {}).get("fallback_decision") != "reject"
        for node in nodes
        if node.get("type") == "approval"
    ):
        raise RuntimeError("Upstream CI/CD workflow has no human approval gate")
    for node in nodes:
        parameters = node.get("parameters", node.get("config", {}))
        if node.get("type") == "agentic" and parameters.get("tool_selection_strategy") != "NONE":
            raise RuntimeError("CI/CD note-writing agents must have tools disabled")
        if node.get("type") == "aap_job_template":
            if parameters.get("job_template_name") not in TEMPLATES:
                raise RuntimeError("Upstream workflow references an unrecognized job template")
    protected = {
        node["id"]
        for node in nodes
        if node.get("parameters", {}).get("job_template_name")
        in {
            "CI/CD Demo - Drain Load Balancer",
            "CI/CD Demo - Deploy to Prod",
            "CI/CD Demo - Rollback to Snapshot",
        }
    }
    if len(protected) != 3:
        raise RuntimeError("CI/CD workflow must retain drain, production deployment and rollback")
    edges = document.get("edges", [])
    for edge in edges:
        if edge["from"] in approvals and edge.get("from_port") != "approved":
            raise RuntimeError("Only explicit approval may continue deployment")
    pending = [trigger["id"] for trigger in document.get("triggers", [])]
    visited: set[str] = set()
    while pending:
        current = pending.pop()
        if current in visited or current in approvals:
            continue
        visited.add(current)
        pending.extend(edge["to"] for edge in edges if edge["from"] == current)
    if protected & visited:
        raise RuntimeError("CI/CD workflow bypasses human production approval")


def constrain_webhook(document: dict[str, Any]) -> None:
    if len(document.get("triggers", [])) != 1:
        raise RuntimeError("CI/CD workflow must have exactly one authenticated webhook")
    for trigger in document.get("triggers", []):
        parameters = trigger.setdefault("parameters", {})
        if (
            trigger.get("type") != "webhook_trigger"
            or parameters.get("webhook_path") != "lightwell-ci-cd"
        ):
            raise RuntimeError("CI/CD workflow has an unexpected trigger")
        parameters["input_schema"] = {
            "type": "object",
            "additionalProperties": False,
            "required": [
                "app_name",
                "artifact_version",
                "git_sha",
                "ci_build_url",
                "change_request",
            ],
            "properties": {
                "app_name": {"type": "string", "enum": ["inventory-service"]},
                "artifact_version": {
                    "type": "string",
                    "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$",
                },
                "git_sha": {"type": "string", "pattern": "^[0-9a-fA-F]{7,64}$"},
                "ci_build_url": {"type": "string", "pattern": "^https://", "maxLength": 2048},
                "change_request": {"type": "string", "pattern": "^CHG[0-9]{1,30}$"},
                "affected_cve": {"type": "string", "pattern": "^CVE-[0-9]{4}-[0-9]{4,10}$"},
                "ci_build_number": {"type": "string", "pattern": "^[0-9]{1,20}$"},
            },
        }


def provision(
    api: Any, ao: Any, importer: Any, bindings: dict[str, str], config: dict[str, str]
) -> None:
    inventory = require(api, "inventories", config["inventory"])
    machine = require(api, "credentials", config["machine_credential"])
    itsm = require(api, "credentials", config["itsm_credential"])
    git = require(api, "credentials", config["git_credential"])
    ssh = (
        require(api, "credentials", config["ssh_credential"])
        if config.get("ssh_credential")
        else None
    )
    organization = require(api, "organizations", "Default")
    hosts = api.request(f"/inventories/{inventory['id']}/hosts/?page_size=2")
    if hosts.get("count") != 1:
        raise RuntimeError(
            "Lightwell requires a dedicated inventory containing exactly one prepared demo host"
        )
    if hosts["results"][0]["name"] in {"localhost", "127.0.0.1", "satellite.demo.lab", "crc"}:
        raise RuntimeError("Use a dedicated application host, not Satellite, CRC or the controller")
    for record in (inventory, machine, itsm, git):
        if record.get("organization") != organization["id"]:
            raise RuntimeError("Lightwell resources must belong to the AAP Default organization")
    itsm_type = api.request(f"/credential_types/{itsm['credential_type']}/")
    git_type = api.request(f"/credential_types/{git['credential_type']}/")
    itsm_injectors = itsm_type.get("injectors", {})
    if not (
        itsm_injectors.get("env", {}).get("SN_PASSWORD")
        or itsm_injectors.get("extra_vars", {}).get("openflake_password")
    ):
        raise RuntimeError("ITSM credential must inject SN_PASSWORD or openflake_password")
    if not git_type.get("injectors", {}).get("extra_vars", {}).get("gitea_token_override"):
        raise RuntimeError(
            "Gitea credential must inject the secret extra variable gitea_token_override"
        )
    for variable in (
        "aap_credential_id",
        "aap_integration_id",
        "agent_credential_id",
        "agent_integration_id",
        "agent_model_id",
    ):
        if not bindings.get(variable):
            raise RuntimeError(f"Required AO binding is missing: {variable}")

    existing_workflows = importer.items(ao.request("/workflows?limit=100"))
    if len(existing_workflows) >= 100:
        raise RuntimeError(
            "AO workflow list may be truncated; narrow the workflow selection before importing"
        )
    for workflow in existing_workflows:
        if workflow.get("name") == WORKFLOW:
            if workflow.get("labels", {}).get("lightwell-managed") != "true":
                raise RuntimeError(
                    "An unmanaged CI/CD workflow already exists; refusing to adopt it"
                )
    project = api.find("projects", PROJECT)
    if project:
        owned(project)
    existing = {name: api.find("job_templates", name) for name in TEMPLATES}
    for template in existing.values():
        if template:
            owned(template)
    with tempfile.TemporaryDirectory(prefix="aap-demo-lightwell-") as directory:
        source = Path(directory) / "cicd-pipeline.json"
        importer.download_archive(
            f"https://raw.githubusercontent.com/ansible-tmm/aap-orchestrator-demos/{REF}"
            "/cicd-pipeline/ao/cicd-pipeline.json",
            source,
        )
        document = json.loads(source.read_text())
        validate_workflow(document)
        constrain_webhook(document)
        source.write_text(json.dumps(document))
        project_payload = {
            "name": PROJECT,
            "description": MARKER,
            "organization": organization["id"],
            "scm_type": "git",
            "scm_url": importer.UPSTREAM_REPOSITORY + ".git",
            "scm_branch": REF,
            "scm_update_on_launch": True,
        }
        if project:
            api.request(f"/projects/{project['id']}/", "PATCH", project_payload)
        else:
            project = api.request("/projects/", "POST", project_payload)
        api.wait_for_project_sync(project["id"])
        for name, playbook in TEMPLATES.items():
            payload = {
                "name": name,
                "description": MARKER,
                "project": project["id"],
                "inventory": inventory["id"],
                "playbook": "cicd-pipeline/" + playbook,
                "job_type": "run",
                "ask_variables_on_launch": True,
                "ask_inventory_on_launch": False,
                "extra_vars": json.dumps(
                    {
                        "openflake_instance_url": config["openflake"],
                        "gitea_url_override": config["gitea"],
                        "gitea_owner_override": config.get("gitea_owner", "gitea-admin"),
                    }
                ),
            }
            if existing[name]:
                template_id = existing[name]["id"]
                api.request(f"/job_templates/{template_id}/", "PATCH", payload)
            else:
                template_id = api.request("/job_templates/", "POST", payload)["id"]
            credentials = [itsm]
            if name not in LOCAL_TEMPLATES:
                credentials.append(machine)
                if ssh:
                    credentials.append(ssh)
            if name == "CI/CD Demo - Simulate Lightwell PR":
                credentials.append(git)
            endpoint = f"/job_templates/{template_id}/credentials/"
            associated = api.request(endpoint).get("results", [])
            desired_ids = {credential["id"] for credential in credentials}
            current_ids = {credential["id"] for credential in associated}
            for credential_id in current_ids - desired_ids:
                api.request(endpoint, "POST", {"id": credential_id, "disassociate": True})
            for credential in credentials:
                if credential["id"] not in current_ids:
                    api.request(endpoint, "POST", {"id": credential["id"]})

        def import_request(base: str, token: str, method: str, path: str, body: Any = None) -> Any:
            if body is not None and path.startswith("/workflows") and method in {"POST", "PATCH"}:
                body = {
                    **body,
                    "labels": {
                        **body.get("labels", {}),
                        "lightwell-managed": "true",
                        "upstream_ref": REF,
                    },
                }
            return ao.request(path, method, body)

        importer.request = import_request
        args = SimpleNamespace(
            route="",
            token="",
            project_id=None,
            source_dir=directory,
            repository=importer.UPSTREAM_REPOSITORY,
            ref=REF,
            mcp_credential_id=None,
            mcp_integration_id=None,
            webhook_service_account_name="aap-demo Lightwell CI",
            **bindings,
        )
        importer.import_workflows(args)
    print(
        "Configured pinned CI/CD templates and approval-gated AO workflow; "
        "no deployment jobs launched"
    )


def activate_workflow(ao: Any, caller_id: str) -> None:
    records = ao.request("/workflows?limit=100")["resources"]
    if len(records) >= 100:
        raise RuntimeError("AO workflow list may be truncated; refusing activation")
    matches = [
        item
        for item in records
        if item.get("name") == WORKFLOW
        and item.get("labels", {}).get("lightwell-managed") == "true"
        and item.get("labels", {}).get("upstream_ref") == REF
    ]
    if len(matches) != 1:
        raise RuntimeError("Exactly one owned pinned Lightwell workflow is required")
    path = "/workflows/" + matches[0]["id"]
    record = ao.request(path)
    document = record["version"]["workflow_definition"]
    validate_workflow(document)
    triggers = [item for item in document["triggers"] if item["type"] == "webhook_trigger"]
    if len(triggers) != 1 or (
        triggers[0]["parameters"].get("authorized_service_account_ids") != [caller_id]
        or triggers[0]["parameters"].get("input_schema", {}).get("additionalProperties")
        is not False
    ):
        raise RuntimeError(
            "Refusing to activate an unconstrained or incorrectly authorized webhook"
        )
    if record.get("has_validation_issues"):
        raise RuntimeError("AO reports workflow validation issues; activation refused")
    version = record["version"]["version"]
    if not record.get("is_enabled") or record.get("published_version_number") != version:
        ao.request(
            f"{path}/versions/{version}/publish",
            "POST",
            {
                "expected_version": version,
                "change_description": "Activate reviewed local Lightwell CI",
            },
        )
        record = ao.request(path)
    if not record.get("is_enabled") or record.get("published_version_number") != version:
        raise RuntimeError("AO did not activate the reviewed Lightwell workflow version")
    print("Activated the reviewed approval-gated AO webhook; no workflow run launched")


def remove(api: Any, ao: Any, importer: Any) -> None:
    project = api.find("projects", PROJECT)
    if project:
        owned(project)
        templates = api.request(f"/job_templates/?project={project['id']}&page_size=100")
        if templates.get("count", 0) > 100:
            raise RuntimeError(
                "Project template list may be truncated; refusing incomplete cleanup"
            )
        for template in templates.get("results", []):
            owned(template)
            if template.get("name") not in TEMPLATES:
                raise RuntimeError("Unexpected template references the project; refusing deletion")
    workflows = importer.items(ao.request("/workflows?limit=100"))
    if len(workflows) >= 100:
        raise RuntimeError("AO workflow list may be truncated; refusing incomplete cleanup")
    for workflow in workflows:
        if workflow.get("labels", {}).get("lightwell-managed") == "true":
            ao.request(f"/workflows/{workflow['id']}", "DELETE")
    for name in TEMPLATES:
        template = api.find("job_templates", name)
        if template and project and template.get("project") == project["id"]:
            owned(template)
            api.request(f"/job_templates/{template['id']}/", "DELETE")
    if project:
        api.request(f"/projects/{project['id']}/", "DELETE")
    print(
        "Removed managed CI/CD workflow and templates; "
        "hosts, service data and credentials preserved"
    )


def clients(access: dict):
    helper = load_helper("lightwell_aap", "provision-aap-demos.py")

    class LabAPI(helper.AAP):
        TRANSIENT_HTTP_STATUSES = {"502", "503", "504"}
        TRANSIENT_READ_ATTEMPTS = 6
        TRANSIENT_RETRY_SECONDS = 5

        def find(self, endpoint: str, name: str) -> dict[str, Any] | None:
            response = self.request(f"/{endpoint}/?name={urllib.parse.quote(name)}&page_size=2")
            records = response.get("results", [])
            if response.get("count", len(records)) > 1:
                raise RuntimeError(f"Ambiguous {endpoint} selection: {name}")
            return next(iter(records), None)

        def request(self, path: str, method: str = "GET", payload: Any = None) -> Any:
            attempts = self.TRANSIENT_READ_ATTEMPTS if method == "GET" else 1
            for attempt in range(1, attempts + 1):
                try:
                    return super().request(path, method, payload)
                except RuntimeError as error:
                    status = str(error).partition(" returned HTTP ")[2].partition(":")[0]
                    if (
                        method == "GET"
                        and status in self.TRANSIENT_HTTP_STATUSES
                        and attempt < attempts
                    ):
                        print(
                            f"  ⚠ API returned HTTP {status} for {path.partition('?')[0]}; "
                            f"retrying in {self.TRANSIENT_RETRY_SECONDS}s "
                            f"({attempt}/{attempts - 1})"
                        )
                        time.sleep(self.TRANSIENT_RETRY_SECONDS)
                        continue
                    if status.isdigit():
                        raise RuntimeError(
                            f"{method} {path.partition('?')[0]} returned HTTP {status}"
                        ) from None
                    raise
            raise RuntimeError("unreachable")

    api = LabAPI(os.environ["LIGHTWELL_AAP_ROUTE"], access["aap_token"])
    ao = LabAPI(os.environ["LIGHTWELL_AO_ROUTE"], access["ao_token"])
    api.context = ao.context = ssl.create_default_context()
    ao.base = f"https://{os.environ['LIGHTWELL_AO_ROUTE']}/api/v1"
    return api, ao


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--delete", action="store_true")
    args = parser.parse_args()
    config = {} if args.delete else configuration()
    if args.preflight:
        print(
            "Lightwell service configuration is valid; "
            "live service and credential checks remain required"
        )
        return 0
    with os.fdopen(3, closefd=False) as stream:
        access = json.load(stream)
    api, ao = clients(access)
    importer = load_helper("lightwell_ao", "import-demos.py")
    if args.delete:
        remove(api, ao, importer)
    else:
        if args.prepare:
            prepare = load_helper("lightwell_prepare", "../../lightwell/prepare.py")
            prepare.prepare_aap(api)
            config = configuration()
        provision(api, ao, importer, access["bindings"], config)
        if args.prepare:
            activate_workflow(ao, prepare.configure_ci(ao))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, RuntimeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1) from None
    except (OSError, urllib.error.URLError) as error:
        print(
            f"ERROR: Lightwell service connection or local file failed ({type(error).__name__})",
            file=sys.stderr,
        )
        raise SystemExit(1) from None
