#!/usr/bin/env bash

# Shared helpers for repeatable GitOps experiments. This file is sourced by the
# scenario scripts; it intentionally does not enable shell options itself.

EXPERIMENTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd -- "${EXPERIMENTS_DIR}/.." && pwd)"

# Git Bash on Windows commonly exposes the interpreter as `python`, whereas
# Linux/macOS environments normally provide `python3`. Keep the scenario code
# uniform while accepting either executable.
python_runtime_supported() {
  local resolved=""
  resolved="$(command -v "$1" 2>/dev/null)" || return 1
  # Microsoft Store App Execution Aliases look executable to `command -v` but
  # may block while opening the Store instead of running Python.
  [[ "${resolved}" != */WindowsApps/python* ]] || return 1
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' \
    >/dev/null 2>&1
}

if ! python_runtime_supported python3; then
  if python_runtime_supported python; then
    python3() {
      command python "$@"
    }
  elif command -v py >/dev/null 2>&1 \
    && py -3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' \
      >/dev/null 2>&1; then
    python3() {
      command py -3 "$@"
    }
  fi
fi

TOOL="${TOOL:-}"
ITERATIONS="${ITERATIONS:-10}"
NAMESPACE="${NAMESPACE:-}"
SERVICE="${SERVICE:-gateway-service}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-1}"
SETTLE_SECONDS="${SETTLE_SECONDS:-5}"
PHASE_WINDOW_SECONDS="${PHASE_WINDOW_SECONDS:-60}"
DELAY_SEED="${DELAY_SEED:-20260905}"
RESULTS_DIR="${RESULTS_DIR:-${REPO_ROOT}/results}"
GITOPS_RESOURCE_NAME="${GITOPS_RESOURCE_NAME:-microservices-app}"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-gitops-thesis}"
ALLOW_ARGOCD_SELF_HEAL_BACKOFF="${ALLOW_ARGOCD_SELF_HEAL_BACKOFF:-false}"

# Route every experiment command to the declared context without changing the
# user's active kubeconfig context. Define the wrapper only when the real CLI is
# present so require_commands still reports a missing kubectl correctly.
if command -v kubectl >/dev/null 2>&1; then
  kubectl() {
    command kubectl --context "${KUBE_CONTEXT}" "$@"
  }
fi
COMMON_REMAINING_ARGS=()
CURRENT_LOG=""
CURRENT_TEST_NAME=""
CURRENT_ITERATION=""
CURRENT_START_ISO=""
CURRENT_START_MS=""
CURRENT_RESULT_RECORDED=true
CURRENT_DETECTION_ISO=""
COMMON_SIGNAL_TRAPS_INSTALLED=false
WAIT_TIME_ISO=""
WAIT_TIME_MS=""
CONTROLLER_BASELINE_OPERATION=""
CONTROLLER_BASELINE_REVISION=""
CONTROLLER_BASELINE_DRIFT_STATUS=""
CONTROLLER_BASELINE_DRIFT_TRANSITION=""
CONTROLLER_BASELINE_DRIFT_EVENTS=""

common_options() {
  cat <<'EOF'
  --tool argocd|fluxcd    GitOps controller under test (required)
  --iterations N         Number of repetitions (default: 10)
  --namespace NAME       Application namespace (default: test-<tool>)
  --service NAME         Service label to target (default: gateway-service)
  --timeout SECONDS      Maximum wait per phase (default: 300)
  --poll-interval SEC    Observation interval (default: 1)
  --settle-seconds SEC   Minimum pre-mutation stabilization (default: 5)
  --phase-window SEC     Deterministic extra delay window (default: 60)
  --delay-seed N         Seed shared by both tools (default: 20260905)
  --results-dir PATH     Results root (default: <repository>/results)
  --gitops-resource NAME Application/HelmRelease name (default: microservices-app)
  --context NAME         kube-context to target (default: kind-gitops-thesis)
  --allow-argocd-self-heal-backoff
                         Permit native stateful backoff in drift tests
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  if [[ -n "${CURRENT_START_MS}" && "${CURRENT_RESULT_RECORDED}" == false ]]; then
    finish_failure "${CURRENT_TEST_NAME:-unknown}" "${CURRENT_ITERATION:-0}" \
      "${CURRENT_DETECTION_ISO}" "command_error"
  fi
  exit 1
}

log() {
  local message
  message="[$(now_iso)] $*"
  printf '%s\n' "${message}"
  if [[ -n "${CURRENT_LOG}" ]]; then
    printf '%s\n' "${message}" >>"${CURRENT_LOG}"
  fi
}

now_iso() {
  python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"))'
}

now_epoch_ms() {
  python3 -c 'import time; print(time.time_ns() // 1_000_000)'
}

now_monotonic_ms() {
  python3 -c 'import time; print(time.monotonic_ns() // 1_000_000)'
}

clock_sample() {
  python3 -c 'from datetime import datetime, timezone; import time; print(datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"), time.monotonic_ns() // 1_000_000, sep="\t")'
}

elapsed_seconds() {
  local start_ms="$1"
  local end_ms="$2"
  LC_ALL=C awk -v start="${start_ms}" -v end="${end_ms}" \
    'BEGIN { printf "%.3f", (end-start)/1000 }'
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_nonnegative_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_dns_label() {
  [[ ${#1} -le 63 && "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}

parse_common_args() {
  local help_requested=false
  while (($#)); do
    case "$1" in
      --tool)
        (($# >= 2)) || die "--tool requires a value"
        TOOL="$2"
        shift 2
        ;;
      --iterations)
        (($# >= 2)) || die "--iterations requires a value"
        ITERATIONS="$2"
        shift 2
        ;;
      --namespace)
        (($# >= 2)) || die "--namespace requires a value"
        NAMESPACE="$2"
        shift 2
        ;;
      --service)
        (($# >= 2)) || die "--service requires a value"
        SERVICE="$2"
        shift 2
        ;;
      --timeout)
        (($# >= 2)) || die "--timeout requires a value"
        TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --poll-interval)
        (($# >= 2)) || die "--poll-interval requires a value"
        POLL_INTERVAL="$2"
        shift 2
        ;;
      --settle-seconds)
        (($# >= 2)) || die "--settle-seconds requires a value"
        SETTLE_SECONDS="$2"
        shift 2
        ;;
      --phase-window)
        (($# >= 2)) || die "--phase-window requires a value"
        PHASE_WINDOW_SECONDS="$2"
        shift 2
        ;;
      --delay-seed)
        (($# >= 2)) || die "--delay-seed requires a value"
        DELAY_SEED="$2"
        shift 2
        ;;
      --results-dir)
        (($# >= 2)) || die "--results-dir requires a value"
        RESULTS_DIR="$2"
        shift 2
        ;;
      --gitops-resource)
        (($# >= 2)) || die "--gitops-resource requires a value"
        GITOPS_RESOURCE_NAME="$2"
        shift 2
        ;;
      --context)
        (($# >= 2)) || die "--context requires a value"
        KUBE_CONTEXT="$2"
        shift 2
        ;;
      --allow-argocd-self-heal-backoff)
        ALLOW_ARGOCD_SELF_HEAL_BACKOFF=true
        shift
        ;;
      -h|--help)
        COMMON_REMAINING_ARGS+=("$1")
        help_requested=true
        shift
        ;;
      *)
        COMMON_REMAINING_ARGS+=("$1")
        shift
        ;;
    esac
  done

  if [[ "${help_requested}" == true ]]; then
    return 0
  fi

  [[ "${TOOL}" == "argocd" || "${TOOL}" == "fluxcd" ]] || \
    die "--tool must be argocd or fluxcd"
  is_positive_integer "${ITERATIONS}" || die "--iterations must be a positive integer"
  is_positive_integer "${TIMEOUT_SECONDS}" || die "--timeout must be a positive integer"
  is_nonnegative_number "${POLL_INTERVAL}" || die "--poll-interval must be a non-negative number"
  is_nonnegative_number "${SETTLE_SECONDS}" || die "--settle-seconds must be a non-negative number"
  is_nonnegative_number "${PHASE_WINDOW_SECONDS}" || die "--phase-window must be a non-negative number"
  [[ "${DELAY_SEED}" =~ ^[0-9]+$ ]] || die "--delay-seed must be a non-negative integer"
  if [[ -z "${NAMESPACE}" ]]; then
    NAMESPACE="test-${TOOL}"
  fi
  is_dns_label "${NAMESPACE}" || die "--namespace must be a valid DNS label"
  is_dns_label "${SERVICE}" || die "--service must be a valid DNS label"
  is_dns_label "${GITOPS_RESOURCE_NAME}" || \
    die "--gitops-resource must be a valid DNS label"
  if command -v kubectl >/dev/null 2>&1; then
    kubectl cluster-info >/dev/null 2>&1 || \
      die "Kubernetes context is not reachable: ${KUBE_CONTEXT}"
  fi
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    if [[ "${command_name}" == "python3" ]]; then
      python_runtime_supported python3 || \
        die "Python 3.12+ not found (tried python3 and python)"
    else
      command -v "${command_name}" >/dev/null 2>&1 || \
        die "Required command not found: ${command_name}"
    fi
  done
}

prepare_results() {
  mkdir -p "${RESULTS_DIR}/${TOOL}" "${RESULTS_DIR}/logs/${TOOL}"
}

ensure_iteration_is_new() {
  local test_name="$1"
  local iteration="$2"
  local csv_file="${RESULTS_DIR}/${TOOL}/${test_name}.csv"
  local header
  [[ -s "${csv_file}" ]] || return 0
  IFS= read -r header <"${csv_file}"
  [[ "${header}" == 'tool,test,iteration,start_time,detection_time,recovery_time,total_seconds,status' ]] || \
    die "Unexpected CSV schema in ${csv_file}; use a new --results-dir instead of appending"
  if ! python3 - "${csv_file}" "${TOOL}" "${test_name}" "${iteration}" <<'PY'
import csv
import sys

path, tool, test, iteration = sys.argv[1:]
with open(path, encoding="utf-8", newline="") as handle:
    duplicate = any(
        row.get("tool") == tool
        and row.get("test") == test
        and row.get("iteration") == iteration
        for row in csv.DictReader(handle)
    )
raise SystemExit(1 if duplicate else 0)
PY
  then
    die "Result ${TOOL}/${test_name} iteration ${iteration} already exists in ${csv_file}; use a new --results-dir for a new series"
  fi
}

csv_escape() {
  local value="${1//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//\"/\"\"}"
  printf '"%s"' "${value}"
}

ensure_result_header() {
  local csv_file="$1"
  if [[ ! -s "${csv_file}" ]]; then
    printf '%s\n' 'tool,test,iteration,start_time,detection_time,recovery_time,total_seconds,status' >"${csv_file}"
  fi
}

record_result() {
  local test_name="$1"
  local iteration="$2"
  local detection_iso="$3"
  local recovery_iso="$4"
  local end_ms="$5"
  local status="$6"
  local csv_file="${RESULTS_DIR}/${TOOL}/${test_name}.csv"
  local total_seconds
  ensure_result_header "${csv_file}"
  total_seconds="$(elapsed_seconds "${CURRENT_START_MS}" "${end_ms}")"
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(csv_escape "${TOOL}")" \
    "$(csv_escape "${test_name}")" \
    "${iteration}" \
    "$(csv_escape "${CURRENT_START_ISO}")" \
    "$(csv_escape "${detection_iso}")" \
    "$(csv_escape "${recovery_iso}")" \
    "${total_seconds}" \
    "$(csv_escape "${status}")" >>"${csv_file}"
  CURRENT_RESULT_RECORDED=true
  trap - ERR
  if [[ "${COMMON_SIGNAL_TRAPS_INSTALLED}" == true ]]; then
    trap - INT TERM
    COMMON_SIGNAL_TRAPS_INSTALLED=false
  fi
}

begin_iteration() {
  local test_name="$1"
  local iteration="$2"
  local log_timestamp safe_timestamp
  ensure_iteration_is_new "${test_name}" "${iteration}"
  log_timestamp="$(now_iso)"
  safe_timestamp="${log_timestamp//:/-}"
  CURRENT_LOG="${RESULTS_DIR}/logs/${TOOL}/${test_name}-${iteration}-${safe_timestamp}.log"
  CURRENT_TEST_NAME="${test_name}"
  CURRENT_ITERATION="${iteration}"
  : >"${CURRENT_LOG}"
  log "Starting ${test_name}, iteration ${iteration}, tool=${TOOL}, namespace=${NAMESPACE}, service=${SERVICE}"
}

iteration_delay_seconds() {
  local test_name="$1"
  local iteration="$2"
  python3 - "${DELAY_SEED}" "${test_name}" "${iteration}" \
    "${SETTLE_SECONDS}" "${PHASE_WINDOW_SECONDS}" <<'PY'
import hashlib
import sys

seed, test, iteration, minimum, window = sys.argv[1:]
digest = hashlib.sha256(f"{seed}:{test}:{iteration}".encode()).digest()
fraction = int.from_bytes(digest[:8], "big") / (2**64 - 1)
delay = float(minimum) + fraction * float(window)
print(f"{delay:.3f}")
PY
}

settle_before_measurement() {
  local test_name="${1:-${CURRENT_TEST_NAME}}"
  local iteration="${2:-${CURRENT_ITERATION}}"
  local delay
  delay="$(iteration_delay_seconds "${test_name}" "${iteration}")"
  log "Pre-mutation stabilization delay: ${delay}s (seed=${DELAY_SEED}, window=${PHASE_WINDOW_SECONDS}s)"
  sleep "${delay}"
}

start_measurement() {
  local message
  # Durations and deadlines use the monotonic clock so NTP or a manual clock
  # correction cannot make an experiment shorter, longer, or negative.
  IFS=$'\t' read -r CURRENT_START_ISO CURRENT_START_MS < <(clock_sample)
  CURRENT_RESULT_RECORDED=false
  CURRENT_DETECTION_ISO=""
  set -E
  trap 'handle_unexpected_experiment_error $? $LINENO' ERR
  install_measurement_signal_traps
  message="[${CURRENT_START_ISO}] Measurement clock started"
  printf '%s\n' "${message}"
  [[ -z "${CURRENT_LOG}" ]] || printf '%s\n' "${message}" >>"${CURRENT_LOG}"
}

install_measurement_signal_traps() {
  if [[ -z "$(trap -p INT)" && -z "$(trap -p TERM)" ]]; then
    trap 'handle_measurement_signal INT 130' INT
    trap 'handle_measurement_signal TERM 143' TERM
    COMMON_SIGNAL_TRAPS_INSTALLED=true
  fi
}

handle_measurement_signal() {
  local signal_name="$1"
  local signal_status="$2"
  trap - INT TERM
  COMMON_SIGNAL_TRAPS_INSTALLED=false
  log "Received SIG${signal_name}; recording an interrupted iteration"
  if [[ "${CURRENT_RESULT_RECORDED}" == false ]]; then
    finish_failure "${CURRENT_TEST_NAME:-unknown}" "${CURRENT_ITERATION:-0}" \
      "${CURRENT_DETECTION_ISO}" "interrupted"
  fi
  exit "${signal_status}"
}

handle_unexpected_experiment_error() {
  local command_status="$1"
  local line_number="$2"
  trap - ERR
  if [[ "${CURRENT_RESULT_RECORDED}" == false ]]; then
    log "Unexpected command failure at line ${line_number} (exit ${command_status})"
    finish_failure "${CURRENT_TEST_NAME:-unknown}" "${CURRENT_ITERATION:-0}" \
      "${CURRENT_DETECTION_ISO}" "command_error"
  fi
  return "${command_status}"
}

snapshot_cluster() {
  local phase="$1"
  {
    printf '\n===== %s snapshot (%s) =====\n' "${phase}" "$(now_iso)"
    kubectl -n "${NAMESPACE}" get deployments,pods,services,configmaps -o wide 2>&1 || true
    printf '\n--- deployments YAML ---\n'
    kubectl -n "${NAMESPACE}" get deployments -o yaml 2>&1 || true
    printf '\n--- recent events ---\n'
    kubectl -n "${NAMESPACE}" get events --sort-by=.lastTimestamp 2>&1 || true
    printf '\n--- controller status ---\n'
    if [[ "${TOOL}" == "argocd" ]]; then
      kubectl -n argocd get applications.argoproj.io -o wide 2>&1 || true
    else
      kubectl -n flux-system get gitrepositories.source.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io -o wide 2>&1 || true
    fi
  } >>"${CURRENT_LOG}"
}

resolve_deployment() {
  local deployment
  deployment="$(kubectl -n "${NAMESPACE}" get deployment \
    -l "app.kubernetes.io/name=${SERVICE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${deployment}" ]] && kubectl -n "${NAMESPACE}" get deployment "${SERVICE}" >/dev/null 2>&1; then
    deployment="${SERVICE}"
  fi
  [[ -n "${deployment}" ]] || die "Cannot find Deployment for service '${SERVICE}' in namespace '${NAMESPACE}'"
  printf '%s\n' "${deployment}"
}

resolve_service() {
  local service_name
  service_name="$(kubectl -n "${NAMESPACE}" get service \
    -l "app.kubernetes.io/name=${SERVICE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${service_name}" ]] && kubectl -n "${NAMESPACE}" get service "${SERVICE}" >/dev/null 2>&1; then
    service_name="${SERVICE}"
  fi
  [[ -n "${service_name}" ]] || die "Cannot find Service for '${SERVICE}' in namespace '${NAMESPACE}'"
  printf '%s\n' "${service_name}"
}

service_proxy_response() {
  local service_name="$1"
  local endpoint="$2"
  local service_port path
  service_port="$(kubectl -n "${NAMESPACE}" get service "${service_name}" \
    -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)" || return 1
  path="/api/v1/namespaces/${NAMESPACE}/services/http:${service_name}:${service_port}/proxy/${endpoint}"
  kubectl get --raw "${path}" 2>/dev/null
}

endpoint_field_equals() {
  local service_name="$1"
  local endpoint="$2"
  local field="$3"
  local expected="$4"
  local response
  response="$(service_proxy_response "${service_name}" "${endpoint}" 2>/dev/null)" || return 1
  python3 -c 'import json, sys; value=json.loads(sys.argv[1]).get(sys.argv[2]); raise SystemExit(0 if str(value) == sys.argv[3] else 1)' \
    "${response}" "${field}" "${expected}" >/dev/null 2>&1
}

controller_is_ready() {
  if [[ "${TOOL}" == "argocd" ]]; then
    local sync health
    IFS='|' read -r sync health < <(
      kubectl -n argocd get application.argoproj.io "${GITOPS_RESOURCE_NAME}" \
        -o jsonpath='{.status.sync.status}{"|"}{.status.health.status}{"\n"}' \
        2>/dev/null || true
    )
    [[ "${sync}" == "Synced" && "${health}" == "Healthy" ]]
  else
    local source_ready release_ready
    source_ready="$(kubectl -n flux-system get gitrepository.source.toolkit.fluxcd.io "${GITOPS_RESOURCE_NAME}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    release_ready="$(kubectl -n flux-system get helmrelease.helm.toolkit.fluxcd.io "${GITOPS_RESOURCE_NAME}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "${source_ready}" == "True" && "${release_ready}" == "True" ]]
  fi
}

controller_operation_is_idle() {
  if [[ "${TOOL}" == "argocd" ]]; then
    local operation_phase
    operation_phase="$(kubectl -n argocd get application.argoproj.io "${GITOPS_RESOURCE_NAME}" \
      -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    [[ "${operation_phase}" != "Running" && "${operation_phase}" != "Terminating" ]]
  else
    local reconciling
    reconciling="$(kubectl -n flux-system get helmrelease.helm.toolkit.fluxcd.io "${GITOPS_RESOURCE_NAME}" \
      -o jsonpath='{.status.conditions[?(@.type=="Reconciling")].status}' \
      2>/dev/null || true)"
    [[ "${reconciling}" != "True" ]]
  fi
}

flux_drift_event_marker() {
  local events_json
  events_json="$(kubectl -n flux-system get events -o json 2>/dev/null)" || return 1
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
name = sys.argv[2]
markers = []
for event in data.get("items", []):
    involved = event.get("involvedObject", {})
    text = (str(event.get("reason", "")) + " " + str(event.get("message", ""))).lower()
    if involved.get("kind") == "HelmRelease" and involved.get("name") == name and "drift" in text:
        metadata = event.get("metadata", {})
        markers.append("{}:{}".format(metadata.get("uid", ""), metadata.get("resourceVersion", "")))
print("|".join(sorted(markers)))
' "${events_json}" "${GITOPS_RESOURCE_NAME}" 2>/dev/null
}

capture_controller_baseline() {
  if [[ "${TOOL}" == "argocd" ]]; then
    IFS='|' read -r CONTROLLER_BASELINE_OPERATION CONTROLLER_BASELINE_REVISION < <(
      kubectl -n argocd get application.argoproj.io "${GITOPS_RESOURCE_NAME}" \
        -o jsonpath='{.status.operationState.startedAt}{"|"}{.status.sync.revision}{"\n"}' \
        2>/dev/null || true
    )
  else
    CONTROLLER_BASELINE_REVISION="$(kubectl -n flux-system get gitrepository.source.toolkit.fluxcd.io "${GITOPS_RESOURCE_NAME}" \
      -o jsonpath='{.status.artifact.revision}' 2>/dev/null || true)"
    IFS='|' read -r CONTROLLER_BASELINE_DRIFT_STATUS CONTROLLER_BASELINE_DRIFT_TRANSITION < <(
      kubectl -n flux-system get helmrelease.helm.toolkit.fluxcd.io "${GITOPS_RESOURCE_NAME}" \
        -o jsonpath='{.status.conditions[?(@.type=="Drifted")].status}{"|"}{.status.conditions[?(@.type=="Drifted")].lastTransitionTime}{"\n"}' \
        2>/dev/null || true
    )
    CONTROLLER_BASELINE_DRIFT_EVENTS="$(flux_drift_event_marker 2>/dev/null || true)"
  fi
}

prepare_iteration_baseline() {
  local deployment="$1"
  wait_until "GitOps controller reports a stable ready state" controller_is_ready || return 1
  wait_until "target Deployment is fully ready before mutation" deployment_is_ready "${deployment}" || return 1
  settle_before_measurement
  wait_until "GitOps controller remains stable after the pre-mutation delay" controller_is_ready || return 1
  wait_until "target Deployment remains ready after the pre-mutation delay" deployment_is_ready "${deployment}" || return 1
  capture_controller_baseline
}

verify_drift_profile() {
  [[ "${TOOL}" == "argocd" ]] || return 0
  local configured_backoff
  configured_backoff="$(kubectl -n argocd get configmap argocd-cmd-params-cm \
    -o jsonpath='{.data.controller\.self\.heal\.backoff\.timeout\.seconds}' \
    2>/dev/null || true)"
  # The key is optional in Argo CD and defaults to 2 seconds.
  configured_backoff="${configured_backoff:-2}"
  if [[ "${configured_backoff}" != "0" && "${ALLOW_ARGOCD_SELF_HEAL_BACKOFF}" != true ]]; then
    die "Argo CD self-heal backoff is active (initial timeout=${configured_backoff}s). Reapply the controlled benchmark configuration or explicitly pass --allow-argocd-self-heal-backoff for a native backoff experiment"
  fi
}

controller_source_reaction_observed() {
  if [[ "${TOOL}" == "argocd" ]]; then
    local operation revision sync
    IFS='|' read -r operation revision sync < <(
      kubectl -n argocd get application.argoproj.io "${GITOPS_RESOURCE_NAME}" \
        -o jsonpath='{.status.operationState.startedAt}{"|"}{.status.sync.revision}{"|"}{.status.sync.status}{"\n"}' \
        2>/dev/null || true
    )
    [[ "${sync}" == "OutOfSync" ||
       ( -n "${operation}" && "${operation}" != "${CONTROLLER_BASELINE_OPERATION}" ) ||
       ( -n "${revision}" && "${revision}" != "${CONTROLLER_BASELINE_REVISION}" ) ]]
  else
    local revision
    revision="$(kubectl -n flux-system get gitrepository.source.toolkit.fluxcd.io "${GITOPS_RESOURCE_NAME}" \
      -o jsonpath='{.status.artifact.revision}' 2>/dev/null || true)"
    [[ -n "${revision}" && "${revision}" != "${CONTROLLER_BASELINE_REVISION}" ]]
  fi
}

controller_drift_reaction_observed() {
  if [[ "${TOOL}" == "argocd" ]]; then
    controller_source_reaction_observed
  else
    local drift_status drift_transition drift_events marker
    local new_drift_event=false
    local -a drift_event_markers=()
    IFS='|' read -r drift_status drift_transition < <(
      kubectl -n flux-system get helmrelease.helm.toolkit.fluxcd.io "${GITOPS_RESOURCE_NAME}" \
        -o jsonpath='{.status.conditions[?(@.type=="Drifted")].status}{"|"}{.status.conditions[?(@.type=="Drifted")].lastTransitionTime}{"\n"}' \
        2>/dev/null || true
    )
    drift_events="$(flux_drift_event_marker 2>/dev/null || true)"
    IFS='|' read -r -a drift_event_markers <<<"${drift_events}"
    for marker in "${drift_event_markers[@]}"; do
      if [[ -n "${marker}" && "|${CONTROLLER_BASELINE_DRIFT_EVENTS}|" != *"|${marker}|"* ]]; then
        new_drift_event=true
        break
      fi
    done
    [[ ( "${drift_status}" == "True" && "${CONTROLLER_BASELINE_DRIFT_STATUS}" != "True" ) ||
       ( -n "${drift_transition}" && "${drift_transition}" != "${CONTROLLER_BASELINE_DRIFT_TRANSITION}" ) ||
       "${new_drift_event}" == true ]]
  fi
}

deployment_field() {
  local deployment="$1"
  local jsonpath="$2"
  kubectl -n "${NAMESPACE}" get deployment "${deployment}" -o "jsonpath=${jsonpath}" 2>/dev/null
}

deployment_is_ready() {
  local deployment="$1"
  local generation observed desired updated ready available
  generation="$(deployment_field "${deployment}" '{.metadata.generation}')" || return 1
  observed="$(deployment_field "${deployment}" '{.status.observedGeneration}')" || return 1
  desired="$(deployment_field "${deployment}" '{.spec.replicas}')" || return 1
  updated="$(deployment_field "${deployment}" '{.status.updatedReplicas}')" || return 1
  ready="$(deployment_field "${deployment}" '{.status.readyReplicas}')" || return 1
  available="$(deployment_field "${deployment}" '{.status.availableReplicas}')" || return 1
  [[ "${generation:-0}" -le "${observed:-0}" &&
     "${desired:-0}" -eq "${updated:-0}" &&
     "${desired:-0}" -eq "${ready:-0}" &&
     "${desired:-0}" -eq "${available:-0}" ]]
}

wait_until() {
  local description="$1"
  shift
  local deadline now
  deadline=$(( $(now_monotonic_ms) + TIMEOUT_SECONDS * 1000 ))
  while true; do
    if "$@"; then
      IFS=$'\t' read -r WAIT_TIME_ISO WAIT_TIME_MS < <(clock_sample)
      if [[ "${CURRENT_RESULT_RECORDED}" == false && -z "${CURRENT_DETECTION_ISO}" ]]; then
        CURRENT_DETECTION_ISO="${WAIT_TIME_ISO}"
      fi
      log "Observed: ${description}"
      return 0
    fi
    now="$(now_monotonic_ms)"
    if (( now >= deadline )); then
      log "Timed out after ${TIMEOUT_SECONDS}s waiting for: ${description}"
      return 1
    fi
    sleep "${POLL_INTERVAL}"
  done
}

finish_success() {
  local test_name="$1"
  local iteration="$2"
  local detection_iso="$3"
  local recovery_iso="$4"
  local recovery_ms="$5"
  snapshot_cluster "after"
  record_result "${test_name}" "${iteration}" "${detection_iso}" "${recovery_iso}" "${recovery_ms}" "success"
  log "Completed ${test_name} iteration ${iteration} successfully"
}

finish_failure() {
  local test_name="$1"
  local iteration="$2"
  local detection_iso="${3:-}"
  local failure_status="${4:-timeout}"
  local end_ms
  end_ms="$(now_monotonic_ms)"
  snapshot_cluster "failure"
  # A failed iteration has no recovery timestamp. Its elapsed time is still
  # recorded using the failure instant supplied as the internal end marker.
  record_result "${test_name}" "${iteration}" "${detection_iso}" "" "${end_ms}" "${failure_status}"
  log "Failed ${test_name} iteration ${iteration}: ${failure_status}"
}

pause_between_iterations() {
  # Kept for scenario compatibility. Stabilization now happens immediately
  # before each mutation and is intentionally independent of API polling.
  :
}
