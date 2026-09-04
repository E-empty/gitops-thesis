#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/git.sh
source "${SCRIPT_DIR}/lib/git.sh"

usage() {
  cat <<'EOF'
Usage: experiments/deploy-new-version.sh --tool argocd|fluxcd \
  --new-tag TAG --new-version VERSION [options]

Commits and pushes a new image tag/version, measures it through /version, then
restores the baseline with a Git revert before the next iteration.

Scenario options:
  --new-tag TAG          Pre-published immutable image tag (required)
  --new-version VERSION  APP_VERSION exposed by the image (required)
EOF
  common_options
  git_options
}

NEW_TAG=""
NEW_VERSION=""
parse_common_args "$@"
parse_git_args "${COMMON_REMAINING_ARGS[@]}"
set -- "${GIT_REMAINING_ARGS[@]}"
while (($#)); do
  case "$1" in
    --new-tag)
      (($# >= 2)) || die "--new-tag requires a value"
      NEW_TAG="$2"
      shift 2
      ;;
    --new-version)
      (($# >= 2)) || die "--new-version requires a value"
      NEW_VERSION="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ -n "${NEW_TAG}" ]] || die "--new-tag is required"
[[ -n "${NEW_VERSION}" ]] || die "--new-version is required"
[[ "${NEW_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || \
  die "--new-tag must be a valid container image tag"
[[ ${#NEW_VERSION} -le 63 && "${NEW_VERSION}" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] || \
  die "--new-version must also be a valid Kubernetes label value"
require_commands kubectl python3 awk git
prepare_results
prepare_git_mutation

deployment="$(resolve_deployment)"
service_resource="$(resolve_service)"
baseline_tag="$(values_get image.tag)"
baseline_version="$(values_get env.APP_VERSION)"
[[ "${NEW_TAG}" != "${baseline_tag}" || "${NEW_VERSION}" != "${baseline_version}" ]] || \
  die "New tag/version equal the baseline"

image_has_new_tag() {
  local image
  image="$(deployment_field "${deployment}" '{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  [[ "${image}" == *":${NEW_TAG}" ]]
}

for ((iteration=1; iteration<=ITERATIONS; iteration++)); do
  begin_iteration "deploy_new_version" "${iteration}"
  prepare_iteration_baseline "${deployment}" || die "Stable baseline was not reached before iteration ${iteration}"
  baseline_image="$(deployment_field "${deployment}" '{.spec.template.spec.containers[0].image}')"
  values_set image.tag "${NEW_TAG}"
  values_set env.APP_VERSION "${NEW_VERSION}"
  snapshot_cluster "before"
  capture_controller_baseline
  log "Committing ${SERVICE} tag=${NEW_TAG}, APP_VERSION=${NEW_VERSION}"
  start_measurement
  commit_and_push_values "experiment(${TOOL}): deploy ${SERVICE} ${NEW_VERSION} [iteration ${iteration}]"
  change_commit="${LAST_GIT_COMMIT}"

  source_reaction_or_new_image() {
    controller_source_reaction_observed || image_has_new_tag
  }
  if ! wait_until "controller detected/reacted to the new Git revision" source_reaction_or_new_image; then
    finish_failure "deploy_new_version" "${iteration}" "" "detection_timeout"
    exit 1
  fi
  detection_iso="${WAIT_TIME_ISO}"

  new_version_ready() {
    image_has_new_tag && deployment_is_ready "${deployment}" && \
      endpoint_field_equals "${service_resource}" version version "${NEW_VERSION}"
  }
  if ! wait_until "new version ready and returned by /version" new_version_ready; then
    finish_failure "deploy_new_version" "${iteration}" "${detection_iso}" "recovery_timeout"
    exit 1
  fi
  finish_success "deploy_new_version" "${iteration}" "${detection_iso}" "${WAIT_TIME_ISO}" "${WAIT_TIME_MS}"

  log "Restoring baseline with a Git rollback commit"
  revert_and_push "${change_commit}"
  baseline_restored() {
    [[ "$(deployment_field "${deployment}" '{.spec.template.spec.containers[0].image}' 2>/dev/null || true)" == "${baseline_image}" ]] && \
      deployment_is_ready "${deployment}" && \
      endpoint_field_equals "${service_resource}" version version "${baseline_version}"
  }
  wait_until "baseline version restored before next iteration" baseline_restored || \
    die "Baseline restoration timed out after iteration ${iteration}"
  pause_between_iterations "${iteration}"
done
