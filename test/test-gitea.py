#!/usr/bin/env python3
"""Focused tests for the standalone Fedora/NFS Git service."""

import concurrent.futures
import hashlib
import importlib.util
import io
import json
import os
import shutil
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("gitea_vm", ROOT / "addons/gitea/manage.py")
assert SPEC and SPEC.loader
gitea = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gitea)


def fixture_state():
    return {
        "domain": gitea.DOMAIN,
        "uuid": "b32017f4-e20f-4bad-b7db-89b44ae4c8ee",
        "mac": "52:54:00:e4:c8:ee",
        "provisioned": True,
    }


def fixture_xml(state):
    return f"""<domain><uuid>{state["uuid"]}</uuid>
<description>aap-demo:gitea:{state["uuid"]}</description><devices>
<disk device="disk"><source file="{gitea.DISKS / (state["uuid"] + ".qcow2")}"/></disk>
<interface><mac address="{state["mac"]}"/><source network="default"/></interface>
</devices></domain>"""


class GiteaTests(unittest.TestCase):
    def test_overlapping_stop_and_timer_backups_are_consistent_and_atomic(self):
        source = (ROOT / "addons/gitea/configure.sh").read_text()
        code = source.split("cat >/usr/local/bin/gitea-db-backup <<'PY'\n", 1)[1].split("\nPY", 1)[
            0
        ]
        with tempfile.TemporaryDirectory() as directory:
            local = Path(directory) / "local"
            backups = Path(directory) / "backups"
            (local / "data").mkdir(parents=True)
            backups.mkdir()
            with sqlite3.connect(local / "data/gitea.db") as database:
                database.execute("CREATE TABLE example (value TEXT)")
                database.execute("INSERT INTO example VALUES ('retained')")
            code = compile(
                code.replace("/var/lib/gitea", str(local)).replace(
                    "/srv/gitea/backups", str(backups)
                ),
                "gitea-db-backup",
                "exec",
            )
            barrier = threading.Barrier(2)
            copyfile = shutil.copyfile

            def overlapping_copy(source, destination):
                result = copyfile(source, destination)
                barrier.wait(timeout=10)
                return result

            with (
                patch.object(shutil, "copyfile", side_effect=overlapping_copy),
                concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor,
            ):
                futures = [executor.submit(exec, code, {}) for _ in range(2)]
                for future in futures:
                    future.result(timeout=15)
            with sqlite3.connect(backups / "gitea.db") as database:
                self.assertEqual(database.execute("PRAGMA integrity_check").fetchone(), ("ok",))
                self.assertEqual(
                    database.execute("SELECT value FROM example").fetchone(), ("retained",)
                )
            self.assertEqual([path.name for path in backups.iterdir()], ["gitea.db"])

    def test_local_api_bypasses_proxies_without_disabling_tls_validation(self):
        context = ssl.create_default_context()
        with (
            patch.object(gitea.ssl, "create_default_context", return_value=context),
            patch.object(gitea.urllib.request, "build_opener") as build,
            patch.object(gitea.urllib.request, "urlopen", side_effect=AssertionError("proxy leak")),
        ):
            build.return_value.open.return_value.__enter__.return_value = io.StringIO(
                '{"login":"aap-demo"}'
            )
            result = gitea.api(
                Path("/unused"), "https://192.168.122.55:3000", "/api/v1/user", "synthetic-test"
            )
        self.assertEqual(result["login"], "aap-demo")
        request = build.return_value.open.call_args.args[0]
        self.assertIn("Authorization", request.unredirected_hdrs)
        self.assertNotIn("Authorization", request.headers)
        self.assertEqual(build.call_args.args[0].proxies, {})
        self.assertIs(build.call_args.args[1]._context, context)
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)

    def test_unsupported_purge_is_rejected_without_stopping_or_deleting_data(self):
        result = subprocess.run(
            ["bash", str(ROOT / "addons/gitea/deploy.sh"), "--delete", "--purge-data"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("data purge is deliberately not supported", result.stderr)

    def test_native_config_preserves_required_uppercase_keys_and_percent_values(self):
        source = io.StringIO(
            "RUN_USER = git\n[security]\nINSTALL_LOCK = true\n"
            "[server]\nPROTOCOL = https\n[database]\nPATH = /tmp/db%name\n"
        )

        class Output(io.StringIO):
            def close(self):
                pass

        output = Output()
        script = (ROOT / "addons/gitea/configure.sh").read_text()
        code = "import configparser" + script.split("import configparser", 1)[1].split("\nPY", 1)[0]
        with (
            patch("builtins.open", side_effect=[source, output]),
            patch.object(sys, "argv", ["_", "192.168.122.55"]),
        ):
            exec(compile(code, "configure.sh", "exec"), {})
        self.assertIn("INSTALL_LOCK = true", output.getvalue())
        self.assertIn("RUN_USER = git", output.getvalue())
        self.assertIn("PATH = /tmp/db%name", output.getvalue())
        self.assertIn("ROOT_URL = https://192.168.122.55:3000/", output.getvalue())

    def test_domain_ownership_rejects_replaced_disks_networks_and_identities(self):
        state = fixture_state()
        xml = fixture_xml(state)
        gitea.check_domain(xml, state)
        for before, after in (
            (state["uuid"], "44444444-4444-4444-4444-444444444444"),
            (state["mac"], "52:54:00:00:00:01"),
            ('network="default"', 'network="unrelated"'),
            (".qcow2", ".unowned"),
            ("aap-demo:gitea:", "unowned:"),
        ):
            with self.subTest(before=before), self.assertRaises(RuntimeError):
                gitea.check_domain(xml.replace(before, after), state)

    def test_fedora_bootstrap_has_nfs_and_no_password_or_root_ssh(self):
        state = fixture_state()
        captured = {}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def execute(*args, **kwargs):
                if args[0] == "genisoimage":
                    captured["config"] = json.loads(Path(args[-2]).read_text().split("\n", 1)[1])
                if args[0] == "virt-install":
                    captured["vm"] = args
                return ""

            with (
                patch.object(gitea, "DISKS", root / "disks"),
                patch.object(gitea, "download"),
                patch.object(gitea, "run", side_effect=execute),
            ):
                gitea.create_vm(root, state, "ssh-ed25519 fixture-public-key")
        self.assertIn("nfs-utils", captured["config"]["packages"])
        self.assertIn("git-core", captured["config"]["packages"])
        self.assertTrue(captured["config"]["disable_root"])
        self.assertFalse(captured["config"]["ssh_pwauth"])
        self.assertTrue(captured["config"]["users"][0]["lock_passwd"])
        self.assertIn("fedora-unknown", captured["vm"])
        self.assertIn(f"network=default,model=virtio,mac={state['mac']}", captured["vm"])

    def test_artifact_checksum_failure_never_replaces_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image"
            path.write_bytes(b"old retained image")

            def execute(*args, **kwargs):
                Path(args[args.index("--output") + 1]).write_bytes(b"corrupt")
                self.assertIn("--proto-redir", args)
                return ""

            with patch.object(gitea, "run", side_effect=execute):
                with self.assertRaisesRegex(RuntimeError, "Checksum mismatch"):
                    gitea.download(
                        "https://example.test/artifact",
                        path,
                        hashlib.sha256(b"expected").hexdigest(),
                        "sha256",
                    )
            self.assertEqual(path.read_bytes(), b"old retained image")
            self.assertFalse(path.with_suffix(".part").exists())

    def test_dhcp_reservation_does_not_replace_another_vm(self):
        state = fixture_state()
        xml = """<network><ip><dhcp>
<host mac="52:54:00:11:22:33" name="unrelated" ip="192.168.122.55"/>
</dhcp></ip></network>"""
        with patch.object(gitea, "virsh", return_value=xml) as virsh:
            with self.assertRaisesRegex(RuntimeError, "conflicts"):
                gitea.reserve_address(state, "192.168.122.55")
        self.assertEqual(virsh.call_count, 1)

    def test_dhcp_reuse_does_not_duplicate_reservations(self):
        state = fixture_state()
        xml = f"""<network><ip><dhcp><host mac="{state["mac"]}"
name="{state["domain"]}" ip="192.168.122.55"/></dhcp></ip></network>"""
        with patch.object(gitea, "virsh", return_value=xml) as virsh:
            gitea.reserve_address(state, "192.168.122.55")
        self.assertEqual(virsh.call_count, 1)

    def test_vault_password_only_uses_stdin_not_process_arguments(self):
        result = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with patch.object(gitea.subprocess, "run", return_value=result) as process:
            gitea.vault("set", "synthetic-password-for-test")
        args, kwargs = process.call_args
        self.assertNotIn("synthetic-password-for-test", " ".join(args[0]))
        self.assertEqual(kwargs["input"], "synthetic-password-for-test\n")

    def test_stop_retains_vm_definition_state_and_data(self):
        state = fixture_state()
        calls = []

        def virsh(*args):
            calls.append(args)
            if args[0] == "dumpxml":
                return fixture_xml(state)
            if args[0] == "domstate":
                return "shut off" if ("shutdown", gitea.DOMAIN) in calls else "running"
            return ""

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gitea.save_state(root, state)
            retained = root / "retained-repository"
            retained.write_text("must remain")
            with (
                patch.dict(os.environ, {"AAP_DEMO_GITEA_DIR": directory}),
                patch.object(sys, "argv", ["manage.py", "stop"]),
                patch.object(gitea, "preflight"),
                patch.object(gitea, "virsh", side_effect=virsh),
            ):
                gitea.main()
            self.assertTrue(retained.exists())
            self.assertEqual(json.loads((root / "state.json").read_text()), state)
        self.assertIn(("shutdown", gitea.DOMAIN), calls)
        self.assertNotIn("undefine", {command[0] for command in calls})
        self.assertNotIn("destroy", {command[0] for command in calls})
        self.assertIn(("autostart", gitea.DOMAIN, "--disable"), calls)

    def test_flags_accept_requested_spelling_without_cluster_creation(self):
        script = (ROOT / "aap-demo.sh").read_text()
        parser = script.split("# Parse command line arguments\n", 1)[1].split(
            "# Check for unprocessed pending flag", 1
        )[0]
        for alias in ("--gitea", "--gittea"):
            result = subprocess.run(
                ["bash", "-s", "--", alias],
                input=parser + '\nprintf "%s|%s" "$COMMAND" "${EXTRA_ARGS[*]}"',
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertEqual(result.stdout, "enable|gitea")

    def test_enable_and_disable_need_neither_crc_nor_wiring(self):
        script = (ROOT / "aap-demo.sh").read_text()
        functions = []
        for name in ("_normalize_addon_name", "cmd_enable", "cmd_disable"):
            functions.append(script.split(name + "() {", 1)[1].split("\n}", 1)[0])
        harness = "\n".join(
            name + "() {" + body + "\n}"
            for name, body in zip(("_normalize_addon_name", "cmd_enable", "cmd_disable"), functions)
        )
        with tempfile.TemporaryDirectory() as directory:
            addon = Path(directory) / "addons/gitea"
            addon.mkdir(parents=True)
            (addon / "deploy.sh").write_text('printf "vm-action:%s\\n" "${1:-deploy}"')
            harness = (
                """
set -euo pipefail
_verify_cluster() { echo UNEXPECTED_CLUSTER; return 1; }
setup_kubeconfig() { echo UNEXPECTED_KUBECONFIG; return 1; }
_aap_demo_run_addon_wire() { echo UNEXPECTED_WIRING; return 1; }
_addons_list() { :; }
_addons_add() { :; }
_addons_remove() { :; }
aap_demo_reload_version() { :; }
aap_demo_version_short() { echo test; }
"""
                + harness
                + """
SCRIPT_DIR="$1"
cmd_enable gittea
cmd_disable gitea
"""
            )
            result = subprocess.run(
                ["bash", "-s", "--", directory],
                input=harness,
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertIn("vm-action:deploy", result.stdout)
            self.assertIn("vm-action:--delete", result.stdout)
            self.assertNotIn("UNEXPECTED", result.stdout)


if __name__ == "__main__":
    unittest.main()
