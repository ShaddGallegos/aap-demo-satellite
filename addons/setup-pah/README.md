# Private Automation Hub setup

`setup-pah` configures the local Automation Hub remotes with the Automation Hub
offline token stored as `ah_offline_token` in Vault-encrypted
`~/.ansible/conf/env.yml`.

```bash
aap-demo enable setup-pah
```

The command validates the token, updates the Certified and Validated Content
remotes, and waits for their Pulp synchronization tasks. Certified Content is
required. Validated Content is attempted when the subscription permits it; a
`401` or `403` first revalidates the saved token with Red Hat SSO. A
SSO-rejected token prompts once for a replacement, validates and stores it only
if valid, then retries the remote configuration. A token that is still valid at
SSO is not re-prompted: the result is an entitlement warning for Validated
Content, or a clear failure for required Certified Content. This prevents a
valid Vault token from being needlessly replaced. Other failed tasks stop setup
and report their failure rather than allowing a later Product Demos job to fail
with an unexplained SSO error.

For a full-demo profile, all Customer Portal, CDN, and Automation Hub prompts
occur before its workflow journal and progress phases start. The later quiet
phases never open another secret prompt: if a previously valid token is later
rejected, the workflow stops with an actionable error and preserves the Vault.

Initial Certified Content synchronization can take several minutes. The
installer reports the active Pulp task every 30 seconds and waits up to 30
minutes by default. For an unusually constrained connection, set
`PAH_SYNC_TIMEOUT_SECONDS` (minimum `60`) before running the command; set
`PAH_SYNC_POLL_SECONDS` (`1`–`30`, default `5`) only when a different status
polling cadence is useful. These values are operational settings, not secrets,
and are not written to the Vault.

If a Pulp task fails only because it cannot resolve Red Hat's S3-backed content
host, or because Pulp reports that its worker disappeared, setup automatically
starts one replacement sync after 15 seconds. Set
`PAH_DNS_RETRY_DELAY_SECONDS` (`1`–`60`) to adjust that delay. A second
transient failure remains an error and reports the Pulp detail; this avoids
concealing a real resolver or worker outage behind repeated retries.

This token is distinct from the Customer Portal/CDN credentials. Full-demo
profiles validate or collect it before any progress-tracked installation phase,
so `setup-pah` does not wait behind a spinner for secret input. Generate it at
the [Automation Hub token page](https://console.redhat.com/ansible/automation-hub/token),
then let the interactive setup store it in the encrypted Vault. Do not place the
token in source, logs, or command arguments.

See [collection authentication](../../docs/collection-authentication.md) for
the token separation and recovery guidance.
