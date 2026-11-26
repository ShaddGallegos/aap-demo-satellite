---
type: Reference
title: Settings
description: Default cluster size, the AAP channel, and the folders aap-demo uses.
tags: [config, paths, channel]
status: draft
stale_after: 2027-01-28
resource: https://github.com/RedHatOfficial/aap-demo
---

# Settings

Change a setting for one run with a flag, or save it:

```bash
aap-demo config set deploy.channel stable-2.6
aap-demo config list
aap-demo config path
```

The file is `~/.config/aap-demo/config.yaml`.

## Cluster size

Defaults when you `create`:

| | Default | Minimum | Flag | Environment variable | Saved key |
| --- | --- | --- | --- | --- | --- |
| Processors | 8 | 2 | `--cpus` | `CRC_CPUS` | `crc.cpus` |
| Memory | 24576 MB (24 GB) | 8192 MB | `--memory` | `CRC_MEMORY` | `crc.memory_mb` |
| Disk | 120 GB | 60 GB | `--disk` | `CRC_DISK` | `crc.disk_gb` |
| Space for volumes | 100 GB | 10 GB | `--pv-size` | `CRC_PV_SIZE` | `crc.pv_size_gb` |

A later source overrides an earlier one:

1. The default in this table
2. The saved key in `~/.config/aap-demo/config.yaml`
3. The environment variable
4. The flag

A value below the minimum stops the command before it changes anything. The error names the flag, the
environment variable, and the saved key. Correct the one that holds the bad value. The saved key and the
environment variable are checked before flags are read, so a flag does not get past a bad value from either.

`create` asks for processors and memory when it is about to make a new virtual machine in a terminal. Press
Enter to keep the value shown. Your answers are saved as `crc.cpus` and `crc.memory_mb`. It does not ask when
`--cpus`, `--memory`, `CRC_CPUS` or `CRC_MEMORY` is set, with `--quiet`, with structured output, or without a
terminal. `AAP_DEMO_INTERACTIVE=1` makes it ask without a terminal.

`create` and `deploy` both print the size they resolved. `create` stops before starting the virtual machine if
the size is more than the computer has. Linux swap counts toward memory. It also warns if the computer has fewer
than 4 processors or 10 GB of memory. Set the size before the virtual machine exists. Changing it later
means `destroy` and `create` again, so `deploy` on an existing machine does not resize it.

```bash
aap-demo create --cpus 6 --memory 16384 --disk 80 --pv-size 60
```

## AAP version

| | |
| --- | --- |
| Default channel | `stable-2.7` |
| Flag | `--channel` on `deploy` |
| Saved key | `deploy.channel` |

See [Choose a version](../guides/choose-a-version.md).

## Where files go

| What | Where |
| --- | --- |
| Settings | `~/.config/aap-demo/config.yaml` |
| Pull secret | `~/.config/aap-demo/pull-secret.txt`, or the same name in `~/.local/state/aap-demo/` or `~/.aap-demo/`. `pull-secret.json` and a bare `pull-secret` are also accepted |
| Subscription manifest | Newest `manifest*.zip` in `~/.config/aap-demo/`, then `~/.local/state/aap-demo/`, then `~/.aap-demo/` |
| Kubeconfig | `~/.local/state/aap-demo/kubeconfig.microshift` |
| Cluster certificate | `~/.local/state/aap-demo/certs/` |
| Cache | `~/.cache/aap-demo` |

`deploy` applies a subscription manifest only if you agree. `--auto-license`, `AAP_DEMO_AUTO_LICENSE=true`, or
`aap-demo config set auto-license true` applies it without asking. See [Subscription](../guides/subscription.md).

Cluster commands stop if the kubeconfig points at a remote API server, which `oc login` can cause. Set
`AAP_DEMO_ALLOW_REMOTE_KUBECONFIG=true` to target that server on purpose.

`AAP_DEMO_DIR` puts settings, state, and cache under one folder you choose. That is for CI and for unusual
layouts, not for a normal install.

The older bash command uses `~/.aap-demo` instead. The new command does not look there.

## Credentials and sensitive values

aap-demo stores its credentials, tokens, private keys, and generated passwords in the
encrypted Ansible Vault at `~/.ansible/conf/env.yml`, under the `aap_demo` namespace.
The Vault password file is `~/.ansible/conf/.vaultpass.txt`; both files are owner-only.
Do not put these values in command arguments, configuration files, logs, or the repository.
Environment variables are accepted only as temporary, one-run overrides and are not saved
outside the Vault. Interactive Red Hat CDN credentials are saved directly to the Vault;
aap-demo does not create a plaintext credential file for them.

Automatic environment reports are redacted. To generate a report for support,
use `aap-demo system-info --redact --output /tmp/aap-support.md`; do not retain
or share an unredacted report.

For a reviewed local evidence directory, use `aap-demo support-bundle preview`
then `aap-demo support-bundle create --output DIRECTORY`. The bundle is
owner-only, redacted, offline-scanned, and never uploaded automatically. It
does not include the Vault, kubeconfig, keys, raw logs, or must-gather output.

Common retained keys include `aap_demo.redhat.cdn_username`,
`aap_demo.redhat.cdn_password`, `aap_demo.satellite.admin_password`,
`aap_demo.satellite.root_password`, and
`aap_demo.satellite.provisioning_root_password`. Their names are safe to
document; their values must remain encrypted.

`ah_offline_token` is a separate Automation Hub token. `setup-pah` reads it to
configure the local Certified and Validated Content remotes, then waits for
their Pulp sync tasks. It is not interchangeable with the Customer Portal/CDN
credentials or `aap_demo.redhat.offline_token`.

## Fleet SSH identity and host keys

The Bash Fleet shared SSH private key is stored under `aap_demo.fleet.ssh_private_key`
in the encrypted `~/.ansible/conf/env.yml` credential Vault. If an older
`~/.aap-demo/fleet/ssh_key` exists, aap-demo imports it, reads it back from the
Vault, and verifies that the public identity matches before removing that
plaintext private-key copy. An unreadable Vault, a mismatched key, or existing
Fleet nodes without a recoverable identity stop the operation; aap-demo does
not silently replace the key.

Host-side SSH commands create a mode-600 temporary key file only for the
connection and remove it on completion, failure, or interruption. Protected
copies remain inside managed guest accounts because they are required for
cross-guest SSH. Server host keys use trust on first use: Fleet node connections
record keys in `~/.aap-demo/fleet/known_hosts`, cross-guest aliases use
`~/.ssh/aap-demo-lab-known_hosts`, and other Bash lab SSH commands use the
standard `~/.ssh/known_hosts`. Later connections fail if a key changes. After
independently verifying an intentional VM rebuild or host-key rotation, remove
only that host's obsolete entry from the applicable file before reconnecting.
