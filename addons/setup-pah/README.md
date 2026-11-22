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
`401` or `403` first prompts once for a replacement token, validates and stores
it only if valid, then retries the remote configuration. If Validated Content
is still unavailable, setup reports a warning and continues with Certified
Content. Other failed tasks stop setup and report their failure rather than
allowing a later Product Demos job to fail with an unexplained SSO error.

Initial Certified Content synchronization can take several minutes. The
installer reports the active Pulp task every 30 seconds and waits up to 30
minutes by default. For an unusually constrained connection, set
`PAH_SYNC_TIMEOUT_SECONDS` (minimum `60`) before running the command; set
`PAH_SYNC_POLL_SECONDS` (`1`–`30`, default `5`) only when a different status
polling cadence is useful. These values are operational settings, not secrets,
and are not written to the Vault.

This token is distinct from the Customer Portal/CDN credentials. Generate it at
the [Automation Hub token page](https://console.redhat.com/ansible/automation-hub/token),
then let the interactive setup store it in the encrypted Vault. Do not place the
token in source, logs, or command arguments.

See [collection authentication](../../docs/collection-authentication.md) for
the token separation and recovery guidance.
