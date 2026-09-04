#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: delete-cluster.sh [--name NAME]

Deletes one Kind cluster. The default name is KIND_CLUSTER_NAME or
"gitops-thesis".
USAGE
}

cluster_exists() {
  local candidate="" clusters=""
  if ! clusters="$(kind get clusters 2>&1)"; then
    printf 'ERROR: kind could not list clusters: %s\n' "$clusters" >&2
    return 2
  fi
  while IFS= read -r candidate; do
    if [[ "$candidate" == "$cluster_name" ]]; then
      return 0
    fi
  done <<<"$clusters"
  return 1
}

main() {
  cluster_name="${KIND_CLUSTER_NAME:-gitops-thesis}"
  local cluster_status=0

  while (($# > 0)); do
    case "$1" in
      --name)
        [[ $# -ge 2 ]] || { printf 'ERROR: --name requires a value.\n' >&2; exit 2; }
        cluster_name="$2"
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

  if ! command -v kind >/dev/null 2>&1; then
    printf 'ERROR: required command is not installed: kind\n' >&2
    exit 1
  fi
  if [[ ! "$cluster_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    printf 'ERROR: invalid Kind cluster name: %s\n' "$cluster_name" >&2
    exit 2
  fi

  if cluster_exists; then
    :
  else
    cluster_status=$?
    (( cluster_status == 1 )) || exit "$cluster_status"
    printf 'Kind cluster %s does not exist; nothing to delete.\n' "$cluster_name"
    exit 0
  fi

  printf 'Deleting Kind cluster %s...\n' "$cluster_name"
  kind delete cluster --name "$cluster_name"
  printf 'Kind cluster %s was deleted.\n' "$cluster_name"
}

main "$@"
