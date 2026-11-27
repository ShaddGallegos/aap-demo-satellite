#!/usr/bin/env bash
# Provider-neutral cloud/VMware profile planning. This module is deliberately
# non-mutating: it never contacts a provider or creates billable resources.

if [ -n "${_AAP_DEMO_CLOUD_PROFILE_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_CLOUD_PROFILE_LOADED=1

_aap_demo_cloud_usage() {
  cat <<'EOF'
Usage:
  aap-demo cloud requirements PROVIDER
  aap-demo cloud profile init PROVIDER FILE [--force]
  aap-demo cloud profile validate FILE
  aap-demo cloud plan FILE

Providers: aws, azure, gcp, vmware

All cloud commands are local-only planning operations. They never authenticate
to a provider, create resources, or incur charges. A profile stores identity
references, never credential values.
EOF
}

_aap_demo_cloud_provider_valid() {
  case "${1:-}" in aws | azure | gcp | vmware) return 0 ;; *) return 1 ;; esac
}

_aap_demo_cloud_template() {
  local provider="$1"
  jq -n --arg provider "$provider" '
    {
      schema_version: 1,
      provider: $provider,
      name: "REPLACE_ME",
      ownership: {
        customer_id: "REPLACE_ME",
        operator: "REPLACE_ME",
        approval_contact: "REPLACE_ME",
        cost_center: "REPLACE_ME"
      },
      location: {region: "REPLACE_ME", zone_or_cluster: "REPLACE_ME"},
      network: {
        private_dns_zone: "REPLACE_ME",
        management_cidrs: ["REPLACE_ME"],
        aap_subnet: "REPLACE_ME",
        fleet_subnet: "REPLACE_ME",
        satellite_subnet: "REPLACE_ME"
      },
      nodes: {
        aap: {count: 1, vcpus: 8, memory_gib: 32, disk_gib: 200},
        fleet: {count: 3, vcpus: 2, memory_gib: 4, disk_gib: 30},
        satellite: {enabled: false, count: 0, vcpus: 8, memory_gib: 32, disk_gib: 500},
        services: {gitea: false, lightwell: false}
      },
      identity_refs: {
        operator: "external:REPLACE_ME",
        workload: "external:REPLACE_ME",
        redhat: "aap_demo.redhat.account_number"
      },
      approvals: {
        network_reviewed: false,
        chargeable_resources_approved: false,
        data_retention_reviewed: false
      }
    }
    + if $provider == "aws" then {
        provider_config: {
          account_id: "REPLACE_ME", vpc_id: "REPLACE_ME", subnet_ids: ["REPLACE_ME"],
          security_group_ids: ["REPLACE_ME"], instance_profile: "REPLACE_ME"
        }
      }
      elif $provider == "azure" then {
        provider_config: {
          subscription_id: "REPLACE_ME", tenant_id: "REPLACE_ME", resource_group: "REPLACE_ME",
          vnet_name: "REPLACE_ME", subnet_names: ["REPLACE_ME"], network_security_group: "REPLACE_ME",
          managed_identity: "REPLACE_ME"
        }
      }
      elif $provider == "gcp" then {
        provider_config: {
          project_id: "REPLACE_ME", network_name: "REPLACE_ME", subnet_names: ["REPLACE_ME"],
          firewall_policy_ref: "REPLACE_ME", service_account: "REPLACE_ME"
        }
      }
      else {
        provider_config: {
          vcenter_url: "REPLACE_ME", datacenter: "REPLACE_ME", cluster: "REPLACE_ME",
          datastore: "REPLACE_ME", port_group: "REPLACE_ME", template: "REPLACE_ME",
          certificate_sha256: "REPLACE_ME"
        }
      }
      end
  '
}

_aap_demo_cloud_required_paths() {
  local provider="$1"
  case "$provider" in
    aws)
      printf '%s\n' '["provider_config","account_id"]' '["provider_config","vpc_id"]' \
        '["provider_config","subnet_ids"]' '["provider_config","security_group_ids"]' \
        '["provider_config","instance_profile"]'
      ;;
    azure)
      printf '%s\n' '["provider_config","subscription_id"]' '["provider_config","tenant_id"]' \
        '["provider_config","resource_group"]' '["provider_config","vnet_name"]' \
        '["provider_config","subnet_names"]' '["provider_config","network_security_group"]' \
        '["provider_config","managed_identity"]'
      ;;
    gcp)
      printf '%s\n' '["provider_config","project_id"]' '["provider_config","network_name"]' \
        '["provider_config","subnet_names"]' '["provider_config","firewall_policy_ref"]' \
        '["provider_config","service_account"]'
      ;;
    vmware)
      printf '%s\n' '["provider_config","vcenter_url"]' '["provider_config","datacenter"]' \
        '["provider_config","cluster"]' '["provider_config","datastore"]' \
        '["provider_config","port_group"]' '["provider_config","template"]' \
        '["provider_config","certificate_sha256"]'
      ;;
  esac | jq -sc .
}

_aap_demo_cloud_profile_problems() {
  local file="$1" provider required
  provider=$(jq -r '.provider // empty' "$file") || return 1
  _aap_demo_cloud_provider_valid "$provider" || {
    _err "Unsupported cloud provider in profile: ${provider:-missing}"
    return 1
  }
  required=$(_aap_demo_cloud_required_paths "$provider") || return 1
  jq -r --argjson provider_required "$required" '
    def unresolved:
      . == null or . == "" or
      (type == "string" and test("REPLACE_(ME|WITH)")) or
      (type == "array" and (length == 0 or any(.[]; unresolved)));
    def need($path):
      getpath($path) as $value |
      if ($value | unresolved) then ($path | join(".")) else empty end;
    def bool_need($path):
      getpath($path) as $value |
      if $value != true then ($path | join(".")) else empty end;
    . as $profile | [
      need(["name"]), need(["ownership", "customer_id"]),
      need(["ownership", "operator"]), need(["ownership", "approval_contact"]),
      need(["ownership", "cost_center"]), need(["location", "region"]),
      need(["location", "zone_or_cluster"]), need(["network", "private_dns_zone"]),
      need(["network", "management_cidrs"]), need(["network", "aap_subnet"]),
      need(["network", "fleet_subnet"]), need(["network", "satellite_subnet"]),
      need(["identity_refs", "operator"]), need(["identity_refs", "workload"]),
      need(["identity_refs", "redhat"]), bool_need(["approvals", "network_reviewed"]),
      bool_need(["approvals", "chargeable_resources_approved"]),
      bool_need(["approvals", "data_retention_reviewed"])
    ] + ($provider_required | map(. as $path | ($profile | need($path)))) | .[]
  ' "$file"
}

_aap_demo_cloud_profile_safe() {
  local file="$1"
  jq -e '
    type == "object" and .schema_version == 1 and
    (.provider | type == "string") and
    ([paths(scalars) as $path |
      ($path[-1] | tostring) as $key |
      select(($key | test("(^|_)(password|secret|token|access_?key|private_?key)($|_)"; "i")) and
             ($key | endswith("_ref") | not))] | length == 0) and
    ([.identity_refs[]? | select(type != "string" or test("^(aap_demo\\.|external:)"; "") | not)] | length == 0) and
    (.nodes.aap.count | type == "number" and . >= 1) and
    (.nodes.fleet.count | type == "number" and . >= 0) and
    (.nodes.satellite.enabled | type == "boolean") and
    (.nodes.satellite.count | type == "number" and . >= 0)
  ' "$file" >/dev/null
}

_aap_demo_cloud_validate() {
  local file="$1" problems
  [ -f "$file" ] || { _err "Cloud profile does not exist: $file"; return 1; }
  if ! _aap_demo_cloud_profile_safe "$file"; then
    _err "Cloud profile has an invalid schema, a plaintext secret-like field, or an invalid identity reference"
    return 1
  fi
  problems=$(_aap_demo_cloud_profile_problems "$file") || return 1
  if [ -n "$problems" ]; then
    _err "Cloud profile is incomplete; resolve these fields before any provider adapter can run:"
    sed 's/^/  - /' <<<"$problems" >&2
    return 1
  fi
  printf 'PASS: cloud profile is complete and contains identity references only: %s\n' "$file"
}

_aap_demo_cloud_requirements() {
  local provider="$1"
  _aap_demo_cloud_provider_valid "$provider" || {
    _err "Provider must be one of: aws, azure, gcp, vmware"
    return 1
  }
  cat <<EOF
Cloud/VMware requirements for ${provider}

Common: named customer/operator/approval contacts; a private DNS zone; separate
AAP, Fleet, and Satellite subnets; private management paths; RHEL entitlement;
an AAP node, three Fleet nodes, and an optional Satellite node; explicit data
retention and chargeable-resource approval. Do not expose the dashboard or
management SSH publicly.
EOF
  case "$provider" in
    aws)
      cat <<'EOF'
AWS: account, region/AZ, VPC, private subnets, security groups, a least-privilege
provisioner role, and an EC2 instance profile for workloads. Prefer federation
or IAM Identity Center for the operator and temporary instance-role credentials.
EOF
      ;;
    azure)
      cat <<'EOF'
Azure: tenant, subscription, resource group, region, VNet/subnets, network
security groups, least-privilege Azure RBAC, and managed identities for workloads.
Prefer Azure CLI/federated operator access rather than a client secret.
EOF
      ;;
    gcp)
      cat <<'EOF'
GCP: project, region/zone, VPC/subnets, narrow firewall policy, least-privilege
IAM, and a user-managed service account for workloads. Prefer workload identity
or application-default credentials rather than service-account key files.
EOF
      ;;
    vmware)
      cat <<'EOF'
VMware: trusted vCenter URL and certificate fingerprint, datacenter, cluster,
datastore, port group, compatible template, VMware Tools readiness, and a
least-privilege vCenter role. Validate placement and datastore capacity first.
EOF
      ;;
  esac
}

cmd_cloud() {
  local action="${1:-requirements}" provider="${2:-}" file="${3:-}" force="${4:-}"
  case "$action" in
    help | --help | -h) _aap_demo_cloud_usage ;;
    requirements)
      [ -n "$provider" ] || { _aap_demo_cloud_usage >&2; return 2; }
      _aap_demo_cloud_requirements "$provider"
      ;;
    profile)
      case "$provider" in
        init)
          provider="$file"
          file="${4:-}"
          force="${5:-}"
          _aap_demo_cloud_provider_valid "$provider" && [ -n "$file" ] || {
            _aap_demo_cloud_usage >&2; return 2;
          }
          if [ -e "$file" ] && [ "$force" != "--force" ]; then
            _err "Refusing to overwrite cloud profile: $file (use --force after review)"
            return 1
          fi
          mkdir -p "$(dirname "$file")" || return 1
          umask 077
          _aap_demo_cloud_template "$provider" >"$file" || return 1
          chmod 600 "$file"
          printf 'Created local-only %s planning profile: %s\n' "$provider" "$file"
          printf 'Fill only non-secret values, then run: aap-demo cloud profile validate %s\n' "$file"
          ;;
        validate)
          file="$file"
          [ -n "$file" ] || { _aap_demo_cloud_usage >&2; return 2; }
          _aap_demo_cloud_validate "$file"
          ;;
        *) _aap_demo_cloud_usage >&2; return 2 ;;
      esac
      ;;
    plan)
      file="$provider"
      [ -n "$file" ] || { _aap_demo_cloud_usage >&2; return 2; }
      _aap_demo_cloud_validate "$file" || return 1
      printf 'PLAN ONLY: no provider API call, authentication, resource creation, or charge was performed.\n'
      printf 'A future adapter must still run provider discovery and require a separate apply approval.\n'
      ;;
    *) _aap_demo_cloud_usage >&2; return 2 ;;
  esac
}
