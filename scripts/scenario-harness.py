#!/usr/bin/env python3
"""Build a bounded, non-live addon scenario matrix and optional test report."""

from __future__ import annotations

import argparse
import itertools
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
ADDONS = ROOT / "addons"
CLI = ROOT / "aap-demo.sh"
RUNNER = ROOT / "test" / "run-unit-tests.sh"


@dataclass(frozen=True)
class Scenario:
    name: str
    dependencies: tuple[str, ...]


def public_addons() -> list[str]:
    source = CLI.read_text(encoding="utf-8")
    match = re.search(r'^AVAILABLE_ADDONS="([^"]+)"', source, re.MULTILINE)
    if not match:
        raise ValueError("could not read AVAILABLE_ADDONS from aap-demo.sh")
    return match.group(1).split()


def addon_directories() -> set[str]:
    return {path.name for path in ADDONS.iterdir() if (path / "deploy.sh").is_file()}


def contracts() -> tuple[dict[str, Scenario], list[str]]:
    loaded: dict[str, Scenario] = {}
    invalid: list[str] = []
    for path in sorted(ADDONS.glob("*/scenario.json")):
        try:
            raw: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
            name = raw["name"]
            dependencies = tuple(raw["dependencies"]["addons"])
            if not isinstance(name, str) or not all(isinstance(item, str) for item in dependencies):
                raise ValueError("name/dependencies.addons has an invalid type")
            loaded[name] = Scenario(name, dependencies)
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
            invalid.append(f"{path.relative_to(ROOT)}: {error}")
    return loaded, invalid


def closure(names: tuple[str, ...], known: dict[str, Scenario]) -> tuple[str, ...]:
    selected = set(names)
    pending = list(names)
    while pending:
        current = pending.pop()
        for dependency in known.get(current, Scenario(current, ())).dependencies:
            if dependency not in selected:
                selected.add(dependency)
                pending.append(dependency)
    return tuple(sorted(selected))


def cases(known: dict[str, Scenario]) -> list[tuple[str, ...]]:
    # Pairwise coverage catches most wiring interactions while avoiding the
    # 2^N powerset. Dependencies are included in each case automatically.
    names = sorted(known)
    raw = [(name,) for name in names]
    raw.extend(itertools.combinations(names, 2))
    return sorted({closure(case, known) for case in raw}, key=lambda item: (len(item), item))


def render(
    public: list[str], directories: set[str], known: dict[str, Scenario], invalid: list[str],
    matrix: list[tuple[str, ...]], unit_result: subprocess.CompletedProcess[str] | None,
) -> str:
    missing = sorted(set(public) - set(known))
    unpublished = sorted(directories - set(public))
    dependencies = sorted({item for scenario in known.values() for item in scenario.dependencies})
    unresolved = sorted(set(dependencies) - directories)
    powerset = (2 ** len(public)) - 1
    lines = [
        "# aap-demo scenario-matrix report",
        "",
        f"Generated: {datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')}",
        "Mode: non-live planning; no addon, VM, cluster, Vault, provider, or vendor action was run.",
        "",
        "## Coverage model",
        "",
        f"- Public addons: {len(public)}",
        f"- Full non-empty powerset: {powerset:,} combinations (intentionally not executed)",
        f"- Contract-backed addons: {len(known)}",
        f"- Contract coverage: {len(known)}/{len(public)} public addons",
        f"- Planned dependency-closed singleton/pair cases: {len(matrix)}",
        "- Live installation is deliberately excluded; it needs an isolated disposable lab, approved subscriptions, and explicit operator approval.",
        "",
        "## Planned cases",
        "",
    ]
    if matrix:
        lines.extend(f"- `{', '.join(case)}`" for case in matrix)
    else:
        lines.append("- None")
    lines.extend(["", "## Gaps and blockers", ""])
    if missing:
        lines.append("### Missing scenario contracts")
        lines.append("")
        lines.append("These public addons cannot be safely combined automatically until they declare lifecycle, dependencies, ownership, readiness, and security boundaries:")
        lines.append("")
        lines.extend(f"- `{name}`" for name in missing)
        lines.append("")
    if unpublished:
        lines.append("### Internal addon directories")
        lines.append("")
        lines.append("These directories have deploy scripts but are not public addon choices; they may satisfy declared dependencies:")
        lines.append("")
        lines.extend(f"- `{name}`" for name in unpublished)
        lines.append("")
    if unresolved:
        lines.append("### Unresolved dependencies")
        lines.append("")
        lines.extend(f"- `{name}`" for name in unresolved)
        lines.append("")
    if invalid:
        lines.append("### Invalid contracts")
        lines.append("")
        lines.extend(f"- {item}" for item in invalid)
        lines.append("")
    if not (missing or invalid or unresolved):
        lines.append("No contract gaps were found. Add explicit incompatibility rules before enabling live matrix execution.")
        lines.append("")
    lines.extend(["## Non-live verification", ""])
    if unit_result is None:
        lines.append("Not run. Re-run with `--run-unit` to execute the isolated unit suite.")
    else:
        lines.append(f"Exit code: `{unit_result.returncode}`")
        summary = next(
            (line for line in reversed(unit_result.stdout.splitlines()) if line.startswith("Unit test files:")),
            "No unit-suite summary was emitted.",
        )
        lines.append(f"Result: {summary}")
        lines.append("")
        lines.append("```text")
        lines.extend((unit_result.stdout + unit_result.stderr).strip().splitlines()[-30:])
        lines.append("```")
    lines.extend([
        "",
        "## Next safe actions",
        "",
        "1. Add contracts for every public addon and declare explicit conflicts where two addons cannot coexist.",
        "2. Add fixture-backed install/check/remove adapters for each contract so cases exercise wiring without a real cluster.",
        "3. Run disposable-lab live qualification only after explicit approval; retain redacted evidence and tear down only owned resources.",
    ])
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="write the Markdown report to this new or existing file")
    parser.add_argument("--run-unit", action="store_true", help="run the isolated non-live unit suite before reporting")
    parser.add_argument("--strict", action="store_true", help="return nonzero when contract coverage is incomplete")
    args = parser.parse_args(argv)

    public = public_addons()
    directories = addon_directories()
    known, invalid = contracts()
    matrix = cases(known)
    unit_result = None
    if args.run_unit:
        unit_result = subprocess.run([str(RUNNER)], cwd=ROOT, text=True, capture_output=True, check=False)
    report = render(public, directories, known, invalid, matrix, unit_result)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report, encoding="utf-8")
        args.output.chmod(0o600)
        print(f"Scenario matrix report written to {args.output}")
    else:
        print(report, end="")
    incomplete = set(public) - set(known)
    if args.strict and (incomplete or invalid or unit_result and unit_result.returncode):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
