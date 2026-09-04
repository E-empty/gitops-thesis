#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/git.sh
source "${SCRIPT_DIR}/lib/git.sh"

usage() {
  cat <<'EOF'
Usage: experiments/change-config.sh --tool argocd|fluxcd [options]

Changes services.<service>.env.EXPERIMENT_CONFIG in Git, measures rollout, and
restores the baseline with a Git revert.

Scenario option:
  --value VALUE          Prefix for the experimental value (default: changed)
EOF
  common_options
  git_options
}

CONFIG_VALUE_PREFIX="changed"
parse_common_args "$@"
parse_git_args "${COMMON_REMAINING_ARGS[@]}"
set -- "${GIT_REMAINING_ARGS[@]}"
while (($#)); do
  case "$1" in
    --value)
      (($# >= 2)) || die "--value requires a value"
      CONFIG_VALUE_PREFIX="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
require_commands kubectl python3 awk git
prepare_results
prepare_git_mutation

deployment="$(resolve_deployment)"
baseline_config="$(values_get env.EXPERIMENT_CONFIG)"

for ((iteration=1; iteration<=ITERATIONS; iteration++)); do
  begin_iteration "change_config" "${iteration}"
  prepare_iteration_baseline "${deployment}" || die "Stable baseline was not reached before iteration ${iteration}"
  baseline_checksum="$(deployment_field "${deployment}" '{.spec.template.metadata.annotations.checksum/config}')"
  experiment_value="${CONFIG_VALUE_PREFIX}-${TOOL}-${iteration}-$(now_epoch_ms)"
  values_set env.EXPERIMENT_CONFIG "${experiment_value}"
  snapshot_cluster "before"
  capture_controller_baseline
  log "Committing EXPERIMENT_CONFIG=${experiment_value}"
  start_measurement
  commit_and_push_values "experiment(${TOOL}): change ${SERVICE} config [iteration ${iteration}]"
  change_commit="${LAST_GIT_COMMIT}"

  checksum_changed() {
    local checksum
    checksum="$(deployment_field "${deployment}" '{.spec.template.metadata.annotations.checksum/config}' 2>/dev/null || true)"
    [[ -n "${checksum}" && "${checksum}" != "${baseline_checksum}" ]]
  }
  config_reaction_observed() {
    controller_source_reaction_observed || checksum_changed
  }
  if ! wait_until "controller detected/reacted to the configuration revision" config_reaction_observed; then
    finish_failure "change_config" "${iteration}" "" "detection_timeout"
    exit 1
  fi
  detection_iso="${WAIT_TIME_ISO}"

  config_rollout_ready() {
    checksum_changed && deployment_is_ready "${deployment}"
  }
  if ! wait_until "changed configuration rollout fully ready" config_rollout_ready; then
    finish_failure "change_config" "${iteration}" "${detection_iso}" "recovery_timeout"
    exit 1
  fi
  finish_success "change_config" "${iteration}" "${detection_iso}" "${WAIT_TIME_ISO}" "${WAIT_TIME_MS}"

  log "Restoring baseline configuration with a Git rollback commit"
  revert_and_push "${change_commit}"
  baseline_restored() {
    [[ "$(deployment_field "${deployment}" '{.spec.template.metadata.annotations.checksum/config}' 2>/dev/null || true)" == "${baseline_checksum}" ]] && \
      deployment_is_ready "${deployment}"
  }
  wait_until "baseline configuration restored before next iteration" baseline_restored || \
    die "Baseline restoration timed out after iteration ${iteration}"
  [[ "$(values_get env.EXPERIMENT_CONFIG)" == "${baseline_config}" ]] || \
    die "Local values did not return to the baseline"
  pause_between_iterations "${iteration}"
done
