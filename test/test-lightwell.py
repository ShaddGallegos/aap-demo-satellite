#!/usr/bin/env python3
"""Isolated Lightwell configuration and workflow safety regressions."""

from __future__ import annotations

import base64
import copy
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("lightwell", ROOT / "addons/lightwell/provision.py")
assert SPEC and SPEC.loader
lightwell = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lightwell)


def workflow() -> dict:
    jobs = [
        ("drain", "CI/CD Demo - Drain Load Balancer"),
        ("production", "CI/CD Demo - Deploy to Prod"),
        ("rollback", "CI/CD Demo - Rollback to Snapshot"),
    ]
    return {
        "name": lightwell.WORKFLOW,
        "triggers": [
            {
                "id": "ci",
                "type": "webhook_trigger",
                "parameters": {"webhook_path": "lightwell-ci-cd"},
            }
        ],
        "nodes": [
            {"id": "approve", "type": "approval", "parameters": {"fallback_decision": "reject"}},
            {"id": "note", "type": "agentic", "parameters": {"tool_selection_strategy": "NONE"}},
            *[
                {
                    "id": name,
                    "type": "aap_job_template",
                    "parameters": {"job_template_name": template},
                }
                for name, template in jobs
            ],
        ],
        "edges": [
            {"from": "ci", "to": "approve"},
            {"from": "approve", "to": "drain", "from_port": "approved"},
            {"from": "drain", "to": "production"},
            {"from": "production", "to": "rollback"},
        ],
    }


class API:
    def __init__(self) -> None:
        self.records = {
            ("organizations", "Default"): {"id": 1},
            ("inventories", "Lightwell CI/CD"): {"id": 2, "organization": 1},
            ("credentials", "Fleet SSH Key"): {"id": 3, "organization": 1},
            ("credentials", "Lightwell OpenFlake"): {
                "id": 4,
                "organization": 1,
                "credential_type": 10,
            },
            ("credentials", "Lightwell Gitea"): {"id": 5, "organization": 1, "credential_type": 11},
        }
        self.workflows: list[dict] = []
        self.accounts: list[dict] = []
        self.writes: list[tuple] = []
        self.host_count = 1
        self.host_name = "dedicated-app"

    def find(self, resource: str, name: str) -> dict | None:
        return self.records.get((resource, name))

    def wait_for_project_sync(self, project_id: int) -> None:
        pass

    def request(self, path: str, method: str = "GET", payload: dict | None = None) -> dict:
        if method != "GET":
            self.writes.append((path, method, payload))
        if path.startswith("/inventories/"):
            return {"count": self.host_count, "results": [{"name": self.host_name}]}
        if path.startswith("/job_templates/?project="):
            records = [
                {**record, "name": name}
                for (kind, name), record in self.records.items()
                if kind == "job_templates"
            ]
            return {"count": len(records), "results": records}
        if path == "/credential_types/10/":
            return {"injectors": {"env": {"SN_PASSWORD": "{{ password }}"}}}
        if path == "/credential_types/11/":
            return {"injectors": {"extra_vars": {"gitea_token_override": "{{ token }}"}}}
        if path == "/projects?limit=100":
            return {"resources": [{"id": "default-project", "is_default": True}]}
        if path.startswith("/service_accounts"):
            if method == "POST":
                self.accounts.append({**(payload or {}), "id": "caller"})
                return self.accounts[-1]
            return {"resources": self.accounts}
        if path == "/workflows?limit=100":
            return {"resources": self.workflows}
        if path == "/workflows" and method == "POST":
            self.workflows.append({**(payload or {}), "id": "pipeline"})
            return self.workflows[-1]
        if path == "/workflows/pipeline" and method == "PATCH":
            self.workflows[0].update(payload or {})
            return self.workflows[0]
        if (
            path.startswith("/job_templates/")
            and path.endswith("/credentials/")
            and method == "GET"
        ):
            return {"results": []}
        if method == "POST" and path in {"/projects/", "/job_templates/"}:
            record = {**(payload or {}), "id": len(self.records) + 10}
            self.records[(path.strip("/"), record["name"])] = record
            return record
        if method in {"PATCH", "POST", "DELETE"}:
            return {}
        raise AssertionError((path, method))


class LightwellTests(unittest.TestCase):
    def setUp(self) -> None:
        self.api = API()
        self.ao = API()
        self.importer = lightwell.load_helper("test_lightwell_import", "import-demos.py")
        self.config = {
            "gitea": "https://git.example.test",
            "openflake": "https://itsm.example.test",
            "inventory": "Lightwell CI/CD",
            "machine_credential": "Fleet SSH Key",
            "itsm_credential": "Lightwell OpenFlake",
            "git_credential": "Lightwell Gitea",
        }
        self.bindings = {
            name: name
            for name in (
                "aap_credential_id",
                "aap_integration_id",
                "agent_credential_id",
                "agent_integration_id",
                "agent_model_id",
            )
        }

    def provision(self) -> None:
        def download(url: str, target: Path) -> None:
            self.assertIn(lightwell.REF, url)
            target.write_text(json.dumps(workflow()))

        with patch.object(self.importer, "download_archive", side_effect=download):
            lightwell.provision(self.api, self.ao, self.importer, self.bindings, self.config)

    def test_repeated_configuration_preserves_approval_and_disables_agent_tools(self) -> None:
        self.provision()
        self.provision()
        self.assertEqual(len(self.ao.workflows), 1)
        document = self.ao.workflows[0]["workflow_definition"]
        approval = next(node for node in document["nodes"] if node["type"] == "approval")
        self.assertEqual(approval["parameters"]["fallback_decision"], "reject")
        agent = next(node for node in document["nodes"] if node["type"] == "agentic")
        self.assertEqual(agent["parameters"]["tool_selection_strategy"], "NONE")
        self.assertNotIn("integration_connections", agent["parameters"])
        self.assertEqual(agent["parameters"]["llm_model_id"], "agent_model_id")
        trigger = document["triggers"][0]["parameters"]
        self.assertEqual(trigger["authorized_service_account_ids"], ["caller"])
        self.assertFalse(trigger["input_schema"]["additionalProperties"])
        self.assertEqual(self.ao.workflows[0]["labels"]["upstream_ref"], lightwell.REF)
        self.assertEqual(
            len([key for key in self.api.records if key[0] == "job_templates"]),
            len(lightwell.TEMPLATES),
        )
        self.assertFalse(any("/launch/" in path for path, _, _ in self.api.writes))

    def test_missing_prerequisites_fail_before_any_writes(self) -> None:
        for missing in ("inventory", "machine_credential", "itsm_credential", "git_credential"):
            with self.subTest(missing=missing):
                config = {**self.config, missing: "missing"}
                with self.assertRaisesRegex(RuntimeError, "missing"):
                    lightwell.provision(self.api, self.ao, self.importer, self.bindings, config)
                self.assertEqual(self.api.writes, [])
                self.assertEqual(self.ao.writes, [])

    def test_native_activation_publishes_only_the_reviewed_safe_version(self) -> None:
        document = workflow()
        document["triggers"][0]["parameters"].update(
            authorized_service_account_ids=["caller"],
            input_schema={"additionalProperties": False},
        )
        summary = {
            "id": "owned",
            "name": lightwell.WORKFLOW,
            "labels": {"lightwell-managed": "true", "upstream_ref": lightwell.REF},
        }
        draft = {"version": {"version": 3, "workflow_definition": document}, "is_enabled": False}
        ao = Mock()
        ao.request.side_effect = [
            {"resources": [summary]},
            draft,
            {},
            {**draft, "is_enabled": True, "published_version_number": 3},
        ]
        lightwell.activate_workflow(ao, "caller")
        publication = ao.request.call_args_list[2]
        self.assertEqual(publication.args[:2], ("/workflows/owned/versions/3/publish", "POST"))
        self.assertEqual(publication.args[2]["expected_version"], 3)
        document["triggers"][0]["parameters"]["authorized_service_account_ids"] = ["other"]
        ao.reset_mock()
        ao.request.side_effect = [{"resources": [summary]}, draft]
        with self.assertRaisesRegex(RuntimeError, "incorrectly authorized"):
            lightwell.activate_workflow(ao, "caller")
        self.assertEqual(ao.request.call_count, 2)

    def test_shared_or_core_inventory_is_rejected(self) -> None:
        for count, name in ((3, "fleet"), (1, "satellite.demo.lab"), (1, "localhost")):
            with self.subTest(count=count, name=name):
                self.api.host_count, self.api.host_name = count, name
                with self.assertRaises(RuntimeError):
                    self.provision()
                self.assertEqual(self.api.writes, [])

    def test_unmanaged_template_is_not_overwritten(self) -> None:
        self.api.records[("job_templates", next(iter(lightwell.TEMPLATES)))] = {
            "id": 99,
            "name": "existing-user-template",
            "description": "user-owned",
        }
        with self.assertRaisesRegex(RuntimeError, "unmanaged"):
            self.provision()
        self.assertEqual(self.api.writes, [])

    def test_approval_bypass_and_agent_tools_are_rejected(self) -> None:
        for kind in ("missing", "bypass", "rejection-edge", "tools"):
            document = copy.deepcopy(workflow())
            if kind == "missing":
                document["nodes"] = [
                    node for node in document["nodes"] if node["type"] != "approval"
                ]
            elif kind == "bypass":
                document["edges"].append({"from": "ci", "to": "production"})
            elif kind == "rejection-edge":
                document["edges"][1]["from_port"] = "rejected"
            else:
                document["nodes"][1]["parameters"]["tool_selection_strategy"] = "ALL"
            with self.subTest(kind=kind), self.assertRaises(RuntimeError):
                lightwell.validate_workflow(document)

    def test_service_url_rejects_embedded_credentials_and_unsafe_schemes(self) -> None:
        for value in (
            "",
            "http://git.example.test",
            "https://user:secret@git.test",
            "javascript:alert(1)",
        ):
            with self.subTest(value=value), patch.dict(os.environ, {"TEST_SERVICE_URL": value}):
                with self.assertRaises(ValueError) as error:
                    lightwell.service_url("TEST_SERVICE_URL")
                self.assertNotIn("secret", str(error.exception))

    def test_cleanup_removes_only_owned_workflow_templates_and_project(self) -> None:
        self.api.records[("projects", lightwell.PROJECT)] = {
            "id": 55,
            "description": lightwell.MARKER,
        }
        name = next(iter(lightwell.TEMPLATES))
        self.api.records[("job_templates", name)] = {
            "id": 56,
            "project": 55,
            "description": lightwell.MARKER,
        }
        self.ao.workflows = [
            {"id": "owned", "labels": {"lightwell-managed": "true"}},
            {"id": "user", "labels": {}},
        ]
        lightwell.remove(self.api, self.ao, self.importer)
        self.assertEqual(self.ao.writes, [("/workflows/owned", "DELETE", None)])
        self.assertEqual(
            self.api.writes,
            [
                ("/job_templates/56/", "DELETE", None),
                ("/projects/55/", "DELETE", None),
            ],
        )

    def test_changed_workflow_name_is_rejected(self) -> None:
        document = workflow()
        document["name"] = "Unmanaged workflow"
        with self.assertRaisesRegex(RuntimeError, "Unexpected upstream workflow name"):
            lightwell.validate_workflow(document)

    def test_cleanup_refuses_unmanaged_project_references_before_mutation(self) -> None:
        self.api.records[("projects", lightwell.PROJECT)] = {
            "id": 55,
            "description": lightwell.MARKER,
        }
        self.api.records[("job_templates", "Unmanaged user template")] = {
            "id": 56,
            "project": 55,
            "description": "User-owned",
        }
        with self.assertRaisesRegex(RuntimeError, "unmanaged"):
            lightwell.remove(self.api, self.ao, self.importer)
        self.assertEqual(self.api.writes, [])
        self.assertEqual(self.ao.writes, [])


class PreparationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = lightwell.load_helper("test_lightwell_prepare", "../../lightwell/prepare.py")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = patch.dict(
            os.environ,
            {
                "AAP_DEMO_LIGHTWELL_DIR": str(self.root),
                "AAP_DEMO_DIR": str(self.root),
                "LIGHTWELL_AO_ROUTE": "ao.example.test",
                "LIGHTWELL_APP_NODE": "4",
            },
        )
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.config = {
            "owner": self.module.MARKER,
            "gitea": "https://git.example.test",
            "gitea_uuid": "owned-vm",
            "openflake": "https://changes.example.test",
        }
        self.module.save(self.config)
        node = self.root / "fleet/node-4"
        node.mkdir(parents=True)
        (node / "meta").write_text("INDEX=4\nMEMORY_MB=4096\n")

    def test_underprovisioned_app_host_fails_before_aap_writes(self) -> None:
        (self.root / "fleet/node-4/meta").write_text("INDEX=4\nMEMORY_MB=1024\n")
        api = Mock()
        with self.assertRaisesRegex(RuntimeError, "at least 4 GiB"):
            self.module.prepare_aap(api)
        api.find.assert_not_called()
        api.request.assert_not_called()

    def test_preparing_aap_preserves_app_name_and_strict_ssh_credential(self) -> None:
        api = Mock()
        api.find.side_effect = lambda kind, name: {"id": 9 if name == "Fleet" else 1}
        api.request.side_effect = [
            {
                "count": 1,
                "results": [
                    {
                        "variables": json.dumps(
                            {"ansible_host": "192.0.2.1", "ansible_port": 2204}
                        ),
                    }
                ],
            },
            {"results": []},
            {},
        ]
        with (
            patch.object(self.module, "prepare_platform_ca"),
            patch.object(self.module, "managed", return_value={"id": 5}) as managed,
            patch.object(self.module, "credential", return_value="synthetic"),
            patch.object(self.module.gitea, "vault", return_value="synthetic"),
            patch.object(
                self.module.gitea,
                "run",
                return_value="[127.0.0.1]:2204 ssh-ed25519 synthetic-public-key",
            ),
        ):
            self.module.prepare_aap(api)
        saved = json.loads((self.root / "config.json").read_text())
        self.assertEqual(saved["app_host"], "aap-fleet-node-4")
        variables = json.loads(api.request.call_args.args[2]["variables"])
        self.assertIn("StrictHostKeyChecking=yes", variables["ansible_ssh_common_args"])
        trust = next(
            call.args[-1]
            for call in managed.call_args_list
            if call.args[1:3] == ("credentials", "Lightwell SSH Host Trust")
        )
        self.assertIn("[192.0.2.1]:2204 ssh-ed25519", trust["inputs"]["known_hosts"])

    def test_platform_ca_refuses_other_owners_before_writing(self) -> None:
        for bundle, secret in (
            ("another-bundle", ""),
            (None, json.dumps({"metadata": {"labels": {}}})),
        ):
            platform = {
                "items": [{"metadata": {"name": "aap"}, "spec": {"bundle_cacert_secret": bundle}}]
            }
            with (
                self.subTest(bundle=bundle),
                patch.object(
                    self.module.gitea, "run", side_effect=[json.dumps(platform), secret]
                ) as run,
            ):
                with self.assertRaisesRegex(RuntimeError, "owner|unowned"):
                    self.module.prepare_platform_ca()
                self.assertFalse(
                    any("apply" in call.args or "patch" in call.args for call in run.call_args_list)
                )

    def test_runner_uses_native_post_and_owned_bridge_not_crc_loopback(self) -> None:
        (self.root / "state.json").write_text(
            json.dumps(
                {
                    "uuid": "owned-vm",
                    "ip": "192.168.122.4",
                }
            )
        )
        (self.root / "crc-ingress-ca.crt").write_text("public test CA")
        with (
            patch.object(self.module.gitea, "data_root", return_value=self.root),
            patch.object(self.module.gitea, "check_domain"),
            patch.object(
                self.module.gitea,
                "virsh",
                return_value='<network><ip address="192.168.122.1"/></network>',
            ),
            patch.object(self.module.gitea, "Guest") as guest,
            patch.object(self.module.gitea, "run") as run,
            patch.object(self.module, "git_api", return_value={"token": "synthetic"}) as git,
        ):
            self.module.runner("transient-key")
        self.assertEqual(git.call_args.kwargs["method"], "POST")
        self.assertEqual(run.call_args.args[-2:], ("192.168.122.4", "192.168.122.1"))
        self.assertIn('"crc_ip": "192.168.122.1"', guest.return_value.ssh.call_args.args[1])

    def test_owned_nonempty_repository_is_never_reseeded(self) -> None:
        with patch.object(
            self.module,
            "git_api",
            return_value=[
                {
                    "full_name": "aap-demo/inventory-service",
                    "description": self.module.MARKER,
                    "empty": False,
                }
            ],
        ) as git:
            self.module.prepare_repository(self.config)
        self.assertEqual(git.call_count, 1)

    def test_existing_ci_identity_is_reused_with_native_secret_payloads(self) -> None:
        self.config["ao_account_id"] = "dedicated-caller"
        self.config["ao_credential_id"] = "retained-credential"
        self.module.save(self.config)
        ao = Mock()
        ao.request.side_effect = [
            {
                "resources": [
                    {"id": "dedicated-caller", "name": "aap-demo Lightwell CI"},
                ]
            },
            {"status": "active", "expires_at": None},
        ]
        writes = []

        def git(config, path, payload=None, method="GET"):
            if method == "PUT":
                writes.append((path, payload))
                return {}
            name = path.split("/contents/")[1].partition("?")[0]
            return {
                "content": base64.b64encode(
                    (self.module.HERE / "seed" / name).read_bytes()
                ).decode()
            }

        with (
            patch.object(self.module.gitea, "vault", return_value="retained"),
            patch.object(self.module, "git_api", side_effect=git),
        ):
            self.module.configure_ci(ao)
        self.assertEqual(ao.request.call_count, 2)
        self.assertEqual(len(writes), 3)
        self.assertTrue(all(set(payload) == {"data"} for _, payload in writes))

    def test_expired_ci_credential_is_not_silently_reissued(self) -> None:
        self.module.save({**self.config, "ao_account_id": "caller", "ao_credential_id": "expired"})
        ao = Mock()
        ao.request.side_effect = [
            {"resources": [{"id": "caller", "name": "aap-demo Lightwell CI"}]},
            {"status": "active", "expires_at": "2000-01-01T00:00:00Z"},
        ]
        with (
            patch.object(self.module.gitea, "vault", return_value="retained"),
            patch.object(self.module, "git_api") as git,
            self.assertRaisesRegex(RuntimeError, "expired"),
        ):
            self.module.configure_ci(ao)
        git.assert_not_called()
        self.assertTrue(all(len(call.args) == 1 for call in ao.request.call_args_list))

    def test_full_demo_reuses_only_marked_host_or_reconstructs_one(self) -> None:
        source = (ROOT / "aap-demo.sh").read_text()
        function = source.split("_full_demo_lightwell_enable() {", 1)[1].split("\n}\n", 1)[0]
        script = (
            "_full_demo_lightwell_enable() {"
            + function
            + "\n}\n"
            + """
_err() { echo "$*" >&2; }
cmd_enable() { printf 'enable %s app=%s\\n' "$*" "${LIGHTWELL_APP_NODE:-unset}"; }
cmd_fleet() {
  echo "fleet $*"
  if [ "$1" = add ]; then
    test "$FLEET_NODE_MEM" = 4096
    FLEET_CREATED_INDICES=(5)
    mkdir -p "$AAP_DEMO_DIR/fleet/node-5"
  fi
}
_full_demo_lightwell_enable
"""
        )
        for state in ("owned", "unowned", "absent"):
            self.module.save({**self.config, "app_index": 4})
            node = self.root / "fleet/node-4"
            node.mkdir(exist_ok=True)
            marker = node / "lightwell-owner"
            marker.unlink(missing_ok=True)
            if state == "owned":
                marker.write_text(self.module.MARKER)
            elif state == "absent":
                shutil.rmtree(node)
            result = subprocess.run(
                ["bash", "-euc", script],
                env=os.environ,
                capture_output=True,
                text=True,
                timeout=15,
            )
            with self.subTest(state=state):
                if state == "unowned":
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn("enable lightwell", result.stdout)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    index = 5 if state == "absent" else 4
                    self.assertIn(f"enable lightwell --prepare app={index}", result.stdout)
                    self.assertEqual(
                        json.loads((self.root / "config.json").read_text())["app_index"], index
                    )

        # A first-run profile has no retained service configuration yet. It
        # must still reserve exactly one marked application host and defer
        # writing configuration until prepare-services has established it.
        (self.root / "config.json").unlink(missing_ok=True)
        shutil.rmtree(self.root / "fleet", ignore_errors=True)
        result = subprocess.run(
            ["bash", "-euc", script],
            env=os.environ,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("enable lightwell --prepare app=5", result.stdout)
        self.assertEqual(
            (self.root / "fleet/node-5/lightwell-owner").read_text().strip(), self.module.MARKER
        )
        self.assertFalse((self.root / "config.json").exists())


@unittest.skipIf(os.name == "nt", "Bash-only addon lifecycle")
class DeployLifecycleTests(unittest.TestCase):
    def test_temporary_token_is_revoked_on_success_and_provision_failure(self) -> None:
        for provision_status, revoke_status in ((0, 0), (1, 0), (0, 1)):
            with self.subTest(provision=provision_status, revoke=revoke_status):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    addon = root / "addons/lightwell"
                    includes = root / "includes"
                    bin_dir = root / "bin"
                    for folder in (addon, includes, bin_dir):
                        folder.mkdir(parents=True)
                    shutil.copy(ROOT / "addons/lightwell/deploy.sh", addon)
                    shutil.copy(ROOT / "includes/secure-curl.sh", includes)
                    (includes / "addon-wire.sh").write_text("""
wire_aap_route_host() { echo aap.example.test; }
wire_ao_route_host() { echo ao.example.test; }
wire_aap_admin_password() { printf synthetic-password; }
wire_ao_admin_password() { printf synthetic-password; }
WIRE_AAP_CREDENTIAL_NAME=AAP
WIRE_AAP_INTEGRATION_NAME=AAP
wire_ao_find_credential_by_name() { wire_ao_api GET /credentials >/dev/null; echo aap-credential; }
wire_ao_find_integration_by_name() { echo aap-integration; }
wire_ao_llm_agent_credential_id() { echo agent-credential; }
wire_ao_llm_agent_integration_id() { echo agent-integration; }
wire_ao_llm_agent_model_id() { echo agent-model; }
""")
                    (bin_dir / "python3").write_text("""#!/usr/bin/env bash
set -euo pipefail
if [ "${2:-}" = --preflight ]; then exit 0; fi
jq -e '.aap_token == "synthetic-token" and .bindings.agent_model_id == "agent-model"' <&3 >/dev/null
exit "$MOCK_PROVISION_STATUS"
""")
                    (bin_dir / "curl").write_text("""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"$MOCK_REQUESTS"
if [[ "$*" == *"-X DELETE"* ]]; then
  echo revoked >>"$MOCK_REQUESTS"
  exit "$MOCK_REVOKE_STATUS"
elif [[ "$*" == *"/api/gateway/v1/tokens/"* ]]; then
  printf '{"id":7,"token":"synthetic-token"}'
elif [[ "$*" == *"/auth/login"* ]]; then
  printf '{"access_token":"synthetic-ao-token"}'
else
  printf '{}'
fi
""")
                    for executable in bin_dir.iterdir():
                        executable.chmod(0o700)
                    requests = root / "requests"
                    result = subprocess.run(
                        ["bash", str(addon / "deploy.sh")],
                        env={
                            **os.environ,
                            "PATH": f"{bin_dir}:{os.environ['PATH']}",
                            "AAP_DEMO_DIR": str(root / "state"),
                            "LIGHTWELL_GITEA_URL": "https://git.example.test",
                            "LIGHTWELL_OPENFLAKE_URL": "https://changes.example.test",
                            "MOCK_PROVISION_STATUS": str(provision_status),
                            "MOCK_REVOKE_STATUS": str(revoke_status),
                            "MOCK_REQUESTS": str(requests),
                        },
                        capture_output=True,
                        text=True,
                        timeout=15,
                    )
                    self.assertEqual(
                        result.returncode == 0, not (provision_status or revoke_status)
                    )
                    calls = requests.read_text()
                    self.assertIn("revoked", calls)
                    for secret in ("synthetic-password", "synthetic-token", "synthetic-ao-token"):
                        self.assertNotIn(secret, calls + result.stdout + result.stderr)
                    if revoke_status:
                        self.assertIn("Could not revoke temporary AAP setup token", result.stderr)
                    self.assertEqual(
                        (root / "state/lightwell/services.json").exists(),
                        provision_status == 0,
                    )


if __name__ == "__main__":
    unittest.main()
