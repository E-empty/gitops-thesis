#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/git.sh
source "${SCRIPT_DIR}/lib/git.sh"

usage() {
  cat <<'EOF'
Usage: experiments/rollback.sh --tool argocd|fluxcd [options]

Deploys APP_FAILURE_MODE=readiness through Git, waits for a failed rollout, then
starts the measured Git rollback and waits for the healthy baseline.
EOF
  common_options
  git_options
}

parse_common_args "$@"
parse_git_args "${COMMON_REMAINING_ARGS[@]}"
set -- "${GIT_REMAINING_ARGS[@]}"
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
require_commands kubectl python3 awk git
prepare_results
prepare_git_mutation

deployment="$(resolve_deployment)"
service_resource="$(resolve_service)"
baseline_failure_mode="$(values_get env.APP_FAILURE_MODE)"
[[ "${baseline_failure_mode}" == "none" ]] || die "Baseline APP_FAILURE_MODE must be 'none'"

for ((iteration=1; iteration<=ITERATIONS; iteration++)); do
  ensure_iteration_is_new "rollback" "${iteration}"
  wait_until "healthy controller baseline before preparing rollback" controller_is_ready || \
    die "Controller baseline was not ready before iteration ${iteration}"
  wait_until "healthy Deployment baseline before preparing rollback" deployment_is_ready "${deployment}" || \
    die "Deployment baseline was not ready before iteration ${iteration}"
  baseline_checksum="$(deployment_field "${deployment}" '{.spec.template.metadata.annotations.checksum/config}')"
  preparation_log="${RESULTS_DIR}/logs/${TOOL}/rollback-preparation-${iteration}-$(now_iso | tr ':' '-').log"
  CURRENT_LOG="${preparation_log}"
  : >"${CURRENT_LOG}"
  log "Preparing intentionally broken readiness release"
  values_set env.APP_FAILURE_MODE readiness
  commit_and_push_values "experiment(${TOOL}): deploy broken ${SERVICE} [iteration ${iteration}]"
  bad_commit="${LAST_GIT_COMMIT}"

  broken_rollout_observed() {
    local checksum updated
    checksum="$(deployment_field "${deployment}" '{.spec.template.metadata.annotations.checksum/config}' 2>/dev/null || true)"
    updated="$(deployment_field "${deployment}" '{.status.updatedReplicas}' 2>/dev/null || true)"
    [[ -n "${checksum}" && "${checksum}" != "${baseline_checksum}" && "${updated:-0}" -gt 0 ]] && \
      ! deployment_is_ready "${deployment}"
  }
  wait_until "broken release applied and at least one new Pod is not ready" broken_rollout_observed || \
    die "Broken release was not observable; rollback measurement cannot start"
  wait_until "failed-release reconciliation is no longer running" controller_operation_is_idle || \
    die "Controller was still processing the broken release; rollback measurement cannot start"

  begin_iteration "rollback" "${iteration}"
  settle_before_measurement
  broken_rollout_observed || die "Broken rollout disappeared before rollback measurement"
  controller_operation_is_idle || die "Controller started another operation before rollback measurement"
  snapshot_cluster "before"
  capture_controller_baseline
  log "Rolling back broken commit ${bad_commit} by creating a Git revert"
  start_measurement
  revert_and_push "${bad_commit}"

  rollback_applied() {
    [[ "$(deployment_field "${deployment}" '{.spec.template.metadata.annotations.checksum/config}' 2>/dev/null || true)" == "${baseline_checksum}" ]]
  }
  rollback_reaction_observed() {
    controller_source_reaction_observed || rollback_applied
  }
  if ! wait_until "controller detected/reacted to the Git rollback" rollback_reaction_observed; then
    finish_failure "rollback" "${iteration}" "" "detection_timeout"
    exit 1
  fi
  detection_iso="${WAIT_TIME_ISO}"

  healthy_again() {
    rollback_applied && deployment_is_ready "${deployment}" && \
      endpoint_field_equals "${service_resource}" ready status ready
  }
  if ! wait_until "healthy baseline fully ready" healthy_again; then
    finish_failure "rollback" "${iteration}" "${detection_iso}" "recovery_timeout"
    exit 1
  fi
  finish_success "rollback" "${iteration}" "${detection_iso}" "${WAIT_TIME_ISO}" "${WAIT_TIME_MS}"
  [[ "$(values_get env.APP_FAILURE_MODE)" == "${baseline_failure_mode}" ]] || \
    die "Local values did not return to the baseline"
  pause_between_iterations "${iteration}"
done
