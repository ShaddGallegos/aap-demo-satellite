# Subscription Attach Addon

Automatically attaches a Red Hat subscription to Ansible Automation Platform (AAP) using Red Hat developer account credentials.

## Overview

This addon eliminates the manual step of logging into AAP UI and registering a subscription (Settings → Subscription).
It uses the `infra.aap_configuration.controller_license` role to automatically look up and attach a Red Hat
developer subscription.

## Features

- **Automatic Subscription Lookup**: Queries Red Hat systems for available subscriptions
- **Secure Credential Storage**: Stores retained credentials in the encrypted Ansible Vault
- **Multiple Input Methods**: Supports temporary environment variables, the Vault, or interactive prompts
- **Non-Blocking**: Warns on failure but doesn't break AAP deployment
- **Auto-Enabled**: Runs automatically after `aap-demo deploy` via addon-wire.sh integration

## How It Works

1. **After AAP Deployment**: Automatically triggered via `includes/addon-wire.sh` after AAP pods are running
2. **Credential Discovery**: Checks for credentials in this order:
   - Environment variables (`REDHAT_SUBSCRIPTION_USERNAME`, `REDHAT_SUBSCRIPTION_PASSWORD`)
   - The encrypted aap-demo Vault (`aap_demo.redhat.cdn_username` and
     `aap_demo.redhat.cdn_password`)
   - Interactive prompt (if terminal is interactive and not in QUIET mode)
3. **Subscription Lookup**: Uses `infra.aap_configuration.controller_license` role with `use_lookup: true` to query
   the Red Hat subscription API
4. **Automatic Attachment**: Attaches the first matching "Red Hat Ansible Automation Platform" subscription with
   "Self-Support" level
5. **Verification**: Confirms subscription was attached successfully

## Prerequisites

- AAP deployed via `aap-demo deploy`
- Red Hat developer account (free at [developers.redhat.com/register](https://developers.redhat.com/register))
- Tools: `kubectl`, `curl`, `jq` (already required by aap-demo)

## Usage

### Automatic (Recommended)

The addon runs automatically after `aap-demo deploy`:

```bash
aap-demo deploy
# ... AAP deploys ...
# Subscription prompt appears:
#   Red Hat username (email): your-email@example.com
#   Red Hat password: ********
# ✓ Subscription attached automatically
```

### Manual Trigger

To attach a subscription to an already-deployed AAP:

```bash
aap-demo enable subscription-attach
```

### Environment Variables

Skip interactive prompts by setting environment variables:

```bash
export REDHAT_SUBSCRIPTION_USERNAME="your-email@example.com"
read -r -s -p "Red Hat password: " REDHAT_SUBSCRIPTION_PASSWORD
export REDHAT_SUBSCRIPTION_PASSWORD
echo
aap-demo deploy
```

### Choose Subscription Interactively

If you have multiple AAP subscriptions and want to choose which one to attach:

```bash
export SUBSCRIPTION_INTERACTIVE=true
aap-demo deploy

# You'll see:
# Available Red Hat Ansible Automation Platform subscriptions:
#
# 1) Employee SKU (ID: 1111111)
# 2) Red Hat Developer Subscription for Individuals (ID: 123456)
#
# Select subscription number [1-2]: 2
```

**Default behavior**: Automatically selects "Red Hat Developer Subscription for Individuals" if available;
otherwise, it uses the first valid AAP subscription.

### Non-Interactive Mode

For CI/CD pipelines, use QUIET mode to skip prompts:

```bash
QUIET=true aap-demo deploy
# Skips subscription attachment if credentials not provided
```

## Credential Storage

### Vault location

Credentials are saved under the `aap_demo` namespace in the encrypted Ansible
Vault at `~/.ansible/conf/env.yml`. The corresponding owner-only Vault password
file is `~/.ansible/conf/.vaultpass.txt`.

### Security

- Retained username and password values are never written to a plaintext
  credential file.
- Environment variables are temporary one-run overrides; they are not required
  once the Vault has the CDN credentials.
- Do not put credentials in command arguments, logs, or repository files.

### Environment Variable Override

The environment variables take precedence over Vault values for that invocation.

## Subscription Management

### Check Subscription Status

```bash
# Via API
AAP_ROUTE=$(kubectl get route aap -n aap-operator -o jsonpath='{.spec.host}')
AAP_PASSWORD=$(kubectl get secret aap-admin-password -n aap-operator -o jsonpath='{.data.password}' | base64 -d)

curl -sk -u "admin:${AAP_PASSWORD}" \
  "https://${AAP_ROUTE}/api/controller/v2/config/" | jq '.license_info'
```

### Manual Attachment (UI)

If automatic attachment fails, attach manually:

1. Get AAP route: `aap-demo status`
2. Log into AAP UI with admin credentials
3. Navigate to: **Settings → Subscription**
4. Enter Red Hat account credentials or upload a manifest

### Update Saved Credentials

Run the add-on interactively again or provide both temporary environment
variables. The resulting values replace only the two `aap_demo.redhat.cdn_*`
keys in the shared encrypted Vault.

## Troubleshooting

### Subscription Already Attached

If AAP already has a valid subscription, the addon skips attachment:

```
✓ AAP already has a valid subscription (type: enterprise)
```

### Invalid Credentials

```
❌ ERROR: Red Hat authentication failed
⚠  Verify the Red Hat account credentials and update the encrypted Vault
```

**Solution**: Verify credentials at [access.redhat.com](https://access.redhat.com)

### No Matching Subscription

```
❌ ERROR: No Red Hat Ansible Automation Platform subscription found
```

**Solution**: Register for a free developer subscription at [developers.redhat.com/register](https://developers.redhat.com/register)

### API Request Failed

```
❌ ERROR: Failed to configure subscription credentials in AAP
⚠  API request failed - check AAP status
```

**Solution**: Verify AAP is running and accessible:

```bash
aap-demo status
kubectl get pods -n aap-operator
```

## Technical Details

### AAP Subscription API

The addon uses direct AAP API calls to attach subscriptions - no Ansible collections or playbooks required.

**API Workflow**:

1. **POST** `/api/controller/v2/config/subscriptions/` with `subscriptions_username` and `subscriptions_password`
   - AAP contacts Red Hat subscription service
   - Returns array of available subscriptions
2. **Select subscription**: Filter for first "Red Hat Ansible Automation Platform" subscription with `valid_key: true`
3. **POST** `/api/controller/v2/config/attach/` with `subscription_id`
   - Attaches the selected subscription to AAP
4. **GET** `/api/controller/v2/config/` to verify `license_info.valid_key == true`

**Why API instead of Ansible Collection:**

- No external dependencies (no `infra.aap_configuration` collection required)
- Simpler implementation (direct curl calls vs. playbook execution)
- Faster execution (no ansible-playbook overhead)
- AAP handles all Red Hat authentication and subscription retrieval automatically

### Integration Point

The addon is wired into the deployment flow via `includes/addon-wire.sh`:

```bash
aap_demo_wire() {
  # ... other wiring ...
  wire_subscription_attach || true  # Non-blocking
  # ... rest of wiring ...
}
```

### API Endpoints

- **List Subscriptions**: `POST /api/controller/v2/config/subscriptions/`
  - Payload: `{"subscriptions_username": "email@example.com", "subscriptions_password": "..."}`
  - Response: Array of available subscriptions from Red Hat account
- **Attach Subscription**: `POST /api/controller/v2/config/attach/`
  - Payload: `{"subscription_id": "12345678"}`
  - Response: Attaches the selected subscription to AAP
- **Check Status**: `GET /api/controller/v2/config/`
  - Returns: `license_info` object with `valid_key`, `license_type`, `subscription_name`

## Files

```
addons/subscription-attach/
├── deploy.sh    # Main script with credential prompting and API calls
└── README.md    # This file
```

**Note**: This addon is auto-enabled via `includes/addon-wire.sh` integration and does not appear in `aap-demo enable` list.

## Development

### Testing

```bash
# Test with environment variables
export REDHAT_SUBSCRIPTION_USERNAME="test@example.com"
read -r -s -p "Red Hat password: " REDHAT_SUBSCRIPTION_PASSWORD
export REDHAT_SUBSCRIPTION_PASSWORD
echo
bash addons/subscription-attach/deploy.sh

# Test non-interactive mode
QUIET=true bash addons/subscription-attach/deploy.sh

# Syntax check
bash -n addons/subscription-attach/deploy.sh
```

## Related Documentation

- [AAP Subscription Management](https://access.redhat.com/documentation/en-us/red_hat_ansible_automation_platform)
- [Red Hat Developer Program](https://developers.redhat.com)
- [AAP API Documentation](https://docs.ansible.com/automation-controller/latest/html/controllerapi/)

## License

GPLv3+ (consistent with aap-demo project)
