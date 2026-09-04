#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: experiments/delete-deployment.sh --tool argocd|fluxcd [options]

Deletes a managed Deployment and measures recreation and full readiness.
EOF
  common_options
}

parse_common_args "$@"
set -- "${COMMON_REMAINING_ARGS[@]}"
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
require_commands kubectl python3 awk
prepare_results

for ((iteration=1; iteration<=ITERATIONS; iteration++)); do
  deployment="$(resolve_deployment)"
  begin_iteration "delete_deployment" "${iteration}"
  prepare_iteration_baseline "${deployment}" || die "Stable baseline was not reached before iteration ${iteration}"
  old_uid="$(deployment_field "${deployment}" '{.metadata.uid}')"
  snapshot_cluster "before"
  capture_controller_baseline

  log "Deleting Deployment ${deployment} (uid=${old_uid}) outside Git"
  start_measurement
  kubectl -n "${NAMESPACE}" delete deployment "${deployment}" --wait=false >>"${CURRENT_LOG}" 2>&1

  deployment_recreated() {
    local new_uid
    new_uid="$(deployment_field "${deployment}" '{.metadata.uid}' 2>/dev/null || true)"
    [[ -n "${new_uid}" && "${new_uid}" != "${old_uid}" ]]
  }
  delete_reaction_observed() {
    controller_drift_reaction_observed || deployment_recreated
  }
  if ! wait_until "controller detected/reacted to the missing Deployment" delete_reaction_observed; then
    finish_failure "delete_deployment" "${iteration}" "" "detection_timeout"
    exit 1
  fi
  detection_iso="${WAIT_TIME_ISO}"

  deployment_recovered() {
    deployment_recreated && deployment_is_ready "${deployment}"
  }
  if ! wait_until "recreated Deployment fully ready" deployment_recovered; then
    finish_failure "delete_deployment" "${iteration}" "${detection_iso}" "recovery_timeout"
    exit 1
  fi
  finish_success "delete_deployment" "${iteration}" "${detection_iso}" "${WAIT_TIME_ISO}" "${WAIT_TIME_MS}"
  pause_between_iterations "${iteration}"
done
