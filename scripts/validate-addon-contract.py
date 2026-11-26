#!/usr/bin/env python3
"""Validate an aap-demo addon scenario contract without loading secrets."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


REQUIRED_TOP_LEVEL = {
    "schema_version",
    "name",
    "summary",
    "lifecycle",
    "dependencies",
    "inputs",
    "resources",
    "readiness",
    "security",
}
REQUIRED_LIFECYCLE = {"enable", "disable", "idempotency", "failure_boundary"}
REQUIRED_DEPENDENCIES = {"addons", "services"}
REQUIRED_INPUT = {"name", "source", "required", "secret"}
REQUIRED_SECURITY = {"secret_storage", "network_trust", "external_actions"}


def fail(message: str) -> None:
    raise ValueError(message)


def object_at(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def string_at(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty string")
    return value


def string_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        fail(f"{label} must be a list of non-empty strings")
    return value


def require_keys(value: dict[str, Any], keys: set[str], label: str) -> None:
    missing = sorted(keys - value.keys())
    if missing:
        fail(f"{label} is missing required field(s): {', '.join(missing)}")


def validate(contract: Any, path: Path) -> None:
    root = object_at(contract, "contract")
    require_keys(root, REQUIRED_TOP_LEVEL, "contract")
    if root["schema_version"] != "1.0":
        fail("schema_version must be '1.0'")
    if root["name"] != path.parent.name:
        fail(f"name must match addon directory '{path.parent.name}'")
    string_at(root["summary"], "summary")

    lifecycle = object_at(root["lifecycle"], "lifecycle")
    require_keys(lifecycle, REQUIRED_LIFECYCLE, "lifecycle")
    for field in REQUIRED_LIFECYCLE:
        string_at(lifecycle[field], f"lifecycle.{field}")
    if lifecycle["enable"] != "deploy.sh" or not lifecycle["disable"].startswith("deploy.sh"):
        fail("lifecycle must declare the addon deploy.sh enable and disable paths")

    dependencies = object_at(root["dependencies"], "dependencies")
    require_keys(dependencies, REQUIRED_DEPENDENCIES, "dependencies")
    for field in REQUIRED_DEPENDENCIES:
        string_list(dependencies[field], f"dependencies.{field}")

    inputs = root["inputs"]
    if not isinstance(inputs, list):
        fail("inputs must be a list")
    names: set[str] = set()
    for index, entry in enumerate(inputs):
        item = object_at(entry, f"inputs[{index}]")
        require_keys(item, REQUIRED_INPUT, f"inputs[{index}]")
        name = string_at(item["name"], f"inputs[{index}].name")
        if name in names:
            fail(f"inputs contains duplicate name '{name}'")
        names.add(name)
        source = string_at(item["source"], f"inputs[{index}].source")
        if not isinstance(item["required"], bool) or not isinstance(item["secret"], bool):
            fail(f"inputs[{index}] required and secret must be booleans")
        if item["secret"] and not source.startswith("vault:"):
            fail(f"secret input '{name}' must use a vault: source")
        if "value" in item or "default_value" in item:
            fail(f"inputs[{index}] must describe a source, never store a value")

    resources = object_at(root["resources"], "resources")
    for resource_type, names in resources.items():
        string_list(names, f"resources.{resource_type}")
    if not resources:
        fail("resources must declare the resources the addon owns")

    readiness = root["readiness"]
    string_list(readiness, "readiness")
    security = object_at(root["security"], "security")
    require_keys(security, REQUIRED_SECURITY, "security")
    for field in REQUIRED_SECURITY:
        string_at(security[field], f"security.{field}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet", action="store_true", help="suppress successful output")
    parser.add_argument("contract", type=Path, help="path to scenario.json")
    args = parser.parse_args(argv)
    try:
        with args.contract.open(encoding="utf-8") as handle:
            contract = json.load(handle)
        validate(contract, args.contract)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"ERROR: invalid addon scenario contract {args.contract}: {error}", file=sys.stderr)
        return 1
    if not args.quiet:
        print(f"PASS: valid addon scenario contract: {args.contract}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
