#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: experiments/drift-scale.sh --tool argocd|fluxcd [options]

Creates an out-of-band replica drift and measures automatic correction.

Scenario option:
  --drift-replicas N     Manual replica count (default: 5)
EOF
  common_options
}

DRIFT_REPLICAS=5
parse_common_args "$@"
set -- "${COMMON_REMAINING_ARGS[@]}"
while (($#)); do
  case "$1" in
    --drift-replicas)
      (($# >= 2)) || die "--drift-replicas requires a value"
      DRIFT_REPLICAS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done
is_positive_integer "${DRIFT_REPLICAS}" || die "--drift-replicas must be a positive integer"
require_commands kubectl python3 awk
prepare_results

deployment="$(resolve_deployment)"

for ((iteration=1; iteration<=ITERATIONS; iteration++)); do
  begin_iteration "scale_drift" "${iteration}"
  prepare_iteration_baseline "${deployment}" || die "Stable baseline was not reached before iteration ${iteration}"
  expected_replicas="$(deployment_field "${deployment}" '{.spec.replicas}')"
  [[ "${expected_replicas}" =~ ^[0-9]+$ ]] || die "Cannot read the declared replica count"
  (( DRIFT_REPLICAS != expected_replicas )) || die "Drift replica count equals the declared count (${expected_replicas})"
  snapshot_cluster "before"
  capture_controller_baseline

  log "Scaling ${deployment} from ${expected_replicas} to ${DRIFT_REPLICAS} outside Git"
  start_measurement
  kubectl -n "${NAMESPACE}" scale deployment "${deployment}" --replicas="${DRIFT_REPLICAS}" >>"${CURRENT_LOG}" 2>&1

  scale_corrected() {
    [[ "$(deployment_field "${deployment}" '{.spec.replicas}' || true)" == "${expected_replicas}" ]]
  }
  scale_reaction_observed() {
    controller_drift_reaction_observed || scale_corrected
  }
  if ! wait_until "controller detected/reacted to replica drift" scale_reaction_observed; then
    finish_failure "scale_drift" "${iteration}" "" "detection_timeout"
    exit 1
  fi
  detection_iso="${WAIT_TIME_ISO}"

  scale_recovered() {
    scale_corrected && deployment_is_ready "${deployment}"
  }
  if ! wait_until "Deployment corrected and fully ready with ${expected_replicas} replicas" scale_recovered; then
    finish_failure "scale_drift" "${iteration}" "${detection_iso}" "recovery_timeout"
    exit 1
  fi
  finish_success "scale_drift" "${iteration}" "${detection_iso}" "${WAIT_TIME_ISO}" "${WAIT_TIME_MS}"
  pause_between_iterations "${iteration}"
done
