#!/usr/bin/env python3
"""Regression checks for machine-readable addon scenario contracts."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts" / "validate-addon-contract.py"
SATELLITE = ROOT / "addons" / "product-demo-satellite" / "scenario.json"


def check(arguments: list[str], expected: int) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["python3", str(VALIDATOR), *arguments], text=True, capture_output=True, check=False
    )
    if result.returncode != expected:
        raise AssertionError(f"expected {expected}, got {result.returncode}: {result.stderr}")
    return result


check([str(SATELLITE)], 0)
with tempfile.TemporaryDirectory() as directory:
    addon = Path(directory) / "product-demo-satellite"
    addon.mkdir()
    invalid = addon / "scenario.json"
    contract = json.loads(SATELLITE.read_text(encoding="utf-8"))
    contract["inputs"][2]["source"] = "environment:SATELLITE_PASSWORD"
    invalid.write_text(json.dumps(contract), encoding="utf-8")
    result = check([str(invalid)], 1)
    if "secret input" not in result.stderr:
        raise AssertionError(result.stderr)

source = (ROOT / "aap-demo.sh").read_text(encoding="utf-8")
if 'aap_demo_validate_addon_contract "$addon_dir" || return 1' not in source:
    raise AssertionError("enable must validate an addon scenario contract before deployment")

print("PASS: addon scenario contracts validate structure and secret sources")
