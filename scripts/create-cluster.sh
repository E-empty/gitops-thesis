#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<USAGE
Usage: create-cluster.sh [options]

Creates the local Kind cluster and waits for its node to become Ready.

Options:
  --name NAME       Cluster name (default: \$KIND_CLUSTER_NAME or gitops-thesis).
  --config FILE     Kind configuration (default: scripts/kind-config.yaml).
  --image IMAGE     kindest/node image (default: pinned Kubernetes v1.33.4).
  --wait DURATION   Kind/kubectl timeout (default: 120s).
  --help            Show this help.

Environment equivalents: KIND_CLUSTER_NAME, KIND_CONFIG, KIND_NODE_IMAGE,
KIND_WAIT_TIMEOUT.
USAGE
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'ERROR: required command is not installed: %s\n' "$1" >&2
    exit 1
  fi
}

cluster_exists() {
  local candidate="" clusters=""
  if ! clusters="$(kind get clusters 2>&1)"; then
    printf 'ERROR: kind could not list clusters: %s\n' "$clusters" >&2
    return 2
  fi
  while IFS= read -r candidate; do
    if [[ "$candidate" == "$CLUSTER_NAME" ]]; then
      return 0
    fi
  done <<<"$clusters"
  return 1
}

main() {
  CLUSTER_NAME="${KIND_CLUSTER_NAME:-gitops-thesis}"
  local config_file="${KIND_CONFIG:-${SCRIPT_DIR}/kind-config.yaml}"
  local node_image="${KIND_NODE_IMAGE:-kindest/node:v1.33.4@sha256:25a6018e48dfcaee478f4a59af81157a437f15e6e140bf103f85a2e7cd0cbbf2}"
  local wait_timeout="${KIND_WAIT_TIMEOUT:-120s}"
  local context=""
  local cluster_status=0
  local -a create_args=()

  while (($# > 0)); do
    case "$1" in
      --name)
        [[ $# -ge 2 ]] || { printf 'ERROR: --name requires a value.\n' >&2; exit 2; }
        CLUSTER_NAME="$2"
        shift 2
        ;;
      --config)
        [[ $# -ge 2 ]] || { printf 'ERROR: --config requires a file.\n' >&2; exit 2; }
        config_file="$2"
        shift 2
        ;;
      --image)
        [[ $# -ge 2 ]] || { printf 'ERROR: --image requires a reference.\n' >&2; exit 2; }
        node_image="$2"
        shift 2
        ;;
      --wait)
        [[ $# -ge 2 ]] || { printf 'ERROR: --wait requires a duration.\n' >&2; exit 2; }
        wait_timeout="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        printf 'ERROR: unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  require_command docker
  require_command kind
  require_command kubectl

  if [[ ! "$CLUSTER_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    printf 'ERROR: invalid Kind cluster name: %s\n' "$CLUSTER_NAME" >&2
    exit 2
  fi
  if [[ ! -f "$config_file" ]]; then
    printf 'ERROR: Kind configuration does not exist: %s\n' "$config_file" >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    printf 'ERROR: Docker daemon is not reachable.\n' >&2
    exit 1
  fi

  context="kind-${CLUSTER_NAME}"
  if cluster_exists; then
    printf 'Kind cluster %s already exists; leaving it unchanged.\n' "$CLUSTER_NAME"
    kubectl --context "$context" cluster-info
    exit 0
  else
    cluster_status=$?
    (( cluster_status == 1 )) || exit "$cluster_status"
  fi

  create_args=(create cluster --name "$CLUSTER_NAME" --config "$config_file" --wait "$wait_timeout")
  create_args+=(--image "$node_image")

  printf 'Creating Kind cluster %s using %s...\n' "$CLUSTER_NAME" "$config_file"
  kind "${create_args[@]}"
  kubectl --context "$context" wait --for=condition=Ready node --all --timeout="$wait_timeout"
  kubectl --context "$context" cluster-info
  printf 'Kind cluster %s is ready (context: %s).\n' "$CLUSTER_NAME" "$context"
}

main "$@"
