#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: experiments/drift-image.sh --tool argocd|fluxcd [options]

Changes a Deployment image outside Git and measures automatic correction.

Scenario option:
  --drift-image IMAGE    Image used only for drift (default: invalid local tag)
EOF
  common_options
}

DRIFT_IMAGE="registry.invalid/gitops-thesis/drift-image:never"
parse_common_args "$@"
set -- "${COMMON_REMAINING_ARGS[@]}"
while (($#)); do
  case "$1" in
    --drift-image)
      (($# >= 2)) || die "--drift-image requires a value"
      DRIFT_IMAGE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done
require_commands kubectl python3 awk
prepare_results

deployment="$(resolve_deployment)"
container="$(deployment_field "${deployment}" '{.spec.template.spec.containers[0].name}')"
[[ -n "${container}" ]] || die "Cannot resolve the first container in ${deployment}"

for ((iteration=1; iteration<=ITERATIONS; iteration++)); do
  begin_iteration "image_drift" "${iteration}"
  prepare_iteration_baseline "${deployment}" || die "Stable baseline was not reached before iteration ${iteration}"
  expected_image="$(deployment_field "${deployment}" '{.spec.template.spec.containers[0].image}')"
  [[ -n "${expected_image}" ]] || die "Cannot read the declared image"
  [[ "${DRIFT_IMAGE}" != "${expected_image}" ]] || die "Drift image equals the declared image"
  snapshot_cluster "before"
  capture_controller_baseline

  log "Setting ${container} image outside Git: ${expected_image} -> ${DRIFT_IMAGE}"
  start_measurement
  kubectl -n "${NAMESPACE}" set image "deployment/${deployment}" \
    "${container}=${DRIFT_IMAGE}" >>"${CURRENT_LOG}" 2>&1

  image_corrected() {
    [[ "$(deployment_field "${deployment}" '{.spec.template.spec.containers[0].image}' || true)" == "${expected_image}" ]]
  }
  image_reaction_observed() {
    controller_drift_reaction_observed || image_corrected
  }
  if ! wait_until "controller detected/reacted to image drift" image_reaction_observed; then
    finish_failure "image_drift" "${iteration}" "" "detection_timeout"
    exit 1
  fi
  detection_iso="${WAIT_TIME_ISO}"

  image_recovered() {
    image_corrected && deployment_is_ready "${deployment}"
  }
  if ! wait_until "Deployment corrected and fully ready with the declared image" image_recovered; then
    finish_failure "image_drift" "${iteration}" "${detection_iso}" "recovery_timeout"
    exit 1
  fi
  finish_success "image_drift" "${iteration}" "${detection_iso}" "${WAIT_TIME_ISO}" "${WAIT_TIME_MS}"
  pause_between_iterations "${iteration}"
done
