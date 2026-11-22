"""Notify AO only for a deliberate, change-tracked simulation run."""

import json
import os
import ssl
import urllib.parse
import urllib.request
from pathlib import Path

change = Path("CHANGE_REQUEST").read_text().strip()
if not change:
    print("No change request: input checks passed; no AO workflow triggered.")
else:
    origin = os.environ["GITEA_SERVER_URL"]
    payload = {
        "app_name": "inventory-service",
        "artifact_version": Path("version.txt").read_text().strip()
        + "-b"
        + os.environ["GITEA_RUN_NUMBER"],
        "git_sha": os.environ["GITEA_SHA"],
        "ci_build_url": origin
        + "/"
        + os.environ["GITEA_REPOSITORY"]
        + "/actions/runs/"
        + os.environ["GITEA_RUN_NUMBER"],
        "change_request": change,
        "ci_build_number": os.environ["GITEA_RUN_NUMBER"],
    }
    cve = Path("PATCHED_CVE").read_text().strip()
    if cve:
        payload["affected_cve"] = cve
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
    )
    token_request = urllib.request.Request(
        os.environ["AO_ORIGIN"] + "/api/v1/auth/token",
        data=urllib.parse.urlencode(
            {
                "grant_type": "client_credentials",
                "client_id": os.environ["AO_CLIENT_ID"],
                "client_secret": os.environ["AO_CLIENT_SECRET"],
            }
        ).encode(),
        method="POST",
    )
    with opener.open(token_request, timeout=60) as response:
        token = json.load(response)["access_token"]
    request = urllib.request.Request(
        os.environ["AO_ORIGIN"] + "/api/v1/webhooks/lightwell-ci-cd",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    request.add_unredirected_header("Authorization", "Bearer " + token)
    with opener.open(request, timeout=60) as response:
        if response.status not in (200, 201, 202):
            raise RuntimeError(f"AO rejected the webhook: HTTP {response.status}")
    print("AO accepted the authenticated change-tracked webhook.")
