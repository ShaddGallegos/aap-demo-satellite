---
type: Reference
title: Credential Vault
description: Store aap-demo secrets in the shared encrypted Ansible Vault without exposing their values.
tags: [security, credentials, vault]
---

# Credential Vault

`aap-demo` stores persistent secrets in the shared Ansible Vault at
`~/.ansible/conf/env.yml`. Its Vault password file is
`~/.ansible/conf/.vaultpass.txt`. The configuration directory is mode `0700`;
both files are mode `0600`. The command checks and repairs those modes whenever
it reads or writes a managed value.

Do not put secrets in shell history, command arguments, repository files, or
the dashboard. Do not decrypt the Vault to inspect it. Use the relevant
interactive command to enter or replace a value; `aap-demo` writes only that
key while preserving unrelated Vault data.

## Managed entries

Entries are created only when the corresponding profile needs them. A missing
entry is not an error until its feature is enabled.

| Feature | Vault entries |
| --- | --- |
| Red Hat and Fleet | `aap_demo.redhat.offline_token`, `aap_demo.redhat.cdn_username`, `aap_demo.redhat.cdn_password`, `aap_demo.redhat.account_number`, `aap_demo.redhat.aap_subscription_id` |
| OpenShift and Satellite mirroring | `aap_demo.redhat.pull_secret`, `aap_demo.redhat.registry_username`, `aap_demo.redhat.registry_token` |
| Automation Hub | `ah_offline_token` |
| Private Automation Hub | `aap_demo.pah.username`, `aap_demo.pah.password`, `aap_demo.pah.token` |
| Fleet access | `aap_demo.fleet.ssh_private_key`, `aap_demo.fleet.legacy_ssh_private_key`, `aap_demo.fleet.node_<index>.password` |
| Gitea | `aap_demo.gitea.admin_password` |
| Lightwell | `aap_demo.lightwell.openflake_password`, `aap_demo.lightwell.postgres_password`, `aap_demo.lightwell.openflake_secret`, `aap_demo.lightwell.gitea_token`, `aap_demo.lightwell.ao_client_id`, `aap_demo.lightwell.ao_client_secret` |
| Satellite lab | `aap_demo.satellite.admin_password`, `aap_demo.satellite.root_password`, `aap_demo.satellite.provisioning_root_password` |
| Automation Orchestrator | `aap_demo.ao.initial_admin_password` |
| Optional GitHub integration | `aap_demo.github.token` |

`aap_demo.cluster.*` and `aap_demo.project.name` are retained metadata, not
credentials. The Vault may also contain entries belonging to another tool; the
cleanup workflow removes only `aap-demo`-managed keys.

## Safe setup and review

Use the feature that owns a credential:

```bash
aap-demo fleet auth
aap-demo enable setup-pah
aap-demo credentials github configure
```

Satellite and Lightwell generate their lab-specific secrets during their
managed preparation. Their values remain encrypted and are supplied to child
processes through protected temporary files or standard input, not command-line
arguments.

Run the repository-only guardrail review without reading Vault values:

```bash
bash scripts/security-audit.sh
```

For stricter first-use SSH trust in a non-disposable lab, use the fingerprint
verification controls in the [security policy](SECURITY.md#local-lab-trust-controls).
