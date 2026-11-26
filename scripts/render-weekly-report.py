#!/usr/bin/env python3
"""Render a local aap-demo health report without reading raw evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
from pathlib import Path


def load(path: Path) -> dict:
    with path.open(encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError("steward state must be a JSON object")
    return value


def cells(issue: dict) -> str:
    return "".join(
        f"<td>{html.escape(str(issue.get(field, "—")))}</td>"
        for field in ("id", "severity", "source", "status", "last_seen", "summary")
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--html", dest="html_path", type=Path, required=True)
    parser.add_argument("--text", type=Path, required=True)
    parser.add_argument("--enabled", default="")
    parser.add_argument("--available", default="")
    parser.add_argument("--version", required=True)
    args = parser.parse_args()

    state = load(args.state)
    issues = state.get("issues", [])
    if not isinstance(issues, list):
        raise ValueError("steward issues must be a list")
    enabled = sorted(set(filter(None, args.enabled.split())))
    available = sorted(set(filter(None, args.available.split())))
    unused = [item for item in available if item not in enabled]
    open_issues = [item for item in issues if item.get("status") == "open"]
    watch_issues = [item for item in issues if item.get("status") == "watch"]
    generated = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    rows = "".join(cells(issue) for issue in open_issues + watch_issues)
    if not rows:
        rows = '<tr><td colspan="6">No tracked findings.</td></tr>'
    enabled_text = ", ".join(enabled) if enabled else "No addons recorded"
    unused_text = ", ".join(unused) if unused else "All known optional addons are enabled"
    text = "\n".join(
        [
            "AAP Demo weekly health report",
            f"Generated: {generated}",
            f"Version: {args.version}",
            f"Open findings: {len(open_issues)}; watching: {len(watch_issues)}",
            f"Enabled capabilities: {enabled_text}",
            f"Optional capabilities not enabled: {unused_text}",
            "CVE and advisory status: No advisory scanner is configured by this report. Review Satellite/Insights results separately.",
            "Safety: findings come only from sanitized, read-only steward checks; no automated repair was run.",
        ]
    )
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>AAP Demo weekly health report</title>
<style>
body{{font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#1f2937;margin:32px;max-width:1100px}}
h1{{color:#b91c1c}} h2{{margin-top:30px;color:#374151}} .cards{{display:flex;gap:12px;flex-wrap:wrap}}
.card{{background:#f3f4f6;border-radius:8px;padding:14px;min-width:180px}} .number{{font-size:28px;font-weight:700}}
table{{border-collapse:collapse;width:100%;font-size:14px}} th,td{{border:1px solid #d1d5db;padding:8px;text-align:left;vertical-align:top}}th{{background:#374151;color:#fff}}
.note{{background:#eff6ff;border-left:4px solid #2563eb;padding:12px}} code{{white-space:normal}}
@media print{{body{{margin:12mm}}}}
</style></head><body>
<h1>AAP Demo weekly health report</h1><p>Generated {generated} · Tool version {html.escape(args.version)}</p>
<div class="cards"><div class="card"><div class="number">{len(open_issues)}</div>Open findings</div>
<div class="card"><div class="number">{len(watch_issues)}</div>Watching</div>
<div class="card"><div class="number">{len(enabled)}</div>Enabled addons</div></div>
<h2>Tracked health findings</h2><table><thead><tr><th>ID</th><th>Severity</th><th>Source</th><th>Status</th><th>Last seen</th><th>Summary</th></tr></thead><tbody>{rows}</tbody></table>
<h2>Capabilities</h2><p><strong>Enabled:</strong> {html.escape(enabled_text)}</p><p><strong>Available but not enabled:</strong> {html.escape(unused_text)}</p>
<h2>Security and advisories</h2><div class="note">This report does not invent CVE status. No advisory scanner is configured here; review Satellite or Red Hat Insights results separately. It includes only sanitized, read-only steward findings and never runs a repair.</div>
<h2>Next actions</h2><ol><li>Review open findings and their private sanitized evidence.</li><li>Confirm an approved, idempotent remediation before making a change.</li><li>Use this HTML report in email or print it to PDF from a browser.</li></ol>
</body></html>"""
    args.html_path.write_text(page + "\n", encoding="utf-8")
    args.text.write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
