#!/usr/bin/env python3
"""Redact credential-shaped values before a steward report reaches disk."""

from __future__ import annotations

import re
import sys


ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
AUTHORIZATION = re.compile(
    r"(?im)^(\s*(?:authorization|proxy-authorization)\s*:\s*)(?:bearer|basic)\s+\S+"
)
KEY_VALUE = re.compile(
    r"(?i)(\b(?:password|passwd|token|secret|api[_-]?key|private[_-]?key|client[_-]?secret)\b"
    r"\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|\S+)"
)
URL_CREDENTIALS = re.compile(r"(?i)(https?://)[^\s/@:]+:[^\s/@]+@")
JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b")


def redact(text: str) -> str:
    text = ANSI.sub("", text)
    text = AUTHORIZATION.sub(r"\1<redacted>", text)
    text = KEY_VALUE.sub(r"\1<redacted>", text)
    text = URL_CREDENTIALS.sub(r"\1<redacted>@", text)
    return JWT.sub("<redacted-jwt>", text)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: sanitize-steward-report.py INPUT", file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8", errors="replace") as report:
        sys.stdout.write(redact(report.read()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
