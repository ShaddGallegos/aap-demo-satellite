#!/usr/bin/env python3
"""Regression checks for the non-live scenario-matrix harness."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / "scripts" / "scenario-harness.py"

with tempfile.TemporaryDirectory() as directory:
    report = Path(directory) / "scenario-matrix.md"
    result = subprocess.run(
        ["python3", str(HARNESS), "--output", str(report)],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise AssertionError(result.stderr)
    text = report.read_text(encoding="utf-8")
    assert "Full non-empty powerset: 33,554,431 combinations" in text
    assert "Contract coverage: 5/25 public addons" in text
    assert "product-demo-satellite, product-demos-base" in text
    assert "### Missing scenario contracts" in text
    assert report.stat().st_mode & 0o777 == 0o600
    strict = subprocess.run(
        ["python3", str(HARNESS), "--strict"], text=True, capture_output=True, check=False
    )
    assert strict.returncode == 1

print("PASS: scenario harness reports bounded coverage and incomplete contracts safely")
