#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/includes/cmd-status.sh"
NAMESPACE=aap-test
_check_pass() { printf 'PASS %s\n' "$*"; }
_check_fail() { printf 'FAIL %s\n' "$*"; }
_check_warn() { printf 'WARN %s\n' "$*"; }
_check_info() { printf 'INFO %s\n' "$*"; }

kubectl() {
  case "$*" in
    'get pods -n aap-test -o json --request-timeout=10s')
      case "$SCENARIO" in
        ready) printf '%s\n' '{"items":[{"metadata":{"name":"ready"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},{"status":{"phase":"Succeeded"}}]}' ;;
        unready) printf '%s\n' '{"items":[{"metadata":{"name":"unready"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"False"}]}}]}' ;;
        retried_job | failed_job | stale_job | jobs_error)
          printf '%s\n' '{"items":[{"metadata":{"name":"ready"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"failed-attempt","ownerReferences":[{"kind":"Job","controller":true,"uid":"job-uid"}]},"status":{"phase":"Failed"}}]}'
          ;;
        *) return 1 ;;
      esac
      ;;
    'get jobs -n aap-test -o json --request-timeout=10s')
      case "$SCENARIO" in
        retried_job) printf '%s\n' '{"items":[{"metadata":{"uid":"job-uid"},"status":{"conditions":[{"type":"Complete","status":"True"}]}}]}' ;;
        failed_job) printf '%s\n' '{"items":[{"metadata":{"uid":"job-uid"},"status":{"conditions":[{"type":"Failed","status":"True"}]}}]}' ;;
        stale_job) printf '%s\n' '{"items":[{"metadata":{"uid":"different-uid"},"status":{"conditions":[{"type":"Complete","status":"True"}]}}]}' ;;
        *) return 1 ;;
      esac
      ;;
    'get hpa -A -o json --request-timeout=10s')
      [ "$SCENARIO" != hpa_error ] || return 1
      if [ "$SCENARIO" = no_hpa ]; then
        printf '%s\n' '{"items":[]}'
      else
        printf '%s\n' '{"items":[{"metadata":{"namespace":"demo","name":"worker"},"spec":{"metrics":[{"type":"Resource","resource":{"name":"cpu"}}]}}]}'
      fi
      ;;
    'get apiservice v1beta1.metrics.k8s.io -o json --request-timeout=10s')
      [ "$SCENARIO" != missing ] || return 1
      if [ "$SCENARIO" = unavailable ]; then
        printf '%s\n' '{"status":{"conditions":[{"type":"Available","status":"False"}]}}'
      else
        printf '%s\n' '{"status":{"conditions":[{"type":"Available","status":"True"}]}}'
      fi
      ;;
    'get --raw /apis/metrics.k8s.io/v1beta1/pods --request-timeout=10s')
      [ "$SCENARIO" != no_samples ] || return 1
      printf '%s\n' '{"items":[]}'
      ;;
    *) return 1 ;;
  esac
}

[[ "$(SCENARIO=ready _diagnose_aap_pods)" == *'PASS All AAP pods ready (1/1)'* ]]
[[ "$(SCENARIO=unready _diagnose_aap_pods)" == *'FAIL AAP pods not ready (0/1 ready): unready'* ]]
[[ "$(SCENARIO=error _diagnose_aap_pods)" == *'WARN Unable to inspect'* ]]
[[ "$(SCENARIO=retried_job _diagnose_aap_pods)" == *'PASS All AAP pods ready (1/1)'* ]]
[[ "$(SCENARIO=failed_job _diagnose_aap_pods)" == *'FAIL AAP pods not ready (1/2 ready): failed-attempt'* ]]
[[ "$(SCENARIO=stale_job _diagnose_aap_pods)" == *'FAIL AAP pods not ready (1/2 ready): failed-attempt'* ]]
[[ "$(SCENARIO=jobs_error _diagnose_aap_pods)" == *'WARN Unable to inspect AAP migration job completion'* ]]
[[ "$(SCENARIO=missing _diagnose_hpa_metrics)" == *'WARN CPU metrics API unavailable'* ]]
[[ "$(SCENARIO=unavailable _diagnose_hpa_metrics)" == *'WARN CPU metrics API is not available'* ]]
[[ "$(SCENARIO=no_samples _diagnose_hpa_metrics)" == *'WARN CPU metrics API cannot return'* ]]
[[ "$(SCENARIO=ready _diagnose_hpa_metrics)" == *'PASS CPU metrics API available'* ]]
[[ "$(SCENARIO=ready _diagnose_hpa_metrics)" == *'WARN HPA CPU samples are unknown: demo/worker'* ]]
[[ "$(SCENARIO=no_hpa _diagnose_hpa_metrics)" == *'INFO No CPU-based'* ]]
[[ "$(SCENARIO=hpa_error _diagnose_hpa_metrics)" == *'WARN Unable to inspect'* ]]
echo "PASS: pod readiness and HPA metrics diagnostics"
