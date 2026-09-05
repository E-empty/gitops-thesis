#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: experiments/restart-gitops-controller.sh --tool argocd|fluxcd [options]

Deletes the primary reconciliation controller Pod and measures its recreation.

Scenario options:
  --controller-namespace NAME  Override argocd/flux-system
  --selector LABELS            Override the controller Pod label selector
EOF
  common_options
}

CONTROLLER_NAMESPACE=""
CONTROLLER_SELECTOR=""
parse_common_args "$@"
set -- "${COMMON_REMAINING_ARGS[@]}"
while (($#)); do
  case "$1" in
    --controller-namespace)
      (($# >= 2)) || die "--controller-namespace requires a value"
      CONTROLLER_NAMESPACE="$2"
      shift 2
      ;;
    --selector)
      (($# >= 2)) || die "--selector requires a value"
      CONTROLLER_SELECTOR="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
require_commands kubectl python3 awk
prepare_results

if [[ "${TOOL}" == "argocd" ]]; then
  CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-argocd}"
  CONTROLLER_SELECTOR="${CONTROLLER_SELECTOR:-app.kubernetes.io/name=argocd-application-controller}"
else
  CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-flux-system}"
  CONTROLLER_SELECTOR="${CONTROLLER_SELECTOR:-app=helm-controller}"
fi
is_dns_label "${CONTROLLER_NAMESPACE}" || die "--controller-namespace must be a valid DNS label"

controller_pod_name() {
  kubectl -n "${CONTROLLER_NAMESPACE}" get pods -l "${CONTROLLER_SELECTOR}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

controller_pod_records() {
  kubectl -n "${CONTROLLER_NAMESPACE}" get pods -l "${CONTROLLER_SELECTOR}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.uid}{"\n"}{end}' 2>/dev/null
}

controller_pod_uid() {
  local pod_name="$1"
  kubectl -n "${CONTROLLER_NAMESPACE}" get pod "${pod_name}" \
    -o jsonpath='{.metadata.uid}' 2>/dev/null
}

pod_is_ready() {
  local pod_name="$1" ready
  ready="$(kubectl -n "${CONTROLLER_NAMESPACE}" get pod "${pod_name}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [[ "${ready}" == "True" ]]
}

replacement_pod_name() {
  local candidate candidate_uid
  while IFS=$'\t' read -r candidate candidate_uid; do
    [[ -n "${candidate}" && -n "${candidate_uid}" ]] || continue
    if [[ "|${BASELINE_CONTROLLER_UIDS}|" != *"|${candidate_uid}|"* ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done < <(controller_pod_records)
  return 1
}

snapshot_controller() {
  local snapshot_phase="$1"
  {
    printf '\n===== controller snapshot %s (%s) =====\n' "${snapshot_phase}" "$(now_iso)"
    kubectl -n "${CONTROLLER_NAMESPACE}" get pods -l "${CONTROLLER_SELECTOR}" -o wide 2>&1 || true
    kubectl -n "${CONTROLLER_NAMESPACE}" describe pods -l "${CONTROLLER_SELECTOR}" 2>&1 || true
    kubectl -n "${CONTROLLER_NAMESPACE}" get events --sort-by=.lastTimestamp 2>&1 || true
  } >>"${CURRENT_LOG}"
}

for ((iteration=1; iteration<=ITERATIONS; iteration++)); do
  old_pod="$(controller_pod_name || true)"
  [[ -n "${old_pod}" ]] || die "No controller Pod matches '${CONTROLLER_SELECTOR}' in '${CONTROLLER_NAMESPACE}'"
  begin_iteration "restart_controller" "${iteration}"
  wait_until "selected controller Pod ready before restart" pod_is_ready "${old_pod}" || \
    die "Controller Pod ${old_pod} was not ready before iteration ${iteration}"
  settle_before_measurement
  wait_until "selected controller Pod remains ready after the pre-mutation delay" \
    pod_is_ready "${old_pod}" || \
    die "Controller Pod ${old_pod} did not remain ready before iteration ${iteration}"
  old_uid="$(controller_pod_uid "${old_pod}")"
  BASELINE_CONTROLLER_UIDS="$(controller_pod_records | awk -F '\t' 'NF >= 2 {printf "%s|", $2}')"
  [[ -n "${BASELINE_CONTROLLER_UIDS}" ]] || die "Cannot capture baseline controller Pod UIDs"
  snapshot_controller "before"

  log "Deleting controller Pod ${CONTROLLER_NAMESPACE}/${old_pod} (uid=${old_uid})"
  start_measurement
  kubectl -n "${CONTROLLER_NAMESPACE}" delete pod "${old_pod}" --wait=false >>"${CURRENT_LOG}" 2>&1

  replacement_observed() {
    [[ -n "$(replacement_pod_name 2>/dev/null || true)" ]]
  }
  if ! wait_until "replacement controller Pod observed" replacement_observed; then
    snapshot_controller "failure"
    finish_failure "restart_controller" "${iteration}" "" "detection_timeout"
    exit 1
  fi
  detection_iso="${WAIT_TIME_ISO}"

  replacement_ready() {
    local candidate
    candidate="$(replacement_pod_name 2>/dev/null || true)"
    [[ -n "${candidate}" ]] || return 1
    pod_is_ready "${candidate}"
  }
  if ! wait_until "replacement controller Pod ready" replacement_ready; then
    snapshot_controller "failure"
    finish_failure "restart_controller" "${iteration}" "${detection_iso}" "recovery_timeout"
    exit 1
  fi
  snapshot_controller "after"
  record_result "restart_controller" "${iteration}" "${detection_iso}" "${WAIT_TIME_ISO}" "${WAIT_TIME_MS}" "success"
  log "Controller recovered"
  pause_between_iterations "${iteration}"
done
