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
  aap-demo cloud preflight FILE [--aws-profile NAME|--gcloud-configuration NAME]

Providers: aws, azure, gcp, vmware

Profile and plan commands are local-only. AWS, GCP, Azure, and VMware preflight make
only documented read-only CLI calls when you explicitly invoke them; no cloud
command creates resources or incurs charges. A profile stores identity
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

_aap_demo_cloud_aws_call() {
  local aws_cli="$1" aws_profile="$2"
  shift 2
  local -a command=("$aws_cli")
  [ -z "$aws_profile" ] || command+=(--profile "$aws_profile")
  command+=("$@" --no-cli-pager --output json)
  "${command[@]}" 2>/dev/null
}

_aap_demo_cloud_aws_preflight() {
  local file="$1" aws_profile="$2" aws_cli
  local account_id region vpc_id instance_profile caller vpc dns_support dns_hostnames subnets groups profile_roles
  local -a subnet_ids group_ids

  _aap_demo_cloud_validate "$file" || return 1
  [ "$(jq -r '.provider' "$file")" = aws ] || {
    _err "AWS preflight requires an aws profile; this profile targets $(jq -r '.provider' "$file")"
    return 2
  }
  aws_cli="${AAP_DEMO_AWS_CLI:-aws}"
  command -v "$aws_cli" >/dev/null 2>&1 || {
    _err "AWS CLI is required for AWS preflight; install/configure it, then retry"
    return 1
  }
  account_id=$(jq -r '.provider_config.account_id' "$file")
  region=$(jq -r '.location.region' "$file")
  vpc_id=$(jq -r '.provider_config.vpc_id' "$file")
  instance_profile=$(jq -r '.provider_config.instance_profile' "$file")
  mapfile -t subnet_ids < <(jq -r '.provider_config.subnet_ids[]' "$file")
  mapfile -t group_ids < <(jq -r '.provider_config.security_group_ids[]' "$file")

  printf 'AWS read-only preflight: %s\n' "$file"
  caller=$(_aap_demo_cloud_aws_call "$aws_cli" "$aws_profile" sts get-caller-identity) || {
    _err "AWS identity check failed; authenticate with federation/SSO or select a usable --aws-profile"
    return 1
  }
  if ! jq -e --arg account "$account_id" '.Account == $account' <<<"$caller" >/dev/null; then
    _err "AWS caller account does not match the profile; no resources were changed"
    return 1
  fi
  printf '  PASS: caller identity matches the profile account\n'

  vpc=$(_aap_demo_cloud_aws_call "$aws_cli" "$aws_profile" ec2 describe-vpcs --region "$region" --vpc-ids "$vpc_id") || {
    _err "AWS VPC lookup failed; confirm read-only EC2 permissions and the profile region"
    return 1
  }
  if ! jq -e --arg vpc "$vpc_id" '[.Vpcs[]? | select(.VpcId == $vpc and .State == "available")] | length == 1' <<<"$vpc" >/dev/null; then
    _err "Configured VPC is missing or not available"
    return 1
  fi
  printf '  PASS: configured VPC exists and is available\n'

  dns_support=$(_aap_demo_cloud_aws_call "$aws_cli" "$aws_profile" ec2 describe-vpc-attribute --region "$region" --vpc-id "$vpc_id" --attribute enableDnsSupport) || {
    _err "AWS VPC DNS-support lookup failed"
    return 1
  }
  dns_hostnames=$(_aap_demo_cloud_aws_call "$aws_cli" "$aws_profile" ec2 describe-vpc-attribute --region "$region" --vpc-id "$vpc_id" --attribute enableDnsHostnames) || {
    _err "AWS VPC DNS-hostname lookup failed"
    return 1
  }
  if ! jq -e '.EnableDnsSupport.Value == true' <<<"$dns_support" >/dev/null \
    || ! jq -e '.EnableDnsHostnames.Value == true' <<<"$dns_hostnames" >/dev/null; then
    _err "Configured VPC must enable DNS support and DNS hostnames for private DNS readiness"
    return 1
  fi
  printf '  PASS: VPC DNS support and hostnames are enabled\n'

  subnets=$(_aap_demo_cloud_aws_call "$aws_cli" "$aws_profile" ec2 describe-subnets --region "$region" --subnet-ids "${subnet_ids[@]}") || {
    _err "AWS subnet lookup failed"
    return 1
  }
  if ! jq -e --arg vpc "$vpc_id" --argjson expected "$(jq -cn '$ARGS.positional' --args "${subnet_ids[@]}")" '
      [.Subnets[]? | select(.VpcId == $vpc and .State == "available" and .MapPublicIpOnLaunch == false) | .SubnetId] as $actual |
      ($expected | sort) == ($actual | sort)
    ' <<<"$subnets" >/dev/null; then
    _err "Every configured subnet must exist in the VPC, be available, and disable automatic public IP assignment"
    return 1
  fi
  printf '  PASS: configured subnets are private, available, and in the VPC\n'

  groups=$(_aap_demo_cloud_aws_call "$aws_cli" "$aws_profile" ec2 describe-security-groups --region "$region" --group-ids "${group_ids[@]}") || {
    _err "AWS security-group lookup failed"
    return 1
  }
  if ! jq -e --arg vpc "$vpc_id" --argjson expected "$(jq -cn '$ARGS.positional' --args "${group_ids[@]}")" '
      [.SecurityGroups[]? | select(.VpcId == $vpc) | .GroupId] as $actual |
      ($expected | sort) == ($actual | sort) and
      ([.SecurityGroups[]?.IpPermissions[]? | (.IpRanges[]?.CidrIp, .Ipv6Ranges[]?.CidrIpv6) |
        select(. == "0.0.0.0/0" or . == "::/0")] | length == 0)
    ' <<<"$groups" >/dev/null; then
    _err "Security groups must belong to the VPC and cannot allow public IPv4/IPv6 ingress"
    return 1
  fi
  printf '  PASS: configured security groups are VPC-scoped with no public ingress\n'

  profile_roles=$(_aap_demo_cloud_aws_call "$aws_cli" "$aws_profile" iam get-instance-profile --instance-profile-name "$instance_profile") || {
    _err "AWS instance-profile lookup failed"
    return 1
  }
  if ! jq -e --arg profile "$instance_profile" '.InstanceProfile.InstanceProfileName == $profile and
      ([.InstanceProfile.Roles[]?] | length) >= 1' <<<"$profile_roles" >/dev/null; then
    _err "Configured EC2 instance profile is missing or has no attached role"
    return 1
  fi
  printf '  PASS: configured instance profile exists with an attached role\n'
  printf 'PASS: AWS read-only preflight completed; no AWS resource was changed.\n'
}

_aap_demo_cloud_gcp_call() {
  local gcloud_cli="$1" gcloud_configuration="$2"
  shift 2
  local -a command=("$gcloud_cli")
  [ -z "$gcloud_configuration" ] || command+=(--configuration "$gcloud_configuration")
  command+=("$@" --format=json --quiet)
  "${command[@]}" 2>/dev/null
}

_aap_demo_cloud_gcp_preflight() {
  local file="$1" gcloud_configuration="$2" gcloud_cli
  local project region network_name service_account project_json network_json firewall_json account_json subnet_json subnet
  local private_google_access_warning=false
  local -a subnet_names

  _aap_demo_cloud_validate "$file" || return 1
  [ "$(jq -r '.provider' "$file")" = gcp ] || {
    _err "GCP preflight requires a gcp profile; this profile targets $(jq -r '.provider' "$file")"
    return 2
  }
  gcloud_cli="${AAP_DEMO_GCLOUD_CLI:-gcloud}"
  command -v "$gcloud_cli" >/dev/null 2>&1 || {
    _err "gcloud CLI is required for GCP preflight; install/authenticate it, then retry"
    return 1
  }
  project=$(jq -r '.provider_config.project_id' "$file")
  region=$(jq -r '.location.region' "$file")
  network_name=$(jq -r '.provider_config.network_name' "$file")
  service_account=$(jq -r '.provider_config.service_account' "$file")
  mapfile -t subnet_names < <(jq -r '.provider_config.subnet_names[]' "$file")

  printf 'GCP read-only preflight: %s\n' "$file"
  project_json=$(_aap_demo_cloud_gcp_call "$gcloud_cli" "$gcloud_configuration" projects describe "$project") || {
    _err "GCP project lookup failed; authenticate with gcloud or select a usable --gcloud-configuration"
    return 1
  }
  if ! jq -e --arg project "$project" '.projectId == $project and .lifecycleState == "ACTIVE"' <<<"$project_json" >/dev/null; then
    _err "Configured GCP project is missing or not active"
    return 1
  fi
  printf '  PASS: configured project exists and is active\n'

  network_json=$(_aap_demo_cloud_gcp_call "$gcloud_cli" "$gcloud_configuration" compute networks describe "$network_name" --project "$project") || {
    _err "GCP VPC lookup failed; confirm Compute Engine read permissions"
    return 1
  }
  if ! jq -e --arg network "$network_name" '.name == $network and .autoCreateSubnetworks == false' <<<"$network_json" >/dev/null; then
    _err "Configured GCP VPC must exist and use custom subnet mode"
    return 1
  fi
  printf '  PASS: configured VPC exists and uses custom subnet mode\n'

  for subnet in "${subnet_names[@]}"; do
    subnet_json=$(_aap_demo_cloud_gcp_call "$gcloud_cli" "$gcloud_configuration" compute networks subnets describe "$subnet" --project "$project" --region "$region") || {
      _err "GCP subnet lookup failed for $subnet"
      return 1
    }
    if ! jq -e --arg subnet "$subnet" --arg network "$network_name" '
        .name == $subnet and (.network | endswith("/networks/" + $network))
      ' <<<"$subnet_json" >/dev/null; then
      _err "Configured subnet $subnet is missing or belongs to another VPC"
      return 1
    fi
    if ! jq -e '.privateIpGoogleAccess == true' <<<"$subnet_json" >/dev/null; then
      private_google_access_warning=true
    fi
  done
  printf '  PASS: configured subnets exist in the selected VPC\n'
  if [ "$private_google_access_warning" = true ]; then
    printf '  WARN: Private Google Access is disabled on one or more subnets; verify NAT/proxy or private API egress before apply\n' >&2
  else
    printf '  PASS: Private Google Access is enabled on all configured subnets\n'
  fi

  firewall_json=$(_aap_demo_cloud_gcp_call "$gcloud_cli" "$gcloud_configuration" compute firewall-rules list --project "$project") || {
    _err "GCP firewall-rule lookup failed"
    return 1
  }
  if ! jq -e --arg network "$network_name" --arg service_account "$service_account" '
      [ .[]? |
        select((.network | endswith("/networks/" + $network)) and .direction == "INGRESS" and (.disabled != true)) |
        select((.targetServiceAccounts | length == 0 and (.targetTags | length == 0)) or
               (.targetServiceAccounts | index($service_account) != null)) |
        .sourceRanges[]? | select(. == "0.0.0.0/0" or . == "::/0")
      ] | length == 0
    ' <<<"$firewall_json" >/dev/null; then
    _err "GCP VPC firewall rules allow public ingress to the workload service account or all instances"
    return 1
  fi
  printf '  PASS: no public ingress applies to the workload service account or all VPC instances\n'

  account_json=$(_aap_demo_cloud_gcp_call "$gcloud_cli" "$gcloud_configuration" iam service-accounts describe "$service_account" --project "$project") || {
    _err "GCP workload service-account lookup failed"
    return 1
  }
  if ! jq -e --arg service_account "$service_account" '.email == $service_account and .disabled != true' <<<"$account_json" >/dev/null; then
    _err "Configured GCP workload service account is missing or disabled"
    return 1
  fi
  printf '  PASS: configured workload service account exists and is enabled\n'
  printf 'PASS: GCP read-only preflight completed; no GCP resource was changed.\n'
}

_aap_demo_cloud_azure_call() {
  local az_cli="$1" subscription="$2"
  shift 2
  local -a command=("$az_cli" "$@" --subscription "$subscription" --output json --only-show-errors)
  "${command[@]}" 2>/dev/null
}

_aap_demo_cloud_azure_preflight() {
  local file="$1" az_cli subscription tenant resource_group region vnet_name nsg_name identity_name dns_zone
  local account_json group_json vnet_json nsg_json dns_json dns_links identity_json subnet_json subnet nsg_id
  local -a subnet_names

  _aap_demo_cloud_validate "$file" || return 1
  [ "$(jq -r '.provider' "$file")" = azure ] || {
    _err "Azure preflight requires an azure profile; this profile targets $(jq -r '.provider' "$file")"
    return 2
  }
  az_cli="${AAP_DEMO_AZ_CLI:-az}"
  command -v "$az_cli" >/dev/null 2>&1 || {
    _err "Azure CLI is required for Azure preflight; install/authenticate it, then retry"
    return 1
  }
  subscription=$(jq -r '.provider_config.subscription_id' "$file")
  tenant=$(jq -r '.provider_config.tenant_id' "$file")
  resource_group=$(jq -r '.provider_config.resource_group' "$file")
  region=$(jq -r '.location.region' "$file")
  vnet_name=$(jq -r '.provider_config.vnet_name' "$file")
  nsg_name=$(jq -r '.provider_config.network_security_group' "$file")
  identity_name=$(jq -r '.provider_config.managed_identity' "$file")
  dns_zone=$(jq -r '.network.private_dns_zone' "$file")
  mapfile -t subnet_names < <(jq -r '.provider_config.subnet_names[]' "$file")

  printf 'Azure read-only preflight: %s\n' "$file"
  account_json=$(_aap_demo_cloud_azure_call "$az_cli" "$subscription" account show) || {
    _err "Azure account lookup failed; authenticate with az login and select the configured subscription"
    return 1
  }
  if ! jq -e --arg subscription "$subscription" --arg tenant "$tenant" '
      .id == $subscription and .tenantId == $tenant and .state == "Enabled"
    ' <<<"$account_json" >/dev/null; then
    _err "Azure signed-in tenant, subscription, or subscription state does not match the profile"
    return 1
  fi
  printf '  PASS: signed-in Azure tenant and subscription match the profile\n'

  group_json=$(_aap_demo_cloud_azure_call "$az_cli" "$subscription" group show --name "$resource_group") || {
    _err "Azure resource-group lookup failed"
    return 1
  }
  if ! jq -e --arg group "$resource_group" '.name | ascii_downcase == ($group | ascii_downcase)' <<<"$group_json" >/dev/null; then
    _err "Configured Azure resource group is missing"
    return 1
  fi
  printf '  PASS: configured resource group exists\n'

  vnet_json=$(_aap_demo_cloud_azure_call "$az_cli" "$subscription" network vnet show --resource-group "$resource_group" --name "$vnet_name") || {
    _err "Azure VNet lookup failed"
    return 1
  }
  if ! jq -e --arg vnet "$vnet_name" --arg region "$region" '
      (.name | ascii_downcase) == ($vnet | ascii_downcase) and (.location | ascii_downcase) == ($region | ascii_downcase)
    ' <<<"$vnet_json" >/dev/null; then
    _err "Configured Azure VNet is missing or in a different region"
    return 1
  fi
  printf '  PASS: configured VNet exists in the selected region\n'

  nsg_json=$(_aap_demo_cloud_azure_call "$az_cli" "$subscription" network nsg show --resource-group "$resource_group" --name "$nsg_name") || {
    _err "Azure network-security-group lookup failed"
    return 1
  }
  nsg_id=$(jq -r '.id // empty' <<<"$nsg_json")
  if [ -z "$nsg_id" ]; then
    _err "Configured Azure network security group is missing"
    return 1
  fi
  if ! jq -e '
      [.securityRules[]? | select(.direction == "Inbound" and .access == "Allow") |
       (.sourceAddressPrefix, .sourceAddressPrefixes[]?) |
       select(. == "*" or . == "Internet" or . == "0.0.0.0/0" or . == "::/0")
      ] | length == 0
    ' <<<"$nsg_json" >/dev/null; then
    _err "Azure NSG allows public inbound traffic; remove or narrow that custom rule before apply"
    return 1
  fi
  printf '  PASS: configured NSG has no custom public inbound allow rule\n'

  for subnet in "${subnet_names[@]}"; do
    subnet_json=$(_aap_demo_cloud_azure_call "$az_cli" "$subscription" network vnet subnet show --resource-group "$resource_group" --vnet-name "$vnet_name" --name "$subnet") || {
      _err "Azure subnet lookup failed for $subnet"
      return 1
    }
    if ! jq -e --arg subnet "$subnet" --arg nsg_id "$nsg_id" '
        (.name | ascii_downcase) == ($subnet | ascii_downcase) and
        ((.networkSecurityGroup.id // "") | ascii_downcase) == ($nsg_id | ascii_downcase)
      ' <<<"$subnet_json" >/dev/null; then
      _err "Configured subnet $subnet is missing or is not associated with the selected NSG"
      return 1
    fi
  done
  printf '  PASS: configured subnets exist and are associated with the selected NSG\n'

  dns_json=$(_aap_demo_cloud_azure_call "$az_cli" "$subscription" network private-dns zone show --resource-group "$resource_group" --name "$dns_zone") || {
    _err "Azure private-DNS-zone lookup failed"
    return 1
  }
  if ! jq -e --arg zone "$dns_zone" '.name == $zone' <<<"$dns_json" >/dev/null; then
    _err "Configured Azure private DNS zone is missing"
    return 1
  fi
  dns_links=$(_aap_demo_cloud_azure_call "$az_cli" "$subscription" network private-dns link vnet list --resource-group "$resource_group" --zone-name "$dns_zone") || {
    _err "Azure private-DNS VNet-link lookup failed"
    return 1
  }
  if ! jq -e --arg vnet "$vnet_name" '
      any(.[]?; (.virtualNetwork.id // "") | ascii_downcase | endswith("/virtualnetworks/" + ($vnet | ascii_downcase)))
    ' <<<"$dns_links" >/dev/null; then
    _err "Configured Azure private DNS zone is not linked to the selected VNet"
    return 1
  fi
  printf '  PASS: private DNS zone exists and is linked to the selected VNet\n'

  identity_json=$(_aap_demo_cloud_azure_call "$az_cli" "$subscription" identity show --resource-group "$resource_group" --name "$identity_name") || {
    _err "Azure user-assigned managed-identity lookup failed"
    return 1
  }
  if ! jq -e --arg identity "$identity_name" '.name == $identity and .type == "UserAssigned" and (.principalId | type == "string" and length > 0)' <<<"$identity_json" >/dev/null; then
    _err "Configured Azure user-assigned managed identity is missing or unusable"
    return 1
  fi
  printf '  PASS: configured user-assigned managed identity exists\n'
  printf 'PASS: Azure read-only preflight completed; no Azure resource was changed.\n'
}

_aap_demo_cloud_vmware_endpoint() {
  # Accept a normal GOVC_URL (which may contain credentials and an /sdk path),
  # but return only the lower-case host[:port] for a non-secret comparison.
  local endpoint="${1#*://}"
  endpoint="${endpoint##*@}"
  endpoint="${endpoint%%/*}"
  endpoint="${endpoint%.}"
  printf '%s' "${endpoint,,}"
}

_aap_demo_cloud_vmware_fingerprint() {
  # Accept the standard OpenSSL presentation as well as a bare SHA-256 value.
  sed -E 's/.*[Ff]ingerprint=//; s/^[Ss][Hh][Aa]256://' | tr -cd '[:xdigit:]' | tr '[:lower:]' '[:upper:]'
}

_aap_demo_cloud_vmware_json_nonempty() {
  jq -e '(type == "object" or type == "array") and length > 0' >/dev/null
}

_aap_demo_cloud_vmware_preflight() {
  local file="$1" govc_cli openssl_cli vcenter_url configured_endpoint govc_endpoint
  local datacenter cluster datastore port_group template expected_fingerprint observed_fingerprint
  local endpoint_host endpoint_connect about_json datacenter_json cluster_json datastore_json network_json template_json govc_insecure

  _aap_demo_cloud_validate "$file" || return 1
  [ "$(jq -r '.provider' "$file")" = vmware ] || {
    _err "VMware preflight requires a vmware profile; this profile targets $(jq -r '.provider' "$file")"
    return 2
  }
  govc_cli="${AAP_DEMO_GOVC_CLI:-govc}"
  openssl_cli="${AAP_DEMO_OPENSSL_CLI:-openssl}"
  command -v "$govc_cli" >/dev/null 2>&1 || {
    _err "govc is required for VMware preflight; install it and configure external GOVC_URL authentication"
    return 1
  }
  command -v "$openssl_cli" >/dev/null 2>&1 || {
    _err "openssl is required to verify the pinned VMware certificate fingerprint"
    return 1
  }
  govc_insecure="${GOVC_INSECURE:-false}"
  case "${govc_insecure,,}" in
    1 | true | yes)
      _err "VMware preflight refuses GOVC_INSECURE; configure trusted TLS or GOVC_TLS_CA_CERTS/GOVC_TLS_KNOWN_HOSTS"
      return 1
      ;;
  esac
  [ -n "${GOVC_URL:-}" ] || {
    _err "VMware preflight requires GOVC_URL from an external credential source; do not add credentials to the profile"
    return 1
  }

  vcenter_url=$(jq -r '.provider_config.vcenter_url' "$file")
  datacenter=$(jq -r '.provider_config.datacenter' "$file")
  cluster=$(jq -r '.provider_config.cluster' "$file")
  datastore=$(jq -r '.provider_config.datastore' "$file")
  port_group=$(jq -r '.provider_config.port_group' "$file")
  template=$(jq -r '.provider_config.template' "$file")
  expected_fingerprint=$(jq -r '.provider_config.certificate_sha256' "$file" | _aap_demo_cloud_vmware_fingerprint)
  configured_endpoint=$(_aap_demo_cloud_vmware_endpoint "$vcenter_url")
  govc_endpoint=$(_aap_demo_cloud_vmware_endpoint "$GOVC_URL")
  if [ -z "$configured_endpoint" ] || [ "$configured_endpoint" != "$govc_endpoint" ]; then
    _err "GOVC_URL host does not match the profile vCenter URL; no VMware inventory call was made"
    return 1
  fi
  if [ "${#expected_fingerprint}" -ne 64 ]; then
    _err "VMware profile certificate_sha256 must be a SHA-256 fingerprint"
    return 1
  fi
  endpoint_host="${configured_endpoint%%:*}"
  endpoint_connect="$configured_endpoint"
  case "$endpoint_connect" in *:*) ;; *) endpoint_connect="${endpoint_connect}:443" ;; esac

  printf 'VMware read-only preflight: %s\n' "$file"
  observed_fingerprint=$("$openssl_cli" s_client -connect "$endpoint_connect" -servername "$endpoint_host" </dev/null 2>/dev/null |
    "$openssl_cli" x509 -noout -fingerprint -sha256 2>/dev/null | _aap_demo_cloud_vmware_fingerprint) || {
    _err "Could not obtain the vCenter TLS certificate for the configured endpoint"
    return 1
  }
  if [ "$observed_fingerprint" != "$expected_fingerprint" ]; then
    _err "vCenter TLS certificate fingerprint does not match the profile; refusing inventory discovery"
    return 1
  fi
  printf '  PASS: vCenter certificate matches the pinned SHA-256 fingerprint\n'

  about_json=$("$govc_cli" about -json 2>/dev/null) || {
    _err "vCenter identity lookup failed; check externally supplied GOVC_URL credentials and least-privilege access"
    return 1
  }
  _aap_demo_cloud_vmware_json_nonempty <<<"$about_json" || {
    _err "vCenter identity lookup returned no usable JSON"
    return 1
  }
  printf '  PASS: authenticated to the configured vCenter over verified TLS\n'

  datacenter_json=$("$govc_cli" datacenter.info -json "$datacenter" 2>/dev/null) || {
    _err "VMware datacenter lookup failed for $datacenter"
    return 1
  }
  _aap_demo_cloud_vmware_json_nonempty <<<"$datacenter_json" || {
    _err "Configured VMware datacenter is missing"
    return 1
  }
  printf '  PASS: configured datacenter exists\n'

  cluster_json=$("$govc_cli" cluster.info -json -dc "$datacenter" "$cluster" 2>/dev/null) || {
    _err "VMware cluster lookup failed for $cluster"
    return 1
  }
  _aap_demo_cloud_vmware_json_nonempty <<<"$cluster_json" || {
    _err "Configured VMware cluster is missing"
    return 1
  }
  printf '  PASS: configured cluster exists\n'

  datastore_json=$("$govc_cli" datastore.info -json -dc "$datacenter" "$datastore" 2>/dev/null) || {
    _err "VMware datastore lookup failed for $datastore"
    return 1
  }
  if ! _aap_demo_cloud_vmware_json_nonempty <<<"$datastore_json" ||
    ! jq -e '[.. | objects | (.summary? // .Summary? // empty) | select(type == "object") | (.accessible? // .Accessible?)] | any(. == true)' <<<"$datastore_json" >/dev/null; then
    _err "Configured VMware datastore is missing or inaccessible"
    return 1
  fi
  printf '  PASS: configured datastore exists and is accessible\n'

  network_json=$("$govc_cli" find -json -dc "$datacenter" -type n -name "$port_group" 2>/dev/null) || {
    _err "VMware port-group lookup failed for $port_group"
    return 1
  }
  _aap_demo_cloud_vmware_json_nonempty <<<"$network_json" || {
    _err "Configured VMware port group is missing"
    return 1
  }
  printf '  PASS: configured port group exists\n'

  template_json=$("$govc_cli" vm.info -json -dc "$datacenter" "$template" 2>/dev/null) || {
    _err "VMware template lookup failed for $template"
    return 1
  }
  if ! jq -e '[.. | objects | (.config? // .Config? // empty) | select(type == "object") | (.template? // .Template?)] | any(. == true)' <<<"$template_json" >/dev/null; then
    _err "Configured VMware template is missing or is not marked as a template"
    return 1
  fi
  printf '  PASS: configured VM template exists and is marked as a template\n'
  printf 'PASS: VMware read-only preflight completed; no VMware resource was changed.\n'
}

_aap_demo_cloud_preflight() {
  local file="${1:-}" aws_profile="${AWS_PROFILE:-}" gcloud_configuration="${CLOUDSDK_ACTIVE_CONFIG_NAME:-}" argument provider
  shift || true
  [ -n "$file" ] || { _aap_demo_cloud_usage >&2; return 2; }
  [ -f "$file" ] || { _err "Cloud profile does not exist: $file"; return 1; }
  while [ "$#" -gt 0 ]; do
    argument="$1"
    shift
    case "$argument" in
      --aws-profile)
        [ "$#" -gt 0 ] || { _err "--aws-profile requires a value"; return 2; }
        aws_profile="$1"
        shift
        ;;
      --aws-profile=*) aws_profile="${argument#*=}" ;;
      --gcloud-configuration)
        [ "$#" -gt 0 ] || { _err "--gcloud-configuration requires a value"; return 2; }
        gcloud_configuration="$1"
        shift
        ;;
      --gcloud-configuration=*) gcloud_configuration="${argument#*=}" ;;
      *) _err "Unknown cloud preflight option: $argument"; return 2 ;;
    esac
  done
  provider=$(jq -r '.provider // empty' "$file" 2>/dev/null) || {
    _err "Cloud profile does not contain valid JSON: $file"
    return 1
  }
  case "$provider" in
    aws) _aap_demo_cloud_aws_preflight "$file" "$aws_profile" ;;
    gcp) _aap_demo_cloud_gcp_preflight "$file" "$gcloud_configuration" ;;
    azure) _aap_demo_cloud_azure_preflight "$file" ;;
    vmware) _aap_demo_cloud_vmware_preflight "$file" ;;
    *) _err "Read-only preflight is currently implemented only for AWS, GCP, Azure, and VMware"; return 2 ;;
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
    preflight)
      shift
      _aap_demo_cloud_preflight "$@"
      ;;
    *) _aap_demo_cloud_usage >&2; return 2 ;;
  esac
}
