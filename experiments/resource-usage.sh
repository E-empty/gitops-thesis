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
  --sample-interval SECONDS    Delay between samples (default: 15)
  --trigger-command COMMAND    Command run concurrently for sync/drift phases

For this scenario --iterations is the number of metric samples.
For sync and drift, a trigger command is required so the phase is not merely a
label. Quote it as one shell argument; it should include its own timeout.
EOF
  common_options
}

PHASE="idle"
CONTROLLER_NAMESPACE=""
SAMPLE_INTERVAL=15
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
IFS= read -r resource_header <"${csv_file}"
[[ "${resource_header}" == 'tool,phase,iteration,timestamp,namespace,pod,cpu_raw,memory_raw,cpu_millicores,memory_mib,status' ]] || \
  die "Unexpected CSV schema in ${csv_file}; use a new --results-dir instead of appending"

if ! python3 - "${csv_file}" "${TOOL}" "${PHASE}" <<'PY'
import csv
import sys

path, tool, phase = sys.argv[1:]
with open(path, encoding="utf-8", newline="") as handle:
    duplicate_series = any(
        row.get("tool") == tool and row.get("phase") == phase
        for row in csv.DictReader(handle)
    )
raise SystemExit(1 if duplicate_series else 0)
PY
then
  die "Resource series ${TOOL}/${PHASE} already exists in ${csv_file}; use a new --results-dir for a new series"
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
  LC_ALL=C awk -v value="$1" 'BEGIN {
    if (value ~ /n$/) { sub(/n$/, "", value); printf "%.6f", value/1000000 }
    else if (value ~ /u$/) { sub(/u$/, "", value); printf "%.6f", value/1000 }
    else if (value ~ /m$/) { sub(/m$/, "", value); printf "%.6f", value }
    else { printf "%.6f", value*1000 }
  }'
}

memory_to_mib() {
  LC_ALL=C awk -v value="$1" 'BEGIN {
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

controller_pod_names() {
  kubectl -n "${CONTROLLER_NAMESPACE}" get pods \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

metrics_include_pod() {
  local metrics="$1"
  local expected_pod="$2"
  LC_ALL=C awk -v pod="${expected_pod}" \
    '$1 == pod { found = 1 } END { exit(found ? 0 : 1) }' <<<"${metrics}"
}

all_controller_metrics_available() {
  local pods metrics pod
  pods="$(controller_pod_names 2>>"${CURRENT_LOG}")" || return 1
  [[ -n "${pods}" ]] || return 1
  metrics="$(kubectl top pods -n "${CONTROLLER_NAMESPACE}" --no-headers \
    2>>"${CURRENT_LOG}")" || return 1
  [[ -n "${metrics}" ]] || return 1
  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    metrics_include_pod "${metrics}" "${pod}" || return 1
  done <<<"${pods}"
}

snapshot_controller_resources "before"
kubectl -n "${CONTROLLER_NAMESPACE}" wait pod --all \
  --for=condition=Ready --timeout="${TIMEOUT_SECONDS}s" >>"${CURRENT_LOG}" 2>&1 \
  || die "Controller Pods did not become Ready before resource sampling"
wait_until "Metrics Server reports every controller Pod" \
  all_controller_metrics_available \
  || die "Metrics Server did not report every controller Pod before sampling"
baseline_controller_pod_count="$(controller_pod_names | LC_ALL=C awk 'NF { count++ } END { print count + 0 }')"
log "Collecting ${ITERATIONS} ${PHASE} samples from namespace ${CONTROLLER_NAMESPACE}"
if [[ -n "${TRIGGER_COMMAND}" ]]; then
  log "Starting phase trigger: ${TRIGGER_COMMAND}"
  bash -c "${TRIGGER_COMMAND}" >>"${CURRENT_LOG}" 2>&1 &
  TRIGGER_PID=$!
fi
for ((iteration=1; iteration<=ITERATIONS; iteration++)); do
  timestamp="$(now_iso)"
  controller_pods="$(controller_pod_names 2>>"${CURRENT_LOG}" || true)"
  controller_pod_count="$(LC_ALL=C awk 'NF { count++ } END { print count + 0 }' <<<"${controller_pods}")"
  metrics="$(kubectl top pods -n "${CONTROLLER_NAMESPACE}" --no-headers 2>>"${CURRENT_LOG}" || true)"
  sample_complete=true
  if [[ -z "${metrics}" || -z "${controller_pods}" ||
        "${controller_pod_count}" -ne "${baseline_controller_pod_count}" ]]; then
    sample_complete=false
  fi
  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    if ! metrics_include_pod "${metrics}" "${pod}"; then
      sample_complete=false
      log "Sample ${iteration}: metrics unavailable for Pod ${pod}"
    fi
  done <<<"${controller_pods}"
  if [[ "${sample_complete}" == false ]]; then
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$(csv_escape "${TOOL}")" "$(csv_escape "${PHASE}")" "${iteration}" \
      "$(csv_escape "${timestamp}")" "$(csv_escape "${CONTROLLER_NAMESPACE}")" \
      '""' '""' '""' '""' '""' '"metrics_unavailable"' >>"${csv_file}"
    log "Sample ${iteration}: incomplete controller metrics"
  fi
  if [[ -n "${metrics}" ]]; then
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
