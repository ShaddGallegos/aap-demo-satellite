#!/usr/bin/env bash
# =============================================================================
# help.sh — show_help command (CLI usage/help text)
# =============================================================================
#
# Extracted from aap-demo.sh. Self-contained; no external function deps.

# Guard against double-sourcing
if [ -n "${_AAP_DEMO_HELP_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_HELP_LOADED=1

show_help() {
  cat <<'EOF'
aap-demo - Deploy AAP 2.7 to OpenShift Local

USAGE:
    aap-demo [OPTIONS] <COMMAND>

OPTIONS:
    --kubeconfig FILE, --kubeconfig=FILE  Kubeconfig path
    --context NAME, --context=NAME        kubectl context
    --branch NAME, --branch=NAME          Branch used by update
    --json                                Emit JSON for status or system-info
    --redact                              Mask secrets in system-info output
    --output FILE, --output=FILE          Write system-info to a custom path
    --no-open                             Do not open a browser for dashboard
    --full-demo                           Build the complete local demo with create
    --satellite                           With create --full-demo: also build and configure the
                                          Satellite lab (Satellite Build and Configure), then
                                          install the Satellite Demo content
    --show-secrets                        Reveal credentials with interactive status only
    --ai                                  Enable AI diagnosis for diagnose
    --reset                               Clear config after destroy
    --skip-cache                          Do not save images during destroy
    --force                               Force supported reinstall operations
    --refresh-catalog                     Refresh supported addon catalogs
    --purge-data                          Delete retained addon data when disabling
    --purge-creds                         Delete retained addon credentials
    -h, --help                            Show this help
    -V, --version                         Show version and build timestamp

CORE COMMANDS:
    deploy | deploy-all             Deploy AAP 2.7; create cluster if needed
    status                          Show cluster, AAP, addons, routes, and Fleet
    status --show-secrets           Reveal login credentials in an interactive terminal
    status --json                   Emit machine-readable status without secret values
    system-info                     Refresh the private Markdown environment report
    system-info [--redact] [--json] [--output FILE]
                                    Export redacted, JSON, or custom-path inventory
    dashboard [--no-open]           Start the localhost dashboard in the background
    console [--no-open]             Show/open the OpenShift web console (CRC_PRESET=openshift only)
    watch                           Watch AAP deployment progress
    clean                           Remove AAP while keeping the cluster
    maintenance [--apply]           Preview or remove safe-to-delete VM data
    maintenance uninstall [--apply] [--reconfigure]
                                    Remove all aap-demo state/settings; preserve source, shared tools,
                                    and the credential Vault (--reconfigure also strips the
                                    aap_demo Vault entries so the next create re-prompts)
    credentials keepalive [setup|enable|status|disable|run]
                                    Manage opt-in offline-token keepalive
    redeploy                        Clean and redeploy AAP
    redeploy-all                    Destroy and rebuild cluster, AAP, and configured addons
    idle [true|false]               Show, scale down, or scale up AAP components
    preflight                       Read-only tools, capacity, storage, and catalog checks
    diagnose [--ai]                 Run health checks; optionally add AI analysis
    must-gather [directory]         Collect AAP and cluster diagnostics
    wire                            Reapply AAP, AO, MCP, Ollama, and addon integrations
    config                          Configure project settings
    redhat-status | rh-status       Check Red Hat registry status
    update [--branch NAME]          Update source and reinstall the CLI
    version                         Show version and build timestamp
    help                            Show this help

CLUSTER COMMANDS:
    create                          Create the OpenShift Local cluster
    create --full-demo              Create AAP, PAH/Product Demos, AO/Ollama, Fleet, and dashboard
    create --full-demo --satellite  Also build/configure the Satellite lab and Satellite Demo
    destroy [--reset] [--skip-cache]
                                    Delete the cluster and optionally config/cache
    stop                            Stop Fleet VMs and the cluster
    start                           Resume AAP, enabled addons and Fleet; wait for readiness
    restart                         Restart demo; save/restore state when service-managed
    service install [--keep N]      Install Linux shutdown/boot or macOS checkpoint/login recovery
      --force-stop                 Linux only: force CRC off after graceful-stop failure
      --stop-timeout SECONDS        Additional wait before forced stop (default: 120)
    service retention N            Keep N completed states (default: 1)
    service backups                List completed backups
    service backup                 Save current state and resume the demo
    service status                 Show platform recovery service status
    service disable                Save state, stop demo, and disable boot restore
    repair                          Repair cluster state after a crash
    setup                           Configure storage, DNS, and local certificate trust
    ssh                             Open a shell on the cluster node
    kubeconfig                      Extract and merge kubeconfig

ADDON COMMANDS:
    enable <addon> [addon-options]  Enable and persist an addon
    disable <addon> [--purge-data] [--purge-creds]
                                    Disable an addon

    Available addons:
      fleet                  Local RHEL QEMU managed nodes
      mcp-server             AAP MCP server; required by AO
      ao                     Automation Orchestrator
      ollama                 Local qwen2.5:3b LLM provider for AO
      setup-pah              Configure Private Automation Hub
      portal                 Helm self-service portal
      portal-operator        AAP Portal Operator Technology Preview (AMD64 only)
      apme-eap               APME early-access portal
      product-demos          Non-Satellite Ansible Product Demos
      product-demo-satellite Satellite demo; requires an external Satellite server
      opa                    Open Policy Agent integration
      local-cache            Local container image cache

    local-cache actions:
      aap-demo enable local-cache [save|load|clear]

FLEET COMMANDS:
    fleet auth [configure|status|reset]
                                    Manage encrypted Red Hat credentials
    fleet add [count] --image <rhel9|rhel10|local-qcow2-path>
                                    Download/cache an entitled image and create VMs
    fleet register                  License AAP if needed, register nodes, and ping them
                                    Uses a saved subscription ID or first entitled subscription
    fleet rhc-connect               Enroll running Fleet VMs in RHSM/Insights/remote management
    fleet start                     Start preserved Fleet VM overlays
    fleet ssh [index]               Open an admin SSH shell (default: node 1)
    fleet list                      List Fleet VM state
    fleet remove [count|name]       Deregister and remove newest or named VMs
    fleet destroy                   Remove all Fleet VMs and AAP Fleet resources

SATELLITE LAB:
    The satellite-lab builds a Satellite 6 demo VM on this host and wires it
    into AAP. Prerequisites: Red Hat credentials in the Vault (aap-demo fleet
    auth) and, for the fully automatic path, the host registered with RHSM.
    Install media: RHEL_INSTALL_SOURCE=netboot (default recommended; no ISO —
    boots the kernel/initrd straight from the CDN using the host entitlement),
    dvd (rhel-9.5-x86_64-dvd.iso, offline), or cdn (rhel-9.5-x86_64-boot.iso).
    The subscription manifest is generated automatically by the
    satellite-manifest addon.

    create --full-demo --satellite  Build AAP + the full Satellite lab and demo
    enable satellite-manifest       Generate/download the Satellite manifest only
    enable product-demo-satellite   Install the Satellite demo content in AAP

    Manual stage-by-stage control (see satellite-lab/README.md):
      sudo satellite-lab/00-network-setup.sh        # satlab network
      sudo satellite-lab/01-provision-satellite-vm.sh  # provision the VM
      satellite-lab/build-and-configure.sh          # orchestrate the full build

CREDENTIALS:
    status --show-secrets           Show login passwords only in an interactive terminal
    fleet auth                      Configure Customer Portal token and CDN credentials
                                    Token: https://access.redhat.com/management/api
    enable setup-pah                Configure the distinct Automation Hub token
                                    Token: https://console.redhat.com/ansible/automation-hub/token
    credentials keepalive enable    Validate configured offline tokens daily
    credentials keepalive setup     Store a validated Hub token and enable four-day cron

    Retained credentials are stored under aap_demo in encrypted:
      ~/.ansible/conf/env.yml
    Customer Portal and Automation Hub tokens are separate and never reused.

ENVIRONMENT AND OVERRIDES:
    NAMESPACE=name                  AAP namespace (default: aap-operator)
    QUIET=true                      Disable interactive prompts where supported
    AAP_START_TIMEOUT=seconds       Readiness timeout per start phase (default: 600)
    FORCE=true                      Force supported reinstall operations
    CRC_DISK=GiB                    CRC VM disk; minimum preserves 100 GiB for images
    CRC_PV_SIZE=GiB                 LVMS PV area; adaptive default stays below CRC_DISK
    AAP_RESOURCE_PREFLIGHT_STRICT=true
                                    Fail preflight on insufficient capacity
    FLEET_NODE_MEM=MB               Memory per Fleet VM (default: 1024)
    FLEET_NODE_CPUS=N               CPUs per Fleet VM (default: 2)
    AO_LLM_PROVIDER=ollama|external|none
                                    AO LLM provider selection
    AO_LLM_BASE_URL=URL             External OpenAI-compatible endpoint
    AO_LLM_MODEL=NAME               External model name
    AO_IMPORT_DEMOS=0               Skip AO demo import
    AAP_PERSISTENT_IMAGE_STORE=true
                        Keep CRI-O image storage on a persistent qcow2 disk
                        (Linux/libvirt only; macOS uses the OCI image cache)
    AAP_IMAGE_STORE_DISK Path to the persistent image disk
    AAP_IMAGE_STORE_SIZE_GB  Persistent disk size (minimum/default: 100)
    AAP_IMAGE_STORE_FORMAT=true
                        Explicitly format a blank persistent disk once
    AAP_DEMO_UNINSTALL_CONFIRM=UNINSTALL
                        Required with QUIET=true for maintenance uninstall --apply

    At 90% filesystem usage, start grows the existing CRC disk by 20% using a
    brief stop/start. Data and PV reservations are preserved; no rebuild occurs.
    This check runs during start, not as a continuous background monitor.

EXAMPLES:
    aap-demo deploy
    aap-demo status
    aap-demo status --show-secrets
    aap-demo status --json
    aap-demo system-info
    aap-demo system-info --redact --output ./aap-support.md
    aap-demo system-info --json --redact
    aap-demo dashboard
    aap-demo diagnose
    aap-demo maintenance
    aap-demo maintenance uninstall
    aap-demo create --full-demo
    aap-demo create --full-demo --satellite
    aap-demo enable satellite-manifest
    aap-demo enable product-demo-satellite
    aap-demo enable fleet
    aap-demo fleet auth
    aap-demo fleet add 3 --image rhel9
    aap-demo fleet add 3 --image rhel10
    aap-demo fleet add 3 --image ~/rhel9.qcow2
    aap-demo fleet register
    aap-demo fleet start
    aap-demo enable ollama
    AO_LLM_PROVIDER=ollama aap-demo enable ao
    aap-demo wire
    aap-demo enable product-demos
    aap-demo enable opa
    aap-demo stop
    aap-demo start
    aap-demo redeploy-all

REQUIREMENTS:
    - OpenShift Local — https://console.redhat.com/openshift/create/local
    - On Linux: libvirt-daemon, libvirt-daemon-driver-storage, qemu-kvm

    For all deployments:
    - kubectl
    - Pull secret imported into encrypted ~/.ansible/conf/env.yml

EOF
}
