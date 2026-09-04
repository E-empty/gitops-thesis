#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: experiments/resource-usage.sh --tool argocd|fluxcd [options]

Collects controller Pod CPU and memory samples from Metrics Server.

Scenario options:
  --phase idle|sync|drift       Measurement phase label (default: idle)
  --controller-namespace NAME  Override argocd/flux-system
  --sample-interval SECONDS    Delay between samples (default: 5)
  --trigger-command COMMAND    Command run concurrently for sync/drift phases

For this scenario --iterations is the number of metric samples.
For sync and drift, a trigger command is required so the phase is not merely a
label. Quote it as one shell argument; it should include its own timeout.
EOF
  common_options
}

PHASE="idle"
CONTROLLER_NAMESPACE=""
SAMPLE_INTERVAL=5
TRIGGER_COMMAND=""
TRIGGER_PID=""
parse_common_args "$@"
set -- "${COMMON_REMAINING_ARGS[@]}"
while (($#)); do
  case "$1" in
    --phase)
      (($# >= 2)) || die "--phase requires a value"
      PHASE="$2"
      shift 2
      ;;
    --controller-namespace)
      (($# >= 2)) || die "--controller-namespace requires a value"
      CONTROLLER_NAMESPACE="$2"
      shift 2
      ;;
    --sample-interval)
      (($# >= 2)) || die "--sample-interval requires a value"
      SAMPLE_INTERVAL="$2"
      shift 2
      ;;
    --trigger-command)
      (($# >= 2)) || die "--trigger-command requires a value"
      TRIGGER_COMMAND="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ "${PHASE}" == "idle" || "${PHASE}" == "sync" || "${PHASE}" == "drift" ]] || \
  die "--phase must be idle, sync, or drift"
is_nonnegative_number "${SAMPLE_INTERVAL}" || die "--sample-interval must be non-negative"
if [[ "${PHASE}" == "idle" && -n "${TRIGGER_COMMAND}" ]]; then
  die "--trigger-command is not valid for the idle phase"
fi
if [[ "${PHASE}" != "idle" && -z "${TRIGGER_COMMAND}" ]]; then
  die "--trigger-command is required for the ${PHASE} phase"
fi
require_commands kubectl python3 awk
prepare_results

if [[ "${TOOL}" == "argocd" ]]; then
  CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-argocd}"
else
  CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-flux-system}"
fi
is_dns_label "${CONTROLLER_NAMESPACE}" || die "--controller-namespace must be a valid DNS label"

csv_file="${RESULTS_DIR}/${TOOL}/resource_usage.csv"
if [[ ! -s "${csv_file}" ]]; then
  printf '%s\n' 'tool,phase,iteration,timestamp,namespace,pod,cpu_raw,memory_raw,cpu_millicores,memory_mib,status' >"${csv_file}"
fi
RESOURCE_TERMINAL_STATUS_RECORDED=false
CURRENT_LOG="${RESULTS_DIR}/logs/${TOOL}/resource-usage-${PHASE}-$(now_iso | tr ':' '-').log"
: >"${CURRENT_LOG}"

snapshot_controller_resources() {
  local snapshot_phase="$1"
  {
    printf '\n===== controller %s snapshot (%s) =====\n' "${snapshot_phase}" "$(now_iso)"
    kubectl -n "${CONTROLLER_NAMESPACE}" get deployments,statefulsets,pods -o wide 2>&1 || true
    printf '\n--- controller pods YAML ---\n'
    kubectl -n "${CONTROLLER_NAMESPACE}" get pods -o yaml 2>&1 || true
    printf '\n--- recent controller events ---\n'
    kubectl -n "${CONTROLLER_NAMESPACE}" get events --sort-by=.lastTimestamp 2>&1 || true
  } >>"${CURRENT_LOG}"
}

cleanup_trigger() {
  local status="$1"
  local resource_status=""
  trap - EXIT INT TERM
  if [[ -n "${TRIGGER_PID}" ]] && kill -0 "${TRIGGER_PID}" 2>/dev/null; then
    log "Stopping unfinished trigger process ${TRIGGER_PID}"
    kill "${TRIGGER_PID}" 2>/dev/null || true
    wait "${TRIGGER_PID}" 2>/dev/null || true
  fi
  if (( status != 0 )); then
    if [[ "${RESOURCE_TERMINAL_STATUS_RECORDED}" == false ]]; then
      resource_status="script_error"
      if (( status == 130 || status == 143 )); then
        resource_status="interrupted"
      fi
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_escape "${TOOL}")" "$(csv_escape "${PHASE}")" "${ITERATIONS}" \
        "$(csv_escape "$(now_iso)")" "$(csv_escape "${CONTROLLER_NAMESPACE}")" \
        '""' '""' '""' '""' '""' "$(csv_escape "${resource_status}")" >>"${csv_file}"
      RESOURCE_TERMINAL_STATUS_RECORDED=true
    fi
    snapshot_controller_resources "failure"
  fi
  exit "${status}"
}
trap 'cleanup_trigger $?' EXIT
trap 'cleanup_trigger 130' INT
trap 'cleanup_trigger 143' TERM

cpu_to_millicores() {
  awk -v value="$1" 'BEGIN {
    if (value ~ /n$/) { sub(/n$/, "", value); printf "%.6f", value/1000000 }
    else if (value ~ /u$/) { sub(/u$/, "", value); printf "%.6f", value/1000 }
    else if (value ~ /m$/) { sub(/m$/, "", value); printf "%.6f", value }
    else { printf "%.6f", value*1000 }
  }'
}

memory_to_mib() {
  awk -v value="$1" 'BEGIN {
    if (value ~ /Ki$/) { sub(/Ki$/, "", value); printf "%.6f", value/1024 }
    else if (value ~ /Mi$/) { sub(/Mi$/, "", value); printf "%.6f", value }
    else if (value ~ /Gi$/) { sub(/Gi$/, "", value); printf "%.6f", value*1024 }
    else if (value ~ /Ti$/) { sub(/Ti$/, "", value); printf "%.6f", value*1048576 }
    else if (value ~ /[kK]$/) { sub(/[kK]$/, "", value); printf "%.6f", value*1000/1048576 }
    else if (value ~ /M$/) { sub(/M$/, "", value); printf "%.6f", value*1000000/1048576 }
    else if (value ~ /G$/) { sub(/G$/, "", value); printf "%.6f", value*1000000000/1048576 }
    else if (value ~ /T$/) { sub(/T$/, "", value); printf "%.6f", value*1000000000000/1048576 }
    else { printf "%.6f", value/1048576 }
  }'
}

snapshot_controller_resources "before"
log "Collecting ${ITERATIONS} ${PHASE} samples from namespace ${CONTROLLER_NAMESPACE}"
if [[ -n "${TRIGGER_COMMAND}" ]]; then
  log "Starting phase trigger: ${TRIGGER_COMMAND}"
  bash -c "${TRIGGER_COMMAND}" >>"${CURRENT_LOG}" 2>&1 &
  TRIGGER_PID=$!
fi
for ((iteration=1; iteration<=ITERATIONS; iteration++)); do
  timestamp="$(now_iso)"
  metrics="$(kubectl top pods -n "${CONTROLLER_NAMESPACE}" --no-headers 2>>"${CURRENT_LOG}" || true)"
  if [[ -z "${metrics}" ]]; then
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$(csv_escape "${TOOL}")" "$(csv_escape "${PHASE}")" "${iteration}" \
      "$(csv_escape "${timestamp}")" "$(csv_escape "${CONTROLLER_NAMESPACE}")" \
      '""' '""' '""' '""' '""' '"metrics_unavailable"' >>"${csv_file}"
    log "Sample ${iteration}: metrics unavailable"
  else
    while read -r pod cpu memory _rest; do
      [[ -n "${pod}" ]] || continue
      cpu_m="$(cpu_to_millicores "${cpu}")"
      memory_mib="$(memory_to_mib "${memory}")"
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_escape "${TOOL}")" "$(csv_escape "${PHASE}")" "${iteration}" \
        "$(csv_escape "${timestamp}")" "$(csv_escape "${CONTROLLER_NAMESPACE}")" \
        "$(csv_escape "${pod}")" "$(csv_escape "${cpu}")" "$(csv_escape "${memory}")" \
        "${cpu_m}" "${memory_mib}" '"success"' >>"${csv_file}"
      printf '[%s] %s cpu=%s (%sm) memory=%s (%sMi)\n' \
        "${timestamp}" "${pod}" "${cpu}" "${cpu_m}" "${memory}" "${memory_mib}" >>"${CURRENT_LOG}"
    done <<<"${metrics}"
  fi
  if (( iteration < ITERATIONS )); then
    sleep "${SAMPLE_INTERVAL}"
  fi
done
if [[ -n "${TRIGGER_PID}" ]]; then
  if wait "${TRIGGER_PID}"; then
    log "Phase trigger completed successfully"
  else
    trigger_status=$?
    TRIGGER_PID=""
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$(csv_escape "${TOOL}")" "$(csv_escape "${PHASE}")" "${ITERATIONS}" \
      "$(csv_escape "$(now_iso)")" "$(csv_escape "${CONTROLLER_NAMESPACE}")" \
      '""' '""' '""' '""' '""' '"trigger_failed"' >>"${csv_file}"
    RESOURCE_TERMINAL_STATUS_RECORDED=true
    die "Phase trigger failed with exit code ${trigger_status}; samples remain available in ${csv_file}"
  fi
  TRIGGER_PID=""
fi
snapshot_controller_resources "after"
log "Metrics written to ${csv_file}"
