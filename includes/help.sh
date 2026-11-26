#!/usr/bin/env bash
# =============================================================================
# help.sh — show_help command (CLI usage/help text)
# =============================================================================
#
# Extracted from aap-demo.sh. Uses the grouped-by-task format validated by
# test/test-core-commands.sh; the addon list is printed from AVAILABLE_ADDONS
# via _help_print_addons (defined in aap-demo.sh) so it cannot drift.

# Guard against double-sourcing
if [ -n "${_AAP_DEMO_HELP_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_HELP_LOADED=1

show_help() {
  cat <<EOF
aap-demo - Deploy AAP ${AAP_VERSION:-2.7} to OpenShift Local

Usage: aap-demo [options] <command>

Cluster
  create            Create the OpenShift Local cluster
  start             Start a stopped cluster (re-applies CoreDNS config)
  stop              Stop the cluster
  restart           Restart the demo, using service recovery when configured
  service           Manage demo shutdown, backup, and startup recovery
  ssh               SSH into the cluster node
  console           Show or open the full OpenShift web console
  destroy           Delete the local cluster
  repair            Repair the cluster after a crash
  trust-ca          Repair ingress certificate trust only
  setup             Run setup only (storage, CoreDNS)
  storage [DISK_GB] [PV_GB]
                    Show or change the VM disk and persistent-volume size
                    Disk must be at least 31GB and the PV pool at least 15GB
  kubeconfig        Extract and merge kubeconfig
  redeploy-all      Destroy the cluster and redeploy fresh

AAP
  deploy            Deploy AAP ${AAP_VERSION:-2.7} (operator + CR)
  status            Show cluster and AAP status
  system-info       Export the environment inventory report
  watch             Watch deployment status
  idle              Scale AAP down or up
  clean             Remove the AAP deployment
  redeploy          Clean and redeploy AAP
  wire              Re-run addon wiring
  dashboard         Start the localhost dashboard
  maintenance       Preview or remove safe-to-delete VM data

Health
  preflight         Read-only tools, capacity, storage, and catalog checks
  diagnose          Check environment health
  check-integrations Inspect enabled integration connections without running jobs
  steward [scan|report]
                    Track sanitized read-only findings; no AI, repair, or ticket actions
  reports [generate|send] [--reconfigure]
                    Create a weekly HTML report and local captured email; no external delivery
  must-gather       Collect AAP and cluster diagnostics
  redhat-status     Check Red Hat registry status

Addons
  enable            Enable an addon
  disable           Disable an addon
  fleet             Manage fleet node VMs
  keycloak          Configure Keycloak OIDC for AAP and AO
  gpu               Inspect or configure NVIDIA GPU passthrough for MicroShift

Other
  config            Configure aap-demo settings
  credentials       Manage the optional offline-token keepalive
  update            Pull latest code and reinstall
  v2 [args...]      Run the Python v2 CLI (for example: aap-demo v2 deploy)
  version           Show version and build timestamp
  help              Show this help

Options
  --kubeconfig=FILE   Path to kubeconfig file (default: ~/.aap-demo/kubeconfig.microshift)
  --context=NAME      kubectl context to use (default: current context)
  --branch=NAME       Branch used by update
  --backend=NAME      Fleet backend: qemu, kube-native, or all
  --ansible           With create: build the complete AAP/AO/MCP/EDA/Fleet demo
  --full-demo         Compatibility alias for --ansible
  --satellite         With create: build the Satellite lab and demo (implies --ansible)
  --lightspeed        With create: enable Ansible Lightspeed with local Ollama (implies --ansible)
  --lightwell         With create: prepare the Lightwell CI/CD profile (implies --ansible,
                      --satellite, --lightspeed, and --gitea)
  --gitea, --gittea   Install/start a Fedora 45 Gitea VM outside CRC, using host NFS
                      Standalone or with create --full-demo; disable retains data
  --sno               With create: use Single Node OpenShift (full control plane +
                      web console); skips the tier prompt, fails if SNO minimums unmet
  --microshift        With create: use MicroShift (minimal edge runtime); skips the
                      tier prompt
  --show-secrets      Reveal credentials with interactive status only
  --no-import         With enable fleet --backend kube-native: skip AAP registration
  --refresh-catalog   Refresh supported addon catalogs
  --purge-data        Delete retained addon data when disabling
  --purge-creds       Delete retained addon credentials when disabling
  --apply             Apply a maintenance uninstall or GPU passthrough change

Environment
  NAMESPACE=<name>    Kubernetes namespace (default: aap-operator)
  QUIET=true          Suppress the disclaimer
  FORCE=true          Force reinstall even if AAP exists
  AAP_VERSION=2.6|2.7 AAP version to deploy (default: 2.7)
  AAP_DEMO_ALLOW_REMOTE_KUBECONFIG=true
                      Allow a remote kubeconfig context. Default is to
                      refuse, so oc login cannot retarget deploy or enable.
  AAP_DEMO_ANSIBLE    Use Ansible by default (true/false)
  AAP_PERSISTENT_IMAGE_STORE=true
                      Keep CRI-O image storage on a persistent qcow2 disk
                      (Linux/libvirt only; macOS uses the OCI image cache)
  AAP_IMAGE_STORE_DISK Path to the persistent image disk
  AAP_IMAGE_STORE_SIZE_GB  Persistent disk size (default: 60)
  AAP_IMAGE_STORE_FORMAT=true
                      Explicitly format a blank persistent disk once
  AO_LLM_PROVIDER=ollama|external|none
                      AO LLM provider selection

Notes
  idle                No argument shows state; true scales down; false scales up
  diagnose            Checks cluster, storage, SCCs, pod readiness, PVCs, HPA metrics, and DNS
  diagnose --ai       Analyze issues with Claude (requires the claude CLI)
  must-gather [dir]   Uses the AAP must-gather image. Output is
                      must-gather.local.<timestamp>, or the directory given
  destroy             --reset also clears config; --skip-cache skips the image cache
  status --json       Emit machine-readable status without secret values
  system-info [--redact] [--json] [--output FILE]
                      Export redacted, JSON, or custom-path inventory
  steward [scan|report] [--output FILE]
                      Record read-only findings in FIX_TRACKING.md; no repair or external action
  reports [generate|send] [--reconfigure]
                      Write polished HTML/text reports and a local captured email; no SMTP relay
  dashboard [--no-open]
                      Start the localhost dashboard without opening a browser
  console [--no-open] Show the console URL without opening a browser
  service install [--keep N] [--force-stop] [--stop-timeout SECONDS]
                      Install demo shutdown and startup recovery
  service retention N | backups | backup | status | disable
                      Manage service checkpoints and recovery
  credentials keepalive [setup|enable|status|disable|run]
                      Manage the opt-in offline-token keepalive
  credentials github [configure|status]
                      Store a GitHub PAT in the encrypted Vault and authenticate gh
  maintenance [--apply]
                      Preview or remove safe-to-delete VM data
  maintenance uninstall [--apply] [--reconfigure]
                      Remove CRC, Fleet, managed Satellite VM/disk, and local state.
                      --reconfigure also removes managed Vault entries.
                      Noninteractive apply requires
                      AAP_DEMO_UNINSTALL_CONFIRM=UNINSTALL with QUIET=true
  gpu [status|enable|disable] [--apply]
                      GPU enable stops/restarts CRC, assigns an isolated NVIDIA PCI
                      group, installs its guest runtime/device plugin, then verifies
                      Kubernetes advertises nvidia.com/gpu. Default: status.
  create --ansible    Build AAP, Product Demos, AO/Ollama/EDA, Fleet, and dashboard
  create --satellite  Adds the Satellite lab/demo
  create --lightwell  Adds Satellite, Lightspeed, retained Gitea, and Lightwell
  fleet               add, list, remove, destroy
                      --backend qemu|kube-native|all
                      add [N] --image <path> creates N RHEL VMs (requires: enable fleet)
                      (legacy Bash v1; local QEMU VMs only)
                      Kubernetes-native fleet: aap-demo fleet list (Kubernetes pod-backed nodes)
                      --no-import with --backend kube-native skips AAP registration
                      disable --backend kube-native delegates to the Python addon
  fleet auth [configure|status|reset]
                      Manage encrypted Red Hat credentials
  fleet add [count] --image <rhel9|rhel10|local-qcow2-path>
                      Download/cache an entitled image and create VMs
  fleet register      License AAP if needed, register nodes, and ping them
  fleet start         Start preserved Fleet VM overlays
  fleet ssh [index]   Open an admin SSH shell (default: node 1)
  fleet rhc-connect   Enroll running Fleet VMs in RHSM/Insights/remote management
  fleet satellite-register
                      Register running Fleet VMs to the Satellite lab (content
                      from local Pulp, hosts in the Satellite inventory)
  fleet list          List Fleet VM state
  fleet remove [count|name]
                      Deregister and remove newest or named VMs
  fleet destroy       Remove all Fleet VMs and AAP Fleet resources
  local-cache         save, load, or clear. Saves images from a running cluster
  keycloak configure  [--target aap|ao|all] [--map-groups] [--apply]
                      Dry-run unless --apply
                      --map-groups aligns Keycloak groups with AAP roles and AO groups
  aliases             deploy-all = deploy, rh-status = redhat-status

Available addons
EOF
  _help_print_addons
  cat <<EOF

Examples
  Choose the task you need below; do not run every group as one script.
  Text after # explains a command; you can type just the command before it.

  First deployment, step by step
    aap-demo create                       # Create the local cluster first
    aap-demo deploy                       # Install AAP into that cluster
    aap-demo watch                        # Follow progress; Ctrl+C stops watching
    aap-demo status                       # Find the web address and check readiness
    aap-demo status --show-secrets        # Reveal login details in your terminal
    Keep those credentials private; do not paste them into logs or messages.

  All-in-one demo instead of the manual deployment above (choose one)
    aap-demo create --ansible             # AAP, demo content, AO/Ollama/EDA, Fleet, dashboard
    aap-demo create --ansible --microshift
                                         # Choose the smaller MicroShift cluster
    aap-demo create --lightspeed --microshift
                                         # Ansible profile plus local-model Lightspeed
    aap-demo create --satellite --sno     # Includes the required Ansible profile
                                         # Full OpenShift console plus the Satellite lab
    aap-demo create --lightwell --microshift
                                         # Ansible, Satellite, Lightspeed, Gitea, and Lightwell
    aap-demo --gitea                      # Start only the retained local Gitea VM
    Satellite requires Red Hat subscriptions and a Linux KVM/libvirt host.
    Reruns reuse Satellite, but maintenance can stop services and reboot its VM.
    Maintenance uses one managed libvirt checkpoint, retained only on failure.
  Optional addons, after AAP is deployed (choose only what you need)
    aap-demo enable                       # List the available addons
    aap-demo enable portal                # Add the self-service portal
    aap-demo enable mcp-server            # Expose AAP tools to AI assistants
    aap-demo enable ollama                # Add the local language-model service
    aap-demo enable eda                   # Add Event-Driven Ansible; no event source/activation
    aap-demo enable ao                    # Add Automation Orchestrator
    aap-demo enable openshift-delivery    # Optional GitOps and Pipelines operators
    aap-demo enable openshift-security    # Optional RHACS Operator prerequisite only
    aap-demo enable openshift-quay        # Optional Red Hat Quay Operator prerequisite only
    aap-demo enable openshift-acm         # Optional ACM Operator prerequisite only
    LIGHTWELL_APP_NODE=4 aap-demo enable lightwell --prepare
                                         # Prepare Lightwell resources for dedicated Fleet node 4
    aap-demo enable product-demos         # Install the non-Satellite demo content
    PRODUCT_DEMOS_ENABLE_EDA=true aap-demo enable product-demo-eda
                                         # Import guarded EDA templates after external prerequisites

  Add three RHEL practice machines (Fleet uses local QEMU VMs)
    aap-demo fleet auth                   # Securely configure Red Hat credentials
    aap-demo enable fleet                 # Enable Fleet before adding machines
    aap-demo fleet add 3 --image rhel9     # Download/cache RHEL 9 and create three VMs
    aap-demo fleet list                   # Check machine names and running state
    aap-demo fleet start                  # Start any preserved, stopped Fleet VMs
    aap-demo fleet register               # License AAP if needed, add hosts, test access
    aap-demo fleet ssh 1                  # Open node 1's admin shell; exit to return
    RHEL image downloads require an entitled Red Hat account.

  Connect an existing Satellite lab
    aap-demo enable satellite-manifest    # Generate/download a manifest; no import here
    aap-demo fleet satellite-register     # Register running Fleet nodes to Satellite
    aap-demo wire                         # Reconcile installed components and integrations
    The create --satellite profile also imports the manifest automatically.
    Satellite registration can migrate Fleet nodes away from direct Red Hat registration.

  Daily use: save resources without deleting your environment
    aap-demo idle                         # Check whether AAP is currently scaled down
    aap-demo idle true                    # Scale AAP down to save memory
    aap-demo idle false                   # Scale AAP back up
    aap-demo stop                         # Stop the local cluster
    aap-demo start                        # Resume the cluster and configured demo
    aap-demo dashboard                    # Open the local management dashboard
    aap-demo gpu status                    # Inspect NVIDIA GPU availability for MicroShift
    aap-demo gpu enable --apply            # Configure approved GPU passthrough; restarts CRC

  Check a problem before rebuilding
    aap-demo preflight                    # Check tools, capacity, storage, and catalogs
    aap-demo diagnose                     # Check workload, storage, and DNS health
    aap-demo must-gather                  # Save diagnostic files for troubleshooting
    aap-demo maintenance                  # Preview reclaimable VM data; deletes nothing
    Review diagnostic files before sharing them; they may contain sensitive details.

  Remove or rebuild only when you intend to lose the existing deployment
    WARNING: These operations remove resources/data. Back up anything you need first.
    aap-demo clean                        # Remove AAP but keep the cluster
    aap-demo redeploy-all                 # Delete the cluster and rebuild the deployment
    aap-demo destroy                      # Delete the local cluster

  More step-by-step guides:
    https://github.com/RedHatOfficial/aap-demo/blob/main/docs/guides/older-command.md

Requirements
  - OpenShift Local — https://console.redhat.com/openshift/create/local
  - On Linux: libvirt-daemon, libvirt-daemon-driver-storage, qemu-kvm

  For all deployments:
  - kubectl
  - Pull secret at ~/.aap-demo/pull-secret.txt (from console.redhat.com)
EOF
}
