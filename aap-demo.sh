#!/usr/bin/env bash
# =============================================================================
# aap-demo - AAP 2.7 Deployment Tool
# =============================================================================
#
# Deploy Ansible Automation Platform 2.7 to OpenShift Local.
#
# Usage:
#   ./aap-demo.sh                     # Deploy AAP 2.7
#   ./aap-demo.sh clean               # Remove AAP deployment
#   ./aap-demo.sh destroy             # Delete entire cluster
#   ./aap-demo.sh stop                # Stop OpenShift Local cluster
#   ./aap-demo.sh start               # Resume the configured demo and wait for readiness
#   ./aap-demo.sh repair              # Repair after crash
#   ./aap-demo.sh setup               # Setup only (no deploy)
#   ./aap-demo.sh create              # Create cluster only
#
# Environment variables:
#   NAMESPACE    - Kubernetes namespace (default: aap-operator)
#   QUIET        - Suppress disclaimer (true/false)
#   FORCE        - Force reinstall even if AAP exists (true/false)
#
# =============================================================================

set -e

_err() { printf '\033[0;31mERROR:\033[0m %s\n' "$*" >&2; }

trap '_err "aap-demo.sh failed unexpectedly at line $LINENO (exit code $?)"' ERR

# Resolve symlinks to get actual script directory
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# shellcheck source=includes/aap-demo-version.sh
source "${SCRIPT_DIR}/includes/aap-demo-version.sh"

# shellcheck source=includes/aap-demo-paths.sh
source "${SCRIPT_DIR}/includes/aap-demo-paths.sh"
# shellcheck source=includes/preset.sh
source "${SCRIPT_DIR}/includes/preset.sh"
# shellcheck source=includes/cmd-dashboard.sh
source "${SCRIPT_DIR}/includes/cmd-dashboard.sh"
# shellcheck source=includes/operation-lock.sh
source "${SCRIPT_DIR}/includes/operation-lock.sh"
# shellcheck source=includes/kubernetes-readiness.sh
source "${SCRIPT_DIR}/includes/kubernetes-readiness.sh"
# shellcheck source=includes/resource-preflight.sh
source "${SCRIPT_DIR}/includes/resource-preflight.sh"
# shellcheck source=includes/ao-llm.sh
source "${SCRIPT_DIR}/includes/ao-llm.sh"
# shellcheck source=includes/credential-vault.sh
source "${SCRIPT_DIR}/includes/credential-vault.sh"
# shellcheck source=includes/addon-restore.sh
source "${SCRIPT_DIR}/includes/addon-restore.sh"

# shellcheck source=includes/persistent-crio-store.sh
source "${SCRIPT_DIR}/includes/persistent-crio-store.sh"

# shellcheck source=includes/aap-readiness.sh
source "${SCRIPT_DIR}/includes/aap-readiness.sh"
# shellcheck source=includes/storage-capacity.sh
source "${SCRIPT_DIR}/includes/storage-capacity.sh"
# shellcheck source=includes/system-inventory.sh
source "${SCRIPT_DIR}/includes/system-inventory.sh"
# shellcheck source=includes/system-info-document.sh
source "${SCRIPT_DIR}/includes/system-info-document.sh"
# shellcheck source=includes/maintenance.sh
source "${SCRIPT_DIR}/includes/maintenance.sh"
# shellcheck source=includes/demo-start.sh
source "${SCRIPT_DIR}/includes/demo-start.sh"
# shellcheck source=includes/crc-storage.sh
source "${SCRIPT_DIR}/includes/crc-storage.sh"
# shellcheck source=includes/state-service.sh
source "${SCRIPT_DIR}/includes/state-service.sh"

# KUBECONFIG is set later by setup_kubeconfig() after argument parsing

# AAP version
# shellcheck disable=SC2034
AAP_VERSION="2.7"
AAP_CHANNEL="stable-2.7"

# Recommended CRC/MicroShift version for stable deployments
# Older versions may encounter VM transport or operator catalog issues.
CRC_RECOMMENDED_VERSION="4.22"

# Minimum CRC/MicroShift version threshold for deployment
# Default: 4.22 (avoids signature validation issues)
# Override to lower value to force deployment on older versions (advanced users only)
CRC_VERSION="${CRC_VERSION:-4.22}"

# Default values
_NAMESPACE_EXPLICIT="${NAMESPACE:+true}"
NAMESPACE="${NAMESPACE:-aap-operator}"
QUIET="${QUIET:-false}"
FORCE="${FORCE:-false}"

# Config file for persistent settings
AAP_DEMO_CONFIG="${AAP_DEMO_CONFIG:-$HOME/.aap-demo/config}"
AAP_DEMO_CONFIG_FILE="$AAP_DEMO_CONFIG"
export AAP_DEMO_CONFIG AAP_DEMO_CONFIG_FILE

# Source config file (command-line env vars take precedence)
if [ -f "$AAP_DEMO_CONFIG" ]; then
  while IFS='=' read -r key value || [ -n "$key" ]; do
    # Skip comments and empty lines
    [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
    # Only set if not already set in environment
    if [ -z "${!key+x}" ]; then
      export "$key=$value"
    fi
  done <"$AAP_DEMO_CONFIG"
fi

# Collection authentication environment variables
GALAXY_TOKEN_FILE="${GALAXY_TOKEN_FILE:-$AAP_DEMO_DIR/galaxy-token}"
PAH_CONFIG_FILE="${PAH_CONFIG_FILE:-$AAP_DEMO_DIR/pah-config.yml}"
SKIP_COLLECTIONS="${SKIP_COLLECTIONS:-false}"

# Infrastructure type (OpenShift Local only)
INFRA_TYPE="crc"
KUBECTL_CONTEXT=""
KUBECTL_KUBECONFIG=""

# Parse command line arguments
COMMAND=""
EXTRA_ARGS=()
PENDING_FLAG=""
OUTPUT_JSON=false
REDACT=false
SYSTEM_INFO_OUTPUT=""
DASHBOARD_NO_OPEN=false
MAINTENANCE_APPLY=false
FULL_DEMO=false
SHOW_SECRETS=false

for arg in "$@"; do
  if [ "$COMMAND" = service ]; then
    EXTRA_ARGS+=("$arg")
    continue
  fi
  # Handle pending flag value
  if [ -n "$PENDING_FLAG" ]; then
    case "$PENDING_FLAG" in
      branch)
        UPDATE_BRANCH="$arg"
        ;;
      context)
        KUBECTL_CONTEXT="$arg"
        ;;
      kubeconfig)
        KUBECTL_KUBECONFIG="$arg"
        ;;
      output)
        SYSTEM_INFO_OUTPUT="$arg"
        ;;
    esac
    PENDING_FLAG=""
    continue
  fi

  # shellcheck disable=SC2221,SC2222
  case "$arg" in
    --branch=*)
      UPDATE_BRANCH="${arg#*=}"
      ;;
    --branch)
      PENDING_FLAG="branch"
      ;;
    --context=*)
      KUBECTL_CONTEXT="${arg#*=}"
      ;;
    --context)
      PENDING_FLAG="context"
      ;;
    --kubeconfig=*)
      KUBECTL_KUBECONFIG="${arg#*=}"
      ;;
    --kubeconfig)
      PENDING_FLAG="kubeconfig"
      ;;
    --output=*)
      SYSTEM_INFO_OUTPUT="${arg#*=}"
      ;;
    --output)
      PENDING_FLAG="output"
      ;;
    --json)
      OUTPUT_JSON=true
      ;;
    --redact)
      REDACT=true
      ;;
    --no-open)
      DASHBOARD_NO_OPEN=true
      ;;
    --full-demo)
      FULL_DEMO=true
      ;;
    --show-secrets)
      SHOW_SECRETS=true
      ;;
    status)
      if [ "$COMMAND" = "fleet" ] && [ "${EXTRA_ARGS[0]:-}" = "auth" ]; then
        EXTRA_ARGS+=("$arg")
      elif [ "$COMMAND" = "credentials" ]; then
        EXTRA_ARGS+=("$arg")
      else
        COMMAND="$arg"
      fi
      ;;
    start | ssh)
      if [ "$COMMAND" = "fleet" ]; then
        EXTRA_ARGS+=("$arg")
      else
        COMMAND="$arg"
      fi
      ;;
    fleet)
      if [ "$COMMAND" = "enable" ] || [ "$COMMAND" = "disable" ]; then
        EXTRA_ARGS+=("$arg")
      elif [ -z "$COMMAND" ]; then
        COMMAND="fleet"
      else
        echo "Unknown argument for '$COMMAND': $arg"
        echo "Run '$0 help' for usage"
        exit 1
      fi
      ;;
    deploy | deploy-all | repair | clean | maintenance | credentials | stop | restart | service | setup | create | watch | update | config | redeploy | redeploy-all | redhat-status | rh-status | kubeconfig | idle | preflight | diagnose | must-gather | enable | disable | wire | system-info | dashboard | console | version | help | --help | -h | --version | -V)
      if [ "$COMMAND" = "credentials" ]; then
        EXTRA_ARGS+=("$arg")
      else
        case "$arg" in
          --version | -V) COMMAND="version" ;;
          *) COMMAND="$arg" ;;
        esac
      fi
      ;;
    destroy)
      # Fleet owns destroy as a subcommand; otherwise destroy is top-level.
      if [ "$COMMAND" = "fleet" ]; then
        EXTRA_ARGS+=("$arg")
      elif [ -n "$COMMAND" ]; then
        echo "Unknown argument for '$COMMAND': $arg"
        echo "Run '$0 help' for usage"
        exit 1
      else
        COMMAND="$arg"
      fi
      ;;
    --ai | --reset | --skip-cache | --force | --refresh-catalog | --purge-data | --purge-creds)
      # Flags for diagnose --ai, destroy --reset, addon deploy.sh options
      EXTRA_ARGS+=("$arg")
      ;;
    --apply)
      MAINTENANCE_APPLY=true
      ;;
    add | remove | list)
      # Subcommand args for fleet command
      EXTRA_ARGS+=("$arg")
      ;;
    mcp-server | portal | portal-operator | setup-pah | ao | ao-eap | apme-eap | local-cache | product-demos-base | product-demos | product-demo-linux | product-demo-windows | product-demo-network | product-demo-cloud | product-demo-openshift | product-demo-satellite | opa | ollama)
      # Addon names for enable/disable commands
      EXTRA_ARGS+=("$arg")
      ;;
    save | load | clear)
      if [ "$COMMAND" = "enable" ] || [ "$COMMAND" = "disable" ]; then
        EXTRA_ARGS+=("$arg")
      else
        echo "Unknown argument: $arg" >&2
        echo "Run 'aap-demo help' for usage" >&2
        exit 1
      fi
      ;;
    true | false)
      # Boolean args for idle command
      EXTRA_ARGS+=("$arg")
      ;;
    github)
      # Pass-through arg for config command
      EXTRA_ARGS+=("$arg")
      ;;
    *=*)
      # Handle KEY=VALUE arguments
      # shellcheck disable=SC2163
      export "$arg"
      ;;
    *)
      # Commands that accept arbitrary args
      if [ "$COMMAND" = "must-gather" ] || [ "$COMMAND" = "clean" ] \
        || [ "$COMMAND" = "fleet" ] || [ "$COMMAND" = "maintenance" ] \
        || [ "$COMMAND" = "credentials" ]; then
        EXTRA_ARGS+=("$arg")
      elif [ -n "$COMMAND" ]; then
        echo "Unknown argument for '$COMMAND': $arg"
        echo "Run '$0 help' for usage"
        exit 1
      else
        echo "Unknown argument: $arg"
        echo "Run '$0 help' for usage"
        exit 1
      fi
      ;;
  esac
done

# Check for unprocessed pending flag
if [ -n "$PENDING_FLAG" ]; then
  echo "ERROR: --$PENDING_FLAG requires a value"
  exit 1
fi

if [ "$OUTPUT_JSON" = true ] && [ "$COMMAND" != status ] && [ "$COMMAND" != system-info ]; then
  echo "ERROR: --json is supported only by status and system-info" >&2
  exit 1
fi
if [ "$SHOW_SECRETS" = true ]; then
  if [ "$COMMAND" != status ]; then
    echo "ERROR: --show-secrets is supported only by status" >&2
    exit 1
  fi
  if [ ! -t 1 ] || [ ! -r /dev/tty ]; then
    echo "ERROR: --show-secrets requires an interactive terminal" >&2
    exit 1
  fi
fi
if [ "$REDACT" = true ] && [ "$COMMAND" != system-info ]; then
  echo "ERROR: --redact is supported only by system-info" >&2
  exit 1
fi
if [ -n "$SYSTEM_INFO_OUTPUT" ] && [ "$COMMAND" != system-info ]; then
  echo "ERROR: --output is supported only by system-info" >&2
  exit 1
fi
if [ "$DASHBOARD_NO_OPEN" = true ] \
  && ! { [ "$COMMAND" = dashboard ] || [ "$COMMAND" = console ] || { [ "$COMMAND" = create ] && [ "$FULL_DEMO" = true ]; }; }; then
  echo "ERROR: --no-open is supported only by dashboard and console" >&2
  exit 1
fi
if [ "$FULL_DEMO" = true ] && [ "$COMMAND" != create ]; then
  echo "ERROR: --full-demo is supported only by create" >&2
  exit 1
fi
if [ "$MAINTENANCE_APPLY" = true ] && [ "$COMMAND" != maintenance ]; then
  echo "ERROR: --apply is supported only by maintenance" >&2
  exit 1
fi

# Load infrastructure abstraction layer
source "${SCRIPT_DIR}/includes/infra-api.sh"
# shellcheck source=includes/ingress-ca-trust.sh
source "${SCRIPT_DIR}/includes/ingress-ca-trust.sh"

# -----------------------------------------------------------------------------
# Prerequisite Checks
# -----------------------------------------------------------------------------

check_kubectl() {
  if command -v kubectl &>/dev/null; then
    return 0
  fi

  # OpenShift Local / MicroShift hosts often have oc but not kubectl (common on Windows).
  if command -v oc &>/dev/null; then
    kubectl() {
      oc "$@"
    }
    return 0
  fi

  if command -v crc &>/dev/null; then
    local _crc_oc_path
    _crc_oc_path=$(crc oc-env 2>/dev/null | grep 'PATH=' | sed 's/.*PATH="\([^:]*\):.*/\1/' | head -1)
    if [ -n "$_crc_oc_path" ] && [ -d "$_crc_oc_path" ] && [ -x "$_crc_oc_path/oc" ]; then
      export PATH="$_crc_oc_path:$PATH"
      kubectl() {
        oc "$@"
      }
      return 0
    fi
  fi

  _err "kubectl not found"
  echo ""
  echo "Install kubectl or the OpenShift CLI (oc):"
  echo ""
  case "$(uname -s)" in
    Darwin)
      echo "  # macOS (Homebrew)"
      echo "  brew install kubectl"
      echo ""
      echo "  # macOS (manual)"
      case "$(uname -m)" in
        arm64 | aarch64)
          echo "  curl -LO https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/arm64/kubectl"
          ;;
        x86_64 | amd64)
          echo "  curl -LO https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"
          ;;
        *)
          echo "  Unsupported macOS architecture: $(uname -m)"
          ;;
      esac
      echo "  chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
      ;;
    MINGW* | MSYS* | CYGWIN*)
      echo "  winget install --id RedHat.OpenShift-Client -e --source winget"
      echo "  # oc works as kubectl for aap-demo commands"
      ;;
    *)
      echo "  # Linux"
      echo "  sudo dnf install kubectl"
      echo "  OR"
      echo "  curl -LO https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
      echo "  chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
      ;;
  esac
  echo ""
  echo "Or download from: https://kubernetes.io/docs/tasks/tools/"
  return 1
}

# -----------------------------------------------------------------------------
# Infrastructure Type Handling
# -----------------------------------------------------------------------------

# Setup KUBECONFIG based on infrastructure type
setup_kubeconfig() {
  check_kubectl || exit 1
  # Apply --kubeconfig override first (takes precedence)
  if [ -n "$KUBECTL_KUBECONFIG" ]; then
    if [ ! -f "$KUBECTL_KUBECONFIG" ]; then
      echo "ERROR: Kubeconfig file not found: $KUBECTL_KUBECONFIG"
      exit 1
    fi
    export KUBECONFIG="$KUBECTL_KUBECONFIG"
  else
    mkdir -p "$AAP_DEMO_DIR"
    KUBECONFIG="$(aap_demo_resolve_kubeconfig)"
    export KUBECONFIG
    # Refresh from cluster if current kubeconfig doesn't work
    if ! kubectl cluster-info --request-timeout=3s &>/dev/null 2>&1; then
      # Ensure infra backend is loaded to set CRC_SSH_KEY
      _infra_ensure_backend 2>/dev/null || true
      if [ "$(aap_demo_detect_crc_preset)" = "openshift" ]; then
        if [ -s "$HOME/.crc/machines/crc/kubeconfig" ]; then
          cp "$HOME/.crc/machines/crc/kubeconfig" "$AAP_DEMO_KUBECONFIG"
          chmod 600 "$AAP_DEMO_KUBECONFIG"
          export KUBECONFIG="$AAP_DEMO_KUBECONFIG"
        fi
      elif [ -n "$CRC_SSH_KEY" ]; then
        if ssh -p 2222 -i "$CRC_SSH_KEY" \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
          -o ConnectTimeout=2 -o BatchMode=yes \
          core@127.0.0.1 "sudo cat $(aap_demo_microshift_kubeconfig_vm_path)" \
          >"${AAP_DEMO_KUBECONFIG}.tmp" 2>/dev/null; then
          mv "${AAP_DEMO_KUBECONFIG}.tmp" "$AAP_DEMO_KUBECONFIG"
          chmod 600 "$AAP_DEMO_KUBECONFIG"
          export KUBECONFIG="$AAP_DEMO_KUBECONFIG"
        else
          rm -f "${AAP_DEMO_KUBECONFIG}.tmp"
        fi
      fi
    fi
  fi

  # Apply context override if specified
  if [ -n "$KUBECTL_CONTEXT" ]; then
    if ! kubectl config use-context "$KUBECTL_CONTEXT" >/dev/null 2>&1; then
      echo "ERROR: Context '$KUBECTL_CONTEXT' not found"
      echo ""
      echo "Available contexts:"
      kubectl config get-contexts -o name 2>/dev/null | sed 's/^/  /' || echo "  (none)"
      exit 1
    fi
  fi
}

# Verify cluster state
verify_cluster_type() {
  local state
  state=$(infra_get_state)
  if [ "$state" = "not_created" ]; then
    echo "WARNING: No cluster exists"
    echo "  Run 'aap-demo create' first"
    echo ""
  elif [ "$state" = "stopped" ]; then
    echo "WARNING: Cluster exists but is stopped"
    echo "  Run 'crc start' to start it"
    echo ""
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Preflight: mkcert CA check (macOS and Linux)
# -----------------------------------------------------------------------------
check_mkcert_ca() {
  # Skip if mkcert is disabled
  [ "${AAP_DEMO_MKCERT:-true}" != "true" ] && return 0

  # Skip if mkcert not installed (will be installed during setup)
  command -v mkcert &>/dev/null || return 0

  local CA_INSTALLED=false

  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS: check system and login keychains
    if security find-certificate -a -c "mkcert" /Library/Keychains/System.keychain 2>/dev/null | grep -q "mkcert" \
      || security find-certificate -a -c "mkcert" ~/Library/Keychains/login.keychain-db 2>/dev/null | grep -q "mkcert"; then
      CA_INSTALLED=true
    fi
  else
    # Linux: check if CA file exists in system trust store
    CAROOT="$(mkcert -CAROOT 2>/dev/null)"
    if [ -f "$CAROOT/rootCA.pem" ]; then
      # Check if it's been added to system trust
      # shellcheck disable=SC2144
      if compgen -G "/etc/ssl/certs/mkcert*" >/dev/null \
        || compgen -G "/usr/local/share/ca-certificates/mkcert*" >/dev/null \
        || compgen -G "/etc/pki/ca-trust/source/anchors/mkcert*" >/dev/null; then
        CA_INSTALLED=true
      elif trust list 2>/dev/null | grep -q "mkcert"; then
        CA_INSTALLED=true
      elif [ -f "$CAROOT/rootCA.pem" ]; then
        # CA file exists, assume mkcert -install was run
        CA_INSTALLED=true
      fi
    fi
  fi

  if [ "$CA_INSTALLED" = false ]; then
    echo ""
    echo "  Trusted SSL Setup Required"
    echo "  --------------------------"
    echo "  aap-demo uses mkcert to generate locally-trusted SSL certificates."
    echo "  This eliminates browser security warnings for *.apps.127.0.0.1.nip.io"
    echo ""
    echo "  To add the certificate authority to your system trust store, run:"
    echo ""
    echo "      mkcert -install"
    echo ""
    echo "  You will be prompted for your system administrator password (sudo)."
    echo "  This is a one-time setup per machine."
    echo ""
    echo "  Firefox: Install certutil first (brew install nss / apt install libnss3-tools)"
    echo ""
    echo "  To skip trusted SSL: AAP_DEMO_MKCERT=false aap-demo deploy"
    echo ""
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
show_welcome() {
  cat <<'EOF'
aap-demo - Deploy AAP 2.7 to OpenShift Local

Usage: aap-demo [options] <command>

Common commands:
  create                    Create the local cluster
  deploy                    Deploy AAP 2.7
  status                    Show cluster, routes, addons, and Fleet without secrets
  diagnose [--ai]           Run environment health checks
  enable <addon>            Enable an addon
  disable <addon>           Disable an addon
  wire                      Reapply addon integrations
  fleet <subcommand>        Manage local RHEL Fleet VMs
  stop | start              Stop or resume the configured demo and Fleet VMs
  restart                   Save and restart the demo (with service installed)
  service install [--keep N] Enable Linux boot or macOS login recovery
  redeploy-all              Destroy and rebuild the configured environment

Examples:
  aap-demo deploy
  aap-demo enable fleet
  aap-demo fleet add 3 --image rhel9
  aap-demo enable ao
  aap-demo wire

Run 'aap-demo --help' for all commands, options, addons, and examples.
EOF
}

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
    maintenance uninstall [--apply]
                                    Remove all aap-demo state/settings; preserve source and shared tools
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

# -----------------------------------------------------------------------------
# Pull Secret Selection
# -----------------------------------------------------------------------------
determine_pull_secret() {
  aap_demo_pull_secret_get
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

cmd_repair() {
  NAMESPACE="${NAMESPACE:-aap-operator}"
  export KUBECONFIG="${KUBECONFIG:-$(aap_demo_resolve_kubeconfig)}"

  echo "Running repair..."
  echo ""

  _grant_sccs "$NAMESPACE"

  verify_coredns

  install_ingress_ca_trust

  local _problem_pods
  _problem_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -E "CrashLoopBackOff|Error|ImagePullBackOff" | awk '{print $1}' || true)
  if [ -n "$_problem_pods" ]; then
    echo "  Restarting problem pods..."
    while IFS= read -r pod; do
      [ -z "$pod" ] && continue
      kubectl delete pod "$pod" -n "$NAMESPACE" 2>/dev/null || true
    done <<<"$_problem_pods"
  fi

  echo ""
  echo "✓ In-cluster repair complete"
  echo ""
  echo "If issues persist (ImagePullBackOff, NFS/storage, wedged VM):"
  echo "  crc stop && crc start"
}

# Shared function: display cluster info for warnings
# shellcheck disable=SC2120
_show_cluster_info() {
  local _CLUSTER _API _AAP_COUNT _POD_COUNT
  _CLUSTER=$(kubectl config current-context 2>/dev/null) || _CLUSTER="unknown"
  _API=$(kubectl cluster-info --request-timeout=2s 2>/dev/null | head -1 | sed 's/.*is running at //' | sed 's/\x1b\[[0-9;]*m//g') || _API="unknown"
  _AAP_COUNT=$(kubectl get aap -n "${NAMESPACE:-aap-operator}" --no-headers --request-timeout=2s 2>/dev/null | wc -l | tr -d ' ') || _AAP_COUNT="0"
  _POD_COUNT=$(kubectl get pods -A --no-headers --request-timeout=2s 2>/dev/null | wc -l | tr -d ' ') || _POD_COUNT="0"

  echo "  Infra:            crc"
  echo "  Cluster Context:  ${_CLUSTER}"
  echo "  API Server:       ${_API}"
  echo "  Namespace:        ${NAMESPACE:-aap-operator}"
  echo "  AAP Instances:    ${_AAP_COUNT}"
  if [ -n "${1:-}" ]; then
    echo "  Total Pods:       ${_POD_COUNT}"
  fi
  return 0
}

# Prune unused container images on cluster VM
_prune_unused_images() {

  _infra_ensure_backend 2>/dev/null || return 0

  echo ""
  echo "Pruning unused container images..."
  local _prune_output
  _prune_output=$(infra_exec_cmd bash -c 'sudo crictl rmi --prune 2>&1' 2>/dev/null) || _prune_output=""
  local _pruned
  _pruned=$(echo "$_prune_output" | grep -ci "deleted" 2>/dev/null) || _pruned=0

  if [ "$_pruned" -gt 0 ] 2>/dev/null; then
    echo "  ✓ Pruned ${_pruned} unused images"
  else
    echo "  ✓ No unused images to prune"
  fi
}

# Check disk space on the CRC VM
# Warns at >80% usage, errors at >95%
_check_disk_space() {
  _infra_ensure_backend 2>/dev/null || return 0

  local disk_usage=""
  disk_usage=$(aap_demo_vm_disk_usage_pct 2>/dev/null) || true

  if [ -z "$disk_usage" ]; then
    return 0
  fi

  if [ "$disk_usage" -ge 95 ] 2>/dev/null; then
    echo ""
    echo "ERROR: Cluster VM disk is ${disk_usage}% full"
    echo ""
    echo "  Free space by pruning unused container images:"
    echo "    aap-demo ssh"
    echo "    sudo crictl rmi --prune"
    echo ""
    echo "  Or destroy and recreate with a larger disk:"
    echo "    aap-demo destroy && aap-demo create"
    return 1
  elif [ "$disk_usage" -ge 80 ] 2>/dev/null; then
    echo ""
    printf "  \033[1;33mWARNING: Cluster VM disk is ${disk_usage}%% full\033[0m\n"
    echo "  Consider pruning unused images: aap-demo ssh && sudo crictl rmi --prune"
    echo ""
  fi
  return 0
}

# Verify cluster is accessible — used before deploy, enable, and other cluster operations
_verify_crc_version() {
  # Check that the installed CRC version matches the required version
  local installed_version

  # Get installed CRC version from status
  installed_version=$(crc status -o json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('openshiftVersion',''))" 2>/dev/null \
    | grep -oE '^[0-9]+\.[0-9]+' || echo "")

  if [ -z "$installed_version" ]; then
    echo ""
    echo "ERROR: Could not detect CRC version"
    echo ""
    echo "Ensure CRC cluster is created and running:"
    echo "  aap-demo create"
    echo ""
    echo "Or bypass version check with explicit override:"
    echo "  CRC_VERSION=4.22 aap-demo deploy"
    echo ""
    return 1
  fi

  # Parse major.minor from installed version
  local major="${installed_version%%.*}"
  local minor="${installed_version#*.}"
  minor="${minor%%.*}" # Handle 4.22.5 → 4.22

  # Parse major.minor from required version (CRC_VERSION)
  local req_major="${CRC_VERSION%%.*}"
  local req_minor="${CRC_VERSION#*.}"
  req_minor="${req_minor%%.*}" # Handle 4.22.5 → 4.22

  # Always warn when the actual cluster is below the recommended version,
  # including when an advanced CRC_VERSION override allows deployment.
  local recommended_major="${CRC_RECOMMENDED_VERSION%%.*}"
  local recommended_minor="${CRC_RECOMMENDED_VERSION#*.}"
  recommended_minor="${recommended_minor%%.*}"
  if [ "$major" -lt "$recommended_major" ] \
    || { [ "$major" -eq "$recommended_major" ] && [ "$minor" -lt "$recommended_minor" ]; }; then
    echo ""
    echo "WARNING: CRC/MicroShift version is below the recommended version"
    echo "  Recommended: $CRC_RECOMMENDED_VERSION or newer"
    echo "  Installed: $installed_version"
    echo "  You may encounter deployment or VM stability issues on older versions."
    echo "  Download latest CRC: https://console.redhat.com/openshift/create/local"
    echo ""
  fi

  # Reject if installed < CRC_VERSION (same logic as needs_signature_policy_relaxation)
  if [ "$major" -lt "$req_major" ] || { [ "$major" -eq "$req_major" ] && [ "$minor" -lt "$req_minor" ]; }; then
    echo ""
    echo "ERROR: CRC version too old"
    echo "  Required: $CRC_VERSION or newer"
    echo "  Installed: $installed_version"
    echo ""
    echo "MicroShift 4.22+ is required to avoid signature validation issues with the operator catalog."
    echo ""
    echo "To fix:"
    echo "  1. Delete the current cluster: aap-demo destroy"
    echo "  2. Download latest CRC: https://console.redhat.com/openshift/create/local"
    echo "  3. Install and create new cluster: aap-demo create"
    echo ""
    echo "Or override the version check: CRC_VERSION=$installed_version aap-demo deploy"
    echo ""
    return 1
  fi

  return 0
}

_verify_cluster() {
  setup_kubeconfig
  if kubectl cluster-info &>/dev/null 2>&1; then
    return 0
  fi

  # Cluster not accessible — try to recover
  local cluster_state
  cluster_state=$(infra_get_state 2>/dev/null || echo "not_created")

  if [ "$cluster_state" = "stopped" ]; then
    echo "Cluster is stopped. Starting..."
    _start_crc_cluster
    setup_kubeconfig
    if kubectl cluster-info &>/dev/null 2>&1; then
      return 0
    fi
  elif [ "$cluster_state" = "not_created" ]; then
    echo ""
    echo "No cluster found."
    echo ""
    if [ -t 0 ]; then
      printf "Create one now? [Y/n]: "
      read -t 15 -r _create_choice || true
      if [ -z "$_create_choice" ] || [[ "$_create_choice" =~ ^[Yy] ]]; then
        cmd_create || return 1
        setup_kubeconfig
        if kubectl cluster-info &>/dev/null 2>&1; then
          return 0
        fi
      fi
    else
      echo "  Run: aap-demo create"
    fi
  fi

  echo ""
  echo "ERROR: Cluster is not accessible"
  echo "  Run: aap-demo create   # Create a new cluster"
  echo "  Run: crc start    # Start a stopped cluster"
  echo "  Run: aap-demo status   # Check cluster status"
  return 1
}

# Wait for MicroShift's OVN components before starting OLM/AAP installation.
# The Kubernetes API can be reachable while the node CNI is still unhealthy,
# which leaves newly-created operator pods stuck in ContainerCreating.
_wait_for_ovn_ready() {
  local ovn_namespace="openshift-ovn-kubernetes"
  local timeout="${AAP_OVN_TIMEOUT:-180}"
  local interval=5
  local elapsed=0
  local node_desired node_ready master_desired master_ready
  local master_required=true

  if ! kubectl get namespace "$ovn_namespace" &>/dev/null; then
    echo ""
    echo "ERROR: OVN namespace '$ovn_namespace' was not found"
    echo "  The cluster network is not ready for AAP deployment."
    return 1
  fi

  echo "Waiting for OVN networking to become ready..."
  if ! kubectl get daemonset ovnkube-master -n "$ovn_namespace" >/dev/null 2>&1; then
    master_required=false
  fi

  while [ "$elapsed" -lt "$timeout" ]; do
    node_desired=$(kubectl get daemonset ovnkube-node -n "$ovn_namespace" \
      -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "")
    node_ready=$(kubectl get daemonset ovnkube-node -n "$ovn_namespace" \
      -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "")
    if [ "$master_required" = true ]; then
      master_desired=$(kubectl get daemonset ovnkube-master -n "$ovn_namespace" \
        -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "")
      master_ready=$(kubectl get daemonset ovnkube-master -n "$ovn_namespace" \
        -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "")
    else
      master_desired="0"
      master_ready="0"
    fi

    if [ "$node_desired" -gt 0 ] 2>/dev/null \
      && [ "$node_ready" -eq "$node_desired" ] 2>/dev/null \
      && { [ "$master_required" = false ] \
        || { [ "$master_desired" -gt 0 ] 2>/dev/null \
          && [ "$master_ready" -eq "$master_desired" ] 2>/dev/null; }; }; then
      echo "  ✓ OVN networking is ready"
      return 0
    fi

    printf "  Waiting for OVN... node %s/%s, master %s/%s (%ss/%ss)\n" \
      "${node_ready:-0}" "${node_desired:-0}" \
      "${master_ready:-0}" "${master_desired:-0}" "$elapsed" "$timeout"
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo ""
  echo "ERROR: OVN networking was not ready after ${timeout}s"
  echo "  Check: kubectl get pods -n ${ovn_namespace} -o wide"
  echo "  Check: kubectl get events -n ${ovn_namespace} --sort-by=.lastTimestamp"
  kubectl get daemonset ovnkube-node ovnkube-master -n "$ovn_namespace" 2>/dev/null || true
  kubectl get pods -n "$ovn_namespace" -o wide 2>/dev/null || true
  return 1
}

cmd_clean() {
  setup_kubeconfig
  _clean_operator
}

_clean_operator() {
  local ns="${NAMESPACE:-aap-operator}"

  echo ""
  printf "\033[1maap-demo clean\033[0m - Removing AAP operator deployment...\n"
  echo ""

  echo "WARNING: AAP CLEANUP - DESTRUCTIVE OPERATION!"
  echo ""
  _show_cluster_info
  echo ""

  local _aap_count
  _aap_count=$(kubectl get aap -n "$ns" --no-headers --request-timeout=2s 2>/dev/null | wc -l | tr -d ' ')
  if [ "${_aap_count:-0}" -gt 0 ] 2>/dev/null; then
    echo "  AAP resources that will be DELETED:"
    kubectl get aap -n "$ns" --no-headers --request-timeout=2s 2>/dev/null | awk '{print "    - " $1}'
    echo ""
  fi

  echo "This will DELETE the namespace '$ns' and all resources within it!"
  echo ""

  if [ "${QUIET:-false}" != "true" ]; then
    echo "Press Ctrl+C to cancel, or press Enter to continue immediately..."
    echo "Auto-continuing in 10 seconds..."
    read -t 10 -r || true
    echo ""
  fi

  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    # Clean up OLM resources created by operator-sdk run bundle
    if command -v operator-sdk &>/dev/null; then
      echo "  Cleaning up OLM resources..."
      operator-sdk cleanup ansible-automation-platform-operator -n "$ns" 2>/dev/null || true
      # Ensure OLM operators weren't scaled down by cleanup
      kubectl scale deploy catalog-operator olm-operator -n olm --replicas=1 2>/dev/null || true
    fi

    # Remove ownerReferences from child CRs to prevent cascade deletion deadlock
    # (blockOwnerDeletion: true causes namespace termination to hang)
    for aap_cr in $(kubectl get aap -n "$ns" --no-headers -o name 2>/dev/null); do
      echo "  Removing owner references from children..."
      kubectl patch "$aap_cr" -n "$ns" --type merge -p '{"spec":{"remove_owner_references_from_children": true}}' 2>/dev/null || true
      # Give the operator a moment to reconcile and strip ownerRefs
      sleep 3
      echo "  Deleting AAP CR..."
      kubectl delete "$aap_cr" -n "$ns" --timeout=30s 2>/dev/null || true
    done

    echo "Deleting namespace $ns..."
    kubectl delete namespace "$ns" --timeout=60s 2>/dev/null || true
    echo "✓ AAP operator deployment removed"

    # Prune unused container images on cluster VM to reclaim disk space
    _prune_unused_images
  else
    echo "Namespace $ns not found - nothing to clean"
  fi
}

cmd_config() {
  local key="${1:-}"
  local value="${2:-}"

  # Ensure config directory exists
  mkdir -p "$(dirname "$AAP_DEMO_CONFIG")"
}

cmd_version() {
  aap_demo_print_version
}

cmd_update() {
  echo ""
  printf "\033[1maap-demo update\033[0m - Pulling latest code and reinstalling...\n"
  printf "  Current:   %s\n" "$(aap_demo_version_short)"
  echo ""

  local repo_root="$SCRIPT_DIR"
  if [ ! -f "${repo_root}/aap-demo.sh" ]; then
    _err "aap-demo repo not found at ${repo_root}"
    echo "  Run from the repo directory or reinstall with ./install.sh"
    return 1
  fi

  if ! git -C "$repo_root" rev-parse --is-inside-work-tree &>/dev/null; then
    _err "Not a git repository: ${repo_root}"
    return 1
  fi

  echo "  Pulling latest code..."
  if ! git -C "$repo_root" pull; then
    _err "git pull failed"
    return 1
  fi

  echo "  Reinstalling launcher..."
  if ! bash "${repo_root}/install.sh"; then
    _err "install.sh failed"
    return 1
  fi

  echo ""
  echo "  ✓ Update complete"
  aap_demo_reload_version
  printf "  Now:       %s\n" "$(aap_demo_version_short)"
  printf "  Built:     %s\n" "$AAP_DEMO_GIT_DATE"
}

cmd_redhat_status() {
  echo ""
  printf "\033[1maap-demo redhat-status\033[0m - Checking Red Hat service status...\n"
  echo ""

  RSS_URL="https://status.redhat.com/history.rss"

  # Fetch RSS feed
  RSS_CONTENT=$(curl -s --connect-timeout 5 "$RSS_URL" 2>/dev/null)
  if [ -z "$RSS_CONTENT" ]; then
    echo "Unable to fetch status from $RSS_URL"
    exit 1
  fi

  # Parse active incidents (not Resolved/Completed)
  # Filter for registry-related issues
  echo "Active Incidents:"
  echo "================="

  # Extract items and check for active registry issues
  ACTIVE_FOUND=false
  while IFS= read -r item; do
    # Skip resolved/completed items
    if echo "$item" | grep -qi "Resolved\|Completed"; then
      continue
    fi

    # Check if it's registry-related or recent (within last 24h would need date parsing)
    if echo "$item" | grep -qi "registry\|quay\|rhsso\|login\|403\|authentication"; then
      TITLE=$(echo "$item" | sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p' | head -1 | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g')
      STATUS=$(echo "$item" | grep -oE "(Investigating|Identified|Monitoring|In progress|Update)" | head -1)
      LINK=$(echo "$item" | sed -n 's/.*<link>\([^<]*\)<\/link>.*/\1/p' | head -1)

      if [ -n "$TITLE" ]; then
        ACTIVE_FOUND=true
        echo ""
        printf "  \033[1;33m⚠ %s\033[0m\n" "$TITLE"
        [ -n "$STATUS" ] && echo "    Status: $STATUS"
        [ -n "$LINK" ] && echo "    Details: $LINK"
      fi
    fi
  done <<<"$(echo "$RSS_CONTENT" | tr '\n' ' ' | sed 's/<item>/\n<item>/g')"

  if [ "$ACTIVE_FOUND" = false ]; then
    printf "  \033[1;32m✓ No active registry-related incidents\033[0m\n"
  fi

  echo ""
  echo "Full status: https://status.redhat.com"
}

cmd_idle() {
  local value="${1:-}"

  # Check if AAP CR exists
  local AAP_NAME
  AAP_NAME=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$AAP_NAME" ]; then
    echo "✗ No AAP instance found in namespace $NAMESPACE"
    exit 1
  fi

  local CURRENT
  CURRENT=$(kubectl get aap "$AAP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.idle_aap}' 2>/dev/null)

  # No argument: show current state
  if [ -z "$value" ]; then
    if [ "$CURRENT" = "true" ]; then
      echo "AAP '$AAP_NAME' is idle (scaled down)"
      echo "  Resume with: aap-demo idle false"
    else
      echo "AAP '$AAP_NAME' is running"
      echo "  Scale down with: aap-demo idle true"
    fi
    return 0
  fi

  case "$value" in
    true)
      if [ "$CURRENT" = "true" ]; then
        echo "AAP '$AAP_NAME' is already idle"
        return 0
      fi
      echo ""
      printf "\033[1maap-demo idle true\033[0m - Scaling down AAP deployment...\n"
      kubectl patch aap "$AAP_NAME" -n "$NAMESPACE" --type merge -p '{"spec":{"idle_aap":true}}'
      echo ""
      echo "✓ AAP '$AAP_NAME' set to idle"
      echo "  The operator will scale down all components (this may take a minute)"
      echo "  Resume with: aap-demo idle false"
      ;;
    false)
      if [ "$CURRENT" != "true" ]; then
        echo "AAP '$AAP_NAME' is already running"
        return 0
      fi
      echo ""
      printf "\033[1maap-demo idle false\033[0m - Scaling up AAP deployment...\n"
      kubectl patch aap "$AAP_NAME" -n "$NAMESPACE" --type merge -p '{"spec":{"idle_aap":false}}'
      echo ""
      echo "✓ AAP '$AAP_NAME' waking up"
      echo "  The operator will scale up all components (this may take a few minutes)"
      echo "  Monitor with: aap-demo watch"
      ;;
    *)
      echo "Usage: aap-demo idle [true|false]"
      echo "  true   Scale down all AAP components"
      echo "  false  Scale up all AAP components"
      echo "  (no arg) Show current idle state"
      exit 1
      ;;
  esac
}

cmd_must_gather() {
  echo ""
  printf "\033[1maap-demo must-gather\033[0m - Collecting diagnostic information...\n"
  echo ""

  local dest_dir="${1:-must-gather.local.$(date +%Y%m%d%H%M%S)}"
  local aap_image="registry.redhat.io/ansible-automation-platform-26/aap-must-gather-rhel9:latest"

  echo "Output directory: ${dest_dir}"
  echo ""

  mkdir -p "${dest_dir}/aap-demo"

  # Collect aap-demo specific diagnostics
  echo "Collecting aap-demo diagnostics..."
  cp "$AAP_DEMO_CONFIG" "${dest_dir}/aap-demo/config" 2>/dev/null || true
  crc status >"${dest_dir}/aap-demo/crc-status.txt" 2>&1 || true
  crc version >"${dest_dir}/aap-demo/crc-version.txt" 2>&1 || true
  kubectl get sc -o yaml >"${dest_dir}/aap-demo/storageclasses.yaml" 2>/dev/null || true
  kubectl get pvc -n "$NAMESPACE" -o yaml >"${dest_dir}/aap-demo/pvcs.yaml" 2>/dev/null || true
  kubectl get pods -n "$NAMESPACE" -o wide >"${dest_dir}/aap-demo/pods.txt" 2>/dev/null || true
  kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' >"${dest_dir}/aap-demo/events.txt" 2>/dev/null || true
  kubectl get aap -n "$NAMESPACE" -o yaml >"${dest_dir}/aap-demo/aap-cr.yaml" 2>/dev/null || true
  {
    echo "=== ClusterRoleBindings (SCC grants) for $NAMESPACE ==="
    kubectl get clusterrolebinding -o wide 2>/dev/null | grep -E "scc:.*(${NAMESPACE}|system:serviceaccounts:${NAMESPACE})" || echo "(none found)"
    echo ""
    echo "=== RoleBindings in $NAMESPACE ==="
    kubectl get rolebinding -n "$NAMESPACE" -o wide 2>/dev/null || echo "(none)"
  } >"${dest_dir}/aap-demo/scc-bindings.txt" 2>/dev/null || true
  kubectl get pods -n nfs-storage -o wide >"${dest_dir}/aap-demo/nfs-pods.txt" 2>/dev/null || true
  kubectl get configmap -n openshift-dns dns-default -o yaml >"${dest_dir}/aap-demo/coredns-config.yaml" 2>/dev/null || true
  echo "  ✓ aap-demo diagnostics collected"
  echo ""

  # Run AAP must-gather
  echo "Running AAP must-gather..."
  echo "  This will launch a pod to collect AAP-specific diagnostics."
  echo "  It may take several minutes to complete."
  echo ""

  oc adm must-gather \
    --image="${aap_image}" \
    --dest-dir="${dest_dir}" 2>&1 | while IFS= read -r line; do
    echo "  $line"
  done

  local exit_code=${PIPESTATUS[0]}

  echo ""
  if [ "$exit_code" -eq 0 ]; then
    echo "✓ Must-gather complete: ${dest_dir}"
  else
    echo "⚠ AAP must-gather failed (exit code: ${exit_code})"
    echo "  aap-demo diagnostics were still collected successfully."
  fi

  echo ""
  echo "Contents:"
  ls -1 "${dest_dir}" 2>/dev/null | sed 's/^/  /'
  echo ""
  echo "To share: tar czf must-gather.tar.gz ${dest_dir}"
}

cmd_preflight() {
  echo ""
  printf "\033[1maap-demo preflight\033[0m - Validating prerequisites and capacity...\n"
  echo ""

  local issues=0 warnings=0 tool cluster_state disk_pct catalog_status architecture
  local infra_name default_storage_class
  _preflight_pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; }
  _preflight_warn() {
    printf "  \033[33m⚠\033[0m %s\n" "$1"
    warnings=$((warnings + 1))
  }
  _preflight_fail() {
    printf "  \033[31m✗\033[0m %s\n" "$1"
    issues=$((issues + 1))
  }

  echo "Tools:"
  for tool in kubectl jq python3; do
    if command -v "$tool" >/dev/null 2>&1; then
      _preflight_pass "$tool available"
    else
      _preflight_fail "$tool is required but not installed"
    fi
  done
  case "$INFRA_TYPE" in
    crc) tool=crc ;;
    minc) tool=podman ;;
    *) tool="" ;;
  esac
  if [ -n "$tool" ]; then
    if command -v "$tool" >/dev/null 2>&1; then
      _preflight_pass "$tool available for $INFRA_TYPE infrastructure"
    else
      _preflight_fail "$tool is required for $INFRA_TYPE infrastructure"
    fi
  fi
  echo ""

  echo "Cluster:"
  infra_name=$(infra_get_name 2>/dev/null || echo "$INFRA_TYPE")
  cluster_state=$(infra_get_state 2>/dev/null || echo "unknown")
  if [ "$cluster_state" = "running" ]; then
    _preflight_pass "$infra_name running"
  else
    _preflight_fail "$infra_name is ${cluster_state}; run: aap-demo start"
  fi
  if kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
    _preflight_pass "Kubernetes API reachable"
  else
    _preflight_fail "Kubernetes API is not reachable"
  fi

  architecture=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' \
    2>/dev/null || true)
  if [ -n "$architecture" ]; then
    _preflight_pass "Cluster architecture: $architecture"
  else
    _preflight_warn "Cluster architecture could not be detected"
  fi
  echo ""

  if [ "$issues" -eq 0 ]; then
    echo "Capacity:"
    if ! aap_demo_resource_preflight "general installation" \
      "${AAP_PREFLIGHT_MIN_CPU_M:-2000}" "${AAP_PREFLIGHT_MIN_MEMORY_MI:-4096}"; then
      _preflight_fail "Recommended resource headroom is unavailable in strict mode"
    elif [ "${AAP_RESOURCE_PREFLIGHT_SKIPPED:-false}" = true ]; then
      _preflight_warn "Resource headroom check explicitly skipped"
    elif [ "${AAP_RESOURCE_PREFLIGHT_UNAVAILABLE:-false}" = true ]; then
      _preflight_warn "Resource headroom could not be calculated"
    elif [ "${AAP_RESOURCE_PREFLIGHT_INSUFFICIENT:-false}" = true ]; then
      _preflight_warn "Resource headroom is below the recommended threshold"
    else
      _preflight_pass "Recommended resource headroom is available"
    fi
    echo ""

    echo "Storage:"
    default_storage_class=$(kubectl get sc \
      -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
      2>/dev/null | head -1)
    if [ -n "$default_storage_class" ]; then
      _preflight_pass "Default StorageClass available: $default_storage_class"
    else
      _preflight_fail "No default writable StorageClass found"
    fi
    if kubectl get sc nfs-local-rwx >/dev/null 2>&1; then
      _preflight_pass "RWX StorageClass available"
    else
      _preflight_warn "nfs-local-rwx is unavailable; Automation Hub file storage may remain pending"
    fi

    disk_pct=$(aap_demo_vm_disk_usage_pct 2>/dev/null || true)
    if [ -z "$disk_pct" ]; then
      _preflight_warn "VM disk usage could not be determined"
    elif [ "$disk_pct" -ge 95 ]; then
      _preflight_fail "VM disk is ${disk_pct}% full"
    elif [ "$disk_pct" -ge 80 ]; then
      _preflight_warn "VM disk is ${disk_pct}% full; prune images before a large deployment"
    else
      _preflight_pass "VM disk usage: ${disk_pct}%"
    fi
    echo ""

    echo "Operator catalog:"
    if kubectl get catalogsource redhat-operators -n "$NAMESPACE" >/dev/null 2>&1; then
      catalog_status=$(kubectl get catalogsource redhat-operators -n "$NAMESPACE" \
        -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
      if [ "$catalog_status" = "READY" ]; then
        _preflight_pass "AAP CatalogSource ready"
      else
        _preflight_warn "AAP CatalogSource state: ${catalog_status:-unknown}"
      fi
    else
      _preflight_warn "AAP CatalogSource not installed yet"
    fi
    echo ""
  fi

  if [ "$issues" -gt 0 ]; then
    printf "\033[31mPreflight failed: %d issue(s), %d warning(s)\033[0m\n" \
      "$issues" "$warnings"
    return 1
  fi
  if [ "$warnings" -gt 0 ]; then
    printf "\033[33mPreflight passed with %d warning(s)\033[0m\n" "$warnings"
  else
    printf "\033[32mPreflight passed\033[0m\n"
  fi
}

cmd_diagnose() {
  echo ""
  printf "\033[1maap-demo diagnose\033[0m - Checking environment health...\n"
  echo ""

  local issues=0
  local warnings=0

  _check_pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; }
  _check_fail() {
    printf "  \033[31m✗\033[0m %s\n" "$1"
    issues=$((issues + 1))
  }
  _check_warn() {
    printf "  \033[33m⚠\033[0m %s\n" "$1"
    warnings=$((warnings + 1))
  }
  _check_info() { printf "  \033[36m·\033[0m %s\n" "$1"; }

  # =========================================================================
  # Cluster connectivity
  # =========================================================================
  echo "Cluster:"
  local crc_state
  crc_state=$(crc status -o json 2>/dev/null | python3 -c "import sys,json; d=json.loads(sys.stdin.read() or '{}'); print(d.get('crcStatus','unknown'))" 2>/dev/null || echo "unknown")
  if [ "$crc_state" = "Running" ]; then
    local ms_version
    ms_version=$(crc status -o json 2>/dev/null | python3 -c "import sys,json; d=json.loads(sys.stdin.read() or '{}'); print(d.get('openshiftVersion',''))" 2>/dev/null || echo "")
    _check_pass "OpenShift Local running"
  elif [ "$crc_state" = "Stopped" ]; then
    _check_fail "OpenShift Local is stopped — run: crc start"
  else
    _check_fail "OpenShift Local cluster not found — run: aap-demo create"
  fi

  if kubectl cluster-info &>/dev/null; then
    _check_pass "kubectl connected"
  else
    _check_fail "kubectl cannot connect to cluster"
    echo ""
    echo "Cannot proceed without cluster connectivity."
    echo "  Check KUBECONFIG: ${KUBECONFIG:-$AAP_DEMO_KUBECONFIG}"
    return 1
  fi
  echo ""

  # =========================================================================
  # Storage
  # =========================================================================
  echo "Storage:"
  if kubectl get sc topolvm-provisioner &>/dev/null; then
    _check_pass "topolvm-provisioner StorageClass (default)"
  else
    _check_warn "topolvm-provisioner StorageClass not found"
  fi

  if kubectl get sc nfs-local-rwx &>/dev/null; then
    _check_pass "nfs-local-rwx StorageClass (RWX)"
    # Check NFS server health
    local nfs_ready
    nfs_ready=$(kubectl get deployment nfs-server -n nfs-storage -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${nfs_ready:-0}" -gt 0 ]; then
      _check_pass "NFS server pod running"
    else
      _check_fail "NFS server pod not running — run: aap-demo create (or kubectl rollout restart deployment/nfs-server -n nfs-storage)"
    fi
  else
    _check_warn "nfs-local-rwx StorageClass not found — hub RWX storage unavailable"
    _check_info "Fix: re-run 'aap-demo create' to deploy NFS provisioner, or create the StorageClass manually"
  fi

  # Check disk usage
  local disk_pct
  disk_pct=$(aap_demo_vm_disk_usage_pct 2>/dev/null || true)
  if [ -z "$disk_pct" ]; then
    _check_warn "Disk usage unavailable — check with: aap-demo ssh -- df -h /var"
  elif [ "$disk_pct" -ge 95 ]; then
    _check_fail "Disk usage: ${disk_pct}% — critically low space"
  elif [ "$disk_pct" -ge 80 ]; then
    _check_warn "Disk usage: ${disk_pct}% — consider pruning: aap-demo ssh && sudo crictl rmi --prune"
  else
    _check_pass "Disk usage: ${disk_pct}%"
  fi
  echo ""

  # =========================================================================
  # Security
  # =========================================================================
  echo "Security:"
  local ns_exists=false
  kubectl get namespace "$NAMESPACE" &>/dev/null && ns_exists=true

  local scc_anyuid=0 scc_privileged=0
  if $ns_exists; then
    # SCC grants create ClusterRoleBindings, not namespace RoleBindings
    local _crb_list
    _crb_list=$(kubectl get clusterrolebinding -o wide 2>/dev/null || true)
    scc_anyuid=$(echo "$_crb_list" | grep -c "scc:anyuid.*system:serviceaccounts:${NAMESPACE}" || true)
    scc_privileged=$(echo "$_crb_list" | grep -c "scc:privileged.*system:serviceaccounts:${NAMESPACE}" || true)
    # Fallback: check namespace rolebindings (older oc versions)
    if [ "${scc_anyuid:-0}" -eq 0 ]; then
      scc_anyuid=$(kubectl get rolebinding -n "$NAMESPACE" -o wide 2>/dev/null | grep -c "scc:anyuid" || true)
    fi
    if [ "${scc_privileged:-0}" -eq 0 ]; then
      scc_privileged=$(kubectl get rolebinding -n "$NAMESPACE" -o wide 2>/dev/null | grep -c "scc:privileged" || true)
    fi
  fi

  if [ "${scc_anyuid:-0}" -gt 0 ] && [ "${scc_privileged:-0}" -gt 0 ]; then
    _check_pass "SCCs granted (anyuid + privileged) in $NAMESPACE"
  elif [ "$scc_anyuid" -gt 0 ]; then
    _check_warn "Only anyuid SCC granted — privileged missing in $NAMESPACE"
  elif [ "$scc_privileged" -gt 0 ]; then
    _check_warn "Only privileged SCC granted — anyuid missing in $NAMESPACE"
  else
    if $ns_exists; then
      _check_fail "No SCCs granted in $NAMESPACE — pods will fail to start"
      _check_info "Fix: oc adm policy add-scc-to-group anyuid system:serviceaccounts:$NAMESPACE"
      _check_info "Fix: oc adm policy add-scc-to-group privileged system:serviceaccounts:$NAMESPACE"
    else
      _check_info "Namespace $NAMESPACE does not exist yet (will be created on deploy)"
    fi
  fi

  # Check supplementalGroups on gateway deployment (OpenShift Local needs group 0)
  if $ns_exists; then
    local _gw_deploy _gw_sg
    _gw_deploy=$(kubectl get deployment -n "$NAMESPACE" -o name 2>/dev/null | grep gateway | grep -v operator | head -1)
    if [ -n "$_gw_deploy" ]; then
      _gw_sg=$(kubectl get "$_gw_deploy" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.securityContext.supplementalGroups}' 2>/dev/null || echo "")
      if [ "$_gw_sg" = "[0]" ]; then
        _check_pass "Gateway has supplementalGroups: [0]"
      else
        _check_fail "Gateway missing supplementalGroups: [0] — supervisord will crash with EACCES"
        _check_info "Fix: kubectl patch $_gw_deploy -n $NAMESPACE --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/securityContext/supplementalGroups\",\"value\":[0]}]'"
      fi
    fi
  fi

  # Check namespace PSA labels
  local psa_enforce
  if $ns_exists; then
    psa_enforce=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || echo "")
    if [ "$psa_enforce" = "privileged" ]; then
      _check_pass "Namespace PSA labels: privileged"
    elif [ -n "$psa_enforce" ]; then
      _check_warn "Namespace PSA enforce: $psa_enforce (expected: privileged)"
    else
      _check_fail "Namespace $NAMESPACE missing PSA labels"
    fi
  fi
  echo ""

  # =========================================================================
  # AAP deployment
  # =========================================================================
  echo "AAP Deployment:"
  local aap_name
  aap_name=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [ -z "$aap_name" ]; then
    _check_info "No AAP instance found in $NAMESPACE"
  else
    # Check idle state
    local idle_state
    idle_state=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.spec.idle_aap}' 2>/dev/null)
    if [ "$idle_state" = "true" ]; then
      _check_info "AAP '$aap_name' is idle (scaled down)"
    else
      # Check AAP status conditions
      local aap_status
      aap_status=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || echo "")
      local aap_running
      aap_running=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Running")].status}' 2>/dev/null || echo "")
      local aap_successful_reason
      aap_successful_reason=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Successful")].reason}' 2>/dev/null || echo "")
      local aap_failure
      aap_failure=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failure")].status}' 2>/dev/null || echo "")

      if aap_condition_is_complete "$aap_status" "$aap_running" "$aap_successful_reason" "$aap_failure"; then
        _check_pass "AAP '$aap_name' deployed successfully"
      elif [ "$aap_failure" = "True" ]; then
        local fail_msg
        fail_msg=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failure")].message}' 2>/dev/null || echo "")
        _check_fail "AAP '$aap_name' has failures: ${fail_msg:-unknown}"
      else
        _check_warn "AAP '$aap_name' is still reconciling"
      fi
    fi

    # Check pods
    local total_pods running_pods problem_pods
    total_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -cv "Completed" || true)
    running_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "Running" || true)
    problem_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -cE "CrashLoopBackOff|Error|ImagePullBackOff|Pending" || true)

    if [ "${problem_pods:-0}" -gt 0 ]; then
      _check_fail "$problem_pods pod(s) in error state ($running_pods/${total_pods:-0} running)"
      local problem_list
      problem_list=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -E "CrashLoopBackOff|Error|ImagePullBackOff|Pending" || true)
      if [ -n "$problem_list" ]; then
        while IFS= read -r line; do
          _check_info "  $line"
        done <<<"$problem_list"
      fi

    elif [ "${total_pods:-0}" -gt 0 ]; then
      _check_pass "All pods healthy ($running_pods/$total_pods running)"
    fi

    # Check PVCs
    local pending_pvcs
    pending_pvcs=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "Pending" || true)
    if [ "${pending_pvcs:-0}" -gt 0 ]; then
      _check_fail "$pending_pvcs PVC(s) pending"
      local pending_list
      pending_list=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep "Pending" || true)
      if [ -n "$pending_list" ]; then
        while IFS= read -r line; do
          _check_info "  $line"
        done <<<"$pending_list"
      fi
    else
      local bound_pvcs
      bound_pvcs=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "Bound" || true)
      if [ "$bound_pvcs" -gt 0 ]; then
        _check_pass "All PVCs bound ($bound_pvcs)"
      fi
    fi
  fi
  echo ""

  # =========================================================================
  # DNS
  # =========================================================================
  echo ""
  echo "DNS:"
  local coredns_running corefile
  coredns_running=$(kubectl get pods -n openshift-dns --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  if [ "$coredns_running" -gt 0 ]; then
    _check_pass "CoreDNS running ($coredns_running pods)"
  else
    _check_warn "CoreDNS pods not found in openshift-dns"
  fi
  corefile=$(kubectl get configmap dns-default -n openshift-dns \
    -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")
  if echo "$corefile" | grep -q "router-internal-default"; then
    _check_pass "CoreDNS route rewrite present"
  elif [ -n "$corefile" ]; then
    _check_fail "CoreDNS missing rewrite for apps.<domain> route hostnames"
    _check_info "AO/portal/MCP cannot resolve AAP routes from inside the cluster"
    verify_coredns
    corefile=$(kubectl get configmap dns-default -n openshift-dns \
      -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")
    if echo "$corefile" | grep -q "router-internal-default"; then
      _check_pass "CoreDNS route rewrite restored"
    else
      _check_info "Fix: aap-demo start   (or aap-demo wire / aap-demo enable ao)"
    fi
  fi
  echo ""

  # =========================================================================
  # Summary
  # =========================================================================
  echo "─────────────────────────────────────"
  if [ "$issues" -eq 0 ] && [ "$warnings" -eq 0 ]; then
    printf "\033[32m✓ All checks passed — environment is healthy\033[0m\n"
  elif [ "$issues" -eq 0 ]; then
    printf "\033[33m⚠ %d warning(s), no critical issues\033[0m\n" "$warnings"
  else
    printf "\033[31m✗ %d issue(s), %d warning(s)\033[0m\n" "$issues" "$warnings"
    echo ""
    echo "For detailed diagnostics: aap-demo must-gather"
    echo "For AI-assisted analysis:  aap-demo diagnose --ai"
  fi

  # AI analysis mode
  if [ "${_DIAGNOSE_AI:-false}" = "true" ]; then
    echo ""

    if ! command -v claude &>/dev/null; then
      echo "✗ 'claude' CLI not found"
      echo "  Install: https://docs.anthropic.com/en/docs/claude-code"
      return 1
    fi

    echo "─────────────────────────────────────"
    printf "\033[1mAI Analysis\033[0m (powered by Claude)\n"
    echo ""

    echo "(Diagnostic data is sent to the Claude API for analysis)"
    echo ""

    # Collect additional context for AI — cache pod list to avoid duplicate kubectl calls
    local pod_output
    pod_output=$(kubectl get pods -n "$NAMESPACE" -o wide --no-headers 2>/dev/null || echo "No pods")
    local problem_pod_names
    problem_pod_names=$(echo "$pod_output" | grep -E "CrashLoopBackOff|Error|ImagePullBackOff|Pending" | awk '{print $1}' || true)
    local problem_pod_logs=""
    if [ -n "$problem_pod_names" ]; then
      while IFS= read -r pod; do
        problem_pod_logs="${problem_pod_logs}--- ${pod} ---
$(kubectl logs "$pod" -n "$NAMESPACE" --tail=20 2>/dev/null || true)
"
      done <<<"$problem_pod_names"
    fi

    local ai_context
    ai_context="AAP Demo Diagnose Results:
Issues: $issues, Warnings: $warnings
Infra: OpenShift Local (CRC)
Namespace: $NAMESPACE

Cluster State:
$pod_output

PVC State:
$(kubectl get pvc -n "$NAMESPACE" 2>/dev/null || echo "No PVCs")

Storage Classes:
$(kubectl get sc 2>/dev/null || echo "No storage classes")

AAP CR Status:
$(kubectl get aap -n "$NAMESPACE" -o yaml 2>/dev/null | grep -A20 "status:" || echo "No AAP CR")

Recent Events:
$(kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || echo "No events")

Problem Pods:
$(echo "$pod_output" | grep -E "CrashLoopBackOff|Error|ImagePullBackOff|Pending" || echo "None")

Problem Pod Logs:
${problem_pod_logs:-None}"

    echo "$ai_context" | claude -p \
      "You are an AAP Demo troubleshooting assistant. Analyze the diagnostic output below and:
1. Identify the root cause of any issues
2. Provide specific fix commands the user can run
3. If the issue appears to be a bug in aap-demo itself, suggest filing a GitHub issue at https://github.com/RedHatOfficial/aap-demo/issues

Be concise and actionable. Focus on what the user needs to do next.

Diagnostic data:" 2>&1 || {
      echo ""
      echo "⚠ AI analysis failed. The diagnostic data above should help with manual troubleshooting."
    }
  fi
}

cmd_ssh() {
  # Ensure infra backend is loaded to set CRC_SSH_KEY
  _infra_ensure_backend 2>/dev/null || true
  if [ -z "$CRC_SSH_KEY" ]; then
    _err "No CRC SSH key found. Is OpenShift Local running?"
    return 1
  fi
  exec ssh -p 2222 -i "$CRC_SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@127.0.0.1
}

cmd_kubeconfig() {
  echo ""
  printf "\033[1maap-demo kubeconfig\033[0m - Syncing local aap-demo kubeconfig...\n"
  echo ""

  # Temp file tracking for cleanup
  TEMP_FILES=()
  cleanup_temp_files() {
    for f in "${TEMP_FILES[@]}"; do
      rm -f "$f" 2>/dev/null
    done
  }
  trap cleanup_temp_files EXIT

  # Check cluster is reachable
  local cluster_name
  cluster_name=$(infra_get_name 2>/dev/null || echo "")
  if [ -z "$cluster_name" ]; then
    echo "  ERROR: Cluster not running"
    echo "         Run 'aap-demo create' first"
    exit 1
  fi

  # Extract kubeconfig with validation
  echo "  Extracting kubeconfig from ${cluster_name}..."
  mkdir -p "$AAP_DEMO_DIR"
  TEMP_KUBECONFIG=$(mktemp)
  TEMP_FILES+=("$TEMP_KUBECONFIG")
  chmod 600 "$TEMP_KUBECONFIG"

  if ! infra_get_kubeconfig "$TEMP_KUBECONFIG" 2>/dev/null; then
    echo "  ERROR: Failed to extract kubeconfig"
    echo "         OpenShift Local may still be initializing. Wait and retry."
    exit 1
  fi

  # Validate extracted kubeconfig
  if ! KUBECONFIG="$TEMP_KUBECONFIG" kubectl config view >/dev/null 2>&1; then
    echo "  ERROR: Extracted kubeconfig is invalid"
    echo "         OpenShift Local may still be initializing. Wait and retry."
    exit 1
  fi

  # Rename context/cluster/user to unique names before saving
  # OpenShift Local defaults to generic names (microshift, user) that collide
  local ctx_name="aap-demo"
  KUBECONFIG="$TEMP_KUBECONFIG" kubectl config rename-context microshift "$ctx_name" >/dev/null 2>&1 || true
  KUBECONFIG="$TEMP_KUBECONFIG" kubectl config set-context "$ctx_name" --cluster="$ctx_name" --user="$ctx_name" >/dev/null 2>&1 || true
  # Rename cluster entry
  local server
  server=$(KUBECONFIG="$TEMP_KUBECONFIG" kubectl config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
  KUBECONFIG="$TEMP_KUBECONFIG" kubectl config set-cluster "$ctx_name" --server="$server" --insecure-skip-tls-verify=true >/dev/null 2>&1
  KUBECONFIG="$TEMP_KUBECONFIG" kubectl config unset clusters.microshift >/dev/null 2>&1 || true
  # Copy user credentials to new name
  local client_cert client_key
  client_cert=$(KUBECONFIG="$TEMP_KUBECONFIG" kubectl config view --raw -o jsonpath='{.users[?(@.name=="user")].user.client-certificate-data}' 2>/dev/null)
  client_key=$(KUBECONFIG="$TEMP_KUBECONFIG" kubectl config view --raw -o jsonpath='{.users[?(@.name=="user")].user.client-key-data}' 2>/dev/null)
  if [ -n "$client_cert" ]; then
    KUBECONFIG="$TEMP_KUBECONFIG" kubectl config set-credentials "$ctx_name" \
      --client-certificate=<(echo "$client_cert" | base64 -d) \
      --client-key=<(echo "$client_key" | base64 -d) \
      --embed-certs=true >/dev/null 2>&1
    KUBECONFIG="$TEMP_KUBECONFIG" kubectl config unset users.user >/dev/null 2>&1 || true
  fi
  KUBECONFIG="$TEMP_KUBECONFIG" kubectl config use-context "$ctx_name" >/dev/null 2>&1

  mv "$TEMP_KUBECONFIG" "$AAP_DEMO_KUBECONFIG"
  TEMP_FILES=() # Clear since file was moved successfully
  chmod 600 "$AAP_DEMO_KUBECONFIG"
  echo "  ✓ Saved to $AAP_DEMO_KUBECONFIG"
  export KUBECONFIG="$AAP_DEMO_KUBECONFIG"

  trap - EXIT
  echo ""
  echo "  kubectl now connects to OpenShift Local cluster."
  echo "  Context: $ctx_name"
  echo "  export KUBECONFIG=$AAP_DEMO_KUBECONFIG"
}

_show_fleet_status() {
  if ! compgen -G "${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet/node-*/meta" >/dev/null; then
    return 0
  fi
  source "${SCRIPT_DIR}/addons/fleet/fleet.sh"
  local fleet_nodes mode=omit
  [ "$SHOW_SECRETS" != true ] || mode=include
  fleet_nodes=$(fleet_access_inventory "$mode") || return 1
  echo "Fleet:"
  echo "-----------"
  fleet_list
  jq -r '.[] | "  \(.hostname): ssh -p \(.ssh_port) \(.username)@\(.ssh_host)\n    Guest IP: \(.guest_ip // "not discovered")" +
    (if .password != null then "\n    Username: \(.username)\n    Password: \(.password)" else "" end)' <<<"$fleet_nodes"
  echo ""
}

cmd_status() {
  echo ""
  printf "\033[1mAAP Demo Status\033[0m\n"
  echo "==============="
  printf "Tool:        %s\n" "$(aap_demo_version_short)"
  printf "Built:       %s\n" "$AAP_DEMO_GIT_DATE"
  echo ""

  # Check cluster status via infra abstraction
  local cluster_state
  cluster_state=$(infra_get_state 2>/dev/null || echo "not_created")
  local cluster_name
  cluster_name=$(infra_get_name 2>/dev/null || echo "")

  printf "Infra:       OpenShift Local (CRC)\n"

  if [ "$cluster_state" = "running" ]; then
    printf "Cluster:     \033[1;32mrunning\033[0m"
    [ -n "$cluster_name" ] && printf " (%s)" "$cluster_name"
    echo ""
  elif [ "$cluster_state" = "stopped" ]; then
    printf "Cluster:     \033[1;33mstopped\033[0m\n"
    echo ""
    echo "Start with: crc start"
    _show_fleet_status || return 1
    return 0
  else
    printf "Cluster:     \033[1;31mnot running\033[0m\n"
    echo ""
    echo "Start with: aap-demo create"
    _show_fleet_status || return 1
    return 0
  fi

  # Status must inspect CRC state before touching Kubernetes. A stopped CRC
  # VM, or a VM with an unhealthy API server, can leave a stale kubeconfig
  # probe hanging indefinitely.
  setup_kubeconfig

  # Export CA env vars if installed, don't prompt for sudo
  local ca_path
  ca_path=$(get_ingress_ca_cert_path)
  if [ -f "$ca_path" ]; then
    _ingress_ca_export_env "$ca_path"
  fi

  echo ""
  echo "TLS:"
  echo "----"
  ingress_ca_trust_status "$ca_path" || true
  echo ""

  # Show kubeconfig
  echo "Kubeconfig:  $KUBECONFIG"
  echo "Source:      $AAP_DEMO_REPO_ROOT (branch: $AAP_DEMO_GIT_BRANCH)"
  [ -n "$AAP_DEMO_GIT_REMOTE" ] && echo "Repo:        $AAP_DEMO_GIT_REMOTE"

  echo ""
  echo "Host:"
  echo "-----"
  local host_os host_arch
  host_os=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  host_arch=$(uname -m 2>/dev/null || echo "unknown")
  echo "  OS:           ${host_os:-unknown}"
  echo "  Architecture: $host_arch"

  # VM stats
  echo ""
  echo "VM:"
  echo "---"
  local vm_info
  vm_info=$(infra_exec_cmd bash -c '
        # RHEL version
        RHEL=$(cat /etc/redhat-release 2>/dev/null || echo "unknown")
        # OpenShift version
        USHIFT=$(microshift version 2>/dev/null | awk "/MicroShift Version:/{print \$3}" || rpm -q microshift --qf "%{VERSION}" 2>/dev/null || echo "unknown")
        # CPU
        CPUS=$(nproc)
        # Memory
        MEM_TOTAL=$(free -h | awk "/Mem:/{print \$2}")
        MEM_USED=$(free -h | awk "/Mem:/{print \$3}")
        MEM_AVAIL=$(free -h | awk "/Mem:/{print \$7}")
        # Load
        LOAD=$(cat /proc/loadavg | awk "{print \$1, \$2, \$3}")
        # Disk
        DISK=$(df -h /var 2>/dev/null | awk "NR==2{print \$3\"/\"\$2\" (\" \$5 \" used)\"}")
        echo "  Guest OS:     $RHEL"
        echo "  OpenShift:    $USHIFT"
        echo "  CPUs:         $CPUS"
        echo "  Memory:       ${MEM_USED} / ${MEM_TOTAL} (${MEM_AVAIL} available)"
        echo "  Load:         $LOAD"
        echo "  Disk:         $DISK"
  ' 2>/dev/null)
  echo "$vm_info"
  persistent_crio_store_status
  echo ""

  # List application namespaces with pod counts (skip openshift-* and kube-* system namespaces)
  echo "Namespaces:"
  echo "-----------"
  NAMESPACES=$(kubectl get ns --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
    | grep -vE '^(openshift|kube-|default$)' | sort)

  if [ -z "$NAMESPACES" ]; then
    echo "  (no application namespaces found)"
  else
    for ns in $NAMESPACES; do
      POD_TOTAL=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -cv Completed 2>/dev/null | tr -d "
" || echo 0)
      POD_RUNNING=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null || true)
      [ -z "$POD_RUNNING" ] && POD_RUNNING=0
      # Skip empty namespaces
      if [ "$POD_TOTAL" -eq 0 ] 2>/dev/null; then continue; fi
      AAP_CR=$(kubectl get aap -n "$ns" --no-headers 2>/dev/null | awk '{print $1}' | head -1 || true)

      if [ -n "$AAP_CR" ]; then
        AAP_STATUS=$(kubectl get aap "$AAP_CR" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || echo "")
        AAP_RUNNING=$(kubectl get aap "$AAP_CR" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Running")].status}' 2>/dev/null || echo "")
        AAP_SUCCESSFUL_REASON=$(kubectl get aap "$AAP_CR" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Successful")].reason}' 2>/dev/null || echo "")
        AAP_FAILURE=$(kubectl get aap "$AAP_CR" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Failure")].status}' 2>/dev/null || echo "")
        if aap_condition_is_complete "$AAP_STATUS" "$AAP_RUNNING" "$AAP_SUCCESSFUL_REASON" "$AAP_FAILURE"; then
          printf "  %-30s %s/%s pods   \033[1;32m%s\033[0m\n" "$ns" "$POD_RUNNING" "$POD_TOTAL" "$AAP_CR"
        else
          if [ "$AAP_RUNNING" = "True" ]; then
            printf "  %-30s %s/%s pods   \033[1;33m%s (Deploying)\033[0m\n" "$ns" "$POD_RUNNING" "$POD_TOTAL" "$AAP_CR"
          else
            printf "  %-30s %s/%s pods   %s\n" "$ns" "$POD_RUNNING" "$POD_TOTAL" "$AAP_CR"
          fi
        fi
      else
        printf "  %-30s %s/%s pods\n" "$ns" "$POD_RUNNING" "$POD_TOTAL"
      fi
    done
  fi
  echo ""

  # Show deployment routes (exclude OpenShift/system namespaces)
  echo "AAP Deployments:"
  echo "----------------"
  ROUTES=$(kubectl get route -A --no-headers 2>/dev/null \
    | grep -v -E '^(openshift-|kube-|aap-demo-)' \
    | awk '{printf "  https://%s\n", $3}' | sort -u)
  if [ -n "$ROUTES" ]; then
    echo "$ROUTES"
  else
    echo "  (no routes found)"
  fi
  echo ""

  # Reveal credentials only after an explicit interactive request.
  local _cred_namespaces _cred_found
  _cred_found=false
  if [ "$SHOW_SECRETS" = true ]; then
    _cred_namespaces=$(kubectl get aap -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u)
    for ns in $_cred_namespaces; do
      local ADMIN_PASSWORD=""
      local ADMIN_SECRET
      ADMIN_SECRET=$(kubectl get aap -n "$ns" -o jsonpath='{.items[0].status.adminPasswordSecret}' 2>/dev/null || true)
      if [ -n "$ADMIN_SECRET" ]; then
        ADMIN_PASSWORD=$(kubectl get secret -n "$ns" "$ADMIN_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
      fi
      if [ -z "$ADMIN_PASSWORD" ]; then
        for secret_name in myaap-admin-password aap-admin-password aap-controller-admin-password custom-admin-password; do
          ADMIN_PASSWORD=$(kubectl get secret -n "$ns" "$secret_name" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
          [ -n "$ADMIN_PASSWORD" ] && break
        done
      fi

      if [ -n "$ADMIN_PASSWORD" ]; then
        if [ "$_cred_found" = "false" ]; then
          echo "Credentials:"
          echo "------------"
          _cred_found=true
        fi
        printf "  %-20s admin / %s\n" "$ns:" "$ADMIN_PASSWORD"
      fi
    done
    [ "$_cred_found" = "true" ] && echo ""
  else
    echo "Credentials: hidden (run 'aap-demo status --show-secrets' in a terminal to reveal)"
    echo ""
  fi

  # Show credentials for Automation Orchestrator (ao addon)
  if [ "$SHOW_SECRETS" = true ] \
    && { echo "$(_addons_list)" | grep -qw "ao" || kubectl get namespace automation-orchestrator &>/dev/null 2>&1; }; then
    local _ao_ns="automation-orchestrator"
    local _ao_pw="" _ao_secret=""
    _ao_secret=$(kubectl get secret -n "$_ao_ns" -o name 2>/dev/null | grep -i "admin-password" | head -1 || true)
    if [ -n "$_ao_secret" ]; then
      _ao_pw=$(kubectl get "$_ao_secret" -n "$_ao_ns" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi
    if [ -n "$_ao_pw" ]; then
      if [ "$_cred_found" = "false" ]; then
        echo "Credentials:"
        echo "------------"
      fi
      printf "  %-20s admin / %s\n" "$_ao_ns:" "$_ao_pw"
      _cred_found=true
      echo ""
    fi
  fi

  if [ "$SHOW_SECRETS" = true ]; then
    local crc_access crc_identity
    crc_access=$(_aap_demo_inventory_crc_access) || return 1
    crc_identity=$(jq -r '.ssh_key // empty' <<<"$crc_access")
    echo "CRC SSH Access:"
    echo "---------------"
    printf '  crc_ip: %s\n' "$(jq -r '.crc_ip // "unavailable"' <<<"$crc_access")"
    echo "  SSH: aap-demo ssh"
    if [ -n "$crc_identity" ]; then
      printf '  Direct command: ssh -i %q -o IdentitiesOnly=yes -p 2222 core@127.0.0.1\n' "$crc_identity"
    fi
    echo ""
  fi

  # Show addons with URLs or enable instructions
  local saved_addons
  saved_addons=$(_addons_list)
  echo "Addons:"
  echo "-------"
  for a in $AVAILABLE_ADDONS; do
    local url="" label="" enabled=false
    if echo "$saved_addons" | grep -qw "$a"; then
      enabled=true
    fi
    case "$a" in
      fleet)
        if [ "$enabled" = true ]; then
          if [ -d "${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet" ] && [ -f "${SCRIPT_DIR}/addons/fleet/fleet.sh" ]; then
            source "${SCRIPT_DIR}/addons/fleet/fleet.sh"
            local _fc
            _fc=$(fleet_count 2>/dev/null || echo "0")
            if [ "$_fc" -gt 0 ] 2>/dev/null; then
              label="${_fc} node(s) running"
            else
              label="enabled (no nodes)"
            fi
          else
            label="enabled"
          fi
        else
          label="disabled"
        fi
        ;;
      mcp-server)
        if [ "$enabled" = true ]; then
          url="https://aap-mcp-${NAMESPACE:-aap-operator}.$(aap_demo_route_domain)/mcp"
          if ! kubectl get ansiblemcpserver aap-mcp-server -n "${NAMESPACE:-aap-operator}" &>/dev/null; then
            label="not-deployed"
          fi
        else
          label="disabled"
        fi
        ;;
      portal)
        if [ "$enabled" = true ]; then
          url="https://$(kubectl get route redhat-rhaap-portal -n redhat-rhaap-portal -o jsonpath='{.spec.host}' 2>/dev/null || kubectl get route redhat-rhaap-portal -n ${NAMESPACE:-aap-operator} -o jsonpath='{.spec.host}' 2>/dev/null || true)"
          if [ -z "$url" ] || [ "$url" = "https://" ]; then
            url=""
            label="not-deployed"
          fi
        else
          label="disabled"
        fi
        ;;
      portal-operator)
        local _note=" (AMD64 only)"
        if [ "$enabled" = true ]; then
          label="enabled${_note}"
        else
          label="disabled${_note}"
        fi
        ;;
      ao)
        if [ "$enabled" = true ] || kubectl get namespace automation-orchestrator &>/dev/null 2>&1; then
          label="enabled"
        else
          label="disabled"
        fi
        ;;
      *)
        if [ "$enabled" = true ]; then
          label="enabled"
        else
          label="disabled"
        fi
        ;;
    esac
    if [ -n "$url" ] && [ -z "$label" ]; then
      printf "  %-15s %s\n" "$a" "$url"
    elif [ -n "$label" ]; then
      printf "  %-15s %s\n" "$a" "$label"
    else
      printf "  %-15s disabled\n" "$a"
    fi
  done
  echo ""

  _show_fleet_status
}

cmd_status_json() {
  local cluster_state
  cluster_state=$(infra_get_state 2>/dev/null || echo "not_created")
  if [ "$cluster_state" = running ]; then
    if ! setup_kubeconfig >/dev/null; then
      echo "ERROR: Could not configure Kubernetes access for JSON status" >&2
      return 1
    fi
  fi
  aap_demo_collect_system_inventory omit | jq .
}

cmd_system_info() {
  local cluster_state secret_mode="redact" format="markdown" output
  cluster_state=$(infra_get_state 2>/dev/null || echo "not_created")
  if [ "$cluster_state" = running ]; then
    if ! setup_kubeconfig >/dev/null; then
      echo "ERROR: Could not configure Kubernetes access for system information" >&2
      return 1
    fi
  fi

  [ "$REDACT" = true ] && secret_mode="redact"
  [ "$OUTPUT_JSON" = true ] && format="json"

  if [ -n "$SYSTEM_INFO_OUTPUT" ]; then
    output="$SYSTEM_INFO_OUTPUT"
  elif [ "$OUTPUT_JSON" = true ] || [ "$REDACT" = true ]; then
    output="-"
  else
    output="${AAP_DEMO_SYSTEM_INFO_FILE:-${SCRIPT_DIR}/docs/aap-demo-system-info.md}"
  fi
  aap_demo_generate_system_info "$secret_mode" "$format" "$output"
}

cmd_redeploy() {
  # Ensure cluster is accessible (auto-create if needed)
  _verify_cluster || exit 1

  _clean_operator

  # Small pause
  sleep 2

  # Deploy fresh
  echo ""
  echo "Redeploying AAP..."
  echo ""

  deploy_latest || return 1
  aap_demo_generate_system_info
}

cmd_redeploy-all() {
  local saved_addons
  saved_addons=$(_addons_list)
  aap_demo_validate_redeploy_addon_capacity "$saved_addons" || return 1

  # Destroy existing cluster (warning shown by cmd_destroy)
  cmd_destroy || return 1
  # cmd_destroy removes addon state as resources are deleted. Restore the
  # original selection immediately so partial failures remain retryable.
  aap_demo_preserve_addon_selection "$saved_addons"

  # Small pause
  sleep 2

  # Run full deploy flow (creates cluster, setup, deploy)
  cmd_deploy || return 1

  # Addon names survive cluster deletion in ~/.aap-demo/config, but their
  # Kubernetes resources do not. Reinstall them and restore integrations.
  aap_demo_restore_addons "$saved_addons" || return 1
  aap_demo_generate_system_info
}

_remove_temp_swap() {
  [ "$(uname -s)" = "Linux" ] || return 0

  if [ ! -f "${SCRIPT_DIR}/includes/temp-swap.sh" ]; then
    return 0
  fi

  # shellcheck source=includes/temp-swap.sh
  source "${SCRIPT_DIR}/includes/temp-swap.sh"
  echo ""
  echo "Removing temp swap..."
  if aap_demo_temp_swap_disable; then
    return 0
  fi
  echo "  ⚠ Temp swap removal failed (sudo may be required)"
  echo "    Run: ${SCRIPT_DIR}/scripts/enable-temp-swap.sh disable"
  return 1
}
_maybe_save_local_cache_before_destroy() {
  if [ "${_DESTROY_SKIP_CACHE:-false}" = "true" ]; then
    echo "Skipping local image cache save and validation (--skip-cache)"
    return 0
  fi

  # Cache saving is intentionally opt-in: a full AAP image cache can use tens
  # of gigabytes and may take a while to create.
  if [ "${QUIET:-false}" = "true" ] || [ ! -t 0 ]; then
    return 0
  fi

  printf "Cache container images locally before destroying the cluster? [y/N]: "
  local _cache_choice=""
  read -r _cache_choice </dev/tty || _cache_choice=""
  case "${_cache_choice:-n}" in
    [yY]*)
      echo ""
      echo "The next deploy can reuse these cached containers instead of downloading them again."
      echo "Saving container images for the next deployment..."
      if ! bash "${SCRIPT_DIR}/addons/local-cache/deploy.sh" save; then
        echo "⚠ Could not save the local image cache — continuing with cluster deletion"
      elif ! bash "${SCRIPT_DIR}/addons/local-cache/deploy.sh" validate; then
        echo "⚠ Local image cache validation failed — continuing with cluster deletion"
      fi
      ;;
    *)
      echo ""
      ;;
  esac
}

cmd_destroy() {
  _maybe_save_local_cache_before_destroy
  local _cache_status=$?
  [ "$_cache_status" -eq 0 ] || return "$_cache_status"
  echo ""
  printf "\033[1maap-demo destroy\033[0m - Deleting CRC cluster...\n"
  echo ""
  echo "✗  WARNING: This will DELETE the entire CRC cluster!"
  echo ""
  echo "  • All cluster data will be PERMANENTLY DESTROYED"
  echo "  • All PVC storage will be LOST"
  echo "  • All deployed applications will be removed"
  if [ "$(uname -s)" = "Linux" ]; then
    echo "  • Temp swap file (if any) will be removed"
  fi
  echo "  • You will need to redeploy AAP from scratch"
  echo ""
  if [ "${QUIET:-false}" != "true" ]; then
    echo "Press Ctrl+C to cancel, or press Enter to continue..."
    echo "Auto-continuing in 10 seconds..."
    read -t 10 -r || true
    echo ""
  fi
  if ! persistent_crio_store_detach; then
    echo "✗ Persistent CRI-O image storage could not be detached — refusing to delete the cluster"
    return 1
  fi

  # Clean up fleet nodes before destroying cluster (addon)
  if [ -d "${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet" ] && [ -f "${SCRIPT_DIR}/addons/fleet/fleet.sh" ]; then
    source "${SCRIPT_DIR}/addons/fleet/fleet.sh"
    fleet_destroy_all
  fi
  if crc delete -f 2>/dev/null || crc delete 2>/dev/null; then
    podman system connection remove aap-demo 2>/dev/null || true
    _addons_save ""
    echo "✓ CRC cluster deleted"
    if [ "${_DESTROY_RESET:-false}" = "true" ]; then
      rm -f "$AAP_DEMO_CONFIG"
      echo "✓ Config reset — next 'aap-demo create' will start fresh"
    fi
  else
    echo "✗ CRC delete failed — config preserved"
  fi
  _remove_temp_swap || true
}

cmd_stop() {
  echo ""
  printf "\033[1maap-demo stop\033[0m - Stopping CRC cluster...\n"

  # Stop Fleet VMs while preserving their overlay disks for restart.
  if [ -d "${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet" ] && [ -f "${SCRIPT_DIR}/addons/fleet/fleet.sh" ]; then
    source "${SCRIPT_DIR}/addons/fleet/fleet.sh"
    fleet_stop_all
    echo "  (Restart preserved Fleet nodes with: aap-demo fleet start)"
  fi

  if ! crc stop; then
    _err "Failed to stop the CRC cluster"
    return 1
  fi
  echo "✓ CRC cluster stopped"
  echo "To restart: aap-demo start"
}

cmd_start() {
  local crc_create_script="${AAP_DEMO_CRC_CREATE_SCRIPT:-${SCRIPT_DIR}/includes/crc-create.sh}"
  local addons tool
  local AAP_START_TIMEOUT="${AAP_START_TIMEOUT:-600}"
  if ! [[ "$AAP_START_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    _err "AAP_START_TIMEOUT must be a positive number of seconds"
    return 1
  fi
  for tool in kubectl jq curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      _err "Required tool not found: $tool"
      return 1
    fi
  done
  addons=$(_addons_list) || return 1
  echo ""
  printf "\033[1maap-demo start\033[0m - Resuming the configured demo...\n"
  _start_crc_cluster || return 1
  setup_kubeconfig
  aap_demo_start_storage || return 1
  aap_demo_start_wait "Kubernetes API" aap_demo_start_api_ready || return 1
  kubectl wait --for=condition=Ready nodes --all --timeout="${AAP_START_TIMEOUT}s" || return 1

  # Re-apply CoreDNS config (fixes DNS after restarts)
  if [ -f "$crc_create_script" ]; then
    if ! AAP_DEMO_CONFIGURE_COREDNS_ONLY=1 bash -c '
      source "$1"
      configure_coredns
    ' bash "$crc_create_script"; then
      _err "Failed to restore CoreDNS after cluster start"
      return 1
    fi
  else
    _err "CoreDNS recovery script not found: $crc_create_script"
    return 1
  fi

  _recover_aap_catalog_after_start || return 1
  aap_demo_resume_demo "$addons" || return 1

  echo "✓ Demo ready"
  echo ""
  cmd_status
  echo ""
  printf 'For kubectl in this terminal: export KUBECONFIG="%s"\n' "$KUBECONFIG"
}

_recover_aap_catalog_after_start() {
  local catalog_namespace="${NAMESPACE:-aap-operator}"
  local catalog_name="redhat-operators"
  local catalog_status

  if ! kubectl get catalogsource "$catalog_name" -n "$catalog_namespace" &>/dev/null; then
    return 0
  fi

  catalog_status=$(kubectl get catalogsource "$catalog_name" -n "$catalog_namespace" \
    -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
  if [ "$catalog_status" = "READY" ]; then
    echo "✓ AAP operator catalog ready"
    return 0
  fi

  echo "Waiting for AAP operator catalog to recover after restart..."
  # shellcheck source=includes/olm-catalog-signature.sh
  source "${SCRIPT_DIR}/includes/olm-catalog-signature.sh"

  # A ready catalog pod with a non-ready CatalogSource indicates stale OLM
  # connection state after a forced VM stop. Restart only the catalog operator.
  if catalog_pod_is_ready "$catalog_namespace" "$catalog_name"; then
    echo "  Restarting OLM catalog operator to refresh the catalog connection..."
    kubectl rollout restart deployment/catalog-operator -n olm >/dev/null \
      || {
        echo "ERROR: Failed to restart the OLM catalog operator." >&2
        return 1
      }
    aap_demo_wait_deployment olm catalog-operator 5m >/dev/null || return 1
  fi

  if ! AAP_CATALOG_TIMEOUT="${AAP_START_CATALOG_TIMEOUT:-600}" \
    wait_for_catalog_ready "$catalog_namespace" "$catalog_name"; then
    echo "ERROR: AAP operator catalog did not recover after cluster start." >&2
    echo "  Check: kubectl get catalogsource $catalog_name -n $catalog_namespace" >&2
    return 1
  fi
  echo "✓ AAP operator catalog ready"
}

_start_crc_cluster() {
  if ! crc start; then
    _err "Failed to start the CRC cluster"
    return 1
  fi
  persistent_crio_store_prepare_or_fallback || return 1
  if [ -f /etc/resolver/testing ]; then
    sudo rm -f /etc/resolver/testing
  fi
}

cmd_create() {
  # Show notice (skip if already shown or quiet mode)
  if [ "$QUIET" != "true" ] && [ "${AAP_DEMO_NOTICE_SHOWN:-}" != "1" ]; then
    bash "${SCRIPT_DIR}/includes/aap-demo-notice.sh" || true
    AAP_DEMO_NOTICE_SHOWN=1
  fi

  if ! bash "${SCRIPT_DIR}/includes/crc-create.sh"; then
    _err "OpenShift Local cluster creation failed"
    exit 1
  fi

  persistent_crio_store_prepare_or_fallback

  install_ingress_ca_trust
  setup_kubeconfig
}

cmd_full_demo() {
  local caller_quiet="${QUIET:-false}"
  local ADDONS="mcp-server,setup-pah,product-demos,ollama,ao,fleet"
  local cluster_state

  echo ""
  printf "\033[1maap-demo create --full-demo\033[0m - Building complete local demo...\n"
  echo ""
  echo "Workflow:"
  echo "  1. Configure Red Hat Customer Portal and CDN credentials"
  echo "  2. Create OpenShift Local cluster"
  echo "  3. Deploy AAP 2.7"
  echo "  4. Configure Automation Hub and enable offline-token keepalive"
  echo "  5. Enable Ollama and Automation Orchestrator"
  echo "  6. Enable Fleet, attach the AAP subscription, and register three RHEL 9 nodes"
  echo "  7. Enable Product Demos"
  echo "  8. Reapply all integrations"
  echo "  9. Install boot recovery (restores CRC settings/state on reboot) and launch dashboard"
  echo ""

  if ! cmd_fleet auth status; then
    echo ""
    echo "Red Hat Fleet credentials need to be configured before provisioning."
    if [ "$caller_quiet" = true ]; then
      echo "ERROR: Full demo cannot prompt for credentials with QUIET=true." >&2
      echo "  Run interactively, or configure them first: aap-demo fleet auth" >&2
      return 1
    fi
    if ! (: <"$AAP_DEMO_SECRET_PROMPT_DEVICE") 2>/dev/null; then
      echo "ERROR: Full demo needs an interactive terminal to configure credentials." >&2
      echo "  Run in a terminal, or configure them first: aap-demo fleet auth" >&2
      return 1
    fi
    echo "Starting secure Red Hat credential setup..."
    QUIET=false cmd_fleet auth configure || {
      echo "ERROR: Red Hat Fleet credential setup did not complete." >&2
      return 1
    }
    cmd_fleet auth status || {
      echo "ERROR: Red Hat Fleet credentials are still invalid after setup." >&2
      return 1
    }
  fi

  local QUIET=true
  export QUIET ADDONS

  cluster_state=$(infra_get_state 2>/dev/null || echo "not_created")
  if [ "$cluster_state" = running ]; then
    echo "✓ OpenShift Local cluster is already running; reusing it"
  elif aap_demo_service_managed; then
    echo "Resuming the existing managed demo without recreating CRC..."
    cmd_start || return 1
  else
    cmd_create || return 1
  fi
  AAP_DEMO_SKIP_STANDARD_AO=true cmd_deploy || return 1
  cmd_enable setup-pah || return 1
  cmd_credentials keepalive enable || return 1
  cmd_enable ollama || return 1
  AO_LLM_PROVIDER=ollama cmd_enable ao || return 1
  cmd_enable fleet || return 1

  local fleet_nodes missing_nodes
  fleet_nodes=$(fleet_count 2>/dev/null || echo 0)
  if [ "$fleet_nodes" -lt 3 ]; then
    missing_nodes=$((3 - fleet_nodes))
    cmd_fleet add "$missing_nodes" --image rhel9 || return 1
  else
    echo "✓ Fleet already has ${fleet_nodes} node(s); reusing them"
  fi
  cmd_fleet start || return 1
  cmd_fleet register || return 1

  # The OpenShift demo domain provisions Windows/CNV VMs (BSOD Recovery,
  # WinPE, CNV) that cannot run on the all-Linux Fleet nodes, and its
  # upstream workflow content fails on this environment. Skip it by default;
  # override with PRODUCT_DEMOS_DOMAINS to include it.
  PRODUCT_DEMOS_DOMAINS="${PRODUCT_DEMOS_DOMAINS:-linux windows network cloud}" \
    cmd_enable product-demos || return 1
  cmd_wire || return 1
  aap_demo_generate_system_info || return 1

  echo ""
  _aap_demo_release_operation_lock
  echo "  Installing boot recovery (requires sudo)..."
  cmd_service install || {
    echo "ERROR: Full demo boot recovery could not be installed. Resolve the error and rerun: aap-demo create --full-demo" >&2
    return 1
  }
  echo ""
  echo "  Launching the aap-demo dashboard..."
  cmd_dashboard || return 1
  _aap_demo_auto_console
  echo ""
  echo "✓ Full demo environment and automatic recovery are ready"
  echo "  AAP, Product Demos, Automation Orchestrator, Ollama, and three Fleet nodes are configured."
}

cmd_credentials() {
  if [ "${1:-}" != keepalive ]; then
    _err "Usage: aap-demo credentials keepalive [setup|enable|status|disable|run]"
    return 2
  fi
  bash "${SCRIPT_DIR}/scripts/aap-demo-token-keepalive.sh" "${2:-status}"
}

# shellcheck source=includes/galaxy-auth.sh
source "${SCRIPT_DIR}/includes/galaxy-auth.sh"

cmd_setup() {
  echo "CRC setup is handled during 'aap-demo create'"
}

_enable_standard_ao() {
  if [ "${AAP_DEMO_SKIP_STANDARD_AO:-false}" = "true" ]; then
    return 0
  fi
  if echo "$(_addons_list)" | grep -qw ao; then
    echo "✓ Automation Orchestrator is already enabled"
    return 0
  fi

  echo ""
  echo "Enabling Automation Orchestrator as part of the standard deployment..."
  cmd_enable ao
}

cmd_deploy() {
  # Show notice/disclaimer
  if [ "$QUIET" != "true" ] && [ "${AAP_DEMO_NOTICE_SHOWN:-}" != "1" ]; then
    bash "${SCRIPT_DIR}/includes/aap-demo-notice.sh" || true
    AAP_DEMO_NOTICE_SHOWN=1
  fi

  # Ensure OpenShift Local is running
  local crc_state
  crc_state=$(infra_get_state 2>/dev/null || echo "not_created")
  if [ "$crc_state" = "not_created" ]; then
    echo "No cluster found. Creating one first..."
    cmd_create
  elif [ "$crc_state" = "stopped" ]; then
    echo "Cluster is stopped. Starting..."
    _start_crc_cluster
  fi

  # Restore any cache left by a previous destroy before OLM and AAP begin
  # pulling images. This is independent of the local-cache addon setting so a
  # destroy/create cycle does not require re-enabling the addon first.
  _load_local_cache

  install_ingress_ca_trust

  # anyuid and privileged SCCs granted in setup_namespace() for all SAs in the namespace
  echo ""
  printf "\033[1maap-demo deploy\033[0m - Deploying AAP to OpenShift Local...\n"
  echo ""
  echo "Infrastructure: OpenShift Local"
  if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to cluster"
    echo "  Current context: $(kubectl config current-context 2>/dev/null || echo 'none')"
    echo "  Check your KUBECONFIG or use --context flag"
    exit 1
  fi
  echo "Connected to: $(kubectl config current-context 2>/dev/null)"
  echo ""

  # Verify CRC version matches required version
  _verify_crc_version || exit 1

  # The API can be available while OVN is still crash-looping. Do not create
  # OLM/AAP workloads until the cluster CNI can create pod sandboxes.
  _wait_for_ovn_ready || exit 1

  # Check if AAP already exists — skip OLM and the full deploy if so
  if [ "$FORCE" != "true" ]; then
    AAP_EXISTS=$(kubectl get aap -n "$NAMESPACE" 2>/dev/null | grep -v NAME | head -1 | awk '{print $1}' || true)
    if [ -n "$AAP_EXISTS" ]; then
      echo ""
      echo "✓ AAP instance '$AAP_EXISTS' already exists in namespace $NAMESPACE"
      echo "  Skipping installation, validating existing deployment..."
      echo "  (Use FORCE=true to reinstall)"
      echo ""
      _patch_gateway_capability
      watch_aap || return 1
      _enable_standard_ao || return 1
      aap_demo_generate_system_info || return 1
      return 0
    fi
  fi

  # Install OLM if not present (OpenShift Local doesn't include it)
  if ! KUBECONFIG="${KUBECONFIG:-$(aap_demo_resolve_kubeconfig)}" bash "${SCRIPT_DIR}/addons/olm/deploy.sh"; then
    printf "\n\033[1;31mERROR: OLM installation failed\033[0m\n"
    printf "OLM is required for AAP deployments. Please fix OLM before continuing.\n"
    printf "Try: \033[1maap-demo enable olm\033[0m\n\n"
    exit 1
  fi

  # Refresh kubeconfig before deploy (certs may have changed during OLM install)
  _verify_cluster || exit 1

  # Deploy AAP 2.7
  deploy_latest || return 1
  _enable_standard_ao || return 1
  aap_demo_generate_system_info
}

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

patch_operator_serviceaccounts() {
  if [ -n "$PULL_SECRET" ]; then
    echo ""
    echo "Patching operator ServiceAccounts with pull secret..."
    sleep 5
    for sa in $(kubectl get serviceaccount -n "$NAMESPACE" -o name 2>/dev/null | grep -E 'operator|controller' | sed 's|serviceaccount/||'); do
      kubectl patch serviceaccount "$sa" -n "$NAMESPACE" \
        -p '{"imagePullSecrets": [{"name": "redhat-operators-pull-secret"}]}' 2>/dev/null || true
    done
    echo "  ✓ Operator ServiceAccounts patched"
  fi
}

deploy_latest() {
  # Check disk space before deploying (latest catalog images are large)
  _check_disk_space || exit 1
  aap_demo_resource_preflight "AAP deployment" \
    "${AAP_DEPLOY_MIN_CPU_M:-2000}" "${AAP_DEPLOY_MIN_MEMORY_MI:-6144}" || exit 1

  echo ""
  echo "Deploying AAP from latest catalog..."
  echo "  Version: 2.7"
  echo "  Namespace: $NAMESPACE"
  echo ""

  AAP_CHANNEL="stable-2.7"
  # Auto-detect OCP version from CRC status (e.g. 4.22.0 → 4.22)
  if [ -z "${AAP_OCP_VERSION:-}" ]; then
    _crc_ocp_version=$(crc status -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('openshiftVersion',''))" 2>/dev/null || true)
    if [[ "$_crc_ocp_version" =~ ^([0-9]+\.[0-9]+) ]]; then
      AAP_OCP_VERSION="${BASH_REMATCH[1]}"
    else
      AAP_OCP_VERSION="4.20"
    fi
  fi

  # Validate OCP version format
  if ! [[ "$AAP_OCP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid AAP_OCP_VERSION: '$AAP_OCP_VERSION' (expected format: X.Y, e.g. 4.22)"
    exit 1
  fi

  # Setup namespace (creates aap-operator namespace + pull secret)
  setup_namespace
  verify_coredns

  # Relax container signature policy for operator index images (MicroShift 4.22+
  # enforces GPG signatures but the index images may fail verification).
  # Demo-only: disables signature verification for registry.redhat.io on the VM.
  # shellcheck source=includes/infra-crc.sh
  source "${SCRIPT_DIR}/includes/infra-crc.sh" 2>/dev/null || true
  # shellcheck source=includes/olm-catalog-signature.sh
  source "${SCRIPT_DIR}/includes/olm-catalog-signature.sh"
  _deploy_preset="$(aap_demo_detect_crc_preset)"
  if [ "$_deploy_preset" = "microshift" ] && needs_signature_policy_relaxation; then
    echo ""
    echo "Relaxing container signature policy for registry.redhat.io (MicroShift 4.22+)..."
    refresh_crc_ssh_config 2>/dev/null || true
    if ! maybe_relax_redhat_registry_signature_policy; then
      echo "  WARNING: Could not relax signature policy — catalog pull may fail"
      echo "  Try: crc start && aap-demo ssh   # verify VM SSH works, then re-run deploy"
    fi
  fi

  # Create CatalogSource in aap-operator namespace
  # (not openshift-marketplace — upstream OLM doesn't create pods there on OpenShift Local)
  echo ""
  _catalog_image="registry.redhat.io/redhat/redhat-operator-index:v${AAP_OCP_VERSION}"
  _cached_catalog_image="$(_cached_operator_catalog_ref "$AAP_OCP_VERSION")"
  if [ -n "$_cached_catalog_image" ]; then
    _catalog_image="$_cached_catalog_image"
    echo "Creating CatalogSource from cached digest (OCP $AAP_OCP_VERSION)..."
  else
    echo "Creating CatalogSource (OCP $AAP_OCP_VERSION)..."
  fi
  sed -e "s|image: registry.redhat.io/redhat/redhat-operator-index:v[0-9.]*|image: ${_catalog_image}|" \
    -e "s|namespace: aap-operator|namespace: $NAMESPACE|" \
    "${SCRIPT_DIR}/config/olm/catalogsource.yaml" | kubectl apply -f -

  # Wait for CatalogSource — skip if already READY
  _catsrc_status=$(kubectl get catalogsource redhat-operators -n "$NAMESPACE" \
    -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
  if [ "$_catsrc_status" = "READY" ]; then
    echo "  ✓ CatalogSource already ready"
    CATSRC_READY=true
  else
    echo ""
    echo "Waiting for CatalogSource to be ready..."
    echo "  (The operator index is multi-GB; this can take 10+ minutes on first pull)"
    if wait_for_catalog_ready "$NAMESPACE"; then
      echo "  ✓ CatalogSource is ready"
      CATSRC_READY=true
    else
      echo "✗ CatalogSource not ready after $(catalog_wait_timeout_seconds)s"
      echo "  Check: kubectl describe pod -n $NAMESPACE -l olm.catalogSource=redhat-operators"
      exit 1
    fi
  fi

  # Create OperatorGroup
  echo ""
  echo "Creating OperatorGroup..."
  sed -e "s|namespace: aap|namespace: $NAMESPACE|g" \
    -e "s|name: aap-og|name: ${NAMESPACE}-og|" \
    -e "s|- aap|- $NAMESPACE|" \
    "${SCRIPT_DIR}/config/olm/operatorgroup.yaml" | kubectl apply -f -

  # Create Subscription
  echo ""
  echo "Creating Subscription..."
  sed -e "s|namespace: aap|namespace: $NAMESPACE|" \
    -e "s|channel: stable-2.6|channel: $AAP_CHANNEL|" \
    "${SCRIPT_DIR}/config/olm/subscription.yaml" | kubectl apply -f -

  # OLM creates the operator deployment asynchronously after the Subscription
  # is applied. Rewrite immediately, then repeat during the CSV wait so a
  # cached digest is applied as soon as the generated workload appears.
  _rewrite_local_cache_refs

  # Wait for CSV
  echo ""
  echo "Waiting for CSV to be created..."
  CSV_NAME=""
  for i in $(seq 1 60); do
    _rewrite_local_cache_refs
    CSV_NAME=$(kubectl get csv -n "$NAMESPACE" 2>/dev/null | grep '^aap-operator\.' | awk '{print $1}' | head -1)
    if [ -n "$CSV_NAME" ]; then
      echo "Found CSV: $CSV_NAME"
      break
    fi
    echo "  Waiting for CSV... ($i/60)"
    sleep 10
  done

  if [ -z "$CSV_NAME" ]; then
    echo "✗ CSV not found after 10 minutes"
    echo "Check: kubectl get subscription -n $NAMESPACE"
    exit 1
  fi

  # Wait for CSV to succeed
  echo ""
  echo "Waiting for CSV to reach Succeeded phase..."
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded csv/"$CSV_NAME" -n "$NAMESPACE" --timeout=600s || true

  create_aap_instance

  # Watch deployment
  watch_aap
}

verify_coredns() {
  local corefile
  corefile=$(kubectl get configmap dns-default -n openshift-dns -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")
  if [ -z "$corefile" ]; then
    return 0
  fi

  local _needs_fix=false
  if [[ "$corefile" == *"rewrite"*"router-internal-default"* ]]; then
    if [[ "$corefile" == *"baseDomain:"* ]]; then
      printf "  \033[1;33mCoreDNS rewrite rule is malformed — fixing...\033[0m\n"
      _needs_fix=true
    fi
  else
    printf "  CoreDNS missing rewrite rule — configuring...\n"
    _needs_fix=true
  fi

  if [ "$_needs_fix" = true ] && [ -f "${SCRIPT_DIR}/includes/crc-create.sh" ]; then
    bash -c "
      AAP_DEMO_CONFIGURE_COREDNS_ONLY=1
      source '${SCRIPT_DIR}/includes/crc-create.sh'
      configure_coredns
    " || {
      printf "  \033[1;33mWARNING: CoreDNS auto-fix failed\033[0m\n"
      echo "  Run 'aap-demo create' to configure CoreDNS manually."
    }
  fi
}

_grant_sccs() {
  local ns="$1"
  local _rc=0
  if command -v oc &>/dev/null; then
    local _scc_output
    _scc_output=$(oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${ns}" 2>&1) || {
      _err "Failed to grant anyuid SCC to namespace ${ns}"
      echo "  oc output: $_scc_output"
      echo "  Fix manually: oc adm policy add-scc-to-group anyuid system:serviceaccounts:${ns}"
      _rc=1
    }
    _scc_output=$(oc adm policy add-scc-to-group privileged "system:serviceaccounts:${ns}" 2>&1) || {
      _err "Failed to grant privileged SCC to namespace ${ns}"
      echo "  oc output: $_scc_output"
      echo "  Fix manually: oc adm policy add-scc-to-group privileged system:serviceaccounts:${ns}"
      _rc=1
    }
  else
    # Fallback: apply SCCs via kubectl (OpenShift Local where oc may not be available)
    echo "  'oc' not found — granting SCCs via kubectl..."
    for scc_name in anyuid privileged; do
      local crb_name="system:openshift:scc:${scc_name}:${ns}"
      if ! kubectl get clusterrolebinding "$crb_name" &>/dev/null; then
        kubectl create clusterrolebinding "$crb_name" \
          --clusterrole="system:openshift:scc:${scc_name}" \
          --group="system:serviceaccounts:${ns}" 2>&1 || {
          _err "Failed to create ClusterRoleBinding for ${scc_name} SCC"
          _rc=1
        }
      fi
    done
  fi
  return $_rc
}

setup_namespace() {
  echo "Setting up namespace..."
  # If namespace is terminating, wait for it to finish (max 30s) then force-clear
  local _ns_status
  _ns_status=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$_ns_status" = "Terminating" ]; then
    echo "  Namespace $NAMESPACE is terminating, waiting..."
    for i in $(seq 1 15); do
      sleep 2
      _ns_status=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      [ "$_ns_status" != "Terminating" ] && break
    done
    # Force-clear if still stuck
    if [ "$_ns_status" = "Terminating" ]; then
      echo "  Force-clearing stuck namespace..."
      kubectl get namespace "$NAMESPACE" -o json 2>/dev/null | python3 -c "import sys,json; d=json.loads(sys.stdin.read() or '{}'); d[\"spec\"][\"finalizers\"]=[];print(json.dumps(d))" | kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f - 2>/dev/null || true
      sleep 2
    fi
  fi
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # Grant SCCs — required for pods to bind privileged ports
  if ! command -v oc &>/dev/null && command -v crc &>/dev/null; then
    local _crc_oc_path
    _crc_oc_path=$(crc oc-env 2>/dev/null | grep 'PATH=' | sed 's/.*PATH="\([^:]*\):.*/\1/' | head -1)
    [ -n "$_crc_oc_path" ] && [ -d "$_crc_oc_path" ] && export PATH="$_crc_oc_path:$PATH"
  fi
  _grant_sccs "$NAMESPACE"
  kubectl label namespace "$NAMESPACE" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged --overwrite

  # Create pull secret
  PULL_SECRET=$(aap_demo_pull_secret_get 2>/dev/null || true)

  if [ -n "$PULL_SECRET" ]; then
    echo "Using pull secret from encrypted Vault"
    kubectl create secret generic redhat-operators-pull-secret \
      --from-file=.dockerconfigjson=/dev/fd/3 \
      --type=kubernetes.io/dockerconfigjson \
      -n "$NAMESPACE" \
      --dry-run=client -o yaml 3< <(printf '%s' "$PULL_SECRET") |
      kubectl apply -f - >/dev/null

    # Add pull secret to default ServiceAccount (merge, don't replace)
    # This ensures pods using the default SA (e.g., postgres, redis) can pull images
    echo "Adding imagePullSecrets to default ServiceAccount..."
    EXISTING_SECRETS=$(kubectl get serviceaccount default -n "$NAMESPACE" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || echo "")
    if echo "$EXISTING_SECRETS" | grep -q "redhat-operators-pull-secret"; then
      echo "  ✓ Pull secret already attached to default SA"
    else
      # Build merged imagePullSecrets array
      SECRETS_JSON='[{"name": "redhat-operators-pull-secret"}'
      for secret in $EXISTING_SECRETS; do
        SECRETS_JSON="${SECRETS_JSON}, {\"name\": \"${secret}\"}"
      done
      SECRETS_JSON="${SECRETS_JSON}]"
      kubectl patch serviceaccount default -n "$NAMESPACE" \
        -p "{\"imagePullSecrets\": ${SECRETS_JSON}}" 2>/dev/null || true
      echo "  ✓ Pull secret added to default SA"
    fi
  else
    echo "WARNING: No pull secret found"
  fi
}

deploy_operator_sdk() {
  local bundle_img="$1"

  echo ""
  echo "Running operator-sdk bundle..."

  # Check for operator-sdk
  if ! command -v operator-sdk >/dev/null 2>&1; then
    echo "ERROR: operator-sdk not found"
    echo "Install with: brew install operator-sdk"
    exit 1
  fi

  operator-sdk run bundle "$bundle_img" \
    --namespace "$NAMESPACE" \
    --security-context-config restricted \
    --timeout 10m \
    --pull-secret-name redhat-operators-pull-secret
}

_load_local_cache() {
  # Loading is safe and quiet when no cache exists. Always check so a
  # destroy/create cycle can reuse a cache even though destroy clears addons.
  AAP_DEMO_LOCAL_CACHE_QUIET=1 bash "${SCRIPT_DIR}/addons/local-cache/deploy.sh" load
}

_cached_operator_catalog_ref() {
  AAP_DEMO_LOCAL_CACHE_QUIET=1 bash "${SCRIPT_DIR}/addons/local-cache/deploy.sh" \
    catalog-ref "$1" 2>/dev/null || true
}

_rewrite_local_cache_refs() {
  # Operators publish image references in generated workload templates. Keep
  # those templates aligned with the platform digests imported from cache.
  AAP_DEMO_LOCAL_CACHE_QUIET=1 bash "${SCRIPT_DIR}/addons/local-cache/deploy.sh" rewrite || true
}

_ensure_aap_storage_pvcs() {
  local cr_file="$1"
  local aap_name ns manifest

  aap_name=$(grep '^  name:' "$cr_file" 2>/dev/null | head -1 | awk '{print $2}')
  [ -n "$aap_name" ] || aap_name="aap"
  ns="${NAMESPACE:-aap-operator}"

  if ! kubectl get sc nfs-local-rwx &>/dev/null; then
    return 0
  fi

  manifest="${SCRIPT_DIR}/config/manifests/aap-storage-pvcs.yaml"
  if [ ! -f "$manifest" ]; then
    echo "  ⚠ Storage PVC manifest not found — postgres may use cluster default StorageClass"
    return 0
  fi

  echo "  Ensuring postgres and hub-redis PVCs use nfs-local-rwx..."
  sed -e "s/__NAMESPACE__/${ns}/g" -e "s/__AAP_NAME__/${aap_name}/g" "$manifest" | kubectl apply -f -
}

create_aap_instance() {
  echo ""
  echo "Creating AAP instance..."

  # Determine CR file (default: minimal, can override with CR=name)
  local cr_name="${CR:-minimal}"
  local cr_file="${SCRIPT_DIR}/config/crs/aap-${cr_name}.yaml"

  if [ ! -f "$cr_file" ]; then
    echo "ERROR: CR file not found: $cr_file"
    echo "Available CRs:"
    ls -1 "${SCRIPT_DIR}/config/crs/" | sed 's/aap-//; s/.yaml//'
    exit 1
  fi

  _ensure_aap_storage_pvcs "$cr_file"

  # For noingress CRs, substitute PUBLIC_URL placeholder
  if [[ "$cr_name" == *"noingress"* ]]; then
    # Auto-construct URL from POD_NAME, POD_NAMESPACE, BASE_DOMAIN if PUBLIC_URL not provided
    if [ -z "$PUBLIC_URL" ]; then
      if [ -n "$POD_NAME" ] && [ -n "$POD_NAMESPACE" ] && [ -n "$BASE_DOMAIN" ]; then
        PUBLIC_URL="https://aap-${POD_NAME}-${POD_NAMESPACE}.${BASE_DOMAIN}"
        echo "Auto-constructed PUBLIC_URL: $PUBLIC_URL"
      else
        echo "ERROR: PUBLIC_URL required for noingress CR"
        echo ""
        echo "Option 1 - Full URL:"
        echo "  aap-demo deploy CR=minimal-noingress PUBLIC_URL=https://aap.apps.example.com"
        echo ""
        echo "Option 2 - Auto-construct from components:"
        echo "  aap-demo deploy CR=minimal-noingress POD_NAME=engkube-runner POD_NAMESPACE=engkube BASE_DOMAIN=apps.ocp.rdu.eng.ansible.com"
        echo "  -> https://aap-engkube-runner-engkube.apps.ocp.rdu.eng.ansible.com"
        exit 1
      fi
    fi
    echo "Using CR: $cr_name with PUBLIC_URL=$PUBLIC_URL"
    sed "s|__PUBLIC_BASE_URL__|${PUBLIC_URL}|g" "$cr_file" | kubectl apply -f - -n "$NAMESPACE"
  else
    echo "Using CR: $cr_name"
    if [ "$(aap_demo_detect_crc_preset)" = "openshift" ]; then
      kubectl apply -f "$cr_file" -n "$NAMESPACE"
    else
      # Inject route_host for nip.io domain resolution
      awk -v host="aap-hub-${NAMESPACE}.$(aap_demo_route_domain)" \
        '/storage_type: file/{print; print "    route_host: " host; next} {print}' \
        "$cr_file" | kubectl apply -f - -n "$NAMESPACE"
    fi
  fi

  # Patch gateway deployment for OpenShift Local compatibility
  # The gateway pod needs NET_BIND_SERVICE capability but the operator
  # doesn't add it. On full OpenShift the privileged SCC grants all
  # capabilities automatically, but on OpenShift Local the SCC admission
  # controller picks restricted-v2 which doesn't include it.
  _patch_gateway_capability
}

_patch_gateway_capability() {
  local aap_name
  aap_name=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  [ -z "$aap_name" ] && return 0

  local deploy_name="${aap_name}-gateway"
  echo ""
  echo "Waiting for gateway deployment..."

  # Wait for gateway deployment to appear (operator creates it during reconciliation)
  local attempts=0
  while ! kubectl get deployment "$deploy_name" -n "$NAMESPACE" &>/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 60 ]; then
      echo "  ⚠ Gateway deployment not found after 5 minutes — skipping capability patch"
      return 0
    fi
    sleep 5
  done

  # Scale to 1 immediately — before capability patch — to prevent concurrent
  # migration race when 2+ replicas spin up simultaneously on fast systems.
  local current_replicas
  current_replicas=$(kubectl get deployment "$deploy_name" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
  if [ "$current_replicas" != "1" ]; then
    echo "  Setting gateway replicas to 1 (prevents concurrent migration race condition)..."
    if kubectl patch deployment "$deploy_name" -n "$NAMESPACE" --type=merge -p '{"spec":{"replicas":1}}' &>/dev/null; then
      echo "  ✓ Gateway replicas set to 1"
    else
      echo "  ⚠ Gateway replica patch failed — migration race may occur"
    fi
  fi

  # Reconcile both OpenShift Local security-context requirements together so
  # an existing capability does not prevent supplemental groups from being set.
  local existing_caps existing_supplemental_groups
  existing_caps=$(kubectl get deployment "$deploy_name" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[?(@.name=="api")].securityContext.capabilities.add}' 2>/dev/null || echo "")
  existing_supplemental_groups=$(kubectl get deployment "$deploy_name" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.securityContext.supplementalGroups}' 2>/dev/null || echo "")
  if [[ "$existing_caps" == *"NET_BIND_SERVICE"* ]] && [ "$existing_supplemental_groups" = "[0]" ]; then
    echo "  ✓ Gateway security context already configured"
    return 0
  fi

  echo "  Patching gateway security context..."
  if kubectl patch deployment "$deploy_name" -n "$NAMESPACE" --type=strategic \
    -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null},"template":{"spec":{"securityContext":{"supplementalGroups":[0]},"containers":[{"name":"api","securityContext":{"capabilities":{"add":["NET_BIND_SERVICE"]}}}]}}}}' &>/dev/null; then
    echo "  ✓ Gateway patched — pod will restart with the required security context"
  else
    echo "  ⚠ Gateway security-context patch failed — gateway may crash with EACCES"
    return 1
  fi
  aap_demo_wait_deployment "$NAMESPACE" "$deploy_name" 10m
}

watch_aap() {
  NAMESPACE="${NAMESPACE:-aap-operator}"
  export KUBECONFIG="${KUBECONFIG:-$(aap_demo_resolve_kubeconfig)}"

  TIMEOUT=3600 # 60 minutes
  INTERVAL=10  # seconds between refreshes
  WATCH_START=$(date +%s)

  while true; do
    _rewrite_local_cache_refs
    # clear requires TERM to be set (fails in nohup/cron)
    if [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
      clear
    fi

    # Calculate elapsed time
    NOW=$(date +%s)
    ELAPSED=$((NOW - WATCH_START))

    # Get cluster info
    CLUSTER=$(kubectl config current-context 2>/dev/null || echo "unknown")

    echo "=== AAP Deployment Status (${ELAPSED}s elapsed) ==="
    echo "Cluster: $CLUSTER | Namespace: $NAMESPACE"
    echo "Press Ctrl+C to exit"
    echo ""

    # AAP CR status
    echo "AAP CR:"
    kubectl get aap -n "$NAMESPACE" 2>/dev/null || echo "  No AAP CR found"
    echo ""

    # AAP conditions
    echo "Conditions:"
    kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[*].status.conditions}' 2>/dev/null \
      | jq -r '.[] | "  \(.type): \(.status) - \(.reason // .message // "n/a")"' 2>/dev/null || echo "  No status yet"
    echo ""

    # Pods
    echo "Pods:"
    kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "  No pods found"
    echo ""

    # Routes
    echo "Routes:"
    kubectl get route -n "$NAMESPACE" 2>/dev/null || echo "  No routes found"
    echo ""

    # Check if deployment is complete. AAP 2.7 reports a terminal
    # Successful=False/reason=Successful alongside Running=True.
    SUCCESSFUL=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || echo "")
    RUNNING=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].status.conditions[?(@.type=="Running")].status}' 2>/dev/null || echo "")
    SUCCESSFUL_REASON=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].status.conditions[?(@.type=="Successful")].reason}' 2>/dev/null || echo "")
    FAILURE=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].status.conditions[?(@.type=="Failure")].status}' 2>/dev/null || echo "")
    if aap_condition_is_complete "$SUCCESSFUL" "$RUNNING" "$SUCCESSFUL_REASON" "$FAILURE"; then
      echo "✓ AAP deployment successful!"
      echo ""
      # Show CSV and namespace
      CSV_NAME=$(kubectl get csv -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
      if [ -n "$CSV_NAME" ]; then
        echo "CSV: $CSV_NAME"
      fi
      echo "Namespace: $NAMESPACE"
      echo ""
      AAP_URL=$(kubectl get route -n "$NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "(route not found)")
      echo "AAP UI: https://$AAP_URL"
      echo ""
      echo "Username: admin"
      echo "Password: hidden (run 'aap-demo status --show-secrets' in a terminal)"
      echo ""

      _aap_demo_run_addon_wire || true
      return 0
    fi

    # Check timeout
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
      echo "WARNING: Deployment not complete after 60 minutes"
      echo "Check: kubectl get aap -n $NAMESPACE -o yaml"
      return 1
    fi

    sleep "$INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# Fleet nodes: managed RHEL VMs for AAP demos (addon)
# ---------------------------------------------------------------------------

cmd_fleet() {
  local fleet_dir="${SCRIPT_DIR}/addons/fleet"
  if [ ! -f "${fleet_dir}/fleet.sh" ]; then
    _err "Fleet addon not found"
    echo "  Expected: ${fleet_dir}/fleet.sh"
    return 1
  fi

  source "${fleet_dir}/fleet.sh"
  source "${fleet_dir}/fleet-aap.sh"
  source "${fleet_dir}/fleet-auth.sh"
  source "${fleet_dir}/fleet-cli.sh"
  source "${fleet_dir}/fleet-images.sh"
  source "${SCRIPT_DIR}/includes/fleet-rhc.sh"

  local subcmd="${1:-}"
  shift 2>/dev/null || true

  case "$subcmd" in
    rhc-connect)
      fleet_rhc_connect "$@"
      ;;
    auth)
      fleet_redhat_auth "${1:-configure}"
      ;;
    add)
      fleet_parse_add_args "$@" || return 1
      local count="$FLEET_ADD_COUNT"
      local image="$FLEET_ADD_IMAGE"

      if [ -z "$image" ]; then
        _err "No QCOW2 image specified"
        echo ""
        echo "Usage: aap-demo fleet add [count] --image <rhel9|rhel10|local-qcow2-path>"
        echo ""
        echo "  count    Number of VMs to create (default: 1)"
        echo "  --image  Path to a RHEL/CentOS QCOW2 cloud image"
        return 1
      fi

      fleet_resolve_image "$image" || return 1
      image="$FLEET_RESOLVED_IMAGE"
      image=$(cd "$(dirname "$image")" 2>/dev/null && echo "$(pwd)/$(basename "$image")")

      _verify_cluster || return 1
      fleet_check_prereqs "$image" || return 1
      fleet_create_all "$count" "$image"
      _fleet_save_image_config "$image"
      fleet_register_aap
      ;;
    start)
      fleet_start_all
      ;;
    register)
      _verify_cluster || return 1
      if [ -z "$(_fleet_running_indices)" ]; then
        _err "No running Fleet nodes found"
        echo "  Create nodes first: aap-demo fleet add <count> --image <rhel9|rhel10|local-qcow2-path>"
        return 1
      fi
      fleet_register_aap
      ;;
    ssh)
      local index="${1:-1}" port
      [[ "$index" =~ ^[1-9][0-9]*$ ]] || { _err "Fleet SSH requires a node index"; return 1; }
      port=$(sed -n 's/^PORT=//p' "$FLEET_DIR/node-$index/meta") || return 1
      [[ "$port" =~ ^[0-9]+$ ]] || { _err "Invalid Fleet node port"; return 1; }
      _aap_demo_release_operation_lock
      ssh -t -p "$port" -i "$FLEET_DIR/ssh_key" \
        -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$FLEET_DIR/known_hosts" admin@127.0.0.1
      ;;
    remove)
      local target="${1:-1}"
      if [[ "$target" =~ ^[0-9]+$ ]]; then
        for narg in "$@"; do
          if [[ "$narg" =~ ^[0-9]+$ ]]; then
            target="$narg"
            break
          fi
        done
        local indices
        indices=$(_fleet_running_indices)
        local to_remove
        to_remove=$(echo "$indices" | tail -n "$target")
        for idx in $to_remove; do
          local hn="aap-fleet-node-${idx}"
          fleet_node_deregister_host "$hn" 2>/dev/null || true
        done
        fleet_remove_last "$target"
      else
        local hn="$target"
        [[ "$hn" != aap-fleet-node-* ]] && hn="aap-fleet-node-${hn}"
        fleet_node_deregister_host "$hn" 2>/dev/null || true
        fleet_remove_by_name "$target"
      fi
      ;;
    list)
      echo ""
      printf "\033[1mFleet Nodes\033[0m\n"
      echo ""
      fleet_list
      ;;
    destroy)
      _verify_cluster 2>/dev/null && fleet_deregister_aap 2>/dev/null || true
      fleet_destroy_all
      ;;
    *)
      echo "Usage: aap-demo fleet <subcommand>"
      echo ""
      echo "Subcommands:"
      echo "  auth [configure|status|reset] Configure Red Hat download authentication"
      echo "  add [count] --image <rhel9|rhel10|local-qcow2-path>"
      echo "                                 Create fleet node VMs"
      echo "  register                     Register existing Fleet VMs in AAP"
      echo "  rhc-connect                  Enroll running Fleet VMs with Red Hat"
      echo "  start                        Start preserved Fleet VMs"
      echo "  ssh [index]                  Open an admin SSH shell on a Fleet node"
      echo "  remove [count|name]          Remove fleet node VMs"
      echo "  list                         List fleet node VMs"
      echo "  destroy                      Remove all VMs and AAP resources"
      echo ""
      echo "Options:"
      echo "  --image <rhel9|rhel10|local-qcow2-path>"
      echo "                    Local QCOW2 path or entitled RHEL image to download"
      echo "  FLEET_NODE_MEM=N   VM memory in MB (default: 1024)"
      echo "  FLEET_NODE_CPUS=N  VM CPU count (default: 2)"
      echo ""
      echo "Examples:"
      echo "  aap-demo fleet add 3 --image rhel9"
      echo "  aap-demo fleet add 3 --image rhel10"
      echo "  aap-demo fleet add 3 --image ~/rhel9.qcow2"
      echo "  aap-demo fleet register"
      echo "  aap-demo fleet start"
      echo "  aap-demo fleet list"
      echo "  aap-demo fleet remove 1"
      echo "  aap-demo fleet destroy"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Addon management: enable / disable
# ---------------------------------------------------------------------------
# product-demos installs all APD domains (runs product-demos-base automatically).
# product-demos-base and individual domain addons are hidden from status; enable directly if needed.
AVAILABLE_ADDONS="fleet mcp-server portal portal-operator setup-pah ao apme-eap local-cache product-demos product-demo-satellite opa ollama"

_normalize_addon_name() {
  case "$1" in
    ao-eap) echo "ao" ;;
    *) echo "$1" ;;
  esac
}

_addons_config_file() {
  echo "$AAP_DEMO_CONFIG"
}

_addons_list() {
  local config _raw _addon _normalized _result=""
  config="$(_addons_config_file)"
  if [ -f "$config" ]; then
    _raw=$(grep '^ADDONS=' "$config" 2>/dev/null | cut -d= -f2 | tr ',' ' ')
    for _addon in $_raw; do
      _normalized=$(_normalize_addon_name "$_addon")
      case " $_result " in
        *" $_normalized "*) ;;
        *)
          if [ -n "$_result" ]; then
            _result="$_result $_normalized"
          else
            _result="$_normalized"
          fi
          ;;
      esac
    done
  fi
  echo "$_result"
}

_addons_save() {
  local addons="$1"
  local config
  config="$(_addons_config_file)"
  mkdir -p "$(dirname "$config")"
  if [ -f "$config" ] && grep -q '^ADDONS=' "$config"; then
    sed -i.bak "s/^ADDONS=.*/ADDONS=${addons}/" "$config" && rm -f "${config}.bak"
  else
    echo "ADDONS=${addons}" >>"$config"
  fi
}

_addons_add() {
  local addon="$1"
  local current
  addon=$(_normalize_addon_name "$addon")
  current=$(_addons_list)
  # Don't add if already present
  if echo "$current" | grep -qw "$addon"; then
    return
  fi
  if [ -n "$current" ]; then
    _addons_save "$(echo "$current $addon" | tr ' ' ',')"
  else
    _addons_save "$addon"
  fi
}

_addons_remove() {
  local addon="$1"
  local current new
  addon=$(_normalize_addon_name "$addon")
  current=$(_addons_list)
  new=$(echo "$current" | tr ' ' '\n' | grep -v "^${addon}$" | tr '\n' ',' | sed 's/,$//')
  _addons_save "$new"
}

_ensure_addon_dependency() {
  local dep="$1"
  shift 2>/dev/null || true
  dep=$(_normalize_addon_name "$dep")
  if echo "$(_addons_list)" | grep -qw "$dep"; then
    return 0
  fi
  echo ""
  echo "Required addon: ${dep}"
  cmd_enable "$dep" "$@" || return 1
}

# Prompt user to enable product-demos before AO if no demo content is installed.
# Skipped in CI, QUIET mode, or when any product-demo addon is already enabled.
_ao_prompt_product_demos() {
  local _current _demo_addon
  _current=$(_addons_list)
  for _demo_addon in product-demos product-demos-base \
    product-demo-linux product-demo-windows product-demo-network \
    product-demo-cloud product-demo-openshift product-demo-satellite; do
    if echo "$_current" | grep -qw "$_demo_addon"; then
      return 0
    fi
  done

  if [ "${CI:-}" = "true" ] || [ "${QUIET:-false}" = "true" ] || [ ! -t 0 ]; then
    return 0
  fi

  echo ""
  echo "AO wires its workflows to AAP job templates at deploy time."
  echo "If you enable product-demos AFTER AO, those templates won't be wired correctly"
  echo "until you re-run 'aap-demo enable ao'."
  echo ""
  echo "No product-demos content detected. Enable product-demos before AO? [Y/n]"
  local _choice
  IFS= read -r _choice </dev/tty || _choice=""
  _choice="${_choice:-y}"
  case "$_choice" in
    [Yy]* | "")
      echo "Enabling product-demos first..."
      if ! cmd_enable product-demos; then
        echo ""
        echo "⚠ Some product-demos domains failed to install."
        echo "  AO will wire to the domains that succeeded."
        echo "  Retry failed domains with: aap-demo enable product-demos"
      fi
      ;;
    *)
      echo "Skipping product-demos. Re-run 'aap-demo enable ao' after enabling demos if needed."
      ;;
  esac
}

# Auto-wire enabled addons (APD credentials, AO integrations). Runs after enable,
# deploy, and watch; idempotent and safe to call multiple times.
_aap_demo_run_addon_wire() {
  local strict="${1:-false}"
  setup_kubeconfig
  # shellcheck source=includes/addon-wire.sh
  source "${SCRIPT_DIR}/includes/addon-wire.sh"
  if [ "$strict" = true ]; then
    aap_demo_wire
  else
    aap_demo_wire || true
  fi
}

_addon_resource_preflight() {
  case "$1" in
    ao) aap_demo_resource_preflight "Automation Orchestrator" 1500 3072 ;;
    ollama) aap_demo_resource_preflight "Ollama" 200 2048 ;;
    portal-operator) aap_demo_resource_preflight "Automation Portal Operator" 1600 2048 ;;
    portal) aap_demo_resource_preflight "Automation Portal" 500 1024 ;;
    apme-eap) aap_demo_resource_preflight "APME" 500 1024 ;;
    *) return 0 ;;
  esac
}

cmd_enable() {
  local addon="${1:-}"
  shift 2>/dev/null || true
  addon=$(_normalize_addon_name "$addon")
  if [ -z "$addon" ]; then
    echo "Usage: aap-demo enable <addon> [--force] [--refresh-catalog]"
    echo "       FORCE=1 aap-demo enable <addon>   # same as --force"
    echo ""
    local saved
    saved=$(_addons_list)
    echo "Available addons:"
    for a in $AVAILABLE_ADDONS; do
      local status="available"
      if echo "$saved" | grep -qw "$a"; then
        status="enabled"
      elif [ ! -d "${SCRIPT_DIR}/addons/${a}" ]; then
        status="not found"
      fi
      [ "$a" = "portal-operator" ] && status="${status}; AMD64 only"
      printf "  %-15s %s\n" "$a" "($status)"
    done
    return 0
  fi

  local addon_dir="${SCRIPT_DIR}/addons/${addon}"
  if [ ! -d "$addon_dir" ]; then
    echo "Unknown addon: $addon"
    echo "Available: $AVAILABLE_ADDONS"
    return 1
  fi

  if [ ! -f "$addon_dir/deploy.sh" ]; then
    echo "Addon '$addon' has no deploy.sh"
    return 1
  fi

  local subcmd="${1:-}"
  local _skip_addon_save=false
  local _skip_cluster_verify=false
  if [ "$addon" = "local-cache" ]; then
    case "$subcmd" in
      load)
        _skip_addon_save=true
        echo "Loading cached container images..."
        ;;
      clear)
        _skip_addon_save=true
        _skip_cluster_verify=true
        echo "Clearing local image cache..."
        ;;
      *) echo "Enabling addon: $addon" ;;
    esac
  else
    echo "Enabling addon: $addon"
  fi
  aap_demo_reload_version
  printf '  Source: %s (%s)\n' "${addon_dir}/deploy.sh" "$(aap_demo_version_short)"
  if [ "$_skip_cluster_verify" != true ]; then
    _verify_cluster || return 1
    aap_demo_capacity_warn_enable "$addon" "$(_addons_list)"
    _addon_resource_preflight "$addon" || return 1
  fi
  if [ "$addon" = "ao" ] && [ "$_skip_addon_save" != true ]; then
    aap_demo_ao_llm_prepare || return 1
    _ao_prompt_product_demos || return 1
    _ensure_addon_dependency mcp-server "$@" || return 1
    if [ "${AO_LLM_PROVIDER:-ollama}" = ollama ]; then
      _ensure_addon_dependency ollama "$@" || return 1
    fi
  fi
  local _addon_was_enabled=false
  if echo "$(_addons_list)" | grep -qw "$addon"; then
    _addon_was_enabled=true
  fi
  if [ "$_skip_addon_save" != true ]; then
    _addons_add "$addon"
  fi
  # AO imports its workflows immediately after wiring because the importer needs
  # the AAP credential created by addon-wire.sh. Keep deferred wiring for others.
  if [ "$addon" = "ao" ]; then
    export AAP_DEMO_WIRE_AFTER_DEPLOY=1
  else
    export AAP_DEMO_WIRE_AFTER_DEPLOY=0
  fi
  if ! bash "$addon_dir/deploy.sh" "$@"; then
    # Do not leave a first-time failed deployment marked as enabled. Otherwise
    # dependency checks skip it on the next run even though setup is incomplete.
    if [ "$_skip_addon_save" != true ] && [ "$_addon_was_enabled" = false ]; then
      _addons_remove "$addon"
    fi
    unset AAP_DEMO_WIRE_AFTER_DEPLOY
    return 1
  fi
  unset AAP_DEMO_WIRE_AFTER_DEPLOY
  if [ "$_skip_addon_save" != true ]; then
    echo "  Saved to config: ADDONS=$(_addons_list | tr ' ' ',')"
  fi
  if [ "$addon" = "ao" ]; then
    # The AO addon performs wiring before provisioning AAP templates and
    # importing workflows. A second login here can fail when AO's initial
    # password secret is stale after the instance has already been initialized.
    # `aap-demo wire` remains available for an explicit retry.
    :
  else
    _aap_demo_run_addon_wire false
  fi
}

cmd_wire() {
  echo "Re-running addon wiring (also runs automatically after enable and deploy)..."
  _verify_cluster || return 1
  _aap_demo_run_addon_wire true
}

cmd_disable() {
  local addon="${1:-}"
  shift 2>/dev/null || true
  addon=$(_normalize_addon_name "$addon")
  if [ -z "$addon" ]; then
    echo "Usage: aap-demo disable <addon> [options]"
    echo ""
    echo "Available addons: $AVAILABLE_ADDONS"
    echo ""
    echo "Addon options:"
    echo "  ao:       --purge-data  Remove the AO database and saved admin credential"
    echo "  apme-eap: --purge-creds   Remove saved GitHub credentials and private key"
    return 0
  fi

  local addon_dir="${SCRIPT_DIR}/addons/${addon}"
  if [ ! -d "$addon_dir" ]; then
    echo "Unknown addon: $addon"
    return 1
  fi

  if [ -f "$addon_dir/deploy.sh" ]; then
    echo "Disabling addon: $addon"
    setup_kubeconfig
    if ! bash "$addon_dir/deploy.sh" --delete "$@"; then
      _err "Failed to disable addon: $addon"
      return 1
    fi
    _addons_remove "$addon"
    echo "  Removed from config"
  else
    echo "Addon '$addon' has no deploy.sh"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Auto-update check (skip for help, update, and empty commands)
# ---------------------------------------------------------------------------
_check_for_updates() {
  local repo_root="$SCRIPT_DIR"
  local stamp_file="${AAP_DEMO_DIR}/.last_update_check"

  # Skip in CI and non-interactive sessions
  [ "${CI:-}" = "true" ] && return 0
  [ -t 0 ] || return 0

  # Throttle: check at most once per 4 hours
  if [ -f "$stamp_file" ]; then
    local last_check now
    last_check=$(cat "$stamp_file" 2>/dev/null || echo "0")
    now=$(date +%s)
    if [ $((now - last_check)) -lt 14400 ]; then
      return 0
    fi
  fi

  # Must be a git repo
  git -C "$repo_root" rev-parse --is-inside-work-tree &>/dev/null || return 0

  # Fetch latest (quick, no merge)
  git -C "$repo_root" fetch --quiet 2>/dev/null || return 0

  mkdir -p "$(dirname "$stamp_file")"
  date +%s >"$stamp_file"

  local local_head remote_head
  local_head=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null)
  remote_head=$(git -C "$repo_root" rev-parse '@{u}' 2>/dev/null) || return 0

  if [ "$local_head" = "$remote_head" ]; then
    return 0
  fi

  local behind
  behind=$(git -C "$repo_root" rev-list --count HEAD..'@{u}' 2>/dev/null || echo "0")
  if [ "$behind" -eq 0 ]; then
    return 0
  fi

  echo ""
  printf "\033[0;33m▸ Update available:\033[0m %s commit(s) behind remote\n" "$behind"
  printf "  Pull latest now? [y/N] (auto-continuing in 10s): "
  read -t 10 -r _update_choice </dev/tty || _update_choice=""
  _update_choice="${_update_choice:-n}"

  case "$_update_choice" in
    [yY]*)
      echo "  Pulling latest..."
      if git -C "$repo_root" pull --quiet 2>/dev/null; then
        echo "  ✓ Updated to latest"
      else
        printf "  \033[0;33mWarning: git pull failed — continuing with current version\033[0m\n"
      fi
      ;;
    *)
      echo "  Skipped — run 'aap-demo update' later"
      ;;
  esac
  echo ""
}

case "$COMMAND" in
  status)
    [ "$OUTPUT_JSON" = true ] || _check_for_updates
    ;;
esac

# Delegate before taking the CLI lock: the recovery runner owns a lock across stop,
# disk backup/restore and start, and its child CLI processes share that lock.
case "$COMMAND" in
  start | restart | stop)
    if aap_demo_service_managed; then
      aap_demo_service_lifecycle "$COMMAND"
      exit $?
    fi
    ;;
esac

if aap_demo_service_managed; then
  case "$COMMAND" in
    create)
      if [ "$FULL_DEMO" != true ] || [ "$(uname -s)" != Linux ]; then
        _err "Disable automatic recovery before rebuilding the demo: aap-demo service disable"
        exit 1
      fi
      ;;
    destroy | redeploy-all)
      _err "Disable automatic recovery before rebuilding or deleting the demo: aap-demo service disable"
      exit 1
      ;;
  esac
fi

if aap_demo_command_requires_lock "$COMMAND" \
  && ! { [ "$COMMAND" = maintenance ] \
    && [ "${EXTRA_ARGS[0]:-}" = uninstall ] \
    && [ "$MAINTENANCE_APPLY" = true ]; }; then
  aap_demo_acquire_operation_lock "$COMMAND" || exit 1
fi

# Setup KUBECONFIG based on infrastructure type (skip for help/config commands)
case "$COMMAND" in
  help | --help | -h | config | update | version | "" | destroy | status | system-info | dashboard | console | service | credentials)
    # These commands don't need cluster access
    ;;
  redeploy-all | deploy | deploy-all | redeploy | create | start | restart | preflight)
    # These handle their own cluster state (auto-start if stopped)
    setup_kubeconfig
    ;;
  maintenance)
    if [ "${EXTRA_ARGS[0]:-preview}" != "uninstall" ]; then
      setup_kubeconfig
      verify_cluster_type || exit 1
    fi
    ;;
  fleet)
    if [ "${EXTRA_ARGS[0]:-}" != "auth" ]; then
      setup_kubeconfig
      verify_cluster_type || exit 1
    fi
    ;;
  *)
    setup_kubeconfig
    verify_cluster_type || exit 1
    ;;
esac

case "$COMMAND" in
  help | --help | -h)
    show_help
    ;;
  repair)
    cmd_repair
    ;;
  clean)
    cmd_clean
    ;;
  maintenance)
    cmd_maintenance "${EXTRA_ARGS[0]:-preview}" "$MAINTENANCE_APPLY"
    ;;
  credentials)
    _credentials_rc=0
    cmd_credentials "${EXTRA_ARGS[@]}" || _credentials_rc=$?
    [ "$_credentials_rc" -eq 0 ] || exit "$_credentials_rc"
    ;;
  destroy)
    for _arg in "${EXTRA_ARGS[@]}"; do
      [ "$_arg" = "--reset" ] && _DESTROY_RESET=true
      [ "$_arg" = "--skip-cache" ] && _DESTROY_SKIP_CACHE=true
    done
    cmd_destroy
    ;;
  stop)
    cmd_stop
    ;;
  start)
    cmd_start
    _aap_demo_auto_dashboard
    ;;
  restart)
    cmd_stop
    cmd_start
    _aap_demo_auto_dashboard
    ;;
  service)
    cmd_service "${EXTRA_ARGS[@]}"
    ;;
  create)
    if [ "$FULL_DEMO" = true ]; then
      if ! cmd_full_demo; then
        exit 1
      fi
    else
      cmd_create
      _aap_demo_auto_dashboard
    fi
    ;;
  setup)
    cmd_setup
    ;;
  setup-pah)
    echo "setup-pah is now an addon. Run: aap-demo enable setup-pah"
    ;;
  watch)
    watch_aap
    ;;
  status)
    if [ "$OUTPUT_JSON" = true ]; then
      cmd_status_json
    else
      cmd_status
    fi
    ;;
  system-info)
    cmd_system_info
    ;;
  dashboard)
    cmd_dashboard
    ;;
  console)
    cmd_console
    ;;
  update)
    cmd_update
    ;;
  version | --version | -V)
    cmd_version
    ;;
  config)
    cmd_config "${EXTRA_ARGS[@]}"
    ;;
  redeploy)
    cmd_redeploy
    ;;
  redeploy-all)
    cmd_redeploy-all
    ;;
  redhat-status | rh-status)
    cmd_redhat_status
    ;;
  kubeconfig)
    cmd_kubeconfig
    ;;
  ssh)
    cmd_ssh
    ;;
  idle)
    cmd_idle "${EXTRA_ARGS[0]:-}"
    ;;
  preflight)
    cmd_preflight
    ;;
  diagnose)
    # Check for --ai flag
    for _arg in "${EXTRA_ARGS[@]}"; do
      [ "$_arg" = "--ai" ] && _DIAGNOSE_AI=true
    done
    cmd_diagnose
    ;;
  must-gather)
    cmd_must_gather "${EXTRA_ARGS[0]:-}"
    ;;
  fleet)
    cmd_fleet "${EXTRA_ARGS[@]}" || exit $?
    ;;
  enable)
    cmd_enable "${EXTRA_ARGS[@]}"
    ;;
  wire)
    cmd_wire
    ;;
  disable)
    cmd_disable "${EXTRA_ARGS[@]}"
    ;;
  deploy | deploy-all)
    cmd_deploy
    ;;
  *)
    # Default: show welcome if no command specified, or error for unknown commands
    if [ -z "$COMMAND" ] || [ "$COMMAND" = "" ]; then
      show_welcome
    else
      echo "Unknown command: $COMMAND"
      echo "Run 'aap-demo help' for usage"
      exit 1
    fi
    ;;
esac
