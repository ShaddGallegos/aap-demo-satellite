#!/usr/bin/env bash

APD_SATELLITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

apd_satellite_is_lab() {
  [ "${SATELLITE_URL:-https://${SATELLITE_LAB_HOST:-satellite.demo.lab}}" = \
    "https://${SATELLITE_LAB_HOST:-satellite.demo.lab}" ]
}

apd_satellite_api() {
  local password="${SATELLITE_PASSWORD:-}"
  if [ -z "$password" ]; then
    password=$(aap_demo_vault_get aap_demo.satellite.admin_password) || return 1
  fi
  [ -n "$password" ] || { echo "ERROR: Satellite password is missing" >&2; return 1; }
  curl -fsS --connect-timeout 10 --max-time 60 \
    -u "${SATELLITE_USERNAME:-admin}:${password}" \
    "${SATELLITE_URL:-https://${SATELLITE_LAB_HOST:-satellite.demo.lab}}$1"
}

apd_discover_satellite_lab() {
  local response
  response=$(apd_satellite_api "/katello/api/content_views?per_page=1000") || return 1
  APD_SATELLITE_LAB=$(jq -ce --arg org "${SAT_ORG:-}" '
    if .subtotal > (.results | length) then error("Satellite content-view discovery is incomplete") else . end
    | [.results[] | select((.name == "RHEL9" or .name == "RHEL10")
        and (.repository_ids | length > 0) and .version_count > 0)
        | select($org == "" or .organization.name == $org)]
    | group_by(.organization_id)
    | if length != 1 then error("Expected one organization with published RHEL9/10 content; set SAT_ORG")
      else .[0] end
    | if any(.[]; .name == "RHEL9") | not then error("Published RHEL9 content is required for Fleet") else . end
    | {organization: .[0].organization,
       content_views: map({name, latest_version}),
       environments: ["DEV", "TEST", "PROD"]}
  ' <<<"$response") || {
    echo "ERROR: Cannot select a unique published Satellite lab content profile; configure content or set SAT_ORG." >&2
    return 1
  }
}

apd_satellite_template() {
  local encoded org_id
  encoded=$(jq -rn --arg name "$1" '$name | @uri')
  org_id=$(apd_apd_org_id) || return 1
  curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/job_templates/?name=${encoded}&organization=${org_id}" \
    | jq -ce 'if .count == 1 then .results[0] else error("Expected one APD Satellite template") end'
}

apd_stage_satellite_lab_playbooks() {
  local playbook org_id
  org_id=$(apd_apd_org_id) || return 1
  APD_SATELLITE_PROJECT_ID=$(curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/projects/?name=Ansible%20Product%20Demos&organization=${org_id}" \
    | jq -er 'if .count == 1 then .results[0].id else error("Expected one APD project") end') || return 1
  apd_overlay_project_playbook "$APD_PROJECT_ID" \
    "$APD_SATELLITE_DIR/playbooks/install-satellite-lab.yml" install-satellite-lab.yml || return 1
  apd_register_project_playbooks "$APD_PROJECT_ID" install-satellite-lab.yml || return 1
  for playbook in setup-satellite-lab.yml register-satellite-lab.yml; do
    apd_overlay_project_playbook "$APD_SATELLITE_PROJECT_ID" \
      "$APD_SATELLITE_DIR/playbooks/$playbook" "$playbook" || return 1
  done
  apd_register_project_playbooks "$APD_SATELLITE_PROJECT_ID" \
    setup-satellite-lab.yml register-satellite-lab.yml || return 1
}

apd_install_satellite_lab() {
  local template_id job_id
  apd_stage_satellite_lab_playbooks || return 1
  template_id=$(apd_ensure_domain_job_template satellite "$APD_PROJECT_ID" "$APD_EE_ID" "$APD_CRED_ID") || return 1
  curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" -X PATCH \
    -H "Content-Type: application/json" -d '{"playbook":"install-satellite-lab.yml"}' \
    "${AAP_API}/job_templates/${template_id}/" >/dev/null || return 1
  job_id=$(curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" -X POST \
    "${AAP_API}/job_templates/${template_id}/launch/" | jq -er '.id') || return 1
  apd_monitor_job "$job_id" "Satellite lab demo install" 160
}

apd_configure_satellite_lab_templates() {
  local name template payload ca views
  views=$(jq -c '[.content_views[].name]' <<<"$APD_SATELLITE_LAB")
  ca=$(curl -fsS --connect-timeout 10 \
    "https://${SATELLITE_LAB_HOST:-satellite.demo.lab}/pub/katello-server-ca.crt") || return 1
  for name in "SETUP | Satellite" "SATELLITE | Publish Content View Version" \
    "SATELLITE | Promote Content View Version" "LINUX | Register with Satellite"; do
    template=$(apd_satellite_template "$name") || return 1
    payload=$(jq -cn --argjson template "$template" --argjson profile "$APD_SATELLITE_LAB" \
      --argjson project "$APD_SATELLITE_PROJECT_ID" --argjson ee "$APD_EE_ID" --arg ca "$ca" '
      ($template.extra_vars | if . == "" then {} else fromjson end) as $vars
      | {extra_vars: ($vars + {organization: $profile.organization.name})}
      | if $template.name == "SETUP | Satellite" then
          . + {project: $project, execution_environment: $ee, playbook: "setup-satellite-lab.yml",
            extra_vars: {satellite_organization: $profile.organization.name,
              satellite_lab_content_views: $profile.content_views,
              satellite_lab_environments: $profile.environments}}
        elif $template.name == "LINUX | Register with Satellite" then
          . + {project: $project, execution_environment: $ee, playbook: "register-satellite-lab.yml",
            extra_vars: ($vars + {org_id: $profile.organization.label, env: "DEV", satellite_lab_ca_pem: $ca})}
        elif $template.name == "SATELLITE | Publish Content View Version" then
          .extra_vars += {env: "DEV", lifecycle_environment: "DEV"}
        else . end
      | .extra_vars |= tojson
    ') || return 1
    curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" -X PATCH \
      -H "Content-Type: application/json" -d "$payload" \
      "${AAP_API}/job_templates/$(jq -r '.id' <<<"$template")/" >/dev/null || return 1
    if [ "$(jq -r '.survey_enabled' <<<"$template")" = true ]; then
      local survey
      survey=$(curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
        "${AAP_API}/job_templates/$(jq -r '.id' <<<"$template")/survey_spec/") || return 1
      survey=$(jq -c --argjson views "$views" '
        .spec |= map(
          if .variable == "content_view" then .choices = ($views | join("\n"))
          elif (.variable == "env" or .variable == "lifecycle_environment"
            or .variable == "current_lifecycle_environment") then .choices = "DEV\nTEST\nPROD"
          else . end)
      ' <<<"$survey") || return 1
      curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" -X POST \
        -H "Content-Type: application/json" -d "$survey" \
        "${AAP_API}/job_templates/$(jq -r '.id' <<<"$template")/survey_spec/" >/dev/null || return 1
    fi
  done
}

apd_sync_satellite_lab_inventory() {
  local org_id sources source_id job_id workflows node payload mapping inventory hosts host fleet_inventory variables
  org_id=$(apd_apd_org_id) || return 1
  sources=$(curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/inventory_sources/?name=Satellite%20Inventory&inventory__organization=${org_id}") || return 1
  source_id=$(jq -er 'if .count == 1 then .results[0].id else error("Expected one Satellite inventory source") end' \
    <<<"$sources") || return 1
  inventory=$(jq -r '.results[0].inventory' <<<"$sources")
  # Retain the AAP-reachable QEMU forwarding addresses, not each VM's private NAT IP.
  fleet_inventory=$(curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/inventories/?name=Fleet&organization=${DEFAULT_ORG_ID}" \
    | jq -er 'if .count == 1 then .results[0].id else error("Expected one Fleet inventory") end') || return 1
  hosts=$(curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/inventories/${fleet_inventory}/hosts/?page_size=200") || return 1
  jq -e '.count == (.results | length) and .count > 0' <<<"$hosts" >/dev/null || return 1
  mapping='{}'
  while IFS= read -r host; do
    variables=$(curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/hosts/$(jq -r '.id' <<<"$host")/variable_data/") || return 1
    mapping=$(jq -ce --arg name "$(jq -r '.name' <<<"$host")" --argjson vars "$variables" '
      if ($vars.ansible_host | type) != "string" or ($vars.ansible_port | type) != "number"
      then error("Fleet SSH forwarding variables are missing")
      else .[$name] = ($vars | {ansible_host, ansible_port}) end
    ' <<<"$mapping") || return 1
  done < <(jq -c '.results[]' <<<"$hosts")
  payload=$(jq -cn --argjson source "$(jq -c '.results[0]' <<<"$sources")" --argjson mapping "$mapping" '
    {update_on_launch: true, source_vars: (($source.source_vars | fromjson) + {
      compose: {
        ansible_host: ("(" + ($mapping | tojson) + ").get(inventory_hostname.split(\".\")[0], {}).get(\"ansible_host\", foreman_ipv4 | default(inventory_hostname))"),
        ansible_port: ("(" + ($mapping | tojson) + ").get(inventory_hostname.split(\".\")[0], {}).get(\"ansible_port\", 22)"),
        ansible_user: "\"ansible\""
      }
    } | tojson)}
  ') || return 1
  curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" -X PATCH \
    -H "Content-Type: application/json" -d "$payload" \
    "${AAP_API}/inventory_sources/${source_id}/" >/dev/null || return 1
  job_id=$(curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" -X POST \
    "${AAP_API}/inventory_sources/${source_id}/update/" | jq -er '.id') || return 1
  apd_wait_satellite_inventory "$job_id" || return 1
  workflows=$(curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/workflow_job_templates/?name=Patch%20Dev&organization=${org_id}") || return 1
  local workflow_id
  workflow_id=$(jq -er 'if .count == 1 then .results[0].id else error("Expected one Patch Dev workflow") end' \
    <<<"$workflows") || return 1
  workflows=$(curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/workflow_job_templates/${workflow_id}/workflow_nodes/?page_size=100") || return 1
  jq -e '.count == (.results | length)' <<<"$workflows" >/dev/null || return 1
  while IFS= read -r node; do
    payload=$(jq -c '{extra_data: (.extra_data
      | if has("content_view") then .content_view = "RHEL9" else . end
      | if has("_hosts") then ._hosts = "env_DEV" else . end
      | if has("feedback") then .feedback |= gsub("RHEL8_Dev"; "DEV") else . end)}' <<<"$node") || return 1
    curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" -X PATCH \
      -H "Content-Type: application/json" -d "$payload" \
      "${AAP_API}/workflow_job_template_nodes/$(jq -r '.id' <<<"$node")/" >/dev/null || return 1
  done < <(jq -c '.results[]' <<<"$workflows")
}

apd_wire_satellite_credentials() {
  local sat_url="${SATELLITE_URL:-https://${SATELLITE_LAB_HOST:-satellite.demo.lab}}"
  local sat_user="${SATELLITE_USERNAME:-admin}" sat_pass="${SATELLITE_PASSWORD:-}"
  if [ -z "$sat_pass" ]; then
    sat_pass=$(aap_demo_vault_get aap_demo.satellite.admin_password) || return 1
  fi
  [ -n "$sat_pass" ] || { echo "ERROR: Satellite admin password is missing" >&2; return 1; }
  local org_id name credential_id
  org_id=$(apd_apd_org_id) || return 1
  [ -n "$org_id" ] || { echo "ERROR: APD organization is missing" >&2; return 1; }
  echo "Wiring Satellite credentials to ${sat_url}..."
  for name in "Satellite Credential" "Satellite Inventory"; do
    credential_id=$(apd_find_apd_credential_by_name "$name" "$org_id") || return 1
    [ -n "$credential_id" ] || { echo "ERROR: $name is missing" >&2; return 1; }
    curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" -X PATCH \
      -H "Content-Type: application/json" \
      -d "$(jq -cn --arg host "$sat_url" --arg username "$sat_user" --arg password "$sat_pass" \
        '{inputs: {host: $host, username: $username, password: $password}}')" \
      "${AAP_API}/credentials/${credential_id}/" >/dev/null || return 1
    echo "  ✓ $name -> $sat_url"
  done
}

apd_wait_satellite_inventory() {
  local job_id="$1" attempt response status
  for attempt in $(seq 1 160); do
    response=$(curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      "${AAP_API}/inventory_updates/${job_id}/") || return 1
    status=$(jq -er '.status' <<<"$response") || return 1
    case "$status" in
      successful) echo "✓ Satellite inventory sync completed (ID: $job_id)"; return 0 ;;
      failed | error | canceled)
        echo "ERROR: Satellite inventory sync ${status} (ID: $job_id)" >&2; return 1 ;;
    esac
    sleep 3
  done
  echo "ERROR: Timed out waiting for Satellite inventory sync (ID: $job_id)" >&2
  return 1
}

apd_wire_satellite_lab_machine_credential() {
  local credential org_id payload
  org_id=$(apd_apd_org_id) || return 1
  credential=$(curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/credentials/?name=APD%20Machine%20Credential&organization=${org_id}" \
    | jq -ce 'if .count == 1 then .results[0] else error("Expected one APD machine credential") end') || return 1
  if jq -e '(.inputs.ssh_key_data // "") != ""
    and .description != "Managed by aap-demo Satellite lab"' <<<"$credential" >/dev/null; then
    echo "ERROR: APD Machine Credential has a custom SSH key; refusing to replace it automatically." >&2
    return 1
  fi
  payload=$(jq -cn --rawfile key "${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet/ssh_key" '
    {description: "Managed by aap-demo Satellite lab",
      inputs: {username: "ansible", ssh_key_data: $key, become_method: "sudo"}}
  ') || return 1
  curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" -X PATCH \
    -H "Content-Type: application/json" -d "$payload" \
    "${AAP_API}/credentials/$(jq -r '.id' <<<"$credential")/" >/dev/null
}

apd_register_satellite_lab_fleet() {
  local SAT_ORG SAT_ORG_LABEL SAT_FLEET_LCE=DEV SAT_FLEET_CV=RHEL9
  SAT_ORG=$(jq -r '.organization.name' <<<"$APD_SATELLITE_LAB")
  SAT_ORG_LABEL=$(jq -r '.organization.label' <<<"$APD_SATELLITE_LAB")
  export SAT_ORG SAT_ORG_LABEL SAT_FLEET_LCE SAT_FLEET_CV
  apd_wire_satellite_lab_machine_credential || return 1
  bash "$APD_SATELLITE_DIR/../../aap-demo.sh" fleet register || return 1
  bash "$APD_SATELLITE_DIR/../../aap-demo.sh" fleet satellite-register
}

apd_complete_satellite_install() {
  local install_rc="$1" template_count

  if apd_satellite_is_lab; then
    [ "$install_rc" -eq 0 ] || return "$install_rc"
    apd_configure_satellite_lab_templates || return 1
  else
    [ "$install_rc" -ne 0 ] || return 0
  fi

  echo "  Running Satellite setup with the wired credentials and content profile..."
  if ! apd_rerun_satellite_setup; then
    echo "  ERROR: Satellite setup failed after retry; the addon is not ready." >&2
    return 1
  fi

  if ! template_count=$(curl -fsSk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/job_templates/?name__startswith=SATELLITE" \
    | jq -er '.count | select(type == "number" and . > 0)'); then
    echo "  ERROR: Satellite setup succeeded but Satellite templates could not be verified." >&2
    return 1
  fi
  echo "  ✓ Satellite setup succeeded and ${template_count} Satellite template(s) are present"
  if apd_satellite_is_lab; then
    apd_register_satellite_lab_fleet || return 1
    apd_sync_satellite_lab_inventory || return 1
  fi
}
